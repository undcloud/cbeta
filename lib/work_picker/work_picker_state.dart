import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

const workPickerStateKey = 'work_picker_state';

class PickerCatalogLevel {
  const PickerCatalogLevel({required this.q, required this.label});

  final String q;
  final String label;

  Map<String, dynamic> toJson() => {'q': q, 'label': label};

  factory PickerCatalogLevel.fromJson(Map<String, dynamic> json) =>
      PickerCatalogLevel(
        q: json['q'] as String? ?? '',
        label: json['label'] as String? ?? '',
      );
}

/// 左側欄關閉前的畫面快照，用來在下次開啟時回到相同位置與內容。
class WorkPickerSnapshot {
  const WorkPickerSnapshot({
    this.tab = 0,
    this.scrollOffsets = const {},
    this.dictionaryQuery = '',
    this.dictionaryExpandedIds = const {},
    this.dictionaryExpandedEntryKeys = const {},
    this.catalogLevels = const {},
    this.creatorQuery = '',
    this.tocQuery = '',
    this.gotoQuery = '',
    this.showingWorks = false,
    this.listedWorks = const [],
    this.resultMessage,
  });

  final int tab;
  final Map<int, double> scrollOffsets;
  final String dictionaryQuery;
  final Set<String> dictionaryExpandedIds;
  final Set<String> dictionaryExpandedEntryKeys;
  final Map<int, List<PickerCatalogLevel>> catalogLevels;
  final String creatorQuery;
  final String tocQuery;
  final String gotoQuery;
  final bool showingWorks;
  final List<Map<String, dynamic>> listedWorks;
  final String? resultMessage;

  Map<String, dynamic> toJson() => {
    'tab': tab,
    'scrollOffsets': {
      for (final entry in scrollOffsets.entries) '${entry.key}': entry.value,
    },
    'dictionaryQuery': dictionaryQuery,
    'dictionaryExpandedIds': dictionaryExpandedIds.toList(),
    'dictionaryExpandedEntryKeys': dictionaryExpandedEntryKeys.toList(),
    'catalogLevels': {
      for (final entry in catalogLevels.entries)
        '${entry.key}': [for (final level in entry.value) level.toJson()],
    },
    'creatorQuery': creatorQuery,
    'tocQuery': tocQuery,
    'gotoQuery': gotoQuery,
    'showingWorks': showingWorks,
    'listedWorks': listedWorks,
    'resultMessage': resultMessage,
  };

  factory WorkPickerSnapshot.fromJson(Map<String, dynamic> json) {
    return WorkPickerSnapshot(
      tab: (json['tab'] as num?)?.toInt() ?? 0,
      scrollOffsets: _scrollOffsetsFromJson(json['scrollOffsets']),
      dictionaryQuery: json['dictionaryQuery'] as String? ?? '',
      dictionaryExpandedIds: _stringSet(json['dictionaryExpandedIds']),
      dictionaryExpandedEntryKeys: _stringSet(
        json['dictionaryExpandedEntryKeys'],
      ),
      catalogLevels: _catalogLevelsFromJson(json['catalogLevels']),
      creatorQuery: json['creatorQuery'] as String? ?? '',
      tocQuery: json['tocQuery'] as String? ?? '',
      gotoQuery: json['gotoQuery'] as String? ?? '',
      showingWorks: json['showingWorks'] as bool? ?? false,
      listedWorks: _listedWorksFromJson(json['listedWorks']),
      resultMessage: json['resultMessage'] as String?,
    );
  }
}

Map<int, double> _scrollOffsetsFromJson(Object? value) {
  final offsets = <int, double>{};
  if (value is Map<String, dynamic>) {
    for (final entry in value.entries) {
      final tab = int.tryParse(entry.key);
      final offset = entry.value;
      if (tab != null && offset is num) offsets[tab] = offset.toDouble();
    }
  }
  return offsets;
}

Map<int, List<PickerCatalogLevel>> _catalogLevelsFromJson(Object? value) {
  final levels = <int, List<PickerCatalogLevel>>{};
  if (value is Map<String, dynamic>) {
    for (final entry in value.entries) {
      final tab = int.tryParse(entry.key);
      final rawLevels = entry.value;
      if (tab == null || rawLevels is! List<dynamic>) continue;
      levels[tab] = [
        for (final level in rawLevels)
          if (level is Map<String, dynamic>) PickerCatalogLevel.fromJson(level),
      ];
    }
  }
  return levels;
}

List<Map<String, dynamic>> _listedWorksFromJson(Object? value) {
  if (value is! List<dynamic>) return const [];
  return [
    for (final item in value)
      if (item is Map<String, dynamic>) item,
  ];
}

Set<String> _stringSet(Object? value) {
  if (value is! List<dynamic>) return const {};
  return {
    for (final item in value)
      if (item is String) item,
  };
}

Future<WorkPickerSnapshot?> loadWorkPickerSnapshot() async {
  try {
    final preferences = await SharedPreferences.getInstance();
    final stored = preferences.getString(workPickerStateKey);
    if (stored == null) return null;
    final decoded = jsonDecode(stored);
    if (decoded is! Map<String, dynamic>) return null;
    return WorkPickerSnapshot.fromJson(decoded);
  } catch (_) {
    return null;
  }
}

Future<void> saveWorkPickerSnapshot(WorkPickerSnapshot snapshot) async {
  try {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      workPickerStateKey,
      jsonEncode(snapshot.toJson()),
    );
  } catch (_) {
    // 狀態備份失敗不影響閱讀。
  }
}
