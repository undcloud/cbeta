import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../cbeta_api_headers.dart';
import '../scripture/cache.dart';
import 'api_rate_limiter.dart';
import 'work_archive.dart';

@immutable
class WorkHeadInfo {
  const WorkHeadInfo({this.contentLength});

  final int? contentLength;
}

class ScriptureHttpException implements Exception {
  const ScriptureHttpException(this.statusCode, [this.message]);

  final int statusCode;
  final String? message;

  @override
  String toString() => message ?? 'HTTP $statusCode';
}

class ScriptureUpdateService {
  ScriptureUpdateService({http.Client Function()? clientFactory})
    : _clientFactory = clientFactory ?? http.Client.new;

  final http.Client Function() _clientFactory;

  /// 以 HEAD 確認作品壓縮檔存在；404 由呼叫端視為「沒有 HTML 版」。
  Future<WorkHeadInfo> headWork(String work) async {
    final client = _clientFactory();
    try {
      final response = await apiRateLimiter.run(
        () => client
            .head(
              Uri.https(
                'cbdata.dila.edu.tw',
                '/stable/download/html/$work.html.zip',
              ),
              headers: cbetaApiHeaders,
            )
            .timeout(const Duration(seconds: 30)),
      );
      if (response.statusCode != 200) {
        throw ScriptureHttpException(
          response.statusCode,
          '檢查經文失敗：HTTP ${response.statusCode}',
        );
      }
      return WorkHeadInfo(contentLength: response.contentLength);
    } finally {
      client.close();
    }
  }

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
}
