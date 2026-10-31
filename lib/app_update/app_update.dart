import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import '../widgets/display_text.dart';

const giteeOwner = 'undclouds';
const giteeRepo = 'cbeta';

/// Gitee 的 `latest` 別名會永遠指向最新發行版中同名的附件，
/// 因此可作為固定不變的下載連結。
const giteeLatestDownloadBase =
    'https://gitee.com/$giteeOwner/$giteeRepo/releases/download/latest';
const latestApkDownloadUrl =
    '$giteeLatestDownloadBase/app-arm64-v8a-release.apk';
const appUpdaterChannel = MethodChannel('xuefo/app_updater');
const pendingUpdatePathKey = 'pending_update_apk_path';
const pendingUpdateVersionKey = 'pending_update_version';

enum InstallPermissionAction { cancel, proceed, settings }

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.version,
    required this.downloadUrl,
    required this.releaseName,
    required this.releaseNotes,
  });
  final String version;
  final String downloadUrl;
  final String releaseName;
  final String releaseNotes;
}

/// 從 Gitee Releases API 取得最新版本資訊。
Future<AppUpdateInfo?> fetchLatestGiteeRelease({
  List<String> preferredAbis = const [],
}) async {
  if (kIsWeb) return null;
  final response = await http
      .get(
        Uri.https(
          'gitee.com',
          '/api/v5/repos/$giteeOwner/$giteeRepo/releases/latest',
        ),
      )
      .timeout(const Duration(seconds: 15));
  if (response.statusCode != 200) return null;
  final payload =
      jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  final version = '${payload['tag_name'] ?? ''}'.trim();
  if (version.isEmpty) return null;
  final apkAssets = (payload['assets'] as List<dynamic>? ?? const [])
      .whereType<Map<String, dynamic>>()
      .where((asset) => '${asset['name'] ?? ''}'.toLowerCase().endsWith('.apk'))
      .toList();
  if (apkAssets.isEmpty) return null;

  Map<String, dynamic>? preferred;
  final abiOrder = <String>[
    ...preferredAbis,
    ...const ['arm64-v8a', 'armeabi-v7a', 'x86_64'],
  ];
  for (final abi in abiOrder) {
    for (final asset in apkAssets) {
      if ('${asset['name']}'.contains(abi)) {
        preferred = asset;
        break;
      }
    }
    if (preferred != null) break;
  }
  preferred ??= apkAssets.first;
  final assetName = '${preferred['name'] ?? ''}'.trim();
  final downloadUrl = assetName.isEmpty
      ? '${preferred['browser_download_url'] ?? ''}'
      : '$giteeLatestDownloadBase/${Uri.encodeComponent(assetName)}';
  if (downloadUrl.isEmpty) return null;
  return AppUpdateInfo(
    version: version,
    downloadUrl: downloadUrl,
    releaseName: '${payload['name'] ?? version}',
    releaseNotes: '${payload['body'] ?? ''}',
  );
}

/// 版本號比較：支援 `v1.2.3`、`1.2`、`1.0.0+4` 等格式，缺少的區段視為 0。
bool isNewerVersion(String latest, String current) {
  List<int> parts(String version) {
    final normalized = version.trim().replaceFirst(RegExp(r'^[vV]'), '');
    final core =
        RegExp(r'^\d+(?:\.\d+)*').firstMatch(normalized)?.group(0) ?? '0';
    return core.split('.').map((part) => int.tryParse(part) ?? 0).toList();
  }

  final latestParts = parts(latest);
  final currentParts = parts(current);
  final length = latestParts.length > currentParts.length
      ? latestParts.length
      : currentParts.length;
  for (var index = 0; index < length; index++) {
    final left = index < latestParts.length ? latestParts[index] : 0;
    final right = index < currentParts.length ? currentParts[index] : 0;
    if (left != right) return left > right;
  }
  return false;
}

/// Android 是否已允許本 App 安裝 APK（Android 8.0 以上需使用者授權）。
Future<bool> canInstallApk() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
  try {
    return await appUpdaterChannel.invokeMethod<bool>('canInstallPackages') ??
        false;
  } on PlatformException {
    return false;
  } on MissingPluginException {
    return false;
  }
}

Future<List<String>> deviceAbis() async {
  try {
    final abis = await appUpdaterChannel.invokeMethod<List<Object?>>(
      'supportedAbis',
    );
    return abis?.whereType<String>().toList() ?? const [];
  } on PlatformException {
    return const [];
  } on MissingPluginException {
    return const [];
  }
}

Future<void> openInstallPermissionSettings() async {
  if (kIsWeb) return;
  try {
    await appUpdaterChannel.invokeMethod<void>('openInstallPermissionSettings');
  } on PlatformException {
    // 忽略：無法開啟設定頁時，使用者仍可自行前往系統設定。
  } on MissingPluginException {
    // 忽略：非 Android 平台沒有此通道。
  }
}

/// 下載更新 APK 到暫存目錄，並回報下載進度（0.0–1.0）。
Future<String> downloadUpdateApk(
  AppUpdateInfo info,
  ValueNotifier<double?> progress,
) async {
  final tempDirectory = await getTemporaryDirectory();
  final directory = Directory(
    '${tempDirectory.path}${Platform.pathSeparator}cbeta_update',
  );
  if (await directory.exists()) {
    await for (final entity in directory.list()) {
      if (entity is File) {
        try {
          await entity.delete();
        } catch (_) {
          // 舊檔無法刪除時忽略，後續仍可寫入新檔。
        }
      }
    }
  } else {
    await directory.create(recursive: true);
  }
  final file = File(
    '${directory.path}${Platform.pathSeparator}cbeta-${info.version}.apk',
  );
  final client = http.Client();
  IOSink? sink;
  try {
    final request = http.Request('GET', Uri.parse(info.downloadUrl));
    final response = await client
        .send(request)
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw Exception('下載失敗（HTTP ${response.statusCode}）');
    }
    final total = response.contentLength ?? 0;
    var received = 0;
    sink = file.openWrite();
    await for (final chunk in response.stream) {
      sink.add(chunk);
      received += chunk.length;
      if (total > 0) {
        progress.value = (received / total).clamp(0.0, 1.0);
      }
    }
    await sink.close();
    sink = null;
    progress.value = 1;
    return file.path;
  } catch (error) {
    try {
      await sink?.close();
    } catch (_) {
      // 忽略關閉串流時的次要錯誤。
    }
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 忽略暫存檔刪除失敗。
    }
    rethrow;
  } finally {
    client.close();
  }
}

class InstallPermissionRequiredException implements Exception {
  const InstallPermissionRequiredException(this.message);

  final String message;

  @override
  String toString() => message;
}

Future<void> launchApkInstaller(String apkPath) async {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    try {
      // 使用 PackageInstaller 工作階段，來源明確為本 App。
      await appUpdaterChannel.invokeMethod<void>('installApk', {
        'path': apkPath,
      });
      return;
    } on PlatformException catch (error) {
      if (error.code == 'permission_denied') {
        throw InstallPermissionRequiredException(error.message ?? '缺少安裝應用程式權限');
      }
      // 原生安裝失敗時改用 open_filex 作為後備。
      try {
        await openApkWithFilex(apkPath);
        return;
      } catch (_) {
        throw Exception(error.message ?? '無法啟動安裝程式');
      }
    } on MissingPluginException {
      // 舊版原生端沒有 installApk，改用 open_filex。
    }
  }
  await openApkWithFilex(apkPath);
}

Future<void> openApkWithFilex(String apkPath) async {
  final result = await OpenFilex.open(
    apkPath,
    type: 'application/vnd.android.package-archive',
  );
  if (result.type != ResultType.done) {
    throw Exception(result.message.isEmpty ? '無法啟動安裝程式' : result.message);
  }
}

class UpdateProgressDialog extends StatelessWidget {
  const UpdateProgressDialog({
    super.key,
    required this.progress,
    required this.version,
  });

  final ValueNotifier<double?> progress;
  final String version;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('正在下載 $version'),
    content: ValueListenableBuilder<double?>(
      valueListenable: progress,
      builder: (context, value, _) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LinearProgressIndicator(value: value),
          const SizedBox(height: 12),
          Text(
            value == null
                ? '正在連線…'
                : '${(value * 100).clamp(0, 100).toStringAsFixed(0)}%',
          ),
        ],
      ),
    ),
  );
}
