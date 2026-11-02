import 'package:flutter_test/flutter_test.dart';
import 'package:xuefo/reader/reader_layout.dart';
import 'package:xuefo/scripture/parser.dart';

void main() {
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
}
