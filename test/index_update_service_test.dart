import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xuefo/scripture/cache.dart';
import 'package:xuefo/scripture/index_maintenance.dart';
import 'package:xuefo/scripture/index_update_service.dart';
import 'package:xuefo/scripture/index_update_status.dart';

class _FakeVolumeStore extends ScriptureVolumeStore {
  _FakeVolumeStore(this.refs);

  final List<ScriptureVolumeRef> refs;

  @override
  Future<List<ScriptureVolumeRef>> listRefs() async => refs;
}

class _FakeMaintenance extends ScriptureIndexMaintenance {
  _FakeMaintenance({required this.store, this.onRebuild});

  final _FakeVolumeStore store;
  final Future<void> Function()? onRebuild;
  int rebuildCalls = 0;

  @override
  ScriptureVolumeStore get volumeStore => store;

  @override
  Future<int> rebuildIndexes({
    void Function(int done, int total)? onProgress,
    bool Function()? shouldAbort,
    Future<void> Function()? beforeBatch,
    int batchSize = 256,
  }) async {
    rebuildCalls += 1;
    if (beforeBatch != null) await beforeBatch();
    if (onRebuild != null) await onRebuild!();
    onProgress?.call(3, 3);
    return 3;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const volume = ScriptureVolumeRef(
    work: 'T01',
    juan: '1',
    path: '/tmp/T01-1.json',
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  IndexUpdateService buildService(
    _FakeMaintenance maintenance, {
    Duration poll = const Duration(milliseconds: 1),
  }) => IndexUpdateService(
    maintenance: maintenance,
    prefsProvider: SharedPreferences.getInstance,
    busyPollInterval: poll,
  );

  test(
    'missing marker rebuilds local volumes and stores the version',
    () async {
      final maintenance = _FakeMaintenance(
        store: _FakeVolumeStore(const [volume]),
      );
      final service = buildService(maintenance);
      await service.initialize();

      expect(service.needsUpdate, isTrue);
      expect(await service.startIfNeeded(), isTrue);
      await service.waitForCompletion();

      expect(maintenance.rebuildCalls, 1);
      expect(service.progress.phase, IndexUpdatePhase.completed);
      expect(service.progress.done, 3);
      expect(service.progress.total, 3);
      expect(service.needsUpdate, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(indexVersionPreferenceKey), currentIndexVersion);
    },
  );

  test('current marker skips the rebuild', () async {
    SharedPreferences.setMockInitialValues({
      indexVersionPreferenceKey: currentIndexVersion,
    });
    final maintenance = _FakeMaintenance(
      store: _FakeVolumeStore(const [volume]),
    );
    final service = buildService(maintenance);
    await service.initialize();

    expect(service.needsUpdate, isFalse);
    expect(await service.startIfNeeded(), isFalse);
    expect(maintenance.rebuildCalls, 0);
  });

  test('dirty marker rebuilds even when the version is current', () async {
    SharedPreferences.setMockInitialValues({
      indexVersionPreferenceKey: currentIndexVersion,
      indexDirtyPreferenceKey: true,
    });
    final maintenance = _FakeMaintenance(
      store: _FakeVolumeStore(const [volume]),
    );
    final service = buildService(maintenance);
    await service.initialize();

    expect(service.needsUpdate, isTrue);
    expect(await service.startIfNeeded(), isTrue);
    await service.waitForCompletion();

    expect(maintenance.rebuildCalls, 1);
    expect(service.needsUpdate, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(indexDirtyPreferenceKey), isNull);
  });

  test('requestUpdate before initialize still triggers a rebuild', () async {
    final maintenance = _FakeMaintenance(
      store: _FakeVolumeStore(const [volume]),
    );
    final service = buildService(maintenance);
    service.requestUpdate();
    await service.initialize();

    expect(service.isDirty, isTrue);
    expect(service.needsUpdate, isTrue);
    expect(await service.startIfNeeded(), isTrue);
    await service.waitForCompletion();

    expect(maintenance.rebuildCalls, 1);
    expect(service.needsUpdate, isFalse);
  });

  test('no local volumes only records the version', () async {
    final maintenance = _FakeMaintenance(store: _FakeVolumeStore(const []));
    final service = buildService(maintenance);
    await service.initialize();

    expect(await service.startIfNeeded(), isFalse);
    expect(maintenance.rebuildCalls, 0);
    expect(service.progress.phase, IndexUpdatePhase.idle);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(indexVersionPreferenceKey), currentIndexVersion);
  });

  test('downloads pause the rebuild until they finish', () async {
    var busy = true;
    final maintenance = _FakeMaintenance(
      store: _FakeVolumeStore(const [volume]),
    );
    final service = buildService(maintenance)..isBusy = () => busy;
    await service.initialize();

    expect(await service.startIfNeeded(), isTrue);
    expect(service.progress.phase, IndexUpdatePhase.preparing);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(maintenance.rebuildCalls, 0);

    busy = false;
    await service.waitForCompletion();
    expect(maintenance.rebuildCalls, 1);
    expect(service.progress.phase, IndexUpdatePhase.completed);
  });

  test('concurrent start requests run a single rebuild', () async {
    final gate = Completer<void>();
    final maintenance = _FakeMaintenance(
      store: _FakeVolumeStore(const [volume]),
      onRebuild: () => gate.future,
    );
    final service = buildService(maintenance);
    await service.initialize();

    expect(await service.startIfNeeded(), isTrue);
    expect(await service.startIfNeeded(), isFalse);
    expect(maintenance.rebuildCalls, 1);

    gate.complete();
    await service.waitForCompletion();
    expect(service.progress.phase, IndexUpdatePhase.completed);
  });

  test('overlapping startup calls share the same start', () async {
    final maintenance = _FakeMaintenance(
      store: _FakeVolumeStore(const [volume]),
    );
    final service = buildService(maintenance);

    final first = service.startIfNeeded();
    final second = service.startIfNeeded();
    expect(await first, isTrue);
    expect(await second, isTrue);

    await service.waitForCompletion();
    expect(maintenance.rebuildCalls, 1);
    expect(service.progress.phase, IndexUpdatePhase.completed);
  });

  test('failure keeps the old marker so the next run retries', () async {
    final maintenance = _FakeMaintenance(
      store: _FakeVolumeStore(const [volume]),
      onRebuild: () async => throw StateError('boom'),
    );
    final service = buildService(maintenance);
    await service.initialize();

    expect(await service.startIfNeeded(), isTrue);
    await service.waitForCompletion();

    expect(service.progress.phase, IndexUpdatePhase.failed);
    expect(service.needsUpdate, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(indexVersionPreferenceKey), isNull);
  });

  testWidgets('status view shows rebuild progress', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: IndexUpdateStatusView(
            progress: IndexUpdateProgress(
              phase: IndexUpdatePhase.running,
              done: 5,
              total: 10,
              message: '正在更新搜尋索引：5/10 卷',
            ),
          ),
        ),
      ),
    );

    expect(find.text('搜尋索引更新'), findsOneWidget);
    expect(find.text('正在更新搜尋索引：5/10 卷'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });
}
