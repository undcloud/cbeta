import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;

import 'cache.dart';
import 'offline_scan.dart';
import 'sidx_store.dart';

/// 一次重建的卷數：派給常駐池的訊息次數與批大小折衷。
const int _rebuildBatchSize = 256;

/// 搜尋索引（`.sidx`）的維護動作。
///
/// `.sidx` 是經卷 `.json` 的派生物，刪掉就能從頭重建；沒有它，驗證「索引到底
/// 省下多少時間」只能把兩萬多卷重下一遍，所以留一條不用重下的路。
class ScriptureIndexMaintenance {
  ScriptureIndexMaintenance({
    ScriptureIndexStore? indexStore,
    ScriptureVolumeStore? volumeStore,
  }) : _indexStore = indexStore,
       _volumeStore = volumeStore;

  /// null 時取全域實例（正式路徑）；測試傳自己 tmp 目錄的實例。
  final ScriptureIndexStore? _indexStore;
  final ScriptureVolumeStore? _volumeStore;

  ScriptureIndexStore get indexStore => _indexStore ?? scriptureIndexStore;
  ScriptureVolumeStore get volumeStore => _volumeStore ?? scriptureVolumeStore;

  /// 清掉全部派生索引（不動經卷本體），回傳刪除的檔案數。
  Future<int> clearAllIndexes() async {
    if (kIsWeb) return 0;
    final count = await countIndexes();
    await indexStore.clearAll();
    return count;
  }

  /// 目前已經存在的索引檔數；目錄還沒建立時為 0。
  Future<int> countIndexes() async {
    if (kIsWeb) return 0;
    try {
      final directory = Directory(await indexStore.directoryPath());
      if (!await directory.exists()) return 0;
      var count = 0;
      await for (final entity in directory.list()) {
        if (entity is File && entity.path.endsWith('.sidx')) count++;
      }
      return count;
    } catch (_) {
      return 0;
    }
  }

  /// 逐卷重建索引，回傳實際建好（或確認已是最新）的卷數。
  ///
  /// 戳記相符的卷會被 `buildOfflineIndexBatch` 跳過，所以重複呼叫是無害的增量
  /// 重建；[shouldAbort] 讓呼叫端在離開頁面或取消時停手。
  Future<int> rebuildIndexes({
    void Function(int done, int total)? onProgress,
    bool Function()? shouldAbort,
  }) async {
    if (kIsWeb) return 0;
    final refs = await scriptureVolumeStore.listRefs();
    final targets = [
      for (final ref in refs)
        if ((ref.path ?? '').isNotEmpty)
          OfflineScanTarget(
            work: ref.work,
            juan: ref.juan,
            path: ref.path ?? '',
          ),
    ];
    final total = targets.length;
    var built = 0;
    for (var start = 0; start < total; start += _rebuildBatchSize) {
      if (shouldAbort != null && shouldAbort()) break;
      final batch = targets.sublist(
        start,
        math.min(start + _rebuildBatchSize, total),
      );
      built += await _runBuildBatch(batch);
      onProgress?.call(math.min(start + batch.length, total), total);
      // 主 isolate 自己掃的場合（測試、網頁版）要讓出畫面，否則几千卷會把 UI
      // 排死在解析 HTML 上。
      await Future<void>.delayed(Duration.zero);
    }
    return built;
  }

  Future<int> _runBuildBatch(List<OfflineScanTarget> batch) async {
    if (batch.isEmpty) return 0;
    final pool = offlineScanSupportsIsolate() ? sharedOfflineScanPool() : null;
    if (pool == null) return buildOfflineIndexBatch(batch);
    await pool.runBuild(
      OfflineIndexBuildRequest(targets: batch),
      math.min(4, math.max(2, Platform.numberOfProcessors)),
    );
    // 池的回覆只帶「成功與否」，計數以派出去的卷數為準：戳記相符的卷會被
    // 跳過，呼叫端只关心進度有没有推進。
    return batch.length;
  }
}

final ScriptureIndexMaintenance scriptureIndexMaintenance =
    ScriptureIndexMaintenance();
