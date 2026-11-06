import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show ValueListenable, ValueNotifier, kIsWeb, visibleForTesting;

import '../search/conversion.dart';
import 'cache.dart';
import 'models.dart';
import 'parser.dart';
import 'sidx_norm.dart';
import 'sidx_segment.dart';
import 'sidx_store.dart';

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
    this.hitCount = 0,
  });

  final String work;
  final String title;

  /// 第一階段每卷只留一筆（展開只需卷號），總出現次數放在 [hitCount]。
  final List<OfflineHit> hits;
  final int hitCount;
}

class OfflineScanOutcome {
  const OfflineScanOutcome({
    required this.groups,
    required this.termHits,
    required this.scannedVolumes,
    this.builtIndexes = 0,
    this.missingIndexes = 0,
  });

  final List<OfflineWorkGroup> groups;
  final int termHits;
  final int scannedVolumes;

  /// 本批中現場從 HTML 建出 `.sidx` 的卷數；首輪掃描後會一路降到 0。
  final int builtIndexes;

  /// 掃完仍沒有可信索引的卷數（重建失敗／拿不到段鎖）。大於 0 時不能
  /// 把「經卷世代」記成已驗證。
  final int missingIndexes;

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
/// [offlineScanIsolateOverride] 讓測試能強制走真的 worker 池。
bool offlineScanSupportsIsolate() =>
    offlineScanIsolateOverride ??
    (!kIsWeb && !Platform.environment.containsKey('FLUTTER_TEST'));

@visibleForTesting
bool? offlineScanIsolateOverride;

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
  bool blockingIo = false,
}) async {
  final pattern = QueryPattern.fromSlotCandidates(request.slotCandidates);
  if (pattern.isBlank || request.targets.isEmpty) {
    return OfflineScanOutcome.empty;
  }
  final segmentStore = _segmentStoreFor(
    request.targets,
    blockingIo: blockingIo,
  );
  final legacyStore = _indexStoreFor(request.targets);
  final targets = request.targets;
  final hitsByTarget = List<List<OfflineHit>?>.filled(targets.length, null);
  final hitCountsByTarget = List<int>.filled(targets.length, 0);
  final titlesByTarget = List<String?>.filled(targets.length, null);
  var termHits = 0;
  var built = 0;
  var scanned = 0;
  var missing = 0;

  // 上次完整掃描若驗證過「經卷世代」，且之後沒有任何寫入，索引戳記就
  // 一定還是新鮮的，可以省掉每卷一次 stat。
  final volumesDirectory = _volumesDirectoryFor(targets);
  var trustStamps = false;
  if (volumesDirectory != null) {
    final generation = blockingIo
        ? readVolumesGenerationSync(volumesDirectory)
        : await readVolumesGeneration(volumesDirectory);
    final marker = await segmentStore.readVolumesGenerationMarker();
    trustStamps = marker != null && marker == generation;
  }

  outer:
  for (final group in _groupTargetIndexesBySegment(targets)) {
    SidxSegmentReader? reader;
    SidxSegmentWriter? writer;
    SidxSegmentMeta? meta;
    try {
      if (group.hasPaths) {
        meta = await segmentStore.readMeta(group.segmentId);
        if (meta != null) {
          reader ??= await segmentStore.openReader(group.segmentId);
          // 字集判定過了、且不在記憶體裡的卷才值得先讀；同段夠密時一次區塊讀
          // 取代逐卷兩萬次小讀。戳記在迴圈裡仍會再驗一次，這裡多讀到過期卷
          // 只是浪費，不會用錯資料。
          await reader?.prefetchVolumes([
            for (final index in group.indexes)
              ?_prefetchEntry(meta, targets[index], pattern.slots),
          ]);
        }
      }
      for (final index in group.indexes) {
        if (yieldBetweenVolumes) {
          await Future<void>.delayed(Duration.zero);
          if (shouldAbort != null && shouldAbort()) break outer;
        }
        final target = targets[index];
        final entry = target.path.isEmpty
            ? null
            : meta?.entryFor(target.work, target.juan);
        final int stamp;
        if (target.path.isEmpty) {
          stamp = 0;
        } else if (trustStamps && entry != null) {
          stamp = entry.sourceStamp;
        } else {
          stamp =
              (blockingIo
                  ? sidxSourceStampSync(target.path)
                  : await sidxSourceStamp(target.path)) ??
              0;
        }
        // 這一卷在掃完後是否有「戳記相符的索引」；沒有的話本輪不能把世代
        // 記成已驗證，否則下一輪會誤信過期索引。
        var indexed = target.path.isEmpty;
        SidxSearchVolume? volume;
        SidxVolume? persistable;
        var fromLegacy = false;
        if (entry != null && entry.sourceStamp == stamp) {
          indexed = true;
          if (entry.canSkipSlots(pattern.slots)) {
            scanned++;
            continue;
          }
          reader ??= await segmentStore.openReader(group.segmentId);
          volume = await reader?.readVolume(entry);
        }
        if (volume == null) {
          if (target.path.isNotEmpty) {
            // 舊版一卷一檔的索引先拿來用，省掉一次 HTML 解析；成功寫進段後
            // 再刪除，讓升級不必重掃整藏。
            persistable = await legacyStore.readAt(
              work: target.work,
              juan: target.juan,
              sourceStamp: stamp,
            );
            fromLegacy = persistable != null;
            volume = persistable;
          }
          if (volume == null) {
            final lines = await _readVolumeLines(
              target,
              blockingIo: blockingIo,
            );
            if (lines == null) {
              missing += 1;
              scanned++;
              continue;
            }
            persistable = buildSidxVolume(
              work: target.work,
              juan: target.juan,
              sourceStamp: stamp,
              lines: lines.lines,
            );
            volume = persistable;
            built += 1;
          }
          if (target.path.isNotEmpty && persistable != null) {
            // 拿不到段鎖就只在記憶體裡用這份索引，下次掃描再補寫；
            // 掃描不該為了等另一趟建置而停住。
            writer ??= await segmentStore.beginWrite(
              group.segmentId,
              timeout: const Duration(milliseconds: 100),
            );
            final newEntry = await writer?.append(persistable);
            if (newEntry != null) {
              indexed = true;
              meta ??= SidxSegmentMeta(group.segmentId);
              meta.add(newEntry);
              if (fromLegacy) {
                unawaited(
                  legacyStore.deleteAt(work: target.work, juan: target.juan),
                );
              }
            }
          }
        }
        if (!indexed) missing += 1;
        scanned++;
        final loaded = volume;
        // 第一階段只需要「這一卷有沒有命中、有幾處」；行號留第一處即可，
        // 展開摘要時會用 HTML 重新定位。常用字每卷幾十處，逐處配置命中
        // 會讓全藏掃描產生上百萬個物件。
        var matches = 0;
        var linehead = '';
        scanNormMatches(loaded.bytes, pattern, (match) {
          if (matches == 0) {
            linehead = loaded.lineheadAt(match.byteStart) ?? '';
          }
          matches += 1;
        });
        if (matches == 0) continue;
        termHits += matches;
        hitCountsByTarget[index] = matches;
        hitsByTarget[index] = [
          OfflineHit(juan: loaded.juan, linehead: linehead),
        ];
        titlesByTarget[index] = loaded.title;
      }
    } finally {
      await writer?.close();
      // 讀取器由 segment store 跨塊重用，這裡不能關；清索引時才統一關閉。
    }
  }

  final merged = <String, List<OfflineHit>>{};
  final mergedCounts = <String, int>{};
  final titles = <String, String>{};
  for (var index = 0; index < targets.length; index++) {
    final hits = hitsByTarget[index];
    if (hits == null || hits.isEmpty) continue;
    final work = targets[index].work;
    merged.putIfAbsent(work, () => <OfflineHit>[]).addAll(hits);
    mergedCounts[work] = (mergedCounts[work] ?? 0) + hitCountsByTarget[index];
    titles.putIfAbsent(work, () => titlesByTarget[index] ?? work);
  }
  return OfflineScanOutcome(
    groups: [
      for (final entry in merged.entries)
        OfflineWorkGroup(
          work: entry.key,
          title: titles[entry.key] ?? entry.key,
          hits: entry.value,
          hitCount: mergedCounts[entry.key] ?? entry.value.length,
        ),
    ],
    termHits: termHits,
    scannedVolumes: scanned,
    builtIndexes: built,
    missingIndexes: missing,
  );
}

Directory? _volumesDirectoryFor(List<OfflineScanTarget> targets) {
  for (final target in targets) {
    if (target.path.isNotEmpty) return File(target.path).parent;
  }
  return null;
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

/// 掃描時按段分組：同一段只讀一次 meta、只開一次 blob 檔。
///
/// 段號只由作品決定，所以同一部經的卷不會被拆開；請求內的卷序也維持不變。
class _TargetGroup {
  _TargetGroup(this.segmentId);

  final int segmentId;
  final List<int> indexes = [];
  bool hasPaths = false;
}

List<_TargetGroup> _groupTargetIndexesBySegment(
  List<OfflineScanTarget> targets,
) {
  final groups = <int, _TargetGroup>{};
  for (var index = 0; index < targets.length; index++) {
    final target = targets[index];
    final segmentId = sidxSegmentId(target.work);
    final group = groups.putIfAbsent(segmentId, () => _TargetGroup(segmentId));
    group.indexes.add(index);
    if (target.path.isNotEmpty) group.hasPaths = true;
  }
  return groups.values.toList();
}

/// 段內值得預讀的卷：字集判定確定不可能命中的卷不讀。
SidxSegmentEntry? _prefetchEntry(
  SidxSegmentMeta meta,
  OfflineScanTarget target,
  List<Int32List> slots,
) {
  final entry = meta.entryFor(target.work, target.juan);
  return entry == null || entry.canSkipSlots(slots) ? null : entry;
}

/// 段檔目錄與經卷目錄同層；worker 裡沒有 path_provider，只能由路徑反推。
SidxSegmentStore _segmentStoreFor(
  List<OfflineScanTarget> targets, {
  bool blockingIo = false,
}) {
  for (final target in targets) {
    if (target.path.isEmpty) continue;
    final cacheDirectory = File(target.path).parent.parent;
    return SidxSegmentStore(
      directoryProvider: () async => cacheDirectory,
      blockingIo: blockingIo,
    );
  }
  return scriptureSidxSegmentStore;
}

class _VolumeLines {
  const _VolumeLines(this.lines);

  final List<ScriptureLine> lines;
}

Future<_VolumeLines?> _readVolumeLines(
  OfflineScanTarget target, {
  bool blockingIo = false,
}) async {
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
      if (blockingIo) {
        if (!file.existsSync()) return null;
      } else if (!await file.exists()) {
        return null;
      }
      final stored = blockingIo
          ? file.readAsStringSync()
          : await file.readAsString();
      final decoded = CachedScriptureVolume.fromJson(
        jsonDecode(stored) as Map<String, dynamic>,
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

/// 一批待建索引的經卷。
class OfflineIndexBuildRequest {
  const OfflineIndexBuildRequest({required this.targets});

  final List<OfflineScanTarget> targets;
}

/// 只做「讀 `.json` → 寫 `.sidx`」，不比對任何查詢。
///
/// 下載時就把索引前置好，使用者第一次搜只剩讀標頭與正文，不必再整藏解析一次
/// HTML。戳記相符的卷直接跳過，重跑一次同一批是無害的。
Future<int> buildOfflineIndexBatch(
  List<OfflineScanTarget> targets, {
  bool blockingIo = false,
}) async {
  if (targets.isEmpty) return 0;
  final segmentStore = _segmentStoreFor(targets, blockingIo: blockingIo);
  final legacyStore = _indexStoreFor(targets);
  var built = 0;
  for (final group in _groupTargetIndexesBySegment(targets)) {
    if (!group.hasPaths) continue;
    // 建置與掃描共用同一把段鎖；批次內同段只開一次檔案、一次寫完 meta。
    final writer = await segmentStore.beginWrite(group.segmentId);
    if (writer == null) continue;
    try {
      final meta =
          await segmentStore.readMeta(group.segmentId) ??
          SidxSegmentMeta(group.segmentId);
      for (final index in group.indexes) {
        final target = targets[index];
        if (target.path.isEmpty) continue;
        final stamp =
            (blockingIo
                ? sidxSourceStampSync(target.path)
                : await sidxSourceStamp(target.path)) ??
            0;
        final existing = meta.entryFor(target.work, target.juan);
        if (existing != null && existing.sourceStamp == stamp) continue;
        var volume = await legacyStore.readAt(
          work: target.work,
          juan: target.juan,
          sourceStamp: stamp,
        );
        final fromLegacy = volume != null;
        if (volume == null) {
          final lines = await _readVolumeLines(target, blockingIo: blockingIo);
          if (lines == null) continue;
          volume = buildSidxVolume(
            work: target.work,
            juan: target.juan,
            sourceStamp: stamp,
            lines: lines.lines,
          );
        }
        final entry = await writer.append(volume);
        if (entry == null) continue;
        meta.add(entry);
        built += 1;
        if (fromLegacy) {
          unawaited(legacyStore.deleteAt(work: target.work, juan: target.juan));
        }
      }
    } finally {
      await writer.close();
    }
  }
  return built;
}

/// 下載期間的索引工作佇列。
///
/// 一次派一卷會把常駐池打成數萬則訊息，所以累積到一批再交出去；下載本身在等
/// 網路，建索引在背景 worker 裡慢慢追。
class OfflineIndexQueue {
  static const int _batchSize = 32;

  /// 並行中的批次上限；下載快過建置時用它回壓，別把記憶體堆滿待辦。
  static const int _maxInFlight = 4;

  final List<OfflineScanTarget> _pending = [];
  final List<Future<void>> _inFlight = [];

  Future<void> add(String work, String juan, String path) async {
    if (kIsWeb || path.isEmpty) return;
    _pending.add(OfflineScanTarget(work: work, juan: juan, path: path));
    if (_pending.length < _batchSize) return;
    if (_inFlight.length >= _maxInFlight) {
      await Future.wait(List<Future<void>>.of(_inFlight));
    }
    drain();
  }

  /// 把待辦交出去（下載結束、取消或換任務時呼叫）。
  Future<void> flush() async {
    drain();
    while (_inFlight.isNotEmpty) {
      await Future.wait(List<Future<void>>.of(_inFlight));
    }
  }

  void drain() {
    if (_pending.isEmpty) return;
    final batch = List<OfflineScanTarget>.of(_pending);
    _pending.clear();
    final future = _runBatch(batch);
    _inFlight.add(future);
    unawaited(future.whenComplete(() => _inFlight.remove(future)));
  }

  List<OfflineScanTarget> get pendingTargets => List.unmodifiable(_pending);

  Future<void> _runBatch(List<OfflineScanTarget> batch) async {
    final pool = offlineScanSupportsIsolate() && batch.first.path.isNotEmpty
        ? sharedOfflineScanPool()
        : null;
    if (pool == null) {
      await buildOfflineIndexBatch(batch);
      return;
    }
    await pool.runBuild(
      OfflineIndexBuildRequest(targets: batch),
      _defaultWorkerCount(),
    );
  }
}

/// 下載流程共用的索引佇列。
final OfflineIndexQueue offlineIndexQueue = OfflineIndexQueue();

int _defaultWorkerCount() =>
    math.min(4, math.max(2, Platform.numberOfProcessors));

/// 第二階段：把一部經的離線命中展開成可讀摘要。
///
/// 索引正文刪掉了標點，不能直接給人看；點開一部經時用 HTML 重新比對一次
/// （實測約 4 ms/卷），摘要、行號與 `sourceOffset` 都取自帶標點的原文。
///
/// 解析整卷 HTML 是 CPU 活，正常路徑把它派給常駐池的 worker；網頁版、測試或池
/// 已釋放時才退回主 isolate 一卷一卷做，那種場合卷與卷之間讓出一幀，並用
/// [shouldAbort] 在離開頁面或換了搜尋後停手。
Future<List<ScripturePassage>> expandOfflineWork({
  required String work,
  required List<OfflineHit> hits,
  required String query,
  List<int> availableJuans = const [],
  bool Function()? shouldAbort,
}) async {
  if (hits.isEmpty) return const [];
  if (shouldAbort != null && shouldAbort()) return const [];
  final pattern = buildOfflinePattern(query);
  if (pattern.isBlank) return const [];
  final juans = (hits.map((hit) => hit.juan).toSet().toList())..sort();
  // 網頁版的卷存在 SharedPreferences，沒有檔案戳記可依賴；其餘情況先取檔案
  // 路徑，展開快取與 worker 池都靠它認出「同一卷還沒變」。
  final targets = [
    for (final juan in juans)
      OfflineScanTarget(
        work: work,
        juan: juan,
        path: kIsWeb ? '' : await _volumePath(work, juan),
      ),
  ];
  final request = OfflineExpandRequest(
    work: work,
    slotCandidates: [for (final slot in pattern.slots) slot.toList()],
    targets: targets,
    availableJuans: availableJuans,
  );
  final pool = offlineScanSupportsIsolate() && targets.first.path.isNotEmpty
      ? sharedOfflineScanPool()
      : null;
  if (pool == null) {
    return runOfflineExpandInline(request, shouldAbort: shouldAbort);
  }
  final passages = await pool.runExpand(request, _defaultWorkerCount());
  // 叫停時丟棄已经回來的結果：展開的代價只花在還活著的搜尋上。
  if (shouldAbort != null && shouldAbort()) return const [];
  return passages;
}

/// 展開用的請求：一部經、要看哪幾卷，以及已由 UI 正規化的查詢候補。
class OfflineExpandRequest {
  const OfflineExpandRequest({
    required this.work,
    required this.slotCandidates,
    required this.targets,
    required this.availableJuans,
  });

  final String work;
  final List<List<int>> slotCandidates;
  final List<OfflineScanTarget> targets;
  final List<int> availableJuans;
}

Future<List<ScripturePassage>> runOfflineExpand(OfflineExpandRequest request) =>
    _runOfflineExpand(request, yieldBetweenVolumes: false);

Future<List<ScripturePassage>> runOfflineExpandInline(
  OfflineExpandRequest request, {
  bool Function()? shouldAbort,
}) => _runOfflineExpand(
  request,
  yieldBetweenVolumes: true,
  shouldAbort: shouldAbort,
);

Future<List<ScripturePassage>> _runOfflineExpand(
  OfflineExpandRequest request, {
  required bool yieldBetweenVolumes,
  bool Function()? shouldAbort,
}) async {
  final pattern = QueryPattern.fromSlotCandidates(request.slotCandidates);
  if (pattern.isBlank || request.targets.isEmpty) return const [];
  final passages = <ScripturePassage>[];
  for (final target in request.targets) {
    if (shouldAbort != null && shouldAbort()) break;
    final volume = await _expandedVolume(target);
    if (yieldBetweenVolumes) {
      await Future<void>.delayed(Duration.zero);
      if (shouldAbort != null && shouldAbort()) break;
    }
    if (volume == null) continue;
    passages.addAll(
      _passagesFromExpanded(
        work: request.work,
        juan: target.juan,
        volume: volume,
        pattern: pattern,
        availableJuans: request.availableJuans,
      ),
    );
  }
  // 一部經的卷被切成好幾份並行跑，合併後要還原成「卷號、卷內位置」的閱讀順序，
  // 否則點開某一筆時跳到的不是畫面上那一筆。
  passages.sort(_comparePassages);
  return passages;
}

int _comparePassages(ScripturePassage left, ScripturePassage right) {
  final byJuan = (int.tryParse(left.juan ?? '') ?? 0).compareTo(
    int.tryParse(right.juan ?? '') ?? 0,
  );
  if (byJuan != 0) return byJuan;
  return (left.sourceOffset ?? 0).compareTo(right.sourceOffset ?? 0);
}

Future<String> _volumePath(String work, String juan) async {
  if (kIsWeb) return '';
  try {
    return await scriptureVolumeStore.pathFor(work, juan);
  } catch (_) {
    // 識別碼不合法時照舊走 store 讀；讀不到就是沒有這一卷。
    return '';
  }
}

/// 展開一整卷要付的錢：解析 HTML、正規化、以及「來源位移 → 顯示位移」表。
///
/// 換了關鍵字重開同一部經、或掃描又補來幾筆命中時都要再展開一次，差異只在比對
/// 哪個字，整卷解析屬白重複。以來源檔的戳記為 key，經卷改版時自然失效。
class _ExpandedVolume {
  _ExpandedVolume({
    required this.stamp,
    required this.source,
    required this.display,
  });

  final int stamp;
  final SidxSource source;
  final _CollapsedText display;
}

final LinkedHashMap<String, _ExpandedVolume> _expandedVolumes = LinkedHashMap();
const int _expandedVolumeCacheLimit = 24;

Future<_ExpandedVolume?> _expandedVolume(OfflineScanTarget target) async {
  final path = target.path;
  if (path.isEmpty) {
    // 網頁版沒有檔案戳記可依賴，每次照原樣重讀重解析。
    final lines = await _readVolumeLines(target);
    if (lines == null) return null;
    return _expandToVolume(0, lines.lines);
  }
  final stamp = await sidxSourceStamp(path) ?? 0;
  final cached = _expandedVolumes[path];
  if (cached != null && cached.stamp == stamp) {
    _expandedVolumes.remove(path);
    _expandedVolumes[path] = cached;
    return cached;
  }
  _expandedVolumes.remove(path);
  final lines = await _readVolumeLines(target);
  if (lines == null) return null;
  final volume = _expandToVolume(stamp, lines.lines);
  _expandedVolumes[path] = volume;
  while (_expandedVolumes.length > _expandedVolumeCacheLimit) {
    _expandedVolumes.remove(_expandedVolumes.keys.first);
  }
  return volume;
}

_ExpandedVolume _expandToVolume(int stamp, List<ScriptureLine> lines) {
  final source = normalizeScriptureLines(lines);
  return _ExpandedVolume(
    stamp: stamp,
    source: source,
    display: _CollapsedText.build(source.normed.source),
  );
}

List<ScripturePassage> _passagesFromExpanded({
  required String work,
  required String juan,
  required _ExpandedVolume volume,
  required QueryPattern pattern,
  required List<int> availableJuans,
}) {
  final source = volume.source;
  final display = volume.display;
  final title = source.title;
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
  ///
  /// 主 isolate 兜底掃描要維持一幀的量級；常駐池在背景跑，塊太小只會讓
  /// 每塊的派工與結果合併開銷占比變高，所以直接從 512 起步。
  static const int volumesPerChunk = 24;
  static const int _poolVolumesPerChunk = 512;
  static const int maxVolumesPerChunk = 2000;
  static const Duration _chunkGap = Duration(milliseconds: 4);

  /// 一塊的目標耗時；比這快就翻倍，慢過四倍就折半。
  /// 段清單與讀取句柄會跨塊重用，塊太小反而讓每塊的派工開銷占比變高。
  static const int _batchBudgetMicros = 16000;
  static const int _poolBatchBudgetMicros = 150000;

  final String query;
  final ValueNotifier<OfflineScanProgress> _progress =
      ValueNotifier<OfflineScanProgress>(const OfflineScanProgress());
  final Map<String, _MergedWork> _merged = {};

  /// 每塊都重建結果要重排兩萬部經、配置兩萬個結果物件；畫面本來就每
  /// 300 ms 才發布一次，這裡再限流一次，掃描期間只保留少數幾次重建。
  final Stopwatch _rebuildClock = Stopwatch()..start();
  static const int _rebuildIntervalMicros = 120000;

  List<ScriptureVolumeRef>? _refs;
  Map<String, List<int>> _juansByWork = const {};
  List<List<int>> _slotCandidates = const [];
  List<ScriptureSearchResult> _results = const [];
  int _cursor = 0;
  int _termHits = 0;
  int _batchVolumes = 0;
  int _missingIndexes = 0;
  Directory? _volumesDirectory;
  int? _generationAtStart;
  bool _usesPool = false;
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
    final refs = [...await scriptureVolumeStore.listRefs()];
    refs.sort((left, right) {
      final byWork = left.work.compareTo(right.work);
      if (byWork != 0) return byWork;
      return _juanNumber(left).compareTo(_juanNumber(right));
    });
    final juans = <String, Set<int>>{};
    String? firstPath;
    for (final ref in refs) {
      final juan = int.tryParse(ref.juan);
      if (juan != null) juans.putIfAbsent(ref.work, () => <int>{}).add(juan);
      final path = ref.path ?? '';
      if (firstPath == null && path.isNotEmpty) firstPath = path;
    }
    if (firstPath != null) {
      _volumesDirectory = File(firstPath).parent;
      _generationAtStart = await readVolumesGeneration(_volumesDirectory!);
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
      final pool = _scanPoolFor(refs[_cursor]);
      _usesPool = pool != null;
      if (_batchVolumes == 0) {
        _batchVolumes = pool == null ? volumesPerChunk : _poolVolumesPerChunk;
      }
      final end = math.min(_cursor + _batchVolumes, refs.length);
      final timer = Stopwatch()..start();
      final outcome = await _runBatch(refs.sublist(_cursor, end), pool);
      timer.stop();
      _merge(outcome);
      _adaptBatch(
        timer.elapsedMicroseconds,
        budget: pool == null ? _batchBudgetMicros : _poolBatchBudgetMicros,
      );
      _cursor = end;
    } else {
      _cursor = refs.length;
    }
    if (_cursor >= refs.length) {
      _finished = true;
      _rebuildResults();
      await _markIndexesVerifiedIfSafe();
    }
    _notify();
    return true;
  }

  /// 只有在「整趟掃描都成功、且掃描期間沒有任何卷被寫入」時，才把目前的
  /// 經卷世代記成已驗證；之後的搜尋就能跳過每卷一次 `stat`。
  Future<void> _markIndexesVerifiedIfSafe() async {
    final directory = _volumesDirectory;
    final start = _generationAtStart;
    if (_disposed || directory == null || start == null) return;
    if (_missingIndexes > 0) return;
    if (await readVolumesGeneration(directory) != start) return;
    final support = directory.parent;
    await SidxSegmentStore(
      directoryProvider: () async => support,
    ).writeVolumesGenerationMarker(start);
  }

  OfflineScanPool? _scanPoolFor(ScriptureVolumeRef ref) =>
      offlineScanSupportsIsolate() && (ref.path ?? '').isNotEmpty
      ? sharedOfflineScanPool()
      : null;

  Future<OfflineScanOutcome> _runBatch(
    List<ScriptureVolumeRef> chunk,
    OfflineScanPool? pool,
  ) {
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
    _missingIndexes += outcome.missingIndexes;
    for (final group in outcome.groups) {
      final bucket = _merged.putIfAbsent(
        group.work,
        () => _MergedWork(group.title),
      );
      bucket.hits.addAll(group.hits);
      bucket.hitCount += group.hitCount;
    }
    if (_results.isEmpty ||
        _rebuildClock.elapsedMicroseconds >= _rebuildIntervalMicros) {
      _rebuildResults();
      _rebuildClock
        ..reset()
        ..start();
    }
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
    // 段式索引按段分組後，命中順序不再等於作品順序；結果仍按經號排，
    // 分頁與「第 N 部之後」的行為才和以前一致。
    final entries = _merged.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));
    _results = [
      for (final entry in entries)
        ScriptureSearchResult(
          title: '${entry.key} ${entry.value.title}'.trim(),
          description: '離線經文 · 命中 ${entry.value.hitCount} 處',
          passages: entry.value.passages,
          workId: entry.key,
          // 命中清單會隨掃描增長；發布的是同一個清單，避免每塊複製整部經的命中。
          pendingHits: _pendingFor(entry.value),
          hitCount: entry.value.hitCount,
        ),
    ];
  }

  static List<OfflineHit> _pendingFor(_MergedWork work) {
    final expanded = work.expandedHits;
    if (expanded == 0) return work.hits;
    final rest = work.hits.length - expanded;
    return rest <= 0 ? const [] : work.hits.sublist(expanded);
  }

  /// 塊大小跟隨預算：省下來的掃描時間直接換成更少的塊次數。
  void _adaptBatch(int micros, {required int budget}) {
    if (micros < budget) {
      _batchVolumes = math.min(maxVolumesPerChunk, _batchVolumes * 2);
    } else if (micros > budget * 4) {
      _batchVolumes = math.max(volumesPerChunk, _batchVolumes ~/ 2);
    }
  }

  int get _workerCount => _defaultWorkerCount();

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
        // 池在背景跑，掃描本身不佔 UI；塊夠大時不必再插固定的等待。
        await Future<void>.delayed(_usesPool ? Duration.zero : _chunkGap);
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
  int hitCount = 0;
  List<ScripturePassage> passages = const [];
  int expandedHits = 0;
}

const int _commandScan = 1;
const int _commandBuild = 2;
const int _commandExpand = 3;

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

/// 常駐背景工作池：掃描、建索引、展開摘要三種活都在同一批 worker 上跑。
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
  final Map<int, Completer<Object?>> _pending = {};

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
    // 同一段固定交給同一個 worker：段清單與 blob 控制代碼才有機會跨塊命中。
    final buckets = _bucketTargetsBySegment(request.targets, workerCount);
    final active = [
      for (var part = 0; part < buckets.length; part++)
        if (buckets[part].isNotEmpty) part,
    ];
    if (active.isEmpty) {
      return runOfflineScanInline(request, shouldAbort: shouldAbort);
    }
    if (active.length == 1 && request.targets.length < 8) {
      return runOfflineScanInline(request, shouldAbort: shouldAbort);
    }
    await _ensureWorkers(active.last + 1);
    if (_disposed) {
      return runOfflineScanInline(request, shouldAbort: shouldAbort);
    }
    final futures = <Future<OfflineScanOutcome>>[];
    for (final part in active) {
      futures.add(
        _dispatch<OfflineScanOutcome>(
          _workers[part],
          _commandScan,
          OfflineScanRequest(
            slotCandidates: request.slotCandidates,
            targets: buckets[part],
          ),
          OfflineScanOutcome.empty,
        ),
      );
    }
    var termHits = 0;
    var scanned = 0;
    var built = 0;
    var missing = 0;
    final groups = <OfflineWorkGroup>[];
    for (final outcome in await Future.wait(futures)) {
      termHits += outcome.termHits;
      scanned += outcome.scannedVolumes;
      built += outcome.builtIndexes;
      missing += outcome.missingIndexes;
      groups.addAll(outcome.groups);
    }
    return OfflineScanOutcome(
      groups: _mergeGroups(groups),
      termHits: termHits,
      scannedVolumes: scanned,
      builtIndexes: built,
      missingIndexes: missing,
    );
  }

  /// 建置工作排隊執行：不同批次若同時命中同一段，段鎖會讓其中一邊白等
  /// 兩秒；下載本身在等網路，序列化建置反而更穩。
  Future<void> _buildGate = Future<void>.value();

  /// 把索引建置分給現成的 worker；池已釋放或卷數太少時自己在當前 isolate 做完。
  Future<void> runBuild(OfflineIndexBuildRequest request, int workerCount) {
    final next = _buildGate.then((_) => _runBuild(request, workerCount));
    _buildGate = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  Future<void> _runBuild(
    OfflineIndexBuildRequest request,
    int workerCount,
  ) async {
    if (_disposed || request.targets.isEmpty) {
      await buildOfflineIndexBatch(request.targets);
      return;
    }
    final buckets = _bucketTargetsBySegment(
      request.targets,
      math.max(1, workerCount),
    );
    final active = [
      for (var part = 0; part < buckets.length; part++)
        if (buckets[part].isNotEmpty) part,
    ];
    if (active.isEmpty) {
      await buildOfflineIndexBatch(request.targets);
      return;
    }
    await _ensureWorkers(active.last + 1);
    if (_disposed) {
      await buildOfflineIndexBatch(request.targets);
      return;
    }
    final futures = <Future<int>>[];
    for (final part in active) {
      futures.add(
        _dispatch<int>(
          _workers[part],
          _commandBuild,
          OfflineIndexBuildRequest(targets: buckets[part]),
          0,
        ),
      );
    }
    await Future.wait(futures);
  }

  /// 展開一部經的命中；卷數少到不值得並行時留在當前 isolate。
  Future<List<ScripturePassage>> runExpand(
    OfflineExpandRequest request,
    int workerCount,
  ) async {
    if (request.targets.isEmpty) return const [];
    final parts = math.min(math.max(1, workerCount), request.targets.length);
    await _ensureWorkers(parts);
    if (_disposed) return runOfflineExpandInline(request);
    final size = (request.targets.length + parts - 1) ~/ parts;
    final futures = <Future<List<ScripturePassage>>>[];
    for (var start = 0; start < request.targets.length; start += size) {
      final end = math.min(start + size, request.targets.length);
      futures.add(
        _dispatch<List<ScripturePassage>>(
          _workers[futures.length % parts],
          _commandExpand,
          OfflineExpandRequest(
            work: request.work,
            slotCandidates: request.slotCandidates,
            targets: request.targets.sublist(start, end),
            availableJuans: request.availableJuans,
          ),
          const <ScripturePassage>[],
        ),
      );
    }
    final passages = <ScripturePassage>[];
    for (final part in await Future.wait(futures)) {
      passages.addAll(part);
    }
    passages.sort(_comparePassages);
    return passages;
  }

  Future<T> _dispatch<T>(
    _ScanWorker worker,
    int command,
    Object? payload,
    T fallback,
  ) {
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    worker.commandPort.send(<Object?>[command, _replies.sendPort, id, payload]);
    return completer.future
        .timeout(
          const Duration(seconds: 120),
          onTimeout: () {
            _pending.remove(id);
            return fallback;
          },
        )
        .then<T>((dynamic value) => value is T ? value : fallback);
  }

  void _onReply(dynamic message) {
    if (message is! List || message.length != 2) return;
    final completer = _pending.remove(message[0]);
    if (completer == null || completer.isCompleted) return;
    completer.complete(message[1]);
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
      if (!completer.isCompleted) completer.complete(null);
    }
    _pending.clear();
  }
}

/// 按段固定分配到 worker：同一段整個掃描期間都由同一個 worker 處理，
/// 段清單與 blob 控制代碼才能留在該 worker 的快取裡。
///
/// 以前每塊重新按負載分配，同一段會被不同 worker 輪流重讀 100 多 KB 的清單，
/// 2 萬卷時讀放大的 GB 級別，正是搜索變慢的主因。
List<List<OfflineScanTarget>> _bucketTargetsBySegment(
  List<OfflineScanTarget> targets,
  int parts,
) {
  if (targets.isEmpty) return const [];
  if (parts <= 1) return [targets];
  final buckets = List.generate(parts, (_) => <OfflineScanTarget>[]);
  for (final target in targets) {
    buckets[sidxSegmentId(target.work) % parts].add(target);
  }
  return buckets;
}

List<OfflineWorkGroup> _mergeGroups(List<OfflineWorkGroup> groups) {
  final order = <String>[];
  final merged = <String, List<OfflineHit>>{};
  final counts = <String, int>{};
  final titles = <String, String>{};
  for (final group in groups) {
    if (!merged.containsKey(group.work)) {
      order.add(group.work);
      merged[group.work] = <OfflineHit>[];
      titles[group.work] = group.title;
    }
    merged[group.work]!.addAll(group.hits);
    counts[group.work] = (counts[group.work] ?? 0) + group.hitCount;
  }
  return [
    for (final work in order)
      OfflineWorkGroup(
        work: work,
        title: titles[work]!,
        hits: merged[work]!,
        hitCount: counts[work] ?? merged[work]!.length,
      ),
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
    if (message is! List || message.length != 4) {
      return;
    }
    final command = message[0] as int;
    final reply = message[1] as SendPort;
    final id = message[2] as int;
    final payload = message[3];
    final Future<Object?> work = switch (command) {
      // worker 獨占 isolate，用同步檔案 I/O 省掉每卷的事件迴圈往返。
      _commandScan => _runOfflineScan(
        payload as OfflineScanRequest,
        yieldBetweenVolumes: false,
        blockingIo: true,
      ),
      _commandBuild => buildOfflineIndexBatch(
        (payload as OfflineIndexBuildRequest).targets,
        blockingIo: true,
      ),
      _commandExpand => runOfflineExpand(payload as OfflineExpandRequest),
      _ => Future<Object?>.value(),
    };
    unawaited(
      work.then(
        (Object? result) => reply.send(<Object?>[id, result]),
        onError: (Object _, StackTrace _) => reply.send(<Object?>[id, null]),
      ),
    );
  };
}

int _juanNumber(ScriptureVolumeRef ref) => int.tryParse(ref.juan) ?? 0;
