import 'conversion.dart';
import 'goto.dart';
import 'history.dart';

class SearchSelection {
  const SearchSelection({required this.rawInput, required this.query});

  final String rawInput;
  final String query;
}

class SearchChoice {
  const SearchChoice({
    required this.text,
    required this.query,
    this.isHistory = false,
    this.isOriginal = false,
    this.isDefault = false,
  });

  final String text;
  final String query;
  final bool isHistory;
  final bool isOriginal;
  final bool isDefault;

  List<String> get labels => [
    if (isHistory) '歷史',
    if (isDefault) '預設',
    if (isOriginal) '原始輸入',
  ];
}

List<SearchChoice> buildHistoryChoices(
  List<String> recentSearches,
  Map<String, String> selections,
) {
  final choices = <SearchChoice>[];
  final seen = <String>{};
  for (final entry in recentSearches) {
    final raw = entry.trim();
    if (raw.isEmpty || !seen.add(raw)) continue;
    choices.add(
      SearchChoice(text: raw, query: selections[raw] ?? raw, isHistory: true),
    );
  }
  return choices;
}

List<SearchChoice> buildSearchChoices(
  String rawInput,
  Map<String, String> selections,
) {
  final raw = rawInput.trim();
  if (raw.isEmpty) return const [];
  if (isCbetaGotoExpression(raw)) return const [];

  final historicalQuery = matchHistoricalSelection(raw, selections);
  final conversion = SimplifiedTraditionalConverter.convertCandidates(
    raw,
    historicalQuery: historicalQuery,
  );
  if (conversion.scriptKind == ScriptKind.traditional ||
      conversion.scriptKind == ScriptKind.neutral) {
    return const [];
  }
  if (conversion.candidates.length <= 1) return const [];

  final preferred = conversion.candidates.first;
  final order = <String>[];
  final entries = <String, SearchChoice>{};

  void add(
    String text, {
    bool history = false,
    bool original = false,
    bool isDefault = false,
  }) {
    if (text.isEmpty) return;
    final existing = entries[text];
    if (existing == null) {
      order.add(text);
      entries[text] = SearchChoice(
        text: text,
        query: text,
        isHistory: history,
        isOriginal: original,
        isDefault: isDefault,
      );
      return;
    }
    entries[text] = SearchChoice(
      text: existing.text,
      query: existing.query,
      isHistory: existing.isHistory || history,
      isOriginal: existing.isOriginal || original,
      isDefault: existing.isDefault || isDefault,
    );
  }

  add(
    preferred,
    history: historicalQuery != null && historicalQuery == preferred,
    isDefault: true,
  );
  add(raw, original: true);
  for (final candidate in conversion.candidates) {
    add(candidate);
  }

  if (order.length <= 1) return const [];
  return [for (final text in order) entries[text]!];
}
