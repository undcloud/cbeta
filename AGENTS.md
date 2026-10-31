# Agent 开发说明

本文件面向 AI 编程 Agent，目标是减少重复探索与无效上下文。

## 项目概览

- Flutter App：CBETA 佛經閱讀、搜尋、AI 語意搜尋、離線經卷與自動更新。
- 入口：`lib/main.dart`（約 190 行）：`main()`、`CbetaSearchApp`、通知欄拉起下載面板，並 `export` 各頁面模組。原 12k 行 `main.dart` 已按模組拆分。
- 模組一覽（每目錄附 `feature_logic.md` 說明）：
  - `lib/home/`：首頁 `ScriptureSearchPage`（搜索調度、Goto、歷史書籤、更新檢查）；
  - `lib/reader/`：閱讀器頁面、layout 偏移换算、引文複製、書籤存取（`reader_store.dart`）；
  - `lib/search/`：簡繁轉換、候選、歷史、Goto、共用輸入框，加 `search_api.dart`（分頁請求）、`passage_resolver.dart`（行号→经卷解析）、`full_text_search_page.dart`（旧页，无引用）；
  - `lib/work_picker/`：`showWorkPicker` 選擇佛經（部類/詞典/冊別/作譯者/年代/經目/Goto）與筆畫排序；
  - `lib/ai/`：AI 搜尋網路層、chunk 模型與 `AiSearchPage`；
  - `lib/app_update/`：Gitee 檢查更新、APK 下載與安裝權限流程；
  - `lib/download/`：下載管理邏輯與 `download_status_ui.dart` 狀態面板；
  - `lib/dictionary/`：詞典服務與吸頂頭（`dictionary_sticky_headers.dart`）；
  - `lib/settings/`：顯示設定資料（`display_settings.dart`）與 UI（`display_settings_ui.dart`）；
  - `lib/widgets/`：**自定義 `Text`（遮蔽 material 的 Text，簡繁顯示轉換）**、`result_widgets.dart` 共用結果元件；
  - `lib/common/`：`navigatorKey` 與共享正則。
- 使用 `Text` 的檔案必須 `import 'package:flutter/material.dart' hide Text;` 並 import `lib/widgets/display_text.dart`，否則簡繁轉換失效。
- 經文模型與解析：`lib/scripture/`（`models.dart`、`parser.dart`、`cache.dart`）。悉曇/蘭札字以「形似漢字碼位 + 字體替換」呈現，解析器把區間記錄在 `ScriptureLine.scriptRuns`，閱讀器依區間套 `CBETA Siddam`／`CBETA Ranjana` 字體（偈頌 WidgetSpan 路徑暫不套字體，為已知限制）。
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
