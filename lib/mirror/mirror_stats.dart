import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'mirror_config.dart';
import 'mirror_identity.dart';

/// 上報鏡像事件；失敗不影響下載流程。
class MirrorStats {
  static Future<void> report(
    MirrorConfig config, {
    required String event,
    required String session,
    String release = '',
    int bytes = 0,
    String detail = '',
  }) async {
    if (!config.enabled || config.baseUrl.isEmpty) return;
    try {
      final device = await MirrorIdentity.deviceId();
      final client = http.Client();
      try {
        await client
            .post(
              config.eventUri,
              headers: const {'Content-Type': 'application/json'},
              body: jsonEncode({
                'event': event,
                'device': device,
                'session': session,
                'release': release,
                'bytes': bytes,
                'detail': detail,
              }),
            )
            .timeout(const Duration(seconds: 8));
      } finally {
        client.close();
      }
    } catch (error) {
      debugPrint('鏡像事件上報失敗: $error');
    }
  }
}
