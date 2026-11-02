import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xuefo/scripture/models.dart';
import 'package:xuefo/scripture/parser.dart';
import 'package:xuefo/scripture/sidx_norm.dart';
import 'package:xuefo/scripture/sidx_store.dart';

/// 只用「原字」當候補的比對，簡繁展開在 `offline_scan_test.dart` 端到端測。
List<NormMatch> hitsIn(String source, String query) {
  final normed = normalizeScriptureSource(source);
  return hitsWith(normed.bytes, query);
}

/// 在已經排除夾注／卷題的索引正文上比對。
List<NormMatch> hitsWith(Uint8List bytes, String query) {
  final pattern = QueryPattern.fromSlotCandidates([
    for (final rune in normalizedQueryRunes(query)) <int>[rune],
  ]);
  final matches = <NormMatch>[];
  scanNormMatches(bytes, pattern, matches.add);
  return matches;
}

String normText(String source) {
  final normed = normalizeScriptureSource(source);
  return normed.normSlice(0, normed.byteLength);
}

void main() {
  test('索引側刪除空白與標點、ASCII 轉小寫', () {
    expect(normText('般若 波羅，蜜多\n心經　ABC。'), '般若波羅蜜多心經abc');
    expect(normText('　）、：？！【】《》―…．'), '');
  });

  test('正規化座標可以映回帶標點的原文', () {
    const source = '般若，波羅蜜多心經';
    final normed = normalizeScriptureSource(source);
    final match = hitsIn(source, '波羅蜜多').single;
    expect(normed.normSlice(match.byteStart, match.byteEnd), '波羅蜜多');
    expect(normed.sourceSlice(match.byteStart, match.byteEnd), '波羅蜜多');
    expect(normed.sourceStart(match.byteStart), source.indexOf('波羅蜜多'));
  });

  test('使用者有無輸入空格或標點都能匹配', () {
    for (final query in ['般若波羅蜜', '般若 波羅，蜜', '般　若波　羅蜜、']) {
      expect(hitsIn('般若波羅蜜多心經', query), hasLength(1), reason: query);
      expect(hitsIn('般若，波羅 蜜多心經', query), hasLength(1), reason: query);
    }
  });

  test('標點閉集的碼位數固定（改動會改變命中集合）', () {
    expect(sidxPunctuationCount, 191);
  });

  test('跨行匹配：命中橫跨兩行也能找到', () {
    const source = '般若波羅\n蜜多心經';
    final matches = hitsIn(source, '般若波羅蜜多');
    expect(matches, hasLength(1));
    final normed = normalizeScriptureSource(source);
    expect(
      normed.sourceSlice(matches.single.byteStart, matches.single.byteEnd),
      '般若波羅\n蜜多',
    );
  });

  test('重疊的命中也會被逐一記錄', () {
    expect(hitsIn('般若般若波羅蜜', '般若波羅蜜'), hasLength(1));
    expect(hitsIn('般若是般若', '般若'), hasLength(2));
  });

  test('sidx 序列化往返一致，含作品名與特殊字體區間', () {
    final volume = buildSidxVolume(
      work: 'T0001',
      juan: '1',
      sourceStamp: 7,
      lines: parseScriptureHtml(
        '<div id="body">'
        '<p class="juan">長阿含經卷第一</p>'
        '<p class="byline">東晉佛陀耶舍共譯</p>'
        '<span class="lb" id="T0001n0001_p0001a01"></span>'
        '<span class="t">如是我聞：</span>'
        '<span class="siddam" char="字" code="SD-A5A9"></span>'
        '</div>',
      ),
    );
    expect(volume.runs, hasLength(1));
    expect(volume.runs.single.reference, 'SD-A5A9');
    expect(volume.runs.single.family, ScriptureScriptFamily.siddam);
    final decoded = decodeSidx(encodeSidx(volume), work: 'T0001', juan: '1');
    expect(decoded, isNotNull);
    expect(decoded!.title, '長阿含經');
    expect(decoded.work, 'T0001');
    expect(decoded.juan, '1');
    expect(decoded.sourceStamp, volume.sourceStamp);
    expect(decoded.charSet, volume.charSet);
    expect(decoded.bytes, volume.bytes);
    expect(decoded.lines.length, volume.lines.length);
    for (var index = 0; index < volume.lines.length; index++) {
      expect(decoded.lines[index].byteOffset, volume.lines[index].byteOffset);
      expect(decoded.lines[index].byteLength, volume.lines[index].byteLength);
      expect(decoded.lines[index].srcOffset, volume.lines[index].srcOffset);
      expect(decoded.lines[index].linehead, volume.lines[index].linehead);
      expect(decoded.lines[index].role, volume.lines[index].role);
    }
    expect(decoded.runs.single.byteOffset, volume.runs.single.byteOffset);
    expect(decoded.runs.single.byteLength, volume.runs.single.byteLength);
    expect(decoded.runs.single.reference, 'SD-A5A9');
    expect(decoded.runs.single.family, ScriptureScriptFamily.siddam);
  });

  test('crc 或正規化版本不符時一律判為失效，由呼叫端重建', () {
    final volume = SidxVolume(
      work: 'T0001',
      juan: '1',
      title: '測試經',
      sourceStamp: 1,
      bytes: normalizeScriptureSource('般若波羅蜜多').bytes,
      lines: const [
        SidxLine(
          byteOffset: 0,
          byteLength: 9,
          srcOffset: 0,
          linehead: 'T0001_p0001a01',
          role: 0,
        ),
      ],
      runs: const [],
      charSet: {'般', '若'}.expand((text) => text.runes).toSet(),
    );
    final bytes = encodeSidx(volume);
    expect(decodeSidx(bytes, work: 'T0001', juan: '1'), isNotNull);
    final corrupted = Uint8List.fromList(bytes)..[bytes.length - 5] ^= 0xFF;
    expect(decodeSidx(corrupted, work: 'T0001', juan: '1'), isNull);
    final wrongVersion = Uint8List.fromList(bytes)..[6] = bytes[6] + 1;
    expect(decodeSidx(wrongVersion, work: 'T0001', juan: '1'), isNull);
    expect(
      decodeSidx(bytes.sublist(0, bytes.length - 8), work: 'T0001', juan: '1'),
      isNull,
    );
  });

  test('字符集跳卷過濾：完全無交集才跳過', () {
    final source = normalizeScriptureLines(
      parseScriptureHtml(
        '<div id="body">'
        '<span class="lb" id="T0001_p0001a01"></span>'
        '<span class="t">般若波羅蜜多</span>'
        '</div>',
      ),
    );
    final skip = SidxSkipInfo(sourceStamp: 2, charSet: source.charSet);
    Set<int> runes(String text) => text.runes.toSet();
    expect(skip.canSkip(runes('般')), isFalse);
    expect(skip.canSkip(runes('必')), isTrue);
    // 簡體輸入展開成「原字 ∪ 繁候選」後仍要落在字符集內，不會誤跳。
    expect(skip.canSkip({...runes('般'), ...runes('說')}), isFalse);
    expect(encodeRuneSet(source.charSet).length, lessThan(64));
    expect(decodeRuneSet(encodeRuneSet(source.charSet)), source.charSet);
  });

  test('校勘夾注不進索引，也不會與正文黏成新詞', () {
    final source = normalizeScriptureLines(
      parseScriptureHtml(
        '<div id="body">'
        '<p class="juan">測試經卷第一</p>'
        '<span class="lb" id="T0001_p0001a01"></span>'
        '<span class="t">般若<span class="inline-note">波羅</span>蜜多心經</span>'
        '</div>',
      ),
    );
    expect(
      source.normed.normSlice(0, source.normed.byteLength),
      '測試經卷第一般若蜜多心經',
    );
    expect(hitsWith(source.normed.bytes, '波羅'), isEmpty);
    expect(hitsWith(source.normed.bytes, '般若波羅'), isEmpty);
    expect(hitsWith(source.normed.bytes, '般若蜜多'), hasLength(1));
  });

  test('卷首經號提示行與作譯者不進索引，卷題仍可搜尋', () {
    final source = normalizeScriptureLines(
      parseScriptureHtml(
        '<div id="body">'
        '<p>No. 1092 [cf. Nos. 1093-1099, 901(Fasc. 5)]</p>'
        '<p class="juan">佛說心經卷第一</p>'
        '<p class="byline">唐玄奘譯</p>'
        '<span class="lb" id="T0001_p0001a01"></span>'
        '<span class="t">色即是空空即是色</span>'
        '</div>',
      ),
    );
    expect(
      source.normed.normSlice(0, source.normed.byteLength),
      '佛說心經卷第一色即是空空即是色',
    );
    expect(source.title, '佛說心經');
    expect(source.records.map((line) => line.linehead), ['', 'T0001_p0001a01']);
    expect(hitsWith(source.normed.bytes, '佛說心經卷第一'), hasLength(1));
    expect(hitsWith(source.normed.bytes, '玄奘'), isEmpty);
  });

  test('行定位表把命中換算回行號', () {
    final source = normalizeScriptureLines(
      parseScriptureHtml(
        '<div id="body">'
        '<p class="juan">測試經卷第一</p>'
        '<span class="lb" id="T0001_p0001a01"></span>'
        '<span class="t">如是我聞一時</span>'
        '<span class="lb" id="T0001_p0001a02"></span>'
        '<span class="t">佛在王舍城</span>'
        '</div>',
      ),
    );
    final volume = SidxVolume(
      work: 'T0001',
      juan: '1',
      title: '測試經',
      sourceStamp: 0,
      bytes: source.normed.bytes,
      lines: source.records,
      runs: const [],
      charSet: source.charSet,
    );
    List<String> lineheadsFor(String query) => [
      for (final match in hitsWith(volume.bytes, query))
        volume.lineAt(match.byteStart)?.linehead ?? '',
    ];
    expect(lineheadsFor('如是我聞'), ['T0001_p0001a01']);
    expect(lineheadsFor('王舍城'), ['T0001_p0001a02']);
  });

  test('跳過區間重疊時先合併，不會把正文一併跳掉', () {
    final merged = mergeSourceRanges([
      Int32List.fromList(<int>[10, 20]),
      Int32List.fromList(<int>[0, 12]),
      Int32List.fromList(<int>[30, 35]),
    ], 40);
    expect(merged.map((range) => <int>[range[0], range[1]]), [
      [0, 20],
      [30, 35],
    ]);
  });

  test('經卷檔案變動後戳記改變，舊索引判為失效', () async {
    final directory = await Directory.systemTemp.createTemp('sidx_stamp');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/T0001-1.json');
    await file.writeAsString('{"a":1}');
    final first = await sidxSourceStamp(file.path);
    expect(first, isNotNull);
    expect(await sidxSourceStamp(file.path), first);
    await file.writeAsString('{"a":2,"b":3}');
    expect(await sidxSourceStamp(file.path), isNot(first));
    expect(await sidxSourceStamp('${directory.path}/missing.json'), isNull);
  });
}
