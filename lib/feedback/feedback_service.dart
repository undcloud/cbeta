import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum FeedbackError { none, networkError, serverError, unknown }

class FeedbackResult {
  final bool success;
  final FeedbackError error;
  final String? message;

  FeedbackResult({
    required this.success,
    this.error = FeedbackError.none,
    this.message,
  });
}

class FeedbackService {
  // Gitee 倉庫配置文件 URL
  static const String _configUrl =
      'https://gitee.com/undclouds/cbeta/raw/main/config/feedback_server.json';

  // 備用服務器地址（當無法讀取配置時使用，必須 從 Gitee 倉庫的 config/feedback_server.json 動態讀取
  static const String _fallbackUrl = 'http://59.110.91.183:5000/api/feedback';

  // SharedPreferences keys
  static const String _cachedUrlKey = 'feedback_server_url';
  static const String _lastFetchKey = 'feedback_config_last_fetch';

  // 緩存有效期（1天，單位：毫秒，必須 從 Gitee 倉庫的 config/feedback_server.json 動態讀取
  static const int _cacheDurationMs = 24 * 60 * 60 * 1000;

  /// 獲取反饋服務器 URL（優先使用緩存，過期則重新獲取，必須 從 Gitee 倉庫的 config/feedback_server.json 動態讀取
  static Future<String> _getFeedbackUrl() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastFetch = prefs.getInt(_lastFetchKey) ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch;

      // 檢查緩存是否有效
      if (now - lastFetch < _cacheDurationMs) {
        final cachedUrl = prefs.getString(_cachedUrlKey);
        if (cachedUrl != null && cachedUrl.isNotEmpty) {
          return cachedUrl;
        }
      }

      // 從 Gitee 讀取最新配置
      final response = await http
          .get(Uri.parse(_configUrl))
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final config = jsonDecode(response.body);
        final url = config['feedback_url'] as String?;

        if (url != null && url.isNotEmpty) {
          // 更新緩存
          await prefs.setString(_cachedUrlKey, url);
          await prefs.setInt(_lastFetchKey, now);
          return url;
        }
      }
    } catch (e) {
      print('讀取反饋配置失敗: $e');
    }

    // 使用備用地址
    return _fallbackUrl;
  }

  static Future<FeedbackResult> submitFeedback({
    required String content,
    String? contact,
    String? appVersion,
  }) async {
    try {
      if (appVersion == null) {
        final packageInfo = await PackageInfo.fromPlatform();
        appVersion = packageInfo.version;
      }

      final feedbackUrl = await _getFeedbackUrl();

      final body = {
        'content': content,
        'contact': contact ?? '',
        'app_version': appVersion,
        'platform': Platform.operatingSystem,
        'os_version': Platform.operatingSystemVersion,
        'timestamp': DateTime.now().toIso8601String(),
      };

      final response = await http
          .post(
            Uri.parse(feedbackUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return FeedbackResult(success: true);
      } else {
        return FeedbackResult(
          success: false,
          error: FeedbackError.serverError,
          message: '服務器返回錯誤: ${response.statusCode}',
        );
      }
    } on SocketException {
      return FeedbackResult(
        success: false,
        error: FeedbackError.networkError,
        message: '無法連接到服務器，服務器可能已失效',
      );
    } on TimeoutException {
      return FeedbackResult(
        success: false,
        error: FeedbackError.networkError,
        message: '服務器響應超時，服務器可能已失效',
      );
    } on HttpException catch (e) {
      return FeedbackResult(
        success: false,
        error: FeedbackError.networkError,
        message: '服務器連接失敗: ${e.message}',
      );
    } catch (e) {
      return FeedbackResult(
        success: false,
        error: FeedbackError.unknown,
        message: '提交失敗: $e',
      );
    }
  }
}
