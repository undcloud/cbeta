import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../scripture/cache.dart';
import 'api_rate_limiter.dart';
import 'work_archive.dart';

@immutable
class WorkRemoteSignature {
  const WorkRemoteSignature({
    this.etag = '',
    this.lastModified = '',
    this.contentLength,
  });

  final String etag;
  final String lastModified;
  final int? contentLength;

  String get signature => etag.isNotEmpty ? etag : lastModified;

  bool matchesLocal(Iterable<String> localVersions) {
    final value = signature;
    if (value.isEmpty) return false;
    var hasVersion = false;
    for (final version in localVersions) {
      if (version.isEmpty) continue;
      hasVersion = true;
      if (version != value) return false;
    }
    return hasVersion;
  }
}

class ScriptureUpdateService {
  ScriptureUpdateService({http.Client Function()? clientFactory})
    : _clientFactory = clientFactory ?? http.Client.new;

  final http.Client Function() _clientFactory;

  /// 以 HEAD 取得作品壓縮檔的遠端簽章；不下載經文內容。
  Future<WorkRemoteSignature> headWork(String work) async {
    final client = _clientFactory();
    try {
      final response = await apiRateLimiter.run(
        () => client
            .head(
              Uri.https(
                'cbdata.dila.edu.tw',
                '/stable/download/html/$work.html.zip',
              ),
            )
            .timeout(const Duration(seconds: 30)),
      );
      if (response.statusCode != 200) {
        throw Exception('檢查經文更新失敗：HTTP ${response.statusCode}');
      }
      return WorkRemoteSignature(
        etag: (response.headers['etag'] ?? '').replaceAll('"', '').trim(),
        lastModified: response.headers['last-modified']?.trim() ?? '',
        contentLength: response.contentLength,
      );
    } finally {
      client.close();
    }
  }

  /// 取得該作品在 CBETA 修訂紀錄中的最新版本，例如 2026.R2。
  ///
  /// 查詢失敗會拋出例外；只有查詢成功但沒有修訂紀錄時才回傳 null。
  Future<String?> latestChangesVersion(String work) async {
    final client = _clientFactory();
    try {
      final response = await apiRateLimiter.run(
        () => client
            .get(
              Uri.https('cbdata.dila.edu.tw', '/stable/changes', {
                'work': work,
              }),
            )
            .timeout(const Duration(seconds: 30)),
      );
      if (response.statusCode != 200) {
        throw Exception('查詢經文修訂紀錄失敗：HTTP ${response.statusCode}');
      }
      final payload =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final results = (payload['results'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>();
      String? latest;
      for (final result in results) {
        final version = '${result['ver'] ?? ''}'.trim();
        if (version.isEmpty) continue;
        if (latest == null || revisionRank(version) > revisionRank(latest)) {
          latest = version;
        }
      }
      return latest;
    } finally {
      client.close();
    }
  }

  /// 版號格式可能有 2026.R2、2026R2、2023 Q4 等寫法，比較前先統一。
  static String normalizeRevision(String version) =>
      version.toUpperCase().replaceAll(RegExp(r'[\s.]'), '');

  Future<WorkArchive> downloadWork(
    String work, {
    String filePrefix = '',
    void Function(int bytes)? onBytesReceived,
  }) => apiRateLimiter.run(
    () => fetchWorkArchive(
      work,
      filePrefix: filePrefix,
      onBytesReceived: onBytesReceived,
    ),
  );

  Future<CachedScriptureVolume> downloadVolume(
    String work,
    String juan, {
    void Function(int bytes)? onBytesReceived,
  }) => apiRateLimiter.run(
    () => fetchScriptureVolume(work, juan, onBytesReceived: onBytesReceived),
  );

  /// 將 2026.R2 這類版號轉成可比較的整數。
  static int revisionRank(String version) {
    final match = RegExp(
      r'(\d{4})\s*\.?\s*R(\d+)',
      caseSensitive: false,
    ).firstMatch(version);
    if (match != null) {
      return int.parse(match.group(1)!) * 1000 + int.parse(match.group(2)!);
    }
    final year = RegExp(r'(\d{4})').firstMatch(version);
    return (int.tryParse(year?.group(1) ?? '') ?? 0) * 1000;
  }
}
