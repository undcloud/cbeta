import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// 鏡像暫存與匯出。
///
/// Android 10+ 用 MediaStore 写入公有 `Download/Fodian`，不需要儲存權限；
/// 暫存 ZIP 放在 App 專屬外部目錄（`getExternalFilesDir`），也不需要權限。
/// Android 9 及以下若無法写入公有目錄，ZIP 會留在私有目錄。
class MirrorStorage {
  static const _channel = MethodChannel('xuefo/mirror_storage');

  static bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<Directory> tempDirectory() async {
    if (_android) {
      try {
        final path = await _channel.invokeMethod<String>('getTempDirectory');
        if (path != null && path.isNotEmpty) {
          final directory = Directory(path);
          await directory.create(recursive: true);
          return directory;
        }
      } on MissingPluginException {
        // 舊安裝沒有原生通道，退回 App Support。
      } on PlatformException catch (error) {
        debugPrint('取得鏡像暫存目錄失敗: ${error.message}');
      }
    }
    final support = await getApplicationSupportDirectory();
    final directory = Directory(
      '${support.path}${Platform.pathSeparator}mirror',
    );
    await directory.create(recursive: true);
    return directory;
  }

  /// 回傳可用位元組；無法查詢時回傳 -1（呼叫端跳過空間檢查）。
  static Future<int> freeBytes(Directory directory) async {
    if (!_android) return -1;
    try {
      return await _channel.invokeMethod<int>('getFreeBytes', {
            'path': directory.path,
          }) ??
          -1;
    } on MissingPluginException {
      return -1;
    } on PlatformException {
      return -1;
    }
  }

  /// 把私有 ZIP 匯出到公有 Downloads；成功回傳公開路徑/URI，失敗回傳 null。
  static Future<String?> exportZip(
    String sourcePath, {
    String fileName = 'cbeta_html_full.zip',
  }) async {
    if (!_android) return null;
    try {
      return await _channel.invokeMethod<String>('exportToDownloads', {
        'sourcePath': sourcePath,
        'fileName': fileName,
      });
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      debugPrint('匯出鏡像 ZIP 失敗: ${error.message}');
      return null;
    }
  }

  /// 公有 Downloads 裡是否已有同名 ZIP；回傳位置字串。
  static Future<String?> publicZipLocation({
    String fileName = 'cbeta_html_full.zip',
  }) async {
    if (!_android) return null;
    try {
      return await _channel.invokeMethod<String>('publicZipLocation', {
        'fileName': fileName,
      });
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// 把公有 ZIP 複製回私有目錄（重新匯入時重用）。
  static Future<bool> copyPublicToPrivate(
    String destPath, {
    String fileName = 'cbeta_html_full.zip',
  }) async {
    if (!_android) return false;
    try {
      return await _channel.invokeMethod<bool>('copyPublicToPrivate', {
            'destPath': destPath,
            'fileName': fileName,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (error) {
      debugPrint('取回公有鏡像 ZIP 失敗: ${error.message}');
      return false;
    }
  }
}
