import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xuefo/scripture/cache.dart';
import 'package:xuefo/scripture/index_maintenance.dart';
import 'package:xuefo/scripture/offline_scan.dart';
import 'package:xuefo/scripture/parser.dart';
import 'package:xuefo/scripture/sidx_store.dart';
import 'package:xuefo/scripture/source_text.dart';
import 'package:xuefo/search/conversion.dart';
import 'package:xuefo/search/passage_resolver.dart';

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

  /// 每卷都含「般若波羅蜜多心經第N卷」，另有一卷只有簡體輸入才打得到的字。
  Future<void> seedVolumes(int count) async {
    for (var index = 1; index <= count; index++) {
      final work = 'T${index.toString().padLeft(4, '0')}';
      await scriptureVolumeStore.write(
        CachedScriptureVolume(
          work: work,
          juan: '1',
          contentVersion: 'v$index',
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

  Future<List<OfflineScanTarget>> targetsFor(int count) async {
    final refs = await scriptureVolumeStore.listRefs();
    expect(refs, hasLength(count));
    return [
      for (final ref in refs)
        OfflineScanTarget(work: ref.work, juan: ref.juan, path: ref.path ?? ''),
    ];
  }

  OfflineScanRequest requestFor(
    String query,
    List<OfflineScanTarget> targets,
  ) => OfflineScanRequest(
    slotCandidates: [
      for (final slot in buildOfflinePattern(query).slots) slot.toList(),
    ],
    targets: targets,
  );

  test('卷題留在正文，離線掃描與展開都能命中', () async {
    await seedVolumes(1);
    final targets = await targetsFor(1);
    final outcome = await runOfflineScan(requestFor('測試經1卷第一', targets));

    expect(outcome.termHits, 1);
    final group = outcome.groups.single;
    final passages = await expandOfflineWork(
      work: group.work,
      hits: group.hits,
      query: '測試經1卷第一',
      availableJuans: const [1],
    );
    expect(passages, hasLength(1));
    expect(passages.single.snippet.trim(), '測試經1卷第一');
    expect(passages.single.linehead, isNull);
    expect(passages.single.sourceOffset, 0);
  });

  test('離線掃描自行連續推進到掃完，結果先只有行號', () async {
    await seedVolumes(25);
    final session = OfflineScanSession('般若波羅蜜');
    addTearDown(session.dispose);

    await session.prepare();
    expect(session.totalVolumes, 25);
    expect(session.scannedVolumes, 0);

    await session.scanChunk();
    expect(session.scannedVolumes, OfflineScanSession.volumesPerChunk);
    expect(session.current.results.length, OfflineScanSession.volumesPerChunk);
    // 第一階段不解析 HTML 出摘要，只交代定位資訊。
    for (final result in session.current.results) {
      expect(result.passages, isEmpty);
      expect(result.pendingHits, isNotEmpty);
      expect(result.workId, isNotEmpty);
    }
    expect(session.finished, isFalse);

    session.start();
    await _waitFor(() => session.finished && !session.scanning);
    expect(session.scannedVolumes, 25);
    expect(session.current.results.length, 25);
    expect(session.current.termHits, 25);
    expect(session.scanning, isFalse);
  });

  test('暫停後不再排下一塊，恢復後從中斷處繼續', () async {
    // 卷數要明顯多過兩塊，否則暫停時最後一塊可能已經在路上，會誤判成掃完。
    await seedVolumes(100);
    final session = OfflineScanSession('般若波羅蜜');
    addTearDown(session.dispose);

    await session.prepare();
    session.start();
    await _waitFor(
      () => session.scannedVolumes >= OfflineScanSession.volumesPerChunk,
    );
    session.pause();
    expect(session.scanning, isFalse);
    // 暫停只管「不再排下一塊」，已經交出去的這一塊仍會跑完。
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final frozen = session.scannedVolumes;
    expect(session.finished, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(session.scannedVolumes, frozen);

    session.resume();
    expect(session.scanning, isTrue);
    await _waitFor(() => session.finished);
    expect(session.scannedVolumes, 100);
  });

  test('進度會持續回報，不必等整輪掃完', () async {
    await seedVolumes(30);
    final session = OfflineScanSession('般若波羅蜜');
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
  });

  test('沒有本地經卷時立即結束', () async {
    final session = OfflineScanSession('般若波羅蜜');
    addTearDown(session.dispose);

    await session.prepare();
    session.start();
    await _waitFor(() => session.finished);
    expect(session.totalVolumes, 0);
    expect(session.current.results, isEmpty);
  });

  test('首輪建索引、次輪直接重用 .sidx', () async {
    await seedVolumes(3);
    final request = requestFor('般若', await targetsFor(3));
    final indexStore = ScriptureIndexStore(
      directoryProvider: () async => tempDir,
    );

    final first = await runOfflineScan(request);
    expect(first.groups, hasLength(3));
    expect(first.termHits, 3);
    expect(first.builtIndexes, 3);
    final sidxPath = await indexStore.pathFor(work: 'T0001', juan: '1');
    expect(File(sidxPath!).existsSync(), isTrue);

    final second = await runOfflineScan(request);
    expect(second.termHits, 3);
    // 派生物就位後不再碰 HTML。
    expect(second.builtIndexes, 0);

    for (final group in second.groups) {
      expect(group.title, startsWith('測試經'));
      expect(group.hits.single.juan, '1');
      expect(group.hits.single.linehead, contains('_p0001a01'));
    }
  });

  test('經卷內容更新後舊索引戳記失效並重建', () async {
    await seedVolumes(1);
    final request = requestFor('波羅蜜', await targetsFor(1));
    expect((await runOfflineScan(request)).builtIndexes, 1);
    expect((await runOfflineScan(request)).builtIndexes, 0);

    await scriptureVolumeStore.write(
      CachedScriptureVolume(
        work: 'T0001',
        juan: '1',
        contentVersion: 'v99',
        html:
            '<div id="body">'
            '<p class="juan">測試經1卷第一</p>'
            '<span class="lb" id="t0001n0001_p0001a01"></span>'
            '<span class="t">新的正文不含關鍵字</span>'
            '</div>',
      ),
    );
    final after = await runOfflineScan(request);
    expect(after.builtIndexes, 1);
    expect(after.termHits, 0);
  });

  test('罕見字查詢靠字符集跳卷，正文一個字節都不讀', () async {
    await seedVolumes(4);
    final targets = await targetsFor(4);
    // 先掃一轮把索引建好，才有「只讀標頭」這條路可走。
    expect((await runOfflineScan(requestFor('波羅', targets))).builtIndexes, 4);

    debugSidxBodyReads = 0;
    final outcome = await runOfflineScan(requestFor('槃', targets));
    expect(outcome.termHits, 0);
    expect(outcome.groups, isEmpty);
    expect(outcome.builtIndexes, 0);
    // 跳卷必須發生在讀正文之前：只碰標頭與字符集。
    expect(debugSidxBodyReads, 0);
    // 跳過不等於沒扫：掃描計數仍是全部卷數。
    expect(outcome.scannedVolumes, 4);

    debugSidxBodyReads = 0;
    expect((await runOfflineScan(requestFor('波羅', targets))).termHits, 4);
    expect(debugSidxBodyReads, 4);
  });

  test('第二段用 HTML 展開摘要，位移與原文都对得上', () async {
    await seedVolumes(2);
    final targets = await targetsFor(2);
    final outcome = await runOfflineScan(requestFor('波羅蜜多', targets));
    final work = outcome.groups.first.work;

    final passages = await expandOfflineWork(
      work: work,
      hits: outcome.groups.first.hits,
      query: '波羅蜜多',
      availableJuans: const [1],
    );
    expect(passages, hasLength(1));
    final passage = passages.single;
    expect(passage.work, work);
    expect(passage.juan, '1');
    expect(passage.linehead, contains('_p0001a01'));
    // 摘要取自帶標點原文，不是無標點的索引正文。
    expect(passage.snippet, '波羅蜜多');
    expect(passage.text, contains('般若波羅蜜多心經'));
    // 上下文停在卷題邊界，不會把「測試經N卷第一」掃成命中前面的文字。
    expect(passage.text, isNot(contains('測試經')));

    final refs = await scriptureVolumeStore.listRefs();
    final stored = await scriptureVolumeStore.readRef(refs.first);
    final source = buildScriptureSearchSource(parseScriptureHtml(stored!.html));
    final offset = passage.sourceOffset!;
    expect(offset, source.indexOf('波羅蜜多'));
    expect(source.substring(offset, offset + 4), '波羅蜜多');
    expect(passage.snippet, source.substring(offset, offset + 4));
  });

  test('展開完成後摘要取代待展開命中', () async {
    await seedVolumes(2);
    final session = OfflineScanSession('波羅蜜');
    addTearDown(session.dispose);
    await session.prepare();
    await session.scanChunk();

    final work = session.current.results.first.workId;
    expect(session.pendingHitsFor(work), isNotEmpty);
    final passages = await expandOfflineWork(
      work: work,
      hits: session.pendingHitsFor(work),
      query: '波羅蜜',
      availableJuans: session.juansFor(work),
    );
    expect(passages, isNotEmpty);

    session.applyPassages(work, passages);
    final result = session.current.results.firstWhere(
      (item) => item.workId == work,
    );
    expect(result.passages, hasLength(passages.length));
    expect(result.pendingHits, isEmpty);
    // 其他尚未展開的作品不受影響。
    final other = session.current.results.firstWhere(
      (item) => item.workId != work,
    );
    expect(other.passages, isEmpty);
    expect(other.pendingHits, isNotEmpty);
  });

  test('簡體輸入匹配繁體正文，且不會誤跳卷', () async {
    await SimplifiedTraditionalConverter.load();
    await seedVolumes(2);
    final outcome = await runOfflineScan(
      requestFor('般若波罗蜜', await targetsFor(2)),
    );
    expect(outcome.termHits, 2);
    expect(outcome.groups, hasLength(2));
  });

  test('查詢有無標點空格都一樣命中', () async {
    await seedVolumes(2);
    for (final query in ['般若波羅蜜', '般若，波羅 蜜', '般若　波\n羅蜜']) {
      final outcome = await runOfflineScan(
        requestFor(query, await targetsFor(2)),
      );
      expect(outcome.termHits, 2, reason: query);
    }
  });

  test('經卷沒有檔案路徑時也能在當前 isolate 掃描', () async {
    await seedVolumes(1);
    final outcome = await runOfflineScan(
      OfflineScanRequest(
        slotCandidates: [
          for (final slot in buildOfflinePattern('般若').slots) slot.toList(),
        ],
        targets: const [OfflineScanTarget(work: 'T0001', juan: '1', path: '')],
      ),
    );
    expect(outcome.groups, hasLength(1));
    expect(outcome.builtIndexes, 1);
    // 沒有路徑就不該落盤。
    expect(
      Directory(
        '${tempDir.path}${Platform.pathSeparator}cbeta_sidx',
      ).existsSync(),
      isFalse,
    );
  });

  test('KWIC 摘要帶上下文並以省略號收尾', () {
    const text = '如是我聞一時佛在王舍城鷲峰山中與大比丘眾俱萬二千人';
    final start = text.indexOf('王舍城');
    final snippet = offlineKwicSnippet(
      text,
      start,
      start + 3,
      before: 4,
      after: 4,
    );
    expect(snippet, contains('王舍城'));
    expect(snippet.startsWith('…'), isTrue);
    expect(snippet.endsWith('…'), isTrue);
    expect(snippet.length, lessThan(text.length + 2));
    expect(offlineKwicSnippet('王舍城', 0, 3), '王舍城');
  });

  test('主 isolate 的兜底掃描能被叫停，不會把整塊掃完', () async {
    await seedVolumes(8);
    final targets = await targetsFor(8);
    final request = requestFor('波羅蜜多', targets);
    var checks = 0;
    final aborted = await runOfflineScanInline(
      request,
      shouldAbort: () {
        checks++;
        return checks >= 2;
      },
    );
    // 叫停只保證「手上這一卷掃完就收工」，剩下的卷不該繼續排主執行緒。
    expect(aborted.scannedVolumes, lessThan(8));
    expect(aborted.termHits, lessThan(8));
    expect((await runOfflineScanInline(request)).scannedVolumes, 8);
  });

  test('展開摘要時換了搜尋就停手', () async {
    await seedVolumes(2);
    final targets = await targetsFor(2);
    final outcome = await runOfflineScan(requestFor('波羅蜜多', targets));
    final group = outcome.groups.first;

    final done = await expandOfflineWork(
      work: group.work,
      hits: group.hits,
      query: '波羅蜜多',
    );
    expect(done, isNotEmpty);
    final aborted = await expandOfflineWork(
      work: group.work,
      hits: group.hits,
      query: '波羅蜜多',
      shouldAbort: () => true,
    );
    expect(aborted, isEmpty);
  });

  test('經目兜底查詢能被叫停，不會讀完全部本地經卷', () async {
    await seedVolumes(8);
    var checks = 0;
    final aborted = await searchOfflineCatalog(
      '測試經',
      shouldAbort: () {
        checks++;
        return checks >= 3;
      },
    );
    expect(aborted.length, lessThan(8));
    expect(await searchOfflineCatalog('測試經'), hasLength(8));
  });

  test('常駐池跨掃描會話重用，離開頁面釋放後才重建', () {
    final pool = sharedOfflineScanPool();
    expect(sharedOfflineScanPool(), same(pool));
    releaseSharedOfflineScanPool();
    expect(sharedOfflineScanPool(), isNot(same(pool)));
    releaseSharedOfflineScanPool();
  });

  test('下載時預建索引：之後的掃描不必再解析 HTML', () async {
    await seedVolumes(3);
    final targets = await targetsFor(3);
    expect(await buildOfflineIndexBatch(targets), 3);

    final outcome = await runOfflineScan(requestFor('波羅蜜', targets));
    expect(outcome.builtIndexes, 0);
    expect(outcome.termHits, 3);
    // 同一批再建一次是增量：戳記沒變的卷直接跳過。
    expect(await buildOfflineIndexBatch(targets), 0);
  });

  test('建置佇列攢批交出去，flush 之後才全部落地', () async {
    await seedVolumes(5);
    final targets = await targetsFor(5);
    final queue = OfflineIndexQueue();
    for (final target in targets) {
      await queue.add(target.work, target.juan, target.path);
    }
    // 還不滿一批：下載還在跑時不為幾卷就派工。
    expect(queue.pendingTargets, hasLength(5));
    await queue.flush();
    expect(queue.pendingTargets, isEmpty);
    expect((await runOfflineScan(requestFor('波羅蜜', targets))).builtIndexes, 0);
  });

  test('.sidx 記憶體快取讓重複搜尋不再讀檔', () async {
    await seedVolumes(3);
    final targets = await targetsFor(3);
    final request = requestFor('波羅蜜', targets);
    await runOfflineScan(request);

    debugSidxBodyReads = 0;
    expect((await runOfflineScan(request)).termHits, 3);
    expect(debugSidxBodyReads, 3);

    debugSidxBodyReads = 0;
    expect((await runOfflineScan(request)).termHits, 3);
    expect(debugSidxBodyReads, 0);
  });

  test('同一部經再展開一次不重解析整卷', () async {
    await seedVolumes(2);
    final targets = await targetsFor(2);
    final outcome = await runOfflineScan(requestFor('波羅蜜多', targets));
    final group = outcome.groups.first;

    debugScriptureHtmlParses = 0;
    final first = await expandOfflineWork(
      work: group.work,
      hits: group.hits,
      query: '波羅蜜多',
    );
    expect(first, isNotEmpty);
    final parsed = debugScriptureHtmlParses;
    expect(parsed, greaterThan(0));

    debugScriptureHtmlParses = 0;
    final again = await expandOfflineWork(
      work: group.work,
      hits: group.hits,
      query: '波羅蜜多',
    );
    expect(debugScriptureHtmlParses, 0);
    expect(
      again.map((passage) => passage.text).toList(),
      first.map((passage) => passage.text).toList(),
    );
  });

  test('經卷改版後展開快取失效，摘要跟著換', () async {
    await seedVolumes(1);
    final targets = await targetsFor(1);
    final outcome = await runOfflineScan(requestFor('波羅蜜多', targets));
    final group = outcome.groups.first;
    expect(
      await expandOfflineWork(
        work: group.work,
        hits: group.hits,
        query: '波羅蜜多',
      ),
      isNotEmpty,
    );

    await scriptureVolumeStore.write(
      CachedScriptureVolume(
        work: 'T0001',
        juan: '1',
        contentVersion: 'v99',
        html:
            '<div id="body">'
            '<p class="juan">測試經1卷第一</p>'
            '<span class="lb" id="t0001n0001_p0001a01"></span>'
            '<span class="t">般若波羅蜜多心經改過了</span>'
            '</div>',
      ),
    );
    final passages = await expandOfflineWork(
      work: group.work,
      hits: outcome.groups.first.hits,
      query: '波羅蜜多',
    );
    expect(passages.single.text, contains('改過了'));
  });

  test('清除索引再重建：不用重下經文也回到就位狀態', () async {
    await seedVolumes(4);
    final targets = await targetsFor(4);
    expect(await buildOfflineIndexBatch(targets), 4);
    final maintenance = ScriptureIndexMaintenance(
      indexStore: ScriptureIndexStore(directoryProvider: () async => tempDir),
      volumeStore: scriptureVolumeStore,
    );
    expect(await maintenance.countIndexes(), 4);

    expect(await maintenance.clearAllIndexes(), 4);
    expect(await maintenance.countIndexes(), 0);

    final steps = <int>[];
    expect(
      await maintenance.rebuildIndexes(
        onProgress: (done, total) => steps.add(done),
      ),
      4,
    );
    expect(steps.last, 4);
    expect(await maintenance.countIndexes(), 4);
    expect((await runOfflineScan(requestFor('波羅蜜', targets))).builtIndexes, 0);
  });

  test('背景 worker 池真的跑通：建索引、掃描與展開', () async {
    offlineScanIsolateOverride = true;
    addTearDown(() => offlineScanIsolateOverride = null);
    addTearDown(releaseSharedOfflineScanPool);
    await seedVolumes(24);
    final targets = await targetsFor(24);

    final queue = OfflineIndexQueue();
    for (final target in targets) {
      await queue.add(target.work, target.juan, target.path);
    }
    await queue.flush();
    // worker 真的落盤了：再建一次應該一卷也不需要動。
    expect(await buildOfflineIndexBatch(targets), 0);

    final session = OfflineScanSession('般若波羅蜜');
    addTearDown(session.dispose);
    await session.prepare();
    session.start();
    await _waitFor(() => session.finished);
    expect(session.current.results, hasLength(24));
    expect(session.current.termHits, 24);

    final work = session.current.results.first.workId;
    final passages = await expandOfflineWork(
      work: work,
      hits: session.pendingHitsFor(work),
      query: '般若波羅蜜',
      availableJuans: session.juansFor(work),
    );
    expect(passages, isNotEmpty);
    expect(passages.first.text, contains('般若波羅蜜多心經'));
  });
}
