import 'package:html/dom.dart' as html_dom;
import 'package:html/parser.dart' show parseFragment;

import 'models.dart';

/// 逐行解析用到的正則只構造一次:離線搜尋會一次解析數萬行經文,
/// 每行構造數個 `RegExp` 會把掃描變成不可中斷的長任務。
final _whitespacePattern = RegExp(r'\s+');
final _leadingSpacePattern = RegExp(r'^[ \t]+');
final _trailingSpacePattern = RegExp(r'[ \t]+$');
final _anchorPrefixPattern = RegExp(r'^#');
final _noteNumberPattern = RegExp(r'n\d+(\d{3})$');
final _trailingDigitsPattern = RegExp(r'(\d+)$');
final _bracketNumberPattern = RegExp(r'\[\d+\]');

/// 線上版把正文切成逐字／標點 token：`<span class="t" l=… w=…>`、
/// `<span class="pc">`、`<span class="line_space">`……這些 class 對解析沒有
/// 語意，卻能佔 DOM 節點九成以上（一卷可達 13 萬個 span）。先把它們的
/// 開閉標籤整對拿掉再 `parseFragment`，實測同樣一卷峰值記憶體減半、
/// 解析時間約三分之一；沒有 class 的 span 可能包著區塊元素
/// （`<span style=…><p>…`），保留不動。
final _spanTagPattern = RegExp(r'<span\b[^>]*>|</span>', caseSensitive: false);
final _classAttributePattern = RegExp(
  r'''class\s*=\s*("([^"]*)"|'([^']*)')''',
  caseSensitive: false,
);
final _semanticSpanClassPattern = RegExp(
  r'(^|\s)(lb|lineinfo|siddam|ranjana|inline-note|doube-line-note|footnote)(\s|$)',
  caseSensitive: false,
);

String _stripInlineTokenSpans(String source) {
  if (!source.contains('<span')) return source;
  final out = StringBuffer();
  final keepStack = <bool>[];
  var cursor = 0;
  for (final match in _spanTagPattern.allMatches(source)) {
    out.write(source.substring(cursor, match.start));
    cursor = match.end;
    final tag = match.group(0)!;
    if (tag.codeUnitAt(1) == 0x2F) {
      // `</span>`：與對應的開標籤一起決定留或丟。
      if (keepStack.isEmpty) {
        out.write(tag);
      } else if (keepStack.removeLast()) {
        out.write(tag);
      }
      continue;
    }
    final classMatch = _classAttributePattern.firstMatch(tag);
    final classValue = classMatch?.group(2) ?? classMatch?.group(3);
    final keep =
        classValue == null ||
        classValue.trim().isEmpty ||
        _semanticSpanClassPattern.hasMatch(classValue);
    keepStack.add(keep);
    if (keep) out.write(tag);
  }
  out.write(source.substring(cursor));
  return out.toString();
}

/// 部分經典的行號在經號與 p 之間沒有底線（例如梵語千字文
/// `T54n2133Ap1190a13`），解析時統一補成 `_p` 格式，
/// 與搜尋 API／Goto 拼出的行號一致，下游引用與跳轉才可比對。
final _joinedLineheadPattern = RegExp(r'^([A-Z]+\d+n\d+[A-Z]?)p(?=\d)');

String visibleScriptureLine(
  ScriptureLine line, {
  required bool showLineBeginnings,
  required bool showCollation,
}) {
  final result = StringBuffer();
  if (showLineBeginnings &&
      line.linehead != null &&
      !line.suppressesLineBeginning) {
    result
      ..write('[')
      ..write(line.linehead!.split('_p').last)
      ..write('] ');
  }
  var offset = 0;
  if (showCollation) {
    for (final footnote in line.footnotes) {
      final noteOffset = footnote.offset.clamp(offset, line.text.length);
      result
        ..write(line.text.substring(offset, noteOffset))
        ..write('[${footnote.label}]');
      offset = noteOffset;
    }
  }
  result.write(line.text.substring(offset));
  if (line.verseCells.isNotEmpty) result.write('\n');
  return result.toString();
}

/// 測試計數：整卷 HTML 被解析過幾次。展開摘要那一段有快取之後，同一卷再展開
/// 一次不該讓這個數字繼續長。
int debugScriptureHtmlParses = 0;

List<ScriptureLine> parseScriptureHtml(String source) {
  debugScriptureHtmlParses += 1;
  final fragment = parseFragment(_stripInlineTokenSpans(source));
  final root = fragment.querySelector('#body') ?? fragment;
  final footnoteContent = {
    for (final note in fragment.querySelectorAll('#back .footnote'))
      if (note.id.isNotEmpty)
        note.id: note.text.trim().replaceAll(_whitespacePattern, ' '),
  };
  final lines = <ScriptureLine>[];
  String? linehead;
  int? activeVerseCellIndex;
  var headingLevel = 0;
  var lineRole = ScriptureLineRole.regular;
  final text = StringBuffer();
  StringBuffer? activeCell;
  List<String> verseCells = [];
  final images = <ScriptureImage>[];
  List<List<ScriptureTableCell>> tableRows = [];
  var footnotes = <ScriptureFootnote>[];
  var inlineNotes = <ScriptureInlineNote>[];
  final scriptRuns = <ScriptureScriptRun>[];
  final activeInlineNotes = <int>[];
  var paragraphEnd = false;

  void flushLine() {
    // 夾注跨行(lb 在 small 內)時：本行末補上右括號並記錄本段的樣式範圍，
    // 下一行以左括號續接，使每行括號成對、小字範圍不錯位。
    final continuesInlineNotes = activeInlineNotes.isNotEmpty;
    final emittedLine =
        linehead != null ||
        text.isNotEmpty ||
        images.isNotEmpty ||
        tableRows.isNotEmpty;
    // 離線壓縮檔經下載器改寫後，行錨點會變成段落內的 <span class="lb">，
    // 緊接在 `<p class="byline">` 等標記之後。這次 flush 不產生任何行，
    // 若連行屬性一起重置，段落開頭的 role／標題層級就會被吞掉。
    final pendingRole = lineRole;
    final pendingHeadingLevel = headingLevel;
    final pendingParagraphEnd = paragraphEnd;
    if (continuesInlineNotes) {
      if (text.toString() == '（') {
        text.clear();
      } else if (text.isNotEmpty) {
        text.write('）');
        for (final start in activeInlineNotes) {
          inlineNotes.add(
            ScriptureInlineNote(offset: start, length: text.length - start),
          );
        }
      }
    }
    if (emittedLine) {
      final rawText = text.toString();
      final leadingMatch = _leadingSpacePattern.firstMatch(rawText);
      final leadingWhitespace = leadingMatch?.end ?? 0;
      final trailingMatch = _trailingSpacePattern.firstMatch(rawText);
      final trimmedText = rawText.substring(
        leadingWhitespace,
        trailingMatch?.start ?? rawText.length,
      );
      lines.add(
        ScriptureLine(
          text: trimmedText,
          linehead: linehead,
          footnotes: footnotes
              .map(
                (note) => ScriptureFootnote(
                  offset: (note.offset - leadingWhitespace).clamp(
                    0,
                    trimmedText.length,
                  ),
                  label: note.label,
                  clue: note.clue,
                  content: note.content,
                  verseCellIndex: note.verseCellIndex,
                ),
              )
              .toList(),
          inlineNotes: inlineNotes
              .map(
                (note) => ScriptureInlineNote(
                  offset: (note.offset - leadingWhitespace).clamp(
                    0,
                    trimmedText.length,
                  ),
                  length: note.length,
                ),
              )
              .toList(),
          scriptRuns: List.unmodifiable(
            scriptRuns.map(
              (run) => ScriptureScriptRun(
                offset: (run.offset - leadingWhitespace).clamp(
                  0,
                  trimmedText.length,
                ),
                length: run.length,
                family: run.family,
                reference: run.reference,
              ),
            ),
          ),
          verseCells: verseCells,
          images: List.unmodifiable(images),
          tableRows: List.unmodifiable(
            tableRows.map((row) => List<ScriptureTableCell>.unmodifiable(row)),
          ),
          headingLevel: headingLevel,
          role: lineRole,
          paragraphEnd: paragraphEnd,
        ),
      );
    }
    linehead = null;
    text.clear();
    verseCells = [];
    images.clear();
    tableRows = [];
    footnotes = [];
    inlineNotes = [];
    scriptRuns.clear();
    headingLevel = emittedLine ? 0 : pendingHeadingLevel;
    lineRole = emittedLine ? ScriptureLineRole.regular : pendingRole;
    paragraphEnd = emittedLine ? false : pendingParagraphEnd;
    if (continuesInlineNotes) {
      text.write('（');
      activeCell?.write('（');
      for (var i = 0; i < activeInlineNotes.length; i++) {
        activeInlineNotes[i] = 0;
      }
    }
  }

  void appendText(String value) {
    text.write(value);
    activeCell?.write(value);
  }

  String tableCellText(html_dom.Node node) {
    if (node is html_dom.Text) return node.data;
    if (node is! html_dom.Element) return '';
    if (node.classes.contains('lb') || node.classes.contains('lineInfo')) {
      return '';
    }
    if (node.localName == 'br') return '\n';
    final children = node.nodes.map(tableCellText).join();
    return const {'p', 'div'}.contains(node.localName)
        ? '$children\n'
        : children;
  }

  bool hasFollowingParagraph(html_dom.Element element) {
    final siblings = element.parent?.nodes;
    if (siblings == null) return false;
    final index = siblings.indexWhere((sibling) => identical(sibling, element));
    if (index < 0) return false;
    for (final sibling in siblings.skip(index + 1)) {
      if (sibling is html_dom.Text && sibling.data.trim().isEmpty) continue;
      return sibling is html_dom.Element && sibling.localName == 'p';
    }
    return false;
  }

  void visit(html_dom.Node node) {
    if (node is html_dom.Element && node.classes.contains('lb')) {
      flushLine();
      final anchorId = node.attributes['id'];
      linehead = anchorId?.replaceFirstMapped(
        _joinedLineheadPattern,
        (match) => '${match.group(1)}_p',
      );
      return;
    }
    if (node is html_dom.Element && node.localName == 'img') {
      final source = node.attributes['src']?.trim() ?? '';
      if (source.isNotEmpty) {
        final uri = Uri.tryParse(source);
        if (uri != null) {
          images.add(
            ScriptureImage(
              source: uri.hasScheme
                  ? source
                  : Uri.parse(
                      'https://cbetaonline.dila.edu.tw/',
                    ).resolveUri(uri).toString(),
              alt: node.attributes['alt']?.trim() ?? '',
            ),
          );
        }
      }
      return;
    }
    if (node is html_dom.Element &&
        (node.classes.contains('bip-table-row') || node.localName == 'tr')) {
      final cells = node.children
          .where(
            (child) =>
                child.classes.contains('bip-table-cell') ||
                child.localName == 'td' ||
                child.localName == 'th',
          )
          .map((cell) {
            final cellText = cell.nodes.map(tableCellText).join().trim();
            final columnSpan =
                int.tryParse(cell.attributes['colspan'] ?? '') ?? 1;
            return ScriptureTableCell(
              text: cellText.replaceAll(_whitespacePattern, ' '),
              columnSpan: columnSpan.clamp(1, 12),
            );
          })
          .toList();
      if (cells.length > 1) {
        if (text.isNotEmpty || images.isNotEmpty || tableRows.isNotEmpty) {
          flushLine();
        }
        tableRows = [cells];
        text.write(cells.map((cell) => cell.text).join('\t'));
        flushLine();
        return;
      }
    }
    if (node is html_dom.Element &&
        node.localName == 'a' &&
        node.classes.contains('noteAnchor')) {
      final href = node.attributes['href'] ?? '';
      final clue = href.replaceFirst(_anchorPrefixPattern, '');
      final addNote = node.classes.contains('add');
      final noteNumber = _noteNumberPattern.firstMatch(href)?.group(1);
      final label = node.classes.contains('star')
          ? '＊'
          : addNote
          ? 'A${_trailingDigitsPattern.firstMatch(clue)?.group(1) ?? ''}'
          : noteNumber == null
          ? null
          : int.tryParse(noteNumber)?.toString();
      if (label != null && clue.isNotEmpty) {
        footnotes.add(
          ScriptureFootnote(
            offset: text.length,
            label: label,
            clue: clue,
            content: footnoteContent[clue] ?? '',
            verseCellIndex: activeVerseCellIndex,
          ),
        );
      }
      return;
    }
    if (node is html_dom.Element &&
        (node.classes.contains('siddam') || node.classes.contains('ranjana'))) {
      // 悉曇/蘭札字是空元素，靠 char 屬性的形似漢字做碼位、
      // 由隨附字體在該碼位換成對應字形。
      final glyph = (node.attributes['char'] ?? '').trim();
      if (glyph.isNotEmpty) {
        final start = text.length;
        appendText(glyph);
        scriptRuns.add(
          ScriptureScriptRun(
            offset: start,
            length: glyph.length,
            family: node.classes.contains('siddam')
                ? ScriptureScriptFamily.siddam
                : ScriptureScriptFamily.ranjana,
            // code 是 CBETA 的悉曇碼位（SD-A5A9）；先存進索引的引用池,
            // 日後要按碼位或羅馬转寫檢索時不必重建索引。
            reference: (node.attributes['code'] ?? '').trim(),
          ),
        );
      }
      return;
    }
    if (node is html_dom.Text) {
      appendText(node.data);
      return;
    }
    if (node is html_dom.Element && node.localName == 'br') {
      appendText('\n');
      return;
    }
    if (node is html_dom.Element &&
        (node.classes.contains('inline-note') ||
            node.classes.contains('doube-line-note'))) {
      activeInlineNotes.add(text.length);
      appendText('（');
      for (final child in node.nodes) {
        visit(child);
      }
      appendText('）');
      final start = activeInlineNotes.removeLast();
      inlineNotes.add(
        ScriptureInlineNote(offset: start, length: text.length - start),
      );
      return;
    }
    if (node is html_dom.Element && node.classes.contains('lg-row')) {
      if (text.isNotEmpty || images.isNotEmpty || tableRows.isNotEmpty) {
        flushLine();
      }
      verseCells = [];
      final cells = node.children
          .where((child) => child.classes.contains('lg-cell'))
          .toList();
      for (var cellIndex = 0; cellIndex < cells.length; cellIndex++) {
        final cell = cells[cellIndex];
        final cellText = StringBuffer();
        activeCell = cellText;
        activeVerseCellIndex = cellIndex;
        for (final child in cell.nodes) {
          visit(child);
        }
        verseCells.add(cellText.toString().trim());
      }
      activeCell = null;
      activeVerseCellIndex = null;
      flushLine();
      return;
    }
    final isBlock = node is html_dom.Element && node.localName == 'p';
    final isVolumeTitle = isBlock && node.classes.contains('juan');
    final isByline = isBlock && node.classes.contains('byline');
    final isStyledLine = isVolumeTitle || isByline;
    final isHeading =
        isBlock &&
        (node.classes.contains('head') ||
            node.attributes.containsKey('data-head-level'));
    if ((isHeading || isStyledLine) && text.isNotEmpty) flushLine();
    if (isVolumeTitle) {
      lineRole = ScriptureLineRole.volumeTitle;
      // 卷題在網頁模式下是正文裡的次級標題，不再上移到閱讀器頁首。
      headingLevel = 2;
    }
    if (isByline) lineRole = ScriptureLineRole.byline;
    if (isHeading) {
      headingLevel =
          int.tryParse(node.attributes['data-head-level'] ?? '') ?? 1;
      headingLevel = headingLevel.clamp(1, 6);
    }
    if (isBlock && text.isNotEmpty && !text.toString().endsWith('\n')) {
      appendText('\n');
    }
    for (final child in node.nodes) {
      visit(child);
    }
    if (isBlock && text.isNotEmpty && !text.toString().endsWith('\n')) {
      appendText('\n');
    }
    if (isBlock &&
        (text.isNotEmpty || images.isNotEmpty || tableRows.isNotEmpty)) {
      paragraphEnd = hasFollowingParagraph(node);
      flushLine();
    }
    if (isHeading || isStyledLine) flushLine();
  }

  for (final child in root.nodes) {
    visit(child);
  }
  flushLine();
  final seenVolumeTitles = <String>{};
  var enteredBody = false;
  return lines.map((line) {
    if (line.role != ScriptureLineRole.volumeTitle) {
      // 卷首標題前的經號等行（如「No. 1135」）不算正文，
      // 否則真正的卷首標題會被誤判成尾題。
      if (seenVolumeTitles.isNotEmpty &&
          line.role != ScriptureLineRole.byline &&
          line.text.trim().isNotEmpty) {
        enteredBody = true;
      }
      return line;
    }
    final normalizedTitle = line.text
        .replaceAll(_whitespacePattern, '')
        .replaceAll(_bracketNumberPattern, '');
    // 正文开始后再出现的卷名是卷末尾题：留在原位，仍套用卷題樣式
    // （置中、變色），但不會被當成卷名 metadata，行號標記也不顯示，
    // 否則其校勘標號會排到卷首標號之前。
    if (enteredBody || !seenVolumeTitles.add(normalizedTitle)) {
      return ScriptureLine(
        text: line.text,
        linehead: line.linehead,
        footnotes: line.footnotes,
        inlineNotes: line.inlineNotes,
        scriptRuns: line.scriptRuns,
        headingLevel: line.headingLevel,
        role: ScriptureLineRole.volumeTailTitle,
        paragraphEnd: line.paragraphEnd,
      );
    }
    return line;
  }).toList();
}
