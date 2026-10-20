import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

final scriptureCacheUpdates = ValueNotifier<Set<String>>({});

class CachedScriptureVolume {
  const CachedScriptureVolume({
    required this.work,
    required this.juan,
    required this.html,
    this.contentVersion,
  });

  final String work;
  final String juan;
  final String html;
  final String? contentVersion;

  String get key => '$work:$juan';

  factory CachedScriptureVolume.fromJson(Map<String, dynamic> json) {
    final work = json['work'];
    final juan = json['juan'];
    final html = json['html'];
    final contentVersion = json['contentVersion'];
    if (work is! String ||
        juan is! String ||
        html is! String ||
        (contentVersion != null && contentVersion is! String)) {
      throw const FormatException('離線經文資料格式無效');
    }
    return CachedScriptureVolume(
      work: work,
      juan: juan,
      html: html,
      contentVersion: contentVersion as String?,
    );
  }

  Map<String, Object?> toJson() => {
    'work': work,
    'juan': juan,
    'html': html,
    'contentVersion': contentVersion,
  };
}

class ScriptureVolumeStore {
  ScriptureVolumeStore({Future<Directory> Function()? directoryProvider})
    : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory;

  static const _webKeyPrefix = 'cbeta_scripture_volume:';
  final Future<Directory> Function() _directoryProvider;

  String _validateKey(String work, String juan) {
    if (!RegExp(r'^[A-Za-z0-9]+$').hasMatch(work) ||
        !RegExp(r'^\d+$').hasMatch(juan)) {
      throw FormatException('無效的經卷識別碼：$work 卷 $juan');
    }
    return '$work-$juan';
  }

  Future<Directory> _cacheDirectory() async {
    final supportDirectory = await _directoryProvider();
    final directory = Directory(
      '${supportDirectory.path}${Platform.pathSeparator}cbeta_scripture',
    );
    await directory.create(recursive: true);
    return directory;
  }

  Future<CachedScriptureVolume?> read(String work, String juan) async {
    final fileKey = _validateKey(work, juan);
    final String? stored;
    if (kIsWeb) {
      stored = (await SharedPreferences.getInstance()).getString(
        '$_webKeyPrefix$fileKey',
      );
    } else {
      final directory = await _cacheDirectory();
      final file = File(
        '${directory.path}${Platform.pathSeparator}$fileKey.json',
      );
      stored = await file.exists() ? await file.readAsString() : null;
    }
    if (stored == null) return null;
    final volume = CachedScriptureVolume.fromJson(
      jsonDecode(stored) as Map<String, dynamic>,
    );
    if (volume.work != work || volume.juan != juan) {
      throw FormatException('離線經卷識別碼不符：$work 卷 $juan');
    }
    return volume;
  }

  Future<void> write(CachedScriptureVolume volume) async {
    final fileKey = _validateKey(volume.work, volume.juan);
    final stored = jsonEncode(volume.toJson());
    if (kIsWeb) {
      final saved = await (await SharedPreferences.getInstance()).setString(
        '$_webKeyPrefix$fileKey',
        stored,
      );
      if (!saved) throw StateError('無法儲存離線經文：${volume.key}');
      return;
    }
    final directory = await _cacheDirectory();
    final file = File(
      '${directory.path}${Platform.pathSeparator}$fileKey.json',
    );
    await file.writeAsString(stored, flush: true);
  }

  Future<List<CachedScriptureVolume>> list() async {
    if (kIsWeb) {
      final preferences = await SharedPreferences.getInstance();
      final volumes = <CachedScriptureVolume>[];
      for (final key in preferences.getKeys().where(
        (key) => key.startsWith(_webKeyPrefix),
      )) {
        final stored = preferences.getString(key);
        if (stored != null) {
          volumes.add(
            CachedScriptureVolume.fromJson(
              jsonDecode(stored) as Map<String, dynamic>,
            ),
          );
        }
      }
      return volumes;
    }
    final directory = await _cacheDirectory();
    if (!await directory.exists()) return const [];
    final files = await directory
        .list()
        .where((entity) => entity is File && entity.path.endsWith('.json'))
        .cast<File>()
        .toList();
    final volumes = <CachedScriptureVolume>[];
    for (final file in files) {
      volumes.add(
        CachedScriptureVolume.fromJson(
          jsonDecode(await file.readAsString()) as Map<String, dynamic>,
        ),
      );
    }
    return volumes;
  }

  Future<void> clearAll() async {
    if (kIsWeb) {
      final preferences = await SharedPreferences.getInstance();
      for (final key in preferences.getKeys().where(
        (key) => key.startsWith(_webKeyPrefix),
      )) {
        final removed = await preferences.remove(key);
        if (!removed) throw StateError('無法清除離線經文快取：$key');
      }
      return;
    }
    final directory = await _cacheDirectory();
    if (!await directory.exists()) return;
    await for (final entity in directory.list()) {
      if (entity is File && entity.path.endsWith('.json')) {
        await entity.delete();
      }
    }
  }
}

var scriptureVolumeStore = ScriptureVolumeStore();

class ScriptureCacheUpdateResult {
  const ScriptureCacheUpdateResult({
    required this.updated,
    required this.unchanged,
    required this.errors,
  });

  final int updated;
  final int unchanged;
  final List<String> errors;
}

Future<CachedScriptureVolume> fetchScriptureVolume(
  String work,
  String juan,
) async {
  final response = await http
      .get(
        Uri.https('cbdata.dila.edu.tw', '/stable/juans', {
          'work': work,
          'juan': juan,
        }),
      )
      .timeout(const Duration(seconds: 20));
  if (response.statusCode != 200) {
    throw Exception('經卷 API 回傳 ${response.statusCode}');
  }
  final payload =
      jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  if (payload['success'] == false) {
    throw Exception('CBETA 經卷下載失敗：${payload['error'] ?? '未知錯誤'}');
  }
  final html = (payload['results'] as List<dynamic>? ?? const [])
      .whereType<String>()
      .firstOrNull;
  if (html == null || html.isEmpty) {
    throw FormatException('CBETA 未回傳經卷內容：$work 卷 $juan');
  }
  return CachedScriptureVolume(
    work: work,
    juan: juan,
    html: html,
    contentVersion: payload['content'] as String?,
  );
}

Future<ScriptureCacheUpdateResult> checkAndUpdateCachedScriptures() async {
  final cachedVolumes = await scriptureVolumeStore.list();
  var updated = 0;
  var unchanged = 0;
  final updatedKeys = <String>{};
  final errors = <String>[];
  for (final cached in cachedVolumes) {
    try {
      final latest = await fetchScriptureVolume(cached.work, cached.juan);
      final isUpdated =
          cached.contentVersion != null && latest.contentVersion != null
          ? cached.contentVersion != latest.contentVersion
          : cached.html != latest.html;
      if (isUpdated) {
        await scriptureVolumeStore.write(latest);
        updated++;
        updatedKeys.add(cached.key);
      } else {
        unchanged++;
      }
    } catch (error) {
      errors.add('${cached.work} 卷 ${cached.juan}：$error');
    }
  }
  if (updatedKeys.isNotEmpty) {
    scriptureCacheUpdates.value = Set.unmodifiable(updatedKeys);
  }
  return ScriptureCacheUpdateResult(
    updated: updated,
    unchanged: unchanged,
    errors: List.unmodifiable(errors),
  );
}
