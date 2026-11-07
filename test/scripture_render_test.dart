import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xuefo/reader/reader_layout.dart';
import 'package:xuefo/scripture/models.dart';
import 'package:xuefo/scripture/parser.dart';
import 'package:xuefo/scripture/reader_blocks.dart';
import 'package:xuefo/scripture/source_text.dart';

void main() {
  test('inline token spans do not change the parsed volume', () {
    const tokenized =
        '<div id="body"><div class="div-other">'
        '<span class="lb" id="T03n0152_p0001a03"></span>'
        '<p class=\'juan\'><span class="t" l="0001a03" w="1">六度集經</span>'
        '<span class="t" l="0001a03" w="5">卷第一</span></p>'
        '<p class="byline"><span class=\'lineInfo\' line=\'0001a05\'></span>'
        '吳<a id=\'note_anchor_0001001\' class=\'noteAnchor\' '
        'href=\'#n0001001\'>[1]</a>康居國沙門康僧會譯</p>'
        '<p data-head-level="1" class="head">布施<span class="pc">度</span>無極'
        '<a class="noteAnchor" href="#n0001002"></a>章第'
        '<a class="noteAnchor" href="#n0001003"></a>一'
        '<small class=\'inline-note doube-line-note\'>'
        '<a class="noteAnchor" href="#n0001004"></a>'
        '<span class="t" l="0001a06" w="9">此有</span>'
        '<span class="pc">，</span>'
        '<span class="t" l="0001a06" w="11">一</span>十章</small></p>'
        '<p>如是我聞。</p></div></div>'
        '<div id=\'back\'><div class="footnote" id="n0001001">注一</div>'
        '<div class="footnote" id="n0001002">注二</div></div>';
    const plain =
        '<div id="body"><div class="div-other">'
        '<span class="lb" id="T03n0152_p0001a03"></span>'
        '<p class=\'juan\'>六度集經卷第一</p>'
        '<p class="byline"><span class=\'lineInfo\' line=\'0001a05\'></span>'
        '吳<a id=\'note_anchor_0001001\' class=\'noteAnchor\' '
        'href=\'#n0001001\'>[1]</a>康居國沙門康僧會譯</p>'
        '<p data-head-level="1" class="head">布施度無極'
        '<a class="noteAnchor" href="#n0001002"></a>章第'
        '<a class="noteAnchor" href="#n0001003"></a>一'
        '<small class=\'inline-note doube-line-note\'>'
        '<a class="noteAnchor" href="#n0001004"></a>此有，一十章</small></p>'
        '<p>如是我聞。</p></div></div>'
        '<div id=\'back\'><div class="footnote" id="n0001001">注一</div>'
        '<div class="footnote" id="n0001002">注二</div></div>';

    String signature(ScriptureLine line) => [
      line.role.name,
      line.headingLevel,
      line.paragraphEnd,
      line.linehead,
      line.text,
      line.footnotes
          .map((note) => '${note.label}@${note.offset}#${note.clue}')
          .join(','),
      line.inlineNotes.map((note) => '${note.offset}+${note.length}').join(','),
    ].join('|');

    final tokenLines = parseScriptureHtml(tokenized);
    final plainLines = parseScriptureHtml(plain);
    expect(
      tokenLines.map(signature).toList(),
      plainLines.map(signature).toList(),
    );
    expect(tokenLines.map((line) => line.text).toList(), [
      '六度集經卷第一\n',
      '吳康居國沙門康僧會譯\n',
      '布施度無極章第一（此有，一十章）\n',
      '如是我聞。\n',
    ]);
    expect(
      tokenLines[2].inlineNotes
          .map((note) => '${note.offset}+${note.length}')
          .toList(),
      ['8+8'],
    );
  });

  test('keeps spans without a class so block nesting stays intact', () {
    final lines = parseScriptureHtml(
      '<div id="body"><p>甲</p>'
      '<span style="margin-left:1em"><p class="form">乙</p></span>'
      '<p>丙</p></div>',
    );
    // 若把沒有 class 的 span 也拿掉，乙會多出「後面還有段落」的判定。
    expect(lines.map((line) => line.paragraphEnd).toList(), [
      false,
      false,
      false,
    ]);
  });

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

  test('retains the juan title at line 0001b08 as a body heading', () {
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
    expect(title.headingLevel, 2);
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
        .where((line) => line.role != ScriptureLineRole.byline)
        .toList();
    // 作譯者也在正文 layout 內，整卷行的位移才與離線索引一致。
    final layout = buildScriptureTextLayout(
      lines,
      showLineBeginnings: false,
      showCollation: true,
    );

    expect(bodyLines.first.role, ScriptureLineRole.volumeTitle);
    expect(bodyLines.first.headingLevel, 2);
    // 卷末（或序後）重複的卷題仍是卷題樣式，只是不再當作卷名 metadata。
    expect(bodyLines.last.role, ScriptureLineRole.volumeTailTitle);
    expect(bodyLines.last.headingLevel, 2);
    expect(layout.text, contains('長阿含經序'));
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

  test('verse-cell boundary footnote does not shift later cell offsets', () {
    final lines = parseScriptureHtml(
      '<div id="body"><div class="lg-row">'
      '<div class="lg-cell">左格<a class="noteAnchor" '
      'href="#n0008001"></a></div>'
      '<div class="lg-cell">右格</div>'
      '</div></div>'
      '<div id="back"><div class="footnote" id="n0008001">校勘</div></div>',
    );
    final layout = buildScriptureTextLayout(
      lines,
      showLineBeginnings: false,
      showCollation: true,
    );

    expect(layout.text, '\uFFFC左格[1]\uFFFC右格\n');
    expect('[1]'.allMatches(layout.text), hasLength(1));
    expect(
      layoutEditableOffsetForSource(layout, lines, 3, showCollation: true),
      8,
    );
  });

  test('offline volume title hit resolves inside the body layout', () {
    final lines = parseScriptureHtml(
      '<div id="body"><p class="byline">後秦譯者</p><p>序文。</p>'
      '<p class="juan">佛說長阿含經卷第一</p><p>正文。</p></div>',
    );
    // 作譯者與卷題都在正文原位排版，layout 覆蓋整卷，
    // 離線索引的整卷來源位移可以直接換算成畫面位移。
    final layout = buildScriptureTextLayout(
      lines,
      showLineBeginnings: false,
      showCollation: true,
    );
    final sourceOffset = buildScriptureSearchSource(lines).indexOf('佛說長阿含經卷第一');
    final passage = ScripturePassage(
      title: '長阿含經',
      reference: '卷 1',
      text: '',
      juan: '1',
      work: 'T0001',
      sourceOffset: sourceOffset,
      snippet: '佛說長阿含經卷第一',
    );

    final target = resolveSearchTargetOffset(
      layout,
      lines,
      passage,
      '佛說長阿含經卷第一',
      0,
    );

    expect(target.sourceOffset, sourceOffset);
    expect(layout.text.substring(target.offset), startsWith('佛說長阿含經卷第一'));
  });

  test('centered volume title keeps layout and block offsets aligned', () {
    final lines = parseScriptureHtml(
      '<div id="body"><span class="lb" id="T01n0001_p0001b08"></span>'
      '<p class="juan">佛說長阿含經卷第一</p><p>正文。</p></div>',
    );
    final layout = buildScriptureTextLayout(
      lines,
      showLineBeginnings: true,
      showCollation: false,
    );
    final blocks = buildScriptureReaderBlocks(lines);
    final bases = scriptureBlockOffsetBases(blocks, lines, layout, true);

    // 段前換行 + 標題行首的置中 placeholder，其後才是行首標記與標題。
    expect(layout.text, startsWith('\n\uFFFC[0001b08] 佛說長阿含經卷第一\n\n'));
    expect(layout.lineStarts.first, 12);
    expect(bases.first, 0);
    expect(
      layoutEditableOffsetForSource(layout, lines, 0, showCollation: false),
      12,
    );
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

  test('keeps the paragraph role when a line anchor heads the paragraph', () {
    // 下載器把壓縮檔的段落級 lineInfo 改寫成段落內的 <span class="lb">。
    // 這個錨點不產生任何行，卻也不能把段落開頭的 role／標題層級重置掉，
    // 否則離線經卷的卷題與作譯者會退化成普通正文行。
    final lines = parseScriptureHtml(
      '<div id="body"><p class="juan"><span class="lb" id="T03n0152_p0001a03">'
      'T03n0152_p0001a03</span>六度集經卷第一</p>'
      '<p class="byline"><span class="lb" id="T03n0152_p0001a05">'
      'T03n0152_p0001a05</span>吳康居國沙門康僧會譯</p></div>',
    );

    expect(lines.first.role, ScriptureLineRole.volumeTitle);
    expect(lines.first.headingLevel, 2);
    expect(lines.first.linehead, 'T03n0152_p0001a03');
    expect(lines.last.role, ScriptureLineRole.byline);
    expect(lines.last.linehead, 'T03n0152_p0001a05');
  });
}
