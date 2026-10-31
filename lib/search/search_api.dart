import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../cbeta_api_headers.dart';
import '../scripture/models.dart';
import '../common/text_patterns.dart';

class SearchBatch {
  const SearchBatch({
    required this.results,
    required this.nextStart,
    required this.totalFound,
    required this.totalTermHits,
    this.hasMore = false,
  });

  final List<ScriptureSearchResult> results;
  final int nextStart;
  final int totalFound;
  final int totalTermHits;
  final bool hasMore;
}

/// 判斷錯誤是否來自網路連線不可用，而非遠端服務回傳的錯誤。
bool isNetworkFailure(Object error) =>
    error is SocketException ||
    error is TimeoutException ||
    error is http.ClientException ||
    error is HandshakeException;

/// 逾時只代表「伺服端還在算」,不代表沒有網路。搜尋結果頁要用這個判別,
/// 才不會在第 20 秒把使用者悄悄丟進本地掃描。
bool isRequestTimeout(Object error) => error is TimeoutException;

Future<SearchBatch> fetchSearchBatch(String query, {int start = 0}) async {
  const pageSize = 20;
  // facet 會讓伺服器多做一輪彙總（實測慢 2～5 倍，單字查詢可差十幾秒），
  // 而回傳的分面欄位並沒有人使用，因此不再請求。
  final response = await http
      .get(
        Uri.https('cbdata.dila.edu.tw', '/stable/search/all_in_one', {
          'q': query,
          'start': '$start',
          'rows': '$pageSize',
          'around': '30',
        }),
        headers: cbetaApiHeaders,
      )
      .timeout(keywordSearchTimeout);
  if (response.statusCode != 200) {
    throw Exception('全文檢索 API 回傳 ${response.statusCode}');
  }

  final payload =
      jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  if (payload['success'] == false) {
    throw Exception('全文檢索失敗：${payload['error'] ?? '未知錯誤'}');
  }
  final rows = (payload['results'] as List<dynamic>? ?? const [])
      .whereType<Map<String, dynamic>>()
      .toList();
  return SearchBatch(
    results: rows.map(parseSearchResult).toList(),
    nextStart: start + rows.length,
    totalFound: payload['num_found'] as int? ?? start + rows.length,
    totalTermHits: (payload['total_term_hits'] as num?)?.toInt() ?? 0,
    hasMore:
        rows.isNotEmpty &&
        start + rows.length < (payload['num_found'] as int? ?? 0),
  );
}

ScriptureSearchResult parseSearchResult(Map<String, dynamic> row) {
  final work = '${row['work'] ?? row['file'] ?? ''}';
  final juan = row['juan']?.toString();
  final title = '${row['title'] ?? ''}';
  final byline = '${row['byline'] ?? ''}';
  final dynasty = '${row['time_dynasty'] ?? ''}';
  final availableJuans = '${row['juan_list'] ?? ''}'
      .split(',')
      .map(int.tryParse)
      .whereType<int>()
      .toList();
  final kwics = row['kwics'];
  final kwicRows = kwics is Map<String, dynamic>
      ? (kwics['results'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
      : const <Map<String, dynamic>>[];
  final passages = kwicRows
      .map((kwic) {
        final rawKwic = '${kwic['kwic'] ?? ''}';
        final text = stripSearchMarkup(rawKwic);
        final volume = '${kwic['vol'] ?? ''}';
        final line = '${kwic['lb'] ?? ''}';
        final linehead =
            kwic['linehead']?.toString() ??
            (line.isEmpty ? null : '${row['file']}_p$line');
        final reference = [
          if (juan != null) '卷$juan',
          if (volume.isNotEmpty) volume,
          if (line.isNotEmpty) line,
        ].join(' · ');
        return ScripturePassage(
          title: title,
          reference: reference,
          text: text,
          linehead: linehead,
          juan: juan,
          work: work,
          availableJuans: availableJuans,
          snippet: searchMarkedTerm(rawKwic),
          fromOnlineIndex: true,
        );
      })
      .where((passage) => passage.text.isNotEmpty)
      .toList();

  return ScriptureSearchResult(
    title: '$work $title'.trim(),
    description: [
      if (byline.isNotEmpty) byline,
      if (dynasty.isNotEmpty && dynasty != 'unknown') dynasty,
      if (juan != null) '卷 $juan',
    ].join(' '),
    passages: passages,
  );
}

String searchMarkedTerm(String rawKwic) {
  final match = markPattern.firstMatch(rawKwic);
  return match == null ? '' : stripSearchMarkup(match.group(1) ?? '').trim();
}

final markPattern = RegExp(
  r'<mark>(.*?)</mark>',
  caseSensitive: false,
  dotAll: true,
);

String stripSearchMarkup(String text) => text
    .replaceAll(htmlTagPattern, '')
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&amp;', '&')
    .trim();

/// 結果區一次展開的列數上限。單幀內對整段命中列表做版式計算會直接
/// 造成滑動卡頓,因此所有結果列表都以分頁方式增長。
const resultSectionPageSize = 20;

/// 全文 API 對常用單字動輒二十幾秒（實測「來」26 秒／283 KB），原本的
/// 20 秒上限都在伺服端算完之前就放弃了。
const keywordSearchTimeout = Duration(seconds: 45);
const localCatalogResultLimit = 200;
