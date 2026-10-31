import 'models.dart';

/// 閱讀頁惰性渲染的最小單位。
///
/// 一個區塊會單獨建成一個 `SelectableText`（表格塊則是純 widget 樹），
/// `ListView.builder` 只構建畫面可見的區塊。
enum ScriptureReaderBlockKind { text, verse, table, image }

class ScriptureReaderBlock {
  const ScriptureReaderBlock({
    required this.kind,
    required this.startLine,
    required this.endLine,
  });

  final ScriptureReaderBlockKind kind;

  /// 區塊涵蓋 `lines` 的起止索引（終點不含）。
  final int startLine;
  final int endLine;

  int get lineCount => endLine - startLine;
}

/// 把整卷切成可惰性渲染的區塊。
///
/// 表格與純圖片行是首幀耗時的來源（每個 `WidgetSpan` 都會被塞進同一個
/// 超長段落裡一起排版），因此各自單獨成塊；純文字與偈頌分別成塊，
/// 並各自受數量預算限制，避免單塊過大。
List<ScriptureReaderBlock> buildScriptureReaderBlocks(
  List<ScriptureLine> lines, {
  int maxTextCharacters = 4000,
  int maxVerseLines = 24,
  int maxTableLines = 12,
}) {
  final blocks = <ScriptureReaderBlock>[];
  var textStart = 0;
  var textCharacters = 0;

  void flushText(int end) {
    if (end <= textStart) return;
    blocks.add(
      ScriptureReaderBlock(
        kind: ScriptureReaderBlockKind.text,
        startLine: textStart,
        endLine: end,
      ),
    );
    textStart = end;
    textCharacters = 0;
  }

  var index = 0;
  while (index < lines.length) {
    final line = lines[index];
    if (line.tableRows.isNotEmpty) {
      flushText(index);
      var end = index;
      while (end < lines.length &&
          lines[end].tableRows.isNotEmpty &&
          end - index < maxTableLines) {
        end++;
      }
      blocks.add(
        ScriptureReaderBlock(
          kind: ScriptureReaderBlockKind.table,
          startLine: index,
          endLine: end,
        ),
      );
      index = end;
      textStart = index;
      continue;
    }
    if (line.images.isNotEmpty && line.text.isEmpty) {
      flushText(index);
      blocks.add(
        ScriptureReaderBlock(
          kind: ScriptureReaderBlockKind.image,
          startLine: index,
          endLine: index + 1,
        ),
      );
      index++;
      textStart = index;
      continue;
    }
    if (line.verseCells.isNotEmpty) {
      flushText(index);
      var end = index;
      while (end < lines.length && lines[end].verseCells.isNotEmpty) {
        end++;
      }
      for (var start = index; start < end; start += maxVerseLines) {
        blocks.add(
          ScriptureReaderBlock(
            kind: ScriptureReaderBlockKind.verse,
            startLine: start,
            endLine: (start + maxVerseLines) < end
                ? (start + maxVerseLines)
                : end,
          ),
        );
      }
      index = end;
      textStart = end;
      continue;
    }
    textCharacters += line.text.length;
    index++;
    if (textCharacters >= maxTextCharacters) flushText(index);
  }
  flushText(lines.length);
  return blocks;
}
