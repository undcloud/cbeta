import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xuefo/scripture/cache.dart';
import 'package:xuefo/scripture/offline_scan.dart';
import 'package:xuefo/scripture/parser.dart';
import 'package:xuefo/scripture/source_text.dart';

Future<void> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('等待條件逾時');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late ScriptureVolumeStore previousStore;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('offline_scan_test');
    previousStore = scriptureVolumeStore;
    scriptureVolumeStore = ScriptureVolumeStore(
      directoryProvider: () async => tempDir,
    );
  });

  tearDown(() async {
    scriptureVolumeStore = previousStore;
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<void> seedVolumes(int count) async {
    for (var index = 1; index <= count; index++) {
      final work = 'T${index.toString().padLeft(4, '0')}';
      await scriptureVolumeStore.write(
        CachedScriptureVolume(
          work: work,
          juan: '1',
          html:
              '<div id="body">'
              '<p class="juan">測試經$index卷第一</p>'
              '<span class="lb" id="${work.toLowerCase()}n0001_p0001a01"></span>'
              '<span class="t">般若波羅蜜多心經第$index卷</span>'
              '</div>',
        ),
      );
    }
  }

  test(
    'offline scan keeps advancing on its own until every volume is done',
    () async {
      await seedVolumes(25);
      final session = OfflineScanSession('般若');
      addTearDown(session.dispose);

      await session.prepare();
      expect(session.totalVolumes, 25);
      expect(session.scannedVolumes, 0);

      await session.scanChunk();
      expect(session.scannedVolumes, OfflineScanSession.volumesPerChunk);
      expect(
        session.current.results.length,
        OfflineScanSession.volumesPerChunk,
      );
      expect(session.finished, isFalse);

      // 交給背景掃描自行推進：沒有捲動、沒有按鈕,也要一路掃到最後一卷。
      session.start();
      await _waitFor(() => session.finished && !session.scanning);
      expect(session.scannedVolumes, 25);
      expect(session.current.results.length, 25);
      expect(session.current.termHits, 25);
      expect(session.scanning, isFalse);
    },
  );

  test('paused offline scan stops and resumes where it left off', () async {
    await seedVolumes(25);
    final session = OfflineScanSession('般若');
    addTearDown(session.dispose);

    await session.prepare();
    session.start();
    await _waitFor(
      () => session.scannedVolumes >= OfflineScanSession.volumesPerChunk,
    );
    session.pause();

    final frozen = session.scannedVolumes;
    expect(session.scanning, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(session.scannedVolumes, frozen);

    session.resume();
    expect(session.scanning, isTrue);
    await _waitFor(() => session.finished);
    expect(session.scannedVolumes, 25);
  });

  test(
    'offline scan reports progress without waiting for the whole run',
    () async {
      await seedVolumes(30);
      final session = OfflineScanSession('般若');
      addTearDown(session.dispose);

      final snapshots = <int>[];
      session.progress.addListener(
        () => snapshots.add(session.current.scannedVolumes),
      );
      await session.prepare();
      session.start();
      await _waitFor(() => session.finished);

      expect(snapshots.first, lessThan(30));
      expect(snapshots.last, 30);
    },
  );

  test('offline scan with no local volumes finishes immediately', () async {
    final session = OfflineScanSession('般若');
    addTearDown(session.dispose);

    await session.prepare();
    session.start();
    await _waitFor(() => session.finished);
    expect(session.totalVolumes, 0);
    expect(session.current.results, isEmpty);
  });

  test(
    'offline keyword matching ignores case of latin and keeps context',
    () async {
      await seedVolumes(1);
      final outcome = await runOfflineScan(
        OfflineScanRequest(
          needle: '波羅蜜',
          targets: [
            OfflineScanTarget(
              work: 'T0001',
              juan: '1',
              path: '${tempDir.path}/cbeta_scripture/T0001-1.json',
            ),
          ],
          juansByWork: const {
            'T0001': [1],
          },
        ),
      );
      expect(outcome.results, hasLength(1));
      final passage = outcome.results.single.passages.single;
      expect(passage.text, contains('般若波羅蜜'));
      expect(outcome.termHits, 1);

      final volume = await scriptureVolumeStore.read('T0001', '1');
      final lines = parseScriptureHtml(volume!.html);
      final source = buildScriptureSearchSource(lines);
      expect(passage.sourceOffset, source.indexOf('波羅蜜'));
      expect(passage.snippet, '波羅蜜');
    },
  );

  test(
    'offline scan offsets match the layout source across verse lines',
    () async {
      const html =
          '<div id="body">'
          '<p class="juan">測試經卷第一</p>'
          '<span class="lb" id="T0001_p0001a01"></span>'
          '<div class="lg-row">'
          '<div class="lg-cell">自他俱入甘露城，</div>'
          '<div class="lg-cell">同證一如真法界。</div></div>'
          '<span class="lb" id="T0001_p0001a02"></span>'
          '<p>太子又問：云何名死？瑜誐答言：五蘊壞滅，名之為死。</p>'
          '<span class="lb" id="T0001_p0001a03"></span>'
          '<p>復次大眾聞是法已，歡喜奉行。</p>'
          '</div>';
      await scriptureVolumeStore.write(
        const CachedScriptureVolume(work: 'T0001', juan: '1', html: html),
      );
      final outcome = await runOfflineScan(
        OfflineScanRequest(
          needle: '五蘊',
          targets: [
            OfflineScanTarget(
              work: 'T0001',
              juan: '1',
              path: '${tempDir.path}/cbeta_scripture/T0001-1.json',
            ),
          ],
          juansByWork: const {
            'T0001': [1],
          },
        ),
      );
      final lines = parseScriptureHtml(html);
      final source = buildScriptureSearchSource(lines);
      final passage = outcome.results.single.passages.single;
      final expected = source.indexOf('五蘊');
      expect(expected, greaterThan(0));
      expect(passage.sourceOffset, expected);
      expect(source.startsWith('五蘊壞滅', expected), isTrue);
      expect(passage.snippet, '五蘊');
    },
  );
}
