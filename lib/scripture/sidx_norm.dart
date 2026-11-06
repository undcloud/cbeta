/// 離線全文索引的正規化與匹配核心。
///
/// 經文本身是繁體，因此**索引側不做任何簡繁轉換**（繁→簡有損、簡→繁多義）；
/// 多義只在查詢側展開成逐字候選集合，一次掃描完成，不會掃三遍。
///
/// 規則寫死并由 [sidxNormVersion] 版本化：
/// NFC → 刪除所有空白（含 U+3000 與換行）→ 刪除標點 → 繁體原樣 → ASCII 轉小寫。
/// 查詢側套用同一個函數，所以使用者有無輸入空格或標點都能匹配。
///
/// 關於 NFC：CBETA 的 HTML 已是預複合形式，被刪除的空白與標點都是單碼位字元，
/// 不會因合成而改變結果，因此 v1 的正規化對合成序列刻意保持原樣；索引與查詢
/// 共用同一個函數，兩側永遠一致。真要改成完整的 NFC，只要遞增
/// [sidxNormVersion]，所有 `.sidx` 會自動重建。
library;

import 'dart:convert';
import 'dart:typed_data';

const int sidxFormatVersion = 1;
// v2: 卷題納入索引（正文次級標題）。
const int sidxNormVersion = 2;

/// 正規化實際套用過的步驟，寫進索引標頭；與標頭不符就要重建。
const int sidxFlagDropWhitespace = 0x01;
const int sidxFlagDropPunctuation = 0x02;
const int sidxFlagLowerAscii = 0x04;
const int sidxFlagsApplied =
    sidxFlagDropWhitespace | sidxFlagDropPunctuation | sidxFlagLowerAscii;

const int _classWhitespace = 0x01;
const int _classPunctuation = 0x02;
const int _classAsciiUpper = 0x04;

final Uint8List _charClass = _buildCharClass();

Uint8List _buildCharClass() {
  final table = Uint8List(0x10000);
  void fill(List<(int, int)> ranges, int bit) {
    for (final (start, end) in ranges) {
      for (var code = start; code <= end; code++) {
        table[code] |= bit;
      }
    }
  }

  fill(_whitespaceRanges, _classWhitespace);
  fill(_punctuationRanges, _classPunctuation);
  fill(const [(0x41, 0x5A)], _classAsciiUpper);
  return table;
}

/// 空白：所有排版空白與全形空格。
const List<(int, int)> _whitespaceRanges = <(int, int)>[
  (0x09, 0x0D),
  (0x20, 0x20),
  (0x85, 0x85),
  (0xA0, 0xA0),
  (0x1680, 0x1680),
  (0x2000, 0x200B),
  (0x2028, 0x2029),
  (0x202F, 0x202F),
  (0x205F, 0x205F),
  (0x3000, 0x3000),
];

/// 標點：**固定閉集**，刻意不用 Unicode P 類通配，避免日後改動悄悄改變命中集合。
const List<(int, int)> _punctuationRanges = <(int, int)>[
  (0x21, 0x2F),
  (0x3A, 0x40),
  (0x5B, 0x60),
  (0x7B, 0x7E),
  (0xA1, 0xA1),
  (0xB7, 0xB7),
  (0xBF, 0xBF),
  (0x2010, 0x2026),
  (0x2039, 0x203A),
  (0x3001, 0x3003),
  (0x3008, 0x3011),
  (0x3014, 0x301B),
  (0x303E, 0x303F),
  (0x30FB, 0x30FB),
  (0xFE10, 0xFE19),
  (0xFE30, 0xFE52),
  (0xFE54, 0xFE66),
  (0xFE68, 0xFE6B),
  (0xFF01, 0xFF0F),
  (0xFF1A, 0xFF20),
  (0xFF3B, 0xFF40),
  (0xFF5B, 0xFF65),
];

/// 標點閉集的碼位總數；變更清單時這條測試會先擋住（命中集合隨之改變）。
int get sidxPunctuationCount =>
    _punctuationRanges.fold(0, (s, r) => s + r.$2 - r.$1 + 1);

/// 逐字元分類只查这张 64 KB 表；掃描每卷兩萬字,不能每字跑正則。
int _classOf(int rune) => rune < 0x10000 ? _charClass[rune] : 0;

int utf8ByteLength(int rune) {
  if (rune < 0x80) return 1;
  if (rune < 0x800) return 2;
  if (rune < 0x10000) return 3;
  return 4;
}

/// 正規化後的一份來源文字。
class NormedSource {
  const NormedSource({
    required this.source,
    required this.bytes,
    required this.toSource,
    required this.flags,
  });

  /// 正規化前的來源文字（含標點）；摘要與位移換算都以它為準。
  final String source;

  /// 正規化正文的 UTF-8 位元組。
  final Uint8List bytes;

  /// 每個正規化位移對應到來源字串的 UTF-16 位移；長度為位元組數 + 1。
  ///
  /// 匹配發生在無標點、無空白的座標系裡，摘要與 `sourceOffset` 都靠这张
  /// 表映回帶標點的原文，所以索引不需要保留可讀性。
  final Int32List toSource;

  final int flags;

  int get byteLength => bytes.length;

  int sourceStart(int byteOffset) =>
      byteOffset >= byteLength ? toSource[byteLength] : toSource[byteOffset];

  int sourceEnd(int byteEnd) =>
      byteEnd >= byteLength ? toSource[byteLength] : toSource[byteEnd];

  /// 原文（含標點）中對應的片段。
  String sourceSlice(int byteStart, int byteEnd) =>
      source.substring(sourceStart(byteStart), sourceEnd(byteEnd));

  /// 正規化座標系中的片段（無標點），供測試與跳卷過濾除錯。
  String normSlice(int byteStart, int byteEnd) => utf8.decode(
    bytes.sublist(byteStart, byteEnd > byteLength ? byteLength : byteEnd),
    allowMalformed: true,
  );
}

/// 把來源文字正規化成可供索引比對的 UTF-8 位元組串。
///
/// [skipRanges] 是來源空間中要整段跳過的 `[start, end)` 位移（校勘夾注靠它
/// 排除，否則注文會與無標點的正文無縫黏成新詞）。[runeSink] 用來收集出現過
/// 的碼位，寫進每卷的精確字符集。
NormedSource normalizeScriptureSource(
  String source, {
  List<Int32List> skipRanges = const [],
  Set<int>? runeSink,
}) {
  final builder = BytesBuilder(copy: false);
  final starts = <int>[];
  var skipIndex = 0;
  var skipEnd = 0;
  var index = 0;
  final length = source.length;
  while (index < length) {
    while (skipIndex < skipRanges.length && skipRanges[skipIndex][0] <= index) {
      skipEnd = skipRanges[skipIndex][1];
      skipIndex += 1;
    }
    final unit = source.codeUnitAt(index);
    final int rune;
    int width;
    if (_isHighSurrogate(unit) &&
        index + 1 < length &&
        _isLowSurrogate(source.codeUnitAt(index + 1))) {
      rune =
          0x10000 +
          ((unit - 0xD800) << 10) +
          (source.codeUnitAt(index + 1) - 0xDC00);
      width = 2;
    } else {
      rune = unit;
      width = 1;
    }
    final next = index + width;
    if (next <= skipEnd) {
      index = next;
      continue;
    }
    final klass = _classOf(rune);
    if (klass & (_classWhitespace | _classPunctuation) != 0) {
      index = next;
      continue;
    }
    final kept = klass & _classAsciiUpper != 0 ? rune + 0x20 : rune;
    final byteWidth = utf8ByteLength(kept);
    _appendUtf8(builder, kept);
    runeSink?.add(kept);
    for (var step = 0; step < byteWidth; step++) {
      starts.add(index);
    }
    index = next;
  }
  final toSource = Int32List(starts.length + 1);
  for (var offset = 0; offset < starts.length; offset++) {
    toSource[offset] = starts[offset];
  }
  toSource[starts.length] = length;
  return NormedSource(
    source: source,
    bytes: Uint8List.fromList(builder.takeBytes()),
    toSource: toSource,
    flags: sidxFlagsApplied,
  );
}

bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;
bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;

/// 來源位移 → 正規化位元組位移（二分搜尋單調的 [NormedSource.toSource]）。
///
/// 行定位表與悉曇區間都以來源位移計算，落地到索引時一律換算成正規化座標系，
/// 兩者才能用同一張表對映回行號與原文。
int byteOffsetForSource(NormedSource normed, int sourceOffset) {
  var low = 0;
  var high = normed.byteLength;
  while (low < high) {
    final middle = (low + high) >> 1;
    if (normed.toSource[middle] < sourceOffset) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  return low;
}

/// 把來源空間中要跳過的區間排序並合併；重疊的區間（整行排除裡面包著夾注）
/// 若不合併，會把跳過範圍延續到相鄰行上，吃掉本該進索引的正文。
List<Int32List> mergeSourceRanges(List<Int32List> ranges, int limit) {
  if (ranges.length < 2) return ranges;
  final sorted = ranges.toList()
    ..sort((left, right) => left[0].compareTo(right[0]));
  final merged = <Int32List>[
    Int32List.fromList(<int>[
      sorted.first[0].clamp(0, limit),
      sorted.first[1].clamp(0, limit),
    ]),
  ];
  for (final range in sorted.skip(1)) {
    final start = range[0].clamp(0, limit);
    final end = range[1].clamp(0, limit);
    final last = merged.last;
    if (start <= last[1]) {
      if (end > last[1]) last[1] = end;
      continue;
    }
    merged.add(Int32List.fromList(<int>[start, end]));
  }
  return merged;
}

void _appendUtf8(BytesBuilder builder, int rune) {
  if (rune < 0x80) {
    builder.addByte(rune);
  } else if (rune < 0x800) {
    builder
      ..addByte(0xC0 | (rune >> 6))
      ..addByte(0x80 | (rune & 0x3F));
  } else if (rune < 0x10000) {
    builder
      ..addByte(0xE0 | (rune >> 12))
      ..addByte(0x80 | ((rune >> 6) & 0x3F))
      ..addByte(0x80 | (rune & 0x3F));
  } else {
    builder
      ..addByte(0xF0 | (rune >> 18))
      ..addByte(0x80 | ((rune >> 12) & 0x3F))
      ..addByte(0x80 | ((rune >> 6) & 0x3F))
      ..addByte(0x80 | (rune & 0x3F));
  }
}

/// 一次正規化查詢；[slots] 是每個槽位可接受的候選碼位（至少一個）。
class QueryPattern {
  const QueryPattern._({
    required this.slots,
    required this.slotBytes,
    required this.anchorSlot,
    required this.singleBytes,
  });

  final List<Int32List> slots;

  /// 每個槽位、每個候選的 UTF-8 位元組。
  final List<List<Uint8List>> slotBytes;

  /// 候選最少的槽位；多位元組模式以它為 BMH 錨點。
  final int anchorSlot;

  /// 所有槽位都只有一個候選時的完整位元組模式，否則 null（改走錨點驗證）。
  final Uint8List? singleBytes;

  int get slotCount => slots.length;

  bool get isBlank => slots.isEmpty;

  /// 由「原字 ∪ 簡→繁候選」的逐字集合構造。
  factory QueryPattern.fromSlotCandidates(List<List<int>> candidates) {
    final slots = <Int32List>[];
    final slotBytes = <List<Uint8List>>[];
    for (final candidate in candidates) {
      final unique = <int>[];
      final encoded = <Uint8List>[];
      for (final rune in candidate) {
        if (unique.contains(rune)) continue;
        unique.add(rune);
        encoded.add(Uint8List.fromList(_encodeUtf8(rune)));
      }
      if (unique.isEmpty) continue;
      slots.add(Int32List.fromList(unique));
      slotBytes.add(encoded);
    }
    if (slots.isEmpty) {
      return QueryPattern._(
        slots: const [],
        slotBytes: const [],
        anchorSlot: 0,
        singleBytes: null,
      );
    }
    var anchor = 0;
    for (var index = 1; index < slots.length; index++) {
      final better =
          slots[index].length < slots[anchor].length ||
          (slots[index].length == slots[anchor].length &&
              slotBytes[index].first.length > slotBytes[anchor].first.length);
      if (better) anchor = index;
    }
    Uint8List? single;
    var isSingle = true;
    final buffer = BytesBuilder(copy: false);
    for (final bytes in slotBytes) {
      if (bytes.length != 1) {
        isSingle = false;
        break;
      }
      buffer.add(bytes.single);
    }
    if (isSingle) single = Uint8List.fromList(buffer.takeBytes());
    return QueryPattern._(
      slots: slots,
      slotBytes: slotBytes,
      anchorSlot: anchor,
      singleBytes: single,
    );
  }
}

List<int> _encodeUtf8(int rune) => utf8.encode(String.fromCharCode(rune));

/// 一處命中：正規化座標系中的位元組區間。
class NormMatch {
  const NormMatch(this.byteStart, this.byteLength);

  final int byteStart;
  final int byteLength;

  int get byteEnd => byteStart + byteLength;
}

/// 在正規化位元組串中找出所有命中（含重疊）。
///
/// 全部槽位唯一時就是單純的整串 BMH；有多義候補時以候補最少的槽位當錨點，
/// 命中後只向左、右各解碼一小段視窗，多義字不會讓掃描退化成逐字元比對。
void scanNormMatches(
  Uint8List text,
  QueryPattern pattern,
  void Function(NormMatch match) onMatch,
) {
  if (pattern.isBlank || text.isEmpty) return;
  final single = pattern.singleBytes;
  if (single != null) {
    _scanBytes(text, single, onMatch);
    return;
  }
  final anchor = pattern.anchorSlot;
  for (final candidate in pattern.slotBytes[anchor]) {
    _scanBytes(text, candidate, (match) {
      final anchorStart = match.byteStart;
      var right = anchorStart + candidate.length;
      for (var slot = anchor + 1; slot < pattern.slotCount; slot++) {
        final consumed = _consumeForward(text, right, pattern.slotBytes[slot]);
        if (consumed < 0) return;
        right = consumed;
      }
      var left = anchorStart;
      for (var slot = anchor - 1; slot >= 0; slot--) {
        final produced = _consumeBackward(text, left, pattern.slotBytes[slot]);
        if (produced < 0) return;
        left = produced;
      }
      onMatch(NormMatch(left, right - left));
    });
  }
}

/// 從 [offset] 起依序嘗試候補編碼，回傳消耗後的位移；不符回傳 -1。
int _consumeForward(Uint8List text, int offset, List<Uint8List> candidates) {
  for (final candidate in candidates) {
    if (offset + candidate.length > text.length) continue;
    if (_bytesAt(text, offset, candidate)) return offset + candidate.length;
  }
  return -1;
}

/// 向左倒著比對候補編碼，回傳新的左邊界；不符回傳 -1。
int _consumeBackward(Uint8List text, int limit, List<Uint8List> candidates) {
  for (final candidate in candidates) {
    final start = limit - candidate.length;
    if (start < 0) continue;
    if (_bytesAt(text, start, candidate)) return start;
  }
  return -1;
}

bool _bytesAt(Uint8List text, int offset, Uint8List bytes) {
  for (var index = 0; index < bytes.length; index++) {
    if (text[offset + index] != bytes[index]) return false;
  }
  return true;
}

/// Boyer–Moore–Horspool；命中後只前進一個字節，讓重疊的詞也被統計到。
void _scanBytes(
  Uint8List text,
  Uint8List needle,
  void Function(NormMatch match) onMatch,
) {
  final length = needle.length;
  if (length == 0 || text.length < length) return;
  // Uint8List 會在超長關鍵字上溢位，位移用 16 位元。
  final skip = Uint16List(256)..fillRange(0, 256, length);
  for (var index = 0; index < length - 1; index++) {
    skip[needle[index]] = length - 1 - index;
  }
  final lastByte = needle[length - 1];
  var window = 0;
  while (window + length <= text.length) {
    final tail = text[window + length - 1];
    // 先比最後一個字節（多數窗口在這裡就被排除），相符才做完整比對。
    if (tail == lastByte && _bytesAt(text, window, needle)) {
      onMatch(NormMatch(window, length));
      window += 1;
      continue;
    }
    // 表中的位移取自 0..length-2，至少為 1，不會停滯。
    window += skip[tail];
  }
}

/// 精確字符集：排序後的碼位差值 + LEB128，一卷約 1.3 KB。
Uint8List encodeRuneSet(Iterable<int> runes) {
  final sorted = runes.toSet().toList()..sort();
  final builder = BytesBuilder(copy: false);
  var previous = 0;
  for (final rune in sorted) {
    var delta = rune - previous;
    previous = rune;
    while (delta >= 0x80) {
      builder.addByte((delta & 0x7F) | 0x80);
      delta >>= 7;
    }
    builder.addByte(delta);
  }
  return Uint8List.fromList(builder.takeBytes());
}

Set<int> decodeRuneSet(Uint8List bytes) {
  final runes = <int>{};
  var rune = 0;
  var value = 0;
  var shift = 0;
  for (final byte in bytes) {
    value += (byte & 0x7F) << shift;
    if (byte & 0x80 == 0) {
      rune += value;
      runes.add(rune);
      value = 0;
      shift = 0;
    } else {
      shift += 7;
    }
  }
  return runes;
}

/// 查詢字串的正規化結果碼位（未展開簡繁候補）。
List<int> normalizedQueryRunes(String query) {
  final normed = normalizeScriptureSource(query);
  if (normed.byteLength == 0) return const [];
  return utf8.decode(normed.bytes, allowMalformed: true).runes.toList();
}
