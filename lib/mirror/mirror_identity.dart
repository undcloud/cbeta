import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// 裝置與下載會話識別。
///
/// 同一個 WiFi 下的多部裝置共用公網 IP，伺服器不能只看 IP 限流；
/// `deviceId` 是首次啟動時生成的隨機 UUID，只用於公平排隊與去重統計。
class MirrorIdentity {
  static const _deviceKey = 'mirror_device_id';
  static String? _deviceId;

  static Future<String> deviceId() async {
    final cached = _deviceId;
    if (cached != null && cached.isNotEmpty) return cached;
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_deviceKey);
    if (saved != null && saved.isNotEmpty) return _deviceId = saved;
    final generated = _randomHex(16);
    await prefs.setString(_deviceKey, generated);
    return _deviceId = generated;
  }

  static String newSessionId() => _randomHex(12);

  static String _randomHex(int bytes) {
    final random = Random.secure();
    final buffer = StringBuffer();
    for (var i = 0; i < bytes; i++) {
      buffer.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}
