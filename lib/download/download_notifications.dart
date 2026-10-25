import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 透過 Android 前景服務在下拉通知欄顯示下載進度。
class DownloadNotificationService {
  static const _channel = MethodChannel('xuefo/download_notifications');

  /// 使用者點擊「正在下載經文」通知時觸發。
  VoidCallback? onOpenDownloadManager;

  bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  void initialize() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'openDownloadManager') {
        onOpenDownloadManager?.call();
      }
    });
  }

  /// 冷啟動時取出原生端暫存的「開啟下載管理」請求。
  Future<bool> consumePendingOpenRequest() async {
    if (!_supported) return false;
    try {
      return await _channel.invokeMethod<bool>('consumeOpenDownloadManager') ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (error) {
      debugPrint('讀取通知開啟請求失敗：${error.message}');
      return false;
    }
  }

  Future<void> requestPermission() => _invoke('requestPermission');

  Future<void> start({
    required String title,
    required String text,
    required int progress,
    required int max,
  }) => _invoke('start', {
    'title': title,
    'text': text,
    'progress': progress,
    'max': max,
  });

  Future<void> update({
    required String title,
    required String text,
    required int progress,
    required int max,
  }) => _invoke('update', {
    'title': title,
    'text': text,
    'progress': progress,
    'max': max,
  });

  Future<void> stop() => _invoke('stop');

  Future<void> _invoke(String method, [Map<String, Object?>? arguments]) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // 舊安裝或非 Android 平台沒有對應的服務。
    } on PlatformException catch (error) {
      debugPrint('下載通知更新失敗：${error.message}');
    }
  }
}

var downloadNotifications = DownloadNotificationService();
