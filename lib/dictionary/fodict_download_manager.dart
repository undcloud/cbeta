import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fodict_catalog.dart';
import 'fodict_service.dart';

enum FodictDownloadStatus { idle, downloading, paused, completed, failed }

@immutable
class FodictDownloadTask {
  const FodictDownloadTask({
    required this.id,
    required this.name,
    required this.url,
    required this.version,
    required this.updatedAt,
    required this.zipSize,
  });

  final String id;
  final String name;
  final String url;
  final String version;
  final String updatedAt;
  final int zipSize;

  factory FodictDownloadTask.fromRemote(FodictRemoteDictionary dictionary) {
    return FodictDownloadTask(
      id: dictionary.id,
      name: dictionary.name,
      url: dictionary.downloadUrl,
      version: dictionary.version,
      updatedAt: dictionary.updatedAt,
      zipSize: dictionary.zipSize,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'version': version,
    'updated_at': updatedAt,
    'zip_size': zipSize,
  };

  factory FodictDownloadTask.fromJson(Map<String, dynamic> json) {
    return FodictDownloadTask(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      url: json['url'] as String? ?? '',
      version: json['version'] as String? ?? '',
      updatedAt: json['updated_at'] as String? ?? '',
      zipSize: (json['zip_size'] as num?)?.toInt() ?? 0,
    );
  }
}

class _PauseSignal implements Exception {
  const _PauseSignal();
}

class FodictDownloadManager extends ChangeNotifier {
  static const _queueKey = 'cbeta_fodict_download_queue';
  static const _installedPrefix = 'cbeta_fodict_installed_at_';

  final List<FodictDownloadTask> _queue = [];
  final Set<String> _installedIds = {};
  final Set<String> _bundledIds = FodictService.assetDictionaryIds.toSet();
  final List<({DateTime time, int bytes})> _speedSamples = [];

  SharedPreferences? _prefs;
  Directory? _baseDir;
  Directory? _downloadDir;
  FodictDownloadStatus _status = FodictDownloadStatus.idle;
  FodictDownloadTask? _currentTask;
  int _receivedBytes = 0;
  int _totalBytes = 0;
  int _sessionBytes = 0;
  int _installRevision = 0;
  String? _error;
  bool _pauseRequested = false;
  http.Client? _client;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  List<FodictDownloadTask> get queue => List.unmodifiable(_queue);
  FodictDownloadStatus get status => _status;
  FodictDownloadTask? get currentTask => _currentTask;
  int get receivedBytes => _receivedBytes;
  int get totalBytes => _totalBytes;
  int get installRevision => _installRevision;
  Set<String> get installedIds => Set.unmodifiable(_installedIds);
  String? get error => _error;
  bool get isDownloading => _status == FodictDownloadStatus.downloading;
  bool get hasQueuedItems => _queue.isNotEmpty;
  bool get canResume =>
      !isDownloading &&
      _queue.isNotEmpty &&
      _status != FodictDownloadStatus.completed;

  double get progress {
    if (_totalBytes <= 0) return 0;
    return (_receivedBytes / _totalBytes).clamp(0.0, 1.0);
  }

  double get downloadSpeedBytesPerSecond {
    if (_speedSamples.length < 2) return 0;
    final latest = _speedSamples.last;
    if (DateTime.now().difference(latest.time) > const Duration(seconds: 2)) {
      return 0;
    }
    final cutoff = latest.time.subtract(const Duration(seconds: 2));
    var oldest = latest;
    for (final sample in _speedSamples) {
      if (!sample.time.isBefore(cutoff)) {
        oldest = sample;
        break;
      }
    }
    final elapsed = latest.time.difference(oldest.time).inMilliseconds;
    if (elapsed <= 0) return 0;
    return (latest.bytes - oldest.bytes) * 1000 / elapsed;
  }

  bool isInstalled(String id) =>
      _installedIds.contains(id) || _bundledIds.contains(id);

  bool isBundled(String id) => _bundledIds.contains(id);

  DateTime? installedAt(String id) {
    final raw = _prefs?.getString('$_installedPrefix$id');
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw)?.toUtc();
  }

  bool hasUpdate(FodictRemoteDictionary dictionary) {
    if (!_installedIds.contains(dictionary.id)) return false;
    final remote = dictionary.updatedAtDate;
    final local = installedAt(dictionary.id);
    if (remote == null || local == null) return false;
    return remote.isAfter(local);
  }

  Future<void> initialize() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      _baseDir = Directory(await FodictService.defaultBaseDir());
      await _baseDir!.create(recursive: true);
      final support = await getApplicationSupportDirectory();
      _downloadDir = Directory(
        '${support.path}${Platform.pathSeparator}fodict_downloads',
      );
      await _downloadDir!.create(recursive: true);
      _installedIds
        ..clear()
        ..addAll(await _scanInstalled());
      _queue
        ..clear()
        ..addAll(_loadQueue());
      _status = _queue.isEmpty
          ? FodictDownloadStatus.idle
          : FodictDownloadStatus.paused;
    } catch (error) {
      debugPrint('Fodict download manager init failed: $error');
    }
    notifyListeners();
  }

  Future<Set<String>> _scanInstalled() async {
    final dir = _baseDir;
    if (dir == null || !await dir.exists()) return {};
    final ids = <String>{};
    await for (final entity in dir.list()) {
      if (entity is! Directory) continue;
      final id = entity.path.split(Platform.pathSeparator).last;
      if (!_validId.hasMatch(id)) continue;
      if (await File(
        '${entity.path}${Platform.pathSeparator}fodict.dat',
      ).exists()) {
        ids.add(id);
      }
    }
    return ids;
  }

  List<FodictDownloadTask> _loadQueue() {
    final raw = _prefs?.getString(_queueKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      final seen = <String>{};
      final tasks = <FodictDownloadTask>[];
      for (final item in decoded.whereType<Map<String, dynamic>>()) {
        final task = FodictDownloadTask.fromJson(item);
        if (!_validId.hasMatch(task.id) ||
            task.url.isEmpty ||
            !seen.add(task.id)) {
          continue;
        }
        tasks.add(task);
      }
      return tasks;
    } catch (_) {
      return [];
    }
  }

  void enqueue(FodictRemoteDictionary dictionary) {
    if (!dictionary.available || isBundled(dictionary.id)) return;
    if (_queue.any((task) => task.id == dictionary.id)) {
      if (!isDownloading) unawaited(startDownload());
      return;
    }
    _queue.add(FodictDownloadTask.fromRemote(dictionary));
    unawaited(_saveQueue());
    _status = isDownloading ? _status : FodictDownloadStatus.paused;
    notifyListeners();
    unawaited(startDownload());
  }

  Future<void> startDownload() async {
    if (isDownloading || _queue.isEmpty) return;
    _pauseRequested = false;
    _error = null;
    _status = FodictDownloadStatus.downloading;
    notifyListeners();
    await _runQueue();
  }

  void pauseDownload() {
    if (!isDownloading) return;
    _pauseRequested = true;
    _status = FodictDownloadStatus.paused;
    _client?.close();
    notifyListeners();
  }

  void resumeDownload() {
    if (!isDownloading && _queue.isNotEmpty) {
      unawaited(startDownload());
    }
  }

  void removeTask(String id) {
    final index = _queue.indexWhere((task) => task.id == id);
    if (index < 0) return;
    final task = _queue[index];
    final isCurrent = _currentTask?.id == id;
    if (isCurrent) {
      _pauseRequested = true;
      _client?.close();
      _currentTask = null;
    }
    _queue.removeAt(index);
    unawaited(_deleteTaskFiles(task));
    unawaited(_saveQueue());
    if (_queue.isEmpty) {
      _status = FodictDownloadStatus.idle;
    } else if (isCurrent) {
      _status = FodictDownloadStatus.paused;
    }
    notifyListeners();
  }

  void clearQueue() {
    if (_queue.isEmpty) return;
    _pauseRequested = true;
    _client?.close();
    final tasks = List<FodictDownloadTask>.of(_queue);
    _queue.clear();
    _currentTask = null;
    _status = FodictDownloadStatus.idle;
    for (final task in tasks) {
      unawaited(_deleteTaskFiles(task));
    }
    unawaited(_saveQueue());
    notifyListeners();
  }

  Future<bool> deleteInstalled(String id) async {
    if (_bundledIds.contains(id) || !_validId.hasMatch(id)) return false;
    final base = _baseDir;
    if (base == null) return false;
    removeTask(id);
    final directory = Directory('${base.path}${Platform.pathSeparator}$id');
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
    _installedIds.remove(id);
    await _prefs?.remove('$_installedPrefix$id');
    FodictService().clearCache();
    _installRevision++;
    notifyListeners();
    return true;
  }

  Future<void> _runQueue() async {
    while (!_pauseRequested && _queue.isNotEmpty) {
      final task = _queue.first;
      _currentTask = task;
      _receivedBytes = 0;
      _totalBytes = task.zipSize;
      _sessionBytes = 0;
      _speedSamples.clear();
      _error = null;
      notifyListeners();

      try {
        await _ensureDownloaded(task);
        await _install(task);

        _installedIds.add(task.id);
        final stamp = task.updatedAt.isNotEmpty
            ? task.updatedAt
            : DateTime.now().toUtc().toIso8601String();
        await _prefs?.setString('$_installedPrefix${task.id}', stamp);
        _queue.removeWhere((item) => item.id == task.id);
        await _saveQueue();
        _installRevision++;
        FodictService().clearCache();
        _currentTask = null;

        if (_pauseRequested) {
          _status = _queue.isEmpty
              ? FodictDownloadStatus.completed
              : FodictDownloadStatus.paused;
          notifyListeners();
          break;
        }
        _status = _queue.isEmpty
            ? FodictDownloadStatus.completed
            : FodictDownloadStatus.downloading;
        notifyListeners();
      } on _PauseSignal {
        _status = _queue.isEmpty
            ? FodictDownloadStatus.idle
            : FodictDownloadStatus.paused;
        notifyListeners();
        break;
      } catch (error) {
        if (_pauseRequested) {
          _status = _queue.isEmpty
              ? FodictDownloadStatus.idle
              : FodictDownloadStatus.paused;
          notifyListeners();
          break;
        }
        _error = '${task.name}：$error';
        _status = FodictDownloadStatus.failed;
        notifyListeners();
        break;
      }
    }

    _currentTask = null;
    if (isDownloading) {
      _status = _pauseRequested
          ? FodictDownloadStatus.paused
          : _queue.isEmpty
          ? FodictDownloadStatus.completed
          : FodictDownloadStatus.idle;
      notifyListeners();
    }
  }

  Future<void> _ensureDownloaded(FodictDownloadTask task) async {
    final downloadDir = _downloadDir;
    if (downloadDir == null) {
      throw Exception('下載目錄不可用');
    }
    final zip = File(_zipPath(task));
    if (await zip.exists() && await zip.length() > 0) {
      _receivedBytes = await zip.length();
      if (_totalBytes <= 0) _totalBytes = _receivedBytes;
      notifyListeners();
      return;
    }

    final part = File('${zip.path}.part');
    var existing = await part.exists() ? await part.length() : 0;
    final client = http.Client();
    _client = client;
    try {
      final request = http.Request('GET', Uri.parse(task.url));
      request.headers['User-Agent'] = 'xuefo-app';
      if (existing > 0) {
        request.headers['Range'] = 'bytes=$existing-';
      }
      final response = await client.send(request);
      if (_pauseRequested) throw const _PauseSignal();
      if (response.statusCode != 200 && response.statusCode != 206) {
        throw Exception('HTTP ${response.statusCode}');
      }

      final append = response.statusCode == 206 && existing > 0;
      if (!append) {
        existing = 0;
        if (await part.exists()) await part.delete();
      }
      _receivedBytes = existing;
      final contentLength = response.contentLength;
      _totalBytes = contentLength != null && contentLength > 0
          ? existing + contentLength
          : task.zipSize > 0
          ? task.zipSize
          : existing;
      _sessionBytes = 0;
      _speedSamples.clear();

      final sink = part.openWrite(
        mode: append ? FileMode.append : FileMode.write,
      );
      try {
        await for (final chunk in response.stream) {
          if (_pauseRequested) throw const _PauseSignal();
          sink.add(chunk);
          _receivedBytes += chunk.length;
          _sessionBytes += chunk.length;
          _recordSpeed();
        }
      } finally {
        await sink.close();
      }

      if (_totalBytes > 0 && _receivedBytes < _totalBytes) {
        throw Exception('下載不完整');
      }
      if (await zip.exists()) await zip.delete();
      await part.rename(zip.path);
    } finally {
      _client = null;
      client.close();
    }
  }

  Future<void> _install(FodictDownloadTask task) async {
    final base = _baseDir;
    if (base == null) throw Exception('詞典目錄不可用');
    final zip = File(_zipPath(task));
    if (!await zip.exists()) throw Exception('壓縮檔不存在');

    final temp = Directory(
      '${base.path}${Platform.pathSeparator}.install_${task.id}',
    );
    if (await temp.exists()) await temp.delete(recursive: true);
    await temp.create(recursive: true);

    try {
      final zipPath = zip.path;
      final tempPath = temp.path;
      await Isolate.run(
        () => extractFileToDisk(zipPath, tempPath, maxSize: 1 << 30),
      );

      var source = Directory('${temp.path}${Platform.pathSeparator}${task.id}');
      if (!await source.exists()) {
        if (await File(
          '${temp.path}${Platform.pathSeparator}fodict.dat',
        ).exists()) {
          source = temp;
        } else {
          throw Exception('壓縮檔缺少 ${task.id} 目錄');
        }
      }
      if (!await File(
        '${source.path}${Platform.pathSeparator}fodict.dat',
      ).exists()) {
        throw Exception('壓縮檔缺少 fodict.dat');
      }

      final target = Directory(
        '${base.path}${Platform.pathSeparator}${task.id}',
      );
      final backup = Directory(
        '${base.path}${Platform.pathSeparator}.backup_${task.id}',
      );
      if (await backup.exists()) await backup.delete(recursive: true);
      if (await target.exists()) await target.rename(backup.path);
      try {
        await source.rename(target.path);
      } catch (_) {
        if (!await target.exists() && await backup.exists()) {
          await backup.rename(target.path);
        }
        rethrow;
      }
      if (await backup.exists()) {
        try {
          await backup.delete(recursive: true);
        } catch (_) {}
      }
      if (await zip.exists()) await zip.delete();
    } finally {
      if (await temp.exists()) await temp.delete(recursive: true);
    }
  }

  void _recordSpeed() {
    final now = DateTime.now();
    _speedSamples.add((time: now, bytes: _sessionBytes));
    final cutoff = now.subtract(const Duration(seconds: 2));
    while (_speedSamples.length > 2 &&
        _speedSamples.first.time.isBefore(cutoff)) {
      _speedSamples.removeAt(0);
    }
    if (now.difference(_lastNotify) >= const Duration(milliseconds: 500)) {
      _lastNotify = now;
      notifyListeners();
    }
  }

  String _zipPath(FodictDownloadTask task) {
    final downloadDir = _downloadDir;
    if (downloadDir == null) throw Exception('下載目錄不可用');
    final stamp = task.updatedAt.replaceAll(RegExp(r'[^0-9A-Za-z]'), '');
    return '${downloadDir.path}${Platform.pathSeparator}'
        '${task.id}_${stamp.isEmpty ? 'current' : stamp}.zip';
  }

  Future<void> _deleteTaskFiles(FodictDownloadTask task) async {
    try {
      final zip = File(_zipPath(task));
      final part = File('${zip.path}.part');
      await Future<void>.delayed(const Duration(seconds: 1));
      if (_queue.any((item) => item.id == task.id)) return;
      if (await part.exists()) await part.delete();
      if (await zip.exists()) await zip.delete();
    } catch (_) {}
  }

  Future<void> _saveQueue() async {
    final prefs = _prefs;
    if (prefs == null) return;
    await prefs.setString(
      _queueKey,
      jsonEncode(_queue.map((task) => task.toJson()).toList()),
    );
  }

  static final _validId = RegExp(r'^[0-9A-Za-z][0-9A-Za-z._-]*$');
}

final fodictDownloadManager = FodictDownloadManager();
