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
import 'package:xuefo/scripture/index_update_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    CatalogCache.instance.debugReset();
  });

  tearDown(() {
    CatalogCache.instance.debugReset();
  });

  group('ScriptureUpdateService', () {
    test('reads the zip content length from HEAD', () async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        return http.Response.bytes(List.filled(2048, 0), 200);
      });
      final service = ScriptureUpdateService(clientFactory: () => client);

      final info = await service.headWork('T0001');

      expect(requests.single.method, 'HEAD');
      expect(requests.single.url.path, '/stable/download/html/T0001.html.zip');
      expect(info.contentLength, 2048);
    });

    test('throws a typed exception when HEAD fails', () async {
      final client = MockClient((_) async => http.Response('', 404));
      final service = ScriptureUpdateService(clientFactory: () => client);

      await expectLater(
        service.headWork('T0001'),
        throwsA(
          isA<ScriptureHttpException>().having(
            (error) => error.statusCode,
            'statusCode',
            404,
          ),
        ),
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
    late _FakeIndexUpdateService indexes;
    late Map<String, AllWorksEntry> catalogAfterUpdate;
    late int reloadCalls;
    late UpdateManager manager;

    const initialCatalog = {
      'T0001': AllWorksEntry(work: 'T0001', title: '長阿含經', juans: ['1']),
      'T0002': AllWorksEntry(work: 'T0002', title: '中阿含經', juans: ['1']),
    };

    UpdateManager buildManager() => UpdateManager(
      catalogService: catalog,
      scriptureService: scripture,
      downloads: downloads,
      notifications: notifications,
      indexService: indexes,
      reloadCatalog: () async {
        reloadCalls++;
        if (catalogAfterUpdate.isNotEmpty) {
          CatalogCache.instance.debugLoad(allWorks: catalogAfterUpdate);
        }
      },
    );

    void catalogChanged({required Map<String, AllWorksEntry> newWorks}) {
      catalog.outcome = const CatalogUpdateOutcome(
        updatedFiles: 4,
        releaseVersion: '2026.R2',
        releaseChanged: true,
      );
      catalogAfterUpdate = newWorks;
    }

    void addArchive(String work, List<String> juans) {
      scripture.archives[work] = WorkArchive(
        volumes: [
          for (final juan in juans) _volume(work, juan, 'new-$work-$juan'),
        ],
        version: 'new-$work',
      );
    }

    setUp(() {
      downloads = _FakeDownloadManager([
        _version('T0001', '1', 'old-etag', release: '2025R1'),
        _version('T0002', '1', 'etag-2', release: '2026.R2'),
      ]);
      catalog = _FakeCatalogUpdateService();
      scripture = _FakeScriptureUpdateService();
      notifications = _FakeNotificationService();
      indexes = _FakeIndexUpdateService();
      catalogAfterUpdate = {};
      reloadCalls = 0;
      CatalogCache.instance.debugLoad(allWorks: initialCatalog);
      manager = buildManager();
    });

    test('silently downloads only newly added works', () async {
      catalogChanged(
        newWorks: {
          ...initialCatalog,
          'T0003': const AllWorksEntry(
            work: 'T0003',
            title: '增壹阿含經',
            juans: ['1', '2'],
          ),
        },
      );
      addArchive('T0003', ['1', '2']);

      expect(await manager.start(), isTrue);
      await _waitFor(() => manager.status == UpdateStatus.completed);

      expect(catalog.calls, 1);
      expect(reloadCalls, 1);
      expect(manager.releaseVersion, '2026.R2');
      expect(scripture.headCalls, ['T0003']);
      expect(scripture.archiveDownloads, 1);
      expect(downloads.stored['T0003'], hasLength(2));
      expect(downloads.stored['T0003']!.map((volume) => volume.juan), [
        '1',
        '2',
      ]);
      expect(downloads.storedReleases['T0003'], '2026.R2');

      final progress = manager.progress;
      expect(progress.totalWorks, 1);
      expect(progress.checkedWorks, 1);
      expect(progress.updatedWorks, 1);
      expect(progress.removedWorks, 0);
      expect(progress.skippedWorks, 0);
      expect(progress.failedWorks, 0);
      expect(manager.stage, UpdateStage.completed);
      expect(progress.message, contains('新增 1 部'));
      expect(manager.canResume, isFalse);

      expect(indexes.requestCalls, greaterThanOrEqualTo(1));
      expect(indexes.startCalls, 1);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('cbeta_update_task'), isNull);
      expect(notifications.starts, 1);
      expect(notifications.stops, 1);
      expect(notifications.updates, greaterThan(0));
    });

    test('skips added works that have no HTML archive', () async {
      catalogChanged(
        newWorks: {
          ...initialCatalog,
          'T0003': const AllWorksEntry(
            work: 'T0003',
            title: '增壹阿含經',
            juans: ['1'],
          ),
          'X0046': const AllWorksEntry(
            work: 'X0046',
            title: '未提供作品',
            juans: ['1'],
          ),
        },
      );
      addArchive('T0003', ['1']);
      scripture.noHtml.add('X0046');

      expect(await manager.start(), isTrue);
      await _waitFor(() => manager.status == UpdateStatus.completed);

      expect(scripture.headCalls, ['T0003', 'X0046']);
      expect(scripture.archiveDownloads, 1);
      expect(manager.progress.updatedWorks, 1);
      expect(manager.progress.skippedWorks, 1);
      expect(manager.progress.failedWorks, 0);
      expect(manager.progress.checkedWorks, 2);
      expect(manager.progress.message, contains('1 部無 HTML 版'));
      expect(manager.error, isNull);
    });

    test('reports removed downloaded works without deleting them', () async {
      catalogChanged(newWorks: {'T0002': initialCatalog['T0002']!});

      expect(await manager.start(), isTrue);
      await _waitFor(() => manager.status == UpdateStatus.completed);

      expect(manager.progress.removedWorks, 1);
      expect(manager.orphanedWorks, ['T0001']);
      expect(manager.progress.updatedWorks, 0);
      expect(scripture.headCalls, isEmpty);
      expect(downloads.stored, isEmpty);
      expect(manager.progress.message, contains('下架 1 部'));

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('cbeta_orphaned_works'), contains('T0001'));

      manager.clearOrphanedWorks();
      expect(manager.orphanedWorks, isEmpty);
      await _waitFor(() => prefs.getString('cbeta_orphaned_works') == null);
    });

    test('does nothing when the catalog and release are unchanged', () async {
      expect(await manager.start(), isTrue);
      await _waitFor(() => manager.status == UpdateStatus.completed);

      expect(reloadCalls, 0);
      expect(scripture.headCalls, isEmpty);
      expect(manager.progress.totalWorks, 0);
      expect(manager.progress.updatedWorks, 0);
      expect(manager.progress.removedWorks, 0);
      expect(manager.progress.message, '經目已是最新');
      expect(indexes.requestCalls, 0);
      expect(indexes.startCalls, 0);
    });

    test('does not mass-download when the old catalog is empty', () async {
      CatalogCache.instance.debugReset();
      CatalogCache.instance.debugLoad(allWorks: const {});
      catalogChanged(newWorks: initialCatalog);

      expect(await manager.start(), isTrue);
      await _waitFor(() => manager.status == UpdateStatus.completed);

      expect(scripture.headCalls, isEmpty);
      expect(downloads.stored, isEmpty);
      expect(manager.progress.updatedWorks, 0);
    });

    test('records failures and keeps downloading the rest', () async {
      catalogChanged(
        newWorks: {
          ...initialCatalog,
          'T0003': const AllWorksEntry(
            work: 'T0003',
            title: '增壹阿含經',
            juans: ['1'],
          ),
          'T0004': const AllWorksEntry(
            work: 'T0004',
            title: '雜阿含經',
            juans: ['1'],
          ),
        },
      );
      scripture.headErrors['T0003'] = Exception('boom');
      addArchive('T0004', ['1']);

      expect(await manager.start(), isTrue);
      await _waitFor(() => manager.status == UpdateStatus.completed);

      expect(manager.progress.failedWorks, 1);
      expect(manager.progress.updatedWorks, 1);
      expect(manager.progress.checkedWorks, 2);
      expect(manager.error, contains('boom'));
      expect(manager.progress.message, contains('1 部失敗'));
    });

    test('retries failed new works on the next update', () async {
      catalogChanged(
        newWorks: {
          ...initialCatalog,
          'T0003': const AllWorksEntry(
            work: 'T0003',
            title: '增壹阿含經',
            juans: ['1'],
          ),
        },
      );
      scripture.headErrors['T0003'] = Exception('boom');

      expect(await manager.start(), isTrue);
      await _waitFor(() => manager.status == UpdateStatus.completed);
      expect(manager.progress.failedWorks, 1);

      final prefs = await SharedPreferences.getInstance();
      await _waitFor(() => prefs.getString('cbeta_update_retry_works') != null);
      expect(prefs.getString('cbeta_update_retry_works'), contains('T0003'));

      scripture.headErrors.clear();
      addArchive('T0003', ['1']);
      catalog.outcome = const CatalogUpdateOutcome(
        updatedFiles: 0,
        releaseVersion: '2026.R2',
        releaseChanged: false,
      );

      expect(await manager.start(), isTrue);
      await _waitFor(() => manager.status == UpdateStatus.completed);

      expect(scripture.headCalls, ['T0003', 'T0003']);
      expect(downloads.stored['T0003'], hasLength(1));
      expect(manager.progress.updatedWorks, 1);
      await _waitFor(() => prefs.getString('cbeta_update_retry_works') == null);
    });

    test('pauses during a download and resumes the remaining works', () async {
      catalogChanged(
        newWorks: {
          ...initialCatalog,
          'T0003': const AllWorksEntry(
            work: 'T0003',
            title: '增壹阿含經',
            juans: ['1'],
          ),
          'T0004': const AllWorksEntry(
            work: 'T0004',
            title: '雜阿含經',
            juans: ['1'],
          ),
        },
      );
      addArchive('T0003', ['1']);
      addArchive('T0004', ['1']);
      final gate = Completer<void>();
      final entered = Completer<void>();
      var gated = false;
      scripture.beforeHead = (work) async {
        if (gated) return;
        gated = true;
        entered.complete();
        await gate.future;
      };

      expect(await manager.start(), isTrue);
      await entered.future;
      expect(manager.isUpdating, isTrue);
      manager.pause();
      expect(manager.isPausing, isTrue);
      gate.complete();
      await _waitFor(() => manager.status == UpdateStatus.paused);

      expect(manager.pendingWorkCount, 2);
      expect(manager.progress.checkedWorks, 0);
      expect(manager.canResume, isTrue);
      expect(notifications.stops, 1);

      manager.resume();
      await _waitFor(() => manager.status == UpdateStatus.completed);

      expect(scripture.headCalls, ['T0003', 'T0003', 'T0004']);
      expect(manager.progress.checkedWorks, 2);
      expect(manager.progress.updatedWorks, 2);
      expect(manager.pendingWorkCount, 0);
      expect(notifications.starts, 2);
      expect(notifications.stops, 2);
    });

    test('restores a schema v2 task as paused and deletes it', () async {
      SharedPreferences.setMockInitialValues({
        'cbeta_update_task': jsonEncode({
          'schema': 2,
          'active': true,
          'catalog_done': true,
          'pending': ['T0003'],
          'checked': 1,
          'added': 1,
          'no_html': 1,
          'failed': 0,
          'removed_count': 2,
          'release': '2026.R2',
        }),
      });
      final restored = buildManager();
      await restored.initialize();

      expect(restored.status, UpdateStatus.paused);
      expect(restored.canResume, isTrue);
      expect(restored.hasTask, isTrue);
      expect(restored.pendingWorkCount, 1);
      expect(restored.progress.checkedWorks, 1);
      expect(restored.progress.updatedWorks, 1);
      expect(restored.progress.skippedWorks, 1);
      expect(restored.progress.removedWorks, 2);
      expect(restored.releaseVersion, '2026.R2');

      restored.deleteTask();
      final prefs = await SharedPreferences.getInstance();
      await _waitFor(() => prefs.getString('cbeta_update_task') == null);

      expect(restored.status, UpdateStatus.idle);
      expect(restored.canResume, isFalse);
      expect(restored.hasTask, isFalse);
      expect(restored.pendingWorkCount, 0);
    });

    test('discards legacy tasks without a schema version', () async {
      SharedPreferences.setMockInitialValues({
        'cbeta_update_task': jsonEncode({
          'active': true,
          'catalog_done': false,
          'pending': ['T0001', 'T0002'],
          'checked': 0,
          'updated': 0,
          'skipped': 0,
          'failed': 0,
        }),
      });
      final restored = buildManager();
      await restored.initialize();

      expect(restored.status, UpdateStatus.idle);
      expect(restored.pendingWorkCount, 0);
      expect(restored.hasTask, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('cbeta_update_task'), isNull);
    });

    test('restores orphaned works after a restart', () async {
      SharedPreferences.setMockInitialValues({
        'cbeta_orphaned_works': jsonEncode(['X0001', 'X0002']),
      });
      final restored = buildManager();
      await restored.initialize();

      expect(restored.orphanedWorks, ['X0001', 'X0002']);
      expect(restored.progress.removedWorks, 2);

      restored.clearOrphanedWorks();
      expect(restored.orphanedWorks, isEmpty);
      final prefs = await SharedPreferences.getInstance();
      await _waitFor(() => prefs.getString('cbeta_orphaned_works') == null);
    });

    test('resumes after the catalog phase failed', () async {
      catalog.failNext = true;
      catalogChanged(
        newWorks: {
          ...initialCatalog,
          'T0003': const AllWorksEntry(
            work: 'T0003',
            title: '增壹阿含經',
            juans: ['1'],
          ),
        },
      );

      expect(await manager.start(), isTrue);
      await _waitFor(() => manager.status == UpdateStatus.failed);

      expect(catalog.calls, 1);
      expect(manager.canResume, isTrue);
      expect(manager.pendingWorkCount, 0);

      addArchive('T0003', ['1']);
      manager.resume();
      await _waitFor(() => manager.status == UpdateStatus.completed);

      expect(catalog.calls, 2);
      expect(manager.progress.checkedWorks, 1);
      expect(manager.progress.updatedWorks, 1);
    });

    test('refuses to start while scriptures are downloading', () async {
      downloads.downloading = true;

      expect(await manager.start(), isFalse);
      expect(catalog.calls, 0);
      expect(manager.isUpdating, isFalse);
    });

    test('ignores downloads after the task is deleted mid-run', () async {
      catalogChanged(
        newWorks: {
          ...initialCatalog,
          'T0003': const AllWorksEntry(
            work: 'T0003',
            title: '增壹阿含經',
            juans: ['1'],
          ),
        },
      );
      addArchive('T0003', ['1']);
      final gate = Completer<void>();
      final entered = Completer<void>();
      scripture.beforeHead = (work) async {
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
      expect(downloads.stored, isEmpty);
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
  final Map<String, List<CachedScriptureVolume>> stored = {};
  final Map<String, String?> storedReleases = {};
  bool downloading = false;

  @override
  bool get isDownloading => downloading;

  @override
  Set<String> get downloadedWorkIds => {
    ...initialVersions.map((version) => version.work),
    ...stored.keys,
  };

  @override
  Future<int> storeDownloadedWork(
    String work,
    Iterable<CachedScriptureVolume> volumes, {
    String? release,
  }) async {
    final list = volumes.toList();
    stored[work] = list;
    storedReleases[work] = release;
    return list.length;
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
  final Map<String, WorkArchive> archives = {};
  final Set<String> noHtml = {};
  final Map<String, Object> headErrors = {};
  final List<String> headCalls = [];
  Future<void> Function(String work)? beforeHead;
  WorkHeadInfo head = const WorkHeadInfo(contentLength: 128);
  int archiveDownloads = 0;

  @override
  Future<WorkHeadInfo> headWork(String work) async {
    headCalls.add(work);
    final hook = beforeHead;
    if (hook != null) await hook(work);
    final error = headErrors[work];
    if (error != null) throw error;
    if (noHtml.contains(work)) {
      throw const ScriptureHttpException(404, '檢查經文失敗：HTTP 404');
    }
    return head;
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
}

class _FakeIndexUpdateService extends IndexUpdateService {
  int requestCalls = 0;
  int startCalls = 0;

  @override
  void requestUpdate() {
    requestCalls++;
  }

  @override
  Future<bool> startIfNeeded() async {
    startCalls++;
    return false;
  }
}
