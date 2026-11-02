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
- 页首只固定作译者等 metadata；`volumeTitle` 留在正文，以
  `headingLevel: 2` 呈现居中的绿色次级标题，段前、段后各留一空行；
  卷末重复题 `navigationAnchor` 保留文字但不套标题样式。因此正文 layout、
  卷内搜索与离线摘要都包含卷题；置中靠行首不可见 placeholder 达成，
  layout 端必须同步计入这 2 个字元（placeholder + 段前换行）；
- 相鄰正文段落之间加一行间距；该段落边界同时进入搜尋文字与位移換算，
  不在偈頌段落前重複插入間距；
- 长按/选择文字：复制、引文格式化、分享、全选（见 reader_citations）；
- 阅读位置记录（「上次阅读位置」/「最近阅读」用）：
  - 除进入时的搜索命中位置外，也会在「使用者自己捲动后停下」时，把
    当下**视窗顶端那一行**记为阅读锚点（`_updateReadingAnchorFromViewportTop`
    经 `_layoutOffsetAtGlobalPoint` → `_lineIndexForLayoutOffset` →
    `scriptureLineheadAtLayoutOffset`，再依 `lineSourceStarts` 加上卷首
    前进量算出整卷来源位移，取该行前 24 字作 `snippet`）；
  - 只在 `UserScrollNotification`（真正的拖拽／惯性滑动）之后才触发，
    程序化的 `jumpTo`（跳到搜索命中、切卷）不算「换了阅读位置」；
    `ScrollEndNotification` 后延迟 400ms 才写一次，避免惯性滑动每一格
    都存取；
  - 应用切到背景／非活动（`didChangeAppLifecycleState`）时也会立刻记下
    当前位置，不必等防抖计时器；`dispose` 只取消防抖计时器，不再补写
    （同步生命周期里排 unawaited 的异步存檔，回调会在 widget 销毁后才
    跑到，反而污染下一笔测试）；
  - 切换命中、切卷、换经（`_goToHit`/`_changeJuan`/`_selectJuan`/
    `_openBookmark`/`_selectWork`）都会先清除旧锚点，重新以进入位置计算；
  - 重新进入时不需要新逻辑：`_positionedPassage()` 存的还是
    `linehead`/`sourceOffset`/`snippet`，走的仍是
    `resolveSearchTargetOffset` 里已有的「先验 snippet、再退回行号」路径。

## reader_layout.dart

原文偏移 ⇄ 可编辑文本 layout 的换算层（阅读器最复杂的一层）：

- `ScriptureTextLayout` / `buildScriptureTextLayout`：把 `ScriptureLine`
  列表拼成单一可搜索字符串，记录每段 offset 基址
  （`scriptureBlockOffsetBases`）、行首前缀、偈颂格渲染文本；
- `resolveSearchTargetOffset` / `locateSnippetOffset` /
  `resolveArchiveAnchorTarget`：把搜索命中或引文锚点定位回 layout offset；
  来源位移会先按「减去页首前进量」与「不減」两个候选用 `snippet` 验证，
  因为作译者行可能位于卷题之前或之后；作译者命中回卷首，卷题按正文定位；
- `highlightedPassageText` / `interactivePassageText` / `matchRangesIn`：
  关键字高亮（跨折叠符号、跨行）与可交互 span；
- 偈颂校勘注统一由 `_verseCellIndexForNote` 归属到唯一一格：优先用解析器
  记录的 `verseCellIndex`，旧数据按位移推导，位移正好落在格尾时归前一格。
  `_verseCellRenderedTexts`、`layoutEditableOffsetForSource`、
  `interactivePassageText` 共用这个判断，避免同一注在相邻格重复渲染
  （如 `[6][6]`）以及后续格的位移多算；
- `scriptureTextStyle`：依 `ScriptureDisplaySettings` 生成正文样式。
- 已知限制：偈頌以 WidgetSpan 呈现，不套 Siddam/Ranjana 字体。

## reader_citations.dart

- `formatSelectedPassageForCopy`：把选区拼成 CBETA 引文格式
  （页/栏/行，如 `T01n0001_p0001a01`，起止同页同栏时折叠）；行号解析用
  `citationLineheadPattern`（`lib/common/text_patterns.dart`），形態靠齊
  CBReader2X `cbreader.js` 的 `_parser_linehead`：藏別前綴可多字母
  （`GA040n0040_p0002a01`）、`_p` 的底線可省（`T54n2133Ap1190a13`）、頁碼可帶
  字母前綴（`B36n0198_ph017a02`）；頁碼與行號用 `_stripCitationPadding` 去前導
  零（字母留在零之前，才與 `normalizeCbetaGotoLinehead` 的補零往返一致）。
  解析不到時整段引文退回只有 `(CBETA 2026.R1)`，卷號/經號/頁碼一併遺失，
  所以新增藏別或頁碼形態只要正則沒放寬就會默默變成「沒有編號」；
- `copySelectedPassage` / `loadSelectionLineheads` / `loadSectionTitle`：
  选区行号与品名读取；`decodeCitationHtml` 清 `<br>`/标签。

## reader_store.dart

- `ReaderBookmark` 与 SharedPreferences 持久化：key `reader_bookmarks`、
  `reading_history`（**保留旧格式**）；
- `loadBookmarks` / `saveBookmarks`（首页历史区共用）、
  `recordRecentReading`（进入经卷、使用者捲动停下、应用切到背景时都会
  回写，见「阅读位置记录」）；`reading_history` 上限
  `maximumReadingHistory = 50` 笔，同一部经重复写入只保留最新一筆。
