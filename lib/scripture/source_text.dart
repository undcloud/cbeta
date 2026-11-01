import 'models.dart';

final _volumeTitleTailPattern = RegExp(r'卷[第]?[〇零一二三四五六七八九十百千兩0-9]+$');

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

({String title, String byline}) localVolumeInfo(List<ScriptureLine> lines) {
  String pick(ScriptureLineRole role) => lines
      .firstWhere(
        (line) => line.role == role && line.text.trim().isNotEmpty,
        orElse: () => const ScriptureLine(text: ''),
      )
      .text
      .trim();
  return (
    title: pick(ScriptureLineRole.volumeTitle),
    byline: pick(ScriptureLineRole.byline),
  );
}

/// 卷題去掉「卷第一」之類尾綴就是作品名；離線索引把它存進標頭，第一階段
/// 不必解析 HTML 也能顯示經名。
String localWorkTitle(List<ScriptureLine> lines) {
  final title = localVolumeInfo(lines).title;
  final stripped = title.replaceFirst(_volumeTitleTailPattern, '').trim();
  return stripped.isEmpty ? title : stripped;
}
