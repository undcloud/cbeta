import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xuefo/dictionary/fodict_key_index.dart';
import 'package:xuefo/dictionary/fodict_service.dart';

Uint8List _uint32(int value) {
  final data = Uint8List(4)
    ..buffer.asByteData().setUint32(0, value, Endian.little);
  return data;
}

Uint8List _utf16le(String value) {
  final units = value.codeUnits;
  final data = Uint8List(units.length * 2);
  final view = data.buffer.asByteData();
  for (var i = 0; i < units.length; i++) {
    view.setUint16(i * 2, units[i], Endian.little);
  }
  return data;
}

/// 組裝標準格式 `fodict.dat`：header(64) → [kwLen][kw][defLen][def] 重複。
Uint8List buildStandardFormatDat(Map<String, String> entries) {
  final bytes = BytesBuilder(copy: false);
  final header = Uint8List(64);
  header.buffer.asByteData().setUint32(32, header.length, Endian.little);
  bytes.add(header);
  for (final entry in entries.entries) {
    final keyword = _utf16le(entry.key);
    bytes.add(_uint32(keyword.length));
    bytes.add(keyword);
    final definition = _utf16le(entry.value);
    bytes.add(_uint32(definition.length));
    bytes.add(definition);
  }
  return bytes.toBytes();
}

void main() {
  const dictA = '901.test-a';
  const dictB = '902.test-b';
  final service = FodictService();
  late Directory baseDir;

  void writeDictionary(String id, Map<String, String> entries) {
    final directory = Directory('${baseDir.path}/$id')..createSync();
    File(
      '${directory.path}/fodict.dat',
    ).writeAsBytesSync(buildStandardFormatDat(entries));
  }

  setUp(() {
    baseDir = Directory.systemTemp.createTempSync('fodict_keys_test');
    service.clearCache();
    debugFodictKeyParses = 0;
    debugFodictFullDictionaryLoads = 0;
  });

  tearDown(() {
    service.clearCache();
    try {
      baseDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('key 索引寫出後原樣讀回，戳記不符或被截斷都判為不存在', () {
    final index = FodictKeyIndex(
      lowerKeys: ['般若', '波羅蜜多', 'buddha', '甲\n乙'],
      sourceStamp: 4242,
    );
    final bytes = encodeFodictKeys(index);

    expect(decodeFodictKeys(bytes, sourceStamp: 4242), index.lowerKeys);
    expect(
      decodeFodictKeys(bytes, sourceStamp: 4243),
      isNull,
      reason: '詞典換了版本，舊 sidecar 不能繼續用',
    );
    expect(
      decodeFodictKeys(bytes.sublist(0, bytes.length - 5), sourceStamp: 4242),
      isNull,
      reason: '截斷的檔案不能解出半條 key',
    );
  });

  test('parseFodictKeys 與整本解析抽出同一批 key', () {
    final data = buildStandardFormatDat({'般若': 'prajñā', 'Buddha': '覺者'});
    expect(
      parseFodictKeys(data),
      parseFodictData(data).lowerKeys,
      reason: '規則分叉會讓候選統計和字典分區對不上',
    );
  });

  test('同一術語在兩部詞典各收一次算 2 筆，計數單位是條目', () async {
    writeDictionary(dictA, {'般若': '智慧', '波羅蜜多': '到彼岸'});
    writeDictionary(dictB, {'般若': 'perfection'});

    final counts = await service.countKeyMatches(
      baseDir.path,
      ['般若', '波羅蜜多', '心經'],
      dictionaryIds: {dictA, dictB},
    );

    expect(counts['般若'], 2);
    expect(counts['波羅蜜多'], 1);
    expect(counts['心經'], 0);
  });

  test('候選計數跳過 001–028 的簡體 key 詞典', () async {
    const simplifiedDict = '001.test-simplified';
    const traditionalDict = '030.test-traditional';
    writeDictionary(simplifiedDict, {'般若': '智慧'});
    writeDictionary(traditionalDict, {'般若': 'prajñā'});

    final counts = await service.countKeyMatches(
      baseDir.path,
      ['般若'],
      dictionaryIds: {simplifiedDict, traditionalDict},
    );

    expect(counts['般若'], 1, reason: '001 的簡體 key 不計入，只算 030');
  });

  test('大小寫不影響 key 命中', () async {
    writeDictionary(dictA, {'Buddha': '覺者'});

    final counts = await service.countKeyMatches(
      baseDir.path,
      ['buddha', 'BUDDHA', 'bodhi'],
      dictionaryIds: {dictA},
    );

    expect(counts['buddha'], 1);
    expect(counts['BUDDHA'], 1);
    expect(counts['bodhi'], 0);
  });

  test('統計只要 key：不載入釋義，重啟後靠 sidecar 也不再解析 .dat', () async {
    writeDictionary(dictA, {'般若': '智慧'});
    writeDictionary(dictB, {'波羅蜜多': '到彼岸'});

    await service.countKeyMatches(
      baseDir.path,
      ['般若'],
      dictionaryIds: {dictA, dictB},
    );
    expect(debugFodictKeyParses, 2, reason: '首次各建一次 sidecar');
    expect(debugFodictFullDictionaryLoads, 0, reason: '統計不該把含釋義的整本詞典搬進快取');

    // 清掉內存快取，模擬 App 重啟：此時只剩 `.keys` 可用。
    service.clearCache();
    debugFodictKeyParses = 0;

    final counts = await service.countKeyMatches(
      baseDir.path,
      ['般若', '波羅蜜多'],
      dictionaryIds: {dictA, dictB},
    );
    expect(debugFodictKeyParses, 0, reason: 'sidecar 命中就不該再讀 .dat');
    expect(counts['般若'], 1);
    expect(counts['波羅蜜多'], 1);
  });

  test('sidecar 損毀時回退到解析重建，計數不變', () async {
    writeDictionary(dictA, {'般若': '智慧'});
    writeDictionary(dictB, {'波羅蜜多': '到彼岸'});
    await service.countKeyMatches(
      baseDir.path,
      ['般若', '波羅蜜多'],
      dictionaryIds: {dictA, dictB},
    );

    service.clearCache();
    debugFodictKeyParses = 0;
    File(
      fodictKeyStore.pathFor(baseDir: baseDir.path, id: dictA)!,
    ).writeAsBytesSync([1, 2, 3, 4, 5]);

    final counts = await service.countKeyMatches(
      baseDir.path,
      ['般若', '波羅蜜多'],
      dictionaryIds: {dictA, dictB},
    );

    expect(counts['般若'], 1);
    expect(counts['波羅蜜多'], 1);
    expect(debugFodictKeyParses, 1, reason: '只有讀回失敗的那部需要重建');
  });

  test('searchByKey 先看 key 索引：沒有命中的詞典不解析釋義', () async {
    writeDictionary(dictA, {'獨有測試詞': '第一'});
    writeDictionary(dictB, {'另一個詞': '第二'});

    final results = await service.searchByKey(baseDir.path, '獨有測試詞');

    expect(results.map((entry) => entry.dictionaryId), [dictA]);
    expect(
      debugFodictFullDictionaryLoads,
      1,
      reason: 'dictB 的 key 沒有命中，不該把整本釋義搬進快取',
    );
  });

  test('詞典刪除後重新列目錄會清掉孤兒 sidecar', () async {
    writeDictionary(dictA, {'般若': '智慧'});
    writeDictionary(dictB, {'波羅蜜多': '到彼岸'});
    await service.countKeyMatches(
      baseDir.path,
      ['般若'],
      dictionaryIds: {dictA, dictB},
    );
    final orphan = File(
      fodictKeyStore.pathFor(baseDir: baseDir.path, id: dictA)!,
    );
    expect(orphan.existsSync(), isTrue);

    // 對齊 deleteInstalled：詞典目錄整包消失，sidecar 卻還在。
    Directory('${baseDir.path}/$dictA').deleteSync(recursive: true);
    service.clearCache();
    await service.getDictionaries(baseDir.path);

    expect(orphan.existsSync(), isFalse);
    expect(
      File(
        fodictKeyStore.pathFor(baseDir: baseDir.path, id: dictB)!,
      ).existsSync(),
      isTrue,
      reason: '仍裝著的詞典不能被誤刪',
    );
  });
}
