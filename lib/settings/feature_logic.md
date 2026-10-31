# settings UI 模块说明

> 最后核对：`lib/settings/display_settings_ui.dart`（数据层在 `display_settings.dart`）。

## 职责

显示设定的界面层：底部弹层、开关/滑杆/选择 chip，以及两个入口按钮。

## 关键成员

- `showDisplaySettings(context)`：打开设定弹层（`DisplaySettingsPanel`），
  内含字号、經文字型（楷體/宋體/黑體/Siddam 开关联动）、背景颜色、
  簡繁顯示、夜間模式、自動更新等；「關於」也从这里进入；
- `updateDisplaySetting(update)`：包一层 SharedPreferences 写失败 SnackBar；
- `ScriptDisplayScope`：`InheritedNotifier<ScriptureDisplaySettings>`，
  `dependOn(context)` 让自定义 `Text` 等组件订阅设定变化；
- `ScriptDisplayButton`：首页/阅读器工具栏的「繁/简」快速切换按钮；
- `SettingsButton`：首页设定按钮，带 `availableUpdate` 更新角标与回调；
- `AppVersionLabel`：弹层底部当前版本（`package_info_plus`）。

## 注意

- 设定值本体、SharedPreferences key 都在 `lib/settings/display_settings.dart`，
  本文件只做 UI；
- 悉曇/蘭札字体的显示由字型 chip 控制，解析侧逻辑见 `lib/scripture/`。
