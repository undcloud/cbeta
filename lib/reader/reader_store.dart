import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../scripture/models.dart';

class ReaderBookmark {
  const ReaderBookmark({
    required this.work,
    required this.title,
    required this.juan,
    required this.linehead,
    required this.availableJuans,
    this.sourceOffset,
    this.snippet = '',
  });

  final String work;
  final String title;
  final String juan;
  final String? linehead;
  final List<int> availableJuans;
  final int? sourceOffset;
  final String snippet;

  String get key => '$work:$juan:${linehead ?? sourceOffset?.toString() ?? ''}';

  factory ReaderBookmark.fromPassage(ScripturePassage passage) =>
      ReaderBookmark(
        work: passage.work ?? '',
        title: passage.title,
        juan: passage.juan ?? '1',
        linehead: passage.linehead,
        availableJuans: passage.availableJuans,
        sourceOffset: passage.sourceOffset,
        snippet: passage.snippet,
      );

  factory ReaderBookmark.fromJson(Map<String, dynamic> json) => ReaderBookmark(
    work: json['work'] as String? ?? '',
    title: json['title'] as String? ?? '',
    juan: json['juan']?.toString() ?? '1',
    linehead: json['linehead'] as String?,
    availableJuans: (json['availableJuans'] as List<dynamic>? ?? const [])
        .whereType<num>()
        .map((value) => value.toInt())
        .toList(),
    sourceOffset: (json['sourceOffset'] as num?)?.toInt(),
    snippet: json['snippet'] as String? ?? '',
  );

  Map<String, Object?> toJson() => {
    'work': work,
    'title': title,
    'juan': juan,
    'linehead': linehead,
    'availableJuans': availableJuans,
    if (sourceOffset != null) 'sourceOffset': sourceOffset,
    if (snippet.isNotEmpty) 'snippet': snippet,
  };

  ScripturePassage toPassage() => ScripturePassage(
    title: title,
    reference: '卷 $juan',
    text: '',
    linehead: linehead,
    juan: juan,
    work: work,
    availableJuans: availableJuans,
    sourceOffset: sourceOffset,
    snippet: snippet,
  );
}

const readerBookmarksKey = 'reader_bookmarks';
const readingHistoryKey = 'reading_history';
const initialRecentReadingsCount = 3;
const recentReadingsPageSize = 20;

Future<List<ReaderBookmark>> loadBookmarkRecords(String key) async {
  final preferences = await SharedPreferences.getInstance();
  final stored = preferences.getString(key);
  if (stored == null) return [];
  final decoded = jsonDecode(stored);
  if (decoded is! List<dynamic>) {
    throw const FormatException('閱讀記錄資料格式錯誤');
  }
  return decoded
      .whereType<Map<String, dynamic>>()
      .map(ReaderBookmark.fromJson)
      .toList();
}

Future<List<ReaderBookmark>> loadBookmarks() async {
  return loadBookmarkRecords(readerBookmarksKey);
}

Future<void> saveBookmarks(List<ReaderBookmark> bookmarks) async {
  final preferences = await SharedPreferences.getInstance();
  final saved = await preferences.setString(
    readerBookmarksKey,
    jsonEncode(bookmarks.map((bookmark) => bookmark.toJson()).toList()),
  );
  if (!saved) throw StateError('無法儲存書籤');
}

Future<void> recordRecentReading(ScripturePassage passage) async {
  final history = await loadBookmarkRecords(readingHistoryKey);
  final current = ReaderBookmark.fromPassage(passage);
  history.removeWhere((item) => item.work == current.work);
  history.insert(0, current);
  final preferences = await SharedPreferences.getInstance();
  final saved = await preferences.setString(
    readingHistoryKey,
    jsonEncode(history.map((bookmark) => bookmark.toJson()).toList()),
  );
  if (!saved) throw StateError('無法儲存閱讀記錄');
}
