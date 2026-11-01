import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show ValueListenable, ValueNotifier, kIsWeb;

import '../search/conversion.dart';
import 'cache.dart';
import 'models.dart';
import 'parser.dart';
import 'sidx_norm.dart';
import 'sidx_store.dart';
import 'source_text.dart';

final _whitespacePattern = RegExp(r'\s+');

/// 一卷離線經文的定位資訊；`path` 為空時只能由主 isolate 透過 store 讀取。
class OfflineScanTarget {
  const OfflineScanTarget({
    required this.work,
    required this.juan,
    required this.path,
  });

  final String work;
  final String juan;
  final String path;
}

/// 交給背景掃描的一份工作：查詢候補與經卷清單。
///
/// `slotCandidates` 是「原字 ∪ 簡→繁候補」的逐字集合，已由 UI isolate 正規化並
/// 展開；一般資料型別才能跨 isolate 傳遞，背景因此不需要載入簡繁表。
class OfflineScanRequest {
  const OfflineScanRequest({
    required this.slotCandidates,
    required this.targets,
  });

  final List<List<int>> slotCandidates;
  final List<OfflineScanTarget> targets;
}

/// 一部作品在本批掃描裡的離線命中。
class OfflineWorkGroup {
  const OfflineWorkGroup({
    required this.work,
    required this.title,
    required this.hits,
  });

  final String work;
  final String title;
  final List<OfflineHit> hits;
}

class OfflineScanOutcome {
  const OfflineScanOutcome({
    required this.groups,
    required this.termHits,
    required this.scannedVolumes,
    this.builtIndexes = 0,
  });

  final List<OfflineWorkGroup> groups;
  final int termHits;
  final int scannedVolumes;

  /// 本批中現場從 HTML 建出 `.sidx` 的卷數；首輪掃描後會一路降到 0。
  final int builtIndexes;

  static const OfflineScanOutcome empty = OfflineScanOutcome(
    groups: [],
    termHits: 0,
    scannedVolumes: 0,
  );
}

/// 是否可以交給背景 isolate。
///
/// `flutter test` 的 fake-async 綁定不會推進真實 isolate 的回覆，網頁版也沒有
/// 檔案系統，兩種情況都走同一份實作，只少了 isolate 的跳板。
bool offlineScanSupportsIsolate() =>
    !kIsWeb && !Platform.environment.containsKey('FLUTTER_TEST');

/// 把使用者輸入換成離線索引的查詢模式。
///
/// 索引側是繁體原樣，查詢只做「簡→繁候補」這一個方向；簡繁表 4064 條映射裡
/// 只有 270 個字多義，絕大多數關鍵字每個槽位仍只有一個候補。
QueryPattern buildOfflinePattern(String query) {
  final runes = normalizedQueryRunes(query);
  if (runes.isEmpty) return QueryPattern.fromSlotCandidates(const []);
  return QueryPattern.fromSlotCandidates(
    SimplifiedTraditionalConverter.traditionalCandidateRunes(
      String.fromCharCodes(runes),
    ),
  );
}

/// 掃描一批經卷：讀檔、跳卷過濾與 BMH 比對都在拿到請求的 isolate 內完成。
Future<OfflineScanOutcome> runOfflineScan(OfflineScanRequest request) =>
    _runOfflineScan(request, yieldBetweenVolumes: false);

/// 主 isolate 上的兜底掃描。
///
/// 塊大小自適應後可長到千卷級，同步掃完整塊會直接把 UI 卡死；逐卷讓出一幀，
/// 代價是慢一點，換來畫面仍能回應。[shouldAbort] 每卷檢查一次，呼叫端（會話
/// 已 dispose、頁面已离开、搜尋已過期）用它把還在吃主執行緒的掃描停下來——
/// 不然「離開頁面」只是不再排下一塊，手上這一塊照樣跑完。
Future<OfflineScanOutcome> runOfflineScanInline(
  OfflineScanRequest request, {
  bool Function()? shouldAbort,
}) => _runOfflineScan(
  request,
  yieldBetweenVolumes: true,
  shouldAbort: shouldAbort,
);

Future<OfflineScanOutcome> _runOfflineScan(
  OfflineScanRequest request, {
  required bool yieldBetweenVolumes,
  bool Function()? shouldAbort,
}) async {
  final pattern = QueryPattern.fromSlotCandidates(request.slotCandidates);
  if (pattern.isBlank || request.targets.isEmpty) {
    return OfflineScanOutcome.empty;
  }
  final store = _indexStoreFor(request.targets);
  final merged = <String, List<OfflineHit>>{};
  final titles = <String, String>{};
  var termHits = 0;
  var built = 0;
  var scanned = 0;
  for (final target in request.targets) {
    final loaded = await _loadVolume(target, store, pattern);
    scanned++;
    if (yieldBetweenVolumes) {
      await Future<void>.delayed(Duration.zero);
      if (shouldAbort != null && shouldAbort()) break;
    }
    if (loaded == null) continue;
    built += loaded.built ? 1 : 0;
    if (loaded.skipped) continue;
    final volume = loaded.volume!;
    final hits = <OfflineHit>[];
    scanNormMatches(volume.bytes, pattern, (match) {
      final line = volume.lineAt(match.byteStart);
      hits.add(OfflineHit(juan: volume.juan, linehead: line?.linehead ?? ''));
    });
    if (hits.isEmpty) continue;
    termHits += hits.length;
    titles.putIfAbsent(volume.work, () => volume.title);
    merged.putIfAbsent(volume.work, () => <OfflineHit>[]).addAll(hits);
  }
  return OfflineScanOutcome(
    groups: [
      for (final entry in merged.entries)
        OfflineWorkGroup(
          work: entry.key,
          title: titles[entry.key] ?? entry.key,
          hits: entry.value,
        ),
    ],
    termHits: termHits,
    scannedVolumes: scanned,
    builtIndexes: built,
  );
}

ScriptureIndexStore _indexStoreFor(List<OfflineScanTarget> targets) {
  for (final target in targets) {
    if (target.path.isEmpty) continue;
    // 經卷存在 `<支援目錄>/cbeta_scripture/`，索引目錄是它的同層兄弟，
    // worker 裡沒有 path_provider，只能由路徑反推。
    final file = File(target.path);
    final cacheDirectory = file.parent.parent;
    return ScriptureIndexStore(directoryProvider: () async => cacheDirectory);
  }
  return scriptureIndexStore;
}

class _LoadedVolume {
  const _LoadedVolume.found(this.volume, {required this.built});

  /// 字符集已判定這一卷不可能命中：正文一個字節都沒讀。
  const _LoadedVolume.skipped() : volume = null, built = false;

  final SidxVolume? volume;
  final bool built;

  bool get skipped => volume == null;
}

/// 取一卷的可搜表示。`.sidx` 缺席或過期時就地重建，所以第一次掃描同時是回填，
/// 之後每卷只剩「讀標頭與字符集 →（可能命中才）讀正文」。
///
/// 跳卷過濾必須发生在讀正文之前：字符集是繁體側且取全部候補的並集，交集為空
/// 即可整卷跳過，簡體輸入不會被誤跳；過期的索引不能拿來跳卷（內容換了字集可能
/// 變大），所以戳記不符時一律重建。
Future<_LoadedVolume?> _loadVolume(
  OfflineScanTarget target,
  ScriptureIndexStore store,
  QueryPattern pattern,
) async {
  // 戳記取自來源 `.json` 的 stat，一次系統呼叫就能判索引新舊；
  // 沒有檔案路徑（網頁版）時不寫索引，戳記固定 0。
  final stamp = target.path.isEmpty
      ? 0
      : (await sidxSourceStamp(target.path)) ?? 0;
  if (target.path.isNotEmpty) {
    final skip = await store.readSkipInfoAt(
      work: target.work,
      juan: target.juan,
    );
    if (skip != null && skip.sourceStamp == stamp) {
      if (skip.canSkip(pattern.runeSet)) return const _LoadedVolume.skipped();
      final volume = await store.readAt(
        work: target.work,
        juan: target.juan,
        sourceStamp: stamp,
      );
      if (volume != null) {
        return _LoadedVolume.found(volume, built: false);
      }
    }
  }
  final lines = await _readVolumeLines(target);
  if (lines == null) return null;
  final volume = buildSidxVolume(
    work: target.work,
    juan: target.juan,
    sourceStamp: stamp,
    lines: lines.lines,
  );
  if (target.path.isNotEmpty) {
    await store.write(volume);
  }
  return _LoadedVolume.found(volume, built: true);
}

class _VolumeLines {
  const _VolumeLines(this.lines);

  final List<ScriptureLine> lines;
}

Future<_VolumeLines?> _readVolumeLines(OfflineScanTarget target) async {
  final CachedScriptureVolume? volume;
  if (target.path.isEmpty) {
    // 網頁版的經卷存在 SharedPreferences，只能由主 isolate 讀。
    volume = await scriptureVolumeStore.readRef(
      ScriptureVolumeRef(work: target.work, juan: target.juan),
    );
    if (volume == null) return null;
  } else {
    try {
      final file = File(target.path);
      if (!await file.exists()) return null;
      final decoded = CachedScriptureVolume.fromJson(
        jsonDecode(await file.readAsString()) as Map<String, dynamic>,
      );
      if (decoded.work != target.work || decoded.juan != target.juan) {
        return null;
      }
      volume = decoded;
    } catch (_) {
      return null;
    }
  }
  try {
    return _VolumeLines(parseScriptureHtml(volume.html));
  } catch (_) {
    return null;
  }
}

/// 經卷沒有檔案路徑時（網頁版）由主 isolate 逐卷讀，用同一份匹配邏輯产结果。
Future<OfflineScanOutcome> scanOfflineVolume(
  OfflineScanTarget target,
  List<List<int>> slotCandidates,
) => runOfflineScan(
  OfflineScanRequest(slotCandidates: slotCandidates, targets: [target]),
);

/// 第二階段：把一部經的離線命中展開成可讀摘要。
///
/// 索引正文刪掉了標點，不能直接給人看；點開一部經時用 HTML 重新比對一次
/// （實測約 4 ms/卷），摘要、行號與 `sourceOffset` 都取自帶標點的原文。
///
/// 每一卷都要在主 isolate 上解析整卷 HTML，所以卷與卷之間讓出一幀，並讓呼叫端
/// 用 [shouldAbort] 在離開頁面或換了搜尋後把這部經的展開停掉。
Future<List<ScripturePassage>> expandOfflineWork({
  required String work,
  required List<OfflineHit> hits,
  required String query,
  List<int> availableJuans = const [],
  bool Function()? shouldAbort,
}) async {
  if (hits.isEmpty) return const [];
  final pattern = buildOfflinePattern(query);
  if (pattern.isBlank) return const [];
  final juans = (hits.map((hit) => hit.juan).toSet().toList())..sort();
  final passages = <ScripturePassage>[];
  for (final juan in juans) {
    if (shouldAbort != null && shouldAbort()) break;
    final volume = await scriptureVolumeStore.readRef(
      ScriptureVolumeRef(work: work, juan: juan),
    );
    await Future<void>.delayed(Duration.zero);
    if (shouldAbort != null && shouldAbort()) break;
    if (volume == null) continue;
    final List<ScriptureLine> lines;
    try {
      lines = parseScriptureHtml(volume.html);
    } catch (_) {
      continue;
    }
    passages.addAll(
      _passagesFromLines(
        work: work,
        juan: juan,
        lines: lines,
        pattern: pattern,
        availableJuans: availableJuans,
      ),
    );
  }
  return passages;
}

List<ScripturePassage> _passagesFromLines({
  required String work,
  required String juan,
  required List<ScriptureLine> lines,
  required QueryPattern pattern,
  required List<int> availableJuans,
}) {
  final source = normalizeScriptureLines(lines);
  final title = localWorkTitle(lines);
  final display = _CollapsedText.build(source.normed.source);
  final passages = <ScripturePassage>[];
  var recordIndex = 0;
  scanNormMatches(source.normed.bytes, pattern, (match) {
    while (recordIndex + 1 < source.records.length &&
        source.records[recordIndex + 1].byteOffset <= match.byteStart) {
      recordIndex += 1;
    }
    final record = source.records[recordIndex];
    if (record.byteOffset > match.byteStart) return;
    final start = source.normed.sourceStart(match.byteStart);
    final end = source.normed.sourceEnd(match.byteEnd);
    final lineLabel = record.linehead.split('_p').last;
    final window = display.windowFor(start, end);
    final context = display.windowFor(
      _islandStart(source.excluded, start),
      _islandEnd(source.excluded, end, source.normed.source.length),
    );
    passages.add(
      ScripturePassage(
        title: title.isEmpty ? work : title,
        reference: ['卷$juan', if (lineLabel.isNotEmpty) lineLabel].join(' · '),
        text: offlineKwicSnippet(
          display.text,
          window.start,
          window.end,
          from: context.start,
          to: context.end,
        ),
        linehead: record.linehead.isEmpty ? null : record.linehead,
        juan: juan,
        work: work,
        availableJuans: availableJuans,
        sourceOffset: start,
        snippet: source.normed.source.substring(start, end),
      ),
    );
  });
  return passages;
}

/// 命中左側可以取上下文的起點：最後一個「在命中之前結束」的排除區間之末尾。
int _islandStart(List<Int32List> excluded, int start) {
  var left = 0;
  for (final range in excluded) {
    if (range[1] <= start && range[1] > left) left = range[1];
  }
  return left;
}

/// 命中右側可以取上下文的終點：第一個「在命中之後開始」的排除區間之開頭。
int _islandEnd(List<Int32List> excluded, int end, int sourceLength) {
  var right = sourceLength;
  for (final range in excluded) {
    if (range[0] >= end && range[0] < right) right = range[0];
  }
  return right;
}

/// 空白摺疊後的顯示文字，保留「來源位移 → 顯示位移」的對映表。
class _CollapsedText {
  const _CollapsedText(this.source, this.text, this._toDisplay);

  final String source;
  final String text;
  final Int32List _toDisplay;

  factory _CollapsedText.build(String source) {
    final buffer = StringBuffer();
    final map = Int32List(source.length + 1);
    var index = 0;
    while (index < source.length) {
      final start = index;
      if (_isSpace(source, index)) {
        while (index < source.length && _isSpace(source, index)) {
          index += 1;
        }
        buffer.write(' ');
      } else {
        buffer.write(source[index]);
        index += 1;
      }
      for (var filled = start; filled < index; filled++) {
        map[filled] = buffer.length;
      }
    }
    for (var filled = source.length; filled < map.length; filled++) {
      map[filled] = buffer.length;
    }
    return _CollapsedText(source, buffer.toString(), map);
  }

  /// 來源區間 [from, to) 在顯示文字裡的起訖位置（首尾空白不計入）。
  ///
  /// 摺疊後的空白會變成一個空格，摘要若正好從換行處開始就會多以一個空格開頭。
  ({int start, int end}) windowFor(int from, int to) {
    var left = from.clamp(0, source.length);
    var right = to.clamp(left, source.length);
    while (left < right && _isSpace(source, left)) {
      left += 1;
    }
    while (right > left && _isSpace(source, right - 1)) {
      right -= 1;
    }
    if (left >= right) {
      final position = left <= 0 ? 0 : _toDisplay[left - 1];
      return (start: position, end: position);
    }
    return (
      start: left <= 0 ? 0 : _toDisplay[left - 1],
      end: _toDisplay[right - 1],
    );
  }
}

bool _isSpace(String source, int index) =>
    _whitespacePattern.hasMatch(source[index]);

/// 取匹配詞前後的一段文字作為上下文摘要，避免離線結果顯示整段經文。
///
/// [from]／[to] 是上下文可以抵達的邊界（卷題、作譯者與夾注不屬於正文）；
/// 停在邊界上時不加省略號，因為省略號代表的是刪掉的經文，不是結構標記。
String offlineKwicSnippet(
  String text,
  int start,
  int end, {
  int before = 40,
  int after = 80,
  int from = 0,
  int? to,
}) {
  if (text.isEmpty) return text;
  final right = (to ?? text.length).clamp(0, text.length);
  final left = math.min(from.clamp(0, text.length), right);
  final match = math.max(start.clamp(left, right), left);
  final matchEnd = math.max(end.clamp(left, right), match);
  final sliceStart = math.max(match - before, left);
  final sliceEnd = math.min(matchEnd + after, right);
  final buffer = StringBuffer();
  if (sliceStart > left) buffer.write('…');
  buffer.write(text.substring(sliceStart, sliceEnd));
  if (sliceEnd < right) buffer.write('…');
  return buffer.toString();
}

/// 連續掃描的進度快照。
class OfflineScanProgress {
  const OfflineScanProgress({
    this.scannedVolumes = 0,
    this.totalVolumes = 0,
    this.results = const <ScriptureSearchResult>[],
    this.termHits = 0,
    this.scanning = false,
    this.finished = false,
  });

  final int scannedVolumes;
  final int totalVolumes;
  final List<ScriptureSearchResult> results;
  final int termHits;
  final bool scanning;
  final bool finished;

  bool get hasMore => !finished;
}

/// 本地經卷的連續掃描會話。
///
/// 塊大小跟著每幀預算自適應：`.sidx` 就位後一卷只需兩次小讀加一次 BMH，塊會一路
/// 長到千卷級，掃描自己推進到掃完，不需要捲動或按鈕。暫停、換字搜尋或離開頁面時
/// 以 [pause]／[dispose] 中止。
class OfflineScanSession {
  OfflineScanSession(this.query);

  /// 第一塊的卷數；之後依實際耗時倍增或折半。
  static const int volumesPerChunk = 24;
  static const int maxVolumesPerChunk = 2000;
  static const Duration _chunkGap = Duration(milliseconds: 4);
  static const int _batchBudgetMicros = 8000;

  final String query;
  final ValueNotifier<OfflineScanProgress> _progress =
      ValueNotifier<OfflineScanProgress>(const OfflineScanProgress());
  final Map<String, _MergedWork> _merged = {};

  List<ScriptureVolumeRef>? _refs;
  Map<String, List<int>> _juansByWork = const {};
  List<List<int>> _slotCandidates = const [];
  List<ScriptureSearchResult> _results = const [];
  int _cursor = 0;
  int _termHits = 0;
  int _batchVolumes = volumesPerChunk;
  int _generation = 0;
  bool _paused = false;
  bool _scanning = false;
  bool _finished = false;
  bool _disposed = false;

  ValueListenable<OfflineScanProgress> get progress => _progress;
  OfflineScanProgress get current => _progress.value;
  String get needle => query.trim().toLowerCase();
  int get scannedVolumes => _cursor;
  int get totalVolumes => _refs?.length ?? 0;
  bool get finished => _finished;
  bool get scanning => _scanning;

  List<int> juansFor(String work) => _juansByWork[work] ?? const [];

  /// 待展開的命中（第一階段只有定位資訊）。
  List<OfflineHit> pendingHitsFor(String work) =>
      _merged[work]?.hits ?? const [];

  /// 列出本地經卷，按作品與卷號排序；同一會話只列一次。
  Future<void> prepare() async {
    if (_refs != null || _disposed) return;
    _slotCandidates = buildOfflinePattern(
      query,
    ).slots.map((slot) => slot.toList()).toList();
    final refs = await scriptureVolumeStore.listRefs();
    refs.sort((left, right) {
      final byWork = left.work.compareTo(right.work);
      if (byWork != 0) return byWork;
      return _juanNumber(left).compareTo(_juanNumber(right));
    });
    final juans = <String, Set<int>>{};
    for (final ref in refs) {
      final juan = int.tryParse(ref.juan);
      if (juan != null) juans.putIfAbsent(ref.work, () => <int>{}).add(juan);
    }
    if (_disposed) return;
    _juansByWork = {
      for (final entry in juans.entries)
        entry.key: entry.value.toList()..sort(),
    };
    _refs = refs;
    _notify();
  }

  /// 掃描下一塊經卷。回傳 false 表示已沒有更多經卷可掃。
  Future<bool> scanChunk() async {
    final refs = _refs;
    if (_disposed || refs == null) return false;
    if (_cursor >= refs.length) {
      if (!_finished) {
        _finished = true;
        _notify();
      }
      return false;
    }
    if (_slotCandidates.isNotEmpty) {
      final end = math.min(_cursor + _batchVolumes, refs.length);
      final timer = Stopwatch()..start();
      final outcome = await _runBatch(refs.sublist(_cursor, end));
      timer.stop();
      _merge(outcome);
      _adaptBatch(timer.elapsedMicroseconds);
      _cursor = end;
    } else {
      _cursor = refs.length;
    }
    if (_cursor >= refs.length) _finished = true;
    _notify();
    return true;
  }

  Future<OfflineScanOutcome> _runBatch(List<ScriptureVolumeRef> chunk) {
    final request = OfflineScanRequest(
      slotCandidates: _slotCandidates,
      targets: [
        for (final ref in chunk)
          OfflineScanTarget(
            work: ref.work,
            juan: ref.juan,
            path: ref.path ?? '',
          ),
      ],
    );
    final pool =
        offlineScanSupportsIsolate() && (chunk.first.path ?? '').isNotEmpty
        ? sharedOfflineScanPool()
        : null;
    // 只能在主 isolate 掃的場合（网页版、測試、池已被釋放）一定要能中止：
    // 這一塊可能是自適應後的千卷級，會話都 dispose 了還把主執行緒排著。
    bool cancelled() => _disposed;
    if (pool == null) {
      return runOfflineScanInline(request, shouldAbort: cancelled);
    }
    return pool
        .run(request, _workerCount, shouldAbort: cancelled)
        .then(
          (outcome) => outcome,
          onError: (Object _) =>
              runOfflineScanInline(request, shouldAbort: cancelled),
        );
  }

  void _merge(OfflineScanOutcome outcome) {
    _termHits += outcome.termHits;
    for (final group in outcome.groups) {
      _merged
          .putIfAbsent(group.work, () => _MergedWork(group.title))
          .hits
          .addAll(group.hits);
    }
    _rebuildResults();
  }

  /// 第二階段展開完成後，用可讀摘要取代同一部經的待展開命中。
  void applyPassages(String work, List<ScripturePassage> passages) {
    final bucket = _merged[work];
    if (bucket == null) return;
    bucket.passages = passages;
    // 命中清單只追加，所以「已展開的筆數」就是一個前綴；掃描後續新发现的命中
    // 仍然留在 pendingHits 裡，下次展開時補上。
    bucket.expandedHits = bucket.hits.length;
    _rebuildResults();
    _notify();
  }

  void _rebuildResults() {
    _results = [
      for (final entry in _merged.entries)
        ScriptureSearchResult(
          title: '${entry.key} ${entry.value.title}'.trim(),
          description: '離線經文 · 命中 ${entry.value.hits.length} 處',
          passages: entry.value.passages,
          workId: entry.key,
          // 命中清單會隨掃描增長；發布的是同一個清單，避免每塊複製整部經的命中。
          pendingHits: _pendingFor(entry.value),
        ),
    ];
  }

  static List<OfflineHit> _pendingFor(_MergedWork work) {
    final expanded = work.expandedHits;
    if (expanded == 0) return work.hits;
    final rest = work.hits.length - expanded;
    return rest <= 0 ? const [] : work.hits.sublist(expanded);
  }

  /// 塊大小跟隨每幀預算：省下來的掃描時間直接換成更少的塊次數。
  void _adaptBatch(int micros) {
    if (micros < _batchBudgetMicros) {
      _batchVolumes = math.min(maxVolumesPerChunk, _batchVolumes * 2);
    } else if (micros > _batchBudgetMicros * 4) {
      _batchVolumes = math.max(volumesPerChunk, _batchVolumes ~/ 2);
    }
  }

  int get _workerCount => math.min(4, math.max(2, Platform.numberOfProcessors));

  /// 開始（或從暫停中恢復）連續掃描。
  void start() {
    if (_disposed || _scanning || _finished) return;
    _paused = false;
    _scanning = true;
    unawaited(_loop(++_generation));
    _notify();
  }

  /// 暫停掃描；已交出去的這一塊仍會完成，之後不再排下一塊。
  void pause() {
    if (_disposed || _paused) return;
    _paused = true;
    _generation++;
    _scanning = false;
    _notify();
  }

  void resume() => start();

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _scanning = false;
    _progress.dispose();
  }

  Future<void> _loop(int generation) async {
    try {
      await prepare();
      while (!_disposed && _generation == generation && !_paused) {
        if (!await scanChunk()) break;
        await Future<void>.delayed(_chunkGap);
      }
    } catch (_) {
      // 掃描失敗時停在當前進度，使用者仍可對已找到的結果操作。
    } finally {
      if (!_disposed && _generation == generation) {
        _scanning = false;
        _notify();
      }
    }
  }

  void _notify() {
    if (_disposed) return;
    _progress.value = OfflineScanProgress(
      scannedVolumes: _cursor,
      totalVolumes: _refs?.length ?? 0,
      results: _results,
      termHits: _termHits,
      scanning: _scanning,
      finished: _finished,
    );
  }
}

class _MergedWork {
  _MergedWork(this.title);

  final String title;
  final List<OfflineHit> hits = [];
  List<ScripturePassage> passages = const [];
  int expandedHits = 0;
}

const int _commandScan = 1;

OfflineScanPool? _sharedScanPool;

/// 跨搜尋會話重用常駐 worker 池。
///
/// 每次換字／重送搜尋都會 dispose 舊會話並建會話；若池跟著會話生死，
/// 一次點擊要殺四個 isolate 再生四個，重生成本比掃描本身還大。
OfflineScanPool sharedOfflineScanPool() =>
    _sharedScanPool ??= OfflineScanPool();

/// 離開搜尋頁時釋放常駐池；下次搜尋會重新拉起 worker。
void releaseSharedOfflineScanPool() {
  _sharedScanPool?.dispose();
  _sharedScanPool = null;
}

/// 常駐掃描 worker 池。
///
/// `compute` 每一塊都要冷啟動一個 isolate（載入 isolate 組件、首次分配），
/// 全藏兩萬多卷時這筆固定開銷比一卷的掃描還大；池把 worker 留著反覆用，並把
/// 一塊工作切成每 worker 一份並行跑，吞吐接近線性提升。
class OfflineScanPool {
  OfflineScanPool() {
    _replies.listen(_onReply);
  }

  final ReceivePort _replies = ReceivePort();
  final List<_ScanWorker> _workers = [];
  final Map<int, Completer<OfflineScanOutcome>> _pending = {};

  /// 池跨會話共用後可能同時被要求扩容，生成 worker 必須排隊，
  /// 否則兩個並發的 `_ensureWorkers` 會拿到同一個 worker。
  Future<void> _growing = Future<void>.value();
  bool _disposed = false;
  int _nextId = 1;

  /// 把一份請求切成至多 [workerCount] 份並行執行，合併後回傳。
  ///
  /// [shouldAbort] 只用在退回主 isolate 自己掃的場合（池已釋放、份數不足），
  /// 派給 worker 的部分無法被叫停，會話dispose 後那些結果直接丟棄。
  Future<OfflineScanOutcome> run(
    OfflineScanRequest request,
    int workerCount, {
    bool Function()? shouldAbort,
  }) async {
    if (_disposed || request.targets.isEmpty) {
      return runOfflineScanInline(request, shouldAbort: shouldAbort);
    }
    final parts = math.min(
      workerCount,
      math.max(1, request.targets.length ~/ 8),
    );
    if (parts < 2) {
      return runOfflineScanInline(request, shouldAbort: shouldAbort);
    }
    await _ensureWorkers(parts);
    if (_disposed) {
      return runOfflineScanInline(request, shouldAbort: shouldAbort);
    }
    final size = (request.targets.length + parts - 1) ~/ parts;
    final futures = <Future<OfflineScanOutcome>>[];
    for (var part = 0; part < parts; part++) {
      final start = part * size;
      if (start >= request.targets.length) break;
      final end = math.min(start + size, request.targets.length);
      futures.add(
        _dispatch(
          _workers[part],
          OfflineScanRequest(
            slotCandidates: request.slotCandidates,
            targets: request.targets.sublist(start, end),
          ),
        ),
      );
    }
    var termHits = 0;
    var scanned = 0;
    var built = 0;
    final groups = <OfflineWorkGroup>[];
    for (final outcome in await Future.wait(futures)) {
      termHits += outcome.termHits;
      scanned += outcome.scannedVolumes;
      built += outcome.builtIndexes;
      groups.addAll(outcome.groups);
    }
    return OfflineScanOutcome(
      groups: _mergeGroups(groups),
      termHits: termHits,
      scannedVolumes: scanned,
      builtIndexes: built,
    );
  }

  Future<OfflineScanOutcome> _dispatch(
    _ScanWorker worker,
    OfflineScanRequest request,
  ) {
    final id = _nextId++;
    final completer = Completer<OfflineScanOutcome>();
    _pending[id] = completer;
    worker.commandPort.send(<Object?>[
      _commandScan,
      _replies.sendPort,
      id,
      request,
    ]);
    return completer.future.timeout(
      const Duration(seconds: 120),
      onTimeout: () {
        _pending.remove(id);
        return OfflineScanOutcome.empty;
      },
    );
  }

  void _onReply(dynamic message) {
    if (message is! List || message.length != 2) return;
    final completer = _pending.remove(message[0]);
    if (completer == null || completer.isCompleted) return;
    completer.complete(message[1] as OfflineScanOutcome);
  }

  Future<void> _ensureWorkers(int count) {
    final next = _growing.then((_) => _growTo(count));
    _growing = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  Future<void> _growTo(int count) async {
    while (_workers.length < count && !_disposed) {
      final worker = await _ScanWorker.spawn();
      if (_disposed) {
        worker.dispose();
        return;
      }
      _workers.add(worker);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final worker in _workers) {
      worker.dispose();
    }
    _workers.clear();
    _replies.close();
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.complete(OfflineScanOutcome.empty);
    }
    _pending.clear();
  }
}

List<OfflineWorkGroup> _mergeGroups(List<OfflineWorkGroup> groups) {
  final order = <String>[];
  final merged = <String, List<OfflineHit>>{};
  final titles = <String, String>{};
  for (final group in groups) {
    if (!merged.containsKey(group.work)) {
      order.add(group.work);
      merged[group.work] = <OfflineHit>[];
      titles[group.work] = group.title;
    }
    merged[group.work]!.addAll(group.hits);
  }
  return [
    for (final work in order)
      OfflineWorkGroup(work: work, title: titles[work]!, hits: merged[work]!),
  ];
}

class _ScanWorker {
  _ScanWorker(this.commandPort, this._isolate);

  final SendPort commandPort;
  final Isolate _isolate;

  static Future<_ScanWorker> spawn() async {
    final handshake = ReceivePort();
    final completer = Completer<SendPort>();
    handshake.listen((dynamic message) {
      completer.complete(message as SendPort);
      handshake.close();
    });
    final isolate = await Isolate.spawn<SendPort>(
      _workerEntry,
      handshake.sendPort,
      debugName: 'cbeta-offline-scan',
    );
    return _ScanWorker(await completer.future, isolate);
  }

  void dispose() {
    try {
      _isolate.kill(priority: Isolate.immediate);
    } catch (_) {
      // 已經自己死掉的 worker 不需要再殺。
    }
  }
}

void _workerEntry(SendPort control) {
  final port = RawReceivePort();
  control.send(port.sendPort);
  port.handler = (dynamic message) {
    if (message is! List || message.length != 4 || message[0] != _commandScan) {
      return;
    }
    final reply = message[1] as SendPort;
    final id = message[2] as int;
    final request = message[3] as OfflineScanRequest;
    unawaited(
      runOfflineScan(request).then(
        (outcome) => reply.send(<Object?>[id, outcome]),
        onError: (Object _, StackTrace _) =>
            reply.send(<Object?>[id, OfflineScanOutcome.empty]),
      ),
    );
  };
}

int _juanNumber(ScriptureVolumeRef ref) => int.tryParse(ref.juan) ?? 0;
