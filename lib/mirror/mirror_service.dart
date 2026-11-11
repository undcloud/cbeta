import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'mirror_config.dart';
import 'mirror_identity.dart';
import 'mirror_models.dart';

class MirrorException implements Exception {
  const MirrorException(this.message, {this.retryable = false});

  final String message;
  final bool retryable;

  @override
  String toString() => message;
}

class MirrorBusyException extends MirrorException {
  const MirrorBusyException(super.message, {this.retryAfter});

  final Duration? retryAfter;
}

class MirrorCancelledException extends MirrorException {
  const MirrorCancelledException() : super('已暫停鏡像下載');
}

class MirrorService {
  static const _userAgent = 'FodianMirror/1.0';

  static Future<MirrorProbe> probe(MirrorConfig config) async {
    if (!config.enabled) {
      return const MirrorProbe(reachable: false, error: '鏡像下載未啟用');
    }
    if (config.baseUrl.isEmpty) {
      return const MirrorProbe(reachable: false, error: '鏡像地址未設定');
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final request = await client
          .headUrl(config.zipUri)
          .timeout(const Duration(seconds: 8));
      request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      request.headers.set('X-Fodian-Device', await MirrorIdentity.deviceId());
      final response = await request.close().timeout(
        const Duration(seconds: 8),
      );
      final size =
          int.tryParse(
            response.headers.value(HttpHeaders.contentLengthHeader) ?? '',
          ) ??
          0;
      final etag = (response.headers.value(HttpHeaders.etagHeader) ?? '')
          .replaceAll('"', '')
          .trim();
      final release =
          (response.headers.value('x-mirror-release') ?? config.release).trim();
      final lastModified =
          response.headers.value(HttpHeaders.lastModifiedHeader) ?? '';
      final acceptRanges =
          (response.headers.value(HttpHeaders.acceptRangesHeader) ?? '')
              .toLowerCase()
              .contains('bytes');
      await response.drain<void>().timeout(const Duration(seconds: 3));
      if (response.statusCode != 200 && response.statusCode != 206) {
        return MirrorProbe(
          reachable: true,
          error: '鏡像接口回傳 ${response.statusCode}',
        );
      }
      return MirrorProbe(
        reachable: true,
        size: size,
        etag: etag,
        lastModified: lastModified,
        release: release,
        acceptsRanges: acceptRanges,
      );
    } on SocketException {
      return const MirrorProbe(reachable: false, error: '無法連接鏡像服務');
    } on TimeoutException {
      return const MirrorProbe(reachable: false, error: '鏡像服務回應逾時');
    } on HandshakeException {
      return const MirrorProbe(reachable: false, error: '鏡像服務連線失敗');
    } on HttpException catch (error) {
      return MirrorProbe(reachable: false, error: error.message);
    } catch (error) {
      return MirrorProbe(reachable: false, error: '鏡像探測失敗：$error');
    } finally {
      client.close(force: true);
    }
  }

  /// 下載或續傳到 [partFile]。完成後呼叫端再把 `.part` 改名。
  ///
  /// 一次嘗試只處理一個 HTTP 回應；中斷、429/503 由呼叫端退避後重試，
  /// `.part` 保留即可續傳。
  static Future<void> download({
    required MirrorConfig config,
    required MirrorProbe probe,
    required File partFile,
    required String deviceId,
    required String session,
    required bool Function() isCancelled,
    required void Function(int received, int total) onProgress,
    required void Function(int bytes) onBytes,
  }) async {
    var existing = 0;
    if (await partFile.exists()) {
      existing = await partFile.length();
    }
    if (probe.size > 0 && existing > probe.size) {
      await partFile.delete();
      existing = 0;
    }
    if (probe.size > 0 && existing == probe.size) {
      onProgress(existing, probe.size);
      return;
    }

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..idleTimeout = const Duration(seconds: 30);
    try {
      final request = await client
          .getUrl(config.zipUri)
          .timeout(const Duration(seconds: 15));
      request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      request.headers.set('X-Fodian-Device', deviceId);
      request.headers.set('X-Fodian-Session', session);
      if (existing > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$existing-');
        if (probe.etag.isNotEmpty) {
          request.headers.set(
            HttpHeaders.ifRangeHeader,
            probe.etag.startsWith('"') ? probe.etag : '"${probe.etag}"',
          );
        }
      }
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );

      final status = response.statusCode;
      if (status == HttpStatus.requestedRangeNotSatisfiable) {
        await response.drain<void>();
        if (probe.size > 0 && existing == probe.size) {
          onProgress(existing, probe.size);
          return;
        }
        await partFile.delete();
        throw const MirrorException('續傳位置已失效，請重新下載', retryable: true);
      }
      if (status == HttpStatus.tooManyRequests ||
          status == HttpStatus.serviceUnavailable) {
        final retryAfter = _retryAfter(response);
        final body = await _readErrorBody(response);
        throw MirrorBusyException(
          body.isEmpty ? '鏡像下載人數已滿' : body,
          retryAfter: retryAfter,
        );
      }
      if (status != HttpStatus.ok && status != HttpStatus.partialContent) {
        final body = await _readErrorBody(response);
        throw MirrorException('鏡像下載失敗（$status）${body.isEmpty ? '' : '：$body'}');
      }

      if (status == HttpStatus.ok && existing > 0) {
        // 伺服器忽略 Range（或 If-Range 不符），必須從零開始。
        await response.drain<void>();
        await partFile.delete();
        throw const MirrorException('伺服器改為重新傳送，正在從頭下載', retryable: true);
      }

      if (status == HttpStatus.partialContent && existing > 0) {
        final start = _contentRangeStart(response);
        if (start >= 0 && start != existing) {
          await response.drain<void>();
          await partFile.delete();
          throw const MirrorException('續傳區間不符，正在重新下載', retryable: true);
        }
      }

      final total = _contentRangeTotal(response) ?? probe.size;
      var received = existing;
      final handle = await partFile.open(mode: FileMode.append);
      try {
        await for (final chunk in response.timeout(
          const Duration(seconds: 90),
        )) {
          if (isCancelled()) throw const MirrorCancelledException();
          await handle.writeFrom(chunk);
          received += chunk.length;
          onBytes(chunk.length);
          onProgress(received, total > 0 ? total : received);
        }
        await handle.flush();
      } finally {
        await handle.close();
      }
      if (total > 0 && received < total) {
        throw MirrorException(
          '下載中斷（${_formatPercent(received, total)}），可續傳',
          retryable: true,
        );
      }
    } on MirrorException {
      rethrow;
    } on SocketException {
      throw const MirrorException('網路連線中斷', retryable: true);
    } on TimeoutException {
      throw const MirrorException('下載停滯逾時', retryable: true);
    } on HttpException catch (error) {
      throw MirrorException('下載失敗：${error.message}', retryable: true);
    } finally {
      client.close(force: true);
    }
  }

  static Duration? _retryAfter(HttpClientResponse response) {
    final raw = response.headers.value(HttpHeaders.retryAfterHeader);
    final seconds = int.tryParse(raw ?? '');
    if (seconds == null || seconds <= 0) return null;
    return Duration(seconds: seconds.clamp(1, 600));
  }

  static Future<String> _readErrorBody(HttpClientResponse response) async {
    try {
      final text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 3));
      return text.length > 200 ? text.substring(0, 200) : text;
    } catch (_) {
      return '';
    }
  }

  static int? _contentRangeTotal(HttpClientResponse response) {
    final value = response.headers.value(HttpHeaders.contentRangeHeader);
    if (value == null) return null;
    final slash = value.lastIndexOf('/');
    if (slash < 0) return null;
    return int.tryParse(value.substring(slash + 1));
  }

  static int _contentRangeStart(HttpClientResponse response) {
    final value = response.headers.value(HttpHeaders.contentRangeHeader);
    if (value == null) return -1;
    final match = RegExp(r'bytes\s+(\d+)-').firstMatch(value);
    return match == null ? -1 : int.tryParse(match.group(1)!) ?? -1;
  }

  static String _formatPercent(int received, int total) =>
      '${(received * 100 / total).toStringAsFixed(1)}%';
}
