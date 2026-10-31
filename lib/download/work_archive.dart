import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;

import '../cbeta_api_headers.dart';
import '../scripture/cache.dart';

class WorkArchive {
  const WorkArchive({required this.volumes, required this.version});

  final List<CachedScriptureVolume> volumes;
  final String version;
}

Future<WorkArchive> fetchWorkArchive(
  String work, {
  String filePrefix = '',
  void Function(int bytes)? onBytesReceived,
}) async {
  final client = http.Client();
  try {
    final request = http.Request(
      'GET',
      Uri.https('cbdata.dila.edu.tw', '/stable/download/html/$work.html.zip'),
    )..headers.addAll(cbetaApiHeaders);
    final response = await client
        .send(request)
        .timeout(const Duration(seconds: 90));
    if (response.statusCode != 200) {
      throw Exception('經文壓縮檔 API 回傳 ${response.statusCode}');
    }
    final bytes = BytesBuilder(copy: false);
    await response.stream
        .forEach((chunk) {
          bytes.add(chunk);
          onBytesReceived?.call(chunk.length);
        })
        .timeout(const Duration(seconds: 90));
    final version = _contentVersion(response.headers);
    return WorkArchive(
      volumes: extractWorkArchive(
        bytes.takeBytes(),
        work: work,
        filePrefix: filePrefix,
        version: version,
      ),
      version: version,
    );
  } finally {
    client.close();
  }
}

String _contentVersion(Map<String, String> headers) {
  final etag = headers['etag']?.replaceAll('"', '').trim();
  if (etag != null && etag.isNotEmpty) return etag;
  final modified = headers['last-modified']?.trim();
  if (modified != null && modified.isNotEmpty) return modified;
  return 'unknown';
}

List<CachedScriptureVolume> extractWorkArchive(
  List<int> bytes, {
  required String work,
  String filePrefix = '',
  String version = 'unknown',
}) {
  final archive = ZipDecoder().decodeBytes(bytes);
  final prefix = filePrefix.trim().isEmpty ? work : filePrefix.trim();
  final pattern = RegExp(
    '^${RegExp.escape(work)}_(\\d+)\\.html\$',
    caseSensitive: false,
  );
  final volumes = <CachedScriptureVolume>[];
  for (final file in archive.files) {
    if (!file.isFile) continue;
    final name = file.name.split('/').last;
    final match = pattern.firstMatch(name);
    if (match == null) continue;
    final juan = int.tryParse(match.group(1)!);
    if (juan == null) continue;
    final html = utf8.decode(file.content, allowMalformed: true);
    volumes.add(
      CachedScriptureVolume(
        work: work,
        juan: '$juan',
        html: normalizeArchiveHtml(html, prefix),
        contentVersion: version,
      ),
    );
  }
  volumes.sort(
    (left, right) =>
        (int.tryParse(left.juan) ?? 0).compareTo(int.tryParse(right.juan) ?? 0),
  );
  return volumes;
}

/// 將下載壓縮檔的 lineInfo 標記轉成 App 解析器使用的行首標記。
String normalizeArchiveHtml(String html, String filePrefix) {
  final prefix = filePrefix.trim();
  String replace(String source, RegExp pattern) =>
      source.replaceAllMapped(pattern, (match) {
        final line = match.group(1)!;
        final id = prefix.isEmpty ? line : '${prefix}_p$line';
        return '<span class="lb" id="$id">$id</span>';
      });

  var normalized = replace(
    html,
    RegExp(r"<span class='lineInfo' line='([^']+)'></span>"),
  );
  normalized = replace(
    normalized,
    RegExp(r'<span class="lineInfo" line="([^"]+)"></span>'),
  );
  // 下載版 HTML 有排版換行；移除標籤之間的空白，避免每行多出空行。
  return normalized.replaceAll(RegExp(r'>\s*\n\s*<'), '><');
}
