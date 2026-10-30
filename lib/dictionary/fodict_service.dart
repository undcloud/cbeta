import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

/// 一部已解析詞典的查表資料。
///
/// [lowerKeys] 與 [keys] 同序,讓 key 匹配不必每次掃描都重新分配
/// 小寫字串;詞典有數萬條, repeated 分配是搜尋頁的主要 GC 來源。
class ParsedDictionary {
  const ParsedDictionary({
    required this.entries,
    required this.keys,
    required this.lowerKeys,
  });

  final Map<String, String> entries;
  final List<String> keys;
  final List<String> lowerKeys;

  int get length => keys.length;
}

/// 在背景 isolate 解析 `fodict.dat`；頂層函式才能傳給 [compute]。
ParsedDictionary parseFodictData(Uint8List data) {
  if (data.length < 64) {
    return const ParsedDictionary(entries: {}, keys: [], lowerKeys: []);
  }

  final contentStart = ByteData.sublistView(data).getUint32(32, Endian.little);
  final entries = <String, String>{};
  if (contentStart < 0 || contentStart + 8 > data.length) {
    return const ParsedDictionary(entries: {}, keys: [], lowerKeys: []);
  }

  // 以第一條目判斷格式：關鍵字後的 defLen 為 0 者為「分類＋全文」兩段式。
  final firstKwLen = FodictService._readUint32(data, contentStart);
  final detectable =
      firstKwLen > 0 &&
      firstKwLen <= 1000 &&
      contentStart + 4 + firstKwLen + 4 <= data.length;
  if (detectable &&
      FodictService._readUint32(data, contentStart + 4 + firstKwLen) == 0) {
    FodictService._loadSpecialFormat(data, contentStart, entries);
  } else {
    FodictService._loadStandardFormat(data, contentStart, entries);
  }

  final keys = List<String>.from(entries.keys, growable: false);
  return ParsedDictionary(
    entries: entries,
    keys: keys,
    lowerKeys: [for (final key in keys) key.toLowerCase()],
  );
}

class FodictEntry {
  final String keyword;
  final String definition;
  final String dictionaryName;
  final String dictionaryId;

  FodictEntry({
    required this.keyword,
    required this.definition,
    required this.dictionaryName,
    required this.dictionaryId,
  });
}

class FodictInfo {
  final String id;
  final String name;
  final String path;
  final int datSize;
  final bool isAsset;

  FodictInfo({
    required this.id,
    required this.name,
    required this.path,
    required this.datSize,
    this.isAsset = false,
  });
}

class FodictService {
  static final FodictService _instance = FodictService._internal();
  factory FodictService() => _instance;
  FodictService._internal();

  List<FodictInfo>? _dictionaries;

  /// 有界 LRU:單部大辭典解析後可佔十餘 MB,無上限快取會造成持續 GC 壓力。
  static const _cacheLimit = 2;
  final LinkedHashMap<String, ParsedDictionary> _cache =
      LinkedHashMap<String, ParsedDictionary>();

  static const _dictionaryNames = {
    '001.dfb-j': '佛學大辭典',
    '002.cyx-j': '禪源諸詮集',
    '003.zgfj-j': '中國佛教',
    '004.szfs-j': '三藏法數',
    '005.fymyj-j': '翻譯名義集',
    '006.fxcdtb-j': '佛學次第統編',
    '007.ce-ec-ee-j': '英漢-漢英-英英佛學詞彙',
    '008.theravada-j': '巴英南傳佛教辭典',
    '009.faxiang-j': '法相辭典',
    '010.bkqszl-j': '中國大百科全書',
    '011.fjrwz-j': '佛教人物傳',
    '012.weishi-j': '唯識名詞白話新解',
    '013.fajie-j': '法界辭典',
    '014.famen-j': '法門名義集',
    '015.syfy-j': '俗語佛源',
    '016.tiantai-j': '天台教學辭典',
    '017.apdm-j': '阿毗達磨辭典',
    '018.chanzongyulu-j': '禪宗語錄辭典',
    '019.fjqiwu-j': '佛教器物簡述',
    '020.ztsy-j': '祖庭事苑',
    '021.yzzj-j': '閱藏知津',
    '022.ssyl-j': '四十二章經疏',
    '023.zcfj-j': '藏傳佛教辭典',
    '024.chanlinxqj-j': '禪林象器箋',
    '025.nanshanlv-j': '南山律學辭典',
    '026.fymydj-j': '翻譯名言大集',
    '027.wyhbjy-j': '無量義經',
    '028.fhchb-j': '梵漢詞彙表',
    '030.dila-dingfubao': '丁福保佛學大辭典',
  };

  static const assetDictionaryIds = ['030.dila-dingfubao'];

  static Future<String> defaultBaseDir() async {
    final directory = await getApplicationDocumentsDirectory();
    return '${directory.path}${Platform.pathSeparator}fodict';
  }

  static final _validDictionaryId = RegExp(r'^[0-9A-Za-z][0-9A-Za-z._-]*$');

  Future<List<FodictInfo>> getDictionaries(String baseDir) async {
    if (_dictionaries != null) return _dictionaries!;

    final dicts = <FodictInfo>[];

    for (final dictId in assetDictionaryIds) {
      try {
        final data = await rootBundle.load('assets/fodict/$dictId/fodict.dat');
        dicts.add(
          FodictInfo(
            id: dictId,
            name: _dictionaryNames[dictId] ?? dictId,
            path: 'assets/fodict/$dictId',
            datSize: data.lengthInBytes,
            isAsset: true,
          ),
        );
      } catch (e) {
        continue;
      }
    }

    final dir = Directory(baseDir);
    if (baseDir.trim().isNotEmpty && await dir.exists()) {
      await for (final entity in dir.list()) {
        if (entity is Directory) {
          final name =
              entity.uri.pathSegments[entity.uri.pathSegments.length - 2];
          if (assetDictionaryIds.contains(name) ||
              name.startsWith('.') ||
              !_validDictionaryId.hasMatch(name)) {
            continue;
          }

          final datFile = File('${entity.path}/fodict.dat');
          if (await datFile.exists()) {
            final stat = await datFile.stat();
            dicts.add(
              FodictInfo(
                id: name,
                name:
                    _dictionaryNames[name] ??
                    await _readNameFromIni(entity.path) ??
                    name,
                path: entity.path,
                datSize: stat.size,
                isAsset: false,
              ),
            );
          }
        }
      }
    }

    dicts.sort((a, b) => a.id.compareTo(b.id));
    _dictionaries = dicts;
    return dicts;
  }

  /// 從词典目录的 fodict.ini 读取 name 欄位，用于未在內建映射中的下載词典。
  Future<String?> _readNameFromIni(String dictPath) async {
    final iniFile = File('$dictPath/fodict.ini');
    if (!await iniFile.exists()) return null;
    try {
      final lines = await iniFile.readAsLines();
      for (final raw in lines) {
        final line = raw.trim();
        if (line.startsWith('[') || line.startsWith('#')) continue;
        final eq = line.indexOf('=');
        if (eq <= 0) continue;
        if (line.substring(0, eq).trim() == 'name') {
          final value = line.substring(eq + 1).trim();
          return value.isEmpty ? null : value;
        }
      }
    } catch (_) {}
    return null;
  }

  Future<ParsedDictionary> _loadDictionary(FodictInfo dict) async {
    final cached = _cache.remove(dict.id);
    if (cached != null) {
      _cache[dict.id] = cached;
      return cached;
    }

    final Uint8List data;
    if (dict.isAsset) {
      final byteData = await rootBundle.load('${dict.path}/fodict.dat');
      data = byteData.buffer.asUint8List();
    } else {
      final datFile = File('${dict.path}/fodict.dat');
      data = await datFile.readAsBytes();
    }

    // 數萬條目的解碼如果留在 UI isolate,任何正在進行的滑动手勢都會掉幀。
    final parsed = await compute(parseFodictData, data);
    _cache[dict.id] = parsed;
    while (_cache.length > _cacheLimit) {
      _cache.remove(_cache.keys.first);
    }
    return parsed;
  }

  static void _loadStandardFormat(
    Uint8List data,
    int startOffset,
    Map<String, String> entries,
  ) {
    var offset = startOffset;
    while (offset + 8 <= data.length) {
      final kwLen = _readUint32(data, offset);
      if (kwLen <= 0 || kwLen > 1000 || offset + 4 + kwLen > data.length) {
        break;
      }

      final kwBytes = data.sublist(offset + 4, offset + 4 + kwLen);
      final keyword = _decodeUtf16LE(kwBytes);

      final defLenOffset = offset + 4 + kwLen;
      if (defLenOffset + 4 > data.length) break;
      final defLen = _readUint32(data, defLenOffset);

      final defStart = defLenOffset + 4;
      if (defLen <= 0 || defLen > 1000000 || defStart + defLen > data.length) {
        break;
      }

      final defBytes = data.sublist(defStart, defStart + defLen);
      final definition = _decodeUtf16LE(defBytes);

      entries[keyword] = definition;
      offset = defStart + defLen;
    }
  }

  static void _loadSpecialFormat(
    Uint8List data,
    int startOffset,
    Map<String, String> entries,
  ) {
    var offset = startOffset;

    // Phase 1: Parse category keywords [kw_len:u32][kw:UTF16LE][00000000:u32]
    while (offset + 8 <= data.length) {
      final kwLen = _readUint32(data, offset);
      if (kwLen <= 0 || kwLen > 10000 || offset + 4 + kwLen > data.length) {
        break;
      }

      final kwBytes = data.sublist(offset + 4, offset + 4 + kwLen);
      final keyword = _decodeUtf16LE(kwBytes);

      final nextOffset = offset + 4 + kwLen;
      if (nextOffset + 4 > data.length) break;
      final separator = _readUint32(data, nextOffset);

      if (separator == 0) {
        entries[keyword] = '';
        offset = nextOffset + 4;
      } else {
        break;
      }
    }

    // Phase 2: Parse full-text entries [entry_size:u32][text:UTF16LE]
    // 先全部解出,標題條要向後看一條才能配對。
    final texts = <String>[];
    while (offset + 4 <= data.length) {
      final entrySize = _readUint32(data, offset);
      if (entrySize == 0 ||
          entrySize > 10000000 ||
          offset + 4 + entrySize > data.length) {
        break;
      }

      final textBytes = data.sublist(offset + 4, offset + 4 + entrySize);
      final text = _trimDecoration(_decodeUtf16LE(textBytes));
      if (text.isNotEmpty) texts.add(text);

      offset = offset + 4 + entrySize;
    }

    for (var index = 0; index < texts.length; index++) {
      final text = texts[index];
      if (_isTitleRecord(text) &&
          index + 1 < texts.length &&
          !_isTitleRecord(texts[index + 1])) {
        final keyword = text.length <= _keywordMaxLength
            ? text
            : _keywordFromText(text);
        if (keyword.isNotEmpty) {
          entries.putIfAbsent(keyword, () => texts[index + 1]);
        }
        index++;
        continue;
      }
      _putFullTextEntry(entries, text);
    }
  }

  /// 「人名（所在）《出處》卷次」一類的標題條,本身沒有正文,是下一條正文的 key。
  static bool _isTitleRecord(String text) =>
      text.length <= _titleRecordMaxLength &&
      text.contains(_sourceOpen) &&
      text.contains(_sourceClose);

  /// 沒有標題條領頭的正文集,以開頭的人稱作 key;同名人往往有多篇傳,
  /// key 衝突時繼續取到下一個句讀,仍衝突才放棄該集。
  static void _putFullTextEntry(Map<String, String> entries, String text) {
    final breaks = _keywordBreakOffsets(text);
    if (breaks.isEmpty) return;

    var keyword = text.substring(0, breaks.first);
    var cursor = 0;
    // 同一人多篇傳記時首句會重複,繼續取到下一個句讀直到 key 唯一。
    while (entries.containsKey(keyword) && cursor + 1 < breaks.length) {
      cursor++;
      keyword = text.substring(0, breaks[cursor]);
    }
    if (entries.containsKey(keyword)) return;

    var definition = text.substring(keyword.length);
    while (definition.isNotEmpty &&
        _keywordTerminators.contains(definition[0])) {
      definition = definition.substring(1);
    }
    entries[keyword] = definition.trim();
  }

  static const _keywordMaxLength = 24;
  static const _titleRecordMaxLength = 40;
  static const _sourceOpen = '《';
  static const _sourceClose = '》';
  static const _keywordTerminators = {
    '(',
    '（',
    ':',
    '：',
    ' ',
    '\u3000',
    '\n',
    '\r',
    '\t',
    _sourceOpen,
    '。',
    '！',
    '？',
    '；',
    '，',
  };

  static String _keywordFromText(String text) {
    final breaks = _keywordBreakOffsets(text);
    if (breaks.isNotEmpty) return text.substring(0, breaks.first);
    return text.length <= _keywordMaxLength
        ? text
        : text.substring(0, _keywordMaxLength);
  }

  /// key 可截斷的句讀/括號位置(不含該字符),最多到 [_keywordMaxLength]。
  static List<int> _keywordBreakOffsets(String text) {
    final limit = text.length < _keywordMaxLength
        ? text.length
        : _keywordMaxLength;
    final breaks = <int>[];
    for (var i = 1; i < limit; i++) {
      if (_keywordTerminators.contains(text[i])) breaks.add(i);
    }
    return breaks;
  }

  /// 傳記正文前後常帶全形空白與私人區裝飾字,它們不屬於 keyword。
  static String _trimDecoration(String text) {
    var start = 0;
    while (start < text.length && _isDecorationCode(text.codeUnitAt(start))) {
      start++;
    }
    var end = text.length;
    while (end > start && _isDecorationCode(text.codeUnitAt(end - 1))) {
      end--;
    }
    return text.substring(start, end);
  }

  static bool _isDecorationCode(int unit) =>
      unit == 0x20 ||
      unit == 0x09 ||
      unit == 0x0A ||
      unit == 0x0D ||
      unit == 0x3000 ||
      (unit >= 0xE000 && unit <= 0xF8FF);

  static int _readUint32(List<int> data, int offset) {
    return data[offset] |
        (data[offset + 1] << 8) |
        (data[offset + 2] << 16) |
        (data[offset + 3] << 24);
  }

  static String _decodeUtf16LE(List<int> bytes) {
    final codeUnits = <int>[];
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      codeUnits.add(bytes[i] | (bytes[i + 1] << 8));
    }
    return String.fromCharCodes(codeUnits);
  }

  Future<List<FodictEntry>> search(
    String baseDir,
    String query, {
    int maxResults = 50,
  }) async {
    if (query.trim().isEmpty) return [];

    final dicts = await getDictionaries(baseDir);
    final results = <FodictEntry>[];
    final lowerQuery = query.toLowerCase();

    for (final dict in dicts) {
      if (results.length >= maxResults) break;

      try {
        final parsed = await _loadDictionary(dict);
        final keys = parsed.keys;
        final lowerKeys = parsed.lowerKeys;

        for (var index = 0; index < keys.length; index++) {
          if (results.length >= maxResults) break;

          final keyword = keys[index];
          final definition = parsed.entries[keyword]!;
          if (!lowerKeys[index].contains(lowerQuery) &&
              !definition.contains(query) &&
              !definition.toLowerCase().contains(lowerQuery)) {
            continue;
          }
          results.add(
            FodictEntry(
              keyword: keyword,
              definition: definition,
              dictionaryName: dict.name,
              dictionaryId: dict.id,
            ),
          );
        }
      } catch (e) {
        continue;
      }
    }

    return results;
  }

  Future<Map<String, int>> countKeyMatches(
    String baseDir,
    List<String> candidates, {
    Set<String>? dictionaryIds,
  }) async {
    final dicts = await getDictionaries(baseDir);
    final filteredDicts = dictionaryIds != null
        ? dicts.where((d) => dictionaryIds.contains(d.id)).toList()
        : dicts;
    final allKeys = <String>{};
    for (final dict in filteredDicts) {
      try {
        final parsed = await _loadDictionary(dict);
        allKeys.addAll(parsed.keys);
      } catch (_) {}
    }
    // 小寫化只做一次,而不是「候選數 × 關鍵字數」次。
    final lowerKeys = [for (final key in allKeys) key.toLowerCase()];
    final counts = <String, int>{};
    for (final candidate in candidates) {
      var count = 0;
      final lowerCandidate = candidate.toLowerCase();
      for (final lowerKey in lowerKeys) {
        if (lowerKey.contains(lowerCandidate)) count++;
      }
      counts[candidate] = count;
    }
    return counts;
  }

  Future<List<FodictEntry>> searchByKey(
    String baseDir,
    String query, {
    int maxResults = 200,
    int maxResultsPerDictionary = 50,
  }) async {
    if (query.trim().isEmpty) return [];

    final dicts = await getDictionaries(baseDir);
    final results = <FodictEntry>[];
    final lowerQuery = query.toLowerCase();

    for (final dict in dicts) {
      if (results.length >= maxResults) break;
      try {
        final parsed = await _loadDictionary(dict);
        final keys = parsed.keys;
        final lowerKeys = parsed.lowerKeys;
        var dictResultCount = 0;
        for (var index = 0; index < keys.length; index++) {
          if (results.length >= maxResults) break;
          if (dictResultCount >= maxResultsPerDictionary) break;
          if (!lowerKeys[index].contains(lowerQuery)) continue;
          final keyword = keys[index];
          results.add(
            FodictEntry(
              keyword: keyword,
              definition: parsed.entries[keyword]!,
              dictionaryName: dict.name,
              dictionaryId: dict.id,
            ),
          );
          dictResultCount++;
        }
      } catch (e) {
        continue;
      }
      // 多部詞典之間讓出一幀,避免掃描串聯成不可中斷的長任務。
      await Future<void>.delayed(Duration.zero);
    }

    return results;
  }

  Future<FodictEntry?> lookupExact(String baseDir, String keyword) async {
    final dicts = await getDictionaries(baseDir);

    for (final dict in dicts) {
      try {
        final parsed = await _loadDictionary(dict);
        final definition = parsed.entries[keyword];
        if (definition != null) {
          return FodictEntry(
            keyword: keyword,
            definition: definition,
            dictionaryName: dict.name,
            dictionaryId: dict.id,
          );
        }
      } catch (e) {
        continue;
      }
    }

    return null;
  }

  void clearCache() {
    _cache.clear();
    _dictionaries = null;
  }
}
