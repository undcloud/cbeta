import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';

import 'sidx_norm.dart';
import 'sidx_store.dart';

/// 段數固定，段號只由作品決定：同一部經的所有卷永遠落在同一段，
/// 更新某卷時只要重寫一段，掃描時也不會把一部經拆到多個 worker。
const int sidxSegmentCount = 256;

const List<int> _metaHeaderMagic = <int>[0x43, 0x53, 0x58, 0x48]; // CSXH
const List<int> _metaRecordMagic = <int>[0x43, 0x53, 0x58, 0x52]; // CSXR
const int _metaHeaderSize = 16;
const int _metaRecordFixedSize = 24;
const Endian _endian = Endian.little;

/// 段檔案內的索引位置；字符集一併放在 meta，跳卷判定不必碰 blob。
class SidxSegmentEntry {
  const SidxSegmentEntry({
    required this.work,
    required this.juan,
    required this.sourceStamp,
    required this.offset,
    required this.byteLength,
    required this.charSetBytes,
  });

  final String work;
  final String juan;
  final int sourceStamp;
  final int offset;
  final int byteLength;

  /// `encodeRuneSet` 的原始位元組；不展開成 Set，掃描時直接串流比對。
  final Uint8List charSetBytes;

  String get key => '$work:$juan';

  /// 查詢候補與本卷字符集無交集時，這卷不可能命中。
  bool canSkip(Set<int> queryRunes) {
    if (queryRunes.isEmpty) return true;
    var rune = 0;
    var value = 0;
    var shift = 0;
    for (final byte in charSetBytes) {
      value += (byte & 0x7F) << shift;
      if (byte & 0x80 != 0) {
        shift += 7;
        continue;
      }
      rune += value;
      if (queryRunes.contains(rune)) return false;
      value = 0;
      shift = 0;
    }
    return true;
  }
}

/// 一段的旁車清單。同一卷在追加式檔案裡可能出現多次，只保留最後一筆。
class SidxSegmentMeta {
  SidxSegmentMeta(this.segmentId, [Map<String, SidxSegmentEntry>? entries])
    : entries = entries ?? <String, SidxSegmentEntry>{};

  final int segmentId;
  final Map<String, SidxSegmentEntry> entries;

  SidxSegmentEntry? entryFor(String work, String juan) =>
      entries['$work:$juan'];

  void add(SidxSegmentEntry entry) => entries[entry.key] = entry;
}

/// 由作品名穩定推導段號；卷號不參與，否則同一部經會散到不同段。
int sidxSegmentId(String work) {
  var hash = 0x811C9DC5;
  for (final unit in work.codeUnits) {
    hash = ((hash ^ unit) * 0x01000193) & 0xFFFFFFFF;
  }
  return hash % sidxSegmentCount;
}

String _segmentFileStem(int id) => 'seg-${id.toString().padLeft(4, '0')}';

/// 卷索引的分段儲存。
///
/// `.sidx` 仍是每一卷的獨立編碼，只是把成千上萬個小檔合并成少量段檔：
/// blob 檔按卷追加，meta 檔按卷追加「戳記 + 偏移 + 字符集」。掃描時先讀
/// meta（可快取），字符集判定跳卷後才按偏移讀 blob，因此常見字的整藏掃描
/// 只剩少量檔案開啟與順序讀取，罕見字連 blob 都不用碰。
class SidxSegmentStore {
  SidxSegmentStore({Future<Directory> Function()? directoryProvider})
    : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directoryProvider;

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

  Future<String> blobPath(int id) async =>
      '${await directoryPath()}${Platform.pathSeparator}'
      '${_segmentFileStem(id)}.csb';

  Future<String> metaPath(int id) async =>
      '${await directoryPath()}${Platform.pathSeparator}'
      '${_segmentFileStem(id)}.csm';

  /// 讀取一段的清單；檔案不存在或版本不符時回傳 null（呼叫端重建）。
  Future<SidxSegmentMeta?> readMeta(int id) async {
    if (kIsWeb) return null;
    try {
      final path = await metaPath(id);
      final file = File(path);
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file) return null;
      final cached = _metaCache[path];
      if (cached != null &&
          cached.size == stat.size &&
          cached.modified == stat.modified.millisecondsSinceEpoch) {
        _rememberMeta(path, cached);
        return cached.meta;
      }
      final meta = decodeSidxSegmentMeta(id, await file.readAsBytes());
      if (meta == null) return null;
      final entry = _MetaCacheEntry(
        meta,
        size: stat.size,
        modified: stat.modified.millisecondsSinceEpoch,
      );
      _rememberMeta(path, entry);
      return meta;
    } catch (_) {
      return null;
    }
  }

  Future<SidxSegmentReader?> openReader(int id) async {
    if (kIsWeb) return null;
    try {
      final path = await blobPath(id);
      final cached = _rememberReader(path);
      if (cached != null) return cached;
      final file = File(path);
      if (!await file.exists()) return null;
      final reader = SidxSegmentReader._(await file.open(), path);
      _readerCache[path] = reader;
      while (_readerCache.length > _readerCacheLimit) {
        final eldest = _readerCache.keys.first;
        await _readerCache.remove(eldest)?.close();
      }
      return reader;
    } catch (_) {
      return null;
    }
  }

  /// 取得一段的寫入權並打開追加檔；拿不到鎖時回傳 null（本次不落盤）。
  Future<SidxSegmentWriter?> beginWrite(
    int id, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    if (kIsWeb) return null;
    final lock = await _acquireLock(id, timeout);
    if (lock == null) return null;
    try {
      final blobFile = File(await blobPath(id));
      final metaFile = File(await metaPath(id));
      var freshMeta = true;
      if (await metaFile.exists()) {
        final existing = await metaFile.readAsBytes();
        freshMeta = !isValidSidxSegmentMetaHeader(existing);
        if (freshMeta && existing.isNotEmpty) {
          // 舊版或損毀的清單不能繼續追加，整份換新；blob 垃圾由清理流程回收。
          await metaFile.writeAsBytes(const <int>[], flush: true);
        } else if (!freshMeta) {
          freshMeta = existing.isEmpty;
        }
      }
      final metaHandle = await metaFile.open(mode: FileMode.append);
      if (freshMeta) {
        await metaHandle.writeFrom(encodeSidxSegmentMetaHeader());
      }
      final blobHandle = await blobFile.open(mode: FileMode.append);
      return SidxSegmentWriter._(this, id, lock, blobHandle, metaHandle);
    } catch (_) {
      await _releaseLock(lock);
      return null;
    }
  }

  /// 目前段內有效的卷數（同一卷只看最後一筆）。
  Future<int> countVolumes() async {
    if (kIsWeb) return 0;
    try {
      final directory = Directory(await directoryPath());
      if (!await directory.exists()) return 0;
      var count = 0;
      await for (final entity in directory.list()) {
        if (entity is! File || !entity.path.endsWith('.csm')) continue;
        final id = _segmentIdFromPath(entity.path);
        if (id == null) continue;
        count += (await readMeta(id))?.entries.length ?? 0;
      }
      return count;
    } catch (_) {
      return 0;
    }
  }

  Future<void> clearAll() async {
    clearSidxSegmentCaches();
    if (kIsWeb) return;
    try {
      final directory = Directory(await directoryPath());
      if (!await directory.exists()) return;
      await for (final entity in directory.list()) {
        if (entity is! File) continue;
        final name = entity.path;
        if (!name.endsWith('.csb') &&
            !name.endsWith('.csm') &&
            !name.endsWith('.lock')) {
          continue;
        }
        try {
          await entity.delete();
        } catch (_) {
          // 派生物刪不掉就留著，下次讀取會依版本／戳記決定重建。
        }
      }
    } catch (_) {
      // 同上。
    }
  }

  Future<File?> _acquireLock(int id, Duration timeout) async {
    final directory = await directoryPath();
    final file = File(
      '$directory${Platform.pathSeparator}${_segmentFileStem(id)}.lock',
    );
    final deadline = DateTime.now().add(timeout);
    while (true) {
      try {
        await file.create(exclusive: true);
        return file;
      } on FileSystemException {
        try {
          final stat = await file.stat();
          if (stat.type == FileSystemEntityType.file &&
              DateTime.now().difference(stat.modified) >
                  const Duration(seconds: 60)) {
            await file.delete();
            continue;
          }
        } catch (_) {
          // 鎖檔剛被別人刪掉，直接重試。
        }
        if (!DateTime.now().isBefore(deadline)) return null;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }
  }

  Future<void> _releaseLock(File lock) async {
    try {
      if (await lock.exists()) await lock.delete();
    } catch (_) {
      // 鎖檔留著也會在 60 秒後被當成過期。
    }
  }

  void _invalidateSegment(int id) {
    // 寫入後清單換了內容，快取與已開的讀取句柄都必須作廢；否則同一個
    // isolate 之後會從舊 inode 讀到已刪除／已重建的段。
    final stem = _segmentFileStem(id);
    final removedMeta = _metaCache.keys
        .where((path) => path.endsWith('$stem.csm'))
        .toList();
    for (final path in removedMeta) {
      _metaCacheBytes -= _metaCache.remove(path)?.size ?? 0;
    }
    final removedReaders = _readerCache.keys
        .where((path) => path.endsWith('$stem.csb'))
        .toList();
    for (final path in removedReaders) {
      _readerCache.remove(path)?.closeSync();
    }
  }

  void _rememberMeta(String path, _MetaCacheEntry entry) {
    final previous = _metaCache.remove(path);
    if (previous != null) _metaCacheBytes -= previous.size;
    _metaCache[path] = entry;
    _metaCacheBytes += entry.size;
    while (_metaCacheBytes > _metaCacheBudgetBytes && _metaCache.length > 1) {
      final eldest = _metaCache.keys.first;
      _metaCacheBytes -= _metaCache.remove(eldest)!.size;
    }
  }
}

/// 一段的讀取器；同一段內多卷共用一個檔案控制代碼。
///
/// 控制代碼由 [SidxSegmentStore.openReader] 跨塊重用，掃描時不再每塊重開
/// 檔；同一 worker 可能同時被派到掃描與建置工作，讀寫位置必須排隊。
class SidxSegmentReader {
  SidxSegmentReader._(this._file, this._blobPath);

  final RandomAccessFile _file;
  final String _blobPath;
  Future<void> _gate = Future<void>.value();

  Future<SidxVolume?> readVolume(SidxSegmentEntry entry) {
    final next = _gate.then((_) => _readVolume(entry));
    _gate = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  Future<SidxVolume?> _readVolume(SidxSegmentEntry entry) async {
    final cacheKey =
        '$_blobPath@${entry.offset}:${entry.byteLength}:${entry.sourceStamp}';
    final cached = _rememberVolume(cacheKey);
    if (cached != null) return cached;
    try {
      await _file.setPosition(entry.offset);
      final bytes = await _file.read(entry.byteLength);
      if (bytes.length != entry.byteLength) return null;
      debugSidxBodyReads += 1;
      final volume = decodeSidx(bytes, work: entry.work, juan: entry.juan);
      if (volume == null || volume.sourceStamp != entry.sourceStamp) {
        return null;
      }
      _cacheVolume(cacheKey, volume);
      return volume;
    } catch (_) {
      return null;
    }
  }

  Future<void> close() async {
    try {
      await _file.close();
    } catch (_) {
      // 已經關掉或檔案被刪都不影響結果。
    }
  }

  void closeSync() {
    try {
      _file.closeSync();
    } catch (_) {
      // 同上。
    }
  }
}

/// 一段的追加寫入器；持有段鎖直到 [close]。
///
/// blob 立即寫入，meta 先緩衝到 [close] 再一次寫完：中途斷電最多留下
/// 沒有 meta 的 blob，下一輪掃描會把它當成缺索引重建，不會讀到半截資料。
class SidxSegmentWriter {
  SidxSegmentWriter._(
    this._store,
    this.segmentId,
    this._lock,
    this._blob,
    this._meta,
  );

  final SidxSegmentStore _store;
  final int segmentId;
  final File _lock;
  final RandomAccessFile _blob;
  final RandomAccessFile _meta;
  final BytesBuilder _pendingMeta = BytesBuilder(copy: false);
  bool _closed = false;

  Future<SidxSegmentEntry?> append(SidxVolume volume) async {
    if (_closed) return null;
    try {
      final bytes = encodeSidx(volume);
      final offset = await _blob.length();
      await _blob.writeFrom(bytes);
      final entry = SidxSegmentEntry(
        work: volume.work,
        juan: volume.juan,
        sourceStamp: volume.sourceStamp,
        offset: offset,
        byteLength: bytes.length,
        charSetBytes: encodeRuneSet(volume.charSet),
      );
      _pendingMeta.add(encodeSidxSegmentMetaRecord(entry));
      return entry;
    } catch (_) {
      return null;
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      // 先讓 blob 落盤，再寫指向它的 meta：反過來的話崩潰會留下
      // 「有清單、沒有正文」的記錄。
      await _blob.flush();
      if (_pendingMeta.isNotEmpty) {
        await _meta.writeFrom(_pendingMeta.takeBytes());
        await _meta.flush();
      }
    } catch (_) {
      // 寫入失敗時索引留在舊狀態，下次掃描重建。
    } finally {
      try {
        await _blob.close();
      } catch (_) {}
      try {
        await _meta.close();
      } catch (_) {}
      _store._invalidateSegment(segmentId);
      await _store._releaseLock(_lock);
    }
  }
}

var scriptureSidxSegmentStore = SidxSegmentStore();

/// 把一段的 meta 清單編碼成追加式記錄。
Uint8List encodeSidxSegmentMetaRecord(SidxSegmentEntry entry) {
  final work = utf8.encode(entry.work);
  final juan = utf8.encode(entry.juan);
  final charset = entry.charSetBytes;
  final total =
      _metaRecordFixedSize + work.length + juan.length + charset.length + 4;
  final out = Uint8List(total);
  _writeMagic(out, 0, _metaRecordMagic);
  ByteData.sublistView(out, 0, _metaRecordFixedSize)
    ..setUint16(4, work.length, _endian)
    ..setUint16(6, juan.length, _endian)
    ..setUint32(8, entry.sourceStamp, _endian)
    ..setUint32(12, entry.offset, _endian)
    ..setUint32(16, entry.byteLength, _endian)
    ..setUint32(20, charset.length, _endian);
  var cursor = _metaRecordFixedSize;
  out.setRange(cursor, cursor + work.length, work);
  cursor += work.length;
  out.setRange(cursor, cursor + juan.length, juan);
  cursor += juan.length;
  out.setRange(cursor, cursor + charset.length, charset);
  cursor += charset.length;
  ByteData.sublistView(
    out,
    cursor,
    cursor + 4,
  ).setUint32(0, crc32(out, 0, cursor), _endian);
  return out;
}

Uint8List encodeSidxSegmentMetaHeader() {
  final out = Uint8List(_metaHeaderSize);
  _writeMagic(out, 0, _metaHeaderMagic);
  ByteData.sublistView(out, 0, _metaHeaderSize)
    ..setUint16(4, 1, _endian)
    ..setUint16(6, sidxFormatVersion, _endian)
    ..setUint16(8, sidxNormVersion, _endian);
  return out;
}

bool isValidSidxSegmentMetaHeader(Uint8List bytes) {
  if (bytes.length < _metaHeaderSize) return false;
  for (var index = 0; index < _metaHeaderMagic.length; index++) {
    if (bytes[index] != _metaHeaderMagic[index]) return false;
  }
  final header = ByteData.sublistView(bytes, 0, _metaHeaderSize);
  if (header.getUint16(4, _endian) != 1) return false;
  if (header.getUint16(6, _endian) != sidxFormatVersion) return false;
  if (header.getUint16(8, _endian) != sidxNormVersion) return false;
  return true;
}

/// 解析追加式清單；尾部半截記錄直接忽略。
SidxSegmentMeta? decodeSidxSegmentMeta(int segmentId, Uint8List bytes) {
  if (!isValidSidxSegmentMetaHeader(bytes)) return null;
  final entries = <String, SidxSegmentEntry>{};
  var cursor = _metaHeaderSize;
  while (cursor + _metaRecordFixedSize + 4 <= bytes.length) {
    final start = cursor;
    for (var index = 0; index < _metaRecordMagic.length; index++) {
      if (bytes[start + index] != _metaRecordMagic[index]) return null;
    }
    final record = ByteData.sublistView(
      bytes,
      start,
      start + _metaRecordFixedSize,
    );
    final workLength = record.getUint16(4, _endian);
    final juanLength = record.getUint16(6, _endian);
    final charsetLength = record.getUint32(20, _endian);
    final end =
        start +
        _metaRecordFixedSize +
        workLength +
        juanLength +
        charsetLength +
        4;
    if (end > bytes.length) break;
    final crcOffset = end - 4;
    if (ByteData.sublistView(bytes, crcOffset, end).getUint32(0, _endian) !=
        crc32(bytes, start, crcOffset)) {
      break;
    }
    var offset = start + _metaRecordFixedSize;
    final work = utf8.decode(
      Uint8List.sublistView(bytes, offset, offset + workLength),
      allowMalformed: true,
    );
    offset += workLength;
    final juan = utf8.decode(
      Uint8List.sublistView(bytes, offset, offset + juanLength),
      allowMalformed: true,
    );
    offset += juanLength;
    // 直接指向清單位元組，不複製也不展開成 Set：2 萬卷的清單約 30 MB，
    // 展開成 Set 會多出上百 MB，且每次重讀都要重新配置。
    final charSetBytes = Uint8List.sublistView(
      bytes,
      offset,
      offset + charsetLength,
    );
    final entry = SidxSegmentEntry(
      work: work,
      juan: juan,
      sourceStamp: record.getUint32(8, _endian),
      offset: record.getUint32(12, _endian),
      byteLength: record.getUint32(16, _endian),
      charSetBytes: charSetBytes,
    );
    entries[entry.key] = entry;
    cursor = end;
  }
  return SidxSegmentMeta(segmentId, entries);
}

void _writeMagic(Uint8List out, int offset, List<int> magic) {
  for (var index = 0; index < magic.length; index++) {
    out[offset + index] = magic[index];
  }
}

int? _segmentIdFromPath(String path) {
  final name = path.replaceAll('\\', '/').split('/').last;
  if (!name.startsWith('seg-') || !name.endsWith('.csm')) return null;
  final digits = name.substring(4, name.length - 4);
  final id = int.tryParse(digits);
  if (id == null || id < 0 || id >= sidxSegmentCount) return null;
  return id;
}

class _MetaCacheEntry {
  const _MetaCacheEntry(
    this.meta, {
    required this.size,
    required this.modified,
  });

  final SidxSegmentMeta meta;
  final int size;
  final int modified;
}

final LinkedHashMap<String, _MetaCacheEntry> _metaCache = LinkedHashMap();
var _metaCacheBytes = 0;

/// 每個 worker 只會碰到一部分段；2 萬卷時一段清單約 120 KB，
/// 16 MB 足以讓固定分配給本 worker 的段清單全程留在記憶體。
const int _metaCacheBudgetBytes = 16 * 1024 * 1024;

final LinkedHashMap<String, SidxSegmentReader> _readerCache = LinkedHashMap();

/// 2 核裝置上每個 worker 會分到 128 段，留一點餘裕避免同一次掃描內重開。
const int _readerCacheLimit = 160;

SidxSegmentReader? _rememberReader(String path) {
  final cached = _readerCache.remove(path);
  if (cached == null) return null;
  _readerCache[path] = cached;
  return cached;
}

final LinkedHashMap<String, SidxVolume> _volumeCache = LinkedHashMap();
final Map<String, int> _volumeSizes = {};
int _volumeCacheBytes = 0;
const int _volumeCacheBudgetBytes = 24 * 1024 * 1024;

SidxVolume? _rememberVolume(String key) {
  final entry = _volumeCache.remove(key);
  if (entry == null) return null;
  _volumeCache[key] = entry;
  return entry;
}

void _cacheVolume(String key, SidxVolume volume) {
  final size = volume.bytes.length + volume.lines.length * 32;
  final replaced = _volumeSizes.remove(key);
  if (replaced != null) _volumeCacheBytes -= replaced;
  _volumeCache.remove(key);
  _volumeCache[key] = volume;
  _volumeSizes[key] = size;
  _volumeCacheBytes += size;
  while (_volumeCacheBytes > _volumeCacheBudgetBytes &&
      _volumeCache.isNotEmpty) {
    final eldest = _volumeCache.keys.first;
    _volumeCache.remove(eldest);
    _volumeCacheBytes -= _volumeSizes.remove(eldest) ?? 0;
  }
}

void clearSidxSegmentCaches() {
  for (final reader in _readerCache.values) {
    reader.closeSync();
  }
  _readerCache.clear();
  _metaCache.clear();
  _metaCacheBytes = 0;
  _volumeCache.clear();
  _volumeSizes.clear();
  _volumeCacheBytes = 0;
}
