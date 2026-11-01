import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';

import 'models.dart';
import 'sidx_norm.dart';
import 'source_text.dart';

/// 一卷的搜尋用表示（`.sidx`）：正規化正文 + 行定位表 + 特殊字體區間 + 字符集。
///
/// 它是 `.json` 經卷的**派生物**，可以隨時刪除並重建；`.json` 才是真相源。
class SidxVolume {
  const SidxVolume({
    required this.work,
    required this.juan,
    required this.title,
    required this.sourceStamp,
    required this.bytes,
    required this.lines,
    required this.runs,
    required this.charSet,
  });

  final String work;
  final String juan;

  /// 作品名（卷題去掉「卷第一」尾綴）；第一階段不解析 HTML 也能顯示經名。
  final String title;

  /// 來源經卷檔案的「大小 + 修改時間」摘要（見 [sidxSourceStamp]）。
  ///
  /// 經卷 `.json` 是真相源、`.sidx` 是派生物；這枚戳記讓掃描只要一次 `stat`
  /// 就能判索引新舊，不必把 25 KB 正文讀進來比對內容版本。
  final int sourceStamp;
  final Uint8List bytes;
  final List<SidxLine> lines;
  final List<SidxRun> runs;
  final Set<int> charSet;

  int get byteLength => bytes.length;

  /// 正規化位元組位移 → 所在行；命中靠它換算成行號。
  SidxLine? lineAt(int byteOffset) {
    if (lines.isEmpty) return null;
    var low = 0;
    var high = lines.length - 1;
    while (low < high) {
      final middle = (low + high + 1) >> 1;
      if (lines[middle].byteOffset <= byteOffset) {
        low = middle;
      } else {
        high = middle - 1;
      }
    }
    return lines[low].byteOffset <= byteOffset ? lines[low] : null;
  }
}

/// 行定位表的一列。`srcOffset` 是閱讀器 layout 用的整卷來源位移。
class SidxLine {
  const SidxLine({
    required this.byteOffset,
    required this.byteLength,
    required this.srcOffset,
    required this.linehead,
    required this.role,
  });

  final int byteOffset;
  final int byteLength;
  final int srcOffset;
  final String linehead;
  final int role;

  int get byteEnd => byteOffset + byteLength;
}

/// 悉曇／蘭札字區間；`reference` 是 CBETA 的 `code`（例如 `SD-A5A9`）。
///
/// 正規化正文裡保留形似漢字殼字，別名層以後只加不改，不必重建索引。
class SidxRun {
  const SidxRun({
    required this.byteOffset,
    required this.byteLength,
    required this.reference,
    required this.family,
  });

  final int byteOffset;
  final int byteLength;
  final String reference;
  final ScriptureScriptFamily family;
}

/// 只讀標頭與字符集就能決定「這一卷跳不跳」，不必把 25 KB 正文讀進來。
class SidxSkipInfo {
  const SidxSkipInfo({required this.charSet, required this.sourceStamp});

  final Set<int> charSet;

  /// 建立索引時經卷檔案的戳記；與現況不符即為過期索引。
  final int sourceStamp;

  /// 查詢候補碼位與該卷字符集完全無交集時，這一卷不可能有命中。
  ///
  /// 字符集是繁體側、且取全部候補的並集，所以簡體輸入不會被誤跳。
  bool canSkip(Set<int> queryRunes) {
    for (final rune in queryRunes) {
      if (charSet.contains(rune)) return false;
    }
    return true;
  }
}

const _magic = <int>[0x43, 0x53, 0x44, 0x58]; // CSDX
const _headerSize = 64;
const _lineRecordSize = 20;
const _runRecordSize = 16;
const _endian = Endian.little;

/// `.sidx` 的讀寫；檔名與經卷一致（`{work}-{juan}.sidx`），放在 `cbeta_sidx/`。
class ScriptureIndexStore {
  ScriptureIndexStore({Future<Directory> Function()? directoryProvider})
    : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directoryProvider;

  Future<String> directoryPath() async {
    final support = await _directoryProvider();
    final directory = Directory(
      '${support.path}${Platform.pathSeparator}cbeta_sidx',
    );
    await directory.create(recursive: true);
    return directory.path;
  }

  /// 索引檔一律放在 `cbeta_sidx/`（與經卷 `cbeta_scripture/` 同層），讀寫刪
  /// 共用同一個推導規則；網頁版沒有檔案系統時回傳 null。
  Future<String?> pathFor({required String work, required String juan}) async {
    if (kIsWeb) return null;
    final directory = await directoryPath();
    return '$directory${Platform.pathSeparator}$work-$juan.sidx';
  }

  Future<void> write(SidxVolume volume) async {
    final path = await pathFor(work: volume.work, juan: volume.juan);
    if (path == null) return;
    await File(path).writeAsBytes(encodeSidx(volume), flush: true);
  }

  /// 讀出可用的索引；戳記不符、損毀或不存在時回傳 null（呼叫端重建）。
  Future<SidxVolume?> readAt({
    required String work,
    required String juan,
    required int sourceStamp,
  }) async {
    final path = await pathFor(work: work, juan: juan);
    if (path == null) return null;
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      debugSidxBodyReads += 1;
      final volume = decodeSidx(
        await file.readAsBytes(),
        work: work,
        juan: juan,
      );
      if (volume == null || volume.sourceStamp != sourceStamp) return null;
      return volume;
    } catch (_) {
      return null;
    }
  }

  /// 兩段式讀取的第一段：只取標頭與字符集。
  Future<SidxSkipInfo?> readSkipInfoAt({
    required String work,
    required String juan,
  }) async {
    final path = await pathFor(work: work, juan: juan);
    if (path == null) return null;
    RandomAccessFile? file;
    try {
      final source = File(path);
      if (!await source.exists()) return null;
      file = await source.open();
      final header = await file.read(_headerSize);
      final parsed = _parseHeader(header, fullFile: false);
      if (parsed == null) return null;
      await file.setPosition(parsed.charsetOffset);
      final charset = await file.read(parsed.charsetLength);
      // 截斷的字符集會讓該卷看起來「沒有這些字」進而誤跳，寧可回傳 null
      // 讓呼叫端從 HTML 重建。
      if (charset.length != parsed.charsetLength) return null;
      return SidxSkipInfo(
        charSet: decodeRuneSet(charset),
        sourceStamp: parsed.sourceStamp,
      );
    } catch (_) {
      return null;
    } finally {
      await file?.close();
    }
  }

  Future<void> deleteAt({required String work, required String juan}) async {
    try {
      final path = await pathFor(work: work, juan: juan);
      if (path == null) return;
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 派生物刪不掉就留著，下次讀取會依戳記決定重建。
    }
  }

  Future<void> clearAll() async {
    if (kIsWeb) return;
    try {
      final directory = Directory(await directoryPath());
      if (!await directory.exists()) return;
      await for (final entity in directory.list()) {
        if (entity is File && entity.path.endsWith('.sidx')) {
          try {
            await entity.delete();
          } catch (_) {
            // 同上。
          }
        }
      }
    } catch (_) {
      // 同上。
    }
  }
}

var scriptureIndexStore = ScriptureIndexStore();

/// 測試計數：讀過幾次 `.sidx` 全文。跳卷過濾生效時不該增加——
/// 字符集沒有查詢用的碼位，這一卷連正文都不該讀。
int debugSidxBodyReads = 0;

/// 來源經卷 `.json` 的「大小 + 修改時間」→ 32 位元戳記。
///
/// 檔案不存在或讀不到時回傳 null；呼叫端把索引當成過期、從 `.json` 重建。
Future<int?> sidxSourceStamp(String jsonPath) async {
  try {
    final stat = await File(jsonPath).stat();
    // 檔案不存在時 stat 不會丟例外，而是回傳 type=notFound 的全零結果。
    if (stat.type != FileSystemEntityType.file) return null;
    return (stat.size * 0x9E3779B9 + stat.modified.millisecondsSinceEpoch) &
        0xFFFFFFFF;
  } catch (_) {
    return null;
  }
}

/// 卷首的經號提示行（`No. 1092 [cf. Nos. 1093-1099, 901(Fasc. 5)]`）就在
/// `#body` 裡面，不排除會讓 cf 引用污染正文結果。
final _leadingNumberPattern = RegExp(r'^\s*No\.\s*\d{3,5}');

/// 一卷的「正規化 + 定位」結果，同時供離線掃描（索引）與點擊展開（第二段）使用。
class SidxSource {
  const SidxSource({
    required this.normed,
    required this.records,
    required this.runs,
    required this.charSet,
    required this.title,
    required this.excluded,
  });

  /// 正規化後的整卷正文與回原文的對映表。
  final NormedSource normed;

  /// 行定位表，按 [normed] 的位元組座標排序。
  final List<SidxLine> records;
  final List<SidxRun> runs;
  final Set<int> charSet;
  final String title;

  /// 不進索引的原文區間（卷題、作譯者、校勘夾注…），摘要取上下文時要停在邊界。
  final List<Int32List> excluded;
}

/// 由已解析的經文行算出正規化表示與定位表。
///
/// 卷題與作譯者整行跳過；校勘夾注（`inlineNotes`）的區間也跳過，否則無標點
/// 的正文會與注文黏成新詞。卷首的 `No. xxxx [cf. ...]` 提示行也在 `#body` 裡，
/// 同樣要排除，否則 cf 引用會污染正文結果。
SidxSource normalizeScriptureLines(List<ScriptureLine> lines) {
  final source = buildScriptureSearchSource(lines);
  final skipRanges = <Int32List>[];
  var seenVolumeTitle = false;
  var advance = 0;
  final included = <({int start, int end, ScriptureLine line})>[];
  for (final line in lines) {
    final lineStart = advance;
    advance += scriptureSourceAdvance(line);
    final lineEnd = lineStart + line.text.length;
    if (line.role == ScriptureLineRole.volumeTitle) seenVolumeTitle = true;
    final excluded =
        line.role == ScriptureLineRole.volumeTitle ||
        line.role == ScriptureLineRole.byline ||
        (!seenVolumeTitle && _leadingNumberPattern.hasMatch(line.text));
    if (excluded) {
      skipRanges.add(
        Int32List.fromList(<int>[
          lineStart,
          lineEnd.clamp(lineStart, source.length),
        ]),
      );
      continue;
    }
    for (final note in line.inlineNotes) {
      skipRanges.add(
        Int32List.fromList(<int>[
          lineStart + note.offset,
          (lineStart + note.offset + note.length).clamp(0, source.length),
        ]),
      );
    }
    included.add((start: lineStart, end: lineEnd, line: line));
  }
  final charSet = <int>{};
  final excluded = mergeSourceRanges(skipRanges, source.length);
  final normed = normalizeScriptureSource(
    source,
    skipRanges: excluded,
    runeSink: charSet,
  );

  final lineRecords = <SidxLine>[];
  for (final entry in included) {
    final byteOffset = byteOffsetForSource(normed, entry.start);
    final byteEnd = byteOffsetForSource(normed, entry.end);
    if (byteEnd <= byteOffset) continue;
    lineRecords.add(
      SidxLine(
        byteOffset: byteOffset,
        byteLength: byteEnd - byteOffset,
        srcOffset: entry.start,
        linehead: entry.line.linehead ?? '',
        role: entry.line.role.index,
      ),
    );
  }

  final runRecords = <SidxRun>[];
  for (final entry in included) {
    for (final run in entry.line.scriptRuns) {
      final offset = entry.start + run.offset;
      final byteOffset = byteOffsetForSource(normed, offset);
      final byteEnd = byteOffsetForSource(normed, offset + run.length);
      if (byteEnd <= byteOffset) continue;
      final reference = run.reference;
      if (reference.isEmpty) continue;
      runRecords.add(
        SidxRun(
          byteOffset: byteOffset,
          byteLength: byteEnd - byteOffset,
          reference: reference,
          family: run.family,
        ),
      );
    }
  }

  return SidxSource(
    normed: normed,
    records: lineRecords,
    runs: runRecords,
    charSet: charSet,
    title: localWorkTitle(lines),
    excluded: excluded,
  );
}

SidxVolume buildSidxVolume({
  required String work,
  required String juan,
  required int sourceStamp,
  required List<ScriptureLine> lines,
}) {
  final source = normalizeScriptureLines(lines);
  return SidxVolume(
    work: work,
    juan: juan,
    title: source.title,
    sourceStamp: sourceStamp,
    bytes: source.normed.bytes,
    lines: source.records,
    runs: source.runs,
    charSet: source.charSet,
  );
}

/// 序列化：標頭 | 字符集 | 行表 | 字體區間 | 行號池 | 引用池 | 正文 | crc32。
Uint8List encodeSidx(SidxVolume volume) {
  final charset = encodeRuneSet(volume.charSet);
  final lineheadPool = BytesBuilder(copy: false);
  final lineCount = volume.lines.length;
  final lineTable = Uint8List(lineCount * _lineRecordSize);
  for (var index = 0; index < lineCount; index++) {
    final line = volume.lines[index];
    final encoded = utf8.encode(line.linehead);
    final poolOffset = lineheadPool.length;
    lineheadPool.add(encoded);
    final record =
        ByteData.sublistView(
            lineTable,
            index * _lineRecordSize,
            (index + 1) * _lineRecordSize,
          )
          ..setUint32(0, line.byteOffset, _endian)
          ..setUint32(4, line.byteLength, _endian)
          ..setUint32(8, line.srcOffset, _endian)
          ..setUint32(12, poolOffset, _endian)
          ..setUint16(16, encoded.length, _endian)
          ..setUint16(18, line.role, _endian);
    assert(record.lengthInBytes == _lineRecordSize);
  }
  final refPool = BytesBuilder(copy: false);
  final runCount = volume.runs.length;
  final runTable = Uint8List(runCount * _runRecordSize);
  for (var index = 0; index < runCount; index++) {
    final run = volume.runs[index];
    final encoded = utf8.encode(run.reference);
    final poolOffset = refPool.length;
    refPool.add(encoded);
    ByteData.sublistView(
        runTable,
        index * _runRecordSize,
        (index + 1) * _runRecordSize,
      )
      ..setUint32(0, run.byteOffset, _endian)
      ..setUint32(4, run.byteLength, _endian)
      ..setUint32(8, poolOffset, _endian)
      ..setUint16(12, encoded.length, _endian)
      ..setUint16(14, run.family.index, _endian);
  }

  final heads = lineheadPool.takeBytes();
  final refs = refPool.takeBytes();
  final title = utf8.encode(volume.title);
  final total =
      _headerSize +
      charset.length +
      lineTable.length +
      runTable.length +
      heads.length +
      refs.length +
      title.length +
      volume.bytes.length +
      4;
  final out = Uint8List(total);
  for (var index = 0; index < _magic.length; index++) {
    out[index] = _magic[index];
  }
  ByteData.sublistView(out, 0, _headerSize)
    ..setUint16(4, sidxFormatVersion, _endian)
    ..setUint16(6, sidxNormVersion, _endian)
    ..setUint32(8, sidxFlagsApplied, _endian)
    ..setUint32(12, volume.sourceStamp, _endian)
    ..setUint32(16, lineCount, _endian)
    ..setUint32(20, runCount, _endian)
    ..setUint32(24, volume.charSet.length, _endian)
    ..setUint32(28, charset.length, _endian)
    ..setUint32(32, lineTable.length, _endian)
    ..setUint32(36, runTable.length, _endian)
    ..setUint32(40, heads.length, _endian)
    ..setUint32(44, refs.length, _endian)
    ..setUint32(48, volume.bytes.length, _endian)
    ..setUint32(52, _headerSize, _endian)
    ..setUint32(56, title.length, _endian);
  var cursor = _headerSize;
  void put(List<int> section) {
    out.setRange(cursor, cursor + section.length, section);
    cursor += section.length;
  }

  put(charset);
  put(lineTable);
  put(runTable);
  put(heads);
  put(refs);
  put(title);
  put(volume.bytes);
  ByteData.sublistView(
    out,
    total - 4,
    total,
  ).setUint32(0, crc32(out, 0, total - 4), _endian);
  return out;
}

class _SidxSections {
  const _SidxSections({
    required this.sourceStamp,
    required this.lineCount,
    required this.runCount,
    required this.charsetOffset,
    required this.charsetLength,
    required this.lineTableOffset,
    required this.runTableOffset,
    required this.headPoolOffset,
    required this.headPoolLength,
    required this.refPoolOffset,
    required this.refPoolLength,
    required this.titleOffset,
    required this.titleLength,
    required this.textOffset,
    required this.textLength,
  });

  final int sourceStamp;
  final int lineCount;
  final int runCount;
  final int charsetOffset;
  final int charsetLength;
  final int lineTableOffset;
  final int runTableOffset;
  final int headPoolOffset;
  final int headPoolLength;
  final int refPoolOffset;
  final int refPoolLength;
  final int titleOffset;
  final int titleLength;
  final int textOffset;
  final int textLength;
}

/// 解析標頭；[fullFile] 為 false 時代表傳進來的只有 64 位元組標頭（跳卷過濾的
/// 第一段讀取），此時不能檢查各段是否落在檔案內。
_SidxSections? _parseHeader(Uint8List bytes, {bool fullFile = true}) {
  if (bytes.length < _headerSize) return null;
  for (var index = 0; index < _magic.length; index++) {
    if (bytes[index] != _magic[index]) return null;
  }
  final header = ByteData.sublistView(bytes, 0, _headerSize);
  if (header.getUint16(4, _endian) != sidxFormatVersion) return null;
  if (header.getUint16(6, _endian) != sidxNormVersion) return null;
  if (header.getUint32(8, _endian) != sidxFlagsApplied) return null;
  if (header.getUint32(52, _endian) != _headerSize) return null;
  final charsetLength = header.getUint32(28, _endian);
  final lineTableLength = header.getUint32(32, _endian);
  final runTableLength = header.getUint32(36, _endian);
  final headPoolLength = header.getUint32(40, _endian);
  final refPoolLength = header.getUint32(44, _endian);
  final titleLength = header.getUint32(56, _endian);
  final textLength = header.getUint32(48, _endian);
  var cursor = _headerSize;
  final charsetOffset = cursor;
  cursor += charsetLength;
  final lineTableOffset = cursor;
  cursor += lineTableLength;
  final runTableOffset = cursor;
  cursor += runTableLength;
  final headPoolOffset = cursor;
  cursor += headPoolLength;
  final refPoolOffset = cursor;
  cursor += refPoolLength;
  final titleOffset = cursor;
  cursor += titleLength;
  final textOffset = cursor;
  if (lineTableLength != header.getUint32(16, _endian) * _lineRecordSize) {
    return null;
  }
  if (runTableLength != header.getUint32(20, _endian) * _runRecordSize) {
    return null;
  }
  if (fullFile) {
    if (charsetOffset + charsetLength > bytes.length) return null;
    if (titleOffset + titleLength > bytes.length) return null;
    if (textOffset + textLength + 4 > bytes.length) return null;
  }
  return _SidxSections(
    sourceStamp: header.getUint32(12, _endian),
    lineCount: header.getUint32(16, _endian),
    runCount: header.getUint32(20, _endian),
    charsetOffset: charsetOffset,
    charsetLength: charsetLength,
    lineTableOffset: lineTableOffset,
    runTableOffset: runTableOffset,
    headPoolOffset: headPoolOffset,
    headPoolLength: headPoolLength,
    refPoolOffset: refPoolOffset,
    refPoolLength: refPoolLength,
    titleOffset: titleOffset,
    titleLength: titleLength,
    textOffset: textOffset,
    textLength: textLength,
  );
}

/// 解析失敗（magic、版本、長度或 crc 不符）一律回傳 null，呼叫端重建。
SidxVolume? decodeSidx(
  Uint8List bytes, {
  required String work,
  required String juan,
}) {
  final sections = _parseHeader(bytes);
  if (sections == null) return null;
  if (ByteData.sublistView(
        bytes,
        bytes.length - 4,
        bytes.length,
      ).getUint32(0, _endian) !=
      crc32(bytes, 0, bytes.length - 4)) {
    return null;
  }
  final headPool = Uint8List.sublistView(
    bytes,
    sections.headPoolOffset,
    sections.headPoolOffset + sections.headPoolLength,
  );
  final refPool = Uint8List.sublistView(
    bytes,
    sections.refPoolOffset,
    sections.refPoolOffset + sections.refPoolLength,
  );
  final lines = <SidxLine>[];
  for (var index = 0; index < sections.lineCount; index++) {
    final offset = sections.lineTableOffset + index * _lineRecordSize;
    final record = ByteData.sublistView(
      bytes,
      offset,
      offset + _lineRecordSize,
    );
    final headOffset = record.getUint32(12, _endian);
    final headLength = record.getUint16(16, _endian);
    if (headOffset + headLength > headPool.length) return null;
    lines.add(
      SidxLine(
        byteOffset: record.getUint32(0, _endian),
        byteLength: record.getUint32(4, _endian),
        srcOffset: record.getUint32(8, _endian),
        linehead: utf8.decode(
          Uint8List.sublistView(headPool, headOffset, headOffset + headLength),
          allowMalformed: true,
        ),
        role: record.getUint16(18, _endian),
      ),
    );
  }
  final runs = <SidxRun>[];
  for (var index = 0; index < sections.runCount; index++) {
    final offset = sections.runTableOffset + index * _runRecordSize;
    final record = ByteData.sublistView(bytes, offset, offset + _runRecordSize);
    final refOffset = record.getUint32(8, _endian);
    final refLength = record.getUint16(12, _endian);
    final familyIndex = record.getUint16(14, _endian);
    if (refOffset + refLength > refPool.length) return null;
    if (familyIndex >= ScriptureScriptFamily.values.length) continue;
    runs.add(
      SidxRun(
        byteOffset: record.getUint32(0, _endian),
        byteLength: record.getUint32(4, _endian),
        reference: utf8.decode(
          Uint8List.sublistView(refPool, refOffset, refOffset + refLength),
          allowMalformed: true,
        ),
        family: ScriptureScriptFamily.values[familyIndex],
      ),
    );
  }
  return SidxVolume(
    work: work,
    juan: juan,
    title: utf8.decode(
      Uint8List.sublistView(
        bytes,
        sections.titleOffset,
        sections.titleOffset + sections.titleLength,
      ),
      allowMalformed: true,
    ),
    sourceStamp: sections.sourceStamp,
    lines: lines,
    runs: runs,
    charSet: decodeRuneSet(
      Uint8List.sublistView(
        bytes,
        sections.charsetOffset,
        sections.charsetOffset + sections.charsetLength,
      ),
    ),
    bytes: Uint8List.sublistView(
      bytes,
      sections.textOffset,
      sections.textOffset + sections.textLength,
    ),
  );
}

final Uint32List _crcTable = _buildCrcTable();

Uint32List _buildCrcTable() {
  final table = Uint32List(256);
  for (var index = 0; index < 256; index++) {
    var value = index;
    for (var bit = 0; bit < 8; bit++) {
      value = (value & 1) != 0 ? 0xEDB88320 ^ (value >> 1) : value >> 1;
    }
    table[index] = value & 0xFFFFFFFF;
  }
  return table;
}

int crc32(List<int> bytes, int start, int end) {
  var crc = 0xFFFFFFFF;
  for (var index = start; index < end; index++) {
    crc = _crcTable[(crc ^ bytes[index]) & 0xFF] ^ (crc >> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
