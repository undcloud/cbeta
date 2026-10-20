# Agent 开发说明

本文件面向 AI 编程 Agent，目标是减少重复探索与无效上下文。

## 项目概览

- Flutter App：CBETA 佛經閱讀、搜尋、AI 語意搜尋、離線經卷與自動更新。
- 入口：`lib/main.dart`，目前仍包含多數頁面與共用元件。
- 經文模型與解析：`lib/scripture/`（`models.dart`、`parser.dart`、`cache.dart`）。
- 顯示設定：`lib/settings/display_settings.dart`。
- 搜尋：`lib/search/`，包含簡繁轉換、搜尋歷史、Goto、候選排序與共用輸入框。
- AI：`lib/ai/`，包含 AI 搜尋網路層與 chunk 模型。
- 測試：`test/widget_test.dart`、`test/ai_service_test.dart`。
- 資產：`assets/`，其中簡繁表與詞組表很大，**不要整份讀取**。

## 常用命令

```bash
flutter pub get
dart format lib test
dart analyze lib test/widget_test.dart
flutter test test/widget_test.dart --name '關鍵測試名稱'
flutter test
flutter build apk --release --split-per-abi
```

開發時優先跑 `dart analyze` 與相關的單一 `--name` 測試，不要每次建置 release APK。

## 搜尋功能規則

- 五個入口：首頁、全文搜尋、卷內搜尋、經目查詢、作译者查詢。
- 使用 `lib/search/search_input.dart` 的實時候選面板。
- 候選生成後**不掃描本地經文、不統計命中數量**。
- 點擊候選會替換輸入框文字並立即搜尋。
- 不選擇直接提交時使用第一候選。
- Goto 僅首頁判斷。
- 顯示文字需跟隨簡繁設定，使用 `_displayText` / `textBuilder`。
- 修改搜尋邏輯時同步更新 `lib/search/feature_logic.md`。

## 程式碼慣例

- 優先把新功能放進對應的 `lib/` 子目錄，不要繼續膨脹 `lib/main.dart`。
- 保留既有 SharedPreferences key 與資料格式。
- 不要引入無限閃爍動畫；widget 測試的 `pumpAndSettle` 會卡住。
- 測試中的大量資產載入使用 `rootBundle.load`，避免 `loadString` 在 fake async 下卡住。
- 修改 Android 安裝流程時，保留 `FileProvider`、`PackageInstaller` 與權限引導。
- 修改備份相關設定時，保留 `backup_rules.xml` / `data_extraction_rules.xml`。

## 給 Agent 的上下文建議

1. 先用 `grep` 定位，再用 `read_file` 讀取行號範圍；不要整份讀 `main.dart`。
2. 不要讀 `build/`、`.dart_tool/`、`assets/hanzi_*.json`、`assets/phrases_*.json`。
3. 同一個任務尽量一次完成多個相關編輯，避免反覆載入上下文。
4. 先跑相關 `--name` 測試，再跑完整測試。
5. 遇到測試互相污染時，確認是否有 static cache 未重置（例如 `resetWorkPickerResponseCache`）。
