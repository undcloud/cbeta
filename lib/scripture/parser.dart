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
      line.role != ScriptureLineRole.navigationAnchor) {
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

List<ScriptureLine> parseScriptureHtml(String source) {
  final fragment = parseFragment(source);
  final root = fragment.querySelector('#body') ?? fragment;
  final footnoteContent = {
    for (final note in fragment.querySelectorAll('#back .footnote'))
      if (note.id.isNotEmpty)
        note.id: note.text.trim().replaceAll(_whitespacePattern, ' '),
  };
  final lines = <ScriptureLine>[];
  String? linehead;
  var headingLevel = 0;
  var lineRole = ScriptureLineRole.regular;
  final text = StringBuffer();
  StringBuffer? activeCell;
  List<String> verseCells = [];
  final images = <ScriptureImage>[];
  List<List<ScriptureTableCell>> tableRows = [];
  var footnotes = <ScriptureFootnote>[];
  var inlineNotes = <ScriptureInlineNote>[];
  final activeInlineNotes = <int>[];

  void flushLine() {
    // 夾注跨行(lb 在 small 內)時：本行末補上右括號並記錄本段的樣式範圍，
    // 下一行以左括號續接，使每行括號成對、小字範圍不錯位。
    final continuesInlineNotes = activeInlineNotes.isNotEmpty;
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
    if (linehead != null ||
        text.isNotEmpty ||
        images.isNotEmpty ||
        tableRows.isNotEmpty) {
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
          verseCells: verseCells,
          images: List.unmodifiable(images),
          tableRows: List.unmodifiable(
            tableRows.map((row) => List<ScriptureTableCell>.unmodifiable(row)),
          ),
          headingLevel: headingLevel,
          role: lineRole,
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
    headingLevel = 0;
    lineRole = ScriptureLineRole.regular;
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
      final label = addNote
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
      verseCells = [];
      for (final cell in node.children.where(
        (child) => child.classes.contains('lg-cell'),
      )) {
        final cellText = StringBuffer();
        activeCell = cellText;
        for (final child in cell.nodes) {
          visit(child);
        }
        verseCells.add(cellText.toString().trim());
      }
      activeCell = null;
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
    if (isVolumeTitle) lineRole = ScriptureLineRole.volumeTitle;
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
    // 正文开始后再出现的卷名是卷末尾题：按网页模式留在原位显示，
    // 不再上移到标题区（否则其校勘标号会排到卷首标号之前）。
    if (enteredBody || !seenVolumeTitles.add(normalizedTitle)) {
      return ScriptureLine(
        text: line.text,
        linehead: line.linehead,
        footnotes: line.footnotes,
        inlineNotes: line.inlineNotes,
        headingLevel: line.headingLevel,
        role: ScriptureLineRole.navigationAnchor,
      );
    }
    return line;
  }).toList();
}
