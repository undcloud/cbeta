import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// 鏡像服務配置，優先順序：Gitee 配置 → SharedPreferences 快取 → 內建備用值。
@immutable
class MirrorConfig {
  const MirrorConfig({
    required this.enabled,
    required this.baseUrl,
    this.zipPath = '/cbeta/html_full.zip',
    this.release = '',
  });

  final bool enabled;
  final String baseUrl;
  final String zipPath;
  final String release;

  String get normalizedBaseUrl => baseUrl.endsWith('/')
      ? baseUrl.substring(0, baseUrl.length - 1)
      : baseUrl;

  Uri get zipUri => Uri.parse('$normalizedBaseUrl$zipPath');
  Uri get eventUri => Uri.parse('$normalizedBaseUrl/api/mirror/event');
  Uri get statsUri => Uri.parse('$normalizedBaseUrl/api/mirror/stats');

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'base_url': baseUrl,
    'zip_path': zipPath,
    'release': release,
  };

  factory MirrorConfig.fromJson(Map<String, dynamic> json) => MirrorConfig(
    enabled: json['enabled'] as bool? ?? true,
    baseUrl: (json['base_url'] as String? ?? '').trim(),
    zipPath: (json['zip_path'] as String? ?? '/cbeta/html_full.zip').trim(),
    release: (json['release'] as String? ?? '').trim(),
  );

  static const fallback = MirrorConfig(
    enabled: true,
    baseUrl: 'http://59.110.91.183:5000',
    release: '',
  );
}

class MirrorConfigService {
  static const _configUrl =
      'https://gitee.com/undclouds/cbeta/raw/main/config/mirror_server.json';
  static const _cacheKey = 'mirror_config_json';
  static const _lastFetchKey = 'mirror_config_last_fetch';
  static const _cacheDuration = Duration(hours: 24);

  static MirrorConfig? _cached;

  static Future<MirrorConfig> load({bool force = false}) async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now().millisecondsSinceEpoch;
    final lastFetch = prefs.getInt(_lastFetchKey) ?? 0;
    final cachedRaw = prefs.getString(_cacheKey);

    if (!force &&
        cachedRaw != null &&
        now - lastFetch < _cacheDuration.inMilliseconds) {
      final parsed = _tryParse(cachedRaw);
      if (parsed != null) return _cached = _sanitize(parsed);
    }

    try {
      final response = await http
          .get(Uri.parse(_configUrl))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final parsed = _tryParse(response.body);
        if (parsed != null) {
          final config = _sanitize(parsed);
          await prefs.setString(_cacheKey, response.body);
          await prefs.setInt(_lastFetchKey, now);
          return _cached = config;
        }
      }
    } catch (error) {
      debugPrint('讀取鏡像配置失敗: $error');
    }

    if (cachedRaw != null) {
      final parsed = _tryParse(cachedRaw);
      if (parsed != null) return _cached = _sanitize(parsed);
    }
    return _cached = MirrorConfig.fallback;
  }

  /// 啟動時使用：只讀本機快取，不發網路請求。
  static Future<MirrorConfig> loadCached() async {
    final cached = _cached;
    if (cached != null) return cached;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey);
      if (raw != null) {
        final parsed = _tryParse(raw);
        if (parsed != null) return _cached = _sanitize(parsed);
      }
    } catch (error) {
      debugPrint('讀取鏡像配置快取失敗: $error');
    }
    return _cached = MirrorConfig.fallback;
  }

  static MirrorConfig? _tryParse(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return MirrorConfig.fromJson(decoded);
      }
    } catch (_) {}
    return null;
  }

  static MirrorConfig _sanitize(MirrorConfig config) {
    if (config.baseUrl.isEmpty) {
      return MirrorConfig(
        enabled: config.enabled,
        baseUrl: MirrorConfig.fallback.baseUrl,
        zipPath: config.zipPath,
        release: config.release,
      );
    }
    return config;
  }
}
