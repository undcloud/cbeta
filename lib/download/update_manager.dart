import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../scripture/cache.dart';
import 'catalog_cache.dart';
import 'catalog_store.dart';
import 'download_manager.dart';
import 'download_models.dart';
import 'download_notifications.dart';
import 'scripture_update_service.dart';
import 'work_archive.dart';

enum UpdateStatus { idle, running, paused, completed, failed }

enum UpdateStage {
  idle,
  checkingCatalog,
  downloadingCatalog,
  checkingWorks,
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
    this.currentWork,
    this.message,
    this.releaseVersion,
  });

  final UpdateStatus status;
  final UpdateStage stage;
  final int totalWorks;
  final int checkedWorks;
  final int updatedWorks;
  final int skippedWorks;
  final int failedWorks;
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

enum _WorkUpdateResult { unchanged, updated, failed }

class UpdateManager extends ChangeNotifier {
  UpdateManager({
    CatalogUpdateService? catalogService,
    ScriptureUpdateService? scriptureService,
    DownloadManager? downloads,
    DownloadNotificationService? notifications,
    Future<SharedPreferences> Function()? prefsProvider,
    Future<void> Function()? reloadCatalog,
  }) : _catalogService = catalogService ?? CatalogUpdateService(),
       _scriptureService = scriptureService ?? ScriptureUpdateService(),
       _downloads = downloads ?? downloadManager,
       _notifications = notifications ?? downloadNotifications,
       _prefsProvider = prefsProvider ?? SharedPreferences.getInstance,
       _reloadCatalog = reloadCatalog ?? CatalogCache.instance.reload;

  static const _prefsKey = 'cbeta_update_task';

  final CatalogUpdateService _catalogService;
  final ScriptureUpdateService _scriptureService;
  final DownloadManager _downloads;
  final DownloadNotificationService _notifications;
  final Future<SharedPreferences> Function() _prefsProvider;
  final Future<void> Function() _reloadCatalog;

  final List<String> _pending = [];
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
  int _updated = 0;
  int _skipped = 0;
  int _failed = 0;
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

  int get _totalWorks => _checked + _pending.length;

  UpdateProgress get progress => UpdateProgress(
    status: _status,
    stage: _stage,
    totalWorks: _totalWorks,
    checkedWorks: _checked,
    updatedWorks: _updated,
    skippedWorks: _skipped,
    failedWorks: _failed,
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
      final raw = _prefs?.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
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
      _updated = (decoded['updated'] as num?)?.toInt() ?? 0;
      _skipped = (decoded['skipped'] as num?)?.toInt() ?? 0;
      _failed = (decoded['failed'] as num?)?.toInt() ?? 0;
      _releaseVersion = decoded['release'] as String?;
      _error = decoded['error'] as String?;
      _taskActive = true;
      _status = UpdateStatus.paused;
      _stage = _catalogDone
          ? UpdateStage.checkingWorks
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
        ? UpdateStage.checkingWorks
        : UpdateStage.checkingCatalog;
    _message = _catalogDone ? '準備檢查經文…' : '檢查經目更新…';
    _stageFraction = 0;
    _notify(force: true);
    unawaited(_startNotification());
    unawaited(_run(++_generation));
    return true;
  }

  void _beginNewTask() {
    _pending
      ..clear()
      ..addAll(_downloads.downloadedWorkIds.toList()..sort());
    _taskActive = true;
    _catalogDone = false;
    _checked = 0;
    _updated = 0;
    _skipped = 0;
    _failed = 0;
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

  /// 刪除更新任務；已更新的經文與經目檔案不會被還原。
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
    _updated = 0;
    _skipped = 0;
    _failed = 0;
    _receivedBytes = 0;
    _totalBytes = 0;
    _stageFraction = 0;
    _speedSamples.clear();
    _stopNotification();
    unawaited(_clearPersisted());
    notifyListeners();
  }

  Future<void> _run(int generation) async {
    try {
      if (!_catalogDone) {
        await _updateCatalog(generation);
        if (generation != _generation || _removed) return;
      }

      if (!CatalogCache.instance.isLoaded) {
        try {
          await CatalogCache.instance.load();
        } catch (error) {
          debugPrint('Catalog load before work update failed: $error');
        }
      }

      while (_pending.isNotEmpty &&
          !_pauseRequested &&
          !_removed &&
          generation == _generation) {
        final work = _pending.first;
        _currentWork = work;
        _stage = UpdateStage.checkingWorks;
        _message = '檢查經文：$work';
        _receivedBytes = 0;
        _totalBytes = 0;
        _sessionBytes = 0;
        _speedSamples.clear();
        _notify(force: true);

        await _updateWork(work, generation);
        if (generation != _generation || _removed) return;

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
            ? UpdateStage.checkingWorks
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
      _message = _failed > 0
          ? '更新完成：共更新 $_updated 部佛經，$_skipped 部已是最新，$_failed 部失敗'
          : '更新完成：共更新 $_updated 部佛經，$_skipped 部已是最新';
      _stopNotification();
      await _clearPersisted();
      _notify(force: true);
    } on CatalogUpdatePaused {
      if (generation == _generation) {
        _status = UpdateStatus.paused;
        _stage = _catalogDone
            ? UpdateStage.checkingWorks
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
      }
    }
  }

  Future<void> _updateCatalog(int generation) async {
    _stage = UpdateStage.checkingCatalog;
    _message = '檢查經目更新…';
    _stageFraction = 0;
    _notify(force: true);
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
    await _persist();
    if (outcome.changed) {
      try {
        await _reloadCatalog();
      } catch (error) {
        debugPrint('Catalog reload after update failed: $error');
        _error = '經目已下載，但重新載入失敗：$error';
      }
    }
    _notify(force: true);
  }

  Future<_WorkUpdateResult> _updateWork(String work, int generation) async {
    final localVersions = _downloads.versionsForWork(work);
    if (localVersions.isEmpty) return _WorkUpdateResult.unchanged;

    String? remoteRelease;
    Object? changesError;
    try {
      remoteRelease = await _scriptureService.latestChangesVersion(work);
    } catch (error) {
      changesError = error;
    }
    if (generation != _generation || _removed) {
      return _WorkUpdateResult.unchanged;
    }

    final localRelease = _storedRelease(localVersions);

    if (changesError == null) {
      if (remoteRelease == null || remoteRelease.isEmpty) {
        _skipped++;
        _message = '無修訂紀錄，略過：$work';
        return _WorkUpdateResult.unchanged;
      }
      if (localRelease != null &&
          ScriptureUpdateService.normalizeRevision(remoteRelease) ==
              ScriptureUpdateService.normalizeRevision(localRelease)) {
        _skipped++;
        _message = '已是最新：$work';
        return _WorkUpdateResult.unchanged;
      }
    } else {
      WorkRemoteSignature remote;
      try {
        remote = await _scriptureService.headWork(work);
      } catch (error) {
        _failed++;
        _error = '$work：$error';
        return _WorkUpdateResult.failed;
      }
      if (generation != _generation || _removed) {
        return _WorkUpdateResult.unchanged;
      }
      if (remote.matchesLocal(localVersions.map((version) => version.ver))) {
        _skipped++;
        _message = '已是最新：$work';
        return _WorkUpdateResult.unchanged;
      }
    }

    _stage = UpdateStage.downloadingWorks;
    _message = remoteRelease != null && remoteRelease.isNotEmpty
        ? '更新經文：$work（$remoteRelease）'
        : '更新經文：$work';
    _notify(force: true);

    WorkArchive? archive;
    try {
      archive = await _scriptureService.downloadWork(
        work,
        filePrefix: CatalogCache.instance.lookupWorkFile(work) ?? '',
        onBytesReceived: _handleBytesReceived,
      );
    } catch (error) {
      debugPrint('Work update archive failed $work: $error');
    }
    if (generation != _generation || _removed) {
      return _WorkUpdateResult.unchanged;
    }

    final localJuans = localVersions.map((version) => version.juan).toSet();
    final byJuan = <String, CachedScriptureVolume>{
      if (archive != null)
        for (final volume in archive.volumes) volume.juan: volume,
    };
    final replacements = <CachedScriptureVolume>[];
    Object? lastError;
    for (final juan in localJuans) {
      final cached = byJuan[juan];
      if (cached != null) {
        replacements.add(cached);
        continue;
      }
      try {
        replacements.add(
          await _scriptureService.downloadVolume(
            work,
            juan,
            onBytesReceived: _handleBytesReceived,
          ),
        );
      } catch (error) {
        lastError = error;
        debugPrint('Work update volume failed $work:$juan: $error');
      }
    }

    if (generation != _generation || _removed) {
      return _WorkUpdateResult.unchanged;
    }
    if (replacements.isEmpty) {
      _failed++;
      _error = lastError == null ? '$work：沒有可更新的經卷' : '$work：$lastError';
      return _WorkUpdateResult.failed;
    }

    final replaced = await _downloads.replaceDownloadedVolumes(
      work,
      replacements,
      release: remoteRelease != null && remoteRelease.isNotEmpty
          ? remoteRelease
          : null,
    );
    if (replaced == 0) {
      _failed++;
      _error = '$work：寫入更新經卷失敗';
      return _WorkUpdateResult.failed;
    }
    _updated++;
    _message = '已更新：$work';
    return _WorkUpdateResult.updated;
  }

  /// 取所有經卷中最舊的版號；只要有一卷沒有記錄就視為舊資料。
  static String? _storedRelease(Iterable<LocalVersion> versions) {
    String? oldest;
    for (final version in versions) {
      final release = version.release?.trim();
      if (release == null || release.isEmpty) return null;
      if (oldest == null ||
          ScriptureUpdateService.revisionRank(release) <
              ScriptureUpdateService.revisionRank(oldest)) {
        oldest = release;
      }
    }
    return oldest;
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
      title: _isCatalogStage ? '正在更新經目' : '正在更新經文',
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
        title: _isCatalogStage ? '正在更新經目' : '正在更新經文',
        text: _notificationText(progress),
        progress: _notificationValue(progress),
        max: _notificationMax(progress),
      ),
    );
  }

  String _notificationText(UpdateProgress progress) {
    if (_isCatalogStage) return progress.message ?? '檢查經目更新…';
    final parts = <String>[
      if (progress.updatedWorks > 0) '已更新 ${progress.updatedWorks} 部',
      if (progress.totalWorks > 0)
        '已檢查 ${progress.checkedWorks}/${progress.totalWorks} 部',
      if (progress.currentWork != null) '目前：${progress.currentWork}',
    ];
    return parts.isEmpty ? '準備檢查經文…' : parts.join(' · ');
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
          'active': _taskActive,
          'catalog_done': _catalogDone,
          'pending': _pending,
          'checked': _checked,
          'updated': _updated,
          'skipped': _skipped,
          'failed': _failed,
          'release': _releaseVersion,
          'error': _error,
        }),
      );
    } catch (error) {
      debugPrint('Failed to persist update task: $error');
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
  }
}

final updateManager = UpdateManager();
