import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../scripture/index_update_service.dart';
import 'catalog_cache.dart';
import 'catalog_store.dart';
import 'download_manager.dart';
import 'download_notifications.dart';
import 'scripture_update_service.dart';
import 'work_archive.dart';

enum UpdateStatus { idle, running, paused, completed, failed }

enum UpdateStage {
  idle,
  checkingCatalog,
  downloadingCatalog,
  downloadingWorks,
  completed,
}

@immutable
class UpdateProgress {
  const UpdateProgress({
    required this.status,
    required this.stage,
    required this.totalWorks,
    required this.checkedWorks,
    required this.updatedWorks,
    required this.skippedWorks,
    required this.failedWorks,
    required this.stageFraction,
    required this.receivedBytes,
    required this.totalBytes,
    this.removedWorks = 0,
    this.currentWork,
    this.message,
    this.releaseVersion,
  });

  final UpdateStatus status;
  final UpdateStage stage;

  /// 本次差分出的新增作品總數；[checkedWorks] 是目前處理到第幾部。
  final int totalWorks;
  final int checkedWorks;

  /// 已新增並寫入本機的作品數。
  final int updatedWorks;

  /// 新增清單中沒有 HTML 版而略過的作品數。
  final int skippedWorks;
  final int failedWorks;

  /// 本次經目差分偵測到、且本機曾下載過的下架作品數。
  final int removedWorks;

  final double stageFraction;
  final int receivedBytes;
  final int totalBytes;
  final String? currentWork;
  final String? message;
  final String? releaseVersion;

  bool get isRunning => status == UpdateStatus.running;

  double get fraction {
    if (stage == UpdateStage.checkingCatalog ||
        stage == UpdateStage.downloadingCatalog ||
        totalWorks == 0) {
      return stageFraction.clamp(0.0, 1.0);
    }
    return (checkedWorks / totalWorks).clamp(0.0, 1.0);
  }
}

class UpdateManager extends ChangeNotifier {
  UpdateManager({
    CatalogUpdateService? catalogService,
    ScriptureUpdateService? scriptureService,
    DownloadManager? downloads,
    DownloadNotificationService? notifications,
    IndexUpdateService? indexService,
    Future<SharedPreferences> Function()? prefsProvider,
    Future<void> Function()? reloadCatalog,
  }) : _catalogService = catalogService ?? CatalogUpdateService(),
       _scriptureService = scriptureService ?? ScriptureUpdateService(),
       _downloads = downloads ?? downloadManager,
       _notifications = notifications ?? downloadNotifications,
       _indexService = indexService ?? indexUpdateService,
       _prefsProvider = prefsProvider ?? SharedPreferences.getInstance,
       _reloadCatalog = reloadCatalog ?? CatalogCache.instance.reload;

  static const _prefsKey = 'cbeta_update_task';
  static const _orphanedPrefsKey = 'cbeta_orphaned_works';
  static const _retryPrefsKey = 'cbeta_update_retry_works';
  static const _schemaVersion = 2;

  final CatalogUpdateService _catalogService;
  final ScriptureUpdateService _scriptureService;
  final DownloadManager _downloads;
  final DownloadNotificationService _notifications;
  final IndexUpdateService _indexService;
  final Future<SharedPreferences> Function() _prefsProvider;
  final Future<void> Function() _reloadCatalog;

  final List<String> _pending = [];
  final List<String> _orphanedWorks = [];
  final List<String> _retryWorks = [];
  final List<({DateTime time, int bytes})> _speedSamples = [];

  SharedPreferences? _prefs;
  UpdateStatus _status = UpdateStatus.idle;
  UpdateStage _stage = UpdateStage.idle;
  bool _taskActive = false;
  bool _catalogDone = false;
  bool _pauseRequested = false;
  bool _removed = false;
  int _generation = 0;
  int _checked = 0;
  int _added = 0;
  int _noHtml = 0;
  int _failed = 0;
  int _removedCount = 0;
  int _receivedBytes = 0;
  int _totalBytes = 0;
  int _sessionBytes = 0;
  double _stageFraction = 0;
  String? _currentWork;
  String? _message;
  String? _error;
  String? _releaseVersion;
  bool _notificationActive = false;
  bool _notificationStarted = false;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastNotification = DateTime.fromMillisecondsSinceEpoch(0);

  UpdateStatus get status => _status;
  UpdateStage get stage => _stage;
  String? get error => _error;
  String? get currentWork => _currentWork;
  String? get releaseVersion => _releaseVersion;
  int get pendingWorkCount => _pending.length;
  bool get isUpdating => _status == UpdateStatus.running;
  bool get isPausing => _pauseRequested && _status == UpdateStatus.running;
  bool get canResume =>
      _taskActive &&
      !isUpdating &&
      (_pending.isNotEmpty || !_catalogDone) &&
      (_status == UpdateStatus.paused || _status == UpdateStatus.failed);
  bool get hasTask => _taskActive || _status != UpdateStatus.idle;

  /// 本機曾下載、但新版經目已移除的作品；只提示，不會自動刪除經卷。
  List<String> get orphanedWorks => List.unmodifiable(_orphanedWorks);

  int get _totalWorks => _checked + _pending.length;

  UpdateProgress get progress => UpdateProgress(
    status: _status,
    stage: _stage,
    totalWorks: _totalWorks,
    checkedWorks: _checked,
    updatedWorks: _added,
    skippedWorks: _noHtml,
    failedWorks: _failed,
    removedWorks: _removedCount,
    stageFraction: _stageFraction,
    receivedBytes: _receivedBytes,
    totalBytes: _totalBytes,
    currentWork: _currentWork,
    message: _message,
    releaseVersion: _releaseVersion,
  );

  double get downloadSpeedBytesPerSecond {
    if (_speedSamples.length < 2) return 0;
    final latest = _speedSamples.last;
    if (DateTime.now().difference(latest.time) > const Duration(seconds: 2)) {
      return 0;
    }
    final cutoff = latest.time.subtract(const Duration(seconds: 2));
    var oldest = latest;
    for (final sample in _speedSamples) {
      if (!sample.time.isBefore(cutoff)) {
        oldest = sample;
        break;
      }
    }
    final elapsed = latest.time.difference(oldest.time).inMilliseconds;
    if (elapsed <= 0) return 0;
    return (latest.bytes - oldest.bytes) * 1000 / elapsed;
  }

  Future<void> initialize() async {
    try {
      _prefs = await _prefsProvider();
      await _restoreOrphaned();
      await _restoreRetry();
      final raw = _prefs?.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      final schema = (decoded['schema'] as num?)?.toInt();
      if (schema != _schemaVersion) {
        // 舊版任務保存的是「重新檢查全部已下載作品」的清單，與新流程不相容。
        await _prefs?.remove(_prefsKey);
        return;
      }
      final pending = (decoded['pending'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .where(_isValidWork)
          .toList();
      final active = decoded['active'] as bool? ?? pending.isNotEmpty;
      if (!active) {
        await _prefs?.remove(_prefsKey);
        return;
      }
      _pending
        ..clear()
        ..addAll(pending);
      _catalogDone = decoded['catalog_done'] as bool? ?? false;
      _checked = (decoded['checked'] as num?)?.toInt() ?? 0;
      _added = (decoded['added'] as num?)?.toInt() ?? 0;
      _noHtml = (decoded['no_html'] as num?)?.toInt() ?? 0;
      _failed = (decoded['failed'] as num?)?.toInt() ?? 0;
      _removedCount = (decoded['removed_count'] as num?)?.toInt() ?? 0;
      _releaseVersion = decoded['release'] as String?;
      _error = decoded['error'] as String?;
      _taskActive = true;
      _status = UpdateStatus.paused;
      _stage = _catalogDone
          ? UpdateStage.downloadingWorks
          : UpdateStage.checkingCatalog;
      _message = '更新已暫停';
    } catch (error) {
      debugPrint('Update manager init failed: $error');
    }
    notifyListeners();
  }

  /// 開始新的更新，或接續既有任務。回傳 false 表示目前不能開始。
  Future<bool> start() async {
    if (isUpdating || _downloads.isDownloading) return false;
    final exhausted =
        _status == UpdateStatus.failed && _catalogDone && _pending.isEmpty;
    if (!_taskActive || _status == UpdateStatus.completed || exhausted) {
      _beginNewTask();
    }
    _pauseRequested = false;
    _removed = false;
    _error = null;
    _status = UpdateStatus.running;
    _stage = _catalogDone
        ? UpdateStage.downloadingWorks
        : UpdateStage.checkingCatalog;
    _message = _catalogDone ? '準備下載新增經文…' : '檢查經目更新…';
    _stageFraction = 0;
    _notify(force: true);
    unawaited(_startNotification());
    unawaited(_run(++_generation));
    return true;
  }

  void _beginNewTask() {
    _pending.clear();
    _taskActive = true;
    _catalogDone = false;
    _checked = 0;
    _added = 0;
    _noHtml = 0;
    _failed = 0;
    _removedCount = 0;
    _releaseVersion = null;
    _stageFraction = 0;
  }

  void pause() {
    if (_status != UpdateStatus.running || _pauseRequested) return;
    _pauseRequested = true;
    _message = '正在暫停…';
    _notify(force: true);
  }

  void resume() {
    if (isUpdating || !canResume) return;
    unawaited(start());
  }

  /// 刪除更新任務；已新增的經文與經目檔案不會被還原。
  void deleteTask() {
    _generation++;
    _removed = true;
    _pauseRequested = false;
    _pending.clear();
    _taskActive = false;
    _catalogDone = false;
    _status = UpdateStatus.idle;
    _stage = UpdateStage.idle;
    _currentWork = null;
    _message = null;
    _error = null;
    _releaseVersion = null;
    _checked = 0;
    _added = 0;
    _noHtml = 0;
    _failed = 0;
    // 下架提示獨立保存，刪除更新任務不會順手清掉。
    _removedCount = _orphanedWorks.length;
    _receivedBytes = 0;
    _totalBytes = 0;
    _stageFraction = 0;
    _speedSamples.clear();
    _retryWorks.clear();
    _stopNotification();
    unawaited(_clearPersisted());
    unawaited(_persistRetry());
    notifyListeners();
  }

  /// 使用者確認後清掉下架提示；本機經卷與下載紀錄保持不動。
  void clearOrphanedWorks() {
    if (_orphanedWorks.isEmpty && _removedCount == 0) return;
    _orphanedWorks.clear();
    _removedCount = 0;
    unawaited(_persistOrphaned());
    notifyListeners();
  }

  Future<void> _run(int generation) async {
    try {
      if (!_catalogDone) {
        await _updateCatalog(generation);
        if (generation != _generation || _removed) return;
      }

      while (_pending.isNotEmpty &&
          !_pauseRequested &&
          !_removed &&
          generation == _generation) {
        final work = _pending.first;
        _currentWork = work;
        _stage = UpdateStage.downloadingWorks;
        _message = '下載新增經文：$work';
        _receivedBytes = 0;
        _totalBytes = 0;
        _sessionBytes = 0;
        _speedSamples.clear();
        _notify(force: true);

        final completed = await _downloadNewWork(work, generation);
        if (generation != _generation || _removed) return;
        if (!completed) break;

        _pending.removeAt(0);
        _checked++;
        _stageFraction = _totalWorks == 0 ? 1 : _checked / _totalWorks;
        await _persist();
        _notify(force: true);
      }

      if (generation != _generation || _removed) return;
      if (_pauseRequested) {
        _status = UpdateStatus.paused;
        _stage = _catalogDone
            ? UpdateStage.downloadingWorks
            : UpdateStage.checkingCatalog;
        _message = '更新已暫停';
        _currentWork = null;
        _stopNotification();
        await _persist();
        _notify(force: true);
        return;
      }

      _status = UpdateStatus.completed;
      _stage = UpdateStage.completed;
      _taskActive = false;
      _currentWork = null;
      _stageFraction = 1;
      _message = _summary();
      _stopNotification();
      await _clearPersisted();
      _notify(force: true);
      _refreshIndexesIfNeeded();
    } on CatalogUpdatePaused {
      if (generation == _generation) {
        _status = UpdateStatus.paused;
        _stage = _catalogDone
            ? UpdateStage.downloadingWorks
            : UpdateStage.checkingCatalog;
        _message = '更新已暫停';
        _currentWork = null;
        _stopNotification();
        await _persist();
        _notify(force: true);
      }
    } catch (error) {
      if (generation == _generation) {
        _status = UpdateStatus.failed;
        _error = '$error';
        _message = '更新中斷';
        _currentWork = null;
        _stopNotification();
        await _persist();
        _notify(force: true);
        _refreshIndexesIfNeeded();
      }
    }
  }

  /// 新經卷落地時已排入逐卷索引；這裡只負責觸發一次全域增量核對。
  void _refreshIndexesIfNeeded() {
    if (_added == 0) return;
    _indexService.requestUpdate();
    unawaited(_indexService.startIfNeeded());
  }

  Future<void> _updateCatalog(int generation) async {
    _stage = UpdateStage.checkingCatalog;
    _message = '檢查經目更新…';
    _stageFraction = 0;
    _notify(force: true);

    Set<String>? oldWorks;
    try {
      oldWorks = await _catalogWorkIds();
    } catch (error) {
      debugPrint('Catalog snapshot failed: $error');
    }
    if (generation != _generation || _removed) return;

    final outcome = await _catalogService.update(
      onProgress: (message, fraction) {
        if (generation != _generation || _removed) return;
        _message = message;
        _stage = message.startsWith('下載')
            ? UpdateStage.downloadingCatalog
            : UpdateStage.checkingCatalog;
        if (fraction != null) _stageFraction = fraction.clamp(0.0, 0.95);
        _notify(force: true);
      },
      isCancelled: () =>
          generation != _generation || _pauseRequested || _removed,
    );
    if (generation != _generation || _removed) return;
    _catalogDone = true;
    _releaseVersion = outcome.releaseVersion.isEmpty
        ? null
        : outcome.releaseVersion;
    _stageFraction = 1;
    _message = outcome.changed ? '經目已更新' : '經目已是最新';
    if (outcome.changed) {
      try {
        await _reloadCatalog();
      } catch (error) {
        debugPrint('Catalog reload after update failed: $error');
        _error = '經目已下載，但重新載入失敗：$error';
      }
    }
    if (generation != _generation || _removed) return;

    Set<String>? newWorks;
    if (outcome.changed) {
      try {
        newWorks = await _catalogWorkIds();
      } catch (error) {
        debugPrint('Catalog snapshot after update failed: $error');
      }
    } else {
      newWorks = oldWorks;
    }

    // 舊經目為空時不做差分，避免把整份清單誤判成新增而下載全藏。
    if (oldWorks != null &&
        newWorks != null &&
        oldWorks.isNotEmpty &&
        newWorks.isNotEmpty) {
      _applyCatalogDiff(oldWorks, newWorks);
    } else {
      _seedRetryWorks();
    }

    await _persist();
    _notify(force: true);
  }

  Future<Set<String>?> _catalogWorkIds() async {
    final cache = CatalogCache.instance;
    if (!cache.isLoaded) {
      try {
        await cache.load();
      } catch (error) {
        debugPrint('Catalog load before diff failed: $error');
        return null;
      }
    }
    if (!cache.isLoaded) return null;
    return {for (final entry in cache.allWorks) entry.work};
  }

  void _applyCatalogDiff(Set<String> oldWorks, Set<String> newWorks) {
    final downloaded = _downloads.downloadedWorkIds;
    if (_retryWorks.any((work) => !newWorks.contains(work))) {
      _retryWorks.removeWhere((work) => !newWorks.contains(work));
      unawaited(_persistRetry());
    }
    final added =
        <String>{...newWorks.difference(oldWorks), ..._retryWorks}
            .where(
              (work) => newWorks.contains(work) && !downloaded.contains(work),
            )
            .toList()
          ..sort();
    final removed =
        oldWorks.difference(newWorks).where(downloaded.contains).toList()
          ..sort();
    _pending
      ..clear()
      ..addAll(added);
    _orphanedWorks
      ..clear()
      ..addAll(removed);
    _removedCount = _orphanedWorks.length;
    unawaited(_persistOrphaned());
  }

  /// 經目沒變時只重試上次下載失敗的新增作品。
  void _seedRetryWorks() {
    final downloaded = _downloads.downloadedWorkIds;
    if (_retryWorks.any(downloaded.contains)) {
      _retryWorks.removeWhere(downloaded.contains);
      unawaited(_persistRetry());
    }
    _pending
      ..clear()
      ..addAll(
        _retryWorks.where((work) => !downloaded.contains(work)).toList()
          ..sort(),
      );
  }

  /// 新增作品靜默下載：先用 HEAD 確認 HTML 壓縮檔存在，再整部寫入。
  Future<bool> _downloadNewWork(String work, int generation) async {
    WorkHeadInfo head;
    try {
      head = await _scriptureService.headWork(work);
    } on ScriptureHttpException catch (error) {
      if (generation != _generation || _removed) return false;
      _failNewWork(work, error, notFound: error.statusCode == 404);
      return true;
    } catch (error) {
      if (generation != _generation || _removed) return false;
      _failNewWork(work, error);
      return true;
    }
    if (generation != _generation || _removed) return false;
    if (_pauseRequested) return false;

    _totalBytes = head.contentLength ?? 0;
    _notify(force: true);

    WorkArchive? archive;
    try {
      archive = await _scriptureService.downloadWork(
        work,
        filePrefix: CatalogCache.instance.lookupWorkFile(work) ?? '',
        onBytesReceived: _handleBytesReceived,
      );
    } catch (error) {
      debugPrint('New work download failed $work: $error');
      _error = '$work：$error';
    }
    if (generation != _generation || _removed) return false;
    if (_pauseRequested) return false;

    if (archive == null || archive.volumes.isEmpty) {
      _failed++;
      _markRetry(work);
      _error ??= '$work：沒有可下載的經卷';
      _message = '新增經文失敗：$work';
      return true;
    }

    var stored = 0;
    try {
      stored = await _downloads.storeDownloadedWork(
        work,
        archive.volumes,
        release: _releaseVersion,
      );
    } catch (error) {
      debugPrint('New work store failed $work: $error');
      _error = '$work：$error';
    }
    if (generation != _generation || _removed) return false;

    if (stored == 0) {
      _failed++;
      _markRetry(work);
      _error ??= '$work：寫入新增經卷失敗';
      _message = '新增經文失敗：$work';
      return true;
    }
    _added++;
    _clearRetry(work);
    _message = '已新增：$work';
    _indexService.requestUpdate();
    return true;
  }

  void _failNewWork(String work, Object error, {bool notFound = false}) {
    if (notFound) {
      // 經目有這部作品，但 CBETA 沒有提供 HTML 壓縮檔。
      _noHtml++;
      _message = '$work：沒有 HTML 版，略過';
      return;
    }
    _failed++;
    _markRetry(work);
    _error = '$work：$error';
    _message = '新增經文失敗：$work';
  }

  void _markRetry(String work) {
    if (_retryWorks.contains(work)) return;
    _retryWorks.add(work);
    unawaited(_persistRetry());
  }

  void _clearRetry(String work) {
    if (!_retryWorks.remove(work)) return;
    unawaited(_persistRetry());
  }

  String _summary() {
    final parts = <String>[
      if (_added > 0) '新增 $_added 部',
      if (_removedCount > 0) '下架 $_removedCount 部',
      if (_noHtml > 0) '$_noHtml 部無 HTML 版',
      if (_failed > 0) '$_failed 部失敗',
    ];
    return parts.isEmpty ? '經目已是最新' : '更新完成：${parts.join('，')}';
  }

  bool get _isCatalogStage =>
      _stage == UpdateStage.checkingCatalog ||
      _stage == UpdateStage.downloadingCatalog;

  Future<void> _startNotification() async {
    if (_notificationActive) return;
    _notificationActive = true;
    await _notifications.requestPermission();
    if (!_notificationActive || _status != UpdateStatus.running) return;
    _notificationStarted = true;
    _lastNotification = DateTime.now();
    final progress = this.progress;
    await _notifications.start(
      title: _notificationTitle,
      text: _notificationText(progress),
      progress: _notificationValue(progress),
      max: _notificationMax(progress),
    );
    if (!_notificationActive) {
      unawaited(_notifications.stop());
    }
  }

  void _stopNotification() {
    if (!_notificationActive && !_notificationStarted) return;
    _notificationActive = false;
    _notificationStarted = false;
    unawaited(_notifications.stop());
  }

  void _updateNotification({bool force = false}) {
    if (!_notificationStarted || _status != UpdateStatus.running) return;
    final now = DateTime.now();
    if (!force &&
        now.difference(_lastNotification) < const Duration(milliseconds: 800)) {
      return;
    }
    _lastNotification = now;
    final progress = this.progress;
    unawaited(
      _notifications.update(
        title: _notificationTitle,
        text: _notificationText(progress),
        progress: _notificationValue(progress),
        max: _notificationMax(progress),
      ),
    );
  }

  String get _notificationTitle => _isCatalogStage ? '正在更新經目' : '正在下載新增經文';

  String _notificationText(UpdateProgress progress) {
    if (_isCatalogStage) return progress.message ?? '檢查經目更新…';
    final parts = <String>[
      if (progress.updatedWorks > 0) '已新增 ${progress.updatedWorks} 部',
      if (progress.removedWorks > 0) '下架 ${progress.removedWorks} 部',
      if (progress.totalWorks > 0)
        '已處理 ${progress.checkedWorks}/${progress.totalWorks} 部',
      if (progress.currentWork != null) '目前：${progress.currentWork}',
    ];
    return parts.isEmpty ? '準備下載新增經文…' : parts.join(' · ');
  }

  int _notificationMax(UpdateProgress progress) => _isCatalogStage
      ? 1000
      : (progress.totalWorks < 1 ? 1 : progress.totalWorks);

  int _notificationValue(UpdateProgress progress) {
    if (_isCatalogStage) {
      return (progress.stageFraction * 1000).round().clamp(0, 1000);
    }
    return progress.checkedWorks.clamp(0, _notificationMax(progress));
  }

  void _handleBytesReceived(int bytes) {
    if (bytes <= 0) return;
    final now = DateTime.now();
    _receivedBytes += bytes;
    _sessionBytes += bytes;
    _speedSamples.add((time: now, bytes: _sessionBytes));
    final cutoff = now.subtract(const Duration(seconds: 2));
    while (_speedSamples.length > 2 &&
        _speedSamples.first.time.isBefore(cutoff)) {
      _speedSamples.removeAt(0);
    }
    _notify();
  }

  void _notify({bool force = false}) {
    final now = DateTime.now();
    if (!force &&
        now.difference(_lastNotify) < const Duration(milliseconds: 500)) {
      return;
    }
    _lastNotify = now;
    _updateNotification(force: force);
    notifyListeners();
  }

  Future<void> _persist() async {
    try {
      final prefs = _prefs ??= await _prefsProvider();
      if (!_taskActive) {
        await prefs.remove(_prefsKey);
        return;
      }
      await prefs.setString(
        _prefsKey,
        jsonEncode({
          'schema': _schemaVersion,
          'active': _taskActive,
          'catalog_done': _catalogDone,
          'pending': _pending,
          'checked': _checked,
          'added': _added,
          'no_html': _noHtml,
          'failed': _failed,
          'removed_count': _removedCount,
          'release': _releaseVersion,
          'error': _error,
        }),
      );
    } catch (error) {
      debugPrint('Failed to persist update task: $error');
    }
  }

  Future<void> _restoreOrphaned() async {
    final raw = _prefs?.getString(_orphanedPrefsKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      _orphanedWorks
        ..clear()
        ..addAll(decoded.whereType<String>().where(_isValidWork));
      _removedCount = _orphanedWorks.length;
    } catch (error) {
      debugPrint('Orphaned works restore failed: $error');
    }
  }

  Future<void> _persistOrphaned() async {
    try {
      final prefs = _prefs ??= await _prefsProvider();
      if (_orphanedWorks.isEmpty) {
        await prefs.remove(_orphanedPrefsKey);
      } else {
        await prefs.setString(_orphanedPrefsKey, jsonEncode(_orphanedWorks));
      }
    } catch (error) {
      debugPrint('Failed to persist orphaned works: $error');
    }
  }

  Future<void> _restoreRetry() async {
    final raw = _prefs?.getString(_retryPrefsKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      _retryWorks
        ..clear()
        ..addAll(decoded.whereType<String>().where(_isValidWork));
    } catch (error) {
      debugPrint('Retry works restore failed: $error');
    }
  }

  Future<void> _persistRetry() async {
    try {
      final prefs = _prefs ??= await _prefsProvider();
      if (_retryWorks.isEmpty) {
        await prefs.remove(_retryPrefsKey);
      } else {
        await prefs.setString(_retryPrefsKey, jsonEncode(_retryWorks));
      }
    } catch (error) {
      debugPrint('Failed to persist retry works: $error');
    }
  }

  Future<void> _clearPersisted() async {
    try {
      final prefs = _prefs ??= await _prefsProvider();
      await prefs.remove(_prefsKey);
    } catch (error) {
      debugPrint('Failed to clear update task: $error');
    }
  }

  static bool _isValidWork(String work) =>
      RegExp(r'^[A-Za-z0-9]+$').hasMatch(work);

  /// 測試用：避免舊任務殘留。
  @visibleForTesting
  static Future<void> debugClearPersisted(
    Future<SharedPreferences> Function() prefsProvider,
  ) async {
    final prefs = await prefsProvider();
    await prefs.remove(_prefsKey);
    await prefs.remove(_orphanedPrefsKey);
    await prefs.remove(_retryPrefsKey);
  }
}

final updateManager = UpdateManager();
