import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

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
  final Map<String, Map<String, String>> _cache = {};

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
  };

  static const _assetDictionaries = [
    '012.weishi-j',
    '013.fajie-j',
    '014.famen-j',
  ];

  Future<List<FodictInfo>> getDictionaries(String baseDir) async {
    if (_dictionaries != null) return _dictionaries!;

    final dicts = <FodictInfo>[];

    for (final dictId in _assetDictionaries) {
      try {
        final data = await rootBundle.load('assets/fodict/$dictId/fodict.dat');
        dicts.add(FodictInfo(
          id: dictId,
          name: _dictionaryNames[dictId] ?? dictId,
          path: 'assets/fodict/$dictId',
          datSize: data.lengthInBytes,
          isAsset: true,
        ));
      } catch (e) {
        continue;
      }
    }

    final dir = Directory(baseDir);
    if (await dir.exists()) {
      await for (final entity in dir.list()) {
        if (entity is Directory) {
          final name = entity.uri.pathSegments[entity.uri.pathSegments.length - 2];
          if (_assetDictionaries.contains(name)) continue;
          
          final datFile = File('${entity.path}/fodict.dat');
          if (await datFile.exists()) {
            final stat = await datFile.stat();
            dicts.add(FodictInfo(
              id: name,
              name: _dictionaryNames[name] ?? name,
              path: entity.path,
              datSize: stat.size,
              isAsset: false,
            ));
          }
        }
      }
    }

    dicts.sort((a, b) => a.id.compareTo(b.id));
    _dictionaries = dicts;
    return dicts;
  }

  Future<Map<String, String>> _loadDictionary(FodictInfo dict) async {
    if (_cache.containsKey(dict.id)) return _cache[dict.id]!;

    Uint8List data;
    if (dict.isAsset) {
      final byteData = await rootBundle.load('${dict.path}/fodict.dat');
      data = byteData.buffer.asUint8List();
    } else {
      final datFile = File('${dict.path}/fodict.dat');
      data = await datFile.readAsBytes();
    }
    
    if (data.length < 64) return {};

    final byteData = ByteData.sublistView(data);
    
    final contentStart = byteData.getUint32(32, Endian.little);
    
    final entries = <String, String>{};
    var offset = contentStart;

    while (offset + 8 <= data.length) {
      final kwLen = _readUint32(data, offset);
      if (kwLen <= 0 || kwLen > 1000 || offset + 4 + kwLen > data.length) break;

      final kwBytes = data.sublist(offset + 4, offset + 4 + kwLen);
      final keyword = _decodeUtf16LE(kwBytes);

      final defLenOffset = offset + 4 + kwLen;
      if (defLenOffset + 4 > data.length) break;
      final defLen = _readUint32(data, defLenOffset);

      final defStart = defLenOffset + 4;
      if (defLen <= 0 || defLen > 1000000 || defStart + defLen > data.length) break;

      final defBytes = data.sublist(defStart, defStart + defLen);
      final definition = _decodeUtf16LE(defBytes);

      entries[keyword] = definition;
      offset = defStart + defLen;
    }

    _cache[dict.id] = entries;
    return entries;
  }

  int _readUint32(List<int> data, int offset) {
    return data[offset] |
        (data[offset + 1] << 8) |
        (data[offset + 2] << 16) |
        (data[offset + 3] << 24);
  }

  String _decodeUtf16LE(List<int> bytes) {
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
        final entries = await _loadDictionary(dict);

        for (final entry in entries.entries) {
          if (results.length >= maxResults) break;

          if (entry.key.contains(query) ||
              entry.key.toLowerCase().contains(lowerQuery) ||
              entry.value.contains(query) ||
              entry.value.toLowerCase().contains(lowerQuery)) {
            results.add(FodictEntry(
              keyword: entry.key,
              definition: entry.value,
              dictionaryName: dict.name,
              dictionaryId: dict.id,
            ));
          }
        }
      } catch (e) {
        continue;
      }
    }

    return results;
  }

  Future<FodictEntry?> lookupExact(String baseDir, String keyword) async {
    final dicts = await getDictionaries(baseDir);

    for (final dict in dicts) {
      try {
        final entries = await _loadDictionary(dict);
        if (entries.containsKey(keyword)) {
          return FodictEntry(
            keyword: keyword,
            definition: entries[keyword]!,
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
