import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xuefo/dictionary/fodict_service.dart';

/// 组裝「分類＋全文」兩段式 `fodict.dat`：
/// header(64) → 分類條 [kwLen][kw][0] → 全文條 [size][text]。
Uint8List buildSpecialFormatDat({
  required List<String> categories,
  required List<String> records,
}) {
  final bytes = BytesBuilder(copy: false);
  final header = Uint8List(64);
  header.buffer.asByteData().setUint32(32, header.length, Endian.little);
  bytes.add(header);

  void writeText(String value) {
    final encoded = utf16leBytes(value);
    bytes.add(uint32(encoded.length));
    bytes.add(encoded);
  }

  for (final category in categories) {
    writeText(category);
    bytes.add(uint32(0));
  }
  for (final record in records) {
    writeText(record);
  }
  return bytes.toBytes();
}

Uint8List uint32(int value) {
  final data = Uint8List(4)
    ..buffer.asByteData().setUint32(0, value, Endian.little);
  return data;
}

Uint8List utf16leBytes(String value) {
  final units = value.codeUnits;
  final data = Uint8List(units.length * 2);
  final view = data.buffer.asByteData();
  for (var i = 0; i < units.length; i++) {
    view.setUint16(i * 2, units[i], Endian.little);
  }
  return data;
}

void main() {
  test('全文式詞典以標題條作 key，正文作 definition', () {
    final data = buildSpecialFormatDat(
      categories: ['佛祖統紀'],
      records: [
        '南山律师道宣《佛祖历代通载》',
        '南山律师道宣。京兆钱氏。父吏部尚书申。母梦月轮贯怀而孕。',
        '智果（隋东都慧日道场）《续高僧传》卷三十',
        '\uE5E5\uE5E5释智果。会稽剡人。率素轻清慈物在性。',
      ],
    );

    final parsed = parseFodictData(data);
    expect(parsed.entries.keys, [
      '佛祖統紀',
      '南山律师道宣《佛祖历代通载》',
      '智果（隋东都慧日道场）《续高僧传》卷三十',
    ]);
    expect(parsed.entries['南山律师道宣《佛祖历代通载》'], startsWith('南山律师道宣。京兆钱氏。'));
    expect(parsed.entries['智果（隋东都慧日道场）《续高僧传》卷三十'], startsWith('释智果。会稽剡人。'));
  });

  test('没有标题条领头的正文以句读截出人名作 key', () {
    final data = buildSpecialFormatDat(
      categories: ['高僧传'],
      records: ['释慧远。本姓贾氏。雁门娄烦人也。弱而好书。'],
    );

    final parsed = parseFodictData(data);
    expect(parsed.entries.containsKey('释慧远'), isTrue);
    expect(parsed.entries['释慧远'], '本姓贾氏。雁门娄烦人也。弱而好书。');
  });

  test('同名条目延长 key 而不是互相覆盖', () {
    final data = buildSpecialFormatDat(
      categories: ['续高僧传'],
      records: ['释慧远。本姓贾氏。雁门楼烦人。', '释慧远。姓贾氏。雁门连云人。'],
    );

    final parsed = parseFodictData(data);
    expect(parsed.entries.keys.where((key) => key != '续高僧传').length, 2);
    expect(parsed.entries.keys, contains('释慧远'));
    expect(parsed.entries.keys, contains('释慧远。姓贾氏'));
  });

  test('key 不会长成整段传记', () {
    final biography = List.generate(400, (_) => '少出家清真务学诵经数百万言善解文义').join('。');
    final data = buildSpecialFormatDat(
      categories: ['神僧传'],
      records: ['佛图澄者。西域人也。本姓帛氏。$biography'],
    );

    final parsed = parseFodictData(data);
    final keyword = parsed.entries.keys.last;
    expect(keyword.length, lessThanOrEqualTo(24));
    expect(parsed.entries[keyword]!.length, greaterThan(1000));
  });

  // cbeta-fodict/ 是本地原始詞典庫，未入版本庫，缺失時跳過。
  final sourceRoot = Directory('cbeta-fodict/fodict');
  for (final dictionaryId in ['011.fjrwz-j', '018.chanzongyulu-j']) {
    final datFile = File('${sourceRoot.path}/$dictionaryId/fodict.dat');
    test(
      '$dictionaryId 解析出的 key 是条目名称',
      () {
        final parsed = parseFodictData(datFile.readAsBytesSync());
        expect(parsed.keys.where((key) => key.length > 24), isEmpty);
        expect(
          parsed.keys.where((key) => key.contains('八戒')),
          isEmpty,
          reason: '正文用詞不該成為 key',
        );
      },
      skip: datFile.existsSync() ? false : '需要本地 cbeta-fodict 詞典庫',
    );
  }

  final biographyDat = File('${sourceRoot.path}/011.fjrwz-j/fodict.dat');
  test(
    '佛教人物傳的 key 是人名與出處',
    () {
      final parsed = parseFodictData(biographyDat.readAsBytesSync());
      expect(parsed.length, greaterThan(2900));
      expect(parsed.entries.keys, contains('南山律师道宣《佛祖历代通载》'));
      expect(parsed.entries.keys, contains('智果（隋东都慧日道场）《续高僧传》卷三十'));
      expect(parsed.entries['智果（隋东都慧日道场）《续高僧传》卷三十'], startsWith('释智果。会稽剡人。'));
    },
    skip: biographyDat.existsSync() ? false : '需要本地 cbeta-fodict 詞典庫',
  );
}
