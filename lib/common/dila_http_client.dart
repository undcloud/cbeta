import 'dart:io';

import 'package:flutter/services.dart';

const dilaRootCertAsset = 'assets/certs/twca_cyber_root_ca_g3.pem';

/// cbdata.dila.edu.tw 的憑證鏈經 TWCA SSL Certification Authority 由
/// TWCA CYBER Root CA G3 簽發。這個根憑證較新，部分 Android 系統信任庫
/// 尚未收錄，連線會回 CERTIFICATE_VERIFY_FAILED。
///
/// 以全域 HttpOverrides 把根憑證補進自訂 SecurityContext，讓 package:http
/// 與 dart:io 建立的連線（經目、經卷、搜尋、AI 等）都能沿用。
class DilaHttpOverrides extends HttpOverrides {
  DilaHttpOverrides(Uint8List rootCertificate)
    : _rootCertificate = rootCertificate;

  final Uint8List _rootCertificate;
  SecurityContext? _context;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final securityContext =
        context ??
        (_context ??= SecurityContext(withTrustedRoots: true)
          ..setTrustedCertificatesBytes(_rootCertificate));
    return super.createHttpClient(securityContext);
  }
}

/// 需在 runApp 之前呼叫；憑證載入失敗時保留系統預設信任庫。
Future<void> installDilaTrust() async {
  try {
    final data = await rootBundle.load(dilaRootCertAsset);
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    HttpOverrides.global = DilaHttpOverrides(bytes);
  } catch (_) {
    // 資產遺失或格式錯誤時不阻斷啟動。
  }
}
