import 'package:flutter/material.dart' hide Text;
import 'package:flutter/gestures.dart';
import '../scripture/models.dart';
import '../scripture/parser.dart';
import '../scripture/reader_blocks.dart';
import '../scripture/source_text.dart';
import '../search/conversion.dart';
import '../settings/display_settings.dart';
import '../widgets/display_text.dart';

TextStyle scriptureTextStyle(ScriptureDisplaySettings settings) {
  final fallbackFamilies = switch (settings.fontFamily) {
    'sans' => const [
      'Noto Sans CJK TC',
      'PingFang TC',
      'CBETA Supplement',
      'sans-serif',
    ],
    'kai' => const ['DFKai-SB', 'BiauKai', 'CBETA Supplement', 'serif'],
    'system' => const ['system-ui', 'CBETA Supplement', 'sans-serif'],
    _ => const ['Noto Serif CJK TC', 'Songti SC', 'CBETA Supplement', 'serif'],
  };
  return TextStyle(
    fontFamily: settings.fontFamilyName,
    fontFamilyFallback: fallbackFamilies,
    fontSize: settings.fontSize.toDouble(),
    height: settings.lineHeight,
    letterSpacing: 0.02 * settings.fontSize,
    color: settings.textColor,
  );
}

/// 經文內容在畫面上的純文字載荷，以及每一行在其中的起始位移。
///
/// 這個 layout 必須與 `interactivePassageText` 使用完全相同的位移計算，
/// 否則「卷內搜尋」的高亮與捲動會偏移。
class ScriptureTextLayout {
  const ScriptureTextLayout({
    required this.text,
    required this.lineStarts,
    required this.lineSourceStarts,
  });

  final String text;
  final List<int> lineStarts;
  final List<int> lineSourceStarts;
}

int _scriptureVisibleContentLength(
  ScriptureLine line, {
  required bool showCollation,
}) =>
    line.text.length +
    (showCollation
        ? line.footnotes.fold<int>(
            0,
            (length, note) => length + note.label.length + 2,
          )
        : 0);

/// 這些行在 layout 中會自帶換行，接在其後的偈頌段不需要再補換行。
bool _lineEndsWithExplicitNewline(ScriptureLine line) =>
    line.text.endsWith('\n') ||
    line.verseCells.isNotEmpty ||
    line.tableRows.isNotEmpty ||
    (line.images.isNotEmpty && line.text.isEmpty);

/// 判斷是否為 CBETA 的經號行，例如 `No. 102 [No. 99(33-34)]`。
bool _isCanonNumberLine(String text) {
  final trimmed = text.trim();
  if (!trimmed.startsWith('No.')) return false;
  return RegExp(r'^No\.[A-Za-z0-9\s\[\]\(\),.\-–—]*$').hasMatch(trimmed);
}

/// 取得此卷正文的第一個行號；標題／譯者沒有行號時用來產生引文。
String? firstScriptureLinehead(List<ScriptureLine> lines) {
  for (final line in lines) {
    final linehead = line.linehead;
    if (linehead != null && linehead.isNotEmpty) return linehead;
  }
  return null;
}

/// 依整卷 layout 位移找出所在行號；位移落在卷題等前置文字時退回 `fallback`。
String? scriptureLineheadAtLayoutOffset(
  ScriptureTextLayout layout,
  List<ScriptureLine> lines,
  String? fallback,
  int offset,
) {
  final starts = layout.lineStarts;
  if (starts.isEmpty || starts.length != lines.length) {
    return fallback ?? firstScriptureLinehead(lines);
  }
  String? current = fallback;
  for (var i = 0; i < lines.length; i++) {
    if (starts[i] > offset) break;
    if (lines[i].linehead != null) current = lines[i].linehead;
    final lineEnd = i + 1 < starts.length ? starts[i + 1] : layout.text.length;
    if (offset <= lineEnd) return current;
  }
  return current;
}

const headerFootnoteStyle = TextStyle(
  color: Color(0xFF8B6B2F),
  fontSize: 13,
  decoration: TextDecoration.underline,
);

/// 表格與純圖片行在 `SelectableText` 中是以 `WidgetSpan` 呈現，
/// 每個 WidgetSpan 在純文字中只佔用 1 個 placeholder 字元。
bool _isWidgetOnlyScriptureLine(ScriptureLine line) =>
    line.tableRows.isNotEmpty || (line.images.isNotEmpty && line.text.isEmpty);

/// 偈頌每一格在畫面上的文字（含校勘標記）。
///
/// 這個結果同時供 layout 位移計算與實際渲染使用，兩者必須完全一致，
/// 否則選取、捲動與搜尋高亮都會偏移。
List<String> _verseCellRenderedTexts(
  ScriptureLine line, {
  required bool showCollation,
}) {
  final rendered = <String>[];
  var cellStart = 0;
  for (final cell in line.verseCells) {
    final cellEnd = cellStart + cell.length;
    final buffer = StringBuffer();
    var cursor = 0;
    for (final note in line.footnotes) {
      if (note.offset < cellStart || note.offset > cellEnd) continue;
      final local = (note.offset - cellStart).clamp(cursor, cell.length);
      buffer.write(cell.substring(cursor, local));
      if (showCollation) {
        buffer.write('[${note.label}]');
      }
      cursor = local;
    }
    buffer.write(cell.substring(cursor));
    rendered.add(buffer.toString());
    cellStart = cellEnd;
  }
  return rendered;
}

/// 行首標記（`[0001a01] `）；`buildScriptureTextLayout` 與分塊渲染共用。
String _scriptureLineBeginningPrefix(
  ScriptureLine line,
  bool showLineBeginnings,
) =>
    showLineBeginnings &&
        line.linehead != null &&
        line.role != ScriptureLineRole.navigationAnchor
    ? '[${line.linehead!.split('_p').last}] '
    : '';

/// 每個閱讀區塊第一個字元在整卷 layout 純文字中的起始位移。
///
/// `lineStarts` 記錄在行首標記之後，偈頌段首的補換行也在區塊內，
/// 因此要把它們扣回去，區塊才與整卷 layout 逐字對齊。
List<int> scriptureBlockOffsetBases(
  List<ScriptureReaderBlock> blocks,
  List<ScriptureLine> lines,
  ScriptureTextLayout layout,
  bool showLineBeginnings,
) {
  final bases = <int>[];
  for (final block in blocks) {
    final start = block.startLine;
    var base = layout.lineStarts[start];
    base -= _scriptureLineBeginningPrefix(
      lines[start],
      showLineBeginnings,
    ).length;
    if (start > 0 &&
        lines[start].verseCells.isNotEmpty &&
        lines[start - 1].verseCells.isEmpty &&
        !_lineEndsWithExplicitNewline(lines[start - 1])) {
      base -= 1;
    }
    bases.add(base);
  }
  return bases;
}

ScriptureTextLayout buildScriptureTextLayout(
  List<ScriptureLine> lines, {
  required bool showLineBeginnings,
  required bool showCollation,
}) {
  final buffer = StringBuffer();
  final lineStarts = <int>[];
  final lineSourceStarts = <int>[];
  var offset = 0;
  var sourceOffset = 0;
  for (var lineIndex = 0; lineIndex < lines.length; lineIndex++) {
    final line = lines[lineIndex];
    final isVerseBlockStart =
        line.verseCells.isNotEmpty &&
        lineIndex > 0 &&
        lines[lineIndex - 1].verseCells.isEmpty;
    final isVerseBlockEnd =
        line.verseCells.isNotEmpty &&
        lineIndex + 1 < lines.length &&
        lines[lineIndex + 1].verseCells.isEmpty;
    if (isVerseBlockStart &&
        !_lineEndsWithExplicitNewline(lines[lineIndex - 1])) {
      // 偈頌段落前只需要一個換行；前一行若已自帶換行就不再重複。
      buffer.write('\n');
      offset += 1;
    }
    final prefix = _scriptureLineBeginningPrefix(line, showLineBeginnings);
    if (prefix.isNotEmpty) {
      buffer.write(prefix);
      offset += prefix.length;
    }
    lineStarts.add(offset);
    lineSourceStarts.add(sourceOffset);
    if (line.tableRows.isNotEmpty) {
      // WidgetSpan placeholder + 換行。
      buffer
        ..write('\uFFFC')
        ..write('\n');
      offset += 2;
    } else if (line.verseCells.isNotEmpty) {
      // 偈頌改以文字呈現，才能逐字選取：
      // 每格前面的間距仍是 WidgetSpan placeholder，格子內容則是真實文字。
      final cellTexts = _verseCellRenderedTexts(
        line,
        showCollation: showCollation,
      );
      buffer.write('\uFFFC');
      offset += 1;
      for (var i = 0; i < cellTexts.length; i++) {
        if (i > 0) {
          buffer.write('\uFFFC');
          offset += 1;
        }
        buffer.write(cellTexts[i]);
        offset += cellTexts[i].length;
      }
      buffer.write('\n');
      offset += 1;
      if (isVerseBlockEnd) {
        // 偈頌段後留一空行，與後段分開。
        buffer.write('\n');
        offset += 1;
      }
    } else if (line.images.isNotEmpty) {
      for (var i = 0; i < line.images.length; i++) {
        buffer.write('\uFFFC');
        offset += 1;
      }
      if (line.text.isNotEmpty) {
        final content = visibleScriptureLine(
          line,
          showLineBeginnings: false,
          showCollation: showCollation,
        );
        buffer.write(content);
        offset += content.length;
      } else {
        buffer.write('\n');
        offset += 1;
      }
    } else {
      final content = visibleScriptureLine(
        line,
        showLineBeginnings: false,
        showCollation: showCollation,
      );
      buffer.write(content);
      offset += content.length;
    }
    sourceOffset += scriptureSourceAdvance(line);
  }
  return ScriptureTextLayout(
    text: buffer.toString(),
    lineStarts: lineStarts,
    lineSourceStarts: lineSourceStarts,
  );
}

/// 把原始經文位移轉成畫面純文字位移（含校勘標記與行首標記）。
int layoutEditableOffsetForSource(
  ScriptureTextLayout layout,
  List<ScriptureLine> lines,
  int sourceOffset, {
  required bool showCollation,
}) {
  if (lines.isEmpty) return 0;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final sourceStart = layout.lineSourceStarts[i];
    final sourceEnd = sourceStart + line.text.length;
    if (sourceOffset <= sourceEnd || i == lines.length - 1) {
      final inLine = (sourceOffset - sourceStart).clamp(0, line.text.length);
      if (line.verseCells.isNotEmpty) {
        final renderedCells = _verseCellRenderedTexts(
          line,
          showCollation: showCollation,
        );
        var rendered = layout.lineStarts[i] + 1; // 行首間距 placeholder
        var consumed = 0;
        for (var c = 0; c < line.verseCells.length; c++) {
          if (c > 0) rendered += 1; // 格與格之間的 placeholder
          final cellLength = line.verseCells[c].length;
          if (inLine <= consumed + cellLength) {
            final markersInCell = showCollation
                ? line.footnotes
                      .where(
                        (note) =>
                            note.offset >= consumed && note.offset <= inLine,
                      )
                      .fold<int>(
                        0,
                        (length, note) => length + note.label.length + 2,
                      )
                : 0;
            return rendered + (inLine - consumed) + markersInCell;
          }
          rendered += renderedCells[c].length;
          consumed += cellLength;
        }
        return rendered;
      }
      // WidgetSpan 內的文字無法用純文字位移定位，統一指向該行開頭。
      if (_isWidgetOnlyScriptureLine(line)) {
        return layout.lineStarts[i];
      }
      final markersBefore = showCollation
          ? line.footnotes
                .where((note) => note.offset <= inLine)
                .fold<int>(0, (length, note) => length + note.label.length + 2)
          : 0;
      final imageOffset = line.images.isEmpty ? 0 : line.images.length;
      return layout.lineStarts[i] + imageOffset + inLine + markersBefore;
    }
  }
  return layout.text.length;
}

/// 同一行號可能命中多筆（線上搜尋會回傳重疊的 kwic），
/// 以「相同行號中的第幾筆」區分，才能跳到正確位置。
int hitOccurrenceAtIndex(List<ScripturePassage> hits, int index) {
  if (index <= 0 || index >= hits.length) return 0;
  final target = hits[index];
  var occurrence = 0;
  for (var i = 0; i < index; i++) {
    final other = hits[i];
    if (other.work == target.work &&
        other.juan == target.juan &&
        other.linehead == target.linehead) {
      occurrence += 1;
    }
  }
  return occurrence;
}

/// 依整卷位移或行號計算畫面純文字中的命中位移。
///
/// 離線掃描與書籤帶有整卷來源位移時先驗證 snippet，命中就直接換算；
/// 線上索引則用逐行行號，找不到時才退回段落錨點搭配 kwic 比對。
({int offset, int lineStart, bool inHeader, int? sourceOffset, String snippet})
resolveSearchTargetOffset(
  ScriptureTextLayout layout,
  List<ScriptureLine> bodyLines,
  List<ScriptureLine> headerLines,
  ScripturePassage passage,
  String query,
  int occurrence,
) {
  const empty = (
    offset: 0,
    lineStart: 0,
    inHeader: false,
    sourceOffset: null,
    snippet: '',
  );
  final headerAdvance = headerLines.fold<int>(
    0,
    (sum, line) => sum + scriptureSourceAdvance(line),
  );
  final source = buildScriptureSearchSource(bodyLines);
  final storedOffset = passage.sourceOffset;
  if (storedOffset != null) {
    final located = _locateSnippetOffset(
      source,
      storedOffset - headerAdvance,
      passage.snippet,
    );
    if (located != null) {
      final layoutOffset = layoutEditableOffsetForSource(
        layout,
        bodyLines,
        located,
        showCollation: scriptureDisplaySettings.showCollation,
      );
      return (
        offset: layoutOffset,
        lineStart: layoutLineStartForOffset(layout, layoutOffset),
        inHeader: false,
        sourceOffset: located + headerAdvance,
        snippet: passage.snippet.isNotEmpty
            ? passage.snippet
            : _lineSnippet(source, located),
      );
    }
  }

  final linehead = passage.linehead;
  if (linehead == null) return empty;
  if (headerLines.any((line) => line.linehead == linehead)) {
    return (
      offset: layout.text.length,
      lineStart: 0,
      inHeader: true,
      sourceOffset: null,
      snippet: '',
    );
  }
  final index = bodyLines.indexWhere((line) => line.linehead == linehead);
  if (index < 0) {
    // 離線壓縮檔只保留段落級錨點（如 0154c14），線上搜尋卻是逐行行號
    // （如 0154c20）；改以目標前一個錨點搭配 kwic 上下文定位。
    final anchored = _resolveArchiveAnchorTarget(
      layout,
      bodyLines,
      passage,
      query,
    );
    if (anchored != null) {
      final layoutOffset = layoutEditableOffsetForSource(
        layout,
        bodyLines,
        anchored,
        showCollation: scriptureDisplaySettings.showCollation,
      );
      return (
        offset: layoutOffset,
        lineStart: layoutLineStartForOffset(layout, layoutOffset),
        inHeader: false,
        sourceOffset: anchored + headerAdvance,
        snippet: passage.snippet,
      );
    }
    return empty;
  }
  final lineStart = layout.lineStarts[index];
  final lineSourceStart = layout.lineSourceStarts[index];
  final lineText = bodyLines[index].text;
  if (query.isEmpty) {
    return (
      offset: lineStart,
      lineStart: lineStart,
      inHeader: false,
      sourceOffset: lineSourceStart + headerAdvance,
      snippet: _lineSnippet(lineText, 0),
    );
  }
  final lowerLine = lineText.toLowerCase();
  for (final form in _queryForms(query)) {
    final lowerForm = form.toLowerCase();
    var searchFrom = 0;
    var found = 0;
    while (searchFrom < lowerLine.length) {
      final hit = lowerLine.indexOf(lowerForm, searchFrom);
      if (hit < 0) break;
      if (found == occurrence) {
        final bodyOffset = lineSourceStart + hit;
        final layoutOffset = layoutEditableOffsetForSource(
          layout,
          bodyLines,
          bodyOffset,
          showCollation: scriptureDisplaySettings.showCollation,
        );
        return (
          offset: layoutOffset,
          lineStart: lineStart,
          inHeader: false,
          sourceOffset: bodyOffset + headerAdvance,
          snippet: lineText.substring(hit, hit + form.length),
        );
      }
      found += 1;
      searchFrom = hit + form.length;
    }
  }
  return (
    offset: lineStart,
    lineStart: lineStart,
    inHeader: false,
    sourceOffset: lineSourceStart + headerAdvance,
    snippet: _lineSnippet(lineText, 0),
  );
}

List<String> _queryForms(String query) {
  final traditional = SimplifiedTraditionalConverter.toTraditionalDisplay(
    query,
  );
  return traditional == query ? [query] : [query, traditional];
}

String _lineSnippet(String text, int offset) {
  if (text.isEmpty) return '';
  final start = offset.clamp(0, text.length);
  final end = (start + 24).clamp(start, text.length);
  return text.substring(start, end);
}

/// 在來源文字中驗證位移：優先用原位移，snippet 對不上時找最近的相同字串。
int? _locateSnippetOffset(String source, int? offset, String snippet) {
  final lowerSource = source.toLowerCase();
  final lowerSnippet = snippet.toLowerCase();
  if (snippet.isEmpty) {
    if (offset == null) return null;
    return offset >= 0 && offset <= source.length ? offset : null;
  }
  if (offset != null &&
      offset >= 0 &&
      offset + lowerSnippet.length <= lowerSource.length &&
      lowerSource.startsWith(lowerSnippet, offset)) {
    return offset;
  }
  int? nearest;
  var nearestDistance = 1 << 30;
  void consider(int hit) {
    if (offset == null) {
      nearest ??= hit;
      return;
    }
    final distance = (hit - offset).abs();
    if (distance < nearestDistance) {
      nearest = hit;
      nearestDistance = distance;
    }
  }

  if (offset != null) {
    final windowStart = (offset - 600).clamp(0, lowerSource.length);
    final windowEnd = (offset + 600 + lowerSnippet.length).clamp(
      0,
      lowerSource.length,
    );
    var from = windowStart;
    while (from < windowEnd) {
      final hit = lowerSource.indexOf(lowerSnippet, from);
      if (hit < 0 || hit >= windowEnd) break;
      consider(hit);
      from = hit + lowerSnippet.length;
    }
    if (nearest != null) return nearest;
  }
  var from = 0;
  while (true) {
    final hit = lowerSource.indexOf(lowerSnippet, from);
    if (hit < 0) break;
    consider(hit);
    from = hit + lowerSnippet.length;
  }
  return nearest;
}

/// 離線／已下載經卷的 HTML 錨點只標到段落開頭，線上搜尋回傳的則是逐行行號。
/// 先在目前卷內找回目標之前的最後一個錨點，再以 kwic 的前文比對
/// 錨點段落內重複出現的關鍵字，取得實際命中的整卷來源位移。
int? _resolveArchiveAnchorTarget(
  ScriptureTextLayout layout,
  List<ScriptureLine> bodyLines,
  ScripturePassage passage,
  String query,
) {
  final linehead = passage.linehead;
  if (linehead == null || bodyLines.isEmpty) return null;
  final split = linehead.lastIndexOf('_p');
  if (split <= 0) return null;
  final prefix = linehead.substring(0, split);
  final target = linehead.substring(split + 2);
  if (target.isEmpty) return null;

  var anchor = -1;
  for (var i = 0; i < bodyLines.length; i++) {
    final head = bodyLines[i].linehead;
    if (head == null || !head.startsWith('${prefix}_p')) continue;
    if (head.substring(prefix.length + 2).compareTo(target) <= 0) {
      anchor = i;
    } else {
      break;
    }
  }
  if (anchor < 0) return null;
  final sourceStart = layout.lineSourceStarts[anchor];
  if (query.isEmpty) return sourceStart;

  // 錨點之後、下一個錨點之前的行都算這段錨點的內容（偈頌行沒有錨點）。
  var spanEndIndex = anchor + 1;
  while (spanEndIndex < bodyLines.length &&
      bodyLines[spanEndIndex].linehead == null) {
    spanEndIndex += 1;
  }
  final source = buildScriptureSearchSource(bodyLines);
  final sourceEnd = spanEndIndex < bodyLines.length
      ? layout.lineSourceStarts[spanEndIndex]
      : source.length;
  if (sourceEnd <= sourceStart) return sourceStart;

  final lowerSource = source.toLowerCase();
  final snippet = passage.text.toLowerCase();
  // 查詢詞可能仍是簡體，經文與 kwic 則是繁體。
  final forms = _queryForms(query);

  for (final form in forms) {
    final lowerForm = form.toLowerCase();
    final snippetIndex = snippet.indexOf(lowerForm);
    int? bestOffset;
    var bestScore = -1;
    var searchFrom = sourceStart;
    while (searchFrom < sourceEnd) {
      final hit = lowerSource.indexOf(lowerForm, searchFrom);
      if (hit < 0 || hit + lowerForm.length > sourceEnd) break;
      var score = 0;
      if (snippetIndex >= 0) {
        while (score < 24 &&
            hit - score - 1 >= sourceStart &&
            snippetIndex - score - 1 >= 0 &&
            source[hit - score - 1] == snippet[snippetIndex - score - 1]) {
          score += 1;
        }
      }
      if (score > bestScore) {
        bestScore = score;
        bestOffset = hit;
      }
      searchFrom = hit + lowerForm.length;
    }
    if (bestOffset == null) continue;
    return bestOffset;
  }
  return sourceStart;
}

/// 找出包含 `offset` 的那一行在畫面純文字中的起點。
int layoutLineStartForOffset(ScriptureTextLayout layout, int offset) {
  var start = 0;
  for (final lineStart in layout.lineStarts) {
    if (lineStart > offset) break;
    start = lineStart;
  }
  return start;
}

/// 關鍵字搜尋（非目前命中）的高亮樣式。
const _globalHighlightStyle = TextStyle(
  backgroundColor: Color(0xFFDDEDE8),
  color: Color(0xFF145D54),
  fontWeight: FontWeight.w700,
);

/// 卷內搜尋／目前命中的高亮樣式。
const _localHighlightStyle = TextStyle(
  backgroundColor: Color(0xFFFFE08A),
  color: Color(0xFF2C1810),
  fontWeight: FontWeight.w700,
);

/// 找出純文字中所有 `query` 的位移範圍（可跨行、跨校勘標記）。
List<({int start, int end})> matchRangesIn(
  String text,
  String query, {
  int minStart = 0,
}) {
  if (query.isEmpty || text.isEmpty) return const [];
  final lowerText = text.toLowerCase();
  final lowerQuery = query.toLowerCase();
  final ranges = <({int start, int end})>[];
  var from = minStart.clamp(0, text.length);
  while (from < text.length) {
    final index = lowerText.indexOf(lowerQuery, from);
    if (index < 0) break;
    ranges.add((start: index, end: index + query.length));
    from = index + query.length;
  }
  return ranges;
}

TextSpan interactivePassageText(
  BuildContext context,
  ScripturePassage passage,
  String query, {
  required int? startAt,
  required ({int start, int end})? localSearchRange,
  required List<({int start, int end})> queryRanges,
  required List<ScriptureLine> sourceLines,
  required int firstLineIndex,
  required int lineCount,
  required int offsetBase,
  required int sourceOffsetBase,
  required double width,
  required List<TapGestureRecognizer> recognizers,
}) {
  for (final recognizer in recognizers) {
    recognizer.dispose();
  }
  recognizers.clear();
  final settings = scriptureDisplaySettings;
  final children = <InlineSpan>[];
  var offset = offsetBase;
  var sourceOffset = sourceOffsetBase;

  /// 依「畫面純文字位移」的命中範圍切割片段。
  ///
  /// 使用範圍而不是在單一片段內 indexOf，才能高亮跨行或跨校勘標記的命中
  /// （例如「四大五｜蘊遷變」）。文字片段只負責渲染。
  TextSpan highlighted(String value, int start, int sourceStart) {
    final local = localSearchRange;
    final ranges = local == null
        ? queryRanges
        : <({int start, int end})>[local];
    if (ranges.isEmpty || value.isEmpty) return TextSpan(text: value);
    final chunkStart = start;
    final chunkEnd = start + value.length;
    var lo = 0;
    var hi = ranges.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (ranges[mid].end <= chunkStart) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final style = local == null ? _globalHighlightStyle : _localHighlightStyle;
    final spans = <TextSpan>[];
    var cursor = chunkStart;
    for (var i = lo; i < ranges.length; i++) {
      final range = ranges[i];
      if (range.start >= chunkEnd) break;
      final from = range.start.clamp(chunkStart, chunkEnd);
      final to = range.end.clamp(chunkStart, chunkEnd);
      if (to <= from || to <= cursor) continue;
      if (from > cursor) {
        spans.add(
          TextSpan(
            text: value.substring(cursor - chunkStart, from - chunkStart),
          ),
        );
      }
      spans.add(
        TextSpan(
          text: value.substring(from - chunkStart, to - chunkStart),
          style: style,
        ),
      );
      cursor = to;
    }
    if (cursor < chunkEnd) {
      spans.add(TextSpan(text: value.substring(cursor - chunkStart)));
    }
    return TextSpan(children: spans);
  }

  /// WidgetSpan（偈頌、表格）內的文字不在 SelectableText 的
  /// 純文字位移系統中，只能改用字串比對來高亮。
  TextSpan highlightedWidget(String value, int lineOffset, int lineAdvance) {
    final range = localSearchRange;
    if (range != null) {
      if (range.start < lineOffset || range.start >= lineOffset + lineAdvance) {
        return TextSpan(text: value);
      }
    } else if (startAt != null && lineOffset < startAt) {
      return TextSpan(text: value);
    }
    return _highlightAllMatches(value, query, active: localSearchRange != null);
  }

  List<InlineSpan> spansForRange(
    String text,
    int from,
    int to,
    int visibleStart,
    int sourceLineStart,
    List<ScriptureInlineNote> inlineNotes,
    List<ScriptureScriptRun> scriptRuns, {
    TextSpan Function(String value)? highlightSpan,
  }) {
    TextSpan buildSpan(String value, int start, int sourceStart) =>
        highlightSpan == null
        ? highlighted(value, start, sourceStart)
        : highlightSpan(value);

    /// 依悉曇/蘭札字體區間切段，區間外包一層 fontFamily；
    /// 切段不增減字數，選取與高亮位移不受影響。
    List<InlineSpan> fontSplit(int segFrom, int segTo, int visibleBase) {
      if (scriptRuns.isEmpty || segTo <= segFrom) {
        return [
          buildSpan(
            text.substring(segFrom, segTo),
            visibleBase,
            sourceLineStart + segFrom,
          ),
        ];
      }
      final result = <InlineSpan>[];
      void plain(int start, int end) {
        if (end <= start) return;
        result.add(
          buildSpan(
            text.substring(start, end),
            visibleBase + (start - segFrom),
            sourceLineStart + start,
          ),
        );
      }

      var cursor = segFrom;
      for (final run in scriptRuns) {
        final runStart = run.offset.clamp(cursor, segTo);
        final runEnd = (run.offset + run.length).clamp(runStart, segTo);
        plain(cursor, runStart);
        if (runEnd > runStart) {
          result.add(
            TextSpan(
              style: TextStyle(
                fontFamily: run.family == ScriptureScriptFamily.siddam
                    ? 'CBETA Siddam'
                    : 'CBETA Ranjana',
              ),
              children: [
                buildSpan(
                  text.substring(runStart, runEnd),
                  visibleBase + (runStart - segFrom),
                  sourceLineStart + runStart,
                ),
              ],
            ),
          );
        }
        cursor = runEnd;
      }
      plain(cursor, segTo);
      return result;
    }

    final spans = <InlineSpan>[];
    var cursor = from;
    for (final note in inlineNotes) {
      final noteStart = note.offset;
      final noteEnd = note.offset + note.length;
      if (noteEnd <= cursor || noteStart >= to) continue;
      final cut = noteStart.clamp(cursor, to);
      if (cut > cursor) {
        spans.addAll(fontSplit(cursor, cut, visibleStart + (cursor - from)));
      }
      final noteFrom = noteStart.clamp(cursor, to);
      final noteTo = noteEnd.clamp(noteFrom, to);
      if (noteTo > noteFrom) {
        spans.add(
          TextSpan(
            style: TextStyle(
              color: const Color(0xFF9C8B78),
              fontSize: settings.fontSize * 0.85,
            ),
            children: fontSplit(
              noteFrom,
              noteTo,
              visibleStart + (noteFrom - from),
            ),
          ),
        );
      }
      cursor = noteTo;
    }
    if (cursor < to) {
      spans.addAll(fontSplit(cursor, to, visibleStart + (cursor - from)));
    }
    return spans;
  }

  List<InlineSpan> contentSpans(
    ScriptureLine line,
    int lineStart,
    int sourceLineStart, {
    TextSpan Function(String value)? highlightSpan,
  }) {
    final spans = <InlineSpan>[];
    var contentOffset = 0;
    int visibleOffset(int sourceInLine) {
      final markersBefore = settings.showCollation
          ? line.footnotes
                .where((note) => note.offset <= sourceInLine)
                .fold<int>(0, (length, note) => length + note.label.length + 2)
          : 0;
      return lineStart + sourceInLine + markersBefore;
    }

    for (final note in line.footnotes) {
      final noteOffset = note.offset.clamp(contentOffset, line.text.length);
      spans.addAll(
        spansForRange(
          line.text,
          contentOffset,
          noteOffset,
          visibleOffset(contentOffset),
          sourceLineStart,
          line.inlineNotes,
          line.scriptRuns,
          highlightSpan: highlightSpan,
        ),
      );
      if (settings.showCollation) {
        final marker = '[${note.label}]';
        if (note.content.isNotEmpty) {
          final recognizer = TapGestureRecognizer()
            ..onTap = () => showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                title: Text(note.label.startsWith('A') ? 'CBETA 修訂註解' : '校勘記'),
                content: DisplaySelectableText(note.content),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('關閉'),
                  ),
                ],
              ),
            );
          recognizers.add(recognizer);
          spans.add(
            TextSpan(
              text: marker,
              style: const TextStyle(
                color: Color(0xFF8B6B2F),
                fontSize: 13,
                decoration: TextDecoration.underline,
              ),
              recognizer: recognizer,
            ),
          );
        } else {
          spans.add(TextSpan(text: marker));
        }
      }
      contentOffset = noteOffset;
    }
    spans.addAll(
      spansForRange(
        line.text,
        contentOffset,
        line.text.length,
        visibleOffset(contentOffset),
        sourceLineStart,
        line.inlineNotes,
        line.scriptRuns,
        highlightSpan: highlightSpan,
      ),
    );
    return spans;
  }

  int visibleLineLength(ScriptureLine line) => _scriptureVisibleContentLength(
    line,
    showCollation: settings.showCollation,
  );

  TextStyle headingStyle(int level) {
    final scale = switch (level) {
      1 => 1.35,
      2 => 1.25,
      3 => 1.16,
      4 => 1.1,
      5 => 1.05,
      _ => 1.0,
    };
    return scriptureTextStyle(settings).copyWith(
      fontSize: settings.fontSize * scale,
      fontWeight: level <= 2 ? FontWeight.w700 : FontWeight.w600,
      letterSpacing: 0,
    );
  }

  void addContent(ScriptureLine line) {
    final content = contentSpans(line, offset, sourceOffset);
    if (line.headingLevel > 0) {
      children.add(
        TextSpan(style: headingStyle(line.headingLevel), children: content),
      );
    } else {
      children.addAll(content);
    }
    offset = offset + visibleLineLength(line);
    sourceOffset += scriptureSourceAdvance(line);
  }

  final endLineIndex = firstLineIndex + lineCount;
  for (
    var lineIndex = firstLineIndex;
    lineIndex < endLineIndex && lineIndex < sourceLines.length;
    lineIndex++
  ) {
    final line = sourceLines[lineIndex];
    final isVerseBlockStart =
        line.verseCells.isNotEmpty &&
        lineIndex > 0 &&
        sourceLines[lineIndex - 1].verseCells.isEmpty;
    final isVerseBlockEnd =
        line.verseCells.isNotEmpty &&
        lineIndex + 1 < sourceLines.length &&
        sourceLines[lineIndex + 1].verseCells.isEmpty;
    if (isVerseBlockStart &&
        !_lineEndsWithExplicitNewline(sourceLines[lineIndex - 1])) {
      // 與 `buildScriptureTextLayout` 一致：前一行沒有換行才補一個。
      children.add(const TextSpan(text: '\n'));
      offset += 1;
    }
    if (settings.showLineBeginnings &&
        line.linehead != null &&
        line.role != ScriptureLineRole.navigationAnchor) {
      final marker = '[${line.linehead!.split('_p').last}] ';
      children.add(
        TextSpan(
          text: marker,
          style: const TextStyle(
            color: Color(0xFF9A7A42),
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
      offset += marker.length;
    }
    if (line.tableRows.isNotEmpty) {
      final lineStartOffset = offset;
      children.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: SizedBox(
            width: width,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final row in line.tableRows)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final cell in row)
                        Expanded(
                          flex: cell.columnSpan,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: settings.textColor.withValues(
                                  alpha: 0.25,
                                ),
                              ),
                            ),
                            child: Text.rich(
                              TextSpan(
                                children: [
                                  highlightedWidget(
                                    cell.text,
                                    lineStartOffset,
                                    2,
                                  ),
                                ],
                              ),
                              style: scriptureTextStyle(settings),
                            ),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      );
      // WidgetSpan 在純文字中只佔 1 個 placeholder，再加上換行。
      offset += 1;
      children.add(const TextSpan(text: '\n'));
      offset += 1;
      sourceOffset += scriptureSourceAdvance(line);
    } else if (line.images.isNotEmpty) {
      for (final image in line.images) {
        children.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: SizedBox(
              width: width,
              child: Image.network(
                image.source,
                width: width,
                fit: BoxFit.contain,
                semanticLabel: image.alt.isEmpty ? null : image.alt,
                loadingBuilder: (context, child, progress) => progress == null
                    ? child
                    : SizedBox(
                        height: 180,
                        child: Center(
                          child: CircularProgressIndicator(
                            value: progress.expectedTotalBytes == null
                                ? null
                                : progress.cumulativeBytesLoaded /
                                      progress.expectedTotalBytes!,
                          ),
                        ),
                      ),
                errorBuilder: (context, error, stackTrace) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    '圖片載入失敗${image.alt.isEmpty ? '' : '：${image.alt}'}',
                    style: scriptureTextStyle(settings),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          ),
        );
        // 每個圖片 WidgetSpan 在純文字中佔 1 個 placeholder。
        offset += 1;
      }
      if (line.text.isNotEmpty) {
        addContent(line);
      } else {
        children.add(const TextSpan(text: '\n'));
        offset++;
        sourceOffset += scriptureSourceAdvance(line);
      }
    } else if (line.verseCells.isNotEmpty) {
      final verseStyle = scriptureTextStyle(settings);
      final renderedCells = _verseCellRenderedTexts(
        line,
        showCollation: settings.showCollation,
      );
      final spansPerCell = <List<InlineSpan>>[];
      final cellWidths = <double>[];
      var layoutCursor = offset + 1; // 行首間距 placeholder
      var sourceCursor = 0;
      for (var cellIndex = 0; cellIndex < line.verseCells.length; cellIndex++) {
        final cellText = line.verseCells[cellIndex];
        final cellEnd = sourceCursor + cellText.length;
        final cellSpans = contentSpans(
          ScriptureLine(
            text: cellText,
            footnotes: line.footnotes
                .where(
                  (note) =>
                      note.offset >= sourceCursor && note.offset <= cellEnd,
                )
                .map(
                  (note) => ScriptureFootnote(
                    offset: (note.offset - sourceCursor).clamp(
                      0,
                      cellText.length,
                    ),
                    label: note.label,
                    clue: note.clue,
                    content: note.content,
                  ),
                )
                .toList(),
          ),
          layoutCursor,
          0,
        );
        final painter = TextPainter(
          text: TextSpan(style: verseStyle, children: cellSpans),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: 1,
        )..layout();
        cellWidths.add(painter.width);
        painter.dispose();
        spansPerCell.add(cellSpans);
        layoutCursor += renderedCells[cellIndex].length + 1;
        sourceCursor = cellEnd;
      }

      // 以文字呈現每一格，才能逐字選取；格與格之間的間距用不可見的
      // WidgetSpan 補足，維持原本每格等寬置中的外觀。
      // 保留 0.5px 餘裕，避免量測誤差讓整行被擠到下一行。
      var rowWidth = width > 1 ? width - 0.5 : width;
      final hasLinePrefix =
          settings.showLineBeginnings &&
          line.linehead != null &&
          line.role != ScriptureLineRole.navigationAnchor;
      if (hasLinePrefix) {
        final marker = '[${line.linehead!.split('_p').last}] ';
        final markerPainter = TextPainter(
          text: TextSpan(
            text: marker,
            style: verseStyle.copyWith(
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: 1,
        )..layout();
        rowWidth = (rowWidth - markerPainter.width).clamp(0.0, double.infinity);
        markerPainter.dispose();
      }
      final cellCount = spansPerCell.length;
      final slot = cellCount == 0 ? rowWidth : rowWidth / cellCount;
      // 偈字行距加大；仍以同一個字元序列呈現，不影響搜尋錨點。
      final verseLineStyle = TextStyle(height: settings.lineHeight + 0.5);
      var cursorX = 0.0;
      for (var i = 0; i < cellCount; i++) {
        final targetLeft = i * slot + (slot - cellWidths[i]) / 2;
        final pad = (targetLeft - cursorX).clamp(0.0, double.infinity);
        children.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: SizedBox(width: pad, height: 0),
          ),
        );
        children.add(
          TextSpan(style: verseLineStyle, children: spansPerCell[i]),
        );
        cursorX = targetLeft + cellWidths[i];
      }
      offset += 1;
      for (var i = 0; i < renderedCells.length; i++) {
        if (i > 0) offset += 1;
        offset += renderedCells[i].length;
      }
      children.add(const TextSpan(text: '\n'));
      offset += 1;
      if (isVerseBlockEnd) {
        // 與 `buildScriptureTextLayout` 一致：偈頌段後留一空行。
        children.add(const TextSpan(text: '\n'));
        offset += 1;
      }
      sourceOffset += scriptureSourceAdvance(line);
    } else if (_isCanonNumberLine(line.text)) {
      // 經號行（No. ...）只是索引資訊，用較小、較淺的字級顯示。
      final content = contentSpans(line, offset, sourceOffset);
      children.add(
        TextSpan(
          style: TextStyle(
            fontSize: settings.fontSize * 0.72,
            color: settings.isDark
                ? const Color(0xFF8E8171)
                : const Color(0xFF9A8B78),
          ),
          children: content,
        ),
      );
      offset = offset + visibleLineLength(line);
      sourceOffset += scriptureSourceAdvance(line);
    } else {
      addContent(line);
    }
  }
  return TextSpan(children: children);
}

TextSpan highlightedPassageText(String text, String query, {int? startAt}) {
  if (query.isEmpty) return TextSpan(text: text);
  final lowerText = text.toLowerCase();
  final lowerQuery = query.toLowerCase();
  final matches = <int>[];
  var searchFrom = startAt ?? 0;
  while (true) {
    final index = lowerText.indexOf(lowerQuery, searchFrom);
    if (index < 0) break;
    matches.add(index);
    searchFrom = index + lowerQuery.length;
  }
  if (matches.isEmpty) return TextSpan(text: text);
  final spans = <TextSpan>[];
  var cursor = 0;
  for (final matchIndex in matches) {
    if (matchIndex > cursor) {
      spans.add(TextSpan(text: text.substring(cursor, matchIndex)));
    }
    spans.add(
      TextSpan(
        text: text.substring(matchIndex, matchIndex + query.length),
        style: const TextStyle(
          backgroundColor: Color(0xFFDDEDE8),
          color: Color(0xFF145D54),
          fontWeight: FontWeight.w700,
        ),
      ),
    );
    cursor = matchIndex + query.length;
  }
  if (cursor < text.length) {
    spans.add(TextSpan(text: text.substring(cursor)));
  }
  return TextSpan(children: spans);
}

/// 在單一文字片段中高亮所有 `query` 出現的位置。
///
/// 用於 `WidgetSpan`（偈頌、表格）內的文字：這些文字不在
/// `SelectableText` 的純文字位移系統中，只能直接比對字串。
TextSpan _highlightAllMatches(
  String text,
  String query, {
  bool active = false,
}) {
  if (query.isEmpty) return TextSpan(text: text);
  final lowerText = text.toLowerCase();
  final lowerQuery = query.toLowerCase();
  final matches = <int>[];
  var searchFrom = 0;
  while (true) {
    final index = lowerText.indexOf(lowerQuery, searchFrom);
    if (index < 0) break;
    matches.add(index);
    searchFrom = index + lowerQuery.length;
  }
  if (matches.isEmpty) return TextSpan(text: text);
  final spans = <TextSpan>[];
  var cursor = 0;
  for (final matchIndex in matches) {
    if (matchIndex > cursor) {
      spans.add(TextSpan(text: text.substring(cursor, matchIndex)));
    }
    spans.add(
      TextSpan(
        text: text.substring(matchIndex, matchIndex + query.length),
        style: TextStyle(
          backgroundColor: active
              ? const Color(0xFFFFE08A)
              : const Color(0xFFDDEDE8),
          color: active ? const Color(0xFF2C1810) : const Color(0xFF145D54),
          fontWeight: FontWeight.w700,
        ),
      ),
    );
    cursor = matchIndex + query.length;
  }
  if (cursor < text.length) {
    spans.add(TextSpan(text: text.substring(cursor)));
  }
  return TextSpan(children: spans);
}
