# reader 模块说明

> 最后核对：`lib/reader/reader_page.dart`、`reader_layout.dart`、
> `reader_citations.dart`、`reader_store.dart`。

## reader_page.dart

`ScriptureReaderPage`：单卷阅读页。

- 顶栏：卷切换（`JuanNavigation` / `JuanSelector`）、卷内搜索、书签、
  换经（`work_picker/showWorkPicker`）、显示设定（`ScriptDisplayButton`）；
- 正文上方经名下方有一行低对比度来源标记：联网为「線上經文」，离线为「離線經文」
  （`_ReaderSourceBadge`，长按有完整 tooltip），随模式切换即时更新；
- 卷内搜索：`LocalSearchBar`，命中列表 `SearchResultNavigation` 上下跳，
  命中处高亮并居中滚动（复用 `search/conversion.dart` 查询形式）；
- 长文渲染：正文按段落拆成 `ReaderPassageBlock`，标题/脚注/偈颂各有分支；
  悉曇/蘭札字区间的字体替换逻辑在 `scripture/parser.dart` 产出的
  `ScriptureLine.scriptRuns`，此页负责套用；
- 卷题与作译者都留在正文原位排版，页首不再抽取 metadata 行：`volumeTitle` 与卷末重复题
  `volumeTailTitle`（都是 `headingLevel: 2`）呈居中的绿色次级标题，`byline` 靠右、`0.8×` 字号、淡色；
  对齐都靠在行首插一个不可见 placeholder 达成（同一段文字才可整段选取）。`volumeTailTitle` 与
  `navigationAnchor` 依 `ScriptureLine.suppressesLineBeginning` **不显示行号标记**（卷末行号排在卷首
  标记之后会让校勘读序错乱），`volumeTailTitle` 也不当作卷名 metadata。layout 端由
  `_alignedBlockLeadingLength` 计入前导长度（卷题固定 2＝换行＋placeholder；作译者 2，
  若前一行已自带换行则只有 1），渲染端 `interactivePassageText` 必须调用同一函数；
  placeholder 宽度**不能刚好等于剩余宽度**：它会先被排版引擎换算，一进到设备像素就超过行宽，
  而 CJK 每个字都是断行点，作译者最后几个字会被挤到下一行。因此留白先向下取整到
  `1/devicePixelRatio`，再用 `RenderParagraph` 本身那条排版路径（带 `maxWidth` 约束、
  `maxLines: 1` 的 `TextPainter`，placeholder 尺寸用 `setPlaceholderDimensions` 喂进去）问一次
  会不会换行，会换行就按 1、2、4、8… 个设备像素一步步收回留白（最多 6 次）；收到 0 仍换行
  说明文字本身就放不下，退回自然换行。两个 TextPainter 都要先过 `displayInlineSpan()`，
  因为渲染端在 `interactivePassageText` 之后还会做一次简繁转换，量的必须是最终画出来的文字；
  卷题与作译者相邻时不再插空行（`_isFollowedByByline` → `_needsParagraphBreak`／
  `_needsVolumeTitleBreak`）。因此正文 layout 覆盖整卷，卷内搜索、离线摘要与书签位移
  都不需要再加减页首前进量；
- 相鄰正文段落之间加一行间距；该段落边界同时进入搜尋文字与位移換算，
  不在偈頌段落前重複插入間距；
- 长按/选择文字：复制、引文格式化、分享、全选（见 reader_citations）；
- 取源模式跟全域 `offlineMode` 走（`preferOnline = !offlineMode`），切换模式会清空
  `juanCache` 并按新来源重新取卷：
  - **联网**只读 CBETA；本地没有这卷时才留一份备份，已有下载不被覆盖。连不上时抛
    `ScriptureOnlineLoadFailure`，**不静默回退本地**，错误面板提供「重试」、
    「改用离线阅读」（本地有副本时）或「前往下载」；
  - **离线**只读本地已下载的卷，缺卷抛 `OfflineVolumeUnavailable`，面板提供
    「前往下载」／「切换到联网」；
  - `juanCache` 只保留当前一卷（`_juanCacheLimit = 1`）：换卷后旧卷立即从快取移除，
    回看上一卷会重新读档解析，用这一点重解析时间换最低的常驻内存。已翻走的卷
    若在解析完成前被替换，结果仍交还给即将卸载的 FutureBuilder，但会从快取移除；
  - 整卷 HTML 用 `scripture/parse_runner.dart` 的 `parseScriptureHtmlAsync` 在背景
    isolate 解析（`flutter test`／网页版回退主 isolate），避免主 isolate 的 DOM
    与暂存字串推高 heap 高水位；
  - 换卷（含换经、书签、来源模式、重试）会调用 `_releaseRenderedJuan` 丢掉旧卷的
    layout、行资料与区块 key，`FutureBuilder` 以 `ObjectKey(linesFuture)` 重建，
    旧 snapshot 不再持有上一卷经文；
- 阅读位置记录（「上次阅读位置」/「最近阅读」用）：
  - 除进入时的搜索命中位置外，也会在「使用者自己捲动后停下」时，把
    当下**视窗顶端那一行**记为阅读锚点（`_updateReadingAnchorFromViewportTop`
    经 `_layoutOffsetAtGlobalPoint` → `_lineIndexForLayoutOffset` →
    `scriptureLineheadAtLayoutOffset`，再依 `lineSourceStarts` 算出整卷来源位移，取该行前 24 字作 `snippet`）；
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
    `resolveSearchTargetOffset`；
  - **联网重开最近阅读／书签时以验证过的位移为主**：先拿存档 `sourceOffset` 与 24 字
    `snippet` 在线上卷内核对（±600 字窗口），对得上就用位移；离线压缩档的行号可能只标到
    段首，位移通常更精确。位移／摘要对不上（或只有行号没有摘要）时才退回逐行行号；
  - 最近阅读／书签这类非搜索命中入口，目标行会贴到视窗顶端
    （`_archiveAnchorTopInset`，预留 12px），因为离开时记录的正是视窗顶端的行；
    搜索命中仍置中，卷内搜索也按命中置中。

## reader_layout.dart

原文偏移 ⇄ 可编辑文本 layout 的换算层（阅读器最复杂的一层）：

- `ScriptureTextLayout` / `buildScriptureTextLayout`：把 `ScriptureLine`
  列表拼成单一可搜索字符串，记录每段 offset 基址
  （`scriptureBlockOffsetBases`）、行首前缀、偈颂格渲染文本；
- `resolveSearchTargetOffset` / `resolveArchiveAnchorTarget`：把搜索命中或引文锚点定位回
  layout offset。`archiveAnchor` 为 true（最近阅读／书签）时，只有 `sourceOffset` 附近的
  ±600 字内能核对到 `snippet` 才采用位移，否则改走行号；没有摘要且行号存在时直接走行号。
  layout 覆盖整卷（卷题与作译者都在正文内），所以來源位移不必再加减页首
  前进量：先以 `_locateSnippetOffset` 驗證 `sourceOffset`（原位對上就用，對不上先在
  ±600 字範圍找最近的相同文字，再退回全文最近命中），換算走
  `layoutEditableOffsetForSource`；沒有來源位移時才用逐行行號，行號也找不到才退回
  段落錨點搭配 kwic 比對。卷题、卷末尾题与作译者都按正文定位；
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
