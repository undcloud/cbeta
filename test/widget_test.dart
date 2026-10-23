// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderEditable;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xuefo/main.dart';
import 'package:xuefo/search/candidates.dart';
import 'package:xuefo/search/search_input.dart';

class _MemoryScriptureVolumeStore extends ScriptureVolumeStore {
  final Map<String, CachedScriptureVolume> volumes = {};

  @override
  Future<CachedScriptureVolume?> read(String work, String juan) async =>
      volumes['$work:$juan'];

  @override
  Future<void> write(CachedScriptureVolume volume) async {
    volumes[volume.key] = volume;
  }

  @override
  Future<List<CachedScriptureVolume>> list() async => volumes.values.toList();

  @override
  Future<void> clearAll() async => volumes.clear();
}

void main() {
  setUp(() {
    scriptureVolumeStore = _MemoryScriptureVolumeStore();
    resetWorkPickerResponseCache();
  });

  tearDown(() {
    scriptureVolumeStore = ScriptureVolumeStore();
  });

  test('compares release version numbers', () {
    expect(isNewerVersion('1.0.1', '1.0.0'), isTrue);
    expect(isNewerVersion('1.1.0', '1.0.9'), isTrue);
    expect(isNewerVersion('1.0.0', '1.0.0'), isFalse);
    expect(isNewerVersion('v1.0.0', '1.0'), isFalse);
    expect(isNewerVersion('1.0.0', '1.0.1'), isFalse);
    expect(isNewerVersion('2.0', '1.9.9'), isTrue);
  });

  test('scripture HTML preserves CBETA lines and decodes visible text', () {
    final lines = parseScriptureHtml(
      '<div id="body">'
      '<span class="lb" id="T01n0001_p0001a01">T01n0001_p0001a01</span>'
      '<span class="t">如<b>是</b><span class="pc">，</span></span>'
      '<span class="lb" id="T01n0001_p0001a02">T01n0001_p0001a02</span>'
      '<span class="t">佛</span>'
      '</div>',
    );

    expect(lines.map((line) => (line.linehead, line.text)).toList(), [
      ('T01n0001_p0001a01', '如是，'),
      ('T01n0001_p0001a02', '佛'),
    ]);
    expect(lines.map((line) => line.text).join(), '如是，佛');

    final paragraphs = parseScriptureHtml(
      '<div id="body"><span class="lb" id="T01n0001_p0001a01"></span>'
      '<p>甲</p><p>乙</p></div>',
    );
    expect(paragraphs.single.text, '甲\n乙\n');
  });

  test('scripture HTML retains CBETA heading levels for display styling', () {
    final lines = parseScriptureHtml(
      '<div id="body">'
      '<span class="lb" id="B22n0117_p0005a01"></span>'
      '<p class="head" data-head-level="1">重刻三藏法數序</p>'
      '<span class="lb" id="B22n0117_p0005a02"></span>'
      '<p class="head" data-head-level="2">三藏法數通檢序</p>'
      '<span class="lb" id="B22n0117_p0005a03"></span>'
      '<p>本文內容</p></div>',
    );

    expect(lines.map((line) => (line.text, line.headingLevel)).toList(), [
      ('重刻三藏法數序\n', 1),
      ('三藏法數通檢序\n', 2),
      ('本文內容\n', 0),
    ]);
  });

  test('scripture HTML identifies volume titles and translator bylines', () {
    final lines = parseScriptureHtml(
      '<div id="body">'
      '<p class="juan">中阿含經卷第五</p>'
      '<p class="byline">東晉罽賓三藏瞿曇僧伽提婆譯</p>'
      '<p>正文<small class="inline-note">夾注</small></p>'
      '</div>',
    );

    expect(lines.map((line) => (line.text, line.role)).toList(), [
      ('中阿含經卷第五\n', ScriptureLineRole.volumeTitle),
      ('東晉罽賓三藏瞿曇僧伽提婆譯\n', ScriptureLineRole.byline),
      ('正文（夾注）\n', ScriptureLineRole.regular),
    ]);
    expect(lines.last.inlineNotes.single.length, '（夾注）'.length);
  });

  test('scripture HTML keeps duplicate volume titles searchable', () {
    final lines = parseScriptureHtml(
      '<div id="body">'
      '<span class="lb" id="T01n0003_p0154b05"></span>'
      '<p class="juan">毘婆尸佛經卷上</p>'
      '<span class="lb" id="T01n0003_p0156c08"></span>'
      '<p class="juan"><a class="noteAnchor star" href="#n0156001"></a>'
      '毘婆尸佛經卷上</p>'
      '</div>',
    );

    expect(lines, hasLength(2));
    expect(lines.first.role, ScriptureLineRole.volumeTitle);
    expect(lines.first.text, '毘婆尸佛經卷上\n');
    expect(lines.last.role, ScriptureLineRole.navigationAnchor);
    expect(lines.last.linehead, 'T01n0003_p0156c08');
    expect(lines.last.text, '毘婆尸佛經卷上\n');
    expect(
      visibleScriptureLine(
        lines.last,
        showLineBeginnings: true,
        showCollation: true,
      ),
      '[1]毘婆尸佛經卷上\n',
    );
  });

  test(
    'scripture HTML keeps linked collation notes and paired verse cells',
    () {
      final lines = parseScriptureHtml(
        '<html><body><div id="body">'
        '<span class="lb" id="T01n0001_p0001a01"></span>'
        '<p>甲<a class="noteAnchor" href="#n0001002"></a>乙</p>'
        '<span class="lb" id="T01n0001_p0001a02"></span>'
        '<div class="lg-row"><div class="lg-cell">'
        '<a class="noteAnchor add" href="#cb_note_1"></a>毘婆尸太子，</div>'
        '<div class="lg-cell">遊觀於園林，</div></div>'
        '</div><div id="back" style="display:none">'
        '<div class="footnote" id="n0001002">宋【明】</div>'
        '<span class="footnote add" id="cb_note_1">忽【CB】，怱【大】</span>'
        '</div></body></html>',
      );

      expect(lines.first.footnotes.single.label, '2');
      expect(lines.first.footnotes.single.content, '宋【明】');
      expect(lines[1].verseCells, ['毘婆尸太子，', '遊觀於園林，']);
      expect(lines[1].footnotes.single.label, 'A1');
      expect(lines[1].footnotes.single.content, '忽【CB】，怱【大】');
      expect(
        visibleScriptureLine(
          lines[1],
          showLineBeginnings: true,
          showCollation: true,
        ),
        '[0001a02] [A1]毘婆尸太子，遊觀於園林，\n',
      );
      expect(lines.any((line) => line.text.contains('宋【明】')), isFalse);
    },
  );

  test('scripture HTML retains figures and CBETA bip-table cells', () {
    final lines = parseScriptureHtml(
      '<div id="body">'
      '<span class="lb" id="B36n0198_pg010a02"></span>'
      '<div class="bip-table">'
      '<div class="bip-table-row">'
      '<div class="bip-table-cell"><span class="t">章節</span></div>'
      '<div class="bip-table-cell"><span class="t">頁碼</span></div>'
      '</div>'
      '<span class="lb" id="B36n0198_pg010a03"></span>'
      '<div class="bip-table-row">'
      '<div class="bip-table-cell"><span class="t">博伽梵歌</span></div>'
      '<div class="bip-table-cell"><span class="t">1</span></div>'
      '</div></div>'
      '<span class="lb" id="B36n0198_pg010a04"></span>'
      '<div class="div-figure"><img '
      'src="https://example.org/figure.gif" alt="插圖" /></div>'
      '</div>',
    );

    expect(lines, hasLength(3));
    expect(lines[0].linehead, 'B36n0198_pg010a02');
    expect(lines[0].tableRows.single.map((cell) => cell.text), ['章節', '頁碼']);
    expect(lines[0].text, '章節\t頁碼');
    expect(lines[1].linehead, 'B36n0198_pg010a03');
    expect(lines[1].tableRows.single.map((cell) => cell.text), ['博伽梵歌', '1']);
    expect(lines[2].linehead, 'B36n0198_pg010a04');
    expect(lines[2].images.single.source, 'https://example.org/figure.gif');
    expect(lines[2].images.single.alt, '插圖');

    final standardTable = parseScriptureHtml(
      '<div id="body"><span class="lb" id="T01n0001_pg001a01"></span>'
      '<table><tbody><tr><td>甲</td><td>乙</td></tr></tbody></table></div>',
    );
    expect(standardTable.single.tableRows.single.map((cell) => cell.text), [
      '甲',
      '乙',
    ]);
  });

  test(
    'cached scripture volumes update when the API content version changes',
    () async {
      await scriptureVolumeStore.write(
        const CachedScriptureVolume(
          work: 'T0001',
          juan: '1',
          html: '<div id="body">舊版</div>',
          contentVersion: 'version-1',
        ),
      );
      final client = MockClient((request) async {
        expect(request.url.path, '/stable/juans');
        expect(request.url.queryParameters, {'work': 'T0001', 'juan': '1'});
        return http.Response(
          jsonEncode({
            'content': 'version-2',
            'results': ['<div id="body">新版</div>'],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final result = await http.runWithClient(
        checkAndUpdateCachedScriptures,
        () => client,
      );

      expect(result.updated, 1);
      expect(result.unchanged, 0);
      expect(result.errors, isEmpty);
      final stored = await scriptureVolumeStore.read('T0001', '1');
      expect(stored?.contentVersion, 'version-2');
      expect(stored?.html, '<div id="body">新版</div>');
      expect(scriptureCacheUpdates.value, contains('T0001:1'));
    },
  );

  test('scripture volume files persist across store instances', () async {
    final directory = await Directory.systemTemp.createTemp(
      'cbeta-scripture-store-test-',
    );
    try {
      final store = ScriptureVolumeStore(
        directoryProvider: () async => directory,
      );
      const volume = CachedScriptureVolume(
        work: 'T0001',
        juan: '1',
        html: '<div id="body">離線資料</div>',
        contentVersion: 'version-1',
      );

      await store.write(volume);
      final restored = await store.read('T0001', '1');

      expect(restored?.html, volume.html);
      expect(restored?.contentVersion, volume.contentVersion);
      final listed = await store.list();
      expect(listed, hasLength(1));
      expect(listed.single.work, volume.work);
      expect(listed.single.juan, volume.juan);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  testWidgets('reader displays CBETA table cells and figures', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await scriptureDisplaySettings.load();
    const scriptureHtml =
        '<html><body><div id="body">'
        '<span class="lb" id="B36n0198_pg010a02"></span>'
        '<div class="bip-table">'
        '<div class="bip-table-row">'
        '<div class="bip-table-cell"><span class="t">章節</span></div>'
        '<div class="bip-table-cell"><span class="t">頁碼</span></div>'
        '</div></div>'
        '<span class="lb" id="B36n0198_pg010a03"></span>'
        '<div class="div-figure"><img src="https://example.org/figure.gif" '
        'alt="插圖" /></div>'
        '</div></body></html>';
    final client = MockClient((request) async {
      if (request.url.path == '/stable/juans') {
        return http.Response(
          jsonEncode({
            'results': [scriptureHtml],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 404);
    });

    await http.runWithClient(() async {
      await tester.pumpWidget(
        const MaterialApp(
          home: ScriptureReaderPage(
            passage: ScripturePassage(
              title: '博伽梵歌',
              reference: '卷 1',
              text: '',
              linehead: 'B36n0198_pg010a02',
              juan: '1',
              work: 'B0198',
            ),
            query: '',
            searchHits: [],
            initialHitIndex: 0,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('章節', findRichText: true), findsOneWidget);
      expect(find.text('頁碼', findRichText: true), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) => widget is Image && widget.semanticLabel == '插圖',
        ),
        findsOneWidget,
      );
      final cached = await scriptureVolumeStore.read('B0198', '1');
      expect(cached?.html, scriptureHtml);
    }, () => client);
  });

  testWidgets('reader uses an offline scripture volume without requesting it', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await scriptureDisplaySettings.load();
    await scriptureVolumeStore.write(
      const CachedScriptureVolume(
        work: 'T0001',
        juan: '1',
        contentVersion: 'stored-version',
        html:
            '<div id="body"><span class="lb" '
            'id="T01n0001_p0001a01"></span><p>離線經文內容</p></div>',
      ),
    );
    var networkRequests = 0;
    final client = MockClient((request) async {
      networkRequests++;
      return http.Response('{}', 404);
    });

    await http.runWithClient(() async {
      await tester.pumpWidget(
        const MaterialApp(
          home: ScriptureReaderPage(
            passage: ScripturePassage(
              title: '測試經',
              reference: '卷 1',
              text: '',
              linehead: 'T01n0001_p0001a01',
              juan: '1',
              work: 'T0001',
            ),
            query: '',
            searchHits: [],
            initialHitIndex: 0,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final renderedText = tester
          .widget<SelectableText>(find.byType(SelectableText).first)
          .textSpan!
          .toPlainText();
      expect(renderedText, contains('離線經文內容'));
      expect(networkRequests, 0);
    }, () => client);
  });

  testWidgets('reader keeps a repeated-title Goto linehead navigable', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await scriptureDisplaySettings.load();
    const scriptureHtml =
        '<html><body><div id="body">'
        '<span class="lb" id="T02n0102_p0499c05"></span>'
        '<p class="juan">佛說五蘊皆空經</p>'
        '<span class="lb" id="T02n0102_p0499c08"></span>'
        '<p>如是我聞。</p>'
        '<span class="lb" id="T02n0102_p0499c28"></span>'
        '<p class="juan"><a class="noteAnchor star" '
        'href="#n0499010"></a>佛說五蘊皆空經</p>'
        '</div><div id="back"><div class="footnote" '
        'id="n0499010">佛說異文</div></div></body></html>';
    final client = MockClient((request) async {
      if (request.url.path == '/stable/juans') {
        return http.Response(
          jsonEncode({
            'results': [scriptureHtml],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 404);
    });

    await http.runWithClient(() async {
      await tester.pumpWidget(
        const MaterialApp(
          home: ScriptureReaderPage(
            passage: ScripturePassage(
              title: '佛說五蘊皆空經',
              reference: '卷 1',
              text: '',
              linehead: 'T02n0102_p0499c28',
              juan: '1',
              work: 'T0102',
            ),
            query: '',
            searchHits: [],
            initialHitIndex: 0,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('完整經卷中找不到搜尋命中行：T02n0102_p0499c28', findRichText: true),
        findsNothing,
      );
      final renderedText = tester
          .widget<SelectableText>(find.byType(SelectableText).first)
          .textSpan!
          .toPlainText();
      expect(renderedText, contains('如是我聞。'));
      final parsed = await scriptureVolumeStore.read('T0102', '1');
      expect(parsed?.html, scriptureHtml);
    }, () => client);
  });

  testWidgets('reader distinguishes opening and closing title hits', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await scriptureDisplaySettings.load();
    await scriptureDisplaySettings.update(
      showCollation: true,
      showLineBeginnings: false,
      backgroundTheme: 'default',
    );
    final buffer = StringBuffer(
      '<html><body><div id="body">'
      '<span class="lb" id="T02n0102_p0499c05"></span>'
      '<p class="juan">佛說五蘊皆空經</p>'
      '<span class="lb" id="T02n0102_p0499c08"></span>'
      '<p>如是我聞。</p>',
    );
    for (var i = 10; i < 50; i++) {
      buffer.write(
        '<span class="lb" id="T02n0102_p0499c${i.toString().padLeft(2, '0')}">'
        '</span><p>第 $i 行內容，觀此五取蘊等法。</p>',
      );
    }
    buffer.write(
      '<span class="lb" id="T02n0102_p0499c28"></span>'
      '<p class="juan">佛說五蘊皆空經</p>'
      '</div></body></html>',
    );
    final scriptureHtml = buffer.toString();
    final client = MockClient((request) async {
      if (request.url.path == '/stable/juans') {
        return http.Response(
          jsonEncode({
            'results': [scriptureHtml],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 404);
    });

    const closingTitleHit = ScripturePassage(
      title: '佛說五蘊皆空經',
      reference: '卷1 · 0499c28',
      text: '佛說五蘊皆空經',
      linehead: 'T02n0102_p0499c28',
      juan: '1',
      work: 'T0102',
    );
    const openingTitleHit = ScripturePassage(
      title: '佛說五蘊皆空經',
      reference: '卷1 · 0499c05',
      text: '佛說五蘊皆空經',
      linehead: 'T02n0102_p0499c05',
      juan: '1',
      work: 'T0102',
    );

    Future<({double pixels, List<String> bodyHighlights})> openHit(
      ScripturePassage passage,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ScriptureReaderPage(
            key: ValueKey<String>(passage.linehead!),
            passage: passage,
            query: '五蘊',
            searchHits: const [openingTitleHit, closingTitleHit],
            initialHitIndex: passage.linehead == openingTitleHit.linehead
                ? 0
                : 1,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final scrollable = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byType(SingleChildScrollView).first,
              matching: find.byType(Scrollable),
            )
            .first,
      );
      final highlights = <String>[];
      void collect(InlineSpan? span) {
        if (span == null || span is! TextSpan) return;
        if (span.style?.backgroundColor == const Color(0xFFDDEDE8)) {
          highlights.add(span.text ?? '');
        }
        for (final child in span.children ?? const <InlineSpan>[]) {
          collect(child);
        }
      }

      // Only collect highlights from the body portion (last child of root),
      // skipping the header prefix (title, reference, header lines).
      final rootSpan = tester
          .widget<SelectableText>(find.byType(SelectableText).first)
          .textSpan;
      collect(rootSpan?.children?.lastOrNull);
      return (pixels: scrollable.position.pixels, bodyHighlights: highlights);
    }

    await http.runWithClient(() async {
      // 開頭經題（標題列）：回到卷首，只在標題列高亮。
      final opening = await openHit(openingTitleHit);
      expect(opening.pixels, 0);
      expect(opening.bodyHighlights, isEmpty);

      // 卷末重複經題：滑到它在正文中的實際位置並在正文高亮，
      // 不會和標題列重複高亮。
      final closing = await openHit(closingTitleHit);
      expect(closing.bodyHighlights, contains('五蘊'));
      expect(closing.pixels, greaterThan(0));
    }, () => client);
    await scriptureDisplaySettings.update(
      showCollation: false,
      showLineBeginnings: false,
      backgroundTheme: 'default',
    );
  });

  testWidgets('reader distinguishes repeated hits sharing a linehead', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await scriptureDisplaySettings.load();
    const scriptureHtml =
        '<html><body><div id="body">'
        '<span class="lb" id="T01n0001_p0001a01"></span>'
        '<p>五蘊五蘊</p>'
        '</div></body></html>';
    final client = MockClient((request) async {
      if (request.url.path == '/stable/juans') {
        return http.Response(
          jsonEncode({
            'results': [scriptureHtml],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 404);
    });

    const hit = ScripturePassage(
      title: '測試經',
      reference: '卷1 · 0001a01',
      text: '五蘊五蘊',
      linehead: 'T01n0001_p0001a01',
      juan: '1',
      work: 'T0001',
    );

    Future<int> openAndCountHighlights(int hitIndex) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ScriptureReaderPage(
            key: ValueKey<int>(hitIndex),
            passage: hit,
            query: '五蘊',
            searchHits: const [hit, hit],
            initialHitIndex: hitIndex,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final selectable = tester.widget<SelectableText>(
        find.byType(SelectableText).first,
      );
      var count = 0;
      void collect(InlineSpan span) {
        if (span is! TextSpan) return;
        if (span.style?.backgroundColor == const Color(0xFFDDEDE8)) count += 1;
        for (final child in span.children ?? const <InlineSpan>[]) {
          collect(child);
        }
      }

      collect(selectable.textSpan!);
      return count;
    }

    await http.runWithClient(() async {
      expect(await openAndCountHighlights(0), 2);
      expect(await openAndCountHighlights(1), 1);
    }, () => client);
  });

  testWidgets('reader keeps the title visible when the hit is the title', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await scriptureDisplaySettings.load();
    await scriptureDisplaySettings.update(
      showCollation: true,
      showLineBeginnings: false,
      backgroundTheme: 'default',
    );
    final buffer = StringBuffer('<div id="body">');
    buffer.write(
      '<span class="lb" id="T02n0102_p0499c05"></span>'
      '<p class="juan">佛說五蘊皆空經</p>',
    );
    buffer.write(
      '<span class="lb" id="T02n0102_p0499c07"></span>'
      '<p class="byline">大唐三藏法師義淨奉制譯</p>',
    );
    for (var i = 8; i < 60; i++) {
      final linehead = 'T02n0102_p0499c${i.toString().padLeft(2, '0')}';
      buffer.write(
        '<span class="lb" id="$linehead"></span>'
        '<p>第 $i 行內容，五取蘊等法。</p>',
      );
    }
    buffer.write(
      '<span class="lb" id="T02n0102_p0499c28"></span>'
      '<p class="juan">佛說五蘊皆空經</p>',
    );
    buffer.write('</div>');
    final html = buffer.toString();

    final client = MockClient((request) async {
      if (request.url.path == '/stable/juans') {
        return http.Response(
          jsonEncode({
            'results': [html],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 404);
    });

    const titleHit = ScripturePassage(
      title: '佛說五蘊皆空經',
      reference: '卷1 · 0499c05',
      text: '佛說五蘊皆空經',
      linehead: 'T02n0102_p0499c05',
      juan: '1',
      work: 'T0102',
    );

    await http.runWithClient(() async {
      await tester.pumpWidget(
        const MaterialApp(
          home: ScriptureReaderPage(
            passage: titleHit,
            query: '五蘊',
            searchHits: [titleHit],
            initialHitIndex: 0,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final scrollable = tester.state<ScrollableState>(
        find.byType(Scrollable).last,
      );
      expect(scrollable.position.pixels, 0);
    }, () => client);
    await scriptureDisplaySettings.update(
      showCollation: false,
      showLineBeginnings: false,
      backgroundTheme: 'default',
    );
  });

  testWidgets('reader styles volume titles, bylines, and inline notes', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await scriptureDisplaySettings.load();
    const scriptureHtml =
        '<html><body><div id="body">'
        '<p class="juan">中阿含經卷第五</p>'
        '<p class="byline">東晉罽賓三藏瞿曇僧伽提婆譯</p>'
        '<span class="lb" id="T01n0026_p0448c11"></span>'
        '<p>正文<small class="inline-note">夾注</small></p>'
        '</div></body></html>';
    final client = MockClient((request) async {
      if (request.url.path == '/stable/juans') {
        return http.Response(
          jsonEncode({
            'results': [scriptureHtml],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 404);
    });

    await http.runWithClient(() async {
      await tester.pumpWidget(
        const MaterialApp(
          home: ScriptureReaderPage(
            passage: ScripturePassage(
              title: '中阿含經',
              reference: '卷 5',
              text: '',
              linehead: 'T01n0026_p0448c11',
              juan: '5',
              work: 'T0026',
            ),
            query: '',
            searchHits: [],
            initialHitIndex: 0,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final selectable = tester.widget<SelectableText>(
        find.byType(SelectableText).first,
      );
      bool containsStyledSpan(
        InlineSpan span, {
        required String text,
        required Color color,
      }) {
        if (span is! TextSpan) return false;
        if (span.style?.color == color && span.toPlainText().contains(text)) {
          return true;
        }
        return span.children?.any(
              (child) => containsStyledSpan(child, text: text, color: color),
            ) ??
            false;
      }

      expect(
        containsStyledSpan(
          selectable.textSpan!,
          text: '中阿含經卷第五',
          color: const Color(0xFF007564),
        ),
        isTrue,
      );
      expect(
        containsStyledSpan(
          selectable.textSpan!,
          text: '東晉罽賓三藏瞿曇僧伽提婆譯',
          color: const Color(0xFF8C7B66),
        ),
        isTrue,
      );

      bool containsMutedInlineNote(InlineSpan span) {
        if (span is! TextSpan) return false;
        return span.style?.color == const Color(0xFF9C8B78) ||
            (span.children?.any(containsMutedInlineNote) ?? false);
      }

      expect(containsMutedInlineNote(selectable.textSpan!), isTrue);
    }, () => client);
  });

  testWidgets('reader keeps collation markers on byline lines', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await scriptureDisplaySettings.load();
    await scriptureDisplaySettings.update(
      showCollation: true,
      showLineBeginnings: false,
      backgroundTheme: 'default',
    );
    const scriptureHtml =
        '<html><body><div id="body">'
        '<p class="juan">毘婆尸佛經卷上</p>'
        '<p class="byline">西天譯經三藏'
        '<a class="noteAnchor" href="#n0002001"></a>臣法天奉詔譯</p>'
        '<span class="lb" id="T01n0003_p0154b09"></span>'
        '<p>爾時，佛告諸苾芻。</p>'
        '</div><div id="back" style="display:none">'
        '<div class="footnote" id="n0002001">宋【明】</div>'
        '</div></body></html>';
    final client = MockClient((request) async {
      if (request.url.path == '/stable/juans') {
        return http.Response(
          jsonEncode({
            'results': [scriptureHtml],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 404);
    });

    await http.runWithClient(() async {
      await tester.pumpWidget(
        const MaterialApp(
          home: ScriptureReaderPage(
            passage: ScripturePassage(
              title: '毘婆尸佛經',
              reference: '卷 1',
              text: '',
              linehead: 'T01n0003_p0154b09',
              juan: '1',
              work: 'T0003',
            ),
            query: '',
            searchHits: [],
            initialHitIndex: 0,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final selectable = tester.widget<SelectableText>(
        find.byType(SelectableText).first,
      );
      expect(selectable.textSpan!.toPlainText(), contains('西天譯經三藏[1]'));
      expect(selectable.textSpan!.toPlainText(), contains('臣法天奉詔譯'));
    }, () => client);
    await scriptureDisplaySettings.update(
      showCollation: false,
      showLineBeginnings: false,
      backgroundTheme: 'default',
    );
  });

  testWidgets('verse blocks keep one break before and a blank line after', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await scriptureDisplaySettings.load();
    await scriptureDisplaySettings.update(
      showCollation: false,
      showLineBeginnings: false,
      backgroundTheme: 'default',
    );
    const scriptureHtml =
        '<div id="body">'
        '<span class="lb" id="T01n0003_p0154b22"></span>'
        '<p>爾時，世尊而說頌曰：</p>'
        '<span class="lb" id="T01n0003_p0154b23"></span>'
        '<div class="lg-row"><div class="lg-cell">自他俱入甘露城，</div>'
        '<div class="lg-cell">同證一如真法界。</div></div>'
        '<span class="lb" id="T01n0003_p0154b26"></span>'
        '<p>爾時，世尊說此偈已。</p>'
        '</div>';
    final client = MockClient((request) async {
      if (request.url.path == '/stable/juans') {
        return http.Response(
          jsonEncode({
            'results': [scriptureHtml],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 404);
    });

    await http.runWithClient(() async {
      await tester.pumpWidget(
        const MaterialApp(
          home: ScriptureReaderPage(
            passage: ScripturePassage(
              title: '毘婆尸佛經',
              reference: '卷 1',
              text: '',
              linehead: 'T01n0003_p0154b22',
              juan: '1',
              work: 'T0003',
            ),
            query: '',
            searchHits: [],
            initialHitIndex: 0,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final plain = tester
          .widget<SelectableText>(find.byType(SelectableText).first)
          .textSpan!
          .toPlainText();
      // 前一段已自帶換行，不再補第二個換行。
      expect(plain, contains('頌曰：\n'));
      expect(plain, isNot(contains('頌曰：\n\n')));
      // 偈頌段後保留一個空行，與後段分開。
      expect(plain, contains('真法界。\n\n'));
    }, () => client);
  });

  test(
    'scripture display settings persist and render collation and line heads',
    () async {
      SharedPreferences.setMockInitialValues({});
      await scriptureDisplaySettings.load();
      expect(scriptureDisplaySettings.fontSize, 19);
      expect(scriptureDisplaySettings.lineHeight, 1.9);
      expect(scriptureDisplaySettings.backgroundColor, const Color(0xFFF5EFE0));

      final lines = parseScriptureHtml(
        '<div id="body">'
        '<span class="lb" id="T01n0001_p0001a01">'
        'T01n0001_p0001a01</span><span class="t">甲'
        '<a class="noteAnchor" href="#n0001002"></a>乙</span>'
        '<span class="lb" id="T01n0001_p0001a02">'
        'T01n0001_p0001a02</span><span class="t">丙</span>'
        '</div>',
      );

      expect(
        visibleScriptureLine(
          lines.first,
          showLineBeginnings: false,
          showCollation: true,
        ),
        '甲[2]乙',
      );
      expect(
        visibleScriptureLine(
          lines.first,
          showLineBeginnings: true,
          showCollation: false,
        ),
        '[0001a01] 甲乙',
      );

      await scriptureDisplaySettings.update(
        fontSize: 24,
        lineHeight: 2.2,
        fontFamily: 'kai',
        backgroundTheme: 'night',
        showCollation: false,
        showLineBeginnings: true,
      );
      await scriptureDisplaySettings.load();

      expect(scriptureDisplaySettings.fontSize, 24);
      expect(scriptureDisplaySettings.lineHeight, 2.2);
      expect(scriptureDisplaySettings.fontFamily, 'kai');
      expect(scriptureDisplaySettings.backgroundTheme, 'night');
      expect(scriptureDisplaySettings.showCollation, isFalse);
      expect(scriptureDisplaySettings.showLineBeginnings, isTrue);
      await scriptureDisplaySettings.update(
        fontSize: 19,
        lineHeight: 1.9,
        fontFamily: 'serif',
        backgroundTheme: 'default',
        showCollation: true,
        showLineBeginnings: false,
      );
    },
  );

  test('selected passage formats chapter title and CBETA line range', () {
    const passage = ScripturePassage(
      title: '大智度論',
      reference: '',
      text: '「如實觀法身故。',
      linehead: 'T25n1509_p0416c18',
      juan: '50',
    );

    expect(
      formatSelectedPassageForCopy(
        passage,
        '「如實觀法身故。\n「是為菩薩住八地中具足四法。」\n'
        '「云何菩薩知上下諸根？」',
        startLinehead: 'T25n1509_p0416c18',
        endLinehead: 'T25n1509_p0416c20',
        sectionTitle: '20 發趣品',
      ),
      '《大智度論》卷50〈20 發趣品〉：「\n'
      '「如實觀法身故。\n「是為菩薩住八地中具足四法。」\n'
      '「云何菩薩知上下諸根？」」'
      '(CBETA 2026.R1, T25, no. 1509, p. 416c18-20)',
    );
  });

  test('citation falls back to the first body linehead', () {
    const passage = ScripturePassage(
      title: '毘婆尸佛經',
      reference: '',
      text: '爾時，佛告諸苾芻。',
      juan: '1',
      lines: [ScriptureLine(text: '爾時，佛告諸苾芻。', linehead: 'T01n0003_p0154b09')],
    );

    expect(
      formatSelectedPassageForCopy(passage, '宋 法天譯'),
      '《毘婆尸佛經》卷1：「\n宋 法天譯」'
      '(CBETA 2026.R1, T01, no. 0003, p. 154b9)',
    );
  });

  test('Goto extracts CBETA citations from surrounding copied text', () {
    expect(
      extractCbetaGotoQuery(
        '《三藏法數》卷1〈序〉：「三藏法數通檢序」'
        '(CBETA 2026.R2, B22, no. 117, p. 5a1)',
      ),
      'CBETA 2026.R2, B22, no. 117, p. 5a1',
    );
    expect(
      normalizeCbetaGotoLinehead(
        extractCbetaGotoQuery(
          '《三藏法數》卷1〈序〉：「三藏法數通檢序」'
          '(CBETA 2026.R2, B22, no. 117, p. 5a1)',
        ),
      ),
      'B22n0117_p0005a01',
    );
    expect(
      normalizeCbetaGotoLinehead('CBETA 2026.R2, T01, no. 3, pp. 154c20'),
      'T01n0003_p0154c20',
    );
    expect(
      normalizeCbetaGotoLinehead('CBETA 2026.R2, B36, no. 198, p. h17a2'),
      'B36n0198_ph017a02',
    );
    expect(isCbetaGotoExpression('T02n0102_p0499c28'), isTrue);
    expect(
      isCbetaGotoExpression('CBETA 2026.R2, B36, no. 198, p. h17a2'),
      isTrue,
    );
    expect(isCbetaGotoExpression('博伽梵歌'), isFalse);
    expect(
      extractCbetaGotoQuery('（CBETA 2026.R2, B22, no. 117, p. 5a1）'),
      'CBETA 2026.R2, B22, no. 117, p. 5a1',
    );
    expect(extractCbetaGotoQuery('T01n0003_p0155a10'), 'T01n0003_p0155a10');
  });

  testWidgets('Goto opens target juan omitted from TOC navigation', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await scriptureDisplaySettings.load();
    final requestedGotoLineheads = <String>[];
    final requestedJuans = <String>[];
    final client = MockClient((request) async {
      final path = request.url.path;
      final parameters = request.url.queryParameters;
      if (path == '/stable/catalog_entry') {
        return http.Response(
          jsonEncode({'label': '部類目錄', 'results': []}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (path == '/stable/juans/goto') {
        requestedGotoLineheads.add(parameters['linehead']!);
        return http.Response(
          jsonEncode({
            'num_found': 1,
            'results': [
              {
                'vol': 'B36',
                'lb': 'h017a02',
                'work': 'B0198',
                'file': 'B36n0198',
                'juan': 1,
                'linehead': 'B36n0198_ph017a02',
                'title': '博伽梵歌',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (path == '/stable/works/toc') {
        return http.Response(
          jsonEncode({
            'results': [
              {
                'mulu': [],
                'juan': [
                  {
                    'file': 'B36n0198',
                    'juan': 2,
                    'lb': 'i034a01',
                    'title': '第二',
                  },
                  {
                    'file': 'B36n0198',
                    'juan': 3,
                    'lb': 'i107a01',
                    'title': '第三',
                  },
                ],
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (path == '/stable/juans') {
        requestedJuans.add(parameters['juan']!);
        return http.Response(
          jsonEncode({
            'results': [
              '<div id="body"><span class="lb" '
                  'id="B36n0198_ph017a02"></span>'
                  '<span class="t">博伽梵歌目標段落</span></div>',
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 404);
    });

    await http.runWithClient(() async {
      await tester.pumpWidget(const CbetaSearchApp());
      await tester.tap(find.byTooltip('選擇佛經'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Goto 查詢'));
      await tester.tap(find.text('Goto 查詢'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).last,
        'CBETA 2026.R2, B36, no. 198, p. h17a2',
      );
      await tester.tap(find.text('到該行'));
      await tester.pumpAndSettle();

      expect(requestedGotoLineheads, ['B36n0198_ph017a02']);
      expect(requestedJuans, ['1']);
      final readerText = tester
          .widget<SelectableText>(find.byType(SelectableText).first)
          .textSpan!
          .toPlainText();
      expect(readerText, contains('博伽梵歌目標段落'));
      expect(find.text('第 1 / 3 卷'), findsOneWidget);
    }, () => client);
  });

  testWidgets('homepage toggles persisted simplified text display', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'reader_bookmarks': jsonEncode([
        {
          'work': 'T0001',
          'title': '三藏法數',
          'juan': '1',
          'linehead': 'T01n0001_p0001a01',
          'availableJuans': [1],
        },
      ]),
    });
    await scriptureDisplaySettings.load();
    await SimplifiedTraditionalConverter.load();
    expect(SimplifiedTraditionalConverter.convert('五蕴'), '五蘊');
    expect(SimplifiedTraditionalConverter.convert('简体搜索发'), '簡體搜索發');
    expect(SimplifiedTraditionalConverter.convert('国'), '國');
    expect(SimplifiedTraditionalConverter.convert('钻'), '鑽');
    expect(SimplifiedTraditionalConverter.convert('ABC 123!'), 'ABC 123!');
    final ambiguous = SimplifiedTraditionalConverter.convertCandidates('厂丑');
    expect(ambiguous.scriptKind, ScriptKind.simplified);
    expect(ambiguous.candidates, ['廠丑', '廠醜', '厂丑', '厂醜']);
    expect(ambiguous.requiresChoice, isTrue);
    expect(SimplifiedTraditionalConverter.toSimplified('五蘊經典'), '五蕴经典');
    expect(SimplifiedTraditionalConverter.toSimplified('雲何'), '云何');
    expect(SimplifiedTraditionalConverter.toSimplified('𠀀'), '𠀀');
    // 繁體經文中的共用字不應被過度轉換。
    expect(SimplifiedTraditionalConverter.toTraditionalDisplay('云何'), '云何');
    expect(SimplifiedTraditionalConverter.toTraditionalDisplay('山谷'), '山谷');
    expect(SimplifiedTraditionalConverter.toTraditionalDisplay('皇后'), '皇后');
    expect(SimplifiedTraditionalConverter.toTraditionalDisplay('公里'), '公里');
    expect(SimplifiedTraditionalConverter.toTraditionalDisplay('干戈'), '干戈');
    expect(SimplifiedTraditionalConverter.toTraditionalDisplay('占卜'), '占卜');
    expect(SimplifiedTraditionalConverter.toTraditionalDisplay('于闐'), '于闐');
    expect(SimplifiedTraditionalConverter.toTraditionalDisplay('尸羅'), '尸羅');
    expect(SimplifiedTraditionalConverter.toTraditionalDisplay('咸皆'), '咸皆');
    expect(SimplifiedTraditionalConverter.toTraditionalDisplay('天台宗'), '天台宗');
    expect(
      SimplifiedTraditionalConverter.toTraditionalDisplay('我们部类册别作译者经目查询'),
      '我們部類冊別作譯者經目查詢',
    );
    expect(SimplifiedTraditionalConverter.toSimplified('我的書籤'), '我的书签');

    await tester.pumpWidget(const CbetaSearchApp());
    await tester.pumpAndSettle();

    expect(scriptureDisplaySettings.showSimplifiedText, isFalse);
    expect(find.text('简'), findsOneWidget);
    expect(find.text('CBETA 閱讀'), findsOneWidget);
    expect(find.text('我的書籤'), findsOneWidget);

    await tester.tap(
      find.byTooltip(
        scriptureDisplaySettings.showSimplifiedText ? '切换简体／繁体' : '切換簡體／繁體',
      ),
    );
    await tester.pumpAndSettle();

    expect(scriptureDisplaySettings.showSimplifiedText, isTrue);
    expect(find.text('繁'), findsOneWidget);
    expect(find.text('CBETA 阅读'), findsOneWidget);
    expect(find.text('我的书签'), findsOneWidget);
    final preferences = await SharedPreferences.getInstance();
    final savedSettings =
        jsonDecode(preferences.getString('scripture_display_settings')!)
            as Map<String, dynamic>;
    expect(savedSettings['showSimplifiedText'], isTrue);

    await scriptureDisplaySettings.update(showSimplifiedText: false);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('live search input shows history and candidate choices', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await scriptureDisplaySettings.load();
    await SimplifiedTraditionalConverter.load();
    final controller = TextEditingController();
    final displayMode = ValueNotifier<bool>(false);
    var simplifiedText = false;
    SearchSelection? selection;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SearchInput(
            controller: controller,
            recentSearches: const ['五蘊'],
            displayListenable: displayMode,
            textBuilder: (text) => simplifiedText
                ? SimplifiedTraditionalConverter.toSimplified(text)
                : text,
            onSearch: (value) => selection = value,
          ),
        ),
      ),
    );

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, '五蘊'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '厂丑');
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, '廠丑'), findsOneWidget);
    expect(find.widgetWithText(ListTile, '厂丑'), findsOneWidget);
    expect(find.text('原始輸入'), findsOneWidget);

    simplifiedText = true;
    displayMode.value = true;
    await tester.pump();
    expect(find.text('原始输入'), findsOneWidget);
    simplifiedText = false;
    displayMode.value = false;
    await tester.pump();
    expect(find.text('原始輸入'), findsOneWidget);

    await tester.tap(find.widgetWithText(ListTile, '廠醜'));
    await tester.pumpAndSettle();
    expect(selection?.rawInput, '厂丑');
    expect(selection?.query, '廠醜');
    expect(controller.text, '廠醜');

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    displayMode.dispose();
  });

  testWidgets('CBETA search page is shown', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await scriptureDisplaySettings.load();
    await tester.pumpWidget(const CbetaSearchApp());

    expect(find.text('CBETA 閱讀'), findsOneWidget);
    expect(find.text('歡迎使用 CBETA 經典閱讀'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
      const Color(0xFFF5EFE0),
    );
    expect(
      Theme.of(tester.element(find.byType(AppBar))).appBarTheme.backgroundColor,
      const Color(0xFFFAF6EC),
    );
  });

  testWidgets('about dialog shows project, data source, and contact details', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await scriptureDisplaySettings.load();
    await tester.pumpWidget(const CbetaSearchApp());
    await tester.tap(find.text('關於我們'));
    await tester.pumpAndSettle();

    expect(find.text('專案介紹'), findsOneWidget);
    expect(find.text('資料來源'), findsOneWidget);
    expect(find.text('開發資訊'), findsOneWidget);
    expect(find.text('聯絡我們'), findsOneWidget);
    expect(find.text('資料版本'), findsOneWidget);
    expect(find.textContaining('非 CBETA Online 官方開發或維護之應用程式'), findsOneWidget);
    expect(find.textContaining('https://cbdata.dila.edu.tw/'), findsOneWidget);
    expect(
      find.textContaining('https://github.com/undcloud/cbeta'),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byTooltip('切換簡體／繁體'),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byTooltip('切换简体／繁体'),
      ),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('searches are saved and can be selected again', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await scriptureDisplaySettings.load();
    var searchRequests = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/stable/search/all_in_one') {
        searchRequests++;
        return http.Response(
          jsonEncode({
            'num_found': 0,
            'total_term_hits': 0,
            'results': <Object>[],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 404);
    });

    await http.runWithClient(() async {
      await tester.pumpWidget(const CbetaSearchApp());
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, '般若波羅蜜');
      await tester.tap(find.byTooltip('搜尋經文'));
      await tester.pumpAndSettle();

      final preferences = await SharedPreferences.getInstance();
      expect(
        jsonDecode(preferences.getString('search_history')!) as List<dynamic>,
        ['般若波羅蜜'],
      );
      expect(searchRequests, 1);

      await tester.tap(find.byTooltip('清除搜尋'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(TextField).first);
      await tester.pumpAndSettle();
      expect(find.text('最近搜尋'), findsNothing);
      final suggestion = find.widgetWithText(ListTile, '般若波羅蜜');
      expect(suggestion, findsOneWidget);
      expect(tester.widget<ListTile>(suggestion).leading, isNull);

      await tester.tap(find.text('歡迎使用 CBETA 經典閱讀'));
      await tester.pumpAndSettle();
      expect(suggestion, findsNothing);

      await tester.tap(find.byType(TextField).first);
      await tester.pumpAndSettle();
      expect(suggestion, findsOneWidget);
      await tester.tap(find.widgetWithText(ListTile, '般若波羅蜜'));
      await tester.pumpAndSettle();

      expect(searchRequests, 2);
      expect(find.text('般若波羅蜜'), findsOneWidget);
    }, () => client);
  });

  testWidgets('offline search falls back to locally saved scriptures', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await scriptureDisplaySettings.load();
    await scriptureVolumeStore.write(
      const CachedScriptureVolume(
        work: 'T0001',
        juan: '1',
        html:
            '<div id="body">'
            '<p class="juan">長阿含經卷第一</p>'
            '<span class="lb" id="T01n0001_p0001a01"></span>'
            '<span class="t">般若波羅蜜多心經</span>'
            '</div>',
      ),
    );
    final client = MockClient((request) async {
      throw const SocketException('offline');
    });

    await http.runWithClient(() async {
      await tester.pumpWidget(const CbetaSearchApp());
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, '般若波羅蜜');
      await tester.tap(find.byTooltip('搜尋經文'));
      await tester.pumpAndSettle();

      expect(find.textContaining('離線模式'), findsWidgets);
      expect(find.text('般若波羅蜜多心經', findRichText: true), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }, () => client);
  });

  testWidgets('offline search shows local catalog matches separately', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await scriptureDisplaySettings.load();
    await scriptureVolumeStore.write(
      const CachedScriptureVolume(
        work: 'T0001',
        juan: '1',
        html:
            '<div id="body">'
            '<p class="juan">長阿含經卷第一</p>'
            '<span class="lb" id="T01n0001_p0001a01"></span>'
            '<span class="t">正文內容</span>'
            '</div>',
      ),
    );
    final client = MockClient((request) async {
      throw const SocketException('offline');
    });

    await http.runWithClient(() async {
      await tester.pumpWidget(const CbetaSearchApp());
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, '長阿含');
      await tester.tap(find.byTooltip('搜尋經文'));
      await tester.pumpAndSettle();

      expect(find.textContaining('離線模式'), findsWidgets);
      expect(find.text('T0001 長阿含經'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }, () => client);
  });

  testWidgets('offline Goto search opens a locally saved line', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await scriptureDisplaySettings.load();
    await scriptureVolumeStore.write(
      const CachedScriptureVolume(
        work: 'T0001',
        juan: '1',
        html:
            '<div id="body">'
            '<span class="lb" id="T01n0001_p0001a01"></span>'
            '<span class="t">離線行號經文</span>'
            '</div>',
      ),
    );
    final client = MockClient((request) async {
      throw const SocketException('offline');
    });

    await http.runWithClient(() async {
      await tester.pumpWidget(const CbetaSearchApp());
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'T01n0001_p0001a01');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<SelectableText>(find.byType(SelectableText).first)
            .textSpan!
            .toPlainText(),
        contains('離線行號經文'),
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }, () => client);
  });

  testWidgets('homepage Goto search opens a passage without keyword search', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await scriptureDisplaySettings.load();
    final requestedPaths = <String>[];
    final client = MockClient((request) async {
      final path = request.url.path;
      requestedPaths.add(path);
      if (path == '/stable/juans/goto') {
        expect(request.url.queryParameters['linehead'], 'T01n0003_p0001a01');
        return http.Response(
          jsonEncode({
            'results': [
              {
                'work': 'T0003',
                'file': 'T01n0003',
                'juan': 1,
                'linehead': 'T01n0003_p0001a01',
                'title': '毘婆尸佛經',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (path == '/stable/works/toc') {
        return http.Response(
          jsonEncode({
            'results': [
              {
                'juan': [
                  {'file': 'T01n0003', 'juan': 1, 'lb': '0001a01'},
                ],
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (path == '/stable/juans') {
        return http.Response(
          jsonEncode({
            'results': [
              '<div id="body"><span class="lb" '
                  'id="T01n0003_p0001a01"></span>'
                  '<span class="t">Goto 目標經文</span></div>',
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 404);
    });

    await http.runWithClient(() async {
      await tester.pumpWidget(const CbetaSearchApp());
      await tester.enterText(find.byType(TextField).first, 'T01n0003_p0001a01');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<SelectableText>(find.byType(SelectableText).first)
            .textSpan!
            .toPlainText(),
        contains('Goto 目標經文'),
      );
      expect(requestedPaths, contains('/stable/juans/goto'));
      expect(requestedPaths, contains('/stable/works/toc'));
      expect(requestedPaths, contains('/stable/juans'));
      expect(requestedPaths, isNot(contains('/stable/search/all_in_one')));
      expect(requestedPaths, isNot(contains('/stable/search/toc')));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }, () => client);
  });

  testWidgets(
    'homepage searches keyword and catalog concurrently and prioritizes catalog matches',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await scriptureDisplaySettings.load();
      tester.view.physicalSize = const Size(800, 1800);
      tester.view.devicePixelRatio = 1;
      final keywordResponse = Completer<http.Response>();
      final catalogResponse = Completer<http.Response>();
      final client = MockClient((request) {
        if (request.url.path == '/stable/search/all_in_one') {
          return keywordResponse.future;
        }
        if (request.url.path == '/stable/search/toc') {
          expect(request.url.queryParameters['q'], '三藏法數');
          return catalogResponse.future;
        }
        return Future.value(http.Response('{}', 404));
      });

      await http.runWithClient(() async {
        await tester.pumpWidget(const CbetaSearchApp());
        await tester.enterText(find.byType(TextField).first, '三藏法數');
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pump();

        keywordResponse.complete(
          http.Response(
            jsonEncode({
              'num_found': 6,
              'total_term_hits': 6,
              'results': [
                {
                  'work': 'T0001',
                  'file': 'T01n0001',
                  'title': '一般匹配',
                  'kwics': {
                    'results': [
                      {'kwic': '一般命中', 'lb': '0001a01'},
                    ],
                  },
                },
                {
                  'work': 'T0002',
                  'file': 'T01n0002',
                  'title': '經目命中',
                  'kwics': {
                    'results': [
                      {'kwic': '經目作品的全文命中', 'lb': '0001a01'},
                    ],
                  },
                },
                for (var index = 3; index <= 6; index++)
                  {
                    'work': 'B${index.toString().padLeft(4, '0')}',
                    'file': 'B01n${index.toString().padLeft(4, '0')}',
                    'title': '全文命中$index',
                    'kwics': {
                      'results': [
                        {'kwic': '全文命中片段$index', 'lb': '0001a01'},
                      ],
                    },
                  },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('T0001 一般匹配'), findsOneWidget);
        expect(find.text('T0002 經目命中'), findsOneWidget);

        catalogResponse.complete(
          http.Response(
            jsonEncode({
              'num_found': 11,
              'results': [
                {
                  'type': 'work',
                  'work': 'T0002',
                  'file': 'T01n0002',
                  'title': '經目命中',
                },
                for (var index = 3; index <= 12; index++)
                  {
                    'type': 'work',
                    'work': 'B${index.toString().padLeft(4, '0')}',
                    'file': 'B01n${index.toString().padLeft(4, '0')}',
                    'title': '經目作品$index',
                  },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('T0002 經目命中'), findsNWidgets(2));
        expect(find.text('B0003 經目作品3'), findsOneWidget);
        expect(find.text('B0006 經目作品6'), findsNothing);
        expect(find.text('B0007 經目作品7'), findsNothing);
        expect(find.text('B0012 經目作品12'), findsNothing);
        expect(find.text('經目匹配 · 點擊開啟'), findsNWidgets(2));
        await tester.ensureVisible(find.text('顯示更多'));
        await tester.tap(find.text('顯示更多'));
        await tester.pumpAndSettle();
        expect(find.text('B0007 經目作品7'), findsOneWidget);
        expect(find.text('B0012 經目作品12'), findsOneWidget);
        expect(find.text('收起'), findsOneWidget);
        expect(find.text('T0002 經目命中'), findsNWidgets(2));
        expect(find.text('經目匹配 · 點擊開啟'), findsNWidgets(11));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }, () => client);
    },
  );

  testWidgets('work picker converts simplified text before TOC search', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await scriptureDisplaySettings.load();
    await SimplifiedTraditionalConverter.load();
    String? tocQuery;
    final client = MockClient((request) async {
      if (request.url.path == '/stable/catalog_entry') {
        return http.Response(
          jsonEncode({'label': '部類目錄', 'results': []}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path == '/stable/search/toc') {
        tocQuery = request.url.queryParameters['q'];
        return http.Response(
          jsonEncode({'num_found': 0, 'results': []}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 404);
    });

    await http.runWithClient(() async {
      await tester.pumpWidget(const CbetaSearchApp());
      await tester.tap(find.byTooltip('選擇佛經'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('經目查詢'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '简体经目发愿');
      await tester.pumpAndSettle();

      final preferredCandidate = find.widgetWithText(ListTile, '簡體經目發願');
      expect(preferredCandidate, findsOneWidget);
      await tester.tap(preferredCandidate);
      await tester.pumpAndSettle();

      expect(tocQuery, '簡體經目發願');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }, () => client);
  });

  testWidgets('homepage ambiguous simplified input offers candidates', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await scriptureDisplaySettings.load();
    await SimplifiedTraditionalConverter.load();
    String? keywordQuery;
    final client = MockClient((request) async {
      if (request.url.path == '/stable/search/all_in_one') {
        keywordQuery = request.url.queryParameters['q'];
        return http.Response(
          jsonEncode({
            'num_found': 0,
            'total_term_hits': 0,
            'results': <Object>[],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path == '/stable/search/toc') {
        return http.Response(
          jsonEncode({'num_found': 0, 'results': <Object>[]}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 404);
    });

    await http.runWithClient(() async {
      await tester.pumpWidget(const CbetaSearchApp());
      await tester.enterText(find.byType(TextField).first, '简体经目发愿');
      await tester.pumpAndSettle();

      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.textContaining('計算中'), findsNothing);
      final preferred = find.widgetWithText(ListTile, '簡體經目發願');
      expect(preferred, findsOneWidget);
      await tester.tap(preferred);
      await tester.pumpAndSettle();

      expect(keywordQuery, '簡體經目發願');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }, () => client);
  });

  testWidgets(
    'multi-character ambiguous input offers cross-product candidates',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await scriptureDisplaySettings.load();
      await SimplifiedTraditionalConverter.load();
      String? keywordQuery;
      final client = MockClient((request) async {
        if (request.url.path == '/stable/search/all_in_one') {
          keywordQuery = request.url.queryParameters['q'];
          return http.Response(
            jsonEncode({
              'num_found': 0,
              'total_term_hits': 0,
              'results': <Object>[],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.url.path == '/stable/search/toc') {
          return http.Response(
            jsonEncode({'num_found': 0, 'results': <Object>[]}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('{}', 404);
      });

      await http.runWithClient(() async {
        await tester.pumpWidget(const CbetaSearchApp());
        await tester.enterText(find.byType(TextField).first, '厂丑');
        await tester.pumpAndSettle();

        expect(find.byType(LinearProgressIndicator), findsNothing);
        for (final candidate in ['廠丑', '廠醜', '厂丑', '厂醜']) {
          expect(find.widgetWithText(ListTile, candidate), findsOneWidget);
        }
        await tester.tap(find.widgetWithText(ListTile, '廠醜'));
        await tester.pumpAndSettle();
        expect(keywordQuery, '廠醜');
        expect(find.text('找不到「廠醜」相關經文'), findsOneWidget);
        expect(find.textContaining('廠丑'), findsNothing);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }, () => client);
    },
  );

  testWidgets('tapping the CBETA logo clears search results to the homepage', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await scriptureDisplaySettings.load();
    final client = MockClient((request) async {
      if (request.url.path == '/stable/search/all_in_one') {
        return http.Response(
          jsonEncode({
            'num_found': 0,
            'total_term_hits': 0,
            'results': <Object>[],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 404);
    });

    await http.runWithClient(() async {
      await tester.pumpWidget(const CbetaSearchApp());
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '中阿含經');
      await tester.tap(find.byTooltip('搜尋經文'));
      await tester.pumpAndSettle();
      expect(find.textContaining('找不到'), findsOneWidget);
      expect(find.text('歡迎使用 CBETA 經典閱讀'), findsNothing);

      await tester.tap(find.text('CBETA 閱讀'));
      await tester.pumpAndSettle();

      expect(find.text('歡迎使用 CBETA 經典閱讀'), findsOneWidget);
      expect(find.textContaining('找不到'), findsNothing);
      expect(find.byType(TextField).first, findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        isEmpty,
      );
    }, () => client);
  });

  testWidgets('system back clears search results before leaving the homepage', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await scriptureDisplaySettings.load();
    final client = MockClient((request) async {
      if (request.url.path == '/stable/search/all_in_one') {
        return http.Response(
          jsonEncode({
            'num_found': 0,
            'total_term_hits': 0,
            'results': <Object>[],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 404);
    });

    await http.runWithClient(() async {
      await tester.pumpWidget(const CbetaSearchApp());
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '長阿含經');
      await tester.tap(find.byTooltip('搜尋經文'));
      await tester.pumpAndSettle();
      expect(find.textContaining('找不到'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.text('歡迎使用 CBETA 經典閱讀'), findsOneWidget);
      expect(find.textContaining('找不到'), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        isEmpty,
      );
    }, () => client);
  });

  testWidgets(
    'clearing recent reading asks for confirmation and clears offline texts only after confirming',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'reading_history': jsonEncode([
          {
            'work': 'T0001',
            'title': '測試經',
            'juan': '1',
            'linehead': 'T01n0001_p0001a01',
            'availableJuans': [1],
          },
        ]),
        'reader_bookmarks': jsonEncode([
          {
            'work': 'T0002',
            'title': '保留的書籤',
            'juan': '1',
            'linehead': 'T01n0002_p0001a01',
            'availableJuans': [1],
          },
        ]),
      });
      await scriptureVolumeStore.write(
        const CachedScriptureVolume(
          work: 'T0001',
          juan: '1',
          html: '<div id="body">離線經文</div>',
        ),
      );

      await tester.pumpWidget(const CbetaSearchApp());
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '清空').first);
      await tester.pumpAndSettle();

      expect(find.text('清除最近閱讀與離線經文？'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(await scriptureVolumeStore.list(), hasLength(1));

      await tester.tap(find.widgetWithText(TextButton, '清空').first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '清除'));
      await tester.pumpAndSettle();

      final preferences = await SharedPreferences.getInstance();
      expect(preferences.containsKey('reading_history'), isFalse);
      expect(
        jsonDecode(preferences.getString('reader_bookmarks')!) as List<dynamic>,
        hasLength(1),
      );
      expect(await scriptureVolumeStore.list(), isEmpty);
      expect(find.text('最近閱讀'), findsNothing);
      expect(find.text('保留的書籤'), findsOneWidget);
      expect(find.text('已清除最近閱讀記錄及離線經文'), findsOneWidget);
    },
  );

  testWidgets('homepage shows reading history and saved bookmarks', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'reading_history': jsonEncode([
        {
          'work': 'B0117',
          'title': '三藏法數',
          'juan': '1',
          'linehead': 'B22n0117_p0005a01',
          'availableJuans': [1],
        },
      ]),
      'reader_bookmarks': jsonEncode([
        {
          'work': 'T0003',
          'title': '毘婆尸佛經',
          'juan': '1',
          'linehead': 'T01n0003_p0154c20',
          'availableJuans': [1],
        },
      ]),
    });
    await tester.pumpWidget(const CbetaSearchApp());
    await tester.pumpAndSettle();

    expect(find.text('上次閱讀位置'), findsOneWidget);
    expect(find.text('最近閱讀'), findsOneWidget);
    expect(find.text('我的書籤'), findsOneWidget);
    expect(find.text('三藏法數'), findsAtLeastNWidgets(1));
    expect(find.text('毘婆尸佛經'), findsOneWidget);
    expect(
      tester.getTopLeft(find.byType(TextField).first).dy,
      lessThan(tester.getTopLeft(find.text('上次閱讀位置')).dy),
    );
  });

  testWidgets('work picker is a dismissible side drawer', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    var catalogRequests = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/stable/catalog_entry') catalogRequests++;
      return http.Response(
        jsonEncode({'label': '部類目錄', 'results': []}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    await http.runWithClient(() async {
      await tester.pumpWidget(const CbetaSearchApp());
      await tester.tap(find.byTooltip('選擇佛經'));
      await tester.pumpAndSettle();
      expect(find.text('選擇佛經'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AppBar).last,
          matching: find.byTooltip('介面設定'),
        ),
        findsNothing,
      );
      final firstOpenRequests = catalogRequests;

      await tester.tapAt(const Offset(700, 40));
      await tester.pumpAndSettle();
      expect(find.text('選擇佛經'), findsNothing);
      expect(find.text('歡迎使用 CBETA 經典閱讀'), findsOneWidget);

      await tester.tap(find.byTooltip('選擇佛經'));
      await tester.pumpAndSettle();
      expect(catalogRequests, firstOpenRequests);
      await tester.tapAt(const Offset(700, 40));
      await tester.pumpAndSettle();
    }, () => client);
  });

  testWidgets(
    'work picker matches CBETA creator groups, identifiers, dynasty ranges, and Goto citations',
    (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      await scriptureDisplaySettings.load();
      final requestedCreatorIds = <String>[];
      final requestedDynasties = <String>[];
      final requestedGotoQueries = <String>[];
      final requestedWorkTocs = <String>[];
      final client = MockClient((request) async {
        final path = request.url.path;
        final parameters = request.url.queryParameters;
        if (path == '/stable/catalog_entry') {
          return http.Response(
            jsonEncode({'label': '部類目錄', 'results': []}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (path == '/stable/download/all-creators-with-alias.json') {
          return http.Response(
            jsonEncode({
              'A000007': {
                'regular_name': '一如',
                'aliases_all': ['明 一如'],
              },
              'A000101': {'regular_name': '佛陀'},
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (path == '/stable/download/stat/dynasty-all.csv') {
          return http.Response.bytes(
            utf8.encode('朝代,起始年,結束年,典籍數\n唐,618,907,1\n'),
            200,
            headers: {'content-type': 'text/csv; charset=utf-8'},
          );
        }
        if (path == '/stable/works') {
          if (parameters.containsKey('creator_id')) {
            requestedCreatorIds.add(parameters['creator_id']!);
          }
          if (parameters.containsKey('dynasty')) {
            requestedDynasties.add(parameters['dynasty']!);
          }
          return http.Response(
            jsonEncode({
              'num_found': 1,
              'results': [
                {
                  'work': 'B0117',
                  'file': 'B22n0117',
                  'title': '三藏法數',
                  'vol': 'B22',
                  'juan': 50,
                  'byline': '一如等編',
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (path == '/stable/search/toc') {
          return http.Response(
            jsonEncode({
              'num_found': 1,
              'results': [
                {
                  'type': 'work',
                  'work': 'B0117',
                  'file': 'B22n0117',
                  'title': '三藏法數',
                  'juan': 50,
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (path == '/stable/juans/goto') {
          requestedGotoQueries.add(parameters['linehead']!);
          return http.Response(
            jsonEncode({
              'num_found': 1,
              'results': [
                {
                  'work': 'B0117',
                  'file': 'B22n0117',
                  'juan': 1,
                  'lb': '0005a01',
                  'linehead': 'B22n0117_p0005a01',
                  'title': '三藏法數',
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (path == '/stable/works/toc') {
          requestedWorkTocs.add(parameters['work']!);
          return http.Response(
            jsonEncode({
              'results': [
                {
                  'juan': [
                    {
                      'file': 'B22n0117',
                      'juan': 50,
                      'lb': '0050a01',
                      'title': '卷五十',
                    },
                    {
                      'file': 'B22n0117',
                      'juan': 1,
                      'lb': '0005a01',
                      'title': '序',
                    },
                  ],
                  'mulu': [],
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (path == '/stable/juans') {
          return http.Response(
            jsonEncode({
              'results': [
                '<div id="body"><span class="lb" '
                    'id="B22n0117_p0005a01"></span>'
                    '<span class="t">三藏法數通檢序</span></div>',
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('{}', 404);
      });

      const passage = ScripturePassage(
        title: '測試經',
        reference: '卷 1',
        text: '',
        linehead: 'T01n0001_p0001a01',
        juan: '1',
        work: 'T0001',
      );
      await http.runWithClient(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: ScriptureReaderPage(
              passage: passage,
              query: '',
              searchHits: const [],
              initialHitIndex: 0,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('選擇佛經'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        await tester.tap(find.text('作譯者'));
        await tester.pumpAndSettle();
        expect(find.text('1 劃'), findsOneWidget);
        expect(find.text('7 劃'), findsOneWidget);
        await tester.tap(find.text('一如'));
        await tester.pumpAndSettle();
        expect(requestedCreatorIds, ['A000007']);
        expect(find.text('B0117 三藏法數'), findsOneWidget);
        await tester.tap(find.text('B0117 三藏法數'));
        await tester.pumpAndSettle();
        expect(requestedWorkTocs, ['B0117']);
        expect(
          tester
              .widget<SelectableText>(find.byType(SelectableText).first)
              .textSpan!
              .toPlainText(),
          contains('三藏法數'),
        );
        expect(
          tester
              .widget<DropdownButton<int>>(find.byType(DropdownButton<int>))
              .value,
          1,
        );
        await tester.tap(find.byType(DropdownButton<int>));
        await tester.pumpAndSettle();
        expect(find.text('第 50 卷'), findsOneWidget);
        await tester.tap(find.text('第 50 卷').last);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<DropdownButton<int>>(find.byType(DropdownButton<int>))
              .value,
          50,
        );
        await tester.tap(find.text('CBETA 閱讀'));
        await tester.pumpAndSettle();
        expect(find.text('CBETA 閱讀'), findsOneWidget);

        await tester.tap(find.byTooltip('選擇佛經'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('年代'));
        await tester.pumpAndSettle();
        expect(find.text('618–907 CE · 1 部'), findsOneWidget);
        await tester.tap(find.text('唐'));
        await tester.pumpAndSettle();
        expect(requestedDynasties, ['唐']);
        expect(find.text('B0117 三藏法數'), findsOneWidget);

        await tester.tap(find.text('經目查詢'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).last, '三藏法數');
        await tester.tap(find.text('搜尋'));
        await tester.pumpAndSettle();
        expect(find.text('B0117 三藏法數'), findsOneWidget);

        await tester.tap(find.text('Goto 查詢'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byType(TextField).last,
          '《三藏法數》卷1〈序〉：「三藏法數通檢序」'
          '(CBETA 2026.R2, B22, no. 117, p. 5a1)',
        );
        await tester.tap(find.text('到該行'));
        await tester.pumpAndSettle();
        expect(requestedGotoQueries, ['B22n0117_p0005a01']);
        expect(requestedWorkTocs, ['B0117']);
        expect(
          tester
              .widget<SelectableText>(find.byType(SelectableText).first)
              .textSpan!
              .toPlainText(),
          contains('三藏法數'),
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }, () => client);
    },
  );

  testWidgets('collation markers open their note from the loaded juan', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await scriptureDisplaySettings.load();
    await SimplifiedTraditionalConverter.load();
    await scriptureDisplaySettings.update(
      showCollation: true,
      showLineBeginnings: false,
      backgroundTheme: 'default',
      showSimplifiedText: false,
    );
    final client = MockClient((request) async {
      if (request.url.path == '/stable/juans') {
        return http.Response(
          jsonEncode({
            'results': [
              '<html><body><div id="body">'
                  '<span class="lb" id="T01n0001_p0001a01"></span>'
                  '<p>甲<a class="noteAnchor" href="#n0001002"></a>乙五蘊經典</p>'
                  '<span class="lb" id="T01n0001_p0001a02"></span>'
                  '<div class="lg-row"><div class="lg-cell">毘婆尸太子，</div>'
                  '<div class="lg-cell">遊觀於園林，</div></div>'
                  '</div><div id="back" style="display:none">'
                  '<div class="footnote" id="n0001002">宋【明】</div>'
                  '</div></body></html>',
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 404);
    });
    const passage = ScripturePassage(
      title: '測試經',
      reference: '卷 1',
      text: '甲乙',
      linehead: 'T01n0001_p0001a01',
      juan: '1',
      work: 'T0001',
    );

    await http.runWithClient(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: ScriptureReaderPage(
            passage: passage,
            query: '',
            searchHits: const [],
            initialHitIndex: 0,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip('切換簡體／繁體'), findsOneWidget);
      final scriptureText = tester.widget<SelectableText>(
        find.byType(SelectableText).first,
      );
      expect(scriptureText.textSpan!.toPlainText(), contains('甲[2]乙五蘊經典'));
      // 偈頌以文字呈現，才能逐字選取。
      expect(scriptureText.textSpan!.toPlainText(), contains('毘婆尸太子，'));
      expect(scriptureText.textSpan!.toPlainText(), contains('遊觀於園林，'));
      await tester.tap(find.byTooltip('切換簡體／繁體'));
      await tester.pumpAndSettle();
      expect(scriptureDisplaySettings.showSimplifiedText, isTrue);
      expect(
        tester
            .widget<SelectableText>(find.byType(SelectableText).first)
            .textSpan!
            .toPlainText(),
        contains('甲[2]乙五蕴经典'),
      );
      await tester.tap(
        find.byTooltip(
          scriptureDisplaySettings.showSimplifiedText ? '切换简体／繁体' : '切換簡體／繁體',
        ),
      );
      await tester.pumpAndSettle();
      expect(scriptureDisplaySettings.showSimplifiedText, isFalse);
      RenderEditable? findEditable(RenderObject object) {
        if (object is RenderEditable) return object;
        RenderEditable? editable;
        object.visitChildren((child) {
          editable ??= findEditable(child);
        });
        return editable;
      }

      final collationEditable = findEditable(
        tester.renderObject(find.byType(SelectableText).first),
      )!;
      final collationText = collationEditable.text!.toPlainText();
      final collationIndex = collationText.indexOf('[2]');
      expect(collationIndex, greaterThanOrEqualTo(0));
      final collationTapPos = collationEditable.localToGlobal(
        collationEditable
            .getLocalRectForCaret(TextPosition(offset: collationIndex))
            .center,
      );
      await tester.tapAt(collationTapPos);
      await tester.pumpAndSettle();
      expect(find.text('宋【明】'), findsOneWidget);
      await tester.tap(find.text('關閉'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('介面設定'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('顯示首行'));
      await tester.pumpAndSettle();
      expect(scriptureDisplaySettings.showLineBeginnings, isTrue);
      expect(
        tester
            .widget<SelectableText>(find.byType(SelectableText).first)
            .textSpan!
            .toPlainText(),
        contains('[0001a01] '),
      );
    }, () => client);
  });

  testWidgets('in-volume search highlights matches across collation markers', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await scriptureDisplaySettings.load();
    await scriptureDisplaySettings.update(
      showCollation: true,
      showLineBeginnings: false,
      backgroundTheme: 'default',
    );
    final client = MockClient((request) async {
      if (request.url.path == '/stable/juans') {
        return http.Response(
          jsonEncode({
            'results': [
              '<div id="body"><span class="lb" id="T01n0001_p0001a01"></span>'
                  '<p>安<a class="noteAnchor" href="#n0001002"></a>置</p>'
                  '</div><div id="back"><div class="footnote" '
                  'id="n0001002">安置異文</div></div>',
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 404);
    });

    const passage = ScripturePassage(
      title: '測試經',
      reference: '卷 1',
      text: '安置',
      linehead: 'T01n0001_p0001a01',
      juan: '1',
      work: 'T0001',
    );
    await http.runWithClient(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: ScriptureReaderPage(
            passage: passage,
            query: '',
            searchHits: const [],
            initialHitIndex: 0,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('當卷搜尋'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '安置');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      final text = tester.widget<SelectableText>(
        find.byType(SelectableText).first,
      );
      final highlightedText = <String>[];
      void collectHighlights(InlineSpan span) {
        if (span is! TextSpan) return;
        if (span.style?.backgroundColor == const Color(0xFFFFE08A)) {
          highlightedText.add(span.text ?? '');
        }
        for (final child in span.children ?? const <InlineSpan>[]) {
          collectHighlights(child);
        }
      }

      collectHighlights(text.textSpan!);
      expect(highlightedText, containsAll(['安', '置']));
      expect(find.text('1 / 1'), findsOneWidget);
    }, () => client);
    await scriptureDisplaySettings.update(
      showCollation: false,
      showLineBeginnings: false,
      backgroundTheme: 'default',
    );
  });

  testWidgets('in-volume search highlights later lines with line beginnings', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await scriptureDisplaySettings.load();
    await scriptureDisplaySettings.update(
      showCollation: true,
      showLineBeginnings: true,
      backgroundTheme: 'default',
    );
    final client = MockClient((request) async {
      if (request.url.path == '/stable/juans') {
        final scriptureLines = List.generate(80, (index) {
          final lineNumber = index + 1;
          final linehead =
              'T01n0003_p0155a${lineNumber.toString().padLeft(2, '0')}';
          final text = lineNumber == 40
              ? '聞已不樂而歸，入定思惟實無免者，所以不'
              : '王聞是事，憶念往昔相師之言，若得在家必作輪王。';
          return '<span class="lb" id="$linehead"></span>'
              '<span class="t">$text</span>';
        }).join();
        return http.Response(
          jsonEncode({
            'results': ['<div id="body">$scriptureLines</div>'],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 404);
    });

    const passage = ScripturePassage(
      title: '毘婆尸佛經',
      reference: '卷 1',
      text: '聞已不樂而歸，入定思惟實無免者，所以不',
      linehead: 'T01n0003_p0155a40',
      juan: '1',
      work: 'T0003',
    );
    await http.runWithClient(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: ScriptureReaderPage(
            passage: passage,
            query: '',
            searchHits: const [],
            initialHitIndex: 0,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('當卷搜尋'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '免者');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      RenderEditable? findEditable(RenderObject object) {
        if (object is RenderEditable) return object;
        RenderEditable? editable;
        object.visitChildren((child) {
          editable ??= findEditable(child);
        });
        return editable;
      }

      final editable = findEditable(
        tester.renderObject(find.byType(SelectableText).first),
      );
      expect(editable, isNotNull);
      final renderEditable = editable!;
      final queryOffset = renderEditable.text!.toPlainText().indexOf('免者');
      expect(queryOffset, greaterThanOrEqualTo(0));
      final caret = renderEditable.localToGlobal(
        renderEditable
            .getLocalRectForCaret(TextPosition(offset: queryOffset))
            .center,
      );
      final viewport = tester.renderObject<RenderBox>(
        find.byType(SingleChildScrollView).first,
      );
      final viewportRect = viewport.localToGlobal(Offset.zero) & viewport.size;
      // 命中行預設置中顯示。
      expect((caret.dy - viewportRect.center.dy).abs(), lessThan(60));

      final text = tester.widget<SelectableText>(
        find.byType(SelectableText).first,
      );
      final highlightedText = <String>[];
      void collectHighlights(InlineSpan span) {
        if (span is! TextSpan) return;
        if (span.style?.backgroundColor == const Color(0xFFFFE08A)) {
          highlightedText.add(span.text ?? '');
        }
        for (final child in span.children ?? const <InlineSpan>[]) {
          collectHighlights(child);
        }
      }

      collectHighlights(text.textSpan!);
      expect(highlightedText, contains('免者'));
      expect(text.textSpan!.toPlainText(), contains('[0155a40] '));
      expect(find.text('1 / 1'), findsOneWidget);
    }, () => client);
    await scriptureDisplaySettings.update(
      showCollation: false,
      showLineBeginnings: false,
      backgroundTheme: 'default',
    );
  });

  testWidgets('reader centers a keyword search hit', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await scriptureDisplaySettings.load();
    await scriptureDisplaySettings.update(
      showCollation: true,
      showLineBeginnings: false,
      backgroundTheme: 'default',
    );
    final client = MockClient((request) async {
      if (request.url.path == '/stable/juans') {
        final scriptureLines = List.generate(80, (index) {
          final lineNumber = index + 1;
          final linehead =
              'T01n0003_p0155a${lineNumber.toString().padLeft(2, '0')}';
          final text = lineNumber == 40
              ? '${List.filled(8, '聞已不樂而歸，').join()}實無免者，所以不'
              : '王聞是事，憶念往昔相師之言，若得在家必作輪王。';
          return '<span class="lb" id="$linehead"></span><p>$text</p>';
        }).join();
        return http.Response(
          jsonEncode({
            'results': ['<div id="body">$scriptureLines</div>'],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 404);
    });

    const hit = ScripturePassage(
      title: '毘婆尸佛經',
      reference: '卷 1',
      text: '聞已不樂而歸，入定思惟實無免者',
      linehead: 'T01n0003_p0155a40',
      juan: '1',
      work: 'T0003',
    );
    const firstHit = ScripturePassage(
      title: '毘婆尸佛經',
      reference: '卷 1',
      text: '王聞是事',
      linehead: 'T01n0003_p0155a01',
      juan: '1',
      work: 'T0003',
    );

    await http.runWithClient(() async {
      await tester.pumpWidget(
        const MaterialApp(
          home: ScriptureReaderPage(
            passage: hit,
            query: '免者',
            searchHits: [firstHit, hit],
            initialHitIndex: 1,
          ),
        ),
      );
      await tester.pumpAndSettle();

      RenderEditable? findEditable(RenderObject object) {
        if (object is RenderEditable) return object;
        RenderEditable? editable;
        object.visitChildren((child) {
          editable ??= findEditable(child);
        });
        return editable;
      }

      final renderEditable = findEditable(
        tester.renderObject(find.byType(SelectableText).first),
      )!;
      final plainText = renderEditable.text!.toPlainText();
      final queryOffset = plainText.indexOf('免者');
      expect(queryOffset, greaterThanOrEqualTo(0));
      final lineStartOffset = plainText.indexOf('聞已不樂');
      expect(lineStartOffset, greaterThanOrEqualTo(0));
      final viewport = tester.renderObject<RenderBox>(
        find.byType(SingleChildScrollView).first,
      );
      final viewportRect = viewport.localToGlobal(Offset.zero) & viewport.size;
      // 長行換行時，置中的是命中所在行的行首。
      final lineCaret = renderEditable.localToGlobal(
        renderEditable
            .getLocalRectForCaret(TextPosition(offset: lineStartOffset))
            .center,
      );
      expect((lineCaret.dy - viewportRect.center.dy).abs(), lessThan(60));
      final matchCaret = renderEditable.localToGlobal(
        renderEditable
            .getLocalRectForCaret(TextPosition(offset: queryOffset))
            .center,
      );
      expect(matchCaret.dy, greaterThan(lineCaret.dy));
    }, () => client);
    await scriptureDisplaySettings.update(
      showCollation: false,
      showLineBeginnings: false,
      backgroundTheme: 'default',
    );
  });

  testWidgets('reader clamps hit scrolling at the start and end of a juan', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await scriptureDisplaySettings.load();
    final client = MockClient((request) async {
      if (request.url.path == '/stable/juans') {
        final scriptureLines = List.generate(80, (index) {
          final lineNumber = index + 1;
          final linehead =
              'T01n0003_p0155a${lineNumber.toString().padLeft(2, '0')}';
          final text = switch (lineNumber) {
            1 => '免者為首，王聞是事，憶念往昔相師之言。',
            80 => '王聞是事，憶念往昔相師之言，實無免者。',
            _ => '王聞是事，憶念往昔相師之言，若得在家必作輪王。',
          };
          return '<span class="lb" id="$linehead"></span><p>$text</p>';
        }).join();
        return http.Response(
          jsonEncode({
            'results': ['<div id="body">$scriptureLines</div>'],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 404);
    });

    ScripturePassage hitAt(int lineNumber) => ScripturePassage(
      title: '毘婆尸佛經',
      reference: '卷 1',
      text: '免者',
      linehead: 'T01n0003_p0155a${lineNumber.toString().padLeft(2, '0')}',
      juan: '1',
      work: 'T0003',
    );

    Future<double> openAndMeasure(ScripturePassage passage) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ScriptureReaderPage(
            key: ValueKey<String>(passage.linehead!),
            passage: passage,
            query: '免者',
            searchHits: [passage],
            initialHitIndex: 0,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final scrollable = tester.state<ScrollableState>(
        find.byType(Scrollable).last,
      );
      return scrollable.position.pixels;
    }

    await http.runWithClient(() async {
      // 命中在卷首：滑到最開頭。
      expect(await openAndMeasure(hitAt(1)), 0);
      // 命中在卷末：滑到最後面。
      final endPixels = await openAndMeasure(hitAt(80));
      final scrollable = tester.state<ScrollableState>(
        find.byType(Scrollable).last,
      );
      expect(
        (endPixels - scrollable.position.maxScrollExtent).abs(),
        lessThan(1),
      );
    }, () => client);
  });

  testWidgets('reader aligns hits that follow verse blocks', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await scriptureDisplaySettings.load();
    final buffer = StringBuffer('<div id="body">');
    for (var i = 0; i < 24; i++) {
      buffer.write(
        '<span class="lb" id="T01n0001_p0001a${i.toString().padLeft(2, '0')}">'
        '</span><div class="lg-row">'
        '<div class="lg-cell">自他俱入甘露城，</div>'
        '<div class="lg-cell">同證一如真法界。</div></div>',
      );
    }
    buffer.write(
      '<span class="lb" id="T01n0001_p0001b01"></span>'
      '<p>爾時樂遠離行菩薩，為諸大眾說是法已。</p>',
    );
    for (var i = 2; i < 20; i++) {
      buffer.write(
        '<span class="lb" id="T01n0001_p0001b${i.toString().padLeft(2, '0')}">'
        '</span><p>復次大眾聞是法已，歡喜奉行。</p>',
      );
    }
    buffer.write('</div>');
    final html = buffer.toString();
    final client = MockClient((request) async {
      if (request.url.path == '/stable/juans') {
        return http.Response(
          jsonEncode({
            'results': [html],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 404);
    });

    const hit = ScripturePassage(
      title: '測試經',
      reference: '卷 1',
      text: '爾時樂遠離行菩薩，為諸大眾說是法已。',
      linehead: 'T01n0001_p0001b01',
      juan: '1',
      work: 'T0001',
    );

    await http.runWithClient(() async {
      await tester.pumpWidget(
        const MaterialApp(
          home: ScriptureReaderPage(
            passage: hit,
            query: '樂遠離行',
            searchHits: [hit],
            initialHitIndex: 0,
          ),
        ),
      );
      await tester.pumpAndSettle();

      RenderEditable? findEditable(RenderObject object) {
        if (object is RenderEditable) return object;
        RenderEditable? editable;
        object.visitChildren((child) {
          editable ??= findEditable(child);
        });
        return editable;
      }

      final renderEditable = findEditable(
        tester.renderObject(find.byType(SelectableText).first),
      )!;
      final queryOffset = renderEditable.text!.toPlainText().indexOf('樂遠離行');
      expect(queryOffset, greaterThanOrEqualTo(0));
      final caret = renderEditable.localToGlobal(
        renderEditable
            .getLocalRectForCaret(TextPosition(offset: queryOffset))
            .center,
      );
      final viewport = tester.renderObject<RenderBox>(
        find.byType(SingleChildScrollView).first,
      );
      final viewportRect = viewport.localToGlobal(Offset.zero) & viewport.size;
      // 偈頌 WidgetSpan 只佔 1 個純文字字元，位移不能被 cell 文字長度污染。
      expect((caret.dy - viewportRect.center.dy).abs(), lessThan(60));
    }, () => client);
  });

  testWidgets('in-volume search highlights text inside verse cells', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await scriptureDisplaySettings.load();
    const html =
        '<div id="body">'
        '<span class="lb" id="T01n0001_p0001a01"></span>'
        '<div class="lg-row">'
        '<div class="lg-cell">自他俱入甘露城，</div>'
        '<div class="lg-cell">同證一如真法界。</div></div>'
        '</div>';
    final client = MockClient((request) async {
      if (request.url.path == '/stable/juans') {
        return http.Response(
          jsonEncode({
            'results': [html],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 404);
    });

    const passage = ScripturePassage(
      title: '測試經',
      reference: '卷 1',
      text: '甘露城',
      linehead: 'T01n0001_p0001a01',
      juan: '1',
      work: 'T0001',
    );

    await http.runWithClient(() async {
      await tester.pumpWidget(
        const MaterialApp(
          home: ScriptureReaderPage(
            passage: passage,
            query: '',
            searchHits: [],
            initialHitIndex: 0,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('當卷搜尋'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '甘露城');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      final highlights = <String>[];
      void collect(InlineSpan? span) {
        if (span == null) return;
        if (span is! TextSpan) return;
        if (span.style?.backgroundColor == const Color(0xFFFFE08A)) {
          highlights.add(span.text ?? '');
        }
        for (final child in span.children ?? const <InlineSpan>[]) {
          collect(child);
        }
      }

      final selectable = tester.widget<SelectableText>(
        find.byType(SelectableText).first,
      );
      collect(selectable.textSpan);
      expect(highlights, contains('甘露城'));
      expect(find.text('1 / 1'), findsOneWidget);
    }, () => client);
  });

  testWidgets('reader offers copy, citation, share and select-all for header '
      'and verse text', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await scriptureDisplaySettings.load();
    await scriptureDisplaySettings.update(
      showCollation: false,
      showLineBeginnings: false,
      backgroundTheme: 'default',
    );
    const html =
        '<div id="body">'
        '<p class="juan">佛說五蘊皆空經</p>'
        '<p class="byline">大唐三藏法師義淨奉制譯</p>'
        '<span class="lb" id="T01n0102_p0499c08"></span>'
        '<div class="lg-row">'
        '<div class="lg-cell">自他俱入甘露城，</div>'
        '<div class="lg-cell">同證一如真法界。</div></div>'
        '</div>';
    final client = MockClient((request) async {
      if (request.url.path == '/stable/juans') {
        return http.Response(
          jsonEncode({
            'results': [html],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 404);
    });

    RenderEditable findEditable(RenderObject object) {
      if (object is RenderEditable) return object;
      late RenderEditable editable;
      object.visitChildren((child) {
        editable = findEditable(child);
      });
      return editable;
    }

    Future<void> expectSelectionMenuAt(int offset) async {
      final editable = findEditable(
        tester.renderObject(find.byType(SelectableText).first),
      );
      final caret = editable.localToGlobal(
        editable.getLocalRectForCaret(TextPosition(offset: offset)).center,
      );
      await tester.longPressAt(caret);
      await tester.pumpAndSettle();
      expect(find.text('全選'), findsWidgets);
      expect(find.text('複製'), findsWidgets);
      expect(find.text('複製引文'), findsWidgets);
      expect(find.text('分享到其他軟件'), findsWidgets);
    }

    await http.runWithClient(() async {
      await tester.pumpWidget(
        const MaterialApp(
          home: ScriptureReaderPage(
            passage: ScripturePassage(
              title: '佛說五蘊皆空經',
              reference: '卷 1',
              text: '',
              linehead: 'T01n0102_p0499c08',
              juan: '1',
              work: 'T0102',
            ),
            query: '',
            searchHits: [],
            initialHitIndex: 0,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final selectable = tester.widget<SelectableText>(
        find.byType(SelectableText).first,
      );
      final plain = selectable.textSpan!.toPlainText();
      // 卷題（固定經名下方）。
      await expectSelectionMenuAt(plain.indexOf('佛說五蘊皆空經') + 1);
      // 译者／年代。
      await expectSelectionMenuAt(plain.indexOf('大唐三藏法師') + 1);
      // 偈頌正文。
      await expectSelectionMenuAt(plain.indexOf('甘露城') + 1);
    }, () => client);
  });

  testWidgets('reader highlights a keyword hit spanning two lines', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await scriptureDisplaySettings.load();
    const html =
        '<div id="body">'
        '<span class="lb" id="T01n0001_p0001a01"></span>'
        '<p>如是災禍其數有三，四大五'
        '<span class="lb" id="T01n0001_p0001a02"></span>'
        '蘊遷變。寂靜安樂。'
        '</p></div>';
    final client = MockClient((request) async {
      if (request.url.path == '/stable/juans') {
        return http.Response(
          jsonEncode({
            'results': [html],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 404);
    });

    const hit = ScripturePassage(
      title: '測試經',
      reference: '卷 1',
      text: '四大五蘊遷變',
      linehead: 'T01n0001_p0001a01',
      juan: '1',
      work: 'T0001',
    );

    await http.runWithClient(() async {
      await tester.pumpWidget(
        const MaterialApp(
          home: ScriptureReaderPage(
            passage: hit,
            query: '五蘊',
            searchHits: [hit],
            initialHitIndex: 0,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final highlights = <String>[];
      void collect(InlineSpan? span) {
        if (span == null || span is! TextSpan) return;
        if (span.style?.backgroundColor == const Color(0xFFDDEDE8)) {
          highlights.add(span.text ?? '');
        }
        for (final child in span.children ?? const <InlineSpan>[]) {
          collect(child);
        }
      }

      collect(
        tester
            .widget<SelectableText>(find.byType(SelectableText).first)
            .textSpan,
      );
      // 「五」與「蘊」分別落在兩個經文行，仍要各自高亮。
      expect(highlights, containsAll(['五', '蘊']));
    }, () => client);
  });

  testWidgets('reader offers in-volume search, bookmarks, and work selection', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await scriptureDisplaySettings.load();
    final client = MockClient((request) async {
      if (request.url.path == '/stable/juans') {
        return http.Response(
          jsonEncode({
            'results': [
              '<div id="body">'
                  '<span class="lb" id="T01n0001_p0001a01"></span>'
                  '<span class="t">五蘊第一</span>'
                  '<span class="lb" id="T01n0001_p0001a02"></span>'
                  '<span class="t">五蘊第二</span>'
                  '</div>',
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path == '/stable/catalog_entry') {
        return http.Response(
          jsonEncode({
            'label': '部類目錄',
            'results': [
              {
                'work': 'T0001',
                'file': 'T01n0001',
                'label': 'T0001 長阿含經 (2卷)',
                'node_type': 'work',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path == '/stable/works/toc') {
        return http.Response(
          jsonEncode({
            'results': [
              {
                'juan': [
                  {
                    'file': 'T01n0001',
                    'juan': 1,
                    'lb': '0001a01',
                    'title': '第一',
                  },
                  {
                    'file': 'T01n0001',
                    'juan': 2,
                    'lb': '0002a01',
                    'title': '第二',
                  },
                ],
                'mulu': [],
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 404);
    });
    const passage = ScripturePassage(
      title: '長阿含經',
      reference: '卷 1',
      text: '五蘊第一',
      linehead: 'T01n0001_p0001a01',
      juan: '1',
      work: 'T0001',
      availableJuans: [1, 2],
    );

    await http.runWithClient(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: ScriptureReaderPage(
            passage: passage,
            query: '',
            searchHits: const [],
            initialHitIndex: 0,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('當卷搜尋'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '五蘊');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.text('1 / 2'), findsOneWidget);
      await tester.tap(find.byTooltip('下一筆'));
      await tester.pumpAndSettle();
      expect(find.text('2 / 2'), findsOneWidget);
      await tester.tap(find.byTooltip('關閉'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('書籤'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.bookmark_added_rounded), findsOneWidget);
      final preferences = await SharedPreferences.getInstance();
      final savedBookmarks =
          jsonDecode(preferences.getString('reader_bookmarks')!)
              as List<dynamic>;
      expect(savedBookmarks, hasLength(1));

      await tester.tap(find.byTooltip('選擇佛經'));
      await tester.pumpAndSettle();
      for (final tab in ['部類', '冊別', '作譯者', '年代', '經目查詢', 'Goto 查詢']) {
        expect(find.text(tab), findsOneWidget);
      }
      await tester.tap(find.text('T0001 長阿含經 (2卷)'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('reader-fixed-title')), findsOneWidget);
      // 經名會跟隨簡繁設定顯示，只確認文字存在即可。
      expect(find.textContaining('阿含'), findsWidgets);
      expect(find.text('第 1 / 2 卷'), findsOneWidget);
    }, () => client);
  });

  testWidgets('display settings panel exposes typography and reading options', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await scriptureDisplaySettings.load();

    await tester.pumpWidget(const CbetaSearchApp());
    await tester.tap(find.byTooltip('介面設定'));
    await tester.pumpAndSettle();

    expect(find.text('經文字體大小'), findsOneWidget);
    expect(find.text('經文行高'), findsOneWidget);
    expect(find.text('明體'), findsOneWidget);
    expect(find.text('黑體'), findsOneWidget);
    expect(find.text('楷體'), findsOneWidget);
    expect(find.text('系統'), findsOneWidget);
    expect(find.text('宣紙'), findsOneWidget);
    expect(find.text('顯示勘校'), findsOneWidget);
    expect(find.text('顯示首行'), findsOneWidget);
    final settingsHeader = find.widgetWithText(ListTile, '介面設定');
    expect(
      find.descendant(of: settingsHeader, matching: find.byTooltip('切換簡體／繁體')),
      findsNothing,
    );
    expect(
      find.descendant(of: settingsHeader, matching: find.byTooltip('切换简体／繁体')),
      findsNothing,
    );
    await tester.scrollUntilVisible(
      find.text('更新離線經文'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('更新離線經文'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('關於我們'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('關於我們'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, '黑體'));
    await tester.pumpAndSettle();
    expect(scriptureDisplaySettings.fontFamily, 'sans');
    await tester.tap(find.byTooltip('關閉'));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'search navigation stays at the bottom and switching hits reuses the loaded juan',
    (WidgetTester tester) async {
      var juanRequests = 0;
      final scriptureHtml =
          '<div id="body">'
          '${List.generate(60, (index) {
            final line = (index + 1).toString().padLeft(2, '0');
            return '<span class="lb" id="T01n0003_p0001a$line">'
                'T01n0003_p0001a$line</span>'
                '<span class="t">五蘊第${index + 1}句</span>';
          }).join()}'
          '</div>';
      final client = MockClient((request) async {
        if (request.url.path == '/stable/juans') {
          juanRequests++;
          return http.Response(
            jsonEncode({
              'results': [scriptureHtml],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('{}', 404);
      });

      const first = ScripturePassage(
        title: '毘婆尸佛經',
        reference: '卷 1 · T01 · 0001a01',
        text: '五蘊第一句',
        linehead: 'T01n0003_p0001a01',
        juan: '1',
        work: 'T0003',
        availableJuans: [1, 2],
      );
      const second = ScripturePassage(
        title: '毘婆尸佛經',
        reference: '卷 1 · T01 · 0001a02',
        text: '五蘊第二句',
        linehead: 'T01n0003_p0001a02',
        juan: '1',
        work: 'T0003',
        availableJuans: [1, 2],
      );

      await http.runWithClient(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: ScriptureReaderPage(
              passage: first,
              query: '五蘊',
              searchHits: const [first, second],
              initialHitIndex: 0,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('1 / 2 筆'), findsOneWidget);
        expect(juanRequests, 1);
        final scriptureText = tester.widget<SelectableText>(
          find.byType(SelectableText),
        );
        expect(scriptureText.style?.fontSize, 19);
        expect(scriptureText.style?.height, 1.9);
        expect(
          tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
          const Color(0xFFF5EFE0),
        );
        expect(
          tester.getCenter(find.text('1 / 2 筆')).dy,
          greaterThan(tester.getSize(find.byType(Scaffold)).height - 80),
        );
        final navY = tester.getCenter(find.text('1 / 2 筆')).dy;

        await tester.tap(find.byTooltip('下一筆'));
        await tester.pumpAndSettle();

        expect(find.text('2 / 2 筆'), findsOneWidget);
        expect(juanRequests, 1);
        expect(find.text('下一卷'), findsOneWidget);
        await tester.ensureVisible(find.text('下一卷'));
        await tester.pumpAndSettle();
        expect(tester.getCenter(find.text('下一卷')).dy, lessThan(navY));
        expect(tester.getCenter(find.text('2 / 2 筆')).dy, closeTo(navY, 1));
      }, () => client);
    },
  );
}
