import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'download_models.dart';

class DownloadStore {
  DownloadStore({Future<Directory> Function()? directoryProvider})
    : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory;

  static const _webQueueKey = 'cbeta_download_queue';
  static const _webVersionsKey = 'cbeta_download_versions';
  final Future<Directory> Function() _directoryProvider;

  Future<Directory> _storeDirectory() async {
    final base = await _directoryProvider();
    final dir = Directory(
      '${base.path}${Platform.pathSeparator}cbeta_downloads',
    );
    await dir.create(recursive: true);
    return dir;
  }

  Future<void> saveQueue(List<DownloadGroup> groups) async {
    final json = jsonEncode(groups.map((g) => g.toJson()).toList());
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_webQueueKey, json);
      return;
    }
    final dir = await _storeDirectory();
    final file = File('${dir.path}${Platform.pathSeparator}queue.json');
    await file.writeAsString(json, flush: true);
  }

  Future<List<DownloadGroup>> loadQueue() async {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_webQueueKey);
      if (raw == null) return const [];
      return _decodeGroups(raw);
    }
    final dir = await _storeDirectory();
    final file = File('${dir.path}${Platform.pathSeparator}queue.json');
    if (!await file.exists()) return const [];
    return _decodeGroups(await file.readAsString());
  }

  Future<void> clearQueue() async {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_webQueueKey);
      return;
    }
    final dir = await _storeDirectory();
    final file = File('${dir.path}${Platform.pathSeparator}queue.json');
    if (await file.exists()) await file.delete();
  }

  Future<void> saveVersions(Map<String, LocalVersion> versions) async {
    final json = jsonEncode(
      versions.map((key, value) => MapEntry(key, value.toJson())),
    );
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_webVersionsKey, json);
      return;
    }
    final dir = await _storeDirectory();
    final file = File('${dir.path}${Platform.pathSeparator}versions.json');
    await file.writeAsString(json, flush: true);
  }

  Future<Map<String, LocalVersion>> loadVersions() async {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_webVersionsKey);
      if (raw == null) return {};
      return _decodeVersions(raw);
    }
    final dir = await _storeDirectory();
    final file = File('${dir.path}${Platform.pathSeparator}versions.json');
    if (!await file.exists()) return {};
    return _decodeVersions(await file.readAsString());
  }

  Future<void> clearVersions() async {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_webVersionsKey);
      return;
    }
    final dir = await _storeDirectory();
    final file = File('${dir.path}${Platform.pathSeparator}versions.json');
    if (await file.exists()) await file.delete();
  }

  List<DownloadGroup> _decodeGroups(String raw) {
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .whereType<Map<String, dynamic>>()
          .map(DownloadGroup.fromJson)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Map<String, LocalVersion> _decodeVersions(String raw) {
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return map.map((key, value) {
        if (value is Map<String, dynamic>) {
          return MapEntry(key, LocalVersion.fromJson(value));
        }
        return MapEntry(
          key,
          LocalVersion(work: '', juan: '', ver: '', savedAt: DateTime.now()),
        );
      });
    } catch (_) {
      return {};
    }
  }
}

var downloadStore = DownloadStore();
