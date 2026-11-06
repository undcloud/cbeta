import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../cbeta_api_headers.dart';
import '../common/cbeta_http_client.dart';
import 'sidx_store.dart';

class CachedScriptureVolume {
  const CachedScriptureVolume({
    required this.work,
    required this.juan,
    required this.html,
    this.contentVersion,
  });

  final String work;
  final String juan;
  final String html;
  final String? contentVersion;

  String get key => '$work:$juan';

  factory CachedScriptureVolume.fromJson(Map<String, dynamic> json) {
    final work = json['work'];
    final juan = json['juan'];
    final html = json['html'];
    final contentVersion = json['contentVersion'];
    if (work is! String ||
        juan is! String ||
        html is! String ||
        (contentVersion != null && contentVersion is! String)) {
      throw const FormatException('離線經文資料格式無效');
    }
    return CachedScriptureVolume(
      work: work,
      juan: juan,
      html: html,
      contentVersion: contentVersion as String?,
    );
  }

  Map<String, Object?> toJson() => {
    'work': work,
    'juan': juan,
    'html': html,
    'contentVersion': contentVersion,
  };
}

class ScriptureVolumeRef {
  const ScriptureVolumeRef({required this.work, required this.juan, this.path});

  final String work;
  final String juan;
  final String? path;

  String get key => '$work:$juan';
}

class ScriptureVolumeStore {
  ScriptureVolumeStore({Future<Directory> Function()? directoryProvider})
    : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory;

  static const _webKeyPrefix = 'cbeta_scripture_volume:';
  static final RegExp _workPattern = RegExp(r'^[A-Za-z0-9]+$');
  static final RegExp _juanPattern = RegExp(r'^\d+$');
  final Future<Directory> Function() _directoryProvider;

  /// 經卷清單只跟「經卷世代」有關；兩萬卷時每次搜尋重掃目錄要上百毫秒，
  /// 世代沒變就直接重用。任何一次寫入／清空都會推進世代或清掉這份快取。
  List<ScriptureVolumeRef>? _refsCache;
  int? _refsGeneration;

  String _validateKey(String work, String juan) {
    if (!_workPattern.hasMatch(work) || !_juanPattern.hasMatch(juan)) {
      throw FormatException('無效的經卷識別碼：$work 卷 $juan');
    }
    return '$work-$juan';
  }

  Future<Directory> _cacheDirectory() async {
    final supportDirectory = await _directoryProvider();
    final directory = Directory(
      '${supportDirectory.path}${Platform.pathSeparator}cbeta_scripture',
    );
    await directory.create(recursive: true);
    return directory;
  }

  Future<CachedScriptureVolume?> read(String work, String juan) async {
    final fileKey = _validateKey(work, juan);
    final String? stored;
    if (kIsWeb) {
      stored = (await SharedPreferences.getInstance()).getString(
        '$_webKeyPrefix$fileKey',
      );
    } else {
      final directory = await _cacheDirectory();
      final file = File(
        '${directory.path}${Platform.pathSeparator}$fileKey.json',
      );
      stored = await file.exists() ? await file.readAsString() : null;
    }
    if (stored == null) return null;
    final volume = CachedScriptureVolume.fromJson(
      jsonDecode(stored) as Map<String, dynamic>,
    );
    if (volume.work != work || volume.juan != juan) {
      throw FormatException('離線經卷識別碼不符：$work 卷 $juan');
    }
    return volume;
  }

  /// 經卷檔案的预期路徑（不保證存在）。背景索引工作只需要字串路徑，
  /// 不該為了找一卷的檔案而把整個目錄列一遍。
  Future<String> pathFor(String work, String juan) async {
    final fileKey = _validateKey(work, juan);
    final directory = await _cacheDirectory();
    return '${directory.path}${Platform.pathSeparator}$fileKey.json';
  }

  /// 只列出已儲存經卷的識別碼，不讀取經文內容，供大量經卷搜尋使用。
  Future<List<ScriptureVolumeRef>> listRefs() async {
    if (kIsWeb) {
      final preferences = await SharedPreferences.getInstance();
      final refs = <ScriptureVolumeRef>[];
      for (final key in preferences.getKeys()) {
        if (!key.startsWith(_webKeyPrefix)) continue;
        final ref = _refFromKey(key.substring(_webKeyPrefix.length));
        if (ref != null) refs.add(ref);
      }
      return refs;
    }
    final directory = await _cacheDirectory();
    if (!await directory.exists()) return const [];
    final generation = await readVolumesGeneration(directory);
    final cached = _refsCache;
    if (cached != null && _refsGeneration == generation) return cached;
    final refs = <ScriptureVolumeRef>[];
    await for (final entity in directory.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      final name = entity.uri.pathSegments.last;
      final ref = _refFromKey(name.substring(0, name.length - 5));
      if (ref != null) {
        refs.add(
          ScriptureVolumeRef(work: ref.work, juan: ref.juan, path: entity.path),
        );
      }
    }
    _refsCache = refs;
    _refsGeneration = generation;
    return refs;
  }

  Future<CachedScriptureVolume?> readRef(ScriptureVolumeRef ref) async {
    try {
      if (kIsWeb) {
        return read(ref.work, ref.juan);
      }
      final path = ref.path ?? '';
      if (path.isEmpty) return read(ref.work, ref.juan);
      final file = File(path);
      if (!await file.exists()) return null;
      return CachedScriptureVolume.fromJson(
        jsonDecode(await file.readAsString()) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }

  static ScriptureVolumeRef? _refFromKey(String fileKey) {
    final separator = fileKey.lastIndexOf('-');
    if (separator <= 0 || separator >= fileKey.length - 1) return null;
    final work = fileKey.substring(0, separator);
    final juan = fileKey.substring(separator + 1);
    if (!_workPattern.hasMatch(work) || !_juanPattern.hasMatch(juan)) {
      return null;
    }
    return ScriptureVolumeRef(work: work, juan: juan);
  }

  /// 寫入經卷並回傳檔案路徑（網頁版回傳空字串）；下載流程用它把索引工作
  /// 直接交給背景建置佇列，不必再推一次路徑。
  Future<String> write(CachedScriptureVolume volume) async {
    final fileKey = _validateKey(volume.work, volume.juan);
    final stored = jsonEncode(volume.toJson());
    if (kIsWeb) {
      final saved = await (await SharedPreferences.getInstance()).setString(
        '$_webKeyPrefix$fileKey',
        stored,
      );
      if (!saved) throw StateError('無法儲存離線經文：${volume.key}');
      return '';
    }
    final directory = await _cacheDirectory();
    // 先推進世代再寫檔：掃描端讀到新世代就會重新 stat；反過來（先寫檔）
    // 若中途斷電會留下「內容已換、世代沒動」的窗口，舊索引會被誤信。
    await bumpVolumesGeneration(directory);
    final file = File(
      '${directory.path}${Platform.pathSeparator}$fileKey.json',
    );
    await file.writeAsString(stored, flush: true);
    // 寫入期間可能已有 listRefs 讀到「世代已前進、檔案還沒出現」的空窗，
    // 這裡清一次，讓下一次清單重建時一定看得到這一卷。
    _refsCache = null;
    // 經卷是真相源，`.sidx` 只是派生物；內容換了就丟（含記憶體裡那一份），
    // 下次掃描或建置佇列會重建。
    await scriptureIndexStore.deleteAt(work: volume.work, juan: volume.juan);
    return file.path;
  }

  Future<List<CachedScriptureVolume>> list() async {
    if (kIsWeb) {
      final preferences = await SharedPreferences.getInstance();
      final volumes = <CachedScriptureVolume>[];
      for (final key in preferences.getKeys().where(
        (key) => key.startsWith(_webKeyPrefix),
      )) {
        final stored = preferences.getString(key);
        if (stored != null) {
          volumes.add(
            CachedScriptureVolume.fromJson(
              jsonDecode(stored) as Map<String, dynamic>,
            ),
          );
        }
      }
      return volumes;
    }
    final directory = await _cacheDirectory();
    if (!await directory.exists()) return const [];
    final files = await directory
        .list()
        .where((entity) => entity is File && entity.path.endsWith('.json'))
        .cast<File>()
        .toList();
    final volumes = <CachedScriptureVolume>[];
    for (final file in files) {
      volumes.add(
        CachedScriptureVolume.fromJson(
          jsonDecode(await file.readAsString()) as Map<String, dynamic>,
        ),
      );
    }
    return volumes;
  }

  Future<void> clearAll() async {
    if (kIsWeb) {
      final preferences = await SharedPreferences.getInstance();
      for (final key in preferences.getKeys().where(
        (key) => key.startsWith(_webKeyPrefix),
      )) {
        final removed = await preferences.remove(key);
        if (!removed) throw StateError('無法清除離線經文快取：$key');
      }
      return;
    }
    final directory = await _cacheDirectory();
    if (!await directory.exists()) return;
    await bumpVolumesGeneration(directory);
    _refsCache = null;
    await for (final entity in directory.list()) {
      if (entity is File && entity.path.endsWith('.json')) {
        await entity.delete();
      }
    }
    await scriptureIndexStore.clearAll();
  }
}

String _volumesGenerationFilePath(Directory directory) =>
    '${directory.path}${Platform.pathSeparator}.generation';

/// 經卷目錄的世代：檔案長度就是寫入次數。
///
/// 掃描用它判斷「上次完整建索引之後，有沒有任何一卷被寫過」，不必逐卷
/// `stat` 兩萬個 `.json`。只追加、不改寫，並發寫入也不會互相覆蓋。
Future<void> bumpVolumesGeneration(Directory directory) async {
  try {
    await File(
      _volumesGenerationFilePath(directory),
    ).writeAsBytes(const <int>[1], mode: FileMode.append, flush: true);
  } catch (_) {
    // 世代檔寫不了只會讓下次掃描多做一點 stat，不影響正確性。
  }
}

int readVolumesGenerationSync(Directory directory) {
  try {
    final file = File(_volumesGenerationFilePath(directory));
    return file.existsSync() ? file.lengthSync() : 0;
  } catch (_) {
    return 0;
  }
}

Future<int> readVolumesGeneration(Directory directory) async {
  try {
    final file = File(_volumesGenerationFilePath(directory));
    return await file.exists() ? await file.length() : 0;
  } catch (_) {
    return 0;
  }
}

var scriptureVolumeStore = ScriptureVolumeStore();

Future<CachedScriptureVolume> fetchScriptureVolume(
  String work,
  String juan, {
  void Function(int bytes)? onBytesReceived,
  http.Client? client,
}) async {
  final ownsClient = client == null;
  final httpClient = client ?? createCbetaHttpClient();
  final Map<String, dynamic> payload;
  try {
    final request = http.Request(
      'GET',
      Uri.https('cbdata.dila.edu.tw', '/stable/juans', {
        'work': work,
        'juan': juan,
      }),
    )..headers.addAll(cbetaApiHeaders);
    final http.StreamedResponse response;
    try {
      response = await httpClient
          .send(request)
          .timeout(const Duration(seconds: 20));
    } on TimeoutException {
      rethrow;
    } catch (error) {
      if (isCbetaConnectionFailure(error)) {
        throw asCbetaConnectionException(error);
      }
      rethrow;
    }
    if (response.statusCode != 200) {
      throw Exception('經卷 API 回傳 ${response.statusCode}');
    }
    final bytes = BytesBuilder(copy: false);
    await response.stream
        .forEach((chunk) {
          bytes.add(chunk);
          onBytesReceived?.call(chunk.length);
        })
        .timeout(const Duration(seconds: 20));
    payload =
        jsonDecode(utf8.decode(bytes.takeBytes())) as Map<String, dynamic>;
  } finally {
    if (ownsClient) httpClient.close();
  }
  if (payload['success'] == false) {
    throw Exception('CBETA 經卷下載失敗：${payload['error'] ?? '未知錯誤'}');
  }
  final html = (payload['results'] as List<dynamic>? ?? const [])
      .whereType<String>()
      .firstOrNull;
  if (html == null || html.isEmpty) {
    throw FormatException('CBETA 未回傳經卷內容：$work 卷 $juan');
  }
  return CachedScriptureVolume(
    work: work,
    juan: juan,
    html: html,
    contentVersion: payload['content'] as String?,
  );
}
