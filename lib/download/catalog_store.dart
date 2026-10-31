import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../cbeta_api_headers.dart';
import 'api_rate_limiter.dart';

/// 可從 CBETA scope selector 下載的經目檔案。
const catalogFileNames = <String>[
  'category.json',
  'vol.json',
  'creators-by-strokes-with-works.json',
  'dynasty-works.json',
];

const _catalogBaseUrl = 'https://cbdata.dila.edu.tw/stable';
const _metaFileName = '.update_meta.json';

@immutable
class CatalogFileMeta {
  const CatalogFileMeta({
    this.etag = '',
    this.lastModified = '',
    this.length = 0,
  });

  final String etag;
  final String lastModified;
  final int length;

  Map<String, Object?> toJson() => {
    'etag': etag,
    'last_modified': lastModified,
    'length': length,
  };

  factory CatalogFileMeta.fromJson(Map<String, dynamic> json) =>
      CatalogFileMeta(
        etag: json['etag'] as String? ?? '',
        lastModified: json['last_modified'] as String? ?? '',
        length: (json['length'] as num?)?.toInt() ?? 0,
      );
}

@immutable
class CatalogUpdateMeta {
  const CatalogUpdateMeta({
    this.files = const {},
    this.releaseVersion = '',
    this.checkedAt,
  });

  final Map<String, CatalogFileMeta> files;
  final String releaseVersion;
  final DateTime? checkedAt;

  Map<String, Object?> toJson() => {
    'files': files.map((name, meta) => MapEntry(name, meta.toJson())),
    'release_version': releaseVersion,
    if (checkedAt != null) 'checked_at': checkedAt!.toIso8601String(),
  };

  factory CatalogUpdateMeta.fromJson(Map<String, dynamic> json) {
    final rawFiles = json['files'];
    final files = <String, CatalogFileMeta>{};
    if (rawFiles is Map<String, dynamic>) {
      for (final entry in rawFiles.entries) {
        final value = entry.value;
        if (value is Map<String, dynamic>) {
          files[entry.key] = CatalogFileMeta.fromJson(value);
        }
      }
    }
    return CatalogUpdateMeta(
      files: files,
      releaseVersion: json['release_version'] as String? ?? '',
      checkedAt: DateTime.tryParse(json['checked_at'] as String? ?? ''),
    );
  }
}

/// 下載後的經目檔案放在應用程式支援目錄，不覆寫安裝包內的資產。
class CatalogStore {
  CatalogStore({Future<Directory> Function()? directoryProvider})
    : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directoryProvider;

  Future<Directory> directory() async {
    final base = await _directoryProvider();
    final dir = Directory('${base.path}${Platform.pathSeparator}cbeta_catalog');
    await dir.create(recursive: true);
    return dir;
  }

  Future<File> _file(String name) async {
    final dir = await directory();
    return File('${dir.path}${Platform.pathSeparator}$name');
  }

  Future<Uint8List?> read(String name) async {
    try {
      final file = await _file(name);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      return bytes.isEmpty ? null : bytes;
    } catch (_) {
      return null;
    }
  }

  Future<void> write(String name, List<int> bytes) async {
    final file = await _file(name);
    final temp = File('${file.path}.tmp');
    await temp.writeAsBytes(bytes, flush: true);
    if (await file.exists()) await file.delete();
    await temp.rename(file.path);
  }

  Future<CatalogUpdateMeta> readMeta() async {
    try {
      final file = await _file(_metaFileName);
      if (!await file.exists()) return const CatalogUpdateMeta();
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return const CatalogUpdateMeta();
      return CatalogUpdateMeta.fromJson(decoded);
    } catch (_) {
      return const CatalogUpdateMeta();
    }
  }

  Future<void> writeMeta(CatalogUpdateMeta meta) async {
    final file = await _file(_metaFileName);
    await file.writeAsString(jsonEncode(meta.toJson()), flush: true);
  }
}

class CatalogUpdatePaused implements Exception {
  const CatalogUpdatePaused();
}

@immutable
class CatalogUpdateOutcome {
  const CatalogUpdateOutcome({
    required this.updatedFiles,
    required this.releaseVersion,
    required this.releaseChanged,
  });

  final int updatedFiles;
  final String releaseVersion;
  final bool releaseChanged;

  bool get changed => updatedFiles > 0 || releaseChanged;
}

class CatalogUpdateService {
  CatalogUpdateService({
    CatalogStore? store,
    http.Client Function()? clientFactory,
    Future<String?> Function(http.Client client)? releaseVersionLoader,
    this.baseUrl = _catalogBaseUrl,
  }) : _store = store ?? catalogStore,
       _clientFactory = clientFactory ?? http.Client.new,
       _releaseVersionLoader = releaseVersionLoader;

  final CatalogStore _store;
  final http.Client Function() _clientFactory;
  final Future<String?> Function(http.Client client)? _releaseVersionLoader;
  final String baseUrl;

  Future<CatalogUpdateOutcome> update({
    void Function(String message, double? fraction)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final meta = await _store.readMeta();
    final files = Map<String, CatalogFileMeta>.from(meta.files);
    final client = _clientFactory();
    var updated = 0;
    try {
      for (var index = 0; index < catalogFileNames.length; index++) {
        if (isCancelled?.call() ?? false) throw const CatalogUpdatePaused();
        final name = catalogFileNames[index];
        final fraction = index / (catalogFileNames.length + 1);
        onProgress?.call('檢查經目：$name', fraction);
        final uri = Uri.parse('$baseUrl/download/scope-selector/$name');
        final remote = await apiRateLimiter.run(() => _head(client, uri));
        final existing = await _store.read(name);
        final known = files[name];
        final unchanged =
            existing != null && known != null && remote.matches(known);
        if (unchanged) {
          files[name] = remote.toMeta(length: existing.length);
          continue;
        }

        if (isCancelled?.call() ?? false) throw const CatalogUpdatePaused();
        onProgress?.call('下載經目：$name', fraction);
        final bytes = await apiRateLimiter.run(() => _download(client, uri));
        _validateJson(name, bytes);
        await _store.write(name, bytes);
        files[name] = remote.toMeta(length: bytes.length);
        updated++;
      }

      if (isCancelled?.call() ?? false) throw const CatalogUpdatePaused();
      onProgress?.call('檢查經目版本…', 0.9);
      final release = await _loadReleaseVersion(client);
      final releaseChanged =
          release != null &&
          release.isNotEmpty &&
          release != meta.releaseVersion;
      await _store.writeMeta(
        CatalogUpdateMeta(
          files: files,
          releaseVersion: release ?? meta.releaseVersion,
          checkedAt: DateTime.now().toUtc(),
        ),
      );
      return CatalogUpdateOutcome(
        updatedFiles: updated,
        releaseVersion: release ?? meta.releaseVersion,
        releaseChanged: releaseChanged,
      );
    } finally {
      client.close();
    }
  }

  Future<_RemoteFileInfo> _head(http.Client client, Uri uri) async {
    final request = http.Request('HEAD', uri)..headers.addAll(cbetaApiHeaders);
    final response = await client
        .send(request)
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw Exception('經目檢查失敗：HTTP ${response.statusCode}');
    }
    return _RemoteFileInfo(
      etag: _normalizeEtag(response.headers['etag']),
      lastModified: response.headers['last-modified']?.trim() ?? '',
      contentLength: response.contentLength,
    );
  }

  Future<List<int>> _download(http.Client client, Uri uri) async {
    final response = await client
        .get(uri, headers: cbetaApiHeaders)
        .timeout(const Duration(seconds: 90));
    if (response.statusCode != 200) {
      throw Exception('經目下載失敗：HTTP ${response.statusCode}');
    }
    return response.bodyBytes;
  }

  Future<String?> _loadReleaseVersion(http.Client client) async {
    final loader = _releaseVersionLoader;
    if (loader != null) return loader(client);
    try {
      final response = await apiRateLimiter.run(
        () => client
            .get(
              Uri.parse('$baseUrl/static_pages/log'),
              headers: cbetaApiHeaders,
            )
            .timeout(const Duration(seconds: 30)),
      );
      if (response.statusCode != 200) return null;
      final html = utf8.decode(response.bodyBytes, allowMalformed: true);
      final match = RegExp(
        r'內容更新至\s*CBETA\s*([0-9]{4}\s*\.?\s*R[0-9]+)',
      ).firstMatch(html);
      return match?.group(1)?.replaceAll(' ', '');
    } catch (_) {
      return null;
    }
  }

  static String _normalizeEtag(String? raw) =>
      raw?.replaceAll('"', '').trim() ?? '';

  static void _validateJson(String name, List<int> bytes) {
    final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
    if (decoded is! List && decoded is! Map) {
      throw FormatException('經目檔案格式無效：$name');
    }
  }
}

@immutable
class _RemoteFileInfo {
  const _RemoteFileInfo({
    required this.etag,
    required this.lastModified,
    required this.contentLength,
  });

  final String etag;
  final String lastModified;
  final int? contentLength;

  bool matches(CatalogFileMeta known) {
    if (etag.isNotEmpty && known.etag.isNotEmpty) return etag == known.etag;
    if (lastModified.isNotEmpty && known.lastModified.isNotEmpty) {
      return lastModified == known.lastModified;
    }
    final length = contentLength;
    return length != null && length > 0 && length == known.length;
  }

  CatalogFileMeta toMeta({required int length}) =>
      CatalogFileMeta(etag: etag, lastModified: lastModified, length: length);
}

final catalogStore = CatalogStore();
