import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 把整個 Task 退到背景（保留 Activity 與 Flutter 引擎），而不是結束行程。
///
/// Android 的根頁面返回鍵改走這裡，讓下載、經文更新與索引重建能繼續跑。
Future<void> moveTaskToBack() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
  try {
    await _channel.invokeMethod<void>('moveTaskToBack');
  } on MissingPluginException {
    // 舊安裝沒有對應的原生實作。
  } on PlatformException catch (error) {
    debugPrint('切換到背景失敗：${error.message}');
  }
}

const _channel = MethodChannel('xuefo/app_lifecycle');
