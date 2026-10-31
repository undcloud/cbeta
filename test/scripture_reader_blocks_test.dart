import 'package:flutter_test/flutter_test.dart';
import 'package:xuefo/scripture/models.dart';
import 'package:xuefo/scripture/reader_blocks.dart';

ScriptureLine textLine(String text) =>
    ScriptureLine(text: text, linehead: null);

ScriptureLine tableLine(String label) => ScriptureLine(
  text: '',
  tableRows: [
    [ScriptureTableCell(text: label), ScriptureTableCell(text: '頁碼')],
  ],
);

ScriptureLine verseLine(String cell) =>
    ScriptureLine(text: '', verseCells: [cell]);

ScriptureLine imageLine() => ScriptureLine(
  text: '',
  images: [ScriptureImage(source: 'https://example.org/a.gif')],
);

void main() {
  test('consecutive table rows share one block up to the line budget', () {
    final lines = List.generate(30, (index) => tableLine('行${index + 1}'));

    final blocks = buildScriptureReaderBlocks(lines, maxTableLines: 12);

    expect(blocks.length, 3);
    expect(
      blocks.every((block) => block.kind == ScriptureReaderBlockKind.table),
      isTrue,
    );
    expect(blocks[0].startLine, 0);
    expect(blocks[0].endLine, 12);
    expect(blocks[2].startLine, 24);
    expect(blocks[2].endLine, 30);
  });

  test('text lines are split by the character budget', () {
    final lines = List.generate(
      10,
      (_) => textLine(List.filled(20, '聞').join()),
    );

    final blocks = buildScriptureReaderBlocks(lines, maxTextCharacters: 100);

    expect(blocks.length, 2);
    expect(
      blocks.every((block) => block.kind == ScriptureReaderBlockKind.text),
      isTrue,
    );
    expect(blocks.map((block) => block.lineCount), everyElement(5));
  });

  test('verse runs are split by the verse line budget', () {
    final lines = <ScriptureLine>[
      textLine('序'),
      ...List.generate(10, (index) => verseLine('偈${index + 1}')),
      textLine('結'),
    ];

    final blocks = buildScriptureReaderBlocks(lines, maxVerseLines: 4);

    expect(blocks.map((block) => block.kind), <ScriptureReaderBlockKind>[
      ScriptureReaderBlockKind.text,
      ScriptureReaderBlockKind.verse,
      ScriptureReaderBlockKind.verse,
      ScriptureReaderBlockKind.verse,
      ScriptureReaderBlockKind.text,
    ]);
    expect(blocks[1].startLine, 1);
    expect(blocks[1].endLine, 5);
    expect(blocks[3].startLine, 9);
    expect(blocks[3].endLine, 11);
  });

  test('image-only lines become their own block', () {
    final lines = <ScriptureLine>[textLine('前'), imageLine(), textLine('後')];

    final blocks = buildScriptureReaderBlocks(lines);

    expect(blocks.map((block) => block.kind), <ScriptureReaderBlockKind>[
      ScriptureReaderBlockKind.text,
      ScriptureReaderBlockKind.image,
      ScriptureReaderBlockKind.text,
    ]);
  });

  test('blocks cover every line exactly once', () {
    final lines = <ScriptureLine>[
      textLine('甲'),
      tableLine('表一'),
      tableLine('表二'),
      ...List.generate(6, (index) => verseLine('偈${index + 1}')),
      imageLine(),
      textLine('乙'),
    ];

    final blocks = buildScriptureReaderBlocks(lines, maxVerseLines: 4);

    expect(blocks.map((block) => block.startLine).toList(), <int>[
      0,
      1,
      3,
      7,
      9,
      10,
    ]);
    expect(blocks.last.endLine, lines.length);
    for (var index = 1; index < blocks.length; index++) {
      expect(blocks[index].startLine, blocks[index - 1].endLine);
    }
  });
}
