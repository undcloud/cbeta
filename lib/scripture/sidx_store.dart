import 'dart:collection';
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
class SidxVolume implements SidxSearchVolume {
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

  @override
  final String work;
  @override
  final String juan;

  /// 作品名（卷題去掉「卷第一」尾綴）；第一階段不解析 HTML 也能顯示經名。
  @override
  final String title;

  /// 來源經卷檔案的「大小 + 修改時間」摘要（見 [sidxSourceStamp]）。
  ///
  /// 經卷 `.json` 是真相源、`.sidx` 是派生物；這枚戳記讓掃描只要一次 `stat`
  /// 就能判索引新舊，不必把 25 KB 正文讀進來比對內容版本。
  @override
  final int sourceStamp;
  @override
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

  @override
  String? lineheadAt(int byteOffset) => lineAt(byteOffset)?.linehead;
}

/// 離線掃描眼裡的一卷：正文、標題與命中行的行號。
///
/// 段索引讀取只回傳這個輕量視圖；完整 [SidxVolume]（含所有行、悉曇區間、
/// 字符集 Set）只在從舊索引遷移或從 HTML 重建時才需要。
abstract class SidxSearchVolume {
  String get work;
  String get juan;
  String get title;
  int get sourceStamp;
  Uint8List get bytes;

  /// 正規化位元組位移落在哪一行；越界或沒有行表時回傳 null。
  String? lineheadAt(int byteOffset);
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

  /// 段式索引與一卷一檔共用同一個目錄，維護入口由此建立對應的段儲存。
  Future<Directory> Function() get directoryProvider => _directoryProvider;

  /// 目錄路徑推導一次就固定；`pathFor` 每卷從搜尋到幾次，不該每次都 `create`。
  String? _directoryPath;

  Future<String> directoryPath() async {
    final cached = _directoryPath;
    if (cached != null) return cached;
    final support = await _directoryProvider();
    final directory = Directory(
      '${support.path}${Platform.pathSeparator}cbeta_sidx',
    );
    await directory.create(recursive: true);
    return _directoryPath = directory.path;
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
    // 派生物換了內容，記憶體裡那份舊的必須一起作廢。
    _forget(path);
  }

  /// 讀出可用的索引；戳記不符、損毀或不存在時回傳 null（呼叫端重建）。
  Future<SidxVolume?> readAt({
    required String work,
    required String juan,
    required int sourceStamp,
  }) async {
    final path = await pathFor(work: work, juan: juan);
    if (path == null) return null;
    final cached = _rememberVolume(path, _volumeCache[path]);
    if (cached != null && cached.sourceStamp == sourceStamp) return cached;
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
      _cacheVolume(path, volume);
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
    final cached = _skipCache.remove(path) ?? _skipCache[path];
    if (cached != null) {
      _skipCache[path] = cached;
      return cached;
    }
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
      final info = SidxSkipInfo(
        charSet: decodeRuneSet(charset),
        sourceStamp: parsed.sourceStamp,
      );
      _cacheSkip(path, info);
      return info;
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
      _forget(path);
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 派生物刪不掉就留著，下次讀取會依戳記決定重建。
    }
  }

  Future<void> clearAll() async {
    _volumeCache.clear();
    _volumeCacheBytes = 0;
    _skipCache.clear();
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

/// 每 isolate 一份的 `.sidx` 記憶體快取（計價以正規化正文位元組數）。
///
/// 常駐 worker 池跨搜尋重用，所以這一層真正的收益是「第二次搜常用字時不必再
/// 逐卷讀檔」。從 HTML 重建的那一轮**不**進快取：否則同一次掃描的
/// [debugSidxBodyReads] 會被掩掉，測試就看不出跳卷過濾有沒有生效。
final LinkedHashMap<String, SidxVolume> _volumeCache = LinkedHashMap();
int _volumeCacheBytes = 0;
const int _volumeCacheBudgetBytes = 24 * 1024 * 1024;

/// 字符集比正文小得多，全藏的標頭資訊值得放更長清單；戳記存在值裡，
/// 呼叫端自己比對，所以內容換了的卷也不會讀到過期判斷。
final LinkedHashMap<String, SidxSkipInfo> _skipCache = LinkedHashMap();
const int _skipCacheEntryLimit = 4096;

SidxVolume? _rememberVolume(String path, SidxVolume? entry) {
  if (entry == null) return null;
  // LinkedHashMap 保留插入順序：移除再插一次就是把它推到最近使用端。
  _volumeCache.remove(path);
  _volumeCache[path] = entry;
  return entry;
}

void _cacheVolume(String path, SidxVolume volume) {
  final size = volume.bytes.length + volume.lines.length * 32;
  final replaced = _volumeSizes.remove(path);
  if (replaced != null) _volumeCacheBytes -= replaced;
  _volumeCache.remove(path);
  _volumeCache[path] = volume;
  _volumeSizes[path] = size;
  _volumeCacheBytes += size;
  while (_volumeCacheBytes > _volumeCacheBudgetBytes &&
      _volumeCache.isNotEmpty) {
    final eldest = _volumeCache.keys.first;
    _volumeCache.remove(eldest);
    _volumeCacheBytes -= _volumeSizes.remove(eldest) ?? 0;
  }
}

final Map<String, int> _volumeSizes = {};

void _cacheSkip(String path, SidxSkipInfo info) {
  _skipCache.remove(path);
  _skipCache[path] = info;
  while (_skipCache.length > _skipCacheEntryLimit && _skipCache.isNotEmpty) {
    _skipCache.remove(_skipCache.keys.first);
  }
}

void _forget(String path) {
  _volumeCacheBytes -= _volumeSizes.remove(path) ?? 0;
  _volumeCache.remove(path);
  _skipCache.remove(path);
}

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

  /// 摘要取上下文時不跨越的原文邊界（卷題、作譯者、校勘夾注…）。
  ///
  /// 卷題本身仍會進索引，只是摘要不要跨到卷題另一側。
  final List<Int32List> excluded;
}

/// 由已解析的經文行算出正規化表示與定位表。
///
/// 作譯者整行跳過；校勘夾注（`inlineNotes`）的區間也跳過，否則無標點
/// 的正文會與注文黏成新詞。卷首的 `No. xxxx [cf. ...]` 提示行也在 `#body` 裡，
/// 同樣要排除，否則 cf 引用會污染正文結果。
///
/// 卷題不再排除：它在網頁模式是正文裡的次級標題，必須能被離線搜尋命中。
SidxSource normalizeScriptureLines(List<ScriptureLine> lines) {
  final source = buildScriptureSearchSource(lines);
  final skipRanges = <Int32List>[];
  final boundaryRanges = <Int32List>[];
  var seenVolumeTitle = false;
  var advance = 0;
  final included = <({int start, int end, ScriptureLine line})>[];
  for (final line in lines) {
    final lineStart = advance;
    advance += scriptureSourceAdvance(line);
    final lineEnd = lineStart + line.text.length;
    final lineRange = Int32List.fromList(<int>[
      lineStart,
      lineEnd.clamp(lineStart, source.length),
    ]);
    if (line.role == ScriptureLineRole.volumeTitle) {
      seenVolumeTitle = true;
      boundaryRanges.add(lineRange);
    } else if (line.role == ScriptureLineRole.volumeTailTitle) {
      // 卷末尾題同樣是摘要的邊界，但不算卷首題：它不該解除
      // 「卷首經號提示行不進索引」的限制。
      boundaryRanges.add(lineRange);
    }
    final excludedFromIndex =
        line.role == ScriptureLineRole.byline ||
        (!seenVolumeTitle && _leadingNumberPattern.hasMatch(line.text));
    if (excludedFromIndex) {
      skipRanges.add(lineRange);
      boundaryRanges.add(lineRange);
      continue;
    }
    for (final note in line.inlineNotes) {
      final noteRange = Int32List.fromList(<int>[
        lineStart + note.offset,
        (lineStart + note.offset + note.length).clamp(0, source.length),
      ]);
      skipRanges.add(noteRange);
      boundaryRanges.add(noteRange);
    }
    included.add((start: lineStart, end: lineEnd, line: line));
  }
  final charSet = <int>{};
  final excluded = mergeSourceRanges(skipRanges, source.length);
  final boundaries = mergeSourceRanges(boundaryRanges, source.length);
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
    excluded: boundaries,
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

/// 掃描用的輕量解碼：只驗標頭，正文用視圖，標題與行號延遲解碼。
///
/// 完整 [decodeSidx] 會校验 crc、把所有行號與標題解成字串、重建字符集
/// Set；2 萬卷全藏掃描時這些都是白工（字符集由段清單判定，行號只在命中
/// 時才要）。[verifyCrc] 預設關閉：段檔只在整卷寫完後才提交清單記錄，
/// 清單又帶 crc，損毀的段會在下一次重建時被換掉。
SidxScanVolume? decodeSidxForScan(
  Uint8List bytes, {
  required String work,
  required String juan,
  bool verifyCrc = false,
}) {
  final sections = _parseHeader(bytes);
  if (sections == null) return null;
  if (verifyCrc &&
      ByteData.sublistView(
            bytes,
            bytes.length - 4,
            bytes.length,
          ).getUint32(0, _endian) !=
          crc32(bytes, 0, bytes.length - 4)) {
    return null;
  }
  return SidxScanVolume._(
    work: work,
    juan: juan,
    sourceStamp: sections.sourceStamp,
    source: bytes,
    lineTableOffset: sections.lineTableOffset,
    lineCount: sections.lineCount,
    headPoolOffset: sections.headPoolOffset,
    headPoolLength: sections.headPoolLength,
    titleOffset: sections.titleOffset,
    titleLength: sections.titleLength,
    textOffset: sections.textOffset,
    textLength: sections.textLength,
  );
}

/// [decodeSidxForScan] 的產物；不持有行表與字符集。
class SidxScanVolume implements SidxSearchVolume {
  SidxScanVolume._({
    required this.work,
    required this.juan,
    required this.sourceStamp,
    required Uint8List source,
    required int lineTableOffset,
    required int lineCount,
    required int headPoolOffset,
    required int headPoolLength,
    required int titleOffset,
    required int titleLength,
    required int textOffset,
    required int textLength,
  }) : _source = source,
       _lineTableOffset = lineTableOffset,
       _lineCount = lineCount,
       _headPoolOffset = headPoolOffset,
       _headPoolLength = headPoolLength,
       _titleOffset = titleOffset,
       _titleLength = titleLength,
       bytes = Uint8List.sublistView(
         source,
         textOffset,
         textOffset + textLength,
       );

  @override
  final String work;
  @override
  final String juan;
  @override
  final int sourceStamp;
  @override
  final Uint8List bytes;

  final Uint8List _source;
  final int _lineTableOffset;
  final int _lineCount;
  final int _headPoolOffset;
  final int _headPoolLength;
  final int _titleOffset;
  final int _titleLength;
  String? _title;

  /// 快取計價用：視圖會保留整個編碼檔，不能只算正文長度。
  int get byteLength => _source.length;

  @override
  String get title {
    final cached = _title;
    if (cached != null) return cached;
    return _title = _titleLength == 0
        ? ''
        : utf8.decode(
            Uint8List.sublistView(
              _source,
              _titleOffset,
              _titleOffset + _titleLength,
            ),
            allowMalformed: true,
          );
  }

  @override
  String? lineheadAt(int byteOffset) {
    if (_lineCount == 0) return null;
    var low = 0;
    var high = _lineCount - 1;
    while (low < high) {
      final middle = (low + high + 1) >> 1;
      if (_readSidxUint32(
            _source,
            _lineTableOffset + middle * _lineRecordSize,
          ) <=
          byteOffset) {
        low = middle;
      } else {
        high = middle - 1;
      }
    }
    final record = _lineTableOffset + low * _lineRecordSize;
    if (_readSidxUint32(_source, record) > byteOffset) return null;
    final headOffset = _readSidxUint32(_source, record + 12);
    final headLength = _readSidxUint16(_source, record + 16);
    if (headOffset + headLength > _headPoolLength) return null;
    final start = _headPoolOffset + headOffset;
    return utf8.decode(
      Uint8List.sublistView(_source, start, start + headLength),
      allowMalformed: true,
    );
  }
}

int _readSidxUint32(Uint8List bytes, int offset) =>
    bytes[offset] |
    (bytes[offset + 1] << 8) |
    (bytes[offset + 2] << 16) |
    (bytes[offset + 3] << 24);

int _readSidxUint16(Uint8List bytes, int offset) =>
    bytes[offset] | (bytes[offset + 1] << 8);

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
