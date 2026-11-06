import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'index_maintenance.dart';
import 'sidx_norm.dart';

/// 目前程式碼產生的索引格式；任一常數變動都會讓本機標記落後而觸發重建。
///
/// 只取格式與正規化版本：段清單標頭也用這兩個版本判有效，改動
/// `sidxFlagsApplied` 時必須同時遞增 `sidxNormVersion`，否則舊段不會失效。
const int currentIndexVersion = sidxFormatVersion * 1000000 + sidxNormVersion;

/// 最後一次「完整走完全部經卷」時使用的索引版本。
const String indexVersionPreferenceKey = 'cbeta_sidx_index_version';

/// 背景重建每批派工的大小；比手動重建小，讓下載可以插進來。
const int _backgroundIndexBatchSize = 64;

enum IndexUpdatePhase { idle, preparing, running, completed, failed }

@immutable
class IndexUpdateProgress {
  const IndexUpdateProgress({
    this.phase = IndexUpdatePhase.idle,
    this.done = 0,
    this.total = 0,
    this.message,
  });

  final IndexUpdatePhase phase;
  final int done;
  final int total;
  final String? message;

  bool get isActive =>
      phase == IndexUpdatePhase.preparing || phase == IndexUpdatePhase.running;

  double? get fraction {
    if (total <= 0) return null;
    return (done / total).clamp(0.0, 1.0);
  }
}

/// APP 升級後自動補齊過期的搜尋索引。
///
/// `.sidx` 是可由 `.json` 重建的派生物；這裡只負責「發現版本落後 → 在背景
/// 重建 → 記下完成版本」。重建與下載/經文更新互斥，避免同時搶 worker 與段鎖。
class IndexUpdateService extends ChangeNotifier {
  IndexUpdateService({
    ScriptureIndexMaintenance? maintenance,
    Future<SharedPreferences> Function()? prefsProvider,
    this.busyPollInterval = const Duration(seconds: 2),
  }) : _maintenance = maintenance ?? scriptureIndexMaintenance,
       _prefsProvider = prefsProvider ?? SharedPreferences.getInstance;

  final ScriptureIndexMaintenance _maintenance;
  final Future<SharedPreferences> Function() _prefsProvider;

  /// 回傳 true 時暫緩重建（下載或經文更新正在進行）。
  bool Function()? isBusy;

  final Duration busyPollInterval;

  IndexUpdateProgress _progress = const IndexUpdateProgress();
  int? _localVersion;
  bool _initialized = false;
  Future<void>? _running;
  Future<bool>? _starting;

  bool get isActive => progress.isActive;
  bool get isInitialized => _initialized;
  bool get needsUpdate =>
      !kIsWeb && _initialized && _localVersion != currentIndexVersion;
  IndexUpdateProgress get progress => _progress;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    if (kIsWeb) return;
    try {
      final prefs = await _prefsProvider();
      _localVersion = prefs.getInt(indexVersionPreferenceKey);
    } catch (_) {
      // 讀不到標記就當作從未完整建置，寧可多做一次增量重建。
      _localVersion = null;
    }
  }

  /// 版本落後時啟動一次背景重建；回傳這次呼叫是否真的開始了新工作。
  ///
  /// 啟動期間（例如還在列本地經卷）重入會等到同一次啟動有結果，
  /// 不會派出第二輪重建。
  Future<bool> startIfNeeded() {
    final existing = _starting;
    if (existing != null) return existing;
    final future = _startIfNeeded();
    _starting = future;
    unawaited(
      future.whenComplete(() {
        if (identical(_starting, future)) _starting = null;
      }),
    );
    return future;
  }

  Future<bool> _startIfNeeded() async {
    if (kIsWeb) return false;
    await initialize();
    if (!needsUpdate || _running != null) return false;
    if (!await _hasLocalVolumes()) {
      // 沒有經卷就沒有索引要建；直接記下版本，避免每次啟動都重查目錄。
      await markCurrentVersion();
      return false;
    }
    _progress = const IndexUpdateProgress(
      phase: IndexUpdatePhase.preparing,
      message: '搜尋索引需要更新，準備中…',
    );
    final future = _run();
    _running = future;
    notifyListeners();
    unawaited(
      future.whenComplete(() {
        if (identical(_running, future)) _running = null;
      }),
    );
    return true;
  }

  /// 等待目前這輪重建結束（沒有在跑就立即返回）。
  Future<void> waitForCompletion() async {
    final starting = _starting;
    if (starting != null) await starting;
    while (true) {
      final running = _running;
      if (running == null) return;
      await running;
    }
  }

  /// 把本機標記推進到目前版本。
  Future<void> markCurrentVersion() async {
    _initialized = true;
    _localVersion = currentIndexVersion;
    try {
      final prefs = await _prefsProvider();
      await prefs.setInt(indexVersionPreferenceKey, currentIndexVersion);
    } catch (_) {
      // 存不下就只影響下次啟動會再檢查一次，不影響本次索引。
    }
  }

  Future<bool> _hasLocalVolumes() async {
    try {
      return (await _maintenance.volumeStore.listRefs()).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<void> _run() async {
    try {
      _setProgress(
        IndexUpdateProgress(
          phase: IndexUpdatePhase.preparing,
          message: _busyMessage(),
        ),
      );
      await _waitWhileBusy();
      _setProgress(
        const IndexUpdateProgress(
          phase: IndexUpdatePhase.running,
          message: '正在更新搜尋索引…',
        ),
      );
      await _maintenance.rebuildIndexes(
        onProgress: (done, total) {
          _setProgress(
            IndexUpdateProgress(
              phase: IndexUpdatePhase.running,
              done: done,
              total: total,
              message: '正在更新搜尋索引：$done/$total 卷',
            ),
          );
        },
        beforeBatch: _waitWhileBusy,
        batchSize: _backgroundIndexBatchSize,
      );
      final total = _progress.total;
      await markCurrentVersion();
      _setProgress(
        IndexUpdateProgress(
          phase: IndexUpdatePhase.completed,
          done: total,
          total: total,
          message: total > 0 ? '搜尋索引已更新（共 $total 卷）' : '搜尋索引已更新',
        ),
      );
    } catch (error) {
      _setProgress(
        IndexUpdateProgress(
          phase: IndexUpdatePhase.failed,
          done: _progress.done,
          total: _progress.total,
          message: '搜尋索引更新失敗：$error',
        ),
      );
    }
  }

  Future<void> _waitWhileBusy() async {
    if (isBusy?.call() != true) return;
    _setProgress(
      IndexUpdateProgress(
        phase: IndexUpdatePhase.preparing,
        done: _progress.done,
        total: _progress.total,
        message: _busyMessage(),
      ),
    );
    while (isBusy?.call() ?? false) {
      await Future<void>.delayed(busyPollInterval);
    }
  }

  String _busyMessage() => _progress.done > 0
      ? '索引更新暫緩，等待下載完成…（已完成 ${_progress.done}/${_progress.total} 卷）'
      : '搜尋索引需要更新，等待下載完成後開始…';

  void _setProgress(IndexUpdateProgress value) {
    if (_progress.phase == value.phase &&
        _progress.done == value.done &&
        _progress.total == value.total &&
        _progress.message == value.message) {
      return;
    }
    _progress = value;
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    _progress = const IndexUpdateProgress();
    _localVersion = null;
    _initialized = false;
    _running = null;
    _starting = null;
    isBusy = null;
  }
}

final IndexUpdateService indexUpdateService = IndexUpdateService();
