# CBETA App 功能逻辑记录

> 本文以当前代码为准，记录简繁转换、搜索候选、搜索入口、词典查询与阅读器高亮的实际行为、设计取舍和已知限制。
> 最后核对：`lib/search/*.dart`、`lib/main.dart`、`lib/dictionary/*`、`test/widget_test.dart`、`tool/check_hanzi_tables.py`。
> 文档与代码冲突时以代码为准；尚未实现的设计会明确标注为「未实现」。

## 代码位置

- `conversion.dart`：简繁单字/词组表加载、文字类型判定、双向候选生成、首选转换、显示转换；
- `candidates.dart`：候选面板行模型，历史/首选/原始输入的标记与去重；
- `history.dart`：搜索记录、原始输入到实际搜索词的选择记录、历史匹配、查询词解析；
- `goto.dart`：Goto 引文提取与行号规范化；
- `search_input.dart`：共享输入框、实时候选浮层、词典 key 命中数统计与提交；
- `feature_logic.md`：本文件；
- `lib/main.dart`：首页搜索、Goto、AI 入口、卷内搜索、经目/作译者查询、词典查询与阅读器高亮的调用点；
- `lib/dictionary/fodict_service.dart`：词典读取、按 key 匹配与 key 命中统计；
- `lib/scripture/offline_scan.dart`：离线正文连续扫描会话、背景 isolate 扫描与 KWIC 片段；
- `lib/download/catalog_cache.dart`：App 内建的全量经目 metadata（work/title/creators/juans）与 `searchWorks` 排序查询（只匹配 work 與 title），首页经目分区与经目查询入口都靠它回答；
- `tool/check_hanzi_tables.py`：四份简繁词表的结构与一致性检查脚本；
- `test/widget_test.dart`：转换、候选、各搜索入口、词典 key 与阅读器行为的测试。

当前没有被任何页面引用的旧实现：

- `lib/main.dart` 的私有 `_FullTextSearchPage`；
- `lib/dictionary/dictionary_page.dart` 的 `DictionarySearchPage`。

实际全文搜索由首页完成，实际词典查询入口是「选择佛经 → 词典查询」。这两个旧页面不影响现行行为，修改逻辑时不要误把它们当作入口。

## 文档索引

1. 数据文件与加载
2. 文字类型判定
3. 候选生成
4. 候选面板交互
5. 搜索历史与选择记录
6. 各搜索入口
7. Goto
8. 繁 → 简显示转换
9. 词典查询
10. 阅读器高亮与锚点
11. 失败处理与缓存
12. 测试、实现状态与后续
13. 卸载后的数据保留

---

## 一、数据文件与加载

### 1.1 四份词表

| 文件 | 当前条数 | 用途 |
|---|---:|---|
| `assets/hanzi_simplified_to_traditional.json` | 4064 | 简 → 繁单字候选 |
| `assets/hanzi_traditional_to_simplified.json` | 4150 | 繁 → 简单字候选 |
| `assets/phrases_simplified_to_traditional.json` | 99 | 简 → 繁词组保护 |
| `assets/phrases_traditional_to_simplified.json` | 69 | 繁 → 简词组保护 |

四份文件的值都是**有序候选数组**，例如：

```json
{
  "发": ["發", "髮"],
  "干": ["干", "乾", "幹", "榦"],
  "后": ["后", "後"],
  "里": ["里", "裡", "裏", "哩"],
  "云": ["云", "雲"],
  "厂": ["廠", "厂"]
}
```

```json
{
  "乾": ["干", "乾"],
  "著": ["著", "着"],
  "乾闥婆": ["乾闼婆"],
  "乾淨": ["干净"]
}
```

规则：

- 数组第一项是首选；
- `_candidateList` 会去重、过滤空值，并在数组为空时回退为 key 本身；
- 词表当前全部是数组；代码仍兼容字符串值；
- 词组表当前每项都只有一个候选，单字表存在多项候选（简 → 繁约 270 项，繁 → 简约 1001 项）；
- 当前词组最长 3 个字符，加载时计算并缓存最大词组长度。

`["廠", "厂"]` 与 `["云", "雲"]` 的差异不是数据错误：

- `厂` 是真正的简体字，标准繁体写作 `廠`，把 `厂` 放在数组第二项是「转繁失败时回退原字」的兜底；
- `云` 本身也是合法繁体字（如「云何」），所以简 → 繁首选仍是 `云`，`雲` 只是另一种写法；
- 四份词表里类似的顺序差异共 70 项（简 → 繁 47 项、繁 → 简 23 项），属于长期编写约定，不是结构性损坏；
- 双向成员不完全对称（125 项）和首选往返不一致（1245 项）多来自异体字（藴/蘊、衆/眾）或分工不同的字（乾/干），同样以提示处理。

### 1.2 加载时机

`main()` 启动时直接 `await SimplifiedTraditionalConverter.load()`，然后才 `runApp`。四份词表在启动时一次性读入静态 `Map`，之后只读。

`load()` 没有捕获异常；资源缺失或 JSON 格式错误会中断启动流程，不会静默退回原文。

### 1.3 文字集合的推导

代码没有单独维护「简体字/繁体字/共用字」三张表，而是从两份单字表自动推导：

- `_simplifiedOnly`：简 → 繁表中，**第一候选与 key 不同**的 key；
- `_traditionalOnly`：繁 → 简表的 key 中，**没有出现在简 → 繁表**的 key。

因此：

- `厂`（`["廠", "厂"]`）、`发`、`国` 属于 `_simplifiedOnly`；
- `干`、`后`、`里`、`云`、`征` 的第一候选等于自身，**不算** `_simplifiedOnly`；
- 未出现在任何集合中的字符（包括共用字、数字、拉丁字母、标点）都按中性处理。

`_simplifiedOnly` 只用于**显示转换的开关**（`toTraditionalDisplay`）和文字类型判定，不再决定「是否生成候选」。例如 `厂` 被归为简体是因为默认显示要转成 `廠`；`云` 不归为简体，避免把「云何」显示成「雲何」。候选生成对两者都会给出 `廠/厂`、`云/雲`。

代码没有人工覆盖集合的机制。

### 1.4 词表检查脚本

```bash
python3 tool/check_hanzi_tables.py           # 只把结构性错误视为失败
python3 tool/check_hanzi_tables.py --strict  # 顺序/覆盖/往返提示也视为失败
```

检查内容：

1. **结构性**（默认失败）：文件缺失、JSON 顶层不是对象、key 为空、候选不是非空数组、空候选、重复候选、值仍是字符串；
2. **顺序提示**：原字出现在候选中但不是第一项；
3. **双向覆盖提示**：A 表 `key -> candidate`，但 B 表 `candidate` 的候选不含 `key`；
4. **首选往返提示**：A 表的首选在 B 表中回查时，首选不是原 key。

默认运行的当前结果：

```text
简→繁: 4064 项（原字第一 213，原字在后 47，原字缺席 3804）
繁→简: 4150 项（原字第一 929，原字在后 23，原字缺席 3198）
简→繁词组: 99 项；繁→简词组: 69 项
未发现结构性错误。
顺序疑点 70 项；双向覆盖提示 125 项；首选往返提示 1245 项。
```

第 2～4 类只作为人工复查清单，不代表程序错误；清理词表时可加 `--strict` 逐项确认。

---

## 二、文字类型判定

`classify(input)` 逐 code point 检查字符集合，返回 `ScriptKind`：

| 输入情况 | 判定 | 首选（第一候选） |
|---|---|---|
| 只含 `SIMPLIFIED_ONLY` 或共用/中性字符，且至少一个 `SIMPLIFIED_ONLY` | `simplified` | 简 → 繁转换的第一候选 |
| 只含 `TRADITIONAL_ONLY` 或共用/中性字符，且至少一个 `TRADITIONAL_ONLY` | `traditional` | 原始输入 |
| 同时含 `SIMPLIFIED_ONLY` 与 `TRADITIONAL_ONLY` | `mixed` | 简 → 繁转换的第一候选 |
| 不含上述两类字（含空输入） | `neutral` | 原始输入 |

重要推论：

- **文字类型只决定首选和组合顺序，不再决定是否生成候选。** 任何非空输入都会生成至少一个候选；
- 共用字/中性输入现在也会展开候选。例如 `云` 得到 `云 / 雲`，`干` 会展开 `干 / 乾 / 幹`（每段最多 3 个）；
- 纯共用字组成的词也会参与双向组合。例如 `以后` 虽然不触发显示转换，但候选面板仍可能给出词表允许的写法；
- 纯繁体输入也会生成 `fullSimplified` 与繁 → 简组合，因此 `五蘊` 会得到 `五蘊 / 五蕴`；
- 空输入在 `SearchInput` 中显示历史记录，提交空输入不会搜索；首页收到空输入会清空结果。

---

## 三、候选生成

入口：`SimplifiedTraditionalConverter.convertCandidates(input)`。函数不再接收 `historicalQuery`，历史只影响面板标记和最终查询词解析。

### 3.1 分段：双向词组优先，单字兜底

生成前先把输入按最长词组切分。简 → 繁和繁 → 简各做一次：

1. 用 runes 逐字处理；
2. 从当前位置尝试最长词组（当前最多 3 字），命中对应方向的词组表就采用该词组的候选数组，并跳过整个词组；
3. 未命中词组时，用对应方向的单字候选数组；
4. 单字表也没有该字时，保留原字。

词组分段和单字分段都允许一个分段携带多个候选。当前词组资产每项只有一个候选，单字表可能有多项。

### 3.2 首选与全简体候选

`_preferredText`：

- `simplified` / `mixed`：使用简 → 繁词表，逐段取第一候选；
- `traditional` / `neutral`：直接使用原始输入。

`fullSimplified = toSimplifiedAll(input)`：按繁 → 简词组优先、单字兜底，把输入中的每个字符都换成该方向的第一候选，得到「全部繁体字转简体」的候选。它与 `toSimplified` 的差别是：`toSimplified` 只在文本含 `_traditionalOnly` 字符时才转换，而 `toSimplifiedAll` 总是执行转换，用于候选集合。

### 3.3 组合与上限

- 每个分段最多取前 **3** 个候选；
- 所有分段做笛卡尔组合，组合过程中去重；
- 单次最多生成 **50** 个组合；
- 达到上限时设置 `truncated = true`，保留先生成的组合；
- 候选面板最多展示 **20** 行，历史列表最多展示 **8** 行。

### 3.4 候选顺序

`convertCandidates` 依次加入：

1. **首选**（`_preferredText`，即「原来命中的文字」）；
2. **原始输入**（如果与首选不同）；
3. **全简体候选**（`fullSimplified`，如果尚未出现）；
4. 组合候选：
   - `traditional` 输入先加繁 → 简组合，再加简 → 繁组合；
   - 其他类型先加简 → 繁组合，再加繁 → 简组合；
5. 全程去重，最多 50 个。

`pinnedCandidates = [首选, 原始输入（若不同）]`。这两项在候选面板中固定在最前，其余候选可以参与词典命中数排序。

示例（来自测试）：

```text
厂丑   → 廠丑 / 厂丑 / 廠醜 / 厂醜
厂     → 廠 / 厂
云     → 云 / 雲
五蕴   → 五蘊 / 五蕴
五蘊   → 五蘊 / 五蕴
简体经目发愿 → 簡體經目發願 / 简体经目发愿 / ...
```

`厂丑` 的 `pinnedCandidates` 为 `[廠丑, 厂丑]`，`fullSimplified` 为 `厂丑`；`五蘊` 的 `fullSimplified` 为 `五蕴`。

### 3.5 结果结构

```dart
class ConversionResult {
  final String rawInput;
  final ScriptKind scriptKind;
  final List<String> candidates;       // 已按固定优先项 + 组合顺序排序
  final List<String> pinnedCandidates; // [首选, 原始输入（若不同）]
  final String fullSimplified;         // 全部转简体后的候选
  final bool truncated;                // 是否因 50 个上限被截断

  bool get requiresChoice => candidates.length > 1;
}
```

### 3.6 同步首选接口

```dart
String convertPreferred(String input); // 返回 candidates.first
String convert(String text);           // convertPreferred 的旧别名
String toSimplified(String text);      // 含繁体字时才转简体（显示/词典回退用）
String toSimplifiedAll(String text);   // 总是转简体（候选生成用）
String preferredQueryFor(String rawInput, Map<String, String> selections);
Future<String> preferredQueryForInput(String rawInput);
```

- `convertPreferred` 不读取历史，只按词表顺序返回第一个候选；
- `preferredQueryFor` **先查历史选择**，命中则直接返回历史选中的查询词；否则返回 `convertCandidates(...).candidates.first`；
- `preferredQueryForInput` 读取 `search_selections` 后调用 `preferredQueryFor`，读取失败时忽略历史；
- 首页和词典的最终查询词由 `resolveSearchQuery` 决定（见 5.5），它还会比较词典 key 命中数；
- 「选择佛经 → 经目查询」按钮使用 `preferredQueryForInput`；
- 作译者输入框的 `onChanged` 使用 `convertPreferred` 即时过滤列表；
- AI 页面使用 `convert(input)`，即无历史的首选候选。

---

## 四、候选面板交互

### 4.1 数据加载

`SearchInput` 初始化及每次获得焦点时加载：

- `search_history`：最近搜索记录；如果调用方传入 `recentSearches`（首页），则使用传入值；
- `search_selections`：原始输入到实际搜索词的映射。

加载失败时按空列表/空映射处理，不影响搜索。

### 4.2 显示条件

`SearchInput` 只在同时满足以下条件时显示浮层：

- 输入框有焦点；
- 输入法当前没有未提交的组合（`controller.value.composing.isValid == false`）；
- 计算出的候选行数大于 0。

候选行来源：

| 输入框内容 | 显示内容 |
|---|---|
| 空 | `buildHistoryChoices`：最近搜索记录（不显示标题），最多 8 行 |
| 非空且 `showCandidates == true` | `buildSearchChoices`：实时转换候选，最多 20 行 |
| 非空且 `showCandidates == false` | 不显示候选 |

`buildSearchChoices` 在以下情况返回空：

- 输入为空；
- 输入是 Goto 表达式；
- 最终候选行数小于等于 1（只有一行时面板没有选择意义）。

### 4.3 候选行顺序与标记

`buildSearchChoices` 的行顺序：

1. `conversion.candidates` 的全部候选（首选第一、原始输入第二、全简体候选与组合随后）；
2. 历史匹配到的查询词如果不在候选中，追加一行并标记为历史。

标记规则：

- `isDefault`：`conversion.candidates.first`；
- `isOriginal`：候选等于当前输入框原文；
- `isHistory`：候选等于 `matchHistoricalSelection` 的结果；
- `isSimplified`：候选等于 `fullSimplified` 且不等于原文；
- 相同文字合并为一行，并合并标记；
- **固定候选**（`isPinned`）只包括 `isDefault` 和 `isOriginal`。历史候选不固定，可以参与词典命中数排序。

界面实际显示的标签（`_buildChoiceTile`）：

- `歷史`：来自历史记录/历史匹配；
- `簡體`：全简体候选；
- `原始輸入`：用户原始输入；
- `實際搜尋：<query>`：历史行的实际搜索词与显示文字不同时附加；
- `字典 N`：该候选在所选词典 key 中的命中次数（统计完成后才显示）。

界面**不显示**「預設」标签。`SearchChoice.labels` getter 仍然没有被 UI 直接使用，UI 在 `_buildChoiceTile` 中另行组装标签。

### 4.4 词典 key 命中数排序

只有调用方传入 `keyMatchCounter` 时才会统计和排序：

- 首页：非 AI 模式且已取得词典目录时传入，统计范围为**全部可用词典**（不再限定内建 `assetDictionaryIds`）；AI 模式或目录不可用时不统计；
- 词典查询：始终传入，同样统计**全部可用词典**，`countScope` 只以词典目录为准；
- 卷内搜索、经目查询、作译者查询：不传入。

统计流程：

1. 候选面板每次刷新时，对尚未缓存的候选去重后收集；
2. 延迟 **180 ms** 防抖，避免每次按键都扫描词典；
3. 调用 `FodictService.countKeyMatches`（不传 `dictionaryIds`），统计全部词典 key 的包含匹配（大小写不敏感）；
4. 成功后把缺失候选补 0；失败时保留原有顺序且不显示次数；
5. 结果按候选 query 缓存；`countScope` 或 `keyMatchCounter` 可用性变化时清空缓存和防抖计时器；
6. 空输入的历史列表不统计。

排序规则（`_applyHitCounts`）：

- 固定候选（首选、原始输入）保持在最前；
- 其余候选只有在**全部**都有命中数时才重排；重排时**繁体／混排候选优先于简体／中性候选**，两组各自按命中数从大到小排序，同次数保持原顺序（`SimplifiedTraditionalConverter.ranksAsTraditional` 判定分组）；
- 任一非固定候选还没有命中数时，整个列表保持原顺序，避免闪烁；
- 命中数显示在候选副标题中，如 `字典 12`。

`resolveSearchQuery` 在没有用户选择而用命中数自动挑词时，遵循同样的优先级：先取繁体／混排候选中命中数最高者，其次才是简体／中性候选（`history.dart`）。

这些次数只来自**本地佛学词典的 key**，与经文正文统计无关。

### 4.5 浮层布局

- 浮层插入根 `Overlay`，通过 `CompositedTransformFollower` 锚定在输入框或宽度锚点下方；
- 首页传入 `widthAnchorKey`，使浮层宽度与整条搜索框（含图标/按钮）一致；其他入口使用输入框自身宽度；
- 最大高度 280，可滚动；
- 不做键盘避让；键盘可能遮挡浮层；
- 使用 `TapRegion` + 相同 `groupId` 与输入框保持焦点关联，点击浮层内部不会先触发失焦；
- 系统 Material 列表样式，无标题、无说明文字，行间有分隔线；
- `displayListenable` 变化时重建输入框和浮层，使标签跟随简繁显示。

### 4.6 点击、提交、焦点

- **点击转换候选**：输入框文字替换为该候选，记录待搜索的 `SearchSelection`（`isExplicit = true`），隐藏浮层并失焦；**不立即搜索**，用户需要再按搜索按钮或键盘搜索键；
- **点击历史行**：输入框保留历史原始输入，待搜索 query 使用 `search_selections` 保存的实际搜索词；同样不立即搜索；
- **按搜索按钮/键盘搜索键**：
  - 如果当前输入等于待搜索选择的 `rawInput` 或 `query`，直接提交待搜索选择；
  - 否则用 `resolveSearchQuery` 重新解析（见 5.5）；
- **光标/选区变化**：只有文字没有变化时保留待搜索选择；
- **修改文字**：清除待搜索选择，并通知父组件 `onSelectionChanged(null)`；
- **清空输入**：如果仍有焦点且有历史记录，浮层切换为历史列表，而不是直接隐藏；
- **失焦/点击外部**：隐藏浮层；
- **输入法组合期间**：直接隐藏浮层，组合结束后重新计算；
- 选择候选时用 `_suppress` 避免程序性写入 controller 触发一次多余刷新；同时更新已同步的文字，避免后续光标事件被误判为文字修改。

### 4.7 不扫描本地经文

候选生成是同步的字符串处理，明确不做以下事情：

- 不读取 `scriptureVolumeStore` 或任何已下载经文；
- 不扫描经文正文，不统计卷数、命中位置或出现次数；
- 不向 CBETA 服务器请求计数；
- 不启动 isolate 或后台任务。

首页和词典入口会异步统计**词典 key** 命中数，用于候选排序；这是独立的防抖任务，不读取经文，也不会阻塞候选首次显示。全文搜索在**用户提交之后**才可能扫描本地经卷（离线回退），这与候选生成无关。

---

## 五、搜索历史与选择记录

### 5.1 存储格式

| SharedPreferences key | 内容 | 上限 |
|---|---|---:|
| `search_history` | 最近输入的原始搜索文字数组，最新的在前 | 20 |
| `search_selections` | `rawInput -> selectedQuery` 的 JSON 对象 | 100 |

- `recordSearchQuery` 对 `search_history` 做大小写不敏感去重，新记录插入到最前面；
- `recordSearchSelection` 对 `search_selections` 先删除同 key 再插入，超过 100 条时删除最早插入的 key；
- 两个 key 的既有数据格式保持不变。

### 5.2 谁写入什么

| 入口 | `search_history` | `search_selections` |
|---|---|---|
| 首页关键字搜索 | 写入原始输入 | 写入 `rawInput -> query` |
| 首页 Goto | 写入 Goto 输入 | 写入 `rawInput -> rawInput` |
| 首页 AI 模式 | 写入原始输入 | 写入 `rawInput -> rawInput` |
| 卷内搜索 | 不写 | 写入 |
| 经目查询 | 不写 | 写入 |
| 作译者查询 | 不写 | 写入 |
| 词典查询 | 写入原始输入 | 写入 `rawInput -> 实际查询词` |
| Goto 查询标签页 | 不写 | 不写 |

因此：

- 首页的「最近搜索」列表来自 `search_history`，主要由首页搜索和词典查询产生；
- 其他入口的输入会进入 `search_selections`，可以参与历史匹配，但不会出现在首页最近搜索列表；
- 词典查询写入的是 `raw -> actualQuery`：用户明确点选候选时，`actualQuery` 就是所选文字，不再做简繁回退；只有未明确选择时才可能因字体回退而变化（见 9.3），输入框随后也会显示该实际查询词；
- AI 页面内部的搜索（从首页进入后再次修改问题）目前不写入任何记录；
- 历史行显示的文字是 `search_history` 中的原始输入；实际搜索词从 `search_selections` 取，取不到时等于原文。

### 5.3 历史匹配

`matchHistoricalSelection(rawInput, selections)`：

1. 如果 `rawInput` 精确等于某个历史 key，直接返回对应 `selectedQuery`；
2. 否则遍历 `search_selections`（最近插入的在前），计算：
   - 包含关系：任一方向包含，且较短一方长度 ≥ 2，得分 `max(0.9, 长度重叠率)`；
   - 否则计算归一化编辑距离相似度，相似度 ≥ 0.8 时取该相似度；
3. 取得分最高的一项；同分时保留最近插入的一项；
4. 没有匹配则返回 `null`。

当前实现**没有使用使用频率**，同分时依据插入顺序（最近者优先）。

历史匹配只用于两处：

- `buildSearchChoices` 把历史查询词追加到候选面板（标记为「歷史」）；
- `resolveSearchQuery` / `preferredQueryFor` 在没有用户选中候选时决定实际查询词。

历史查询词**不再**由 `convertCandidates` 置顶；候选的固定顺序只由「首选 + 原始输入」决定。

### 5.4 查询词解析 `resolveSearchQuery`

首页和词典提交时使用：

```dart
Future<String> resolveSearchQuery(
  String rawInput, {
  String? selectedQuery,
  Map<String, String>? selections,
  KeyMatchCounter? keyMatchCounter,
});
```

优先级：

1. `selectedQuery` 非空：直接使用（用户点击候选/历史后产生的选择）；
2. 历史匹配命中：使用 `search_selections` 中的值；
3. 否则取 `convertCandidates(rawInput).candidates.first`；
4. 如果传入了 `keyMatchCounter` 且候选多于 1 个，统计全部候选的词典 key 命中数：
   - 繁体／混排候选整体优先于简体／中性候选（与 4.4 的重排一致）；
   - 同组内选命中数最高的候选；命中数相同或同分时保留首选；
   - 统计抛异常时退回首选。

首页只在「非 AI 模式且 `_fodictBaseDir != null`」时传入计数器（统计范围为全部可用词典，见 9.2）；词典查询始终传入。其他 `SearchInput` 入口没有计数器，因此只执行第 1～3 步。

`preferredQueryFor` 是第 1～3 步的同步版本（无用户选择、先历史后首选），供经目查询等入口使用。

---

## 六、各搜索入口

| 入口 | 输入组件 | 候选面板 | 实际查询 | 记录 | Goto |
|---|---|---|---|---|---|
| 首页关键字搜索 | `SearchInput` | 有，实时，含词典 key 命中数 | 选中候选 / 历史 / 首选 + key 命中统计 | history + selection | 转换前先判断并执行 |
| 首页 AI 模式 | 首页 `SearchInput` + AI 页面 `TextField` | 首页非空时关闭；AI 页无 | 首页把原始输入交给 AI 页；AI 页用 `convert` 首选 | 首页写 raw/raw | 首页在进入 AI 前判断 |
| 首页全文/经目结果 | 同上 | 有，实时 | 选中候选 / 历史 / 首选 + key 命中统计 | 同上 | 同上 |
| 卷内搜索 | `SearchInput` | 有，实时 | 选中候选 / 历史 / 首选 | 仅 selection | 不执行；Goto 形状输入也会抑制候选 |
| 经目查询（选择佛经） | `SearchInput` | 有，实时 | 选中候选 / 历史 / `preferredQueryForInput` | 仅 selection | 不执行 |
| 作译者查询（选择佛经） | `SearchInput` | 有，实时 | 选中候选；输入时用 `convertPreferred` 过滤列表 | 仅 selection | 不执行 |
| Goto 查询（选择佛经） | 普通 `TextField` | 无 | `normalizeCbetaGotoLinehead` + `/juans/goto` | 不记录 | 始终执行 |
| 词典查询（选择佛经） | `SearchInput` | 有，实时，含词典 key 命中数 | 选中候选 / 历史 / `resolveSearchQuery` + key 命中统计 | history + selection | 不执行 |
| 离线全文搜索 | 首页搜索框 | 与在线相同 | 与在线相同 | 与首页相同 | 同首页 |

补充：

- 首页搜索同时发起全文关键字、经目检索与字典 key 检索；三个来源由 `_runKeywordSearch` 以 `unawaited(...)` **并行、异步各自落地**（各自维护 `isKeywordSearchPending`／`isCatalogSearchPending`／`isDictionarySearchPending` 与 `setState`），任一方先完成就先显示，不必等其它方；结果页仍在首页，不存在独立的「全文搜索页」入口；实测服务端与 Dart 客户端都能并行处理这些请求（同一批三个查询并行约 2 秒、串行约 5.5 秒），慢的原因不是并发冲突；
- 首页搜索结果显示为三个可折叠分区：經目搜尋結果、字典搜尋結果、正文搜尋結果；经目与字典分区初始各只显示 1 条，可分别展开全部；正文分区按「作品（一级）→ 卷（二级）」分组：先由 `_groupResultsByWork` 把**同一部作品（work）跨卷的多笔结果合并成一筆**（结果以 passages 的 work 为分组键），因此一级只展示去重后的作品目录；一级 `ExpansionTile`（`_WorkResultGroup`）**默认折叠且懒惰渲染**（只在该作品第一次展开时才构建二级与命中片段，避免正文结果一次性渲染卡顿），二级卷分组在展开后默认展开并列出该卷命中片段；
- 字典分区使用 `FodictService.searchByKey` 依次尝试提交词、全简体、全繁体的第一个有结果写法，命中后点击条目在**当前结果列表中就地展开/收起完整释义**（不再弹窗）；词条名、摘要与展开后的释义都使用 `_scriptureTextStyle(scriptureDisplaySettings)`，跟随显示设置的字号、字体与行高，展开前后字号一致；字典检索失败只影响该分区，不阻止关键字与经目结果；
- 首页经目分区**完全由本机回答**：先查 App 内建的完整经目（`CatalogCache.searchWorks`，只匹配书名与编号），没命中再看本地已储存经卷的经名，全程不发请求；「選擇佛經 → 經目查詢」分页才是「本地先铺 + 远端 `/search/toc` 合并」。两者都不搜正文（细节与理由见 11.6）；
- 作译者查询只过滤作译者元数据；
- 卷内搜索只搜当前卷，提交后才计算当前卷命中；
- 离线搜索是在网络请求失败后扫描本地经卷/经目，候选阶段仍然只看词表；离线正文命中用 `offlineKwicSnippet`（`lib/scripture/offline_scan.dart`）取关键词前后各一段（默认前 40、后 80 字，超出加省略号）作为上下文，而不是整行/整卷原文，避免像「发」这类高频字把整部经文塞进结果；离线扫描的细节见 11.4；
- 所有 `SearchInput` 入口共用同一套候选生成与「点击只填充、不搜索」交互；
- 首页搜索按钮传入的 `query` 为空，由待搜索选择或 `resolveSearchQuery` 决定；经目查询按钮由 `_searchToc` 使用待搜索选择或 `preferredQueryForInput`；
- AI 页面没有候选面板，直接使用 `convert` 的首选候选；
- 首页 AI 模式下，空输入仍会显示历史；点击历史行后按搜索键会走 AI 分支，使用 `rawInput` 并忽略 `selectedQuery`，最终交给 AI 页的仍是原始输入；
- 首页先判断 Goto、再判断 AI 模式，因此 Goto 表达式在 AI 模式下也会打开 Goto；
- 词典查询的候选与记录细节见第九章；词典输入即使形似 Goto 也不会执行 Goto，只会按词条 key 查询。

---

## 七、Goto

相关函数在 `goto.dart`：

1. `extractCbetaGotoQuery`：如果输入中包含括号包裹的 `CBETA ...` 引文，取括号内内容；否则取去除首尾空白的原文；
2. `normalizeCbetaGotoLinehead`：把 `CBETA 2026.R2, T01, no. 3, pp. 154c20` 之类的引文规范成 `T01n0003_p0154c20`；支持带 `h` 的页码前缀；
3. `isCbetaGotoExpression`：用规范化后的正则判断是否命中 `卷号n经号_p页码行号` 形式。

执行规则：

- **仅首页关键字搜索**在 AI 模式判断和简繁转换之前自动判断 Goto；命中就记录搜索记录并打开 Goto，不进入候选流程；
- 「选择佛经 → Goto 查询」是独立入口，使用普通 `TextField`，始终规范化并请求 `/juans/goto`，不做简繁候选；
- 卷内搜索、经目查询、作译者查询、词典查询、AI 页面都不会把输入自动解释为 Goto；
- 但 `buildSearchChoices` 对所有 `SearchInput` 都检查 Goto 表达式，因此这些入口输入 Goto 形状的文字时不会显示候选面板，提交后按普通关键字/元数据处理。

示例：

```text
CBETA 2026.R2, B22, no. 117, p. 5a1 → B22n0117_p0005a01
CBETA 2026.R2, B36, no. 198, p. h17a2 → B36n0198_ph017a02
T02n0102_p0499c28 → 命中 Goto
博伽梵歌 → 不命中 Goto
```

---

## 八、繁 → 简显示转换

### 8.1 当前实际范围

显示转换由 `_displayText` 统一调用，跟随三态文字模式（繁 / 简 / 原样）：

```dart
if (scriptureDisplaySettings.showOriginalText) return text;
return scriptureDisplaySettings.showSimplifiedText
    ? SimplifiedTraditionalConverter.toSimplified(text)
    : SimplifiedTraditionalConverter.toTraditionalDisplay(text);
```

顶部文字按钮 `_ScriptDisplayButton` 在这三态之间循环（繁 → 简 → 原样 → 繁），图标显示**当前**模式：繁体态显示 `繁`、简体态显示 `简`、原样态显示 `原`（点击后切换到下一态）。模式存进 `scripture_display_settings` 的 `showOriginalText` 与 `showSimplifiedText` 两个布尔值；`showOriginalText == true` 时为「原样」，界面文字一律不做简繁转换。

当前它主要用于：

- 首页、阅读器顶部标题、按钮、提示等界面文字（`main.dart` 内自定义 `Text`/`_DisplaySelectableText` 会经过 `_displayText`）；
- 候选面板的「歷史 / 簡體 / 原始輸入 / 實際搜尋 / 字典」标签；
- 词典页面与词典查询结果的词条 key、词典名与释义 value（词典内容本身是简体，切到繁体时经 `toTraditionalDisplay` 转繁，切到原样时直接显示简体原文）。

**经卷正文不在转换范围内。** 阅读器的正文、卷题/作译者行和检索高亮都直接使用 CBETA 原文；切换简繁显示不会重新生成整卷简体正文。也就是说：

- 顶部界面可以显示简体，但正文仍可能显示繁体；
- 卷内搜索与全局搜索都在原文上进行，不会因为显示模式改变而改变匹配文字。

这是一个已知的产品/实现现状，不是文档遗漏；若要让正文也跟随简繁切换，需要单独设计与缓存策略。

### 8.2 转换算法

`toTraditionalDisplay(text)`：

1. 如果文本不含任何 `_simplifiedOnly` 字符，直接返回原文；
2. 否则按 `phrases_simplified_to_traditional` 做最长词组匹配；
3. 未命中词组时查 `hanzi_simplified_to_traditional`，取第一个候选；
4. 词表和单字表都没有的字保留原字。

`toSimplified(text)`：

1. 如果文本不含任何 `_traditionalOnly` 字符，直接返回原文；
2. 否则按 `phrases_traditional_to_simplified` 做最长词组匹配；
3. 未命中词组时查 `hanzi_traditional_to_simplified`，取第一个候选；
4. 词表和单字表都没有的字保留原字。

`toSimplifiedAll(text)` 与 `toSimplified` 使用相同的分段规则，但**跳过第 1 步的集合检查**，总是执行转换。它只用于生成 `fullSimplified` 候选，不用于界面显示。

因此：

- 词组优先于单字；
- 多候选时永远取第一个，不弹选择；
- `toSimplified` 会因第一步的集合检查跳过纯共用字文本；`toSimplifiedAll` 不会；
- 词表覆盖不到的字不会猜测，保持原样。

### 8.3 性能现状

当前实现对传入的整段文字逐位置做最长词组扫描（最长 3 字），没有 Trie、Aho-Corasick 或转换结果缓存。由于正文目前不经过显示转换，主要调用点是短界面文字，实际成本较低。

早期方案中讨论过的以下优化**尚未实现**：

- 只对歧义字附近做词组匹配；
- 用 Trie / Aho-Corasick 替代逐位置扫描；
- 以 `work:juan:mode:lexiconVersion` 为 key 缓存整卷转换结果；
- 词库版本变化时整体失效缓存。

如果以后把简繁转换应用到整卷正文，需要先补齐这些性能措施。

---

## 九、词典查询

入口是「选择佛经 → 词典查询」。输入组件已改为 `SearchInput`，提供与正文搜索相同的实时候选面板；候选排序依据是**字典 key 的命中数**，不是本地经文统计。

### 9.1 输入与候选

- 输入框使用 `SearchInput`，支持拼音/简繁输入时的实时候选；
- 候选产生规则与第三章相同：首选、原始输入、全简体、双向组合；
- 候选面板为每个候选统计所选词典的 key 命中数，并按第四章的规则排序、显示 `字典 N`；
- 点击候选只替换输入框文字，不立即查询；
- 键盘搜索键或「搜尋」按钮才执行查询。

### 9.2 按 key 命中数统计

`FodictService.countKeyMatches(baseDir, candidates)`：

- 首页与词典查询都**不传 `dictionaryIds`**，即按全部可用词典的 key 统计（不再限定内建 030）；
- 对每个候选统计 `key.contains(candidate)` 的次数（大小写不敏感）；
- 返回 `candidate -> count`。

统计是异步的，由 `SearchInput` 做 180 ms 防抖；候选首次显示不等待统计，统计完成后再重排非固定候选。重排时繁体／混排候选优先于简体／中性候选，各组内部再按命中数从大到小（见 4.4）。

### 9.3 实际查询与字体回退

提交时按以下优先级决定查询词：

1. 用户选中的候选（`SearchSelection.query`）；
2. `search_selections` 的历史匹配；
3. `resolveSearchQuery` 用首选 + 词典 key 命中数选出更优候选。

如果用户**明确点选**了候选（`SearchSelection.isExplicit == true`），词典查询只使用所选文字本身，不再尝试简繁变体；即使该写法没有 key 命中，也不会静默改用另一种写法。这样「云 → 雲」的明确选择不会被回退成简体「云」，记录和输入框也保持「雲」。

未明确选择时，`_searchDictionaryKeys(query)` 依次尝试：

1. 原字符串；
2. `toSimplified(query)`；
3. `toTraditionalDisplay(query)`；

用 `searchByKey` 做 key 包含匹配，并过滤到当前选中的词典。使用第一个有结果的写法；如果发生了替换，结果提示会附带「已用「...」查询」。这个实际使用的写法就是写入 `search_selections` 的值，输入框也会同步更新为该写法。

`FodictService` 会缓存已加载的词典内容；这里扫描的是词典 key，不读取经文。

词典结果条目点击后在侧栏内就地展开/收起释义（不弹窗）。词条名与释义都使用 `_scriptureTextStyle(scriptureDisplaySettings)`，与首页字典结果一致跟随显示设置的字号、字体与行高。在展开的释义中选中文字会弹出自定义工具栏：**全選／查詞典／複製**；点「查詞典」会把所选文字写入输入框，并**立即以该文字执行查询**（等同按下「搜尋」按钮），侧栏结果列表随即更新为新词的搜索结果。

### 9.4 记录与 Goto

- 每次实际执行词典查询后写入：
  - `search_history`：原始输入；
  - `search_selections`：原始输入 → 实际查询词；
- 记录失败不影响查询结果；
- 词典查询不会执行 Goto，也不会打开阅读器；
- Goto 形状的输入不会显示候选面板（`buildSearchChoices` 的统一抑制），提交后仍按词典 key 查询。

### 9.5 字典目录

- 内建词典从 `assets/fodict/030.dila-dingfubao` 加载（`FodictService.assetDictionaryIds` 目前只有这一部）；
- 其余词典（含 001.dfb-j 佛學大辭典）都作为可下载词典，从 Gitee Release 清单取得，用户下载后存进应用文档目录下的 `fodict` 子目录；
- 首页与词典查询的**候选 key 命中计数器对全部可用词典统计**（不再限定 `assetDictionaryIds`），并按「繁体优先、各组按命中数从大到小」重排（见 4.4）；
- 如果系统无法提供文档目录，工作选择器仍会加载内建词典，并使用空目录字符串查询，不会因为 `path_provider` 失败而无法打开词典页；
- 内建词典以 App 的 `FodictService.assetDictionaryIds`（当前只有 030）为准，选择器不再相信远程清单的 `bundled` 栏位；012/013/014 已从内建改为可下载词典；
- 词典是否「可下載」由 `FodictCatalogService._parse` 只看**是否存在受信任（gitee/github）的 `download_url`** 判定（`available = trustedUrl`），**完全忽略遠端清單的 `bundled`／`available` 欄位**（这两个栏位在线上的清单曾出现与事实相反的情况）；「內建」一律以 App 的 `FodictService.assetDictionaryIds`（`fodictDownloadManager.isBundled`）为准；因此只要词典有有效下载链接就不会再显示「尚未上傳」，012/013/014 显示 尚未上傳 的根因是**仓库里部署的 `fodict_manifest.json` 是旧版**（把 012/013/014 标成 `bundled:true/available:false`），需要重新生成并 push 到 gitee origin 与 github 两个 remote；
- 经卷选择器抽屉里的词典入口标签为「詞典」，位置在「部類」之后、「冊別」之前；其右上角的下载按钮会展开字典选择面板、全选所有词典，并弹出「下载全部词典」的确认对话框，确认后一次性排队下载所有尚未安装的可下载词典。

### 9.6 阅读器选中文字查詞典

- 阅读页正文选中文字后的浮动工具列，在「全選」与「複製」之间新增「查詞典」按钮；
- 点击后以选中文字打开 `_SelectionDictionaryDialog`，用 `FodictService.defaultBaseDir()` 解析词典目录（失败时退回空目录，仅查内建 030）；
- **不再提供「繁體／简体」字体分段按钮，也不再放词典筛选 chips**；改为对**所有已安装／内建词典**同时检索，命中结果**按词典折叠、汇总到同一个可滚动清单**（每部词典是一个 `ExpansionTile`，默认展开第一部，标题显示词典名与條数，「让用户选择」通过展开/收起各词典实现）；
- 查询时对词条做**繁体与简体两种写法都搜**（`toTraditionalDisplay` 与 `toSimplified`），并按当前显示模式排序：简体界面（`scriptMode == 'simplified'`）时简体写法的结果排前，繁体与原样界面时繁体写法的结果排前；同一词典内的条目按加入顺序去重（`dictionaryId + keyword`），偏好写法先加入故自然靠前；
- 每个词典条目（词头＋释义合成一段）渲染为 `SelectableText.rich`，选中后弹出自定义工具列（`contextMenuBuilder`），提供**「查詞典」与「複製」两项**：複製写入系统剪贴板，查詞典则以当前选中的文字**就地再次检索**（更新弹窗内的 `_term` 并重跑查询）。**弹窗内不再有单独的搜索输入框**，继续查询完全靠「选中文字 → 查詞典」；
- 结果文字（词条名与释义）的大小与字体**跟随 APP 显示设置**（使用 `_scriptureTextStyle(scriptureDisplaySettings)`，与经文正文一致），颜色走主题 `colorScheme` / `_displayText`；
- 弹窗标题栏右侧有一个**下载按钮**，点击后关闭弹窗并经 `_showWorkPicker(context, initialTab: 詞典, autoOpenDictionarySelection: true)` 跳到左侧边栏的选择佛经「詞典」标签页（`_workPickerDictionaryTab = 1`），并**自动点击「字典选择」按钮**（`_WorkPickerPageState.initState` 在 `autoOpenDictionarySelection` 为真时于首帧后调用 `_openFodictDownloadPanel()`，即展开字典选择面板、全选词典并弹出下载全部确认）。

### 9.7 「分類＋全文」式词典的 key 推导

`011.fjrwz-j 佛教人物传` 与 `018.chanzongyulu-j 禪宗語錄辭典` 的 `fodict.dat` 是两段式（`FodictService._loadSpecialFormat`）：先是分类条（关键字后跟 `defLen == 0`），之后是**没有独立关键字字段**的全文区。

- 全文区按「标题条＋正文条」成对存放，标题条形如 `南山律师道宣《佛祖历代通载》`、`智果（隋东都慧日道场）《续高僧传》卷三十`；判定规则是 `_isTitleRecord`：长度 ≤ 40 且同时含 `《` 与 `》`；
- 配对成功时 **key = 标题条全文（含出处）**，definition = 下一条正文（保留正文开头的自称，与原始文本一致）；标题条本身不再成为条目；
- 没有标题条领头的正文，key 取开头到第一个句读的位置，句读集合是 `（ ( ： : 半形空格 全形空格 换行 《 。 ！ ？ ； ，`，上限 24 字（`_keywordMaxLength`）；正文前后的私人区装饰字（`U+E000–U+F8FF`）与空白先剥掉，否则会出现空 key；
- 同名条目（一人有多篇传）不互相覆盖：key 冲突时继续取到下一个句读再试，仍冲突才丢弃该条；
- 实测结果（本地 `cbeta-fodict/fodict`）：011 得到 3036 条、key 平均 15.4 字、最长 24 字；018 得到 10230 条、平均 14.5 字、最长 24 字。修改前 011 最长 key 是 14098 字（整篇《法显传》），搜「八戒」会命中昙延整篇传记作 key；
- 影响：`searchByKey` 与 `countKeyMatches` 只扫描 key，所以正文用词（如「八戒」）不再进入候选面板的 `字典 N` 统计；`FodictService.search` 仍匹配 definition，全文检索能力没有丢。

标准格式词典（001–030 其余各部）走 `_loadStandardFormat`，key 就是词典自带的字段，不受本节规则影响。

---

## 十、阅读器高亮与锚点


搜索命中与卷内搜索共用一套「画面纯文字位移」系统：

- `_buildScriptureTextLayout` 依 `scriptureLines`、行首标记、校勘标记与直排/表格换行规则，产生实际渲染的文字与每行起始位移；
- 关键字命中以 `linehead` 定位到目标行，再由 `_resolveSearchTargetOffset` 换算成画面位移；同一行号可能有多笔命中，以「同行第 N 笔」区分；
- 卷内搜索在原始经文文字中比对（可跨过校勘标记），再把来源位移映射到画面位移，因此「安[2]置」能被「安置」命中并分别高亮「安」「置」；
- 卷末重复的经题保留文字（`navigationAnchor`），只是不显示行首标记；`volumeTitle` / `byline` 命中视为标题命中（回到卷首、只在顶部经题列高亮）；`navigationAnchor` 视为正文命中，滑到它在卷末的实际位置并在正文高亮，避免两笔搜索结果重复高亮同一个标题；
- 找不到行号（跨卷或经文改版）时退回卷首，不再阻止整卷阅读；
- 跳转后以「命中所在行」的行首为基准置中显示；`clamp(0, maxScrollExtent)` 会让卷首命中自动滑到最开头、卷末命中滑到最后面，其余情况维持居中；
- 表格与图片仍以 `WidgetSpan` 呈现，在 `SelectableText` 纯文字中各占 1 个 placeholder；`_buildScriptureTextLayout` 与渲染端必须使用相同的前进量，否则锚点与卷内搜索会整段偏移；
- 偈颂（`lg-row`）改以纯文字呈现（每格之间以不可见的 `WidgetSpan` 补足等宽置中间距），因此可以逐字选取；`_verseCellRenderedTexts` 同时供 layout 与渲染使用，两端的格内文字、校勘标记与 placeholder 数量必须一致；
- 偈颂段落前只在上一行没有自带换行时补一个换行（不额外留空行）；段落後补一个空行；偈字使用较大的行高。这些换行字符也必须同时写进 `_buildScriptureTextLayout` 与渲染端，`lineStarts` 以偈颂列本身为起点，搜索锚点才不会偏移；
- 标题固定在阅读页顶端显示，卷动内容的卷题/作译者靠右是用不可见的 `WidgetSpan` 留白达成（同一段文字才能选取）；该 placeholder 也算一个字符，reader 端的 `headerPrefixLength` 与 span 的 `toPlainText().length` 必须一致。卷题/作译者行的校勘标记也要一起渲染并计入长度；
- `WidgetSpan` 内的文字（当前主要是表格）不在纯文字位移系统中，改用 `highlightedWidget` 直接字符串比对来高亮（卷内搜索使用黄色、全局搜索使用绿色）；
- 关键字高亮以 `_matchRangesIn(layout.text, query)` 先算出所有命中范围，再与每个文字片段求交集；因此跨经文行、跨校勘标记的命中（如「四大五｜蕴迁变」的「五蕴」）也能正确高亮。

---

## 十一、失败处理与缓存

### 11.1 候选生成与命中统计

- 候选生成是同步的最长匹配与组合，随输入即时完成；
- 候选首次显示不等待词典统计；统计为异步、防抖 180 ms，失败时保留原顺序；
- 不启动 isolate、不读取本地经文、不发送计数请求；
- 用户修改输入、取消浮层或离开页面时，只需丢弃当前候选结果。

### 11.2 词表与转换缓存

- 四份词表在启动时加载一次，之后只读；
- 当前没有候选缓存，也没有繁 → 简转换结果缓存；
- 词表加载失败会中断启动（见 1.2），不会退回原文搜索；
- 修改词表后需要重新启动 App 才能生效。

### 11.3 历史记录与词典

- `SearchInput` 加载 `search_history` / `search_selections` 失败时按空数据继续；
- `resolveSearchQuery` / `preferredQueryForInput` 读取 `search_selections` 失败时忽略历史；
- `keyMatchCounter` 抛异常时退回首选候选，不阻塞搜索；
- 首页加载首页区块失败时会显示 SnackBar（「載入閱讀記錄失敗」），但搜索本身仍可继续；
- 应用文档目录不可用时，工作选择器与首页字典分区仍使用空目录加载内建词典（见 9.5）；
- 首页字典分区检索失败时只在该分区显示错误，关键字与经目结果继续展示；
- `FodictService` 缓存已加载的词典内容，提供 `clearCache()` 供测试或数据变更后清理；
- 全文搜索有 `_FullTextSearchCache`，按 query 缓存搜索结果快照，与候选生成无关。

### 11.4 离线正文连续扫描

- 实作在 `lib/scripture/offline_scan.dart` 的 `OfflineScanSession`：一次只交出一塊 `volumesPerChunk = 10` 卷给 `runOfflineScan`，读档、JSON 解码、`parseScriptureHtml`、逐行比对与 KWIC 片段都在背景 isolate 完成，UI isolate 只负责送出与接收，因此扫描期间不会挤掉任何一帧；
- `flutter test` 的 fake-async 不会推进真实 isolate 的回覆，网页版也没有档案，所以 `offlineScanSupportsIsolate()` 在这两种情况下走同一份同步实作（只少了 isolate 跳板）；经卷 ref 没有 `path` 时（网页版存 SharedPreferences）由主 isolate 用 `scanOfflineVolume` 逐卷读；
- 首页 `_applyOfflineKeywordResults` 先 `prepare()` 并扫一块让首屏有结果，接着 `start()` 交给会话自行连续推进（每块之间让出 12 ms），**不再依赖卷动或「繼續搜尋本地經卷」按钮**；离线正文会一路扫完全部本地经卷直到 `finished`；
- 进度透过 `ValueNotifier<OfflineScanProgress>` 回报，页面把通知合并成最多每 300 ms 一次 `setState`（`_offlinePublishInterval`），避免每一块都重建整个结果页；`loadMore()` 在离线模式直接返回，卷动不会再触发扫描；
- 中断方式：换新搜索、`clearSearch()`、离开页面（`dispose`）都会 `_stopOfflineScan()`（移除监听并 dispose 会话，进行中的那一块完成后自行退出）；App 进入后台时 `didChangeAppLifecycleState` 自动 `pause()`，回前台自动 `resume()`；用户可用正文分区的「暫停掃描／繼續掃描」按钮就地暂停；
- 离线结果不分页：每次发布的是会话累计的全部命中快照（`progress.results`），`hasMore` 表示「还没扫完」，扫完后显示「已載入全部 N 筆結果」；扫描中显示「已掃描 X/Y 卷」。
- 作品卡片上限**只作用于离线扫描模式**：扫描会自己累积几百部作品，所以正文分区只渲染前 `keywordVisibleGroups` 部（每页 `_resultSectionPageSize = 20` 部）；线上结果是使用者一頁一頁主动要来的，全部渲染，否则「載入更多結果」换来的新一批会被上限挡住、看起来像没反应；
- 两种分页按钮互斥，不重复出现：离线模式只有「顯示更多作品（剩餘 N 部）／收合多顯示的作品」，线上模式只有「載入更多結果」；
- 向下卷动是两种模式的主要推进方式（`_onResultsScroll`）：离线模式到底就 `_revealMoreKeywordGroups()` 再放行一页卡片，线上模式到底就 `loadMore(fromScroll: true)` 发下一批请求；扫描期间每 300 ms 发布一次快照，若几百张卡片全部挂在一棵 `Column` 上，点击最后一卷时整串卡片会跟着重画而卡死；
- 页面被其它路由盖住时（`_ownRoute.secondaryAnimation` 监听 + `isCurrent` 判断），进度只存进 `_pendingOfflineProgress`，等转场结束（`dismissed`）再一次性 flush，避免打开阅读器动画期间还在重建整页。

### 11.5 在线全文延迟

- `_fetchSearchBatch` 只发 `q`、`start`、`rows`、`around`，**不再请求 `facet`**：实测 `facet=1` 会让服务器多做一轮汇总，同一查询慢 2～6 倍（单字如「来」可差十几秒），而回传的分面栏位在本 App 没有任何使用者；
- 单字查询仍有服务端下限（约 3.5～4 秒），这是移除 `facet` 后剩下的时间，客户端无法再压缩；
- 因此 `_loadKeywordResults` 采用 stale-while-revalidate：先发 `_searchAllInOne`，但只要 `_FullTextSearchCache.get(query)` 有上次的快照就立刻用它的 `results` / `nextStart` / `totalFound` / `totalTermHits` / `hasMore` 顶住画面（并把 `isLoading` 关掉），API 回来后整批取代并重新 `remember`；同一个字再查第二次时不再面对空白转圈；
- `_FullTextSearchCache` 是静态 Map，测试之间会互相污染，所以提供 `debugReset()`，并由档案外的 `resetFullTextSearchCache()` 在 `setUp` 调用；
- 词典候选统计（`countKeyMatches`）冷启动约 112 ms、热缓存约 7 ms，不是搜索慢的原因。

### 11.6 逾时语义与经目本地回答

**逾时不再被当作离线故障**

- `_isNetworkFailure` 里包含 `TimeoutException`，所以旧版在网络上明明通、只是伺服端慢（单字「來」的 `all_in_one` 实测 26.3 秒）时，会在第 20 秒悄悄切去本地扫描，使用者看到的就是「等了二十多秒才出结果」；
- 新增 `_isRequestTimeout(error)`（`error is TimeoutException`），放在 `_isNetworkFailure` 判断**之前**：逾时只显示可重试的错误，保留画面上已有的结果，不启动离线回退。两处这样做——`_loadKeywordResults`（「全文搜尋逾時（等待超過 45 秒）…」）与 `loadMore`（「載入更多結果逾時…」）；经目分区改成纯本地之后已经没有需要判逾时的请求；
- 全文的超时上限从 20 秒调到 `_keywordSearchTimeout = 45 秒`（`_fetchSearchBatch` 与「載入更多」都用它），单字查询的服务端下限（约 3.5～4 秒）与慢查询的二十几秒都落在上限内；
- `_buildKeywordSectionContent` 的空结果分支加了 `keywordSearchError == null` 条件，请求失败时不再同时宣称「找不到『X』相關經文」。

**首页经目分区改成纯本地回答**

- `/stable/search/toc` 只有 `q` 参数，**完全忽略 `rows`／`start`／`limit`／`top`／`facet`**：实测一个常见单字回传 1177 笔、769 KB、耗时 56～79 秒，等它分页没有意义；
- `_searchLocalCatalog(query)` 直接用 `lib/download/catalog_cache.dart` 的 `CatalogCache.instance`（内建全量 work/title/creators/juans metadata，解析 5 份 JSON 约 4.4 MB）做 `searchWorks(needle, limit: 200)`，**零流量、即时**；`initState` 里 `unawaited(CatalogCache.instance.load())` 先暖好，第一次搜索才不用等解析；
- `searchWorks` **只按 `work`（編號）與 `title`（書名）匹配**，不再匹配 `creators`：目錄的 `creators` 是 `【…】` 裡的「朝代 + 譯者」（如「姚秦 佛陀耶舍 共 竺佛念 譯」），拿它参与匹配會讓人名與朝代變成經目結果裡的命中項（行尾顯示為「經目匹配 · 姚秦 佛陀耶舍譯」）；找翻譯者本來就有側欄的「作譯者」分頁（走 `CatalogCache.creators`），朝代有「年代」分頁，所以經目查詢不需要重複這件事。排序只剩完全同名（rank 0）與前綴（rank 1）；返回行仍保留 `byline`／`creators` 欄位供顯示與詳情使用；離線經目回退 `_searchOfflineCatalog` 的本地經卷匹配的也只是「書名 + work 編號」，同樣不含 byline；
- `_loadCatalogSearchResults` 已经**完全不发网络请求**：`_searchLocalCatalog`（内建全量目录）没命中时，再看本地已储存经卷的 `_searchOfflineCatalog`，两步都是本机的；分区标题固定是「經目搜尋結果（本地經目）」，没有命中就显示「本地經目沒有書名含『X』的作品」；`_fetchCatalogSearchResults`、`_catalogSearchTimeout` 与 `catalogSearchIsLocal` 标记都已删除；
- **本地查完也必须走完 `finally`**：整段包在外层 `try/finally` 里清 `isCatalogSearchPending`，因为 `_updateCombinedSearchError()` 与 `isLoading` 要等两个 pending 都结束才更新，卡在 `true` 会让全文逾时的提示信息完全不被显示（这是先前本地经目抢答后错误信息消失的原因）；
- `/stable/search/toc` 只剩「選擇佛經 → 經目查詢」分页的 `_runTocSearch` 还在用：它先本地 `searchWorks` 铺满，再合并远端 `type == 'work'` 的行（远端优先、按 work 去重），请求失败时保留本地结果。要按人名／朝代查，用侧栏的「作譯者」「年代」分页，而不是首页搜索框。

实测数据（供后续调整参考）：`facet=1` 让同一查询慢 2～6 倍；移除后单字仍有 3.5～4 秒下限；「來」`all_in_one` 26.3 秒；「法」`toc` 56～79 秒／1177 笔；三个搜索请求并行约 2 秒、串行约 5.5 秒。

---

## 十二、测试、实现状态与后续

### 12.1 当前测试覆盖

`test/widget_test.dart` 中与搜索相关的主要测试：

- `homepage toggles persisted simplified text display`：`convert`、`convertCandidates`、`toSimplified`/`toSimplifiedAll`、`toTraditionalDisplay` 的典型结果与简繁显示切换；
- `live search input shows history and candidate choices`：空输入历史、实时候选、原始输入标记、标签随显示模式转换、点击候选只填充、光标变化后按搜索键仍提交原始输入；
- `candidate rows show and sort by dictionary key hits`：词典命中数显示、固定候选保持前两位、其余按次数排序；
- `search query resolution prioritizes selection, history, and hits`：选中候选 > 历史 > 首选；命中数更高时覆盖首选；统计异常退回首选；全简体候选标记；
- `searches are saved and can be selected again`：首页写入 `search_history`、清空后重新聚焦显示历史、点击历史后按搜索键再次搜索；
- `homepage ambiguous simplified input offers candidates`：多候选面板、点击候选不搜索、按搜索按钮后才搜索；
- `multi-character ambiguous input offers cross-product candidates`：`厂丑` 的四个组合与延迟提交；
- `work picker converts simplified text before TOC search`：经目查询点击候选后使用转换结果；
- `dictionary tab offers live candidates and records the query`：词典页实时候选、命中数、点击候选不查询、按钮查询、写入 history + selection、不执行 Goto；
- `dictionary explicit traditional selection is not converted back`：词典页明确选择「雲」后按搜索，仍以「雲」查询与记录，不回退成「云」；
- `homepage groups results into collapsible sections`：首页经目 / 字典 / 正文三个分区、经目与字典初始各 1 条与展开全部、各分区折叠/展开；
- `dictionary key matches keep simplified candidates`：词典 key 统计与简繁候选；
- `Goto extracts CBETA citations from surrounding copied text`、首页/离线 Goto 测试：Goto 解析与打开；
- `offline search ...`：离线全文/经目回退；`offline search scans local volumes incrementally` 验证不需要任何卷动就会一路扫完 70 卷并显示「已載入全部 70 筆結果」，且只画出前 20 部作品（「顯示更多作品（剩餘 50 部）」）；
- `repeat keyword search paints cached results before the API`：第二次同字查询用 `_FullTextSearchCache` 先出结果（API 被 `Completer` 挡住时画面已有结果），并断言 `all_in_one` 请求不带 `facet`；
- `catalog section is answered locally without toc request`：经目分区由内建目录直接回答，统计 `/stable/search/toc` 请求数为 0；
- `homepage searches keyword and catalog concurrently and prioritizes catalog matches`：用 `CatalogCache.debugLoad` 造 11 部测试经目，全文请求还被 `Completer` 挡住时经目分区已经出结果且 `toc` 请求数为 0；全文回来后断言「经目命中的作品」排在只有全文命中的作品前面，以及展开后的分页行数；
- `keyword search timeout keeps results instead of going offline`：`all_in_one` 抛 `TimeoutException` 时只显示「全文搜尋逾時」，不出现「找不到…」／离线扫描提示，经目分区仍由本地回答；
- `offline search shows local catalog matches separately`：离线经目命中显示「經目搜尋結果（本地經目）」并可展开更多；
- `online search keeps loading batches while scrolling`：线上第一批全部渲染、没有「顯示更多作品」按钮，卷到底自动发 `start=2` 的下一批并渲染新一部作品；
- `scrolling reveals the next offline result groups`：离线扫描先只渲染 20 部（第 25 部看不到），卷到底自动放行第二页并出现「收合多顯示的作品」；
- `test/offline_scan_test.dart`：`OfflineScanSession` 的分块扫描、自行连续推进到全部卷、暂停后不再排下一块、恢复后从中断处继续、没有本地经卷时立即结束，以及 `runOfflineScan` 的 KWIC 片段；
- `in-volume search highlights ...`、`reader centers ...`、`reader clamps ...`、`reader aligns hits ...`：卷内搜索位移、跨校勘标记、偈颂与滚动对齐。

### 12.2 尚未覆盖或建议补充

- 历史匹配的包含/编辑距离阈值与同分规则；
- 混合输入原文置顶与历史候选不固定；
- 50 个组合上限、20 行面板上限、8 行历史上限；
- AI 页面使用首选候选而非原始输入；
- 词典统计失败、词典目录不可用时的降级；
- 非首页入口对 Goto 形状输入抑制候选但不执行 Goto；
- `_FullTextSearchPage` 与 `DictionarySearchPage` 若恢复使用，需要重新接入测试。

### 12.3 实现状态

已完成：

- 四份词表的加载、文字类型判定、双向词组优先 + 单字兜底的候选生成；
- 任何非空输入都生成候选；首选 = 原来命中的文字，原始输入第二，全简体候选随后；
- `pinnedCandidates`、`fullSimplified`、`resolveSearchQuery`；
- 词典 key 命中统计、180 ms 防抖、缓存、面板排序与「字典 N」显示；
- 共享 `SearchInput` 实时候选浮层、历史列表、标记合并、点击只填充、提交/输入法处理；
- 首页、卷内搜索、经目查询、作译者查询、词典查询的候选接入；
- 首页与词典查询使用「选中候选 / 历史 / 首选 + key 命中统计」；
- 首页结果分为经目 / 字典 / 正文三个可折叠分区；经目与字典初始各 1 条，可分别展开全部；正文分区按作品（一级，默认折叠且懒惰渲染）→ 卷（二级）分组；
- 词典查询记录 history + selection，且不执行 Goto；
- 用户明确点选的词典候选不再做简繁字体回退；
- 离线正文连续扫描（isolate 分块、300 ms 合并发布、暂停/恢复、路由转场期间抑制重建）与离线模式下才生效的作品卡片上限（见 11.4）；
- 线上全文的 `facet` 移除、stale-while-revalidate 快照顶屏，以及「逾时 ≠ 离线故障」的分支与 45 秒上限（见 11.5、11.6）；
- 首页经目分区改成纯本地回答：内建全量目录 + 本地已储存经卷，全程不发请求，标题固定为「經目搜尋結果（本地經目）」（见 11.6）；
- 阅读器关键字高亮与卷内搜索锚点；
- 词表检查脚本与 `厂`/`云` 顺序说明。

未实现：

- Trie / Aho-Corasick 词表匹配；
- 整卷转换缓存；
- 正文的简繁显示转换（当前只转换界面文字）；
- 按使用频率排序的历史匹配；
- 候选生成中的任何本地经文统计。

### 12.4 与早期方案的差异

| 早期方案 | 当前实现 |
|---|---|
| 按字组合并统计本地经文命中 | 候选生成不扫描经文；首页/词典只统计词典 key |
| 等待计数后再排序 | 候选立即展示；命中数异步返回后只重排非固定候选 |
| 纯繁体/共用字不生成候选 | 任何非空输入都生成候选，并提供全简体候选 |
| 历史选择参与候选置顶 | 历史只作为候选标记与查询词优先级，固定项只有首选和原文 |
| 点击候选立即搜索 | 点击只填充输入框，必须再按搜索按钮/搜索键 |
| 文本编辑下拉框 | 根 Overlay 中的只读 Material 列表 |
| 只判断“全简体/全繁体” | 增加 mixed / neutral 与共用字处理 |
| 所有入口都做 Goto | 只有首页自动判断；另有独立 Goto 查询标签页 |
| 卷内/经目/作译者使用首选转换 | 三者都接入共享候选面板 |
| 经目/作译者搜索正文 | 只查经目/作译者元数据 |
| 历史按使用频率优先 | 按匹配得分，同分取最近插入 |
| 整卷简繁转换 | 只转换界面文字；正文保持原文 |
| 词典查询用候选对话框 | 词典页直接使用 `SearchInput` 实时候选面板 |
| 首页结果混排 | 经目 / 字典 / 正文三个可折叠分区，前两者初始各 1 条，正文一级作品默认折叠并懒惰渲染，展开后显示卷分组与命中片段 |
| 词典查询总是尝试简繁回退 | 明确点选候选时只查所选文字；未明确选择才回退 |

### 12.5 后续如果要扩展

1. 让正文跟随简繁显示切换：先补转换缓存与词表匹配性能，再改阅读器渲染；
2. 修正纯共用字词组（如「以后」）的显示转换触发问题；
3. 根据实际搜索记录补充词组表；
4. 为历史匹配阈值、候选上限、AI/词典交互补充测试；
5. 清理未接线的 `_FullTextSearchPage` / `DictionarySearchPage`，或重新接入并补测试。

---

## 十三、卸载后的数据保留

Android 端启用系统自动备份与卸载保留提示：

- `android:allowBackup="true"`；
- `backup_rules.xml` 与 `data_extraction_rules.xml` 包含 `sharedpref`、`file`、`database`、`external` 域，覆盖搜索记录、设置与离线经文；
- `android:hasFragileUserData="true"`：卸载时系统会询问是否保留应用数据。

注意：自动备份依赖设备的备份开关与云端配额，不能保证在所有设备上跨卸载恢复；卸载对话框中是否勾选保留数据也由用户决定。
