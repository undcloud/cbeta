import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xuefo/download/download_notifications.dart';
import 'package:xuefo/scripture/cache.dart';
import 'package:xuefo/scripture/index_maintenance.dart';
import 'package:xuefo/scripture/index_update_notification.dart';
import 'package:xuefo/scripture/index_update_service.dart';

class _FakeVolumeStore extends ScriptureVolumeStore {
  @override
  Future<List<ScriptureVolumeRef>> listRefs() async => const [
    ScriptureVolumeRef(work: 'T01', juan: '1', path: '/tmp/T01-1.json'),
  ];
}

class _FakeMaintenance extends ScriptureIndexMaintenance {
  _FakeMaintenance(this.onRebuild);

  final Future<void> Function() onRebuild;

  @override
  ScriptureVolumeStore get volumeStore => _FakeVolumeStore();

  @override
  Future<int> rebuildIndexes({
    void Function(int done, int total)? onProgress,
    bool Function()? shouldAbort,
    Future<void> Function()? beforeBatch,
    int batchSize = 256,
  }) async {
    if (beforeBatch != null) await beforeBatch();
    await onRebuild();
    onProgress?.call(3, 3);
    return 3;
  }
}

class _FakeNotifications extends DownloadNotificationService {
  int starts = 0;
  int updates = 0;
  int stops = 0;

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
  }

  @override
  Future<void> update({
    required String title,
    required String text,
    required int progress,
    required int max,
  }) async {
    updates++;
  }

  @override
  Future<void> stop() async {
    stops++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<IndexUpdateService> buildService(
    Future<void> Function() onRebuild,
  ) async {
    final service = IndexUpdateService(
      maintenance: _FakeMaintenance(onRebuild),
      prefsProvider: SharedPreferences.getInstance,
      busyPollInterval: const Duration(milliseconds: 1),
    );
    await service.initialize();
    return service;
  }

  test('shows the shared foreground notification while rebuilding', () async {
    final gate = Completer<void>();
    final service = await buildService(() => gate.future);
    final notifications = _FakeNotifications();
    final notifier = IndexUpdateNotification(
      service: service,
      notifications: notifications,
    )..initialize();
    addTearDown(notifier.dispose);

    expect(await service.startIfNeeded(), isTrue);
    await pumpEventQueue();
    expect(notifications.starts, 1);

    gate.complete();
    await service.waitForCompletion();
    await pumpEventQueue();
    expect(notifications.stops, 1);
  });

  test('leaves the notification alone while a download owns it', () async {
    final gate = Completer<void>();
    final service = await buildService(() => gate.future);
    final notifications = _FakeNotifications();
    final notifier = IndexUpdateNotification(
      service: service,
      notifications: notifications,
    )..initialize();
    notifier.otherTaskActive = () => true;
    addTearDown(notifier.dispose);

    expect(await service.startIfNeeded(), isTrue);
    await pumpEventQueue();
    expect(notifications.starts, 0);

    gate.complete();
    await service.waitForCompletion();
    await pumpEventQueue();
    expect(notifications.stops, 0);
  });
}
