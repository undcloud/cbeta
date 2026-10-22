import 'package:html/dom.dart' as html_dom;
import 'package:html/parser.dart' show parseFragment;

import 'models.dart';

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
        note.id: note.text.trim().replaceAll(RegExp(r'\s+'), ' '),
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

  void flushLine() {
    if (linehead != null ||
        text.isNotEmpty ||
        images.isNotEmpty ||
        tableRows.isNotEmpty) {
      final rawText = text.toString();
      final trimmedText = rawText
          .replaceFirst(RegExp(r'^[ \t]+'), '')
          .replaceFirst(RegExp(r'[ \t]+$'), '');
      final leadingWhitespace =
          rawText.length - rawText.replaceFirst(RegExp(r'^[ \t]+'), '').length;
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
      linehead = node.attributes['id'];
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
              text: cellText.replaceAll(RegExp(r'\s+'), ' '),
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
      final clue = href.replaceFirst(RegExp(r'^#'), '');
      final addNote = node.classes.contains('add');
      final noteNumber = RegExp(r'n\d+(\d{3})$').firstMatch(href)?.group(1);
      final label = addNote
          ? 'A${RegExp(r'(\d+)$').firstMatch(clue)?.group(1) ?? ''}'
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
      final start = text.length;
      appendText('（');
      for (final child in node.nodes) {
        visit(child);
      }
      appendText('）');
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
  return lines.map((line) {
    if (line.role != ScriptureLineRole.volumeTitle) return line;
    final normalizedTitle = line.text
        .replaceAll(RegExp(r'\s+'), '')
        .replaceAll(RegExp(r'\[\d+\]'), '');
    if (seenVolumeTitles.add(normalizedTitle)) return line;
    // 重複出現的卷名（通常是卷末的經題）仍保留文字，
    // 讓搜尋命中可以定位與高亮，只是不再顯示行首標記。
    return ScriptureLine(
      text: line.text,
      linehead: line.linehead,
      footnotes: line.footnotes,
      inlineNotes: line.inlineNotes,
      headingLevel: line.headingLevel,
      role: ScriptureLineRole.navigationAnchor,
    );
  }).toList();
}
