import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../cbeta_api_headers.dart';
import '../scripture/cache.dart';
import '../scripture/models.dart';
import '../scripture/offline_scan.dart';
import '../scripture/parser.dart';
import '../search/goto.dart';
import '../download/catalog_cache.dart';
import '../common/text_patterns.dart';
import 'search_api.dart';

String catalogResultWorkId(Map<String, dynamic> result) {
  final work = '${result['work'] ?? ''}'.trim();
  if (work.isNotEmpty) return work;
  final file = '${result['file'] ?? ''}';
  final match = fileWorkIdPattern.firstMatch(file);
  return match == null ? '' : '${match.group(1)}${match.group(2)}';
}

/// 取得作品的卷清單。
///
/// 多數作品以 `juan` 欄位提供卷資料；部分作品（例如印順法師著作等 Y 系列）
/// 只提供 `mulu` 目錄樹，此時改由目錄樹依卷彙整出可讀取的卷。
List<Map<String, dynamic>> tocJuanEntries(Map<String, dynamic>? toc) {
  final juans = (toc?['juan'] as List<dynamic>? ?? const [])
      .whereType<Map<String, dynamic>>()
      .toList();
  if (juans.isNotEmpty) return juans;

  void collect(List<dynamic> entries, Map<int, Map<String, dynamic>> byJuan) {
    for (final entry in entries.whereType<Map<String, dynamic>>()) {
      final juan = int.tryParse('${entry['juan'] ?? ''}');
      final lb = '${entry['lb'] ?? ''}';
      if (juan != null) {
        final current = byJuan[juan];
        if (current == null ||
            (lb.isNotEmpty && lb.compareTo('${current['lb'] ?? ''}') < 0)) {
          byJuan[juan] = {
            'file': entry['file'],
            'juan': juan,
            'lb': entry['lb'],
            'title': '第$juan卷',
          };
        }
      }
      collect(entry['children'] as List<dynamic>? ?? const [], byJuan);
    }
  }

  final byJuan = <int, Map<String, dynamic>>{};
  collect(toc?['mulu'] as List<dynamic>? ?? const [], byJuan);
  return byJuan.values.toList()..sort(
    (left, right) => (left['juan'] as int).compareTo(right['juan'] as int),
  );
}

String searchResultWorkId(ScriptureSearchResult result) {
  final passageWork = result.passages.firstOrNull?.work;
  if (passageWork != null && passageWork.isNotEmpty) return passageWork;
  final match = workIdPattern.firstMatch(result.title);
  return match?.group(1) ?? '';
}

Future<ScripturePassage> resolveGotoPassage(String input) async {
  final linehead = normalizeCbetaGotoLinehead(extractCbetaGotoQuery(input));
  if (!isCbetaGotoExpression(linehead)) {
    throw const FormatException('請輸入有效的 CBETA 行號或引文');
  }
  try {
    return await resolveGotoPassageOnline(linehead);
  } catch (error) {
    if (isNetworkFailure(error)) {
      final local = await resolveGotoPassageLocally(linehead);
      if (local != null) return local;
      throw FormatException('離線模式下，本地尚未儲存「$linehead」所在的經卷');
    }
    rethrow;
  }
}

Future<ScripturePassage> resolveGotoPassageOnline(String linehead) async {
  final response = await http
      .get(
        Uri.https('cbdata.dila.edu.tw', '/stable/juans/goto', {
          'linehead': linehead,
        }),
        headers: cbetaApiHeaders,
      )
      .timeout(const Duration(seconds: 20));
  if (response.statusCode != 200) {
    throw Exception('Goto API 回傳 ${response.statusCode}');
  }
  final payload =
      jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  final apiError = payload['error'];
  if (apiError is Map<String, dynamic>) {
    throw FormatException('${apiError['message'] ?? '無法識別此行號'}');
  }
  if (apiError is String && apiError.isNotEmpty) {
    throw FormatException(apiError);
  }
  final result = (payload['results'] as List<dynamic>? ?? const [])
      .whereType<Map<String, dynamic>>()
      .firstOrNull;
  if (result == null) throw const FormatException('找不到此行號對應的經卷');
  return resolveWorkPassage(
    result,
    targetLinehead: '${result['linehead'] ?? linehead}',
  );
}

Future<ScripturePassage> resolveCatalogWorkPassage(
  Map<String, dynamic> result,
) async {
  final work = catalogResultWorkId(result);
  if (work.isEmpty) throw const FormatException('經目資料缺少作品編號');
  return resolveWorkPassage({...result, 'work': work});
}

Future<ScripturePassage> resolveWorkPassage(
  Map<String, dynamic> item, {
  String? targetLinehead,
}) async {
  final work = '${item['work'] ?? catalogResultWorkId(item)}';
  if (work.isEmpty) throw const FormatException('經目資料缺少作品編號');
  try {
    return await resolveWorkPassageOnline(
      work,
      item,
      targetLinehead: targetLinehead,
    );
  } catch (error) {
    if (isNetworkFailure(error)) {
      final local = await localWorkPassage(
        work,
        targetLinehead: targetLinehead,
      );
      if (local != null) return local;
    }
    rethrow;
  }
}

Future<ScripturePassage> resolveWorkPassageOnline(
  String work,
  Map<String, dynamic> item, {
  String? targetLinehead,
}) async {
  final response = await http
      .get(
        Uri.https('cbdata.dila.edu.tw', '/stable/works/toc', {'work': work}),
        headers: cbetaApiHeaders,
      )
      .timeout(const Duration(seconds: 20));
  if (response.statusCode != 200) {
    throw Exception('作品目錄 API 回傳 ${response.statusCode}');
  }
  final payload =
      jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  final toc = (payload['results'] as List<dynamic>? ?? const [])
      .whereType<Map<String, dynamic>>()
      .firstOrNull;
  final juans = tocJuanEntries(toc);
  if (juans.isEmpty) throw const FormatException('此作品沒有可讀取的卷');

  final availableJuans =
      juans
          .map((entry) => entry['juan'])
          .whereType<num>()
          .map((value) => value.toInt())
          .toSet()
          .toList()
        ..sort();
  final targetJuan = targetLinehead == null
      ? null
      : int.tryParse('${item['juan'] ?? ''}');
  if (targetJuan != null && !availableJuans.contains(targetJuan)) {
    availableJuans.add(targetJuan);
    availableJuans.sort();
  }
  final selected =
      juans.where((entry) => entry['juan'] == targetJuan).firstOrNull ??
      (targetJuan == null
          ? null
          : {
              'file': item['file'],
              'juan': targetJuan,
              'lb': item['lb'] ?? targetLinehead!.split('_p').last,
            }) ??
      juans
          .where((entry) => entry['juan'] == availableJuans.first)
          .firstOrNull ??
      juans.first;
  final file = '${selected['file'] ?? item['file'] ?? work}';
  final line = targetLinehead == null
      ? '${selected['lb'] ?? ''}'
      : targetLinehead.split('_p').last;
  final rawTitle = '${item['title'] ?? item['label'] ?? work}';
  final title = rawTitle.replaceFirst(
    RegExp('^${RegExp.escape(work)}\\s+'),
    '',
  );
  return ScripturePassage(
    title: title,
    reference: '卷 ${selected['juan']}',
    text: '',
    linehead: line.isEmpty ? null : '${file}_p$line',
    juan: '${selected['juan']}',
    work: work,
    availableJuans: availableJuans,
  );
}

/// 以 App 內建的完整經目 metadata 查詢,不發任何網路請求。
Future<List<Map<String, dynamic>>> searchLocalCatalog(String query) async {
  final needle = query.trim();
  if (needle.isEmpty) return const [];
  try {
    final catalog = CatalogCache.instance;
    await catalog.load();
    return catalog.searchWorks(needle, limit: localCatalogResultLimit);
  } catch (_) {
    // 經目資產載入失敗時沒有可查的書名表,交由離線經卷那層兜底。
    return const [];
  }
}

List<ScriptureLine>? tryParseLocalVolume(CachedScriptureVolume volume) {
  try {
    return parseScriptureHtml(volume.html);
  } catch (_) {
    return null;
  }
}

List<int> cachedJuansForRefs(List<ScriptureVolumeRef> refs, String work) =>
    refs
        .where((ref) => ref.work == work)
        .map((ref) => int.tryParse(ref.juan))
        .whereType<int>()
        .toSet()
        .toList()
      ..sort();

int juanNumber(ScriptureVolumeRef ref) => int.tryParse(ref.juan) ?? 0;

void sortRefsByJuan(List<ScriptureVolumeRef> refs) {
  refs.sort((left, right) => juanNumber(left).compareTo(juanNumber(right)));
}

String lineheadWorkId(String linehead) {
  final match = RegExp(r'^([A-Z]+)\d+n(\d+[A-Z]?)_p').firstMatch(linehead);
  return match == null ? '' : '${match.group(1)}${match.group(2)}';
}

ScripturePassage localPassage({
  required String work,
  required CachedScriptureVolume volume,
  required List<ScriptureLine> lines,
  required List<int> juans,
  String? linehead,
}) {
  final title = localWorkTitle(lines);
  return ScripturePassage(
    title: title.isEmpty ? work : title,
    reference: '卷 ${volume.juan}',
    text: '',
    linehead: linehead,
    juan: volume.juan,
    work: work,
    availableJuans: juans,
  );
}

/// 以本地已儲存的離線經卷建立可開啟的經卷位置，
/// 供離線經目點擊與 Goto 使用。
Future<ScripturePassage?> localWorkPassage(
  String work, {
  String? targetLinehead,
}) async {
  if (work.isEmpty) return null;
  final allRefs = await scriptureVolumeStore.listRefs();
  final workRefs = allRefs.where((ref) => ref.work == work).toList();
  if (workRefs.isEmpty) return null;
  sortRefsByJuan(workRefs);
  final juans = cachedJuansForRefs(allRefs, work);
  if (targetLinehead != null) {
    for (final ref in workRefs) {
      final volume = await scriptureVolumeStore.readRef(ref);
      if (volume == null) continue;
      final lines = tryParseLocalVolume(volume);
      if (lines != null &&
          lines.any((line) => line.linehead == targetLinehead)) {
        return localPassage(
          work: work,
          volume: volume,
          lines: lines,
          juans: juans,
          linehead: targetLinehead,
        );
      }
    }
  }
  final target = await scriptureVolumeStore.readRef(workRefs.first);
  if (target == null) return null;
  final lines = tryParseLocalVolume(target) ?? const <ScriptureLine>[];
  return localPassage(work: work, volume: target, lines: lines, juans: juans);
}

/// 離線時依行號在本地已儲存的經卷中尋找對應位置。
Future<ScripturePassage?> resolveGotoPassageLocally(String linehead) async {
  final work = lineheadWorkId(linehead);
  if (work.isEmpty) return null;
  final refs = await scriptureVolumeStore.listRefs();
  final workRefs = refs.where((ref) => ref.work == work).toList();
  sortRefsByJuan(workRefs);
  final juans = cachedJuansForRefs(refs, work);
  for (final ref in workRefs) {
    final volume = await scriptureVolumeStore.readRef(ref);
    if (volume == null) continue;
    final lines = tryParseLocalVolume(volume);
    if (lines == null || !lines.any((line) => line.linehead == linehead)) {
      continue;
    }
    return localPassage(
      work: work,
      volume: volume,
      lines: lines,
      juans: juans,
      linehead: linehead,
    );
  }
  return null;
}

/// 離線時以本地已儲存經卷的經名／作譯者進行經目查詢。
///
/// 優先使用已載入的經目資料，避免為了查詢而解析大量經文 HTML；
/// 只有經目未收錄的經卷才需要讀取內容。
Future<List<Map<String, dynamic>>> searchOfflineCatalog(String query) async {
  final needle = query.trim();
  if (needle.isEmpty) return const [];
  final refs = await scriptureVolumeStore.listRefs();
  if (refs.isEmpty) return const [];
  final downloadedWorks = {for (final ref in refs) ref.work};
  final results = <Map<String, dynamic>>[];
  final seenWorks = <String>{};
  final catalog = CatalogCache.instance;

  if (catalog.isLoaded) {
    for (final item in catalog.searchWorks(needle, limit: 5000)) {
      final work = '${item['work'] ?? ''}';
      if (work.isEmpty || !downloadedWorks.contains(work)) continue;
      if (!seenWorks.add(work)) continue;
      results.add({...item, 'offline': true});
    }
  }

  final firstRefByWork = <String, ScriptureVolumeRef>{};
  for (final ref in refs) {
    if (seenWorks.contains(ref.work)) continue;
    if (catalog.isLoaded && catalog.lookupWork(ref.work) != null) continue;
    final existing = firstRefByWork[ref.work];
    if (existing == null || juanNumber(ref) < juanNumber(existing)) {
      firstRefByWork[ref.work] = ref;
    }
  }

  final lowerNeedle = needle.toLowerCase();
  var processed = 0;
  for (final entry in firstRefByWork.entries) {
    final volume = await scriptureVolumeStore.readRef(entry.value);
    if (volume == null) continue;
    final lines = tryParseLocalVolume(volume);
    if (lines == null) continue;
    final info = localVolumeInfo(lines);
    final workTitle = localWorkTitle(lines);
    final title = workTitle.isNotEmpty ? workTitle : entry.key;
    final haystack = '$title ${entry.key}'.toLowerCase();
    if (!haystack.contains(lowerNeedle)) continue;
    results.add({
      'work': entry.key,
      'title': title,
      if (info.byline.isNotEmpty) 'byline': info.byline,
      'offline': true,
    });
    processed++;
    if (processed % 8 == 0) {
      await Future<void>.delayed(Duration.zero);
    }
  }
  results.sort(
    (left, right) => '${left['title']}'.compareTo('${right['title']}'),
  );
  return results;
}
