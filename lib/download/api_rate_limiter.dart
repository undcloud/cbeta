import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

/// CBETA API 的共用限流器：同一時間只送出一個請求，
/// 且任一秒最多 4 次、任一分鐘最多 30 次。
class ApiRateLimiter {
  ApiRateLimiter({
    this.maxPerSecond = 4,
    this.maxPerMinute = 30,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final int maxPerSecond;
  final int maxPerMinute;
  final DateTime Function() _clock;
  final Queue<DateTime> _requests = Queue<DateTime>();
  final Queue<_PendingRequest> _pending = Queue<_PendingRequest>();
  bool _draining = false;
  int _generation = 0;

  Future<T> run<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _pending.add(
      _PendingRequest(Zone.current, () async {
        try {
          completer.complete(await action());
        } catch (error, stackTrace) {
          completer.completeError(error, stackTrace);
        }
      }),
    );
    _drain();
    return completer.future;
  }

  void _drain() {
    if (_draining) return;
    _draining = true;
    unawaited(_processQueue(_generation));
  }

  Future<void> _processQueue(int generation) async {
    try {
      while (_pending.isNotEmpty && generation == _generation) {
        final request = _pending.removeFirst();
        await _waitForSlot();
        if (generation != _generation) return;
        await request.zone.run(request.execute);
      }
    } finally {
      if (generation == _generation) _draining = false;
    }
  }

  Future<void> _waitForSlot() async {
    while (true) {
      final now = _clock();
      _requests.removeWhere(
        (request) => now.difference(request) >= const Duration(minutes: 1),
      );
      final inLastSecond = _requests
          .where(
            (request) => now.difference(request) < const Duration(seconds: 1),
          )
          .length;
      if (_requests.length < maxPerMinute && inLastSecond < maxPerSecond) {
        _requests.add(now);
        return;
      }

      Duration wait;
      if (_requests.length >= maxPerMinute) {
        wait =
            const Duration(minutes: 1) -
            now.difference(_requests.first) +
            const Duration(milliseconds: 10);
      } else {
        final oldestInSecond = _requests.firstWhere(
          (request) => now.difference(request) < const Duration(seconds: 1),
        );
        wait =
            const Duration(seconds: 1) -
            now.difference(oldestInSecond) +
            const Duration(milliseconds: 10);
      }
      await Future<void>.delayed(wait.isNegative ? Duration.zero : wait);
    }
  }

  @visibleForTesting
  void debugReset() {
    _generation++;
    _pending.clear();
    _requests.clear();
    _draining = false;
  }
}

class _PendingRequest {
  _PendingRequest(this.zone, this.execute);

  final Zone zone;
  final Future<void> Function() execute;
}

final apiRateLimiter = ApiRateLimiter();
