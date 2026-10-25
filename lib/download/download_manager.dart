import 'dart:async';

import 'package:flutter/foundation.dart';

import '../scripture/cache.dart';
import 'api_rate_limiter.dart';
import 'catalog_cache.dart';
import 'download_models.dart';
import 'download_notifications.dart';
import 'download_store.dart';
import 'work_archive.dart';

class DownloadManager extends ChangeNotifier {
  final List<DownloadGroup> _queue = [];
  final Map<String, LocalVersion> _versions = {};
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
  DownloadStatus get status => _status;
  DownloadProgress? get progress => _progress;
  bool get isDownloading => _status == DownloadStatus.downloading;
  bool get hasQueuedItems =>
      _queue.any((group) => group.items.any((item) => !_isItemComplete(item)));
  bool get canResume => !isDownloading && hasQueuedItems;
  int get downloadedWorkCount =>
      _versions.keys.map((key) => key.split(':').first).toSet().length;
  int get downloadedJuanCount => _versions.length;
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
    _queue
      ..clear()
      ..addAll(_normalizeQueue(savedQueue));
    _versions
      ..clear()
      ..addAll(savedVersions);
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
    final entry = CatalogCache.instance.lookupWork(work);
    if (entry == null) return false;
    return entry.juans.every((juan) => _versions.containsKey('$work:$juan'));
  }

  bool isWorkPartiallyDownloaded(String work) {
    final entry = CatalogCache.instance.lookupWork(work);
    if (entry == null) return false;
    final downloaded = entry.juans.where(
      (j) => _versions.containsKey('$work:$j'),
    );
    return downloaded.isNotEmpty && downloaded.length < entry.juans.length;
  }

  bool _isItemComplete(DownloadItem item) {
    return item.juans.every(
      (juan) => _versions.containsKey('${item.work}:$juan'),
    );
  }

  bool isItemComplete(DownloadItem item) => _isItemComplete(item);

  List<String> pendingJuans(DownloadItem item) => item.juans
      .where((juan) => !_versions.containsKey('${item.work}:$juan'))
      .toList();

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
      _totalJuans += items.fold<int>(0, (sum, item) => sum + item.totalJuans);
      _progress = _buildProgress(
        currentWork: _progress?.currentWork,
        currentJuan: _progress?.currentJuan,
      );
      _updateNotification();
      notifyListeners();
      await _processDownloadQueue(items);
    }

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
    final juans = entry?.juans ?? item.juans;
    final pending = juans
        .where((juan) => !_versions.containsKey('${item.work}:$juan'))
        .toList();
    if (pending.isEmpty) {
      _completedCount++;
      notifyListeners();
      return;
    }
    var failed = false;

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

    if (archive != null) {
      final byJuan = {
        for (final volume in archive.volumes) volume.juan: volume,
      };
      for (final juan in pending) {
        if (_cancelled) return;
        final volume = byJuan[juan];
        if (volume == null) continue;
        if (!await _storeVolume(item.work, volume)) failed = true;
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
        if (!await _storeVolume(item.work, volume)) failed = true;
      } catch (e) {
        debugPrint('Download failed $key: $e');
        failed = true;
      }
    }

    if (failed) {
      _failedCount++;
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

  Future<bool> _storeVolume(String work, CachedScriptureVolume volume) async {
    try {
      await scriptureVolumeStore.write(volume);
      _versions['$work:${volume.juan}'] = LocalVersion(
        work: work,
        juan: volume.juan,
        ver: volume.contentVersion ?? 'unknown',
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
}

final downloadManager = DownloadManager();
