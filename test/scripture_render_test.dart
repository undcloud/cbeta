import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xuefo/reader/reader_layout.dart';
import 'package:xuefo/scripture/models.dart';
import 'package:xuefo/scripture/parser.dart';
import 'package:xuefo/scripture/source_text.dart';

void main() {
  test('adds paragraph spacing without shifting source offsets', () {
    final lines = parseScriptureHtml(
      '<div id="body"><p>第一段。</p><p>第二段。</p></div>',
    );
    final layout = buildScriptureTextLayout(
      lines,
      showLineBeginnings: false,
      showCollation: false,
    );

    expect(layout.text, '第一段。\n\n第二段。\n');
    expect(buildScriptureSearchSource(lines), layout.text);
    expect(layout.lineSourceStarts, [0, '第一段。\n'.length + 1]);
  });

  testWidgets('reader rendering uses the same paragraph spacing as layout', (
    tester,
  ) async {
    final lines = parseScriptureHtml(
      '<div id="body"><p>第一段。</p><p>第二段。</p></div>',
    );
    final layout = buildScriptureTextLayout(
      lines,
      showLineBeginnings: false,
      showCollation: false,
    );
    late TextSpan readerSpan;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            readerSpan = interactivePassageText(
              context,
              const ScripturePassage(title: '', reference: '', text: ''),
              '',
              startAt: null,
              localSearchRange: null,
              queryRanges: const [],
              sourceLines: lines,
              firstLineIndex: 0,
              lineCount: lines.length,
              offsetBase: 0,
              sourceOffsetBase: 0,
              width: 400,
              recognizers: [],
            );
            return Material(child: Text.rich(readerSpan));
          },
        ),
      ),
    );

    expect(readerSpan.toPlainText(), layout.text);
  });

  test('keeps prose before a verse block in the rendered layout', () {
    const passage =
        '佛告諸比丘：「過去九十一劫，時，世有佛名毘婆尸如來、至真，出現于世。'
        '復次，比丘！過去三十一劫，有佛名尸棄如來、至真，出現於世。'
        '復次，比丘！即彼三十一劫中，有佛名毘舍婆如來、至真，出現於世。'
        '復次，比丘！此賢劫中有佛名拘樓孫，又名拘那含，又名迦葉。'
        '我今亦於賢劫中成最正覺。」佛時頌曰：';
    final lines = parseScriptureHtml(
      '<div id="body">'
      '<span class="lb" id="T01n0001_p0001c19"></span>'
      '<p>$passage</p>'
      '<div class="lg regular"><div class="lg-row">'
      '<div class="lg-cell">「過九十一劫，</div>'
      '<div class="lg-cell">有毘婆尸佛；</div>'
      '</div></div></div>',
    );

    final proseLine = lines.singleWhere((line) => line.text.contains(passage));
    final layout = buildScriptureTextLayout(
      lines,
      showLineBeginnings: false,
      showCollation: false,
    );

    expect(proseLine.verseCells, isEmpty);
    expect(layout.text, contains(passage));
    expect(layout.text, contains('過九十一劫，'));
  });

  test('retains the juan title at line 0001b08 for the reader header', () {
    final lines = parseScriptureHtml(
      '<div id="body"><p class="head">長阿含經序</p>'
      '<p class="byline">後秦譯者</p><p>序文。</p>'
      '<span class="lb" id="T01n0001_p0001b08"></span>'
      '<p class="juan">佛說<a class="noteAnchor" href="#n0001011"></a>'
      '長阿含經卷第一</p></div>'
      '<div id="back"><div class="footnote" id="n0001011">校勘</div></div>',
    );
    final title = lines.singleWhere(
      (line) => line.linehead == 'T01n0001_p0001b08',
    );

    expect(title.role, ScriptureLineRole.volumeTitle);
    expect(
      visibleScriptureLine(
        title,
        showLineBeginnings: false,
        showCollation: true,
      ),
      '佛說[11]長阿含經卷第一\n',
    );
  });

  test('keeps the volume title that follows the preface in body text', () {
    final lines = parseScriptureHtml(
      '<div id="body">'
      '<p class="juan">長阿含經序</p>'
      '<p class="byline">後秦譯者</p>'
      '<p>序文。</p>'
      '<span class="lb" id="T01n0001_p0001b08"></span>'
      '<p class="juan"><span>佛說</span><a class="noteAnchor" '
      'href="#n0001011"></a><span>長阿含經卷第一</span></p>'
      '</div><div id="back"><div class="footnote" id="n0001011">'
      '校勘</div></div>',
    );
    final bodyLines = lines
        .where(
          (line) =>
              line.role != ScriptureLineRole.volumeTitle &&
              line.role != ScriptureLineRole.byline,
        )
        .toList();
    final layout = buildScriptureTextLayout(
      bodyLines,
      showLineBeginnings: false,
      showCollation: true,
    );

    expect(bodyLines.last.role, ScriptureLineRole.navigationAnchor);
    expect(layout.text, contains('佛說[11]長阿含經卷第一'));
  });

  test('renders star collation marks in prose and verse cells', () {
    final lines = parseScriptureHtml(
      '<div id="body">'
      '<span class="lb" id="T01n0001_p0002a17"></span>'
      '<p>正文<a class="noteAnchor star" href="#n0001026"></a>續文</p>'
      '<span class="lb" id="T01n0001_p0002a21"></span>'
      '<div class="lg-row"><div class="lg-cell">左格</div>'
      '<div class="lg-cell">出<a class="noteAnchor star" '
      'href="#n0002002"></a>拘利若姓。</div></div>'
      '</div><div id="back"><div class="footnote" id="n0001026">'
      '星號校勘一</div><div class="footnote" id="n0002002">'
      '星號校勘二</div></div>',
    );
    final layout = buildScriptureTextLayout(
      lines,
      showLineBeginnings: false,
      showCollation: true,
    );

    expect('[＊]'.allMatches(layout.text), hasLength(2));
  });

  test('shows a verse-cell footnote only in its source cell', () {
    final lines = parseScriptureHtml(
      '<div id="body"><div class="lg-row">'
      '<div class="lg-cell">如鳥遊虛空，</div>'
      '<div class="lg-cell"><a class="noteAnchor" href="#n0008006"></a>'
      '東西隨風<a class="noteAnchor add" href="#cb_note_5"></a>逝；'
      '</div></div></div>'
      '<div id="back"><div class="footnote" id="n0008006">校勘</div>'
      '<div class="footnote add" id="cb_note_5">增補</div></div>',
    );
    final layout = buildScriptureTextLayout(
      lines,
      showLineBeginnings: false,
      showCollation: true,
    );

    expect('[6]'.allMatches(layout.text), hasLength(1));
    expect(layout.text, contains('[6]東西隨風[A5]逝；'));
  });

  testWidgets('interactive reader spans show each footnote once', (
    tester,
  ) async {
    final lines = parseScriptureHtml(
      '<div id="body"><div class="lg-row">'
      '<div class="lg-cell">如鳥遊虛空，</div>'
      '<div class="lg-cell"><a class="noteAnchor" href="#n0008006"></a>'
      '東西隨風<a class="noteAnchor add" href="#cb_note_5"></a>逝；'
      '</div></div></div>'
      '<div id="back"><div class="footnote" id="n0008006">校勘</div>'
      '<div class="footnote add" id="cb_note_5">增補</div></div>',
    );
    late TextSpan readerSpan;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            readerSpan = interactivePassageText(
              context,
              const ScripturePassage(title: '', reference: '', text: ''),
              '',
              startAt: null,
              localSearchRange: null,
              queryRanges: const [],
              sourceLines: lines,
              firstLineIndex: 0,
              lineCount: lines.length,
              offsetBase: 0,
              sourceOffsetBase: 0,
              width: 400,
              recognizers: [],
            );
            return Material(child: Text.rich(readerSpan));
          },
        ),
      ),
    );

    final rendered = readerSpan.toPlainText(includePlaceholders: true);
    expect('[6]'.allMatches(rendered), hasLength(1));
    expect(rendered, contains('[6]東西隨風[A5]逝；'));
  });
}
