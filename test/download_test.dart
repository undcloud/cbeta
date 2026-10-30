import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xuefo/download/api_rate_limiter.dart';
import 'package:xuefo/download/catalog_cache.dart';
import 'package:xuefo/download/download_manager.dart';
import 'package:xuefo/download/download_models.dart';
import 'package:xuefo/download/download_notifications.dart';
import 'package:xuefo/download/download_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ApiRateLimiter', () {
    test('serializes requests and limits them per second', () async {
      final limiter = ApiRateLimiter(maxPerSecond: 2);
      final events = <String>[];
      final stopwatch = Stopwatch()..start();
      Future<void> request(String name) => limiter.run(() async {
        events.add('start-$name');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        events.add('end-$name');
      });

      await Future.wait([request('a'), request('b'), request('c')]);
      stopwatch.stop();

      expect(events, [
        'start-a',
        'end-a',
        'start-b',
        'end-b',
        'start-c',
        'end-c',
      ]);
      expect(
        stopwatch.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 900)),
      );
    });
  });

  group('DownloadItem', () {
    test('serializes to and from JSON', () {
      const item = DownloadItem(
        work: 'T0001',
        title: '長阿含經',
        juans: ['1', '2', '3'],
        creators: '佛陀耶舍',
        category: '阿含部類',
      );
      final json = item.toJson();
      final restored = DownloadItem.fromJson(json);
      expect(restored.work, 'T0001');
      expect(restored.title, '長阿含經');
      expect(restored.juans, ['1', '2', '3']);
      expect(restored.creators, '佛陀耶舍');
      expect(restored.category, '阿含部類');
      expect(restored.totalJuans, 3);
    });

    test('totalJuans returns 1 when juans is empty', () {
      const item = DownloadItem(work: 'T0001', title: 'Test');
      expect(item.totalJuans, 1);
    });
  });

  group('DownloadGroup', () {
    test('serializes to and from JSON', () {
      const group = DownloadGroup(
        id: 'g1',
        label: 'Test Group',
        items: [
          DownloadItem(work: 'T0001', title: '經1', juans: ['1', '2']),
          DownloadItem(work: 'T0002', title: '經2', juans: ['1']),
        ],
      );
      final json = group.toJson();
      final restored = DownloadGroup.fromJson(json);
      expect(restored.id, 'g1');
      expect(restored.label, 'Test Group');
      expect(restored.items, hasLength(2));
      expect(restored.totalJuans, 3);
    });
  });

  group('LocalVersion', () {
    test('serializes to and from JSON', () {
      final now = DateTime.utc(2024, 1, 15, 10, 30);
      final version = LocalVersion(
        work: 'T0001',
        juan: '1',
        ver: '2023Q4',
        release: '2026.R2',
        savedAt: now,
      );
      final json = version.toJson();
      final restored = LocalVersion.fromJson(json);
      expect(restored.work, 'T0001');
      expect(restored.juan, '1');
      expect(restored.ver, '2023Q4');
      expect(restored.release, '2026.R2');
      expect(restored.savedAt, now);
      expect(restored.key, 'T0001:1');
    });

    test('reads old records without a release field', () {
      final restored = LocalVersion.fromJson({
        'work': 'T0001',
        'juan': '1',
        'ver': 'v1',
        'savedAt': DateTime.utc(2024, 1, 15).toIso8601String(),
      });
      expect(restored.release, isNull);
    });
  });

  group('DownloadProgress', () {
    test('calculates fraction correctly', () {
      const progress = DownloadProgress(
        totalItems: 10,
        completedItems: 5,
        failedItems: 0,
        totalJuans: 100,
        completedJuans: 50,
      );
      expect(progress.fraction, 0.5);
      expect(progress.isComplete, false);
    });

    test('isComplete when all items done', () {
      const progress = DownloadProgress(
        totalItems: 10,
        completedItems: 8,
        failedItems: 2,
        totalJuans: 100,
        completedJuans: 80,
      );
      expect(progress.isComplete, true);
    });

    test('fraction is 0 when totalJuans is 0', () {
      const progress = DownloadProgress(
        totalItems: 0,
        completedItems: 0,
        failedItems: 0,
        totalJuans: 0,
        completedJuans: 0,
      );
      expect(progress.fraction, 0);
    });
  });

  group('formatDownloadSpeed', () {
    test('formats speeds below one megabyte as KB/s', () {
      expect(formatDownloadSpeed(0), '0.0 KB/s');
      expect(formatDownloadSpeed(512 * 1024), '512.0 KB/s');
    });

    test('formats speeds at or above one megabyte as MB/s', () {
      expect(formatDownloadSpeed(1024 * 1024), '1.00 MB/s');
      expect(formatDownloadSpeed(1.5 * 1024 * 1024), '1.50 MB/s');
    });
  });

  group('DownloadNotificationService', () {
    const channel = MethodChannel('xuefo/download_notifications');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('forwards notification taps and pending open requests', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final service = DownloadNotificationService();
      var opened = 0;
      service
        ..initialize()
        ..onOpenDownloadManager = () => opened++;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'consumeOpenDownloadManager') return true;
        return null;
      });

      await messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('openDownloadManager'),
        ),
        (_) {},
      );

      expect(opened, 1);
      expect(await service.consumePendingOpenRequest(), isTrue);
    });
  });

  group('DownloadStore', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('download_store_test');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('saves and loads queue', () async {
      final store = DownloadStore(directoryProvider: () async => tempDir);
      const groups = [
        DownloadGroup(
          id: 'g1',
          label: 'Group 1',
          items: [
            DownloadItem(work: 'T0001', title: '經1', juans: ['1']),
          ],
        ),
      ];
      await store.saveQueue(groups);
      final loaded = await store.loadQueue();
      expect(loaded, hasLength(1));
      expect(loaded.first.id, 'g1');
      expect(loaded.first.items.first.work, 'T0001');
    });

    test('saves and loads versions', () async {
      final store = DownloadStore(directoryProvider: () async => tempDir);
      final versions = {
        'T0001:1': LocalVersion(
          work: 'T0001',
          juan: '1',
          ver: '2023Q4',
          savedAt: DateTime.utc(2024, 1, 15),
        ),
      };
      await store.saveVersions(versions);
      final loaded = await store.loadVersions();
      expect(loaded, hasLength(1));
      expect(loaded['T0001:1']?.ver, '2023Q4');
    });

    test('clears queue and versions', () async {
      final store = DownloadStore(directoryProvider: () async => tempDir);
      await store.saveQueue([
        const DownloadGroup(id: 'g1', label: 'G', items: []),
      ]);
      await store.saveVersions({
        'T0001:1': LocalVersion(
          work: 'T0001',
          juan: '1',
          ver: 'v1',
          savedAt: DateTime.now(),
        ),
      });
      await store.clearQueue();
      await store.clearVersions();
      expect(await store.loadQueue(), isEmpty);
      expect(await store.loadVersions(), isEmpty);
    });

    test('returns empty when files do not exist', () async {
      final store = DownloadStore(directoryProvider: () async => tempDir);
      expect(await store.loadQueue(), isEmpty);
      expect(await store.loadVersions(), isEmpty);
    });

    test('handles corrupted JSON gracefully', () async {
      final store = DownloadStore(directoryProvider: () async => tempDir);
      final dir = Directory('${tempDir.path}/cbeta_downloads');
      await dir.create(recursive: true);
      await File('${dir.path}/queue.json').writeAsString('not json');
      await File('${dir.path}/versions.json').writeAsString('{bad');
      expect(await store.loadQueue(), isEmpty);
      expect(await store.loadVersions(), isEmpty);
    });
  });

  group('DownloadManager', () {
    late Directory tempDir;
    late DownloadStore store;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('download_manager_test');
      store = DownloadStore(directoryProvider: () async => tempDir);
      downloadStore = store;
      CatalogCache.instance.debugReset();
      CatalogCache.instance.debugLoad(
        allWorks: const {
          'T0001': AllWorksEntry(
            work: 'T0001',
            title: '長阿含經',
            juans: ['1', '2'],
          ),
          'T0002': AllWorksEntry(work: 'T0002', title: '七佛經', juans: ['1']),
        },
      );
    });

    tearDown(() async {
      downloadStore = DownloadStore();
      CatalogCache.instance.debugReset();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'restores an interrupted queue and reports downloaded works',
      () async {
        await store.saveQueue([
          const DownloadGroup(
            id: 'g1',
            label: '阿含部類',
            items: [
              DownloadItem(work: 'T0001', title: '長阿含經', juans: ['1', '2']),
              DownloadItem(work: 'T0002', title: '七佛經', juans: ['1']),
            ],
          ),
        ]);
        await store.saveVersions({
          'T0001:1': LocalVersion(
            work: 'T0001',
            juan: '1',
            ver: 'v1',
            savedAt: DateTime.utc(2026, 10, 25),
          ),
          'T0002:1': LocalVersion(
            work: 'T0002',
            juan: '1',
            ver: 'v1',
            savedAt: DateTime.utc(2026, 10, 25),
          ),
        });

        final manager = DownloadManager();
        await manager.initialize();

        expect(manager.downloadedWorkCount, 2);
        expect(manager.downloadedJuanCount, 2);
        expect(manager.isWorkDownloaded('T0002'), isTrue);
        expect(manager.isWorkPartiallyDownloaded('T0001'), isTrue);
        expect(manager.hasQueuedItems, isTrue);
        expect(manager.canResume, isTrue);
        expect(manager.status, DownloadStatus.pending);
      },
    );

    test(
      'does not offer resume when every queued juan is downloaded',
      () async {
        await store.saveQueue([
          const DownloadGroup(
            id: 'g1',
            label: '阿含部類',
            items: [
              DownloadItem(work: 'T0002', title: '七佛經', juans: ['1']),
            ],
          ),
        ]);
        await store.saveVersions({
          'T0002:1': LocalVersion(
            work: 'T0002',
            juan: '1',
            ver: 'v1',
            savedAt: DateTime.utc(2026, 10, 25),
          ),
        });

        final manager = DownloadManager();
        await manager.initialize();

        expect(manager.downloadedWorkCount, 1);
        expect(manager.hasQueuedItems, isFalse);
        expect(manager.canResume, isFalse);
        expect(manager.isWorkDownloaded('T0002'), isTrue);
        expect(manager.isWorkPartiallyDownloaded('T0002'), isFalse);
      },
    );

    test('deduplicates queued works and juans across groups', () async {
      final manager = DownloadManager();
      manager.addToQueue([
        const DownloadGroup(
          id: 'g1',
          label: '阿含部類（2 部）',
          items: [
            DownloadItem(work: 'T0001', title: '長阿含經', juans: ['1', '2']),
            DownloadItem(work: 'T0002', title: '七佛經', juans: ['1']),
          ],
        ),
        const DownloadGroup(
          id: 'g2',
          label: '阿含部類（2 部）',
          items: [
            DownloadItem(work: 'T0001', title: '長阿含經', juans: ['2', '1', '3']),
            DownloadItem(work: 'T0002', title: '七佛經', juans: ['1']),
          ],
        ),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(manager.queue, hasLength(1));
      expect(manager.queue.single.id, 'g1');
      expect(manager.queue.single.items, hasLength(2));
      expect(manager.queue.single.label, '阿含部類（2 部）');
      expect(
        manager.queue.single.items
            .firstWhere((item) => item.work == 'T0001')
            .juans,
        ['1', '2', '3'],
      );
      expect(manager.pendingWorkCount, 2);
      expect(manager.pendingJuanCount, 4);
    });

    test('normalizes duplicate saved queue and counts pending juans', () async {
      await store.saveQueue([
        const DownloadGroup(
          id: 'g1',
          label: '阿含部類（2 部）',
          items: [
            DownloadItem(work: 'T0001', title: '長阿含經', juans: ['1', '2']),
            DownloadItem(work: 'T0002', title: '七佛經', juans: ['1']),
          ],
        ),
        const DownloadGroup(
          id: 'g2',
          label: '阿含部類（2 部）',
          items: [
            DownloadItem(work: 'T0001', title: '長阿含經', juans: ['2']),
            DownloadItem(work: 'T0002', title: '七佛經', juans: ['1']),
          ],
        ),
      ]);
      await store.saveVersions({
        'T0001:1': LocalVersion(
          work: 'T0001',
          juan: '1',
          ver: 'v1',
          savedAt: DateTime.utc(2026, 10, 25),
        ),
        'T0002:1': LocalVersion(
          work: 'T0002',
          juan: '1',
          ver: 'v1',
          savedAt: DateTime.utc(2026, 10, 25),
        ),
      });

      final manager = DownloadManager();
      await manager.initialize();

      expect(manager.queue, hasLength(1));
      expect(manager.queue.single.items, hasLength(2));
      expect(manager.pendingWorkCount, 1);
      expect(manager.pendingJuanCount, 1);
      expect(
        manager.queue.single.items
            .firstWhere((item) => item.work == 'T0001')
            .juans,
        ['1', '2'],
      );

      final saved = await store.loadQueue();
      expect(saved, hasLength(1));
      expect(saved.single.items, hasLength(2));
      expect(
        saved.single.items.firstWhere((item) => item.work == 'T0001').juans,
        ['1', '2'],
      );
    });
  });
}
