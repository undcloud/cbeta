import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// 建立 TCP／TLS 連線的期限。回應本身仍由各 API 自己的逾時控制，
/// 常用字在伺服端算十幾秒是正常的，不能把「慢」誤判成「斷線」。
const Duration cbetaConnectTimeout = Duration(seconds: 5);

class CbetaConnectionException implements Exception {
  const CbetaConnectionException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

/// 建立 CBETA 請求用的 client。
///
/// 測試以 `http.runWithClient` 注入 MockClient 時沿用注入的 client；
/// 正式環境則換成一個 `connectionTimeout` 為 5 秒的 IOClient，斷網時
/// 不會卡在 TCP 連線直到整體請求逾時。
http.Client createCbetaHttpClient() {
  final client = http.Client();
  if (client is IOClient) {
    client.close();
    return IOClient(HttpClient()..connectionTimeout = cbetaConnectTimeout);
  }
  return client;
}

bool isCbetaConnectionFailure(Object error) =>
    error is CbetaConnectionException ||
    error is SocketException ||
    error is http.ClientException ||
    error is HandshakeException;

String describeCbetaConnectionError(Object error) {
  if (error is CbetaConnectionException) return error.message;
  if (error is SocketException) return '無法連接 CBETA 伺服器';
  if (error is HandshakeException) return '無法建立安全連線：${error.message}';
  if (error is http.ClientException) {
    return '連線 CBETA 伺服器失敗：${error.message}';
  }
  return '無法連接 CBETA 伺服器';
}

CbetaConnectionException asCbetaConnectionException(Object error) =>
    error is CbetaConnectionException
    ? error
    : CbetaConnectionException(
        describeCbetaConnectionError(error),
        cause: error,
      );
