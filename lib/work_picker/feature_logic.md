# work_picker 模块说明

> 最后核对：`lib/work_picker/work_picker_page.dart`、
> `creator_collation.dart`、`work_picker_state.dart`。

## work_picker_page.dart

「選擇佛經」全屏对话框，`showWorkPicker(context, initialTab: …)` 返回
`ScripturePassage?`（选中即跳阅读器）。七个 tab：
`部類 / 詞典 / 冊別 / 作譯者 / 年代 / 經目查詢 / Goto 查詢`。

- 每个 tab 的状态持久化在 `work_picker_state.dart`（SharedPreferences，
  保留既有 key）；
- `_WorkPickerResponseCache`：同一请求在对话框生命周期内只发一次，
  `resetWorkPickerResponseCache()`（`@visibleForTesting`）供测试重置，
  **跨测试污染多因忘记调用它**；
- 詞典 tab：查词结果经 `dictionary/dictionary_sticky_headers.dart` 的
  `DictionaryStickyHeader` 吸顶展示，可下载/删除词库
  （`dictionary/fodict_download_manager.dart`）；
- 經目查詢 / Goto tab 的线上请求走 `search/search_api.dart` 与
  `search/passage_resolver.dart`。

## creator_collation.dart

作译者名单排序：`creatorStrokeGroup` 按姓氏笔画分组（繁简归并），
组内用 `IcuCollator`（`icu_kit`）拼音/笔画次序比较
`compareCreatorNames`；collator 懒加载去重（`ensureCreatorCollator`）。

## 注意

- 页面较大（约 2.4k 行），新功能优先拆成独立 widget 文件放入本目录；
- 显示文案沿用 `widgets/display_text.dart` 的 `Text`。
