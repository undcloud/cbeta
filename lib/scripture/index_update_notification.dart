import 'dart:async';

import '../download/download_notifications.dart';
import 'index_update_service.dart';

/// 索引重建期間沿用下載用的前景服務通知，讓 App 退到背景後較不易被回收。
///
/// 與下載／經文更新共用同一個通知與服務；對方正在跑時完全不碰通知，
/// 避免互相覆蓋或提早停掉前景服務。
class IndexUpdateNotification {
  IndexUpdateNotification({
    IndexUpdateService? service,
    DownloadNotificationService? notifications,
  }) : _service = service ?? indexUpdateService,
       _notifications = notifications ?? downloadNotifications;

  static const _title = '正在更新搜尋索引';

  final IndexUpdateService _service;
  final DownloadNotificationService _notifications;

  /// 下載或經文更新是否正在使用同一個通知。
  bool Function() otherTaskActive = () => false;

  bool _initialized = false;
  bool _attempted = false;
  bool _ownsNotification = false;
  DateTime _lastUpdate = DateTime.fromMillisecondsSinceEpoch(0);

  void initialize() {
    if (_initialized) return;
    _initialized = true;
    _service.addListener(_onProgressChanged);
  }

  void dispose() {
    if (!_initialized) return;
    _initialized = false;
    _service.removeListener(_onProgressChanged);
    if (_ownsNotification && !otherTaskActive()) {
      unawaited(_notifications.stop());
    }
    _ownsNotification = false;
  }

  void _onProgressChanged() {
    final progress = _service.progress;
    if (progress.phase == IndexUpdatePhase.running) {
      if (otherTaskActive()) return;
      if (!_ownsNotification) {
        if (_attempted) return;
        _attempted = true;
        _ownsNotification = true;
        unawaited(_start(progress));
        return;
      }
      final now = DateTime.now();
      if (now.difference(_lastUpdate) < const Duration(milliseconds: 800)) {
        return;
      }
      _lastUpdate = now;
      unawaited(
        _notifications.update(
          title: _title,
          text: _text(progress),
          progress: progress.done,
          max: _max(progress),
        ),
      );
      return;
    }
    _attempted = false;
    if (!_ownsNotification) return;
    _ownsNotification = false;
    if (otherTaskActive()) return;
    unawaited(_notifications.stop());
  }

  Future<void> _start(IndexUpdateProgress progress) async {
    await _notifications.requestPermission();
    if (!_ownsNotification || otherTaskActive()) return;
    _lastUpdate = DateTime.now();
    await _notifications.start(
      title: _title,
      text: _text(progress),
      progress: progress.done,
      max: _max(progress),
    );
  }

  String _text(IndexUpdateProgress progress) => progress.message ?? '正在更新搜尋索引…';

  int _max(IndexUpdateProgress progress) =>
      progress.total < 1 ? 1 : progress.total;
}

final indexUpdateNotification = IndexUpdateNotification();
