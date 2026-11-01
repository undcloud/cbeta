/// 熱路徑上的正則表達式只構造一次。`new RegExp` 每次都會重新編譯模式,
/// 而離線掃描與結果分組會在同一幀內成千上万次地呼叫這些輔助函式。
final collapseWhitespacePattern = RegExp(r'\s+');
final leadingParentheticalPattern = RegExp(r'^\s*（[^）]*）\s*');
final workIdPattern = RegExp(r'^([A-Z]+\d+)');
final fileWorkIdPattern = RegExp(r'^([A-Z]+)\d+n(\d+[A-Z]?)');
final citationBrPattern = RegExp(r'<br\s*/?>', caseSensitive: false);
final htmlTagPattern = RegExp(r'<[^>]*>');

/// 引文行號解析，形態靠齊 CBReader2X `cbreader.js` 的 `_parser_linehead`：
/// 藏別前綴可多字母（GA040）、`_p` 的底線可省、頁碼可帶字母前綴
/// （卍續／史部的 `ph017`）。這些任一項沒放寬，對應的書就會靜默退回
/// 只有 `(CBETA ...)` 而沒有卷號頁碼的引文。
final citationLineheadPattern = RegExp(
  r'^([A-Z]+\d+)n(\d+[A-Z]?)_?p([a-z]?\d{3,4})([a-z])(\d+)$',
);

/// 引文頁碼／行號的前導零（字母前綴之後）。
final citationPaddingZeroPattern = RegExp(r'^([a-z]?)0+(?=\d)');
