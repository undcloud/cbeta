import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'conversion.dart';

const searchHistoryKey = 'search_history';
const searchSelectionsKey = 'search_selections';
const maximumSearchHistory = 20;
const maximumSearchSelections = 100;

Future<List<String>> loadSearchHistory() async {
  final preferences = await SharedPreferences.getInstance();
  final stored = preferences.getString(searchHistoryKey);
  if (stored == null) return [];
  final decoded = jsonDecode(stored);
  if (decoded is! List<dynamic> || decoded.any((item) => item is! String)) {
    throw const FormatException('搜尋記錄資料格式錯誤');
  }
  return decoded.whereType<String>().toList();
}

Future<void> recordSearchQuery(String query) async {
  final trimmed = query.trim();
  if (trimmed.isEmpty) return;
  final history = await loadSearchHistory();
  history.removeWhere(
    (savedQuery) => savedQuery.trim().toLowerCase() == trimmed.toLowerCase(),
  );
  history.insert(0, trimmed);
  if (history.length > maximumSearchHistory) {
    history.removeRange(maximumSearchHistory, history.length);
  }
  final saved = await (await SharedPreferences.getInstance()).setString(
    searchHistoryKey,
    jsonEncode(history),
  );
  if (!saved) throw StateError('無法儲存搜尋記錄');
}

Future<Map<String, String>> loadSearchSelections() async {
  final preferences = await SharedPreferences.getInstance();
  final stored = preferences.getString(searchSelectionsKey);
  if (stored == null) return {};
  final decoded = jsonDecode(stored);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('搜尋選擇記錄資料格式錯誤');
  }
  return {
    for (final entry in decoded.entries)
      if (entry.value is String) entry.key: entry.value as String,
  };
}

Future<void> recordSearchSelection(
  String rawInput,
  String selectedQuery,
) async {
  final raw = rawInput.trim();
  final selected = selectedQuery.trim();
  if (raw.isEmpty || selected.isEmpty) return;
  final selections = await loadSearchSelections();
  selections.remove(raw);
  selections[raw] = selected;
  while (selections.length > maximumSearchSelections) {
    selections.remove(selections.keys.first);
  }
  final saved = await (await SharedPreferences.getInstance()).setString(
    searchSelectionsKey,
    jsonEncode(selections),
  );
  if (!saved) throw StateError('無法儲存搜尋選擇記錄');
}

String? matchHistoricalSelection(
  String rawInput,
  Map<String, String> selections,
) {
  final raw = rawInput.trim();
  if (raw.isEmpty || selections.isEmpty) return null;
  final query = selections[raw]?.trim();
  return query == null || query.isEmpty ? null : query;
}

typedef KeyMatchCounter =
    Future<Map<String, int>> Function(List<String> candidates);

/// 依「選中候選 → 精確歷史選擇 → 首選候選＋字典命中數」決定實際查詢詞。
Future<String> resolveSearchQuery(
  String rawInput, {
  String? selectedQuery,
  Map<String, String>? selections,
  KeyMatchCounter? keyMatchCounter,
}) async {
  final raw = rawInput.trim();
  if (raw.isEmpty) return '';
  final selected = selectedQuery?.trim() ?? '';
  if (selected.isNotEmpty) return selected;

  var savedSelections = selections ?? const <String, String>{};
  if (selections == null) {
    try {
      savedSelections = await loadSearchSelections();
    } catch (_) {
      // 歷史記錄損壞時仍可搜尋。
    }
  }
  final historical = matchHistoricalSelection(raw, savedSelections);
  if (historical != null && historical.isNotEmpty) return historical;

  final conversion = SimplifiedTraditionalConverter.convertCandidates(raw);
  if (conversion.candidates.isEmpty) return raw;
  final preferred = conversion.candidates.first;
  if (keyMatchCounter == null || conversion.candidates.length <= 1) {
    return preferred;
  }

  Map<String, int> counts;
  try {
    counts = await keyMatchCounter(conversion.candidates);
  } catch (_) {
    return preferred;
  }
  var best = preferred;
  var bestTraditional = SimplifiedTraditionalConverter.ranksAsTraditional(
    preferred,
  );
  var bestCount = counts[preferred] ?? 0;
  for (final candidate in conversion.candidates) {
    final count = counts[candidate] ?? 0;
    final isTraditional = SimplifiedTraditionalConverter.ranksAsTraditional(
      candidate,
    );
    final betterGroup = isTraditional && !bestTraditional;
    final sameGroupCount =
        isTraditional == bestTraditional && count > bestCount;
    if (betterGroup || sameGroupCount) {
      best = candidate;
      bestTraditional = isTraditional;
      bestCount = count;
    }
  }
  return best;
}

String preferredQueryFor(String rawInput, Map<String, String> selections) {
  final raw = rawInput.trim();
  if (raw.isEmpty) return '';
  final historical = matchHistoricalSelection(raw, selections);
  if (historical != null && historical.isNotEmpty) return historical;
  final conversion = SimplifiedTraditionalConverter.convertCandidates(raw);
  return conversion.candidates.isEmpty ? raw : conversion.candidates.first;
}

Future<String> preferredQueryForInput(String rawInput) async {
  Map<String, String> selections = const {};
  try {
    selections = await loadSearchSelections();
  } catch (_) {
    // 歷史記錄損壞時不影響搜尋。
  }
  return preferredQueryFor(rawInput, selections);
}
