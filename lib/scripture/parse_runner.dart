import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart' show kIsWeb;

import 'models.dart';
import 'parser.dart';

/// `flutter test` 的 fake-async 綁定不會推進真實 isolate 的回覆，網頁版也
/// 沒有必要為此開背景 isolate；兩種情況都直接在主 isolate 解析。
bool parseSupportsIsolate() =>
    !kIsWeb && !Platform.environment.containsKey('FLUTTER_TEST');

/// 整卷 HTML 解析放到背景 isolate，避免主 isolate 的 DOM 與暫存字串把
/// heap 高水位推高，也讓捲動／換卷在解析期間維持回應。
Future<List<ScriptureLine>> parseScriptureHtmlAsync(String source) {
  if (!parseSupportsIsolate()) {
    return Future.sync(() => parseScriptureHtml(source));
  }
  return Isolate.run(() => parseScriptureHtml(source));
}
