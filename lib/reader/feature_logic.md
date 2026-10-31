# reader 模块说明

> 最后核对：`lib/reader/reader_page.dart`、`reader_layout.dart`、
> `reader_citations.dart`、`reader_store.dart`。

## reader_page.dart

`ScriptureReaderPage`：单卷阅读页。

- 顶栏：卷切换（`JuanNavigation` / `JuanSelector`）、卷内搜索、书签、
  换经（`work_picker/showWorkPicker`）、显示设定（`ScriptDisplayButton`）；
- 卷内搜索：`LocalSearchBar`，命中列表 `SearchResultNavigation` 上下跳，
  命中处高亮并居中滚动（复用 `search/conversion.dart` 查询形式）；
- 长文渲染：正文按段落拆成 `ReaderPassageBlock`，标题/脚注/偈颂各有分支；
  悉曇/蘭札字区间的字体替换逻辑在 `scripture/parser.dart` 产出的
  `ScriptureLine.scriptRuns`，此页负责套用；
- 长按/选择文字：复制、引文格式化、分享、全选（见 reader_citations）。

## reader_layout.dart

原文偏移 ⇄ 可编辑文本 layout 的换算层（阅读器最复杂的一层）：

- `ScriptureTextLayout` / `buildScriptureTextLayout`：把 `ScriptureLine`
  列表拼成单一可搜索字符串，记录每段 offset 基址
  （`scriptureBlockOffsetBases`）、行首前缀、偈颂格渲染文本；
- `resolveSearchTargetOffset` / `locateSnippetOffset` /
  `resolveArchiveAnchorTarget`：把搜索命中或引文锚点定位回 layout offset；
- `highlightedPassageText` / `interactivePassageText` / `matchRangesIn`：
  关键字高亮（跨折叠符号、跨行）与可交互 span；
- `scriptureTextStyle`：依 `ScriptureDisplaySettings` 生成正文样式。
- 已知限制：偈頌以 WidgetSpan 呈现，不套 Siddam/Ranjana 字体。

## reader_citations.dart

- `formatSelectedPassageForCopy`：把选区拼成 CBETA 引文格式
  （页/栏/行，如 `T01n0001_p0001a01`，起止同页同栏时折叠）；
- `copySelectedPassage` / `loadSelectionLineheads` / `loadSectionTitle`：
  选区行号与品名读取；`decodeCitationHtml` 清 `<br>`/标签。

## reader_store.dart

- `ReaderBookmark` 与 SharedPreferences 持久化：key `reader_bookmarks`、
  `reading_history`（**保留旧格式**）；
- `loadBookmarks` / `saveBookmarks`（首页历史区共用）、
  `recordRecentReading`（阅读器打开经卷时回写）。
