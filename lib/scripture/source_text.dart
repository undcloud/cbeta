import 'models.dart';

/// 一行在「整卷來源文字」中佔用的長度。
///
/// 表格、偈頌與純圖片行在 layout 中各自帶一個換行，因此來源文字也要補上
/// 一個換行，離線掃描算出的位移才能和閱讀器的 layout 對齊。
int scriptureSourceAdvance(ScriptureLine line) =>
    line.text.length +
    (line.tableRows.isNotEmpty ||
            line.verseCells.isNotEmpty ||
            (line.images.isNotEmpty && line.text.isEmpty)
        ? 1
        : 0);

/// 與閱讀器 layout 相同行距規則的原始經文文字，用於卷內搜尋與位移換算。
String buildScriptureSearchSource(List<ScriptureLine> lines) {
  final buffer = StringBuffer();
  for (final line in lines) {
    buffer.write(line.text);
    final advance = scriptureSourceAdvance(line);
    for (var i = line.text.length; i < advance; i++) {
      buffer.write('\n');
    }
  }
  return buffer.toString();
}
