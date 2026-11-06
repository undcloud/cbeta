import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 全域離線模式：正文閱讀與正文搜尋都只使用本地經卷，不請求 CBETA。
///
/// 這個 key 舊版只控制正文搜尋（`search_offline_only`），現在沿用同一個
/// key 升級為全域模式，避免使用者升級後設定被重置。
const String offlineModeKey = 'search_offline_only';

bool offlineMode = false;

/// 讓已開啟的頁面（例如閱讀器）能跟著模式切換重新取源。
final ValueNotifier<bool> offlineModeListenable = ValueNotifier<bool>(false);

Future<void> loadOfflineMode() async {
  try {
    final preferences = await SharedPreferences.getInstance();
    final value = preferences.getBool(offlineModeKey) ?? false;
    offlineMode = value;
    offlineModeListenable.value = value;
  } catch (_) {
    // 讀不到設定就用預設值（聯網），不擋搜尋與閱讀。
  }
}

Future<void> setOfflineMode(bool value) async {
  if (offlineMode != value) {
    offlineMode = value;
    offlineModeListenable.value = value;
  }
  try {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(offlineModeKey, value);
  } catch (_) {
    // 存不下也至少在本次執行期間生效。
  }
}

@visibleForTesting
void resetOfflineModeForTest() {
  offlineMode = false;
  offlineModeListenable.value = false;
}
