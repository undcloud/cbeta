import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xuefo/download/catalog_cache.dart';
import 'package:xuefo/download/catalog_store.dart';
import 'package:xuefo/download/download_manager.dart';
import 'package:xuefo/download/download_models.dart';
import 'package:xuefo/download/download_notifications.dart';
import 'package:xuefo/download/scripture_update_service.dart';
import 'package:xuefo/download/update_manager.dart';
import 'package:xuefo/download/work_archive.dart';
import 'package:xuefo/scripture/cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    CatalogCache.instance.debugLoad();
  });

  tearDown(() {
    CatalogCache.instance.debugReset();
  });

  group('WorkRemoteSignature', () {
    test('prefers the etag and matches every local version', () {
      const signature = WorkRemoteSignature(
        etag: 'abc',
        lastModified: 'Tue, 01 Sep 2026 00:00:00 GMT',
        contentLength: 10,
      );

      expect(signature.signature, 'abc');
      expect(signature.matchesLocal(['abc']), isTrue);
      expect(signature.matchesLocal(['abc', 'abc']), isTrue);
      expect(signature.matchesLocal(['abc', 'def']), isFalse);
      expect(signature.matchesLocal(['def']), isFalse);
      expect(signature.matchesLocal(const []), isFalse);
      expect(signature.matchesLocal(['']), isFalse);
    });

    test('falls back to last-modified when no etag is available', () {
      const signature = WorkRemoteSignature(
        lastModified: 'Tue, 01 Sep 2026 00:00:00 GMT',
      );
      expect(signature.signature, 'Tue, 01 Sep 2026 00:00:00 GMT');
      expect(signature.matchesLocal(['Tue, 01 Sep 2026 00:00:00 GMT']), isTrue);
    });

    test('never matches when the remote has no signature', () {
      const signature = WorkRemoteSignature(contentLength: 42);
      expect(signature.signature, isEmpty);
      expect(signature.matchesLocal(['42']), isFalse);
    });
  });

  group('ScriptureUpdateService', () {
    test('reads the etag and last-modified from HEAD', () async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        return http.Response(
          '',
          200,
          headers: {
            'etag': '"zip-etag"',
            'last-modified': 'Wed, 21 Oct 2026 07:28:00 GMT',
          },
        );
      });
      final service = ScriptureUpdateService(clientFactory: () => client);

      final signature = await service.headWork('T0001');

      expect(requests.single.method, 'HEAD');
      expect(requests.single.url.path, '/stable/download/html/T0001.html.zip');
      expect(signature.etag, 'zip-etag');
      expect(signature.lastModified, 'Wed, 21 Oct 2026 07:28:00 GMT');
      expect(signature.matchesLocal(['zip-etag']), isTrue);
    });

    test('throws when HEAD fails', () async {
      final client = MockClient((_) async => http.Response('', 404));
      final service = ScriptureUpdateService(clientFactory: () => client);
      expect(service.headWork('T0001'), throwsException);
    });

    test('returns the highest revision from the changes API', () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/stable/changes');
        expect(request.url.queryParameters['work'], 'T0001');
        return http.Response(
          jsonEncode({
            'results': [
              {'ver': '2025R1'},
              {'ver': '2026.R2'},
              {'ver': '2024R3'},
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      final service = ScriptureUpdateService(clientFactory: () => client);

      expect(await service.latestChangesVersion('T0001'), '2026.R2');
    });

    test('throws when the changes API fails', () async {
      final client = MockClient((_) async => http.Response('', 500));
      final service = ScriptureUpdateService(clientFactory: () => client);
      expect(service.latestChangesVersion('T0001'), throwsA(isA<Exception>()));
    });

    test('returns null when the changes API has no records', () async {
      final client = MockClient((_) async {
        return http.Response(
          jsonEncode({'results': []}),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      final service = ScriptureUpdateService(clientFactory: () => client);

      expect(await service.latestChangesVersion('T0001'), isNull);
    });

    test('normalizes revision format', () {
      expect(
        ScriptureUpdateService.normalizeRevision('2026.R2'),
        ScriptureUpdateService.normalizeRevision('2026R2'),
      );
      expect(
        ScriptureUpdateService.normalizeRevision('2023 Q4'),
        ScriptureUpdateService.normalizeRevision('2023Q4'),
      );
    });
  });

  group('CatalogUpdateService', () {
    late Directory tempDir;
    late CatalogStore store;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('catalog_update_test');
      store = CatalogStore(directoryProvider: () async => tempDir);
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    test('skips unchanged files and downloads changed ones', () async {
      await store.write('category.json', utf8.encode('[{"title":"old"}]'));
      await store.writeMeta(
        const CatalogUpdateMeta(
          files: {'category.json': CatalogFileMeta(etag: 'etag-a')},
        ),
      );
      final etags = {
        'category.json': 'etag-a',
        'vol.json': 'etag-b',
        'creators-by-strokes-with-works.json': 'etag-c',
        'dynasty-works.json': 'etag-d',
      };
      final downloaded = <String>[];
      final client = MockClient((request) async {
        final name = request.url.pathSegments.last;
        if (request.method == 'HEAD') {
          return http.Response('', 200, headers: {'etag': '"${etags[name]}"'});
        }
        downloaded.add(name);
        return http.Response(
          '[{"title":"new"}]',
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final service = CatalogUpdateService(
        store: store,
        clientFactory: () => client,
        releaseVersionLoader: (_) async => '2026.R2',
      );

      final outcome = await service.update();

      expect(outcome.updatedFiles, 3);
      expect(outcome.releaseVersion, '2026.R2');
      expect(outcome.releaseChanged, isTrue);
      expect(outcome.changed, isTrue);
      expect(downloaded, [
        'vol.json',
        'creators-by-strokes-with-works.json',
        'dynasty-works.json',
      ]);
      expect(utf8.decode((await store.read('vol.json'))!), contains('new'));
      final meta = await store.readMeta();
      expect(meta.files.keys, containsAll(etags.keys));
      expect(meta.files['vol.json']?.etag, 'etag-b');
      expect(meta.releaseVersion, '2026.R2');
      expect(meta.checkedAt, isNotNull);
    });

    test(
      'reports no change when every file and the release are current',
      () async {
        final etags = {
          'category.json': 'etag-a',
          'vol.json': 'etag-b',
          'creators-by-strokes-with-works.json': 'etag-c',
          'dynasty-works.json': 'etag-d',
        };
        await store.writeMeta(
          CatalogUpdateMeta(
            files: {
              for (final entry in etags.entries)
                entry.key: CatalogFileMeta(etag: entry.value, length: 3),
            },
            releaseVersion: '2026.R2',
          ),
        );
        for (final name in etags.keys) {
          await store.write(name, utf8.encode('[]'));
        }
        final client = MockClient((request) async {
          if (request.method == 'HEAD') {
            final name = request.url.pathSegments.last;
            return http.Response(
              '',
              200,
              headers: {'etag': '"${etags[name]}"'},
            );
          }
          throw StateError('不應下載未變更的經目：${request.url}');
        });
        final service = CatalogUpdateService(
          store: store,
          clientFactory: () => client,
          releaseVersionLoader: (_) async => '2026.R2',
        );

        final outcome = await service.update();

        expect(outcome.updatedFiles, 0);
        expect(outcome.releaseChanged, isFalse);
        expect(outcome.changed, isFalse);
      },
    );

    test('stops at a file boundary when cancelled', () async {
      final service = CatalogUpdateService(
        store: store,
        clientFactory: () => MockClient((_) async => http.Response('[]', 200)),
      );

      expect(
        service.update(isCancelled: () => true),
        throwsA(isA<CatalogUpdatePaused>()),
      );
    });
  });

  group('UpdateManager', () {
    late _FakeDownloadManager downloads;
    late _FakeCatalogUpdateService catalog;
    late _FakeScriptureUpdateService scripture;
    late _FakeNotificationService notifications;
    late int reloadCalls;
    late UpdateManager manager;

    UpdateManager buildManager() => UpdateManager(
      catalogService: catalog,
      scriptureService: scripture,
      downloads: downloads,
      notifications: notifications,
      reloadCatalog: () async => reloadCalls++,
    );

    setUp(() {
      downloads = _FakeDownloadManager([
        _version('T0001', '1', 'old-etag', release: '2025R1'),
        _version('T0001', '2', 'old-etag', release: '2025R1'),
        _version('T0002', '1', 'etag-2', release: '2026.R2'),
      ]);
      catalog = _FakeCatalogUpdateService();
      scripture = _FakeScriptureUpdateService();
      notifications = _FakeNotificationService();
      reloadCalls = 0;
      manager = buildManager();
    });

    test('updates changed works and skips unchanged ones', () async {
      catalog.outcome = const CatalogUpdateOutcome(
        updatedFiles: 2,
        releaseVersion: '2026.R2',
        releaseChanged: true,
      );
      scripture.releases['T0001'] = '2026.R2';
      scripture.releases['T0002'] = '2026.R2';
      scripture.archives['T0001'] = WorkArchive(
        volumes: [
          _volume('T0001', '1', 'new-1'),
          _volume('T0001', '2', 'new-2'),
        ],
        version: 'new-etag',
      );

      expect(await manager.start(), isTrue);
      await _waitFor(() => manager.status == UpdateStatus.completed);

      expect(catalog.calls, 1);
      expect(reloadCalls, 1);
      expect(manager.releaseVersion, '2026.R2');
      expect(scripture.changesCalls, ['T0001', 'T0002']);
      expect(scripture.archiveDownloads, 1);
      expect(downloads.replaced['T0001'], hasLength(2));
      expect(downloads.replaced['T0001']!.map((volume) => volume.juan), [
        '1',
        '2',
      ]);

      final progress = manager.progress;
      expect(progress.totalWorks, 2);
      expect(progress.checkedWorks, 2);
      expect(progress.updatedWorks, 1);
      expect(progress.skippedWorks, 1);
      expect(progress.failedWorks, 0);
      expect(manager.stage, UpdateStage.completed);
      expect(progress.message, contains('更新 1 部'));
      expect(manager.canResume, isFalse);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('cbeta_update_task'), isNull);
      expect(downloads.replacementReleases['T0001'], '2026.R2');
      expect(notifications.starts, 1);
      expect(notifications.stops, 1);
      expect(notifications.updates, greaterThan(0));
    });

    test('skips when remote release matches local', () async {
      downloads = _FakeDownloadManager([
        _version('T0001', '1', 'old-etag', release: '2026.R2'),
        _version('T0002', '1', 'etag-2', release: '2026.R2'),
      ]);
      manager = buildManager();
      scripture.releases['T0001'] = '2026.R2';
      scripture.releases['T0002'] = '2026.R2';

      expect(await manager.start(), isTrue);
      await _waitFor(() => manager.status == UpdateStatus.completed);

      expect(scripture.archiveDownloads, 0);
      expect(scripture.volumeDownloads, 0);
      expect(manager.progress.updatedWorks, 0);
      expect(manager.progress.skippedWorks, 2);
    });

    test('updates when remote release differs from local', () async {
      downloads = _FakeDownloadManager([
        _version('T0001', '1', 'old-etag', release: '2024R1'),
      ]);
      manager = buildManager();
      scripture.releases['T0001'] = '2025R2';
      scripture.archives['T0001'] = WorkArchive(
        volumes: [_volume('T0001', '1', 'new')],
        version: 'new-etag',
      );

      expect(await manager.start(), isTrue);
      await _waitFor(() => manager.status == UpdateStatus.completed);

      expect(scripture.archiveDownloads, 1);
      expect(manager.progress.updatedWorks, 1);
      expect(downloads.replacementReleases['T0001'], '2025R2');
    });

    test('updates legacy records without a stored release', () async {
      downloads = _FakeDownloadManager([_version('T0001', '1', 'old-etag')]);
      manager = buildManager();
      scripture.releases['T0001'] = '2024R1';
      scripture.archives['T0001'] = WorkArchive(
        volumes: [_volume('T0001', '1', 'new')],
        version: 'new-etag',
      );

      expect(await manager.start(), isTrue);
      await _waitFor(() => manager.status == UpdateStatus.completed);

      expect(scripture.archiveDownloads, 1);
      expect(downloads.replacementReleases['T0001'], '2024R1');
    });

    test('skips when remote has no change records', () async {
      downloads = _FakeDownloadManager([
        _version('T0001', '1', 'old-etag', release: '2025R2'),
      ]);
      manager = buildManager();
      scripture.releases['T0001'] = null;

      expect(await manager.start(), isTrue);
      await _waitFor(() => manager.status == UpdateStatus.completed);

      expect(scripture.archiveDownloads, 0);
      expect(manager.progress.skippedWorks, 1);
      expect(manager.progress.updatedWorks, 0);
    });

    test('does not reload the catalog when nothing changed', () async {
      catalog.outcome = const CatalogUpdateOutcome(
        updatedFiles: 0,
        releaseVersion: '2026.R2',
        releaseChanged: false,
      );
      scripture.releases['T0001'] = '2025R1';
      scripture.releases['T0002'] = '2026.R2';

      expect(await manager.start(), isTrue);
      await _waitFor(() => manager.status == UpdateStatus.completed);

      expect(reloadCalls, 0);
      expect(manager.progress.updatedWorks, 0);
      expect(manager.progress.skippedWorks, 2);
      expect(scripture.archiveDownloads, 0);
      expect(scripture.volumeDownloads, 0);
    });

    test(
      'falls back to per-juan downloads when the archive is empty',
      () async {
        scripture.releases['T0001'] = '2026.R2';
        scripture.releases['T0002'] = '2026.R2';
        scripture.archives['T0001'] = const WorkArchive(
          volumes: [],
          version: 'new',
        );

        expect(await manager.start(), isTrue);
        await _waitFor(() => manager.status == UpdateStatus.completed);

        expect(scripture.volumeDownloads, 2);
        expect(downloads.replaced['T0001'], hasLength(2));
        expect(manager.progress.updatedWorks, 1);
      },
    );

    test('records failures and keeps going', () async {
      scripture.changesErrors['T0001'] = Exception('boom');
      scripture.headErrors['T0001'] = Exception('boom');
      scripture.releases['T0002'] = '2026.R2';

      expect(await manager.start(), isTrue);
      await _waitFor(() => manager.status == UpdateStatus.completed);

      expect(manager.progress.failedWorks, 1);
      expect(manager.progress.skippedWorks, 1);
      expect(manager.progress.checkedWorks, 2);
      expect(manager.error, contains('boom'));
      expect(manager.progress.message, contains('1 部失敗'));
    });

    test('falls back to HEAD when changes API fails', () async {
      downloads = _FakeDownloadManager([
        _version('T0001', '1', 'old-etag', release: '2025R1'),
      ]);
      manager = buildManager();
      scripture.changesErrors['T0001'] = Exception('changes down');
      scripture.signatures['T0001'] = const WorkRemoteSignature(
        etag: 'new-etag',
      );
      scripture.archives['T0001'] = WorkArchive(
        volumes: [_volume('T0001', '1', 'new')],
        version: 'new-etag',
      );

      expect(await manager.start(), isTrue);
      await _waitFor(() => manager.status == UpdateStatus.completed);

      expect(scripture.changesCalls, ['T0001']);
      expect(scripture.headCalls, ['T0001']);
      expect(scripture.archiveDownloads, 1);
      expect(manager.progress.updatedWorks, 1);
    });

    test('pauses during work checks and resumes the remaining works', () async {
      final gate = Completer<void>();
      final entered = Completer<void>();
      var gateFirst = true;
      scripture.beforeChanges = (work) async {
        if (!gateFirst) return;
        gateFirst = false;
        entered.complete();
        await gate.future;
      };
      scripture.releases['T0001'] = '2025R1';
      scripture.releases['T0002'] = '2026.R2';

      expect(await manager.start(), isTrue);
      await entered.future;
      expect(manager.isUpdating, isTrue);
      manager.pause();
      expect(manager.isPausing, isTrue);
      gate.complete();
      await _waitFor(() => manager.status == UpdateStatus.paused);

      expect(manager.pendingWorkCount, 1);
      expect(manager.progress.checkedWorks, 1);
      expect(manager.canResume, isTrue);
      expect(notifications.stops, 1);

      manager.resume();
      await _waitFor(() => manager.status == UpdateStatus.completed);

      expect(scripture.changesCalls, ['T0001', 'T0002']);
      expect(manager.progress.checkedWorks, 2);
      expect(manager.pendingWorkCount, 0);
      expect(notifications.starts, 2);
      expect(notifications.stops, 2);
    });

    test('restores a persisted task as paused and deletes it', () async {
      SharedPreferences.setMockInitialValues({
        'cbeta_update_task': jsonEncode({
          'active': true,
          'catalog_done': true,
          'pending': ['T0001', 'T0002'],
          'checked': 3,
          'updated': 1,
          'skipped': 2,
          'failed': 0,
          'release': '2026.R2',
        }),
      });
      final restored = buildManager();
      await restored.initialize();

      expect(restored.status, UpdateStatus.paused);
      expect(restored.canResume, isTrue);
      expect(restored.hasTask, isTrue);
      expect(restored.pendingWorkCount, 2);
      expect(restored.progress.checkedWorks, 3);
      expect(restored.releaseVersion, '2026.R2');

      restored.deleteTask();
      final prefs = await SharedPreferences.getInstance();
      await _waitFor(() => prefs.getString('cbeta_update_task') == null);

      expect(restored.status, UpdateStatus.idle);
      expect(restored.canResume, isFalse);
      expect(restored.hasTask, isFalse);
      expect(restored.pendingWorkCount, 0);
    });

    test('resumes after the catalog phase failed', () async {
      catalog.failNext = true;
      scripture.releases['T0001'] = '2025R1';
      scripture.releases['T0002'] = '2026.R2';

      expect(await manager.start(), isTrue);
      await _waitFor(() => manager.status == UpdateStatus.failed);

      expect(catalog.calls, 1);
      expect(manager.canResume, isTrue);
      expect(manager.pendingWorkCount, 2);

      manager.resume();
      await _waitFor(() => manager.status == UpdateStatus.completed);

      expect(catalog.calls, 2);
      expect(manager.progress.checkedWorks, 2);
    });

    test('refuses to start while scriptures are downloading', () async {
      downloads.downloading = true;

      expect(await manager.start(), isFalse);
      expect(catalog.calls, 0);
      expect(manager.isUpdating, isFalse);
    });

    test('ignores updates after the task is deleted mid-run', () async {
      final gate = Completer<void>();
      final entered = Completer<void>();
      scripture.beforeChanges = (work) async {
        entered.complete();
        await gate.future;
      };

      expect(await manager.start(), isTrue);
      await entered.future;
      manager.deleteTask();
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(manager.status, UpdateStatus.idle);
      expect(manager.pendingWorkCount, 0);
      expect(downloads.replaced, isEmpty);
      expect(scripture.archiveDownloads, 0);
    });
  });
}

LocalVersion _version(
  String work,
  String juan,
  String ver, {
  String? release,
}) => LocalVersion(
  work: work,
  juan: juan,
  ver: ver,
  release: release,
  savedAt: DateTime.utc(2026, 10, 1),
);

CachedScriptureVolume _volume(String work, String juan, String version) =>
    CachedScriptureVolume(
      work: work,
      juan: juan,
      html: '<p>$work $juan</p>',
      contentVersion: version,
    );

Future<void> _waitFor(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('等待更新狀態逾時');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

class _FakeDownloadManager extends DownloadManager {
  _FakeDownloadManager(this.initialVersions);

  final List<LocalVersion> initialVersions;
  final Map<String, List<CachedScriptureVolume>> replaced = {};
  final Map<String, String?> replacementReleases = {};
  bool downloading = false;

  @override
  bool get isDownloading => downloading;

  @override
  Set<String> get downloadedWorkIds =>
      initialVersions.map((version) => version.work).toSet();

  @override
  List<LocalVersion> versionsForWork(String work) =>
      initialVersions.where((version) => version.work == work).toList();

  @override
  Future<int> replaceDownloadedVolumes(
    String work,
    Iterable<CachedScriptureVolume> volumes, {
    String? release,
  }) async {
    final localJuans = versionsForWork(
      work,
    ).map((version) => version.juan).toSet();
    final incoming = volumes
        .where((volume) => localJuans.contains(volume.juan))
        .toList();
    replaced[work] = incoming;
    replacementReleases[work] = release;
    return incoming.length;
  }
}

class _FakeNotificationService extends DownloadNotificationService {
  int starts = 0;
  int updates = 0;
  int stops = 0;
  String? lastTitle;
  String? lastText;

  @override
  Future<void> requestPermission() async {}

  @override
  Future<void> start({
    required String title,
    required String text,
    required int progress,
    required int max,
  }) async {
    starts++;
    lastTitle = title;
    lastText = text;
  }

  @override
  Future<void> update({
    required String title,
    required String text,
    required int progress,
    required int max,
  }) async {
    updates++;
    lastTitle = title;
    lastText = text;
  }

  @override
  Future<void> stop() async {
    stops++;
  }
}

class _FakeCatalogUpdateService extends CatalogUpdateService {
  int calls = 0;
  bool failNext = false;
  CatalogUpdateOutcome outcome = const CatalogUpdateOutcome(
    updatedFiles: 0,
    releaseVersion: '2026.R2',
    releaseChanged: false,
  );

  @override
  Future<CatalogUpdateOutcome> update({
    void Function(String message, double? fraction)? onProgress,
    bool Function()? isCancelled,
  }) async {
    calls++;
    if (failNext) {
      failNext = false;
      throw Exception('catalog down');
    }
    onProgress?.call('檢查經目：category.json', 0.1);
    if (isCancelled?.call() ?? false) throw const CatalogUpdatePaused();
    return outcome;
  }
}

class _FakeScriptureUpdateService extends ScriptureUpdateService {
  final Map<String, WorkRemoteSignature> signatures = {};
  final Map<String, WorkArchive> archives = {};
  final Map<String, String?> releases = {};
  final List<String> changesCalls = [];
  final List<String> headCalls = [];
  Future<void> Function(String work)? beforeChanges;
  final Map<String, Object> changesErrors = {};
  final Map<String, Object> headErrors = {};
  int archiveDownloads = 0;
  int volumeDownloads = 0;

  @override
  Future<WorkRemoteSignature> headWork(String work) async {
    headCalls.add(work);
    final error = headErrors[work];
    if (error != null) throw error;
    return signatures[work] ?? const WorkRemoteSignature();
  }

  @override
  Future<String?> latestChangesVersion(String work) async {
    changesCalls.add(work);
    final hook = beforeChanges;
    if (hook != null) await hook(work);
    final error = changesErrors[work];
    if (error != null) throw error;
    return releases[work];
  }

  @override
  Future<WorkArchive> downloadWork(
    String work, {
    String filePrefix = '',
    void Function(int bytes)? onBytesReceived,
  }) async {
    archiveDownloads++;
    onBytesReceived?.call(128);
    return archives[work] ?? const WorkArchive(volumes: [], version: 'unknown');
  }

  @override
  Future<CachedScriptureVolume> downloadVolume(
    String work,
    String juan, {
    void Function(int bytes)? onBytesReceived,
  }) async {
    volumeDownloads++;
    onBytesReceived?.call(64);
    return _volume(work, juan, 'downloaded');
  }
}
