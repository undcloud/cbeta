import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 一部詞典的 key 索引（只用於候選命中數統計）。
///
/// 它是 `fodict.dat` 的**派生物**，可以隨時刪除並重建；`.dat` 才是真相源。
/// 與含釋義的 `ParsedDictionary` 分開存放，統計才不會把正文擠出快取。
class FodictKeyIndex {
  const FodictKeyIndex({required this.lowerKeys, required this.sourceStamp});

  /// 小寫化的 key 清單，順序與詞典解析結果一致。
  final List<String> lowerKeys;

  /// 來源 `fodict.dat` 的「大小 + 修改時間」摘要（見 [fodictSourceStamp]）。
  final int sourceStamp;
}

/// `.keys` 標頭：magic、格式版本、條目數、blob 長度、來源戳記。
const _fodictKeysMagic = 0x4B444F46; // 'FODK'（小端讀出）
const _fodictKeysFormatVersion = 1;
const _fodictKeysHeaderSize = 24;

const _fodictKeysEndian = Endian.little;

/// 把 key 清單序列化成 `.keys` 位元組。
///
/// 排版：標頭 24 B | 位移表 (keyCount + 1) × 4 B | UTF-8 key blob。
/// 用位移表而不是分隔符，是因為全文式詞典的 key 允許含換行。
Uint8List encodeFodictKeys(FodictKeyIndex index) {
  final blob = BytesBuilder(copy: false);
  final offsets = Int32List(index.lowerKeys.length + 1);
  for (var i = 0; i < index.lowerKeys.length; i++) {
    offsets[i] = blob.length;
    blob.add(utf8.encode(index.lowerKeys[i]));
  }
  offsets[offsets.length - 1] = blob.length;

  final offsetBytes = ByteData(offsets.length * 4);
  for (var i = 0; i < offsets.length; i++) {
    offsetBytes.setUint32(i * 4, offsets[i], _fodictKeysEndian);
  }

  final bytes = Uint8List(
    _fodictKeysHeaderSize + offsetBytes.lengthInBytes + blob.length,
  );
  final header = ByteData.sublistView(bytes);
  header
    ..setUint32(0, _fodictKeysMagic, _fodictKeysEndian)
    ..setUint16(4, _fodictKeysFormatVersion, _fodictKeysEndian)
    ..setUint16(6, 0, _fodictKeysEndian)
    ..setUint32(8, index.lowerKeys.length, _fodictKeysEndian)
    ..setUint32(12, blob.length, _fodictKeysEndian)
    ..setUint32(16, index.sourceStamp, _fodictKeysEndian);
  bytes.setRange(
    _fodictKeysHeaderSize,
    _fodictKeysHeaderSize + offsetBytes.lengthInBytes,
    offsetBytes.buffer.asUint8List(),
  );
  bytes.setRange(
    _fodictKeysHeaderSize + offsetBytes.lengthInBytes,
    bytes.length,
    blob.toBytes(),
  );
  return bytes;
}

/// 讀回 key 清單；戳記不符、結構不對或位元組被截斷時回傳 null（呼叫端重建）。
List<String>? decodeFodictKeys(Uint8List bytes, {required int sourceStamp}) {
  if (bytes.length < _fodictKeysHeaderSize) return null;
  final header = ByteData.sublistView(bytes);
  if (header.getUint32(0, _fodictKeysEndian) != _fodictKeysMagic) return null;
  if (header.getUint16(4, _fodictKeysEndian) != _fodictKeysFormatVersion) {
    return null;
  }
  if (header.getUint32(16, _fodictKeysEndian) != sourceStamp) return null;

  final keyCount = header.getUint32(8, _fodictKeysEndian);
  final blobLength = header.getUint32(12, _fodictKeysEndian);
  final tableLength = (keyCount + 1) * 4;
  if (keyCount > 10000000 ||
      blobLength > 100000000 ||
      bytes.length != _fodictKeysHeaderSize + tableLength + blobLength) {
    return null;
  }

  final tableStart = _fodictKeysHeaderSize;
  final blobStart = tableStart + tableLength;
  final offsets = Int32List(keyCount + 1);
  final table = ByteData.sublistView(bytes, tableStart, blobStart);
  for (var i = 0; i < offsets.length; i++) {
    final value = table.getUint32(i * 4, _fodictKeysEndian);
    // 位移必須單調且不超過 blob；截斷的檔案會在這裡被判掉，而不是解出半條 key。
    if (value < (i == 0 ? 0 : offsets[i - 1]) || value > blobLength) {
      return null;
    }
    offsets[i] = value;
  }
  if (offsets.first != 0 || offsets.last != blobLength) return null;

  try {
    final keys = List<String>.filled(keyCount, '', growable: false);
    for (var i = 0; i < keyCount; i++) {
      keys[i] = utf8.decode(
        bytes.sublist(blobStart + offsets[i], blobStart + offsets[i + 1]),
      );
    }
    return keys;
  } on FormatException {
    return null;
  }
}

/// `fodict.dat` 的「大小 + 修改時間」→ 32 位元戳記；讀不到時回傳 null。
///
/// 內建資產詞典沒有檔案路徑，呼叫端直接用打包長度當戳記（隨 APK 固定）。
Future<int?> fodictSourceStamp(String datPath) async {
  try {
    final stat = await File(datPath).stat();
    // 檔案不存在時 stat 不會丟例外，而是回傳 type=notFound 的全零結果。
    if (stat.type != FileSystemEntityType.file) return null;
    return (stat.size * 0x9E3779B9 + stat.modified.millisecondsSinceEpoch) &
        0xFFFFFFFF;
  } catch (_) {
    return null;
  }
}

/// `.keys` 檔案的存放與回收。
///
/// 統一放在 `<baseDir>/_keys/<詞典 id>.keys`：詞典目錄被 `deleteInstalled`
/// 整目錄刪除時 sidecar 不會跟著消失，所以重新列目錄時要掃一次孤兒。
/// 內建 030 的 `.dat` 在 `assets/` 裡不可寫，這也是不能同目錄存放的原因。
class FodictKeyStore {
  static const directoryName = '_keys';

  static final _validDictionaryId = RegExp(r'^[0-9A-Za-z][0-9A-Za-z._-]*$');

  String? pathFor({required String baseDir, required String id}) {
    if (baseDir.trim().isEmpty || !_validDictionaryId.hasMatch(id)) return null;
    return '$baseDir${Platform.pathSeparator}$directoryName'
        '${Platform.pathSeparator}$id.keys';
  }

  /// 讀出可用的 key 清單；不存在、過期或損毀時回傳 null。
  Future<List<String>?> readAt({
    required String baseDir,
    required String id,
    required int sourceStamp,
  }) async {
    final path = pathFor(baseDir: baseDir, id: id);
    if (path == null) return null;
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      return decodeFodictKeys(
        await file.readAsBytes(),
        sourceStamp: sourceStamp,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> write({
    required String baseDir,
    required String id,
    required FodictKeyIndex index,
  }) async {
    final path = pathFor(baseDir: baseDir, id: id);
    if (path == null) return;
    try {
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(encodeFodictKeys(index), flush: false);
    } catch (_) {
      // 派生物寫不進去不影響搜尋，下次照樣重建。
    }
  }

  /// 刪掉不再屬於任何已安裝詞典的 `.keys`，避免卸掉詞典後留垃圾。
  Future<void> sweepOrphans({
    required String baseDir,
    required Set<String> installedIds,
  }) async {
    if (baseDir.trim().isEmpty) return;
    try {
      final directory = Directory(
        '$baseDir${Platform.pathSeparator}$directoryName',
      );
      if (!await directory.exists()) return;
      await for (final entity in directory.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (!name.endsWith('.keys')) continue;
        final id = name.substring(0, name.length - '.keys'.length);
        if (installedIds.contains(id)) continue;
        try {
          await entity.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }
}

var fodictKeyStore = FodictKeyStore();
