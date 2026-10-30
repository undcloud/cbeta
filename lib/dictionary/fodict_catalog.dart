import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

@immutable
class FodictRemoteDictionary {
  const FodictRemoteDictionary({
    required this.id,
    required this.name,
    required this.version,
    required this.entries,
    required this.datSize,
    required this.zipSize,
    required this.updatedAt,
    required this.file,
    required this.downloadUrl,
    required this.bundled,
    required this.available,
  });

  final String id;
  final String name;
  final String version;
  final int entries;
  final int datSize;
  final int zipSize;
  final String updatedAt;
  final String file;
  final String downloadUrl;
  final bool bundled;
  final bool available;

  DateTime? get updatedAtDate => DateTime.tryParse(updatedAt)?.toUtc();
}

class FodictCatalogException implements Exception {
  const FodictCatalogException(this.message);

  final String message;

  @override
  String toString() => message;
}

class FodictCatalogService {
  FodictCatalogService._();

  static final FodictCatalogService instance = FodictCatalogService._();

  static const _manifestUrls = [
    'https://gitee.com/undclouds/cbeta-fodict/raw/master/fodict_manifest.json',
    'https://raw.githubusercontent.com/undcloud/cbeta-fodict/main/fodict_manifest.json',
  ];

  List<FodictRemoteDictionary>? _cache;
  Future<List<FodictRemoteDictionary>>? _inflight;

  Future<List<FodictRemoteDictionary>> load({bool refresh = false}) async {
    if (!refresh && _cache != null) return _cache!;
    final inflight = _inflight;
    if (inflight != null) return inflight;

    final future = _fetch(refresh: refresh);
    _inflight = future;
    try {
      final dictionaries = await future;
      _cache = dictionaries;
      return dictionaries;
    } finally {
      _inflight = null;
    }
  }

  Future<List<FodictRemoteDictionary>> _fetch({required bool refresh}) async {
    Object? lastError;
    for (final url in _manifestUrls) {
      try {
        final uri = Uri.parse(url);
        final target = refresh
            ? uri.replace(
                queryParameters: {
                  ...uri.queryParameters,
                  't': '${DateTime.now().millisecondsSinceEpoch}',
                },
              )
            : uri;
        final response = await http
            .get(target, headers: const {'User-Agent': 'xuefo-app'})
            .timeout(const Duration(seconds: 20));
        if (response.statusCode != 200) {
          lastError = 'HTTP ${response.statusCode}';
          continue;
        }
        return _parse(response.bodyBytes);
      } catch (error) {
        lastError = error;
      }
    }
    throw FodictCatalogException('無法取得詞典清單：$lastError');
  }

  List<FodictRemoteDictionary> _parse(List<int> bytes) {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic>) {
      throw const FodictCatalogException('詞典清單格式錯誤');
    }
    final rawList = decoded['dictionaries'];
    if (rawList is! List) {
      throw const FodictCatalogException('詞典清單缺少 dictionaries');
    }

    final dictionaries = <FodictRemoteDictionary>[];
    for (final raw in rawList.whereType<Map<String, dynamic>>()) {
      final id = (raw['id'] as String? ?? '').trim();
      if (!_validId.hasMatch(id)) continue;

      final file = (raw['file'] as String? ?? '$id.zip').trim();
      final downloadUrl = (raw['download_url'] as String? ?? '').trim();
      final bundled = raw['bundled'] == true;
      final trustedUrl = _isTrustedUrl(downloadUrl);
      // 是否「可下載」只看有無受信任的下載連結；遠端清單的 bundled 欄位不可信，
      // 內建與否一律由 App 的 assetDictionaryIds（downloadManager.isBundled）判定。
      final available = trustedUrl;

      dictionaries.add(
        FodictRemoteDictionary(
          id: id,
          name: (raw['name'] as String? ?? id).trim(),
          version: (raw['version'] as String? ?? '').trim(),
          entries: _readInt(raw['entries']),
          datSize: _readInt(raw['dat_size']),
          zipSize: _readInt(raw['zip_size']),
          updatedAt: (raw['updated_at'] as String? ?? '').trim(),
          file: file,
          downloadUrl: downloadUrl,
          bundled: bundled,
          available: available,
        ),
      );
    }

    if (dictionaries.isEmpty) {
      throw const FodictCatalogException('詞典清單為空');
    }
    dictionaries.sort((a, b) => a.id.compareTo(b.id));
    return dictionaries;
  }

  static final _validId = RegExp(r'^[0-9A-Za-z][0-9A-Za-z._-]*$');

  static bool _isTrustedUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return false;
    final host = uri.host.toLowerCase();
    return host == 'gitee.com' ||
        host.endsWith('.gitee.com') ||
        host == 'github.com' ||
        host.endsWith('.github.com') ||
        host == 'githubusercontent.com' ||
        host.endsWith('.githubusercontent.com');
  }

  static int _readInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('$value') ?? 0;
  }
}
