import 'package:shared_preferences/shared_preferences.dart';

/// 關鍵字正文搜尋是否只看本地經卷，不把請求發給 CBETA 全文 API。
///
/// 常用單字在伺服端要跑十幾秒（實測「來」26 秒），已經下載經卷的使用者寧可
/// 立刻掃本地。預設關：多數人還是希望拿到伺服器的完整命中統計。
const String offlineKeywordSearchOnlyKey = 'search_offline_only';

bool offlineKeywordSearchOnly = false;

Future<void> loadOfflineKeywordSearchOnly() async {
  try {
    final preferences = await SharedPreferences.getInstance();
    offlineKeywordSearchOnly =
        preferences.getBool(offlineKeywordSearchOnlyKey) ?? false;
  } catch (_) {
    // 讀不到設定就用預設值，不擋搜尋。
  }
}

Future<void> setOfflineKeywordSearchOnly(bool value) async {
  offlineKeywordSearchOnly = value;
  try {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(offlineKeywordSearchOnlyKey, value);
  } catch (_) {
    // 存不下也至少在本次執行期間生效。
  }
}
