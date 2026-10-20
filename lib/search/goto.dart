String extractCbetaGotoQuery(String input) {
  final trimmed = input.trim();
  final citation = RegExp(
    r'[\(（]\s*(CBETA\b[^)）]*?)\s*[\)）]',
    caseSensitive: false,
  ).firstMatch(trimmed);
  return citation?.group(1)?.trim() ?? trimmed;
}

String normalizeCbetaGotoLinehead(String input) {
  final linehead = RegExp(
    r'\b([A-Z]\d{1,3})\s*,?\s*no\.?\s*(\d+)\s*,?\s*p{1,2}\.?\s*([a-z]?)(\d{1,4})([a-z])(\d{1,2})',
    caseSensitive: false,
  ).firstMatch(input);
  if (linehead == null) return input.trim();
  return '${linehead.group(1)!.toUpperCase()}n'
      '${linehead.group(2)!.padLeft(4, '0')}_p'
      '${linehead.group(3)!.toLowerCase()}'
      '${linehead.group(4)!.padLeft(linehead.group(3)!.isEmpty ? 4 : 3, '0')}'
      '${linehead.group(5)!.toLowerCase()}'
      '${linehead.group(6)!.padLeft(2, '0')}';
}

bool isCbetaGotoExpression(String input) {
  final candidate = normalizeCbetaGotoLinehead(extractCbetaGotoQuery(input));
  return RegExp(
    r'^[A-Z]\d{1,3}n\d{4}_p[a-z]?\d{3,4}[a-z]\d{2}$',
  ).hasMatch(candidate);
}
