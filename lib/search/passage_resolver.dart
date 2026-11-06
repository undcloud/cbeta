import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../cbeta_api_headers.dart';
import '../scripture/cache.dart';
import '../scripture/models.dart';
import '../scripture/source_text.dart';
import '../scripture/parser.dart';
import '../search/goto.dart';
import '../download/catalog_cache.dart';
import '../common/text_patterns.dart';
import 'offline_preference.dart';
import 'search_api.dart';

String catalogResultWorkId(Map<String, dynamic> result) {
  final work = '${result['work'] ?? ''}'.trim();
  if (work.isNotEmpty) return work;
  final file = '${result['file'] ?? ''}';
  final match = fileWorkIdPattern.firstMatch(file);
  return match == null ? '' : '${match.group(1)}${match.group(2)}';
}

/// 取得作品的卷清單。
///
/// 多數作品以 `juan` 欄位提供卷資料；部分作品（例如印順法師著作等 Y 系列）
/// 只提供 `mulu` 目錄樹，此時改由目錄樹依卷彙整出可讀取的卷。
List<Map<String, dynamic>> tocJuanEntries(Map<String, dynamic>? toc) {
  final juans = (toc?['juan'] as List<dynamic>? ?? const [])
      .whereType<Map<String, dynamic>>()
      .toList();
  if (juans.isNotEmpty) return juans;

  void collect(List<dynamic> entries, Map<int, Map<String, dynamic>> byJuan) {
    for (final entry in entries.whereType<Map<String, dynamic>>()) {
      final juan = int.tryParse('${entry['juan'] ?? ''}');
      final lb = '${entry['lb'] ?? ''}';
      if (juan != null) {
        final current = byJuan[juan];
        if (current == null ||
            (lb.isNotEmpty && lb.compareTo('${current['lb'] ?? ''}') < 0)) {
          byJuan[juan] = {
            'file': entry['file'],
            'juan': juan,
            'lb': entry['lb'],
            'title': '第$juan卷',
          };
        }
      }
      collect(entry['children'] as List<dynamic>? ?? const [], byJuan);
    }
  }

  final byJuan = <int, Map<String, dynamic>>{};
  collect(toc?['mulu'] as List<dynamic>? ?? const [], byJuan);
  return byJuan.values.toList()..sort(
    (left, right) => (left['juan'] as int).compareTo(right['juan'] as int),
  );
}

String searchResultWorkId(ScriptureSearchResult result) {
  if (result.workId.isNotEmpty) return result.workId;
  final passageWork = result.passages.firstOrNull?.work;
  if (passageWork != null && passageWork.isNotEmpty) return passageWork;
  final match = workIdPattern.firstMatch(result.title);
  return match?.group(1) ?? '';
}

Future<ScripturePassage> resolveGotoPassage(String input) async {
  final linehead = normalizeCbetaGotoLinehead(extractCbetaGotoQuery(input));
  if (!isCbetaGotoExpression(linehead)) {
    throw const FormatException('請輸入有效的 CBETA 行號或引文');
  }
  if (offlineMode) {
    // 離線模式連 Goto 也不能先打伺服器；卷不在本地就直接引導下載或切換。
    final local = await resolveGotoPassageLocally(linehead);
    if (local != null) return local;
    throw FormatException(
      '離線模式下，本地尚未儲存「$linehead」所在的經卷；'
      '請先下載或切換到聯網模式',
    );
  }
  try {
    return await resolveGotoPassageOnline(linehead);
  } catch (error) {
    if (isNetworkFailure(error)) {
      final local = await resolveGotoPassageLocally(linehead);
      if (local != null) return local;
      throw FormatException('離線模式下，本地尚未儲存「$linehead」所在的經卷');
    }
    rethrow;
  }
}

Future<ScripturePassage> resolveGotoPassageOnline(String linehead) async {
  final response = await http
      .get(
        Uri.https('cbdata.dila.edu.tw', '/stable/juans/goto', {
          'linehead': linehead,
        }),
        headers: cbetaApiHeaders,
      )
      .timeout(const Duration(seconds: 20));
  if (response.statusCode != 200) {
    throw Exception('Goto API 回傳 ${response.statusCode}');
  }
  final payload =
      jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  final apiError = payload['error'];
  if (apiError is Map<String, dynamic>) {
    throw FormatException('${apiError['message'] ?? '無法識別此行號'}');
  }
  if (apiError is String && apiError.isNotEmpty) {
    throw FormatException(apiError);
  }
  final result = (payload['results'] as List<dynamic>? ?? const [])
      .whereType<Map<String, dynamic>>()
      .firstOrNull;
  if (result == null) throw const FormatException('找不到此行號對應的經卷');
  return resolveWorkPassage(
    result,
    targetLinehead: '${result['linehead'] ?? linehead}',
  );
}

Future<ScripturePassage> resolveCatalogWorkPassage(
  Map<String, dynamic> result,
) async {
  final work = catalogResultWorkId(result);
  if (work.isEmpty) throw const FormatException('經目資料缺少作品編號');
  return resolveWorkPassage({...result, 'work': work});
}

Future<ScripturePassage> resolveWorkPassage(
  Map<String, dynamic> item, {
  String? targetLinehead,
}) async {
  final work = '${item['work'] ?? catalogResultWorkId(item)}';
  if (work.isEmpty) throw const FormatException('經目資料缺少作品編號');
  if (offlineMode) {
    final local = await localWorkPassage(work, targetLinehead: targetLinehead);
    if (local != null) return local;
    throw FormatException('離線模式下，本地尚未儲存《$work》；請先下載或切換到聯網模式');
  }
  try {
    return await resolveWorkPassageOnline(
      work,
      item,
      targetLinehead: targetLinehead,
    );
  } catch (error) {
    if (isNetworkFailure(error)) {
      final local = await localWorkPassage(
        work,
        targetLinehead: targetLinehead,
      );
      if (local != null) return local;
    }
    rethrow;
  }
}

Future<ScripturePassage> resolveWorkPassageOnline(
  String work,
  Map<String, dynamic> item, {
  String? targetLinehead,
}) async {
  final response = await http
      .get(
        Uri.https('cbdata.dila.edu.tw', '/stable/works/toc', {'work': work}),
        headers: cbetaApiHeaders,
      )
      .timeout(const Duration(seconds: 20));
  if (response.statusCode != 200) {
    throw Exception('作品目錄 API 回傳 ${response.statusCode}');
  }
  final payload =
      jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  final toc = (payload['results'] as List<dynamic>? ?? const [])
      .whereType<Map<String, dynamic>>()
      .firstOrNull;
  final juans = tocJuanEntries(toc);
  if (juans.isEmpty) throw const FormatException('此作品沒有可讀取的卷');

  final availableJuans =
      juans
          .map((entry) => entry['juan'])
          .whereType<num>()
          .map((value) => value.toInt())
          .toSet()
          .toList()
        ..sort();
  final targetJuan = targetLinehead == null
      ? null
      : int.tryParse('${item['juan'] ?? ''}');
  if (targetJuan != null && !availableJuans.contains(targetJuan)) {
    availableJuans.add(targetJuan);
    availableJuans.sort();
  }
  final selected =
      juans.where((entry) => entry['juan'] == targetJuan).firstOrNull ??
      (targetJuan == null
          ? null
          : {
              'file': item['file'],
              'juan': targetJuan,
              'lb': item['lb'] ?? targetLinehead!.split('_p').last,
            }) ??
      juans
          .where((entry) => entry['juan'] == availableJuans.first)
          .firstOrNull ??
      juans.first;
  final file = '${selected['file'] ?? item['file'] ?? work}';
  final line = targetLinehead == null
      ? '${selected['lb'] ?? ''}'
      : targetLinehead.split('_p').last;
  final rawTitle = '${item['title'] ?? item['label'] ?? work}';
  final title = rawTitle.replaceFirst(
    RegExp('^${RegExp.escape(work)}\\s+'),
    '',
  );
  return ScripturePassage(
    title: title,
    reference: '卷 ${selected['juan']}',
    text: '',
    linehead: line.isEmpty ? null : '${file}_p$line',
    juan: '${selected['juan']}',
    work: work,
    availableJuans: availableJuans,
  );
}

/// 以 App 內建的完整經目 metadata 查詢,不發任何網路請求。
Future<List<Map<String, dynamic>>> searchLocalCatalog(String query) async {
  final needle = query.trim();
  if (needle.isEmpty) return const [];
  try {
    final catalog = CatalogCache.instance;
    await catalog.load();
    return catalog.searchWorks(needle, limit: localCatalogResultLimit);
  } catch (_) {
    // 經目資產載入失敗時沒有可查的書名表,交由離線經卷那層兜底。
    return const [];
  }
}

List<ScriptureLine>? tryParseLocalVolume(CachedScriptureVolume volume) {
  try {
    return parseScriptureHtml(volume.html);
  } catch (_) {
    return null;
  }
}

List<int> cachedJuansForRefs(List<ScriptureVolumeRef> refs, String work) =>
    refs
        .where((ref) => ref.work == work)
        .map((ref) => int.tryParse(ref.juan))
        .whereType<int>()
        .toSet()
        .toList()
      ..sort();

int juanNumber(ScriptureVolumeRef ref) => int.tryParse(ref.juan) ?? 0;

void sortRefsByJuan(List<ScriptureVolumeRef> refs) {
  refs.sort((left, right) => juanNumber(left).compareTo(juanNumber(right)));
}

String lineheadWorkId(String linehead) {
  final match = RegExp(r'^([A-Z]+)\d+n(\d+[A-Z]?)_p').firstMatch(linehead);
  return match == null ? '' : '${match.group(1)}${match.group(2)}';
}

ScripturePassage localPassage({
  required String work,
  required CachedScriptureVolume volume,
  required List<ScriptureLine> lines,
  required List<int> juans,
  String? linehead,
}) {
  final title = localWorkTitle(lines);
  return ScripturePassage(
    title: title.isEmpty ? work : title,
    reference: '卷 ${volume.juan}',
    text: '',
    linehead: linehead,
    juan: volume.juan,
    work: work,
    availableJuans: juans,
  );
}

/// 下載壓縮檔只保留段落級錨點（如 0150a07），而 CBETA 引文是逐行行號
/// （如 0150a09）；取目標行號之前最近的錨點，Goto 才不會因為行號比本檔更細而失敗。
String? nearestLocalLinehead(List<ScriptureLine> lines, String linehead) {
  final split = linehead.lastIndexOf('_p');
  if (split <= 0) return null;
  final prefix = linehead.substring(0, split);
  final target = linehead.substring(split + 2);
  String? nearest;
  for (final line in lines) {
    final head = line.linehead;
    if (head == null || !head.startsWith('${prefix}_p')) continue;
    final value = head.substring(prefix.length + 2);
    if (value.compareTo(target) > 0) continue;
    if (nearest == null || value.compareTo(nearest) > 0) nearest = value;
  }
  return nearest == null ? null : '${prefix}_p$nearest';
}

typedef LocalAnchorHit = ({
  CachedScriptureVolume volume,
  List<ScriptureLine> lines,
});

/// 在本地已儲存的經卷中找出目標行號所在的卷：先找精確錨點，
/// 沒有就拿「行號之前最近錨點」所在的那一卷（跨卷時取最接近目標的一卷）。
Future<LocalAnchorHit?> findLocalVolumeForLinehead(
  List<ScriptureVolumeRef> workRefs,
  String linehead,
) async {
  LocalAnchorHit? nearest;
  String? nearestAnchor;
  for (final ref in workRefs) {
    final volume = await scriptureVolumeStore.readRef(ref);
    if (volume == null) continue;
    final lines = tryParseLocalVolume(volume);
    if (lines == null) continue;
    final anchor = nearestLocalLinehead(lines, linehead);
    if (anchor == null) continue;
    if (anchor == linehead) {
      return (volume: volume, lines: lines);
    }
    if (nearestAnchor == null || anchor.compareTo(nearestAnchor) > 0) {
      nearestAnchor = anchor;
      nearest = (volume: volume, lines: lines);
    }
  }
  return nearest;
}

/// 以本地已儲存的離線經卷建立可開啟的經卷位置，
/// 供離線經目點擊與 Goto 使用。
Future<ScripturePassage?> localWorkPassage(
  String work, {
  String? targetLinehead,
}) async {
  if (work.isEmpty) return null;
  final allRefs = await scriptureVolumeStore.listRefs();
  final workRefs = allRefs.where((ref) => ref.work == work).toList();
  if (workRefs.isEmpty) return null;
  sortRefsByJuan(workRefs);
  final juans = cachedJuansForRefs(allRefs, work);
  if (targetLinehead != null) {
    final hit = await findLocalVolumeForLinehead(workRefs, targetLinehead);
    if (hit != null) {
      return localPassage(
        work: work,
        volume: hit.volume,
        lines: hit.lines,
        juans: juans,
        linehead: targetLinehead,
      );
    }
  }
  final target = await scriptureVolumeStore.readRef(workRefs.first);
  if (target == null) return null;
  final lines = tryParseLocalVolume(target) ?? const <ScriptureLine>[];
  return localPassage(work: work, volume: target, lines: lines, juans: juans);
}

/// 離線時依行號在本地已儲存的經卷中尋找對應位置。
///
/// 本地行號比目标粗（下載檔只有段落級錨點）時也要能開啟，所以保留引文的
/// 逐行行號交給閱讀器，由閱讀器的段落錨點回退選出正確的那一段。
Future<ScripturePassage?> resolveGotoPassageLocally(String linehead) async {
  final work = lineheadWorkId(linehead);
  if (work.isEmpty) return null;
  final refs = await scriptureVolumeStore.listRefs();
  final workRefs = refs.where((ref) => ref.work == work).toList();
  sortRefsByJuan(workRefs);
  if (workRefs.isEmpty) return null;
  final juans = cachedJuansForRefs(refs, work);
  final hit = await findLocalVolumeForLinehead(workRefs, linehead);
  if (hit == null) return null;
  return localPassage(
    work: work,
    volume: hit.volume,
    lines: hit.lines,
    juans: juans,
    linehead: linehead,
  );
}

/// 離線時以本地已儲存經卷的經名／作譯者進行經目查詢。
///
/// 優先使用已載入的經目資料，避免為了查詢而解析大量經文 HTML；
/// 只有經目未收錄的經卷才需要讀取內容。
///
/// [shouldAbort] 在每一部經之間檢查：那些讀卷與解析 HTML 都发生在呼叫端的
/// isolate 上（通常是主 isolate），過期的查詢要能立刻停手。
Future<List<Map<String, dynamic>>> searchOfflineCatalog(
  String query, {
  bool Function()? shouldAbort,
}) async {
  final needle = query.trim();
  if (needle.isEmpty) return const [];
  final refs = await scriptureVolumeStore.listRefs();
  if (refs.isEmpty) return const [];
  final downloadedWorks = {for (final ref in refs) ref.work};
  final results = <Map<String, dynamic>>[];
  final seenWorks = <String>{};
  final catalog = CatalogCache.instance;

  if (catalog.isLoaded) {
    for (final item in catalog.searchWorks(needle, limit: 5000)) {
      final work = '${item['work'] ?? ''}';
      if (work.isEmpty || !downloadedWorks.contains(work)) continue;
      if (!seenWorks.add(work)) continue;
      results.add({...item, 'offline': true});
    }
  }

  final firstRefByWork = <String, ScriptureVolumeRef>{};
  for (final ref in refs) {
    if (seenWorks.contains(ref.work)) continue;
    if (catalog.isLoaded && catalog.lookupWork(ref.work) != null) continue;
    final existing = firstRefByWork[ref.work];
    if (existing == null || juanNumber(ref) < juanNumber(existing)) {
      firstRefByWork[ref.work] = ref;
    }
  }

  final lowerNeedle = needle.toLowerCase();
  var processed = 0;
  for (final entry in firstRefByWork.entries) {
    // 每一部不在經目裡的經都要讀卷並解析 HTML，所以「讀了幾部」就要讓出一幀，
    // 不能只在有命中時才讓（沒命中時從不讓幀，等於把主 isolate 排死）。
    if (processed > 0 && processed % 4 == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    if (shouldAbort != null && shouldAbort()) break;
    processed++;
    final volume = await scriptureVolumeStore.readRef(entry.value);
    if (volume == null) continue;
    final lines = tryParseLocalVolume(volume);
    if (lines == null) continue;
    final info = localVolumeInfo(lines);
    final workTitle = localWorkTitle(lines);
    final title = workTitle.isNotEmpty ? workTitle : entry.key;
    final haystack = '$title ${entry.key}'.toLowerCase();
    if (!haystack.contains(lowerNeedle)) continue;
    results.add({
      'work': entry.key,
      'title': title,
      if (info.byline.isNotEmpty) 'byline': info.byline,
      'offline': true,
    });
  }
  results.sort(
    (left, right) => '${left['title']}'.compareTo('${right['title']}'),
  );
  return results;
}
