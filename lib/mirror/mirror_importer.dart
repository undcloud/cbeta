import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';

import '../download/catalog_cache.dart';
import '../download/download_manager.dart';
import '../download/download_models.dart';
import '../download/download_notifications.dart';
import '../download/update_manager.dart';
import '../download/work_archive.dart';
import '../scripture/cache.dart';
import '../scripture/index_update_service.dart';
import '../scripture/offline_scan.dart';
import 'mirror_config.dart';
import 'mirror_identity.dart';
import 'mirror_models.dart';
import 'mirror_service.dart';
import 'mirror_stats.dart';
import 'mirror_storage.dart';

/// 讀入外層 ZIP 後交給背景 isolate 解壓、正規化的一批作品。
class _WorkArchiveBatchItem {
  const _WorkArchiveBatchItem(this.work, this.filePrefix, this.bytes);

  final String work;
  final String filePrefix;
  final Uint8List bytes;
}

List<CachedScriptureVolume> _extractArchiveBatch(
  List<_WorkArchiveBatchItem> items,
  String version,
) {
  final volumes = <CachedScriptureVolume>[];
  for (final item in items) {
    volumes.addAll(
      extractWorkArchive(
        item.bytes,
        work: item.work,
        filePrefix: item.filePrefix,
        version: version,
      ),
    );
  }
  return volumes;
}

/// 全量鏡像 ZIP 的下載、解壓與匯入。
///
/// 流程：私有目錄下載 `.part`（支援 Range 續傳）→ 串流讀外層 ZIP →
/// 每批作品在背景 isolate 解壓/正規化 → 寫入與 CBETA 相同的
/// `cbeta_scripture` 目錄並建索引 → 匯出 ZIP 到公有 Downloads。
class MirrorImporter extends ChangeNotifier {
  static const _zipName = 'cbeta_html_full.zip';
  static const _batchWorks = 12;
  static const _batchBytes = 8 * 1024 * 1024;
  static const _flushEveryWorks = 48;

  MirrorConfig? _config;
  MirrorLocalState _local = const MirrorLocalState();
  MirrorProbe? _lastProbe;
  MirrorImportPhase _phase = MirrorImportPhase.idle;
  String? _message;
  int _receivedBytes = 0;
  int _totalBytes = 0;
  int _works = 0;
  int _juans = 0;
  int _totalWorks = 0;
  String? _currentWork;
  String _release = '';
  String _session = '';
  bool _cancelled = false;
  Future<bool>? _running;
  final List<({DateTime time, int bytes})> _speedSamples = [];
  int _sampleBytes = 0;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastNotification = DateTime.fromMillisecondsSinceEpoch(0);

  MirrorConfig? get config => _config;
  MirrorLocalState get local => _local;
  MirrorProbe? get lastProbe => _lastProbe;
  MirrorImportPhase get phase => _phase;
  String get release => _release;
  int get works => _works;
  int get juans => _juans;
  int get receivedBytes => _receivedBytes;
  int get totalBytes => _totalBytes;
  String? get message => _message;

  bool get isImporting =>
      _phase == MirrorImportPhase.probing ||
      _phase == MirrorImportPhase.downloading ||
      _phase == MirrorImportPhase.extracting ||
      _phase == MirrorImportPhase.indexing ||
      _phase == MirrorImportPhase.exporting;

  bool get hasPendingData =>
      !_local.importCompleted && _local.size > 0 && _local.release.isNotEmpty;

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

  MirrorImportProgress get progress => MirrorImportProgress(
    phase: _phase,
    receivedBytes: _receivedBytes,
    totalBytes: _totalBytes,
    works: _works,
    juans: _juans,
    totalWorks: _totalWorks,
    currentWork: _currentWork,
    message: _message,
    speedBytesPerSecond: downloadSpeedBytesPerSecond,
  );

  bool isUpToDateFor(MirrorProbe probe) =>
      _local.isUpToDate && _local.matchesProbe(probe);

  Future<void> initialize() async {
    _config = await MirrorConfigService.loadCached();
    _local = await MirrorLocalState.load();
    _release = _local.release;
    notifyListeners();
  }

  /// 探測伺服器；不會下載。匯入進行中時直接回傳上次結果。
  Future<MirrorProbe> probe() async {
    final current = _lastProbe;
    if (isImporting && current != null) return current;
    final config = await MirrorConfigService.load();
    _config = config;
    _phase = MirrorImportPhase.probing;
    _message = '正在檢查鏡像...';
    _notify(force: true);
    final result = await MirrorService.probe(config);
    _lastProbe = result;
    if (result.usable) {
      _release = _resolveRelease(config, result);
      _totalBytes = result.size;
      _message = null;
    } else {
      _message = result.error ?? '鏡像暫不可用';
    }
    _phase = MirrorImportPhase.idle;
    _notify(force: true);
    return result;
  }

  Future<bool> start({bool force = false}) {
    final running = _running;
    if (running != null) return running;
    final future = _run(force: force);
    _running = future;
    return future.whenComplete(() {
      if (identical(_running, future)) _running = null;
    });
  }

  void cancel() {
    if (!isImporting) return;
    _cancelled = true;
    _message = '正在暫停...';
    _notify(force: true);
  }

  Future<bool> _run({required bool force}) async {
    _cancelled = false;
    _message = null;
    _receivedBytes = 0;
    _works = 0;
    _juans = 0;
    _totalWorks = 0;
    _currentWork = null;
    _speedSamples.clear();
    _sampleBytes = 0;
    _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
    _lastNotification = DateTime.fromMillisecondsSinceEpoch(0);
    _session = MirrorIdentity.newSessionId();

    MirrorConfig? config;
    try {
      if (downloadManager.isDownloading) {
        return _fail('經文下載進行中，完成後再匯入鏡像');
      }
      if (updateManager.isUpdating) {
        return _fail('經目更新進行中，完成後再匯入鏡像');
      }
      config = await MirrorConfigService.load();
      _config = config;
      if (!config.enabled) return _fail('鏡像下載未啟用');

      _phase = MirrorImportPhase.probing;
      _message = '正在檢查鏡像...';
      _notify(force: true);
      final probe = await MirrorService.probe(config);
      _lastProbe = probe;
      if (!probe.usable) {
        return _fail(probe.error ?? '鏡像暫不可用');
      }
      _release = _resolveRelease(config, probe);
      _totalBytes = probe.size;

      if (!force && isUpToDateFor(probe)) {
        _phase = MirrorImportPhase.completed;
        _message = '本機已匯入 ${_releaseLabel()}';
        _notify(force: true);
        return true;
      }

      await MirrorStats.report(
        config,
        event: 'start',
        session: _session,
        release: _release,
      );

      final temp = await MirrorStorage.tempDirectory();
      final requiredBytes = probe.size * 5;
      final free = await MirrorStorage.freeBytes(temp);
      if (free >= 0 && free < requiredBytes) {
        return _fail(
          '儲存空間不足：約需 ${formatMirrorBytes(requiredBytes)}，'
          '可用 ${formatMirrorBytes(free)}',
        );
      }

      final device = await MirrorIdentity.deviceId();
      final prepared = await _prepareZip(config, probe, device, temp);
      final zipPath = prepared.path;

      await _importZip(zipPath, _release);

      _phase = MirrorImportPhase.exporting;
      _message = '正在匯出壓縮檔...';
      _notify(force: true);
      final exported = await MirrorStorage.exportZip(
        zipPath,
        fileName: _zipName,
      );
      var keptZipPath = zipPath;
      var publicZipPath = '';
      if (exported != null && exported.isNotEmpty) {
        publicZipPath = exported;
        keptZipPath = '';
        await _deleteQuietly(File(zipPath));
      }

      _local = MirrorLocalState(
        release: _release,
        etag: probe.etag,
        size: probe.size,
        downloadedAt: _local.downloadedAt ?? DateTime.now(),
        importedAt: DateTime.now(),
        importedWorks: _works,
        importedJuans: _juans,
        zipPath: keptZipPath,
        publicZipPath: publicZipPath,
        importCompleted: true,
      );
      await _local.save();
      await MirrorStats.report(
        config,
        event: 'import_complete',
        session: _session,
        release: _release,
        bytes: probe.size,
        detail: 'works=$_works juans=$_juans',
      );
      _phase = MirrorImportPhase.completed;
      _message =
          '鏡像匯入完成：$_works 部 · $_juans 卷'
          '${publicZipPath.isEmpty ? '' : ' · ZIP 已存到 Downloads'}';
      _notify(force: true);
      unawaited(downloadNotifications.stop());
      return true;
    } on MirrorCancelledException {
      _phase = MirrorImportPhase.cancelled;
      _message = '已暫停；下次開始會從已下載部分續傳';
      _notify(force: true);
      unawaited(downloadNotifications.stop());
      return false;
    } catch (error) {
      debugPrint('Mirror import failed: $error');
      final detail = error is MirrorException ? error.message : '$error';
      if (config != null) {
        unawaited(
          MirrorStats.report(
            config,
            event: 'failed',
            session: _session,
            release: _release,
            detail: detail,
          ),
        );
      }
      return _fail(error is MirrorException ? error.message : '鏡像匯入失敗：$detail');
    }
  }

  Future<({String path, bool downloaded})> _prepareZip(
    MirrorConfig config,
    MirrorProbe probe,
    String device,
    Directory temp,
  ) async {
    final zip = File('${temp.path}${Platform.pathSeparator}$_zipName');
    final part = File('${zip.path}.part');

    if (await zip.exists()) {
      final length = await zip.length();
      if (length == probe.size && _sameSource(probe)) {
        _receivedBytes = probe.size;
        return (path: zip.path, downloaded: false);
      }
      await _deleteQuietly(zip);
    }

    if (_local.publicZipPath.isNotEmpty) {
      final location = await MirrorStorage.publicZipLocation(
        fileName: _zipName,
      );
      if (location != null && location.isNotEmpty) {
        _phase = MirrorImportPhase.downloading;
        _message = '正在從公有目錄取回鏡像...';
        _notify(force: true);
        await _deleteQuietly(part);
        final copied = await MirrorStorage.copyPublicToPrivate(
          zip.path,
          fileName: _zipName,
        );
        if (copied && await zip.exists() && await zip.length() == probe.size) {
          _receivedBytes = probe.size;
          return (path: zip.path, downloaded: false);
        }
        await _deleteQuietly(zip);
      }
    }

    _phase = MirrorImportPhase.downloading;
    _message = '正在下載鏡像...';
    _notify(force: true);
    unawaited(_startNotification());

    var attempt = 0;
    while (true) {
      if (_cancelled) throw const MirrorCancelledException();
      try {
        await MirrorService.download(
          config: config,
          probe: probe,
          partFile: part,
          deviceId: device,
          session: _session,
          isCancelled: () => _cancelled,
          onProgress: (received, total) {
            _receivedBytes = received;
            if (total > 0) _totalBytes = total;
            _updateNotification();
            _notify();
          },
          onBytes: _handleBytes,
        );
        break;
      } on MirrorBusyException catch (error) {
        attempt++;
        if (attempt > 8) throw MirrorException(error.message);
        final wait =
            error.retryAfter ?? Duration(seconds: math.min(60, 5 * attempt));
        _message = '${error.message}，${wait.inSeconds} 秒後重試（已下載部分會續傳）';
        _notify(force: true);
        await _sleepCancellable(wait);
      } on MirrorException catch (error) {
        if (!error.retryable) rethrow;
        attempt++;
        if (attempt > 6) throw MirrorException(error.message);
        final wait = Duration(seconds: math.min(30, 3 * attempt));
        _message = '${error.message}，${wait.inSeconds} 秒後重試';
        _notify(force: true);
        await _sleepCancellable(wait);
      }
    }

    if (!await part.exists()) {
      throw const MirrorException('鏡像下載未完成');
    }
    final length = await part.length();
    if (length != probe.size) {
      throw MirrorException(
        '鏡像下載不完整（${formatMirrorBytes(length)} / '
        '${formatMirrorBytes(probe.size)}）',
        retryable: true,
      );
    }
    await _deleteQuietly(zip);
    await part.rename(zip.path);
    _receivedBytes = probe.size;
    _totalBytes = probe.size;
    _local = _local.copyWith(
      release: _release,
      etag: probe.etag,
      size: probe.size,
      downloadedAt: DateTime.now(),
      zipPath: zip.path,
      importCompleted: false,
    );
    await _local.save();
    await MirrorStats.report(
      config,
      event: 'download_complete',
      session: _session,
      release: _release,
      bytes: probe.size,
    );
    unawaited(downloadNotifications.stop());
    return (path: zip.path, downloaded: true);
  }

  Future<void> _importZip(String zipPath, String release) async {
    _phase = MirrorImportPhase.extracting;
    _works = 0;
    _juans = 0;
    _currentWork = null;
    _message = '正在解壓經文...';
    _notify(force: true);

    final input = InputFileStream(zipPath);
    try {
      final archive = ZipDecoder().decodeStream(input);
      _totalWorks = archive.files
          .where((entry) => entry.isFile && _zipEntryWork(entry) != null)
          .length;
      final batch = <_WorkArchiveBatchItem>[];
      var batchBytes = 0;
      for (final entry in archive.files) {
        if (_cancelled) throw const MirrorCancelledException();
        if (!entry.isFile) continue;
        final work = _zipEntryWork(entry);
        if (work == null) continue;
        final bytes = entry.readBytes();
        entry.clear();
        if (bytes == null || bytes.isEmpty) continue;
        final prefix = CatalogCache.instance.lookupWorkFile(work) ?? '';
        batch.add(_WorkArchiveBatchItem(work, prefix, bytes));
        batchBytes += bytes.length;
        if (batch.length >= _batchWorks || batchBytes >= _batchBytes) {
          await _flushBatch(batch, release);
          batchBytes = 0;
        }
      }
      if (batch.isNotEmpty) await _flushBatch(batch, release);
    } finally {
      input.closeSync();
    }

    _phase = MirrorImportPhase.indexing;
    _message = '正在完成搜尋索引...';
    _currentWork = null;
    _notify(force: true);
    await downloadManager.flushImportProgress();
    offlineIndexQueue.drain();
    await offlineIndexQueue.flush();
    indexUpdateService.requestUpdate();
  }

  Future<void> _flushBatch(
    List<_WorkArchiveBatchItem> batch,
    String release,
  ) async {
    if (batch.isEmpty) return;
    final items = List<_WorkArchiveBatchItem>.of(batch);
    batch.clear();

    final List<CachedScriptureVolume> volumes;
    if (kIsWeb) {
      volumes = _extractArchiveBatch(items, release);
    } else {
      volumes = await Isolate.run(
        () => _extractArchiveBatch(items, release),
        debugName: 'mirror-extract',
      );
    }
    if (_cancelled) throw const MirrorCancelledException();

    final byWork = <String, List<CachedScriptureVolume>>{};
    for (final volume in volumes) {
      byWork.putIfAbsent(volume.work, () => []).add(volume);
    }
    for (final entry in byWork.entries) {
      if (_cancelled) throw const MirrorCancelledException();
      _currentWork = entry.key;
      final stored = await downloadManager.importVolumes(
        entry.key,
        entry.value,
        release: release,
        persist: false,
        flushIndex: false,
      );
      if (stored > 0) {
        _works++;
        _juans += stored;
      }
      if (_works > 0 && _works % _flushEveryWorks == 0) {
        _phase = MirrorImportPhase.indexing;
        _message = '正在建立搜尋索引...';
        _notify(force: true);
        await downloadManager.flushImportProgress();
        _phase = MirrorImportPhase.extracting;
        _message = '正在解壓經文...';
      }
      _updateNotification();
      _notify();
    }
  }

  String? _zipEntryWork(ArchiveFile entry) {
    final base = entry.name.split('/').last;
    if (!base.toLowerCase().endsWith('.html.zip')) return null;
    final work = base.substring(0, base.length - '.html.zip'.length).trim();
    return work.isEmpty ? null : work;
  }

  bool _sameSource(MirrorProbe probe) {
    if (_local.etag.isNotEmpty && probe.etag.isNotEmpty) {
      return _local.etag == probe.etag &&
          (_local.size == 0 || probe.size == 0 || _local.size == probe.size);
    }
    if (_local.release.isNotEmpty &&
        probe.release.isNotEmpty &&
        _local.release != probe.release) {
      return false;
    }
    return _local.size == 0 || probe.size == 0 || _local.size == probe.size;
  }

  String _resolveRelease(MirrorConfig config, MirrorProbe probe) {
    if (probe.release.isNotEmpty) return probe.release;
    if (config.release.isNotEmpty) return config.release;
    if (probe.etag.isNotEmpty) return probe.etag;
    return '${probe.size}';
  }

  String _releaseLabel() => _release.isEmpty ? '目前版本' : _release;

  bool _fail(String message) {
    _phase = MirrorImportPhase.failed;
    _message = message;
    _notify(force: true);
    unawaited(downloadNotifications.stop());
    return false;
  }

  Future<void> _sleepCancellable(Duration duration) async {
    final deadline = DateTime.now().add(duration);
    while (DateTime.now().isBefore(deadline)) {
      if (_cancelled) throw const MirrorCancelledException();
      final remaining = deadline.difference(DateTime.now());
      final step = remaining > const Duration(milliseconds: 500)
          ? const Duration(milliseconds: 500)
          : remaining;
      if (step <= Duration.zero) break;
      await Future<void>.delayed(step);
    }
    if (_cancelled) throw const MirrorCancelledException();
  }

  void _handleBytes(int bytes) {
    if (bytes <= 0) return;
    _sampleBytes += bytes;
    final now = DateTime.now();
    _speedSamples.add((time: now, bytes: _sampleBytes));
    final cutoff = now.subtract(const Duration(seconds: 2));
    while (_speedSamples.length > 2 &&
        _speedSamples.first.time.isBefore(cutoff)) {
      _speedSamples.removeAt(0);
    }
  }

  Future<void> _startNotification() async {
    await downloadNotifications.requestPermission();
    if (!isImporting) return;
    await downloadNotifications.start(
      title: '正在下載鏡像',
      text: '準備下載全量佛典鏡像',
      progress: 0,
      max: 1000,
    );
  }

  void _updateNotification() {
    if (_phase != MirrorImportPhase.downloading) return;
    final now = DateTime.now();
    if (now.difference(_lastNotification) < const Duration(seconds: 1)) {
      return;
    }
    _lastNotification = now;
    final fraction = _totalBytes <= 0 ? 0.0 : _receivedBytes / _totalBytes;
    unawaited(
      downloadNotifications.update(
        title: '正在下載鏡像',
        text:
            '${formatMirrorBytes(_receivedBytes)} / '
            '${formatMirrorBytes(_totalBytes)}'
            ' · ${formatDownloadSpeed(downloadSpeedBytesPerSecond)}',
        progress: (fraction.clamp(0.0, 1.0) * 1000).round(),
        max: 1000,
      ),
    );
  }

  void _notify({bool force = false}) {
    final now = DateTime.now();
    if (!force &&
        now.difference(_lastNotify) < const Duration(milliseconds: 300)) {
      return;
    }
    _lastNotify = now;
    notifyListeners();
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (error) {
      debugPrint('刪除鏡像暫存失敗：$error');
    }
  }
}

final mirrorImporter = MirrorImporter();
