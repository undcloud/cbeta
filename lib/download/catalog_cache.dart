import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

@immutable
class CatalogNode {
  const CatalogNode({
    required this.label,
    required this.query,
    this.children = const [],
    this.works = const [],
    this.totalWorks,
  });

  final String label;
  final String query;
  final List<CatalogNode> children;
  final List<CatalogWork> works;

  /// 子樹中不重複的經文數量；未提供時即時計算。
  final int? totalWorks;

  int get workCount => totalWorks ?? collectWorkIds().length;

  Iterable<String> collectWorkIds() sync* {
    for (final work in works) {
      yield work.work;
    }
    for (final child in children) {
      yield* child.collectWorkIds();
    }
  }
}

@immutable
class CatalogWork {
  const CatalogWork({
    required this.work,
    required this.label,
    this.title = '',
    this.creators = '',
    this.file = '',
    this.juanStart,
    this.juans = const [],
  });

  final String work;
  final String label;
  final String title;
  final String creators;
  final String file;
  final int? juanStart;
  final List<String> juans;

  int get totalJuans => juans.isNotEmpty
      ? juans.length
      : (juanStart == null ? 1 : (juanStart! < 1 ? 1 : juanStart!));

  Map<String, dynamic> toItemMap() {
    final displayTitle = title.isNotEmpty
        ? title
        : label.replaceFirst(RegExp('^${RegExp.escape(work)}\\s+'), '');
    return {
      'work': work,
      'label': label,
      'title': displayTitle,
      'byline': creators,
      'creators': creators,
      'file': file,
      'juan': totalJuans,
      'juan_start': juanStart ?? 1,
      if (juans.isNotEmpty) 'juans': juans,
    };
  }
}

@immutable
class AllWorksEntry {
  const AllWorksEntry({
    required this.work,
    required this.title,
    required this.juans,
    this.creators = '',
    this.category = '',
    this.file = '',
  });

  final String work;
  final String title;
  final List<String> juans;
  final String creators;
  final String category;
  final String file;
}

@immutable
class CreatorEntry {
  const CreatorEntry({
    required this.id,
    required this.name,
    this.aliases = const [],
    this.works = const [],
    this.strokeGroup = '',
  });

  final String id;
  final String name;
  final List<String> aliases;
  final List<CreatorWork> works;
  final String strokeGroup;
}

@immutable
class CreatorWork {
  const CreatorWork({
    required this.work,
    required this.label,
    this.title = '',
    this.creators = '',
    this.file = '',
    this.juanStart,
    this.juan,
  });

  final String work;
  final String label;
  final String title;
  final String creators;
  final String file;
  final int? juanStart;
  final int? juan;

  Map<String, dynamic> toMap() => {
    'work': work,
    'label': label,
    'title': title,
    'byline': creators,
    'creators': creators,
    'file': file,
    'juan': juan ?? juanStart,
    'juan_start': juanStart,
  };
}

@immutable
class DynastyEntry {
  const DynastyEntry({
    required this.name,
    required this.start,
    required this.end,
    this.works = const [],
    this.period,
  });

  final String name;
  final String start;
  final String end;
  final List<DynastyWork> works;
  final String? period;

  Map<String, dynamic> toMap() => {
    'name': name,
    'start': start,
    'end': end,
    if (period != null && period!.isNotEmpty) 'period': period,
    'count': '${works.length}',
    'works': works.map((w) => w.toMap()).toList(),
  };
}

@immutable
class DynastyWork {
  const DynastyWork({
    required this.work,
    required this.label,
    this.title = '',
    this.byline = '',
    this.file = '',
    this.juan,
  });

  final String work;
  final String label;
  final String title;
  final String byline;
  final String file;
  final int? juan;

  Map<String, dynamic> toMap() => {
    'work': work,
    'label': label,
    'title': title,
    'byline': byline,
    'file': file,
    'juan': juan,
  };
}

class _WorkMeta {
  _WorkMeta({required this.work, required this.label, required this.title});

  final String work;
  final String label;
  String title;
  String creators = '';
  int? juan;
}

class CatalogCache extends ChangeNotifier {
  CatalogCache._();

  static final CatalogCache instance = CatalogCache._();

  /// 經目更新後，下載檔案會放在應用程式支援目錄；由 App 啟動時注入讀取器。
  /// 測試未注入時一律使用安裝包內的資產。
  Future<Uint8List?> Function(String fileName)? localFileLoader;

  CatalogNode? _cbetaTree;
  CatalogNode? _origTree;
  Map<String, AllWorksEntry>? _allWorks;
  Map<String, String> _workFiles = {};
  Map<String, CreatorEntry>? _creators;
  List<DynastyEntry>? _dynasties;
  Map<String, String> _workDepartments = {};
  bool _loaded = false;
  Future<void>? _loading;

  bool get isLoaded => _loaded;

  Future<void> load() async {
    if (_loaded) return;
    final loading = _loading;
    if (loading != null) return loading;
    final future = _load();
    _loading = future;
    try {
      await future;
    } catch (_) {
      _loading = null;
      rethrow;
    }
  }

  /// 重新讀取經目檔（可能已被更新服務覆寫），並通知側邊欄重建目錄。
  Future<void> reload() async {
    final loading = _loading;
    if (loading != null) {
      try {
        await loading;
      } catch (_) {}
    }
    _resetState();
    await load();
    notifyListeners();
  }

  Future<void> _load() async {
    final categoryRaw = await _loadCatalogJson('category.json');
    final volumeRaw = await _loadCatalogJson('vol.json');
    final creatorsRaw = await _loadCatalogJson(
      'creators-by-strokes-with-works.json',
    );
    final dynastiesRaw = await _loadCatalogJson('dynasty-works.json');
    final workFilesRaw = await _loadCatalogJson('work_files.json');
    _workFiles = {
      if (workFilesRaw.isNotEmpty)
        for (final entry in workFilesRaw.first.entries)
          if (entry.value is String) entry.key: entry.value as String,
    };

    final metas = <String, _WorkMeta>{};
    _collectWorkMeta(categoryRaw, metas);
    _collectWorkMeta(volumeRaw, metas);
    _collectWorkMeta(creatorsRaw, metas);
    _collectWorkMeta(dynastiesRaw, metas);

    _cbetaTree = _buildScopeTree(categoryRaw, rootQuery: 'CBETA', metas: metas);
    _origTree = _buildScopeTree(volumeRaw, rootQuery: 'orig', metas: metas);
    _dynasties = _buildDynasties(dynastiesRaw, metas);
    _creators = _buildCreators(creatorsRaw, metas);

    _workDepartments = {};
    final cbeta = _cbetaTree;
    if (cbeta != null) {
      for (final department in cbeta.children) {
        final label = department.label;
        for (final work in department.collectWorkIds()) {
          _workDepartments.putIfAbsent(work, () => label);
        }
      }
    }

    _allWorks = {
      for (final meta in metas.values)
        meta.work: AllWorksEntry(
          work: meta.work,
          title: meta.title,
          juans: _juanList(meta.juan),
          creators: meta.creators,
          category: _workDepartments[meta.work] ?? '',
          file: _workFiles[meta.work] ?? '',
        ),
    };
    _loaded = true;
    _loading = null;
  }

  CatalogNode? get cbetaTree => _cbetaTree;
  CatalogNode? get origTree => _origTree;

  AllWorksEntry? lookupWork(String workId) => _allWorks?[workId];

  List<AllWorksEntry> get allWorks => _allWorks?.values.toList() ?? const [];

  /// 以本地內建的完整經目搜尋作品編號、經名與作譯者。
  List<Map<String, dynamic>> searchWorks(String rawQuery, {int limit = 200}) {
    final query = rawQuery.trim().toLowerCase();
    final works = _allWorks;
    if (query.isEmpty || works == null) return const [];
    final matches = <(int, AllWorksEntry)>[];
    for (final entry in works.values) {
      final workId = entry.work.toLowerCase();
      final title = entry.title.toLowerCase();
      // 經目查詢只按編號與書名匹配；作譯者／朝代有獨立的分頁入口。
      if (!workId.contains(query) && !title.contains(query)) {
        continue;
      }
      var rank = 3;
      if (workId == query || title == query) {
        rank = 0;
      } else if (title.startsWith(query) || workId.startsWith(query)) {
        rank = 1;
      }
      matches.add((rank, entry));
    }
    matches.sort((left, right) {
      final byRank = left.$1.compareTo(right.$1);
      if (byRank != 0) return byRank;
      return left.$2.title.compareTo(right.$2.title);
    });
    return matches.take(limit).map((match) {
      final work = match.$2;
      return <String, dynamic>{
        'work': work.work,
        'label': '${work.work} ${work.title}'.trim(),
        'title': work.title,
        'byline': work.creators,
        'creators': work.creators,
        'juan': work.juans.length,
        'juan_start': 1,
        if (work.category.isNotEmpty) 'category': work.category,
        if (work.file.isNotEmpty) 'file': work.file,
      };
    }).toList();
  }

  Map<String, CreatorEntry> get creators => _creators ?? const {};

  List<DynastyEntry> get dynasties => _dynasties ?? const [];

  String? lookupWorkFile(String workId) => _workFiles[workId];

  String? departmentForWork(String workId) => _workDepartments[workId];

  Set<String> workIdsInNode(CatalogNode node) => node.collectWorkIds().toSet();

  CatalogNode? findNode(String query) {
    if (_cbetaTree == null && _origTree == null) return null;
    if (query == 'CBETA') return _cbetaTree;
    if (query == 'orig') return _origTree;
    return _findInTree(_cbetaTree, query) ?? _findInTree(_origTree, query);
  }

  CatalogNode? _findInTree(CatalogNode? root, String query) {
    if (root == null) return null;
    if (root.query == query) return root;
    for (final child in root.children) {
      final found = _findInTree(child, query);
      if (found != null) return found;
    }
    return null;
  }

  List<Map<String, dynamic>> nodeToItems(CatalogNode node) {
    final items = <Map<String, dynamic>>[];
    for (final child in node.children) {
      items.add({
        'n': child.query,
        'label': child.label,
        'count': child.workCount,
      });
    }
    for (final work in node.works) {
      items.add(work.toItemMap());
    }
    return items;
  }

  Future<List<Map<String, dynamic>>> _loadCatalogJson(String fileName) async {
    final loader = localFileLoader;
    if (loader != null) {
      try {
        final local = await loader(fileName);
        if (local != null) {
          final decoded = jsonDecode(utf8.decode(local));
          final list = _normalizeJsonRoot(decoded);
          if (list != null && list.isNotEmpty) return list;
        }
      } catch (_) {
        // 下載檔損壞時退回安裝包內的經目，避免整個側邊欄無法使用。
      }
    }
    return _loadAssetJsonArray('assets/cbeta_catalog/$fileName');
  }

  static Future<List<Map<String, dynamic>>> _loadAssetJsonArray(
    String path,
  ) async {
    final data = await rootBundle.load(path);
    final decoded = jsonDecode(
      utf8.decode(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      ),
    );
    return _normalizeJsonRoot(decoded) ?? const [];
  }

  static List<Map<String, dynamic>>? _normalizeJsonRoot(Object? decoded) {
    if (decoded is Map<String, dynamic>) return [decoded];
    if (decoded is List) {
      return decoded.whereType<Map<String, dynamic>>().toList();
    }
    return null;
  }

  static String _titleOf(Map<String, dynamic> node) =>
      '${node['title'] ?? ''}'.trim();

  static String? _keyOf(Map<String, dynamic> node) {
    final key = '${node['key'] ?? ''}'.trim();
    return key.isEmpty ? null : key;
  }

  static List<Map<String, dynamic>> _childrenOf(Map<String, dynamic> node) =>
      (node['children'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();

  static List<String> _juanList(int? count) =>
      List.generate(count == null || count < 1 ? 1 : count, (i) => '${i + 1}');

  static _WorkMeta _parseWorkMeta(String key, String rawTitle) {
    var rest = rawTitle;
    if (rest.startsWith(key)) rest = rest.substring(key.length).trim();

    var creators = '';
    final bylineMatch = RegExp(r'【(.*)】\s*$').firstMatch(rest);
    if (bylineMatch != null) {
      creators = bylineMatch.group(1)!.trim();
      rest = rest.substring(0, bylineMatch.start).trim();
    }

    int? juan;
    final volumeMatch = RegExp(
      r'[\(（]\s*(\d*)\s*卷\s*[\)）]\s*$',
    ).firstMatch(rest);
    if (volumeMatch != null) {
      juan = int.tryParse(volumeMatch.group(1) ?? '');
      rest = rest.substring(0, volumeMatch.start).trim();
    }
    if (rest.isEmpty) rest = rawTitle;
    final meta = _WorkMeta(work: key, label: rawTitle, title: rest);
    meta.creators = creators;
    meta.juan = juan;
    return meta;
  }

  static void _collectWorkMeta(
    List<Map<String, dynamic>> roots,
    Map<String, _WorkMeta> metas,
  ) {
    void walk(Map<String, dynamic> node) {
      final children = _childrenOf(node);
      if (children.isNotEmpty) {
        for (final child in children) {
          walk(child);
        }
        return;
      }
      final key = _keyOf(node);
      if (key == null) return;
      final parsed = _parseWorkMeta(key, _titleOf(node));
      final existing = metas[key];
      if (existing == null) {
        metas[key] = parsed;
        return;
      }
      if (existing.creators.isEmpty && parsed.creators.isNotEmpty) {
        existing.creators = parsed.creators;
      }
      if (existing.juan == null && parsed.juan != null) {
        existing.juan = parsed.juan;
      }
      if ((existing.title.isEmpty ||
              existing.title.contains('卷)') ||
              existing.title.contains('卷）')) &&
          parsed.title.isNotEmpty) {
        existing.title = parsed.title;
      }
    }

    for (final root in roots) {
      walk(root);
    }
  }

  static String _workLabel(_WorkMeta meta, String fallback) {
    final title = meta.title.isNotEmpty ? meta.title : fallback;
    return title.startsWith(meta.work) ? title : '${meta.work} $title';
  }

  CatalogNode _buildScopeTree(
    List<Map<String, dynamic>> roots, {
    required String rootQuery,
    required Map<String, _WorkMeta> metas,
  }) {
    final root = roots.isEmpty ? <String, dynamic>{} : roots.first;
    return _buildScopeNode(root, query: rootQuery, metas: metas);
  }

  CatalogNode _buildScopeNode(
    Map<String, dynamic> raw, {
    required String query,
    required Map<String, _WorkMeta> metas,
  }) {
    final children = <CatalogNode>[];
    final works = <CatalogWork>[];
    final rawChildren = _childrenOf(raw);
    for (var index = 0; index < rawChildren.length; index++) {
      final child = rawChildren[index];
      final childChildren = _childrenOf(child);
      if (childChildren.isNotEmpty) {
        children.add(
          _buildScopeNode(child, query: '$query/$index', metas: metas),
        );
        continue;
      }
      final key = _keyOf(child);
      if (key == null) continue;
      final meta = metas[key] ?? _parseWorkMeta(key, _titleOf(child));
      works.add(
        CatalogWork(
          work: key,
          label: _workLabel(meta, _titleOf(child)),
          title: meta.title,
          creators: meta.creators,
          juans: _juanList(meta.juan),
          juanStart: 1,
        ),
      );
    }

    final workIds = <String>{
      for (final work in works) work.work,
      for (final child in children) ...child.collectWorkIds(),
    };
    return CatalogNode(
      label: _titleOf(raw),
      query: query,
      children: children,
      works: works,
      totalWorks: workIds.length,
    );
  }

  List<DynastyEntry> _buildDynasties(
    List<Map<String, dynamic>> roots,
    Map<String, _WorkMeta> metas,
  ) {
    if (roots.isEmpty) return const [];
    final root = roots.first;
    final entries = <DynastyEntry>[];
    for (final raw in _childrenOf(root)) {
      final name = _keyOf(raw) ?? _titleOf(raw);
      if (name.isEmpty) continue;
      final rawTitle = _titleOf(raw);
      final rest = rawTitle.startsWith(name)
          ? rawTitle.substring(name.length).trim()
          : rawTitle;
      final range = RegExp(
        r'^(-?\d+)\s+(BCE|CE)\s*~\s*(-?\d+)\s+(BCE|CE)$',
      ).firstMatch(rest);
      final period = rest.isEmpty
          ? null
          : rest.replaceAll(RegExp(r'\s*~\s*'), '–');
      final works = <DynastyWork>[];
      for (final child in _childrenOf(raw)) {
        final work = _keyOf(child);
        if (work == null) continue;
        final meta = metas[work] ?? _parseWorkMeta(work, _titleOf(child));
        works.add(
          DynastyWork(
            work: work,
            label: _workLabel(meta, _titleOf(child)),
            title: meta.title,
            byline: meta.creators,
            juan: meta.juan,
          ),
        );
      }
      entries.add(
        DynastyEntry(
          name: name,
          start: range?.group(1) ?? '',
          end: range?.group(3) ?? '',
          period: period,
          works: works,
        ),
      );
    }
    return entries;
  }

  Map<String, CreatorEntry> _buildCreators(
    List<Map<String, dynamic>> roots,
    Map<String, _WorkMeta> metas,
  ) {
    if (roots.isEmpty) return const {};
    final root = roots.first;
    final result = <String, CreatorEntry>{};
    for (final stroke in _childrenOf(root)) {
      final strokeTitle = _titleOf(stroke);
      final group =
          RegExp(
            r'^(\d+)劃',
          ).firstMatch(strokeTitle)?.group(0)?.replaceFirst('劃', ' 劃') ??
          (strokeTitle.contains('缺作譯者') ? '其他' : strokeTitle);
      final characters = _childrenOf(stroke);
      for (final character in characters) {
        for (final raw in _childrenOf(character)) {
          final name = _titleOf(raw);
          if (name.isEmpty) continue;
          final baseId = _keyOf(raw) ?? name;
          var id = baseId;
          var suffix = 2;
          while (result.containsKey(id)) {
            id = '$baseId#${suffix++}';
          }
          final works = <CreatorWork>[];
          for (final child in _childrenOf(raw)) {
            final work = _keyOf(child);
            if (work == null) continue;
            final meta = metas[work] ?? _parseWorkMeta(work, _titleOf(child));
            works.add(
              CreatorWork(
                work: work,
                label: _workLabel(meta, _titleOf(child)),
                title: meta.title,
                creators: meta.creators,
                juanStart: 1,
                juan: meta.juan,
              ),
            );
          }
          result[id] = CreatorEntry(
            id: id,
            name: name,
            strokeGroup: group,
            works: works,
          );
        }
      }
    }
    return result;
  }

  @visibleForTesting
  void debugLoad({
    CatalogNode? cbetaTree,
    CatalogNode? origTree,
    Map<String, AllWorksEntry>? allWorks,
    Map<String, CreatorEntry>? creators,
    List<DynastyEntry>? dynasties,
    Map<String, String>? workDepartments,
    Map<String, String>? workFiles,
  }) {
    if (cbetaTree != null) _cbetaTree = cbetaTree;
    if (origTree != null) _origTree = origTree;
    if (allWorks != null) _allWorks = allWorks;
    if (creators != null) _creators = creators;
    if (dynasties != null) _dynasties = dynasties;
    if (workDepartments != null) _workDepartments = workDepartments;
    if (workFiles != null) _workFiles = workFiles;
    _loaded = true;
  }

  @visibleForTesting
  void debugReset() {
    _resetState();
  }

  void _resetState() {
    _cbetaTree = null;
    _origTree = null;
    _allWorks = null;
    _workFiles = {};
    _creators = null;
    _dynasties = null;
    _workDepartments = {};
    _loaded = false;
    _loading = null;
  }
}
