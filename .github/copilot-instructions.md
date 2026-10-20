# Copilot 專案指示

完整說明見根目錄 `AGENTS.md`。重點：

- Flutter 專案，入口 `lib/main.dart`；經文模型/解析在 `lib/scripture/`，設定在 `lib/settings/`，搜尋在 `lib/search/`，AI 在 `lib/ai/`。
- 先用 grep 定位再讀取行號範圍，不要整份讀 `lib/main.dart`。
- 不要讀 `build/`、`.dart_tool/`、`assets/hanzi_*.json`、`assets/phrases_*.json`。
- 開發驗證優先使用：

```bash
dart analyze lib test/widget_test.dart
flutter test test/widget_test.dart --name '相關測試名稱'
```

- 搜尋功能：不掃描本地經文、不統計命中數；候選立即展示，點擊即搜尋。
- 修改搜尋邏輯時同步更新 `lib/search/feature_logic.md`。
- 不要加入無限閃爍動畫；`pumpAndSettle` 會卡住。
- 優先將新功能拆到 `lib/` 子目錄，避免 `main.dart` 繼續變大。
