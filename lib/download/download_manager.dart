import 'dart:async';

import 'package:flutter/foundation.dart';

import '../scripture/cache.dart';
import '../scripture/offline_scan.dart';
import 'api_rate_limiter.dart';
import 'catalog_cache.dart';
import 'download_models.dart';
import 'download_notifications.dart';
import 'download_store.dart';
import 'scripture_update_service.dart';
import 'work_archive.dart';

class DownloadManager extends ChangeNotifier {
  DownloadManager({Future<String?> Function(String work)? releaseVersionLoader})
    : _releaseVersionLoader = releaseVersionLoader ?? _loadWorkChangesRelease;

  final Future<String?> Function(String work) _releaseVersionLoader;
  final List<DownloadGroup> _queue = [];
  final Map<String, LocalVersion> _versions = {};
  final Map<String, List<String>> _workJuans = {};
  bool _workJuansDirty = false;
  final List<String> _failedWorkIds = [];
  DownloadStatus _status = DownloadStatus.pending;
  DownloadProgress? _progress;
  bool _cancelled = false;
  int _completedCount = 0;
  int _failedCount = 0;
  int _completedJuans = 0;
  int _totalItems = 0;
  int _totalJuans = 0;
  final List<({DateTime time, int bytes})> _speedSamples = [];
  int _receivedBytes = 0;
  DateTime _lastSpeedUpdate = DateTime.fromMillisecondsSinceEpoch(0);

  List<DownloadGroup> get queue => List.unmodifiable(_queue);
  Map<String, LocalVersion> get versions => Map.unmodifiable(_versions);
  List<String> get failedWorkIds => List.unmodifiable(_failedWorkIds);
  DownloadStatus get status => _status;
  DownloadProgress? get progress => _progress;
  bool get isDownloading => _status == DownloadStatus.downloading;
  bool get hasQueuedItems =>
      _queue.any((group) => group.items.any((item) => !_isItemComplete(item)));
  bool get canResume => !isDownloading && hasQueuedItems;
  int get downloadedWorkCount => downloadedWorkIds.length;
  int get downloadedJuanCount => _versions.length;

  Set<String> get downloadedWorkIds =>
      _versions.keys.map((key) => key.split(':').first).toSet();

  /// 已完成全部經卷的作品數；與 [partialWorkCount] 分開呈現，避免和待下載
  /// 清單相加時重複計算部分下載的作品。
  int get completeWorkCount => downloadedWorkIds.where(isWorkDownloaded).length;

  int get partialWorkCount =>
      downloadedWorkIds.where(isWorkPartiallyDownloaded).length;

  List<LocalVersion> versionsForWork(String work) =>
      _versions.values.where((version) => version.work == work).toList();
  int get pendingWorkCount => _queue
      .expand((group) => group.items)
      .where((item) => !_isItemComplete(item))
      .length;
  int get pendingJuanCount => _queue
      .expand((group) => group.items)
      .fold<int>(0, (sum, item) => sum + pendingJuans(item).length);

  /// 最近兩秒的平均下載速度；沒有傳輸時回傳 0。
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

  void _handleBytesReceived(int bytes) {
    if (bytes <= 0) return;
    final now = DateTime.now();
    _receivedBytes += bytes;
    _speedSamples.add((time: now, bytes: _receivedBytes));
    final cutoff = now.subtract(const Duration(seconds: 2));
    while (_speedSamples.length > 2 &&
        _speedSamples.first.time.isBefore(cutoff)) {
      _speedSamples.removeAt(0);
    }
    if (now.difference(_lastSpeedUpdate) >= const Duration(milliseconds: 500)) {
      _lastSpeedUpdate = now;
      notifyListeners();
    }
  }

  Future<void> initialize() async {
    await CatalogCache.instance.load();
    final savedQueue = await downloadStore.loadQueue();
    final savedVersions = await downloadStore.loadVersions();
    final savedWorkJuans = await downloadStore.loadWorkJuans();
    _queue
      ..clear()
      ..addAll(_normalizeQueue(savedQueue));
    _versions
      ..clear()
      ..addAll(savedVersions);
    _workJuans
      ..clear()
      ..addAll(savedWorkJuans);
    _workJuansDirty = false;
    if (savedQueue.isNotEmpty) {
      await _saveQueue();
    }
    if (_queue.isNotEmpty &&
        _queue.any((g) => g.items.any((i) => !_isItemComplete(i)))) {
      _status = DownloadStatus.pending;
    }
    notifyListeners();
  }

  bool isWorkDownloaded(String work) {
    final juans = _expectedJuans(work);
    if (juans.isEmpty) return false;
    return juans.every((juan) => _versions.containsKey('$work:$juan'));
  }

  bool isWorkPartiallyDownloaded(String work) {
    final juans = _expectedJuans(work);
    if (juans.isEmpty) return false;
    final downloaded = juans.where((j) => _versions.containsKey('$work:$j'));
    return downloaded.isNotEmpty && downloaded.length < juans.length;
  }

  /// 經目卷號只是「1..N」的推定值；下載過的作品以壓縮檔解析出的真實卷號為準。
  List<String> _expectedJuans(String work) =>
      _workJuans[work] ??
      CatalogCache.instance.lookupWork(work)?.juans ??
      const [];

  List<String> _expectedJuansForItem(DownloadItem item) {
    final resolved = _workJuans[item.work];
    if (resolved != null) return resolved;
    if (item.juans.isNotEmpty) return item.juans;
    return _expectedJuans(item.work);
  }

  int _expectedJuanCount(DownloadItem item) {
    final count = _expectedJuansForItem(item).length;
    return count == 0 ? 1 : count;
  }

  List<String> _pendingJuans(String work, List<String> juans) =>
      juans.where((juan) => !_versions.containsKey('$work:$juan')).toList();

  static bool _sameJuans(List<String> left, List<String> right) {
    if (left.length != right.length) return false;
    for (var i = 0; i < left.length; i++) {
      if (left[i] != right[i]) return false;
    }
    return true;
  }

  void _adoptWorkJuans(String work, List<String> juans) {
    if (_sameJuans(_workJuans[work] ?? const <String>[], juans)) return;
    _workJuans[work] = List.unmodifiable(juans);
    _workJuansDirty = true;
  }

  bool _isItemComplete(DownloadItem item) => _expectedJuansForItem(
    item,
  ).every((juan) => _versions.containsKey('${item.work}:$juan'));

  bool isItemComplete(DownloadItem item) => _isItemComplete(item);

  List<String> pendingJuans(DownloadItem item) => _expectedJuansForItem(
    item,
  ).where((juan) => !_versions.containsKey('${item.work}:$juan')).toList();

  void addToQueue(List<DownloadGroup> groups) {
    if (groups.isEmpty) return;
    _queue
      ..clear()
      ..addAll(_normalizeQueue([..._queue, ...groups]));
    _saveQueue();
    notifyListeners();
  }

  /// 跨群組合併同一部作品，並去除重複的卷號。
  ///
  /// 重複提交下載時不會再產生重複的 work，舊佇列中的重複項目也會一併收斂。
  static List<DownloadGroup> _normalizeQueue(Iterable<DownloadGroup> groups) {
    final items = <String, DownloadItem>{};
    final workGroup = <String, String>{};
    final groupOrder = <String>[];
    final groupLabels = <String, String>{};

    for (final group in groups) {
      if (!groupLabels.containsKey(group.id)) {
        groupLabels[group.id] = group.label;
        groupOrder.add(group.id);
      }
      for (final item in group.items) {
        final work = item.work.trim();
        if (work.isEmpty) continue;
        final juans = _uniqueJuans(item.juans);
        final existing = items[work];
        if (existing == null) {
          items[work] = item.copyWith(juans: juans);
          workGroup.putIfAbsent(work, () => group.id);
          continue;
        }
        final merged = _uniqueJuans([...existing.juans, ...juans]);
        if (merged.length != existing.juans.length) {
          items[work] = existing.copyWith(juans: merged);
        }
      }
    }

    final itemsByGroup = <String, List<DownloadItem>>{
      for (final id in groupOrder) id: <DownloadItem>[],
    };
    for (final entry in items.entries) {
      itemsByGroup[workGroup[entry.key]]!.add(entry.value);
    }

    return [
      for (final id in groupOrder)
        if (itemsByGroup[id]!.isNotEmpty)
          DownloadGroup(
            id: id,
            label: _syncGroupLabel(groupLabels[id]!, itemsByGroup[id]!.length),
            items: itemsByGroup[id]!,
          ),
    ];
  }

  static List<String> _uniqueJuans(Iterable<String> juans) {
    final seen = <String>{};
    final unique = <String>[];
    for (final juan in juans) {
      final value = juan.trim();
      if (value.isEmpty || !seen.add(value)) continue;
      unique.add(value);
    }
    return unique;
  }

  static String _syncGroupLabel(String label, int itemCount) =>
      label.replaceFirst(RegExp(r'（\d+ 部）\s*$'), '（$itemCount 部）');

  void removeFromQueue(String groupId) {
    _queue.removeWhere((g) => g.id == groupId);
    _saveQueue();
    notifyListeners();
  }

  void clearQueue() {
    _queue.clear();
    _saveQueue();
    notifyListeners();
  }

  Future<void> startDownload() async {
    if (_status == DownloadStatus.downloading) return;
    _cancelled = false;
    _completedCount = 0;
    _failedCount = 0;
    _failedWorkIds.clear();
    _completedJuans = 0;
    _totalItems = 0;
    _totalJuans = 0;
    _speedSamples.clear();
    _receivedBytes = 0;
    _lastSpeedUpdate = DateTime.fromMillisecondsSinceEpoch(0);
    _status = DownloadStatus.downloading;
    _progress = const DownloadProgress(
      totalItems: 0,
      completedItems: 0,
      failedItems: 0,
      totalJuans: 0,
      completedJuans: 0,
    );
    unawaited(_startNotification());
    notifyListeners();

    final attempted = <String>{};
    while (!_cancelled) {
      final items = _collectPendingItems(attempted);
      if (items.isEmpty) break;
      for (final item in items) {
        attempted.add(item.work);
      }
      _totalItems += items.length;
      _totalJuans += items.fold<int>(
        0,
        (sum, item) => sum + _expectedJuanCount(item),
      );
      _progress = _buildProgress(
        currentWork: _progress?.currentWork,
        currentJuan: _progress?.currentJuan,
      );
      _updateNotification();
      notifyListeners();
      await _processDownloadQueue(items);
    }

    await _saveWorkJuansIfDirty();

    // 索引建置在背景 worker 裡追進度：收完才宣告結束，否則使用者以為下載好了，
    // 第一次搜還是得自己把沒建完的卷補一遍。
    await offlineIndexQueue.flush();

    _status = _cancelled
        ? DownloadStatus.cancelled
        : _failedCount > 0
        ? DownloadStatus.failed
        : DownloadStatus.completed;
    _progress = _buildProgress(
      currentWork: _progress?.currentWork,
      currentJuan: _progress?.currentJuan,
    );
    notifyListeners();
    unawaited(downloadNotifications.stop());
  }

  String _notificationText(DownloadProgress progress) {
    final counts =
        '${progress.completedItems}/${progress.totalItems} 部 · '
        '${progress.completedJuans}/${progress.totalJuans} 卷';
    final current = progress.currentWork;
    if (current == null) return counts;
    final juan = progress.currentJuan;
    return juan == null ? '$current · $counts' : '$current 卷 $juan · $counts';
  }

  Future<void> _startNotification() async {
    await downloadNotifications.requestPermission();
    final progress = _progress;
    if (_status != DownloadStatus.downloading || progress == null) return;
    await downloadNotifications.start(
      title: '正在下載經文',
      text: _notificationText(progress),
      progress: 0,
      max: 1,
    );
  }

  void _updateNotification() {
    final progress = _progress;
    if (_status != DownloadStatus.downloading || progress == null) return;
    final max = progress.totalJuans > 0
        ? progress.totalJuans
        : progress.totalItems;
    final value = progress.totalJuans > 0
        ? progress.completedJuans
        : progress.completedItems;
    unawaited(
      downloadNotifications.update(
        title: '正在下載經文',
        text: _notificationText(progress),
        progress: value,
        max: max < 1 ? 1 : max,
      ),
    );
  }

  DownloadProgress _buildProgress({String? currentWork, String? currentJuan}) =>
      DownloadProgress(
        totalItems: _totalItems,
        completedItems: _completedCount,
        failedItems: _failedCount,
        totalJuans: _totalJuans,
        completedJuans: _completedJuans,
        currentWork: currentWork,
        currentJuan: currentJuan,
      );

  List<DownloadItem> _collectPendingItems(Set<String> attempted) {
    final items = <DownloadItem>[];
    for (final group in _queue) {
      for (final item in group.items) {
        if (attempted.contains(item.work) || _isItemComplete(item)) continue;
        items.add(item);
      }
    }
    return items;
  }

  Future<void> _processDownloadQueue(List<DownloadItem> items) async {
    for (final item in items) {
      if (_cancelled) break;
      await _downloadItem(item);
    }
  }

  Future<void> _downloadItem(DownloadItem item) async {
    final entry = CatalogCache.instance.lookupWork(item.work);
    var expected = _expectedJuansForItem(item);
    var pending = _pendingJuans(item.work, expected);
    if (pending.isEmpty) {
      _completedCount++;
      notifyListeners();
      return;
    }
    var failed = false;
    final existingVersions = versionsForWork(item.work);
    final release = await _resolveInitialRelease(item.work, existingVersions);
    if (_cancelled) return;

    _progress = _buildProgress(currentWork: item.work);
    _updateNotification();
    notifyListeners();

    WorkArchive? archive;
    final filePrefix =
        entry?.file ?? CatalogCache.instance.lookupWorkFile(item.work) ?? '';
    try {
      archive = await apiRateLimiter.run(
        () => fetchWorkArchive(
          item.work,
          filePrefix: filePrefix,
          onBytesReceived: _handleBytesReceived,
        ),
      );
    } catch (e) {
      debugPrint('Work archive download failed ${item.work}: $e');
    }

    if (archive == null || archive.volumes.isEmpty) {
      // 壓縮檔失敗時改用經目 TOC 的真實卷號，避免拿 1..N 反覆打單卷 API。
      try {
        final tocJuans = await apiRateLimiter.run(
          () => fetchWorkTocJuans(item.work),
        );
        if (tocJuans.isNotEmpty) {
          if (!_sameJuans(expected, tocJuans)) {
            _totalJuans += tocJuans.length - expected.length;
            expected = tocJuans;
            _adoptWorkJuans(item.work, tocJuans);
          }
          pending = _pendingJuans(item.work, expected);
        }
      } catch (e) {
        debugPrint('Work TOC lookup failed ${item.work}: $e');
      }
    }

    if (archive != null && archive.volumes.isNotEmpty) {
      // 壓縮檔內的卷號才是原書真實卷次；經目標題的 (N卷) 只是卷數。
      final archiveJuans = archive.volumes
          .map((volume) => volume.juan)
          .toList();
      if (!_sameJuans(expected, archiveJuans)) {
        _totalJuans += archiveJuans.length - expected.length;
        expected = archiveJuans;
        _adoptWorkJuans(item.work, archiveJuans);
      }
      pending = _pendingJuans(item.work, expected);
      final byJuan = {
        for (final volume in archive.volumes) volume.juan: volume,
      };
      // 不在 1..N 內的真實卷也要落地，否則這部作品永遠補不齊。
      for (final juan in expected) {
        if (_cancelled) return;
        if (_versions.containsKey('${item.work}:$juan')) continue;
        final volume = byJuan[juan];
        if (volume == null) continue;
        if (!await _storeVolume(item.work, volume, release: release)) {
          failed = true;
        }
      }
    }

    // 壓縮檔缺少部分經卷時，退回單卷 API 補齊。
    for (final juan in pending) {
      if (_cancelled) return;
      final key = '${item.work}:$juan';
      if (_versions.containsKey(key)) continue;

      _progress = _buildProgress(currentWork: item.work, currentJuan: juan);
      _updateNotification();
      notifyListeners();

      try {
        final volume = await apiRateLimiter.run(
          () => fetchScriptureVolume(
            item.work,
            juan,
            onBytesReceived: _handleBytesReceived,
          ),
        );
        if (!await _storeVolume(item.work, volume, release: release)) {
          failed = true;
        }
      } catch (e) {
        debugPrint('Download failed $key: $e');
        failed = true;
      }
    }

    if (failed) {
      _failedCount++;
      if (!_failedWorkIds.contains(item.work)) {
        _failedWorkIds.add(item.work);
      }
    } else {
      _completedCount++;
    }
    _progress = _buildProgress(
      currentWork: _progress?.currentWork,
      currentJuan: _progress?.currentJuan,
    );
    _updateNotification();
    notifyListeners();
  }

  Future<bool> _storeVolume(
    String work,
    CachedScriptureVolume volume, {
    String? release,
  }) async {
    try {
      final path = await scriptureVolumeStore.write(volume);
      // 經卷一落地就把搜尋索引排在後面：攢著到下載結束才建的話，
      // 使用者第一次搜要把整藏重解析一遍。
      await offlineIndexQueue.add(work, volume.juan, path);
      _versions['$work:${volume.juan}'] = LocalVersion(
        work: work,
        juan: volume.juan,
        ver: volume.contentVersion ?? 'unknown',
        release: release,
        savedAt: DateTime.now().toUtc(),
      );
      await _saveVersions();
      _completedJuans++;
      _progress = _buildProgress(currentWork: work, currentJuan: volume.juan);
      _updateNotification();
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('Failed to store $work:${volume.juan}: $e');
      return false;
    }
  }

  /// 以更新的內容覆寫已下載的經卷；未下載的卷不會被新增。
  Future<int> replaceDownloadedVolumes(
    String work,
    Iterable<CachedScriptureVolume> volumes, {
    String? release,
  }) async {
    final existing = versionsForWork(
      work,
    ).map((version) => version.juan).toSet();
    if (existing.isEmpty) return 0;
    var replaced = 0;
    for (final volume in volumes) {
      if (!existing.contains(volume.juan)) continue;
      try {
        final path = await scriptureVolumeStore.write(volume);
        await offlineIndexQueue.add(work, volume.juan, path);
        _versions['$work:${volume.juan}'] = LocalVersion(
          work: work,
          juan: volume.juan,
          ver: volume.contentVersion ?? 'unknown',
          release: release ?? _versions['$work:${volume.juan}']?.release,
          savedAt: DateTime.now().toUtc(),
        );
        replaced++;
      } catch (e) {
        debugPrint('Failed to update $work:${volume.juan}: $e');
      }
    }
    if (replaced > 0) {
      // 覆寫過的卷要把重建好的索引收乾淨，更新才算真的結束。
      await offlineIndexQueue.flush();
      await _saveVersions();
      notifyListeners();
    }
    return replaced;
  }

  /// 初次下載時查詢 changes 取得 release；部分下載時沿用既有的共用 release。
  Future<String?> _resolveInitialRelease(
    String work,
    List<LocalVersion> existingVersions,
  ) async {
    if (existingVersions.isEmpty) {
      try {
        return await _releaseVersionLoader(work);
      } catch (error) {
        debugPrint('Changes lookup failed for $work: $error');
        return null;
      }
    }
    return _sharedRelease(existingVersions);
  }

  /// 取所有經卷共用的 release；只要有一卷沒有記錄或版本不一致就回傳 null。
  static String? _sharedRelease(Iterable<LocalVersion> versions) {
    String? shared;
    for (final version in versions) {
      final value = version.release?.trim();
      if (value == null || value.isEmpty) return null;
      if (shared == null) {
        shared = value;
      } else if (shared != value) {
        return null;
      }
    }
    return shared;
  }

  void cancelDownload() {
    _cancelled = true;
    _status = DownloadStatus.cancelled;
    notifyListeners();
    unawaited(downloadNotifications.stop());
  }

  void resumeDownload() {
    if (!isDownloading && hasQueuedItems) {
      unawaited(startDownload());
    }
  }

  Future<void> _saveQueue() => downloadStore.saveQueue(_queue);
  Future<void> _saveVersions() => downloadStore.saveVersions(_versions);

  Future<void> _saveWorkJuansIfDirty() async {
    if (!_workJuansDirty) return;
    _workJuansDirty = false;
    await downloadStore.saveWorkJuans(_workJuans);
  }
}

/// 初次下載時以該作品的 changes 版號作為 release。
Future<String?> _loadWorkChangesRelease(String work) async {
  try {
    return await ScriptureUpdateService().latestChangesVersion(work);
  } catch (error) {
    debugPrint('Changes lookup failed for $work: $error');
    return null;
  }
}

final downloadManager = DownloadManager();
