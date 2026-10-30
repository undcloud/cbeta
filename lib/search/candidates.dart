import 'conversion.dart';
import 'goto.dart';
import 'history.dart';

class SearchSelection {
  const SearchSelection({
    required this.rawInput,
    required this.query,
    this.isExplicit = false,
  });

  final String rawInput;
  final String query;

  /// 使用者是否明確點選了候選或歷史記錄。
  final bool isExplicit;
}

class SearchChoice {
  const SearchChoice({
    required this.text,
    required this.query,
    this.rawInput = '',
    this.isHistory = false,
    this.isOriginal = false,
    this.isDefault = false,
    this.isSimplified = false,
    this.hitCount,
  });

  final String text;
  final String query;

  /// 產生此候選時輸入框裡的原始文字；空字串表示沿用當前輸入。
  final String rawInput;
  final bool isHistory;
  final bool isOriginal;
  final bool isDefault;
  final bool isSimplified;
  final int? hitCount;

  /// 首選（原輸入的轉換）與原始輸入固定在最前，其餘候選依字典命中數排序。
  bool get isPinned => isDefault || isOriginal;

  List<String> get labels => [
    if (isHistory) '歷史',
    if (isSimplified) '簡體',
    if (isOriginal) '原始輸入',
  ];

  SearchChoice withHitCount(int? value) => SearchChoice(
    text: text,
    query: query,
    rawInput: rawInput,
    isHistory: isHistory,
    isOriginal: isOriginal,
    isDefault: isDefault,
    isSimplified: isSimplified,
    hitCount: value,
  );
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
    final query = selections[raw] ?? raw;
    choices.add(
      SearchChoice(
        text: query,
        query: query,
        rawInput: raw,
        isHistory: true,
      ),
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

  final conversion = SimplifiedTraditionalConverter.convertCandidates(raw);
  final historicalQuery = matchHistoricalSelection(raw, selections);
  final order = <String>[];
  final entries = <String, SearchChoice>{};

  void add(
    String text, {
    bool history = false,
    bool original = false,
    bool isDefault = false,
    bool simplified = false,
  }) {
    if (text.isEmpty) return;
    final existing = entries[text];
    if (existing == null) {
      order.add(text);
      entries[text] = SearchChoice(
        text: text,
        query: text,
        rawInput: raw,
        isHistory: history,
        isOriginal: original,
        isDefault: isDefault,
        isSimplified: simplified,
      );
      return;
    }
    entries[text] = SearchChoice(
      text: existing.text,
      query: existing.query,
      rawInput: raw,
      isHistory: existing.isHistory || history,
      isOriginal: existing.isOriginal || original,
      isDefault: existing.isDefault || isDefault,
      isSimplified: existing.isSimplified || simplified,
    );
  }

  for (var index = 0; index < conversion.candidates.length; index++) {
    final candidate = conversion.candidates[index];
    add(
      candidate,
      isDefault: index == 0,
      original: candidate == raw,
      history: candidate == historicalQuery,
      simplified: candidate == conversion.fullSimplified && candidate != raw,
    );
  }
  if (historicalQuery != null &&
      historicalQuery.isNotEmpty &&
      !entries.containsKey(historicalQuery)) {
    add(historicalQuery, history: true);
  }

  if (order.length <= 1) return const [];
  return [for (final text in order) entries[text]!];
}
