import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show ValueListenable, ValueNotifier, compute, kIsWeb;

import 'cache.dart';
import 'models.dart';
import 'parser.dart';

final _whitespacePattern = RegExp(r'\s+');
final _volumeTitleTailPattern = RegExp(r'卷[第]?[〇零一二三四五六七八九十百千兩0-9]+$');

/// 一卷離線經文的定位資訊;`path` 为空時只能由主 isolate 透過 store 讀取。
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

/// 交付掃描的一份工作:關鍵字、經卷清單,以及各部作品已下載的卷號。
class OfflineScanRequest {
  const OfflineScanRequest({
    required this.needle,
    required this.targets,
    required this.juansByWork,
  });

  final String needle;
  final List<OfflineScanTarget> targets;
  final Map<String, List<int>> juansByWork;
}

class OfflineScanOutcome {
  const OfflineScanOutcome({required this.results, required this.termHits});

  final List<ScriptureSearchResult> results;
  final int termHits;
}

/// 是否可以交給背景 isolate。
///
/// `flutter test` 的 fake-async 綁定不會推進真實 isolate 的回覆,因此測試
/// 與網頁版一律走同一份同步實作,只少了 isolate 的跳板。
bool offlineScanSupportsIsolate() =>
    !kIsWeb && !Platform.environment.containsKey('FLUTTER_TEST');

/// 掃描一批經卷。背景 isolate 内完成讀檔、JSON 解碼、HTML 解析與匹配,
/// UI isolate 只負責送出與接收,因此連續掃描不會擠掉任何一幀。
Future<OfflineScanOutcome> runOfflineScan(OfflineScanRequest request) {
  if (!offlineScanSupportsIsolate()) return _scanOfflineChunk(request);
  return compute(_scanOfflineChunk, request);
}

Future<OfflineScanOutcome> _scanOfflineChunk(OfflineScanRequest request) async {
  final needle = request.needle;
  if (needle.isEmpty) {
    return const OfflineScanOutcome(results: [], termHits: 0);
  }
  final results = <ScriptureSearchResult>[];
  var termHits = 0;
  for (final target in request.targets) {
    final lines = await _readVolumeLines(target);
    if (lines == null) continue;
    final outcome = _scanVolumeLines(
      target: target,
      lines: lines,
      needle: needle,
      juansByWork: request.juansByWork,
    );
    results.addAll(outcome.results);
    termHits += outcome.termHits;
  }
  return OfflineScanOutcome(results: results, termHits: termHits);
}

/// 經卷沒有可用檔案路徑時（網頁版存在 SharedPreferences）只能由主 isolate
/// 讀取，再由同一份匹配邏輯产出結果。
Future<OfflineScanOutcome> scanOfflineVolume(
  OfflineScanTarget target,
  String needle,
  Map<String, List<int>> juansByWork,
) async {
  if (needle.isEmpty) return const OfflineScanOutcome(results: [], termHits: 0);
  final volume = await scriptureVolumeStore.readRef(
    ScriptureVolumeRef(work: target.work, juan: target.juan),
  );
  if (volume == null) return const OfflineScanOutcome(results: [], termHits: 0);
  final lines = _parseVolumeLines(volume);
  if (lines == null) return const OfflineScanOutcome(results: [], termHits: 0);
  return _scanVolumeLines(
    target: target,
    lines: lines,
    needle: needle,
    juansByWork: juansByWork,
  );
}

List<ScriptureLine>? _parseVolumeLines(CachedScriptureVolume volume) {
  try {
    return parseScriptureHtml(volume.html);
  } catch (_) {
    return null;
  }
}

OfflineScanOutcome _scanVolumeLines({
  required OfflineScanTarget target,
  required List<ScriptureLine> lines,
  required String needle,
  required Map<String, List<int>> juansByWork,
}) {
  final title = localWorkTitle(lines);
  final juans = juansByWork[target.work] ?? const <int>[];
  final passages = <ScripturePassage>[];
  var termHits = 0;
  for (final line in lines) {
    if (line.role == ScriptureLineRole.volumeTitle ||
        line.role == ScriptureLineRole.byline) {
      continue;
    }
    final text = line.text.replaceAll(_whitespacePattern, ' ').trim();
    if (text.isEmpty) continue;
    final lower = text.toLowerCase();
    if (!lower.contains(needle)) continue;
    termHits += _countOccurrences(lower, needle);
    final linehead = line.linehead;
    final lineLabel = linehead == null ? '' : linehead.split('_p').last;
    passages.add(
      ScripturePassage(
        title: title.isEmpty ? target.work : title,
        reference: [
          '卷${target.juan}',
          if (lineLabel.isNotEmpty) lineLabel,
        ].join(' · '),
        text: offlineKwicSnippet(text, needle),
        linehead: linehead,
        juan: target.juan,
        work: target.work,
        availableJuans: juans,
      ),
    );
  }
  if (passages.isEmpty) {
    return const OfflineScanOutcome(results: [], termHits: 0);
  }
  return OfflineScanOutcome(
    results: [
      ScriptureSearchResult(
        title: '${target.work} ${title.isEmpty ? '（離線經文）' : title}'.trim(),
        description: '離線經文 · 命中 ${passages.length} 處',
        passages: passages,
      ),
    ],
    termHits: termHits,
  );
}

Future<List<ScriptureLine>?> _readVolumeLines(OfflineScanTarget target) async {
  if (target.path.isEmpty) return null;
  try {
    final file = File(target.path);
    if (!await file.exists()) return null;
    final volume = CachedScriptureVolume.fromJson(
      jsonDecode(await file.readAsString()) as Map<String, dynamic>,
    );
    if (volume.work != target.work || volume.juan != target.juan) return null;
    return parseScriptureHtml(volume.html);
  } catch (_) {
    return null;
  }
}

int _countOccurrences(String haystack, String needle) {
  if (needle.isEmpty) return 0;
  var count = 0;
  var index = haystack.indexOf(needle);
  while (index >= 0) {
    count += 1;
    index = haystack.indexOf(needle, index + needle.length);
  }
  return count;
}

/// 取匹配詞前後的一段文字作為上下文摘要，避免離線結果顯示整段經文。
String offlineKwicSnippet(
  String text,
  String needle, {
  int before = 40,
  int after = 80,
}) {
  if (needle.isEmpty) return text;
  final match = text.toLowerCase().indexOf(needle);
  if (match < 0) return text;
  final start = (match - before).clamp(0, text.length);
  final end = math.min(match + needle.length + after, text.length);
  final buffer = StringBuffer();
  if (start > 0) buffer.write('…');
  buffer.write(text.substring(start, end));
  if (end < text.length) buffer.write('…');
  return buffer.toString();
}

({String title, String byline}) localVolumeInfo(List<ScriptureLine> lines) {
  String pick(ScriptureLineRole role) => lines
      .firstWhere(
        (line) => line.role == role && line.text.trim().isNotEmpty,
        orElse: () => const ScriptureLine(text: ''),
      )
      .text
      .trim();
  return (
    title: pick(ScriptureLineRole.volumeTitle),
    byline: pick(ScriptureLineRole.byline),
  );
}

String localWorkTitle(List<ScriptureLine> lines) {
  final title = localVolumeInfo(lines).title;
  final stripped = title.replaceFirst(_volumeTitleTailPattern, '').trim();
  return stripped.isEmpty ? title : stripped;
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
/// 一次只交出一小塊經卷給背景 isolate，掃描本身不佔用 UI isolate，因此
/// [start] 之後會自行推進到掃完全部經卷，不需要使用者捲動或按按鈕觸發。
/// 暫停、換字搜尋或離開頁面時以 [pause]／[dispose] 中止。
class OfflineScanSession {
  OfflineScanSession(this.query);

  static const int volumesPerChunk = 10;
  static const Duration _chunkGap = Duration(milliseconds: 12);

  final String query;
  final List<ScriptureSearchResult> _results = [];
  final ValueNotifier<OfflineScanProgress> _progress =
      ValueNotifier<OfflineScanProgress>(const OfflineScanProgress());

  List<ScriptureVolumeRef>? _refs;
  Map<String, List<int>> _juansByWork = const {};
  int _cursor = 0;
  int _termHits = 0;
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

  /// 列出本地經卷，按作品與卷號排序；同一會話只列一次。
  Future<void> prepare() async {
    if (_refs != null || _disposed) return;
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
    final end = math.min(_cursor + volumesPerChunk, refs.length);
    final needle = this.needle;
    if (needle.isNotEmpty) {
      final chunk = refs.sublist(_cursor, end);
      final fromFiles = chunk
          .where((ref) => (ref.path ?? '').isNotEmpty)
          .map(
            (ref) => OfflineScanTarget(
              work: ref.work,
              juan: ref.juan,
              path: ref.path!,
            ),
          )
          .toList();
      if (fromFiles.isNotEmpty) {
        final outcome = await runOfflineScan(
          OfflineScanRequest(
            needle: needle,
            targets: fromFiles,
            juansByWork: _juansByWork,
          ),
        );
        _results.addAll(outcome.results);
        _termHits += outcome.termHits;
      }
      // 網頁版的經卷存在 SharedPreferences，只能由主 isolate 逐卷讀。
      for (final ref in chunk.where((ref) => (ref.path ?? '').isEmpty)) {
        final outcome = await scanOfflineVolume(
          OfflineScanTarget(work: ref.work, juan: ref.juan, path: ''),
          needle,
          _juansByWork,
        );
        _results.addAll(outcome.results);
        _termHits += outcome.termHits;
      }
    }
    _cursor = end;
    if (_cursor >= refs.length) _finished = true;
    _notify();
    return true;
  }

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
      results: List<ScriptureSearchResult>.of(_results),
      termHits: _termHits,
      scanning: _scanning,
      finished: _finished,
    );
  }
}

int _juanNumber(ScriptureVolumeRef ref) => int.tryParse(ref.juan) ?? 0;
