/// 熱路徑上的正則表達式只構造一次。`new RegExp` 每次都會重新編譯模式,
/// 而離線掃描與結果分組會在同一幀內成千上万次地呼叫這些輔助函式。
final collapseWhitespacePattern = RegExp(r'\s+');
final leadingParentheticalPattern = RegExp(r'^\s*（[^）]*）\s*');
final workIdPattern = RegExp(r'^([A-Z]+\d+)');
final fileWorkIdPattern = RegExp(r'^([A-Z]+)\d+n(\d+[A-Z]?)');
final citationBrPattern = RegExp(r'<br\s*/?>', caseSensitive: false);
final htmlTagPattern = RegExp(r'<[^>]*>');
final citationLineheadPattern = RegExp(
  r'^([A-Z]\d+)n(\d+[A-Z]?)_p(\d{4})([a-z])(\d+)$',
);
