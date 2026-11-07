# HTML 解析／渲染衝突樣本集（回归門禁）

> 目的：CBETA 的**線上 `/stable/juans`** 與**離線 `download/html/*.html.zip`** 是兩套形態不同的 HTML，
> 同一段經文在兩邊標記並不等價。歷來「改好一個、弄壞另一個」的問題都在這裡登記。
> 改 `lib/scripture/parser.dart`、`lib/reader/reader_layout.dart`、`lib/reader/reader_page.dart`
> 的任何解析／排版／樣式邏輯之前，先把這份文件當檢查清單跑一遍。
>
> 最後核對：2026-11-02，CBETA `stable`（網頁引號為 2026.R2；可下載 ZIP 內部檔案日期 2026-08-04、
> 使用者手機上的離線包可能是 2026.R1 → 兩边引文版本會不一致，先懷疑資料而不是代碼），
> 樣本卷 `T0001_001`（長阿含經卷第一）、`T0152_001`（六度集經卷第一）。

---

## 1. 兩份資料源的結構差異（務必知道這是「資料不同」不是「解析漏字」）

| 特性 | 線上 `/stable/juans` | 離線 ZIP `T0152.html.zip` | 對 App 的影響 |
|---|---|---|---|
| 逐字 token | `<span class="t" l="0001a03" w="1">六度集經</span>`（T0001 1756 筆、T0152 868 筆） | 完全沒有（0 筆），文字直接是 `<p>` 的裸文字 | 文字被切成碎片，任何「靠字串比對」的定位都要先拼接；反過來說離線版比較「乾淨」 |
| 行錨點 | 每行都有 `<span class="lb" id="T03n0152_p0001a03">` | 只有段落級 `<span class='lineInfo' line='0001a05'>` | 行號跳轉：線上可精確逐行；離線要退到 `_resolveArchiveAnchorTarget`（取最近段落錨點） |
| 校勘錨點 | `<a class="noteAnchor" href="#n0001001"></a>`（**空元素**，注文在 `#back`） | `<a id='note_anchor_0001001' class='noteAnchor' href='#n0001001'>[1]</a>`（**錨點內含可見 `[1]` 文字**） | ⚠️ `[6][6]` 類重複標記的根源：解析器跳過錨點子節點，但任何「不跳過子節點」的取文字路徑都會把 `[1]` 帶進來，再加上自己插的標記 → 兩次 |
| 星號校勘 `<app type="star">` | 有：`class="noteAnchor star"`（T0001 35 筆、T0152 16 筆）→ 顯示 `[＊]` | **0 筆**（ZIP 管線整段去掉） | 離線閱讀／離線索引本來就沒有 `[＊]`；測試不可假設兩邊一致（詳見 `lib/download/feature_logic.md`） |
| 異體字 | `<a class='gaijiAnchor' href='#CB02425'>𥥧</a>`（另有 `gaijiInfo`） | `<span class="gaiji" data-gid="CB00416">箒</span>` | 兩種 class 名都不同，且**都不是** `siddam`/`ranjana`；靠通用分支保留字元，改 `visit()` 的 class 攔截時容易漏 |
| 影印頁標記 | `<a class="facsimile" data-ref="...">`（T0001 45 筆） | 0 筆 | 空 `<a>`，若哪天不再跳過空元素就會多出垃圾 |
| 下載器改寫 | 不經改寫，逐字進線上快取 | `normalizeArchiveHtml()` 先把 `<span class='lineInfo' line='X'>` 換成 `<span class="lb" id="<prefix>_pX">…</span>`，再壓掉 `>\s*\n\s*<` 的標籤間空白 | ⚠️ 離線存的 HTML **不等於**原始 ZIP 內容：行錨點因此可能落在 `<p class="byline">` 等段落**內部**，觸發 `flushLine()`（見 C-16） |
| `<style>` 區塊 | 無 | 有（內嵌整個 CSS） | ⚠️ 這是「網頁長怎樣」的權威依據，`#body` 之外，解析起點是 `querySelector('#body')`，不會讀到它 |
| 前導 `No. xxx` | 在 `#body` 內（`<span class="t">No. 152</span>`） | 在 `#body` 內是裸文字 `\n  No. 152` | 兩邊都要靠 `_leadingNumberPattern` 排除出索引，但仍顯示在正文 |

### CBETA 內嵌 CSS（離線 ZIP 裡逐字抓到，網頁外觀的真相源）

```css
p        { text-indent: 2em; }
.byline  { color: #408080;  text-align: right; }      /* 作譯者：靠右、青灰，字不差 */
.juan    { font-size: larger; color: #00f; }          /* 卷題：放大、藍色（不置中） */
.head    { font-size: larger; color: #0000a0; }       /* 品題：放大、深藍 */
div.lg   { display: table; color: #008040; margin-left: 4em; }   /* 偈頌：綠色、左縮排 */
.doube-line-note { color: purple; font-size: 0.8em; }  /* 夾注：紫色小字 */
span.footnote { display: block }
```

> App 自己的慣例與官方 CSS **故意不同**：卷題＝置中＋綠（淺 `#007564`／暗 `#72C5B2`）、
> 作譯者＝靠右＋`0.8×`＋淡色（淺 `#8C7B66`／暗 `#A99A85`）、章題＝放大加粗但不染色。
> 調樣式時以 App 慣例為準，但**不要**讓「卷題」與「章題」用同一個判準（見 C-05）。
>
> **不讀 HTML 的 `<style>` 是刻意的**：解析起點是 `querySelector('#body')`，內嵌 CSS 根本進不了渲染層；
> 樣式一律由 `ScriptureLine.role`＋`ScriptureDisplaySettings` 決定。若改成跟隨官方 CSS，需要
> ① 解析並級聯 CSS（含 `!important`、`em` 單位），② 把 `color`/`text-align`/`font-size` 映射成 `TextStyle`，
> ③ 再決定它與使用者設定（字號、暗色、簡繁、行距）誰優先——而官方 `.juan` 是藍色**不置中**、
> `.byline` 是 `#408080`，直接採用會推翻 App 既有慣例。要忠於原樣請開瀏覽器看 CBETA 網頁。

### 重取樣本（更新這份文件時用）

```bash
curl -s "https://cbdata.dila.edu.tw/stable/juans?work=T0152&juan=1" \
  | python3 -c "import json,sys;open('T0152_001.online.html','w').write(json.load(sys.stdin)['results'][0])"
curl -s -o T0152.zip "https://cbdata.dila.edu.tw/stable/download/html/T0152.html.zip" && unzip -o T0152.zip
```

---

## 2. 案例卡

每張卡片記：**原始片段（逐字，含引號形態）→ 當今實測 → 期望 → 它保護的 bug → 动了会坏什么**。
「實測」＝ 2026-11-02 用真資料跑 `parseScriptureHtml()` 與閱讀器 widget（800px 視窗、預設字號 19）得到的數字。

### C-01 卷首卷題（線上形態）
`T0152` p.1a3 —
```html
<div class="div-other"><span class="lb" id="T03n0152_p0001a03">T03n0152_p0001a03</span>
<a class="facsimile" data-canon="K" data-s="dongguk" data-ref="K0206.11.0285.a"></a>
<p class='juan'><span class="t" l="0001a03" w="1">六度集經</span><span class="t" l="0001a03" w="5">卷第一</span></p>
```
- 實測：`role=volumeTitle headingLevel=2`；渲染 span `color=#007564 fontSize=23.75 w700`，caret 起點 240.9／終點 407.1，段寬 648 → 中點 324 = 648/2，**置中成立**。
- 保護：卷題曾被抽到頁首 metadata 而在正文消失。
- 注意：`class='juan'` 用**單引號**、`class="t"` 用雙引號，混用；任何字串級 HTML 前置處理都可能改寫它。

### C-02 卷首卷題＋作譯者（離線 ZIP 形態，同一句話的另一種寫法）
`T0152` p.1a3／1a5 —
```html
<div id='body'>
  No. 152<div class="div-other"><p class='juan'>六度集經卷第一</p>
  <p class="byline"><span class='lineInfo' line='0001a05'></span>吳<a id='note_anchor_0001001' class='noteAnchor' href='#n0001001'>[1]</a>康居國沙門康僧會譯</p>
```
- 實測：`volumeTitle HEAD=2`；`role=byline text=吳康居國沙門康僧會譯 footnotes=[1]`（錨點內可见的 `[1]` 被正確丟棄，只在 offset 1 前插一次）。
- 保護：`[6][6]` 同型的「標記重複」；離線版沒有逐字 token，走的是另一條文字拼接路徑。
- ⚠️ 這裡測的是**原始 ZIP 內容**；App 離線 store 裡存的是**改寫後**的內容，role 會不一樣 → 見 C-16。
- 注意：卷題與作譯者**同一卷各只有一筆**（`class="byline"` 1 筆、`class='juan'` 2 筆），第二筆 juan 是卷末尾題 → C-04。

### C-03 序文之後才出現的卷題（不能被判成「尾題」）
`T0001` p.1b8（離線 ZIP）—
```html
…故略記時事，以示來賢焉。</p>
</div><p class='juan'>佛說<a id='note_anchor_0001011' class='noteAnchor' href='#n0001011'>[11]</a>長阿含經卷第一</p>
<p class="byline"><span class='lineInfo' line='0001b10'></span><a id='note_anchor_0001012' class='noteAnchor' href='#n0001012'>[12]</a>後秦弘始年佛陀耶舍共竺佛念譯</p>
```
- 實測：離線卷第 **8** 行＝`volumeTitle HEAD=2`（有置中綠色）；線上同卷第 **41** 行也是 `volumeTitle`。
  原因是降級條件 `enteredBody` 只在「**已經出現過卷題**之後的非卷題行」才為真，序文不會把後面的真卷題吃掉。
- 保護：使用者回報「離線下載缺這句文字」。**這條是 C-04 改動的對照組**：任何「重複卷名一律降級」的寫法都會把這句弄回無樣式。
- 注意：卷題自己帶校勘 `[11]`、作譯者帶 `[12]` → 標記只能出現一次。作譯者現在**留在正文原位**，
  它的標記長度由 `_bylineLeadingLength`／`_alignedBlockLeadingLength` 在 layout 與渲染兩端同一函數算出，不再有 `headerPrefixLength`。

### C-04 卷末尾題（第二次出現的同名卷題）→ 置中＋綠色，但不顯示行首標記
`T0152` p.6a20 —
```html
…菩薩慈惠度無極行布施如是。」</p>
</div><span class="lb" id="T03n0152_p0006a20">T03n0152_p0006a20</span>
<p class='juan'><span class="t" l="0006a20" w="1">六度集經</span><span class="t" l="0006a20" w="5">卷第一</span></p></div></div>
```
（離線 ZIP 同段：`</div><p class='juan'>六度集經卷第一</p></div>`）
- 實測：`parser.dart` 尾部掃瞄把 `text` 去空白、去 `[n]` 後與第一筆卷題同名 → 降成
  **`role=volumeTailTitle, headingLevel=2`**（不再是 `navigationAnchor/HEAD=0`）。
  渲染 span `color=#007564`，caret 起點 240.9／終點 407.1，段寬 648 → 中點 324 = 648/2，**與卷首題同樣置中**
  （實測線上 p.6a20 落點 `@787`、離線 ZIP `@514`，兩邊都 mid=324.0）。
- 保留的兩條保護（原本靠 `navigationAnchor` 取得）：
  1. `ScriptureLine.suppressesLineBeginning` 包含 `volumeTailTitle` → **不顯示行號標記**，
     否則卷末標號會排在卷首標號之後，校勘與行號讀序錯亂（`visibleScriptureLine` 與 `_scriptureLineBeginningPrefix` 都以這個 getter 為閘門）。
  2. 不當作卷名 metadata；`sidx_store.dart` 把它當成**摘要邊界**（`boundaryRanges`）但**不**設 `seenVolumeTitle`，
     所以卷末之前的「前導經號提示行」仍不會進索引。
- 保護的 bug：commit `97e3195` 的「卷題上移頁首 → 校勘標記重複／序內卷題消失」。改這裡時那兩條回归必須一起跑。
- ⚠️ 判準陷阱：`headingLevel==2` **不能**當卷題樣式的閘門 → 見 C-05。
- ⚠️ 列舉順序陷阱：`ScriptureLineRole` 的新值**只能加在 enum 末尾**，離線索引 `.sidx` 以 `role.index`（uint16）存角色；
  插入中間會讓舊離線包的角色全部錯位。

### C-05 品題／章題（`headingLevel` 與卷題撞值）
`T0001` 卷1（離線 ZIP）與 `T0152` p.1a6 —
```html
<p data-head-level="1" class="head">布施度無極<a class="noteAnchor" href="#n0001002"></a>章第<a class="noteAnchor" href="#n0001003"></a>一<small class='inline-note doube-line-note'>…</small></p>
<p data-head-level="2" class="head">（一）第一分初<a class="noteAnchor" href="#n0001021"></a>大本經第一</p>
```
- 實測：`T0152` 章題 `role=regular headingLevel=1`（渲染 w700、25.65px、**不染色**）；`T0001` 的「（一）第一分初大本經第一」`role=regular headingLevel=2`。
- 結論：卷題的綠色／置中只能靠 **role** 辨認，`headingLevel` 會與二級品題相同。

### C-06 作譯者行的視覺（靠右＋小字＋淡色）
- 實測（真資料 T0152，800px 視窗／預設字號 19）：作譯者 span `color=#8C7B66`、`fontSize=15.2`（=19×0.8）；
  行內片段「康居國沙門」caret 508.08 → 585.92（舊版約 0 → 左齊）。整行靠右由 widget 測試斷言「行尾 caret ≈ 段寬 648」。
- 目前做法：**不抽頁首**，`_isBodyByline` 判定後在正文原位排版，靠右用與卷題置中同一條路徑
  （`TextPainter` 量寬 → 補一個不可見 `WidgetSpan`，`pad = spareWidth`）。表格／偈頌／圖片行不適用。
- 過去四個結構盲區**已关闭**，改回去時要重新驗：
  1. ~~只掛在 block 0~~ → 現在在正文原位，從 p.6a20 之类的卷尾行進入也看得到。
  2. ~~排在 `No. 152` 與卷題之上、違反來源順序~~ → 實測 T0152 離線卷序為
     `volumeTitle(六度集經卷第一)` → `byline(吳康居國沙門康僧會譯)`，來源順序即顯示順序。
  3. ~~量測 spans 與渲染 spans 不同源~~ → 兩端都取自同一個 `contentSpans(line, …)`，寬度一致；
     不再需要 `pad.clamp` 退化成左齊的補丁。
  4. ~~header 路徑不做簡繁轉換~~ → `reader_page.dart` 區塊根節點就是正文 span，統一過 `displayInlineSpan`，
     卷題與作譯者現在會隨簡繁設定轉換。
- 保留的代價：`resolveSearchTargetOffset` 不再有 `inHeader`／`headerAdvance` 特例，
  layout 覆盖整卷，書籤與搜尋命中的 source offset 直接换算（改這裡要一起驗 `test/offline_scan_test.dart`）。

### C-07 一卷有多條作譯者
`T0001` 卷1 —
```html
<p data-head-level="1" class="head">長阿含經序</p><p class="byline">長安釋僧肇述</p>
… <p class="byline">…後秦弘始年佛陀耶舍共竺佛念譯</p>
```
- 實測：兩條都是 `role=byline`，各自留在原位（離線卷第 2 行與第 9 行），第 9 行前後的卷題是
  `volumeTitle`（見 C-03），卷末再出現的同名卷題才是 `volumeTailTitle`。
  離線 T0001 卷1 開頭四行的實測序列：`byline(長安釋僧肇述)` → `volumeTitle(佛說長阿含經卷第一)`
  → `byline(後秦弘始年佛陀耶舍共竺佛念譯)` → `volumeTailTitle(佛說長阿含經卷第一)`。
- 影響：`localVolumeInfo()` 取**第一筆** `byline` 當書名／作譯者顯示，所以 T0001 摘要的 byline 是「長安釋僧肇述」而不是譯者。
  這條與渲染無關，只依賴解析順序 → 改 parser 抽 byline 的順序時會變。
- ⚠️ 相鄰規則：卷題與作譯者**緊鄰時不插空行**（`_isFollowedByByline` →
  `_needsParagraphBreak`／`_needsVolumeTitleBreak` 回傳 false）。
  這條規則必須在 `buildScriptureTextLayout` 與 `interactivePassageText` **兩端同時成立**，
  少一端就會讓 `lineStarts` 與實際渲染位移錯一位，搜尋高亮／跳轉跟著偏。

### C-08 偈頌跨格校勘 `[6][6]`（位移歸屬歧義）
`T0001` p.7b21（離線 ZIP）—
```html
<div class="lg-row"><div class='lg-cell'>如鳥遊虛空，</div>
<div class='lg-cell'><a id='note_anchor_0008006' class='noteAnchor' href='#n0008006'>[6]</a>東西隨風<a id='cb_note_anchor5' class='noteAnchor add' href='#cb_note_5'>[A5]</a>逝；</div>
</div>
```
- 實測（現況正確）：`verseCells=[如鳥遊虛空，, 東西隨風逝；]`；
  `NOTE label=6 offset=6 cell=1`、`NOTE label=A5 offset=10 cell=1`。
- 由來：錨點寫在**第二格開頭**，而 `ScriptureFootnote.offset` 記的是**全域 text buffer 長度**，
  `6` 正好等於第一格「如鳥遊虛空，」的長度 → 按位移推歸屬時同時落在「前一格格尾」與「後一格格首」→ 兩格都渲染 → `[6][6]`。
- 守則：**任何「依位移推斷語意」的地方都要有解析期記錄的備援**（`verseCellIndex` 就是這個角色）；
  `_verseCellIndexForNote`、`_verseCellRenderedTexts`、`layoutEditableOffsetForSource`、`interactivePassageText` 四處必須共用同一判斷。

### C-09 夾注跨行（`inline-note`／`doube-line-note`）
`T0152` p.1a6（線上）—
```html
<small class='inline-note doube-line-note'><a class="noteAnchor" href="#n0001004"></a>
<span class="t" l="0001a06" w="9">此有</span><a class="noteAnchor" href="#n0001005"></a><span class="t" l="0001a06" w="11">一</span>
<span class="t" l="0001a06" w="12">十章</span></small>
```
- 實測：卷題下方渲染成 `布施度無極[2]章第[3]一（([4]此有[5]一十章)）`；離線版是 `（此有一十章）`。
- 守則：夾注跨 `lb` 時「本行補右括號、次行以左括號續接」，括號必須成對，且小字範圍 `inlineNotes` 的 offset 要跟著減掉前導空白（`flushLine()` 裡的 `leadingWhitespace` 位移修正）。索引端 `inlineNotes` 區間要跳過，否則無標點正文會與注文黏成新詞。

### C-10 行號沒有底線的寫法
例：`T54n2133Ap1190a13`（梵語千字文類，行號與 `p` 之間無 `_`）
- 守則：`_joinedLineheadPattern` 統一補成 `..._p` 格式，與搜尋 API／Goto 拼出的行號一致；引用與跳轉才可比對。改這裡要連同 `lib/search/passage_resolver.dart` 的 Goto 正则一起驗。

### C-11 星號校勘 `[＊]`（資料源差異，不是 bug）
- 實測：線上 T0001 `noteAnchor star` 35 筆、T0152 16 筆；離線 ZIP 兩者都是 **0 筆**。
- 守則：離線不補星號（启发式重建會產生假標記）；相關測試若用線上片段，不能斷言離線也過。

### C-12 異體字／特殊字（三种寫法都要留字）
| 寫法 | 出处 | 现況 |
|---|---|---|
| `<a class='gaijiAnchor' href='#CB02425'>𥥧</a>` | 線上 T0152（13 筆，含 `gaijiInfo`） | 走通用分支，保留字元（不是 `noteAnchor`，不會被跳過） |
| `<span class="gaiji" data-gid="CB00416">箒</span>` | 離線 T0152（3 筆） | 走通用分支，保留字元 |
| `class="siddam"`／`class="ranjana"`（`char=`＋`code=`） | 悉曇／蘭札字，走 `scriptRuns` 換字體 | ⚠️ **T0001／T0152 兩卷裡 0 筆**，本樣本集沒有真資料佐證 → 待補樣本 |

### C-13 空行與前導行對位移的污染
- 實測：解析會產出 `text=''` 的行（例如 T0152 離線卷第 4 行、線上卷多處），它們仍進 `lineStarts`／`buildScriptureTextLayout`，會拿一個空區塊。
- 前導 `No. 152` 行：正文要顯示（淡色小字），但索引要排除（`_leadingNumberPattern` + `!seenVolumeTitle`），否則 `cf.` 引用會污染正文結果。

### C-14 表格／圖片（**本樣本集尚未涵蓋**）
- 現況：`tableCellText()` **不會**跳過 `noteAnchor` 子節點文字 → 若離線表格內也有 `<a…>[n]</a>`，會與渲染端插入的標記疊成 `[n][n]`。
- 待辦：T0001／T0152 兩卷內 `<table>`／`<tr>`／`bip-table` 都是 0 筆，需另取一部帶表格的經（儀軌類）補一張 C-14，並同時存線上／離線兩份。

### C-15 偈頌與悉曇字體的已知限制
- 偈頌以 `WidgetSpan`/純文字拼接呈現，**不套** Siddam/Ranjana 字體（`lib/reader/feature_logic.md` 記為已知限制）；表格內文字也不進純文字位移系統，改用 `highlightedWidget` 字串比對高亮。

### C-16 下載器改寫後，段落內部的行錨點吞掉段落 role（**這條才是使用者看到的「作譯者不靠右」**）
原始 ZIP／`download/html/T0152_001.html` p.1a5（離線）—
```html
<p class="byline"><span class='lineInfo' line='0001a05'></span>吳<a id='note_anchor_0001001' class='noteAnchor' href='#n0001001'>[1]</a>康居國沙門康僧會譯</p>
```
經 `normalizeArchiveHtml()`（`lib/download/work_archive.dart:102`）存進離線 store 後變成 —
```html
<p class="byline"><span class="lb" id="T03n0152_p0001a05">T03n0152_p0001a05</span>吳…</p>
```
- 干擾源：`parser.dart` 的 `visit()` 看到 `class="lb"` 會先 `flushLine()`。這一次 flush **沒有產出任何行**
  （`linehead==null` 且 `text` 空），卻連 `lineRole`／`headingLevel`／`paragraphEnd` 一起重置，
  於是 `<p class="byline">` 的判定被丟棄 → 離線經卷的作譯者變成普通正文行。卷題、`data-head-level` 同理受害。
- 實測（修之前，餵「真 ZIP 內容過 `normalizeArchiveHtml()`」的形態）：
  `role=regular lh=T03n0152_p0001a05`，渲染 `left=59.7`／`color=#2C1810`／`size=19` → **靠左、黑色、字同正文**。
- 為什麼之前測不到：線上 `/stable/juans` 的 `lb` 在段落**之間**，走的是另一條分支；合成測試用的
  `<p class="byline">` 裡面沒有錨點。**測離線形態必須先過 `normalizeArchiveHtml()`**，不能直接餵 ZIP 原文。
- 現況：`flushLine()` 用 `emittedLine` 判定，只在真的產生了行時才重置行屬性；
  回归測試＝解析層 `keeps the paragraph role when a line anchor heads the paragraph`
  ＋渲染層 `styles the byline of a downloaded volume`（後者走 store 裡的離線形態，斷言行尾≈段寬、`#8C7B66`、`0.8×`）。
- 修後實測（同一份真檔案 normalized 後）：`byline(吳康居國沙門康僧會譯)` caret `left=508.08 → right=648.0`（=段寬）、
  `#8C7B66`／15.2px；卷末尾題 `mid=324.0`（=648/2）置中綠色。
- ⚠️ 改 `normalizeArchiveHtml()` 的替換規則（例如改成段落外的錨點、或不再壓掉 `>\s*\n\s*<`）會直接改變
  `flushLine()` 的命中順序，兩端規則要一起驗。

### C-17 靠右／置中的補齊留白把最後幾個字擠到下一行（**「譯者名字沒螢幕寬卻換行」**）
- 現象：離線經卷的作譯者已經靠右了，但像「吳康居國沙門康僧會譯」這種明明比行寬短的字串，
  最後幾個字仍掉到下一行。
- 干擾源：`interactivePassageText()` 對齊的做法是塞一個不可見 `WidgetSpan(child: SizedBox(width: pad))`，
  `pad = width − TextPainter.width`，**恰好把整行塞滿**（實測 `width=288.0`、文字 `155.67`、`pad=132.33`，
  加總 `288.00`＝零餘量）。placeholder 寬度進排版引擎後不再等於傳進去的小數，
  只要往上進到下一個設備像素，行寬就被超出；CJK 每個字都是斷行點，於是斷在最後幾個字。
- 手上的 APK 已經含「向下取整＋内在寬度校正」還是掉字（2026-11-02 使用者實測），代表手機上的殘差比 1 個設備像素大，
  而測試環境（Skia、沒有 App 自帶字型）量不到那個差。所以修法不再**猜誤差大小**，改成直接問排版引擎。
- 復現（把取整方向改成 `ceil`，其餘不動）：`surface=320×1200`（可行寬 288）、`font=32`、`dpr=1.0` →
  caret 首字 `top=137.36`、末字 `top=186.36`，`lastLeft` 退回 `26.55`＝**換行**。
  同一份資料用「向下取整＋驗證迴圈」：`sameLine=true`、末字 `left≈287.5`，仍然貼住右緣。
  `dpr=1/2/2.75/3` 與 `font=19/26/32` 的組合裡，`ceil` 版本 12 個案例有 10 個換行。
- 現況：留白先**向下**取整到設備像素（`step = 1/devicePixelRatio`），然後用 **`RenderParagraph` 自己那條排版路徑**
  （`TextPainter`＋`setPlaceholderDimensions`＋`layout(maxWidth: width)`＋`maxLines: 1`）問一次「會不會換行」，
  會換行就按 1、2、4、8… 個設備像素一步步收回留白（最多 6 次），收到 0 仍換行代表文字本身放不下、退回自然換行。
  兩個 `TextPainter` 都要先過 `displayInlineSpan()`：渲染端在 `interactivePassageText` 之後還會做一次簡繁轉換，
  量的必須是最後畫出來的那份文字。
  - 代價：留白可能比理論最大值小幾個設備像素（視覺上仍在右緣），換來的是「不會掉字」。
  - 實測：把取整故意改成 `ceil`（原本 12 例換行 10 例）配上這條驗證迴圈 → **全部不換行**；
    再人為把留白多塞 4px → 仍不換行，但置中卷題偏移 4.6px（迴圈只能犧牲對齊精度，不能救「量少了」）。
- 回归測試＝`test/widget_test.dart --name 'styles the byline of a downloaded volume'` 的兩段：
  800px 視窗斷言行尾≈段寬／`#8C7B66`／`0.8×`；窄畫面（320×1200、可行寬 288）＋`fontSize: 32`＋`dpr 1.0`
  斷言作譯者首字與末字 `top` 相同（不掉行）且末字 `left ≈ 288`。
  ⛔ 不要把補齊留白改回「剛好等於剩餘寬」，也不要拿掉那道「會不會換行」的驗證；
  把容差放寬前先看第一段的 `closeTo(width, 1.5)`，它盯的就是留白有沒有多收過頭。
- 同源風險：卷題置中用 `spareWidth / 2`，本來就有餘量，但仍走同一段取整邏輯；
  動它會同時影響 C-01/C-04 的置中斷言（容差 1.5px，取整誤差 ≤0.5px 才算安全）。

---

### C-18 逐字 token span 在解析前整對移除（記憶體與速度）

線上 `/stable/juans` 把正文切成 token（離線 ZIP 沒有這層）：

```html
<span class="t" l="0001a03" w="1">六度集經</span><span class="pc">，</span>
<span class="line_space">　</span>
```

- 實測（B0170 卷3，5.58M 字元）：`<span>` 共 137,780 個，其中 `pc` 89,033、`t` 24,412；
  `parseFragment` 建出的 DOM 讓單卷解析峰值 `210MB`、耗時 `543ms`（AOT 桌面）。
- 現況：`parser.dart` 的 `_stripInlineTokenSpans()` 在 `parseFragment` 前，把
  **有 class 且不含語意 class**（`lb`／`lineInfo`／`siddam`／`ranjana`／
  `inline-note`／`doube-line-note`／`footnote`）的 `<span>` 開閉標籤整對移除；
  同一卷變成 `97MB`、`157ms`，解析結果逐欄相同。
- ⚠️ **沒有 class 的 span 一律保留**：`<span style="margin-left:1em"><p class="form">…</p></span>`
  是真的存在的寫法（X0223 卷54）。拿掉它會改變 `hasFollowingParagraph()` 看到的兄弟節點，
  實測 `paragraphEnd` 由 false 變 true → 排版多空行。
- ⚠️ 必須用堆疊配對整對刪除，不能只刪開標籤：`inline-note` 裡常有 `span.t`，
  留著的 `</span>` 會提前關掉外層 span，夾注範圍與括號位置就錯了（C-09）。
- 驗證：399 份真實卷（最大 50 份＋均勻抽樣）用「原字串 vs 移除後」比對
  `role`／`headingLevel`／`paragraphEnd`／`linehead`／`text`／`footnotes`／
  `inlineNotes`／`scriptRuns` 全等；回歸在 `test/scripture_render_test.dart`
  （`inline token spans do not change the parsed volume`、
  `keeps spans without a class so block nesting stays intact`）。
- 保護的 bug：低端機線上閱讀時單卷就把 Dart heap 推高數百 MB，換卷後 GC 追不上，
  `dumpsys meminfo` 的 Native Heap 隨卷數一路上升。改這裡不要只按 class 名稱前綴判斷，
  也不要把沒有 class 的 span 一起拿掉。

---

## 3. 用這份文件批量測試

### 3.1 每次改動後的最小驗證組合
```bash
dart analyze lib test
dart format lib test
flutter test test/scripture_render_test.dart                       # 解析／layout／尾題降級斷言
flutter test test/widget_test.dart --name 'reader shows the volume title'   # C-01/C-03/C-06：卷題置中＋作譯者在正文原位（靠右、0.8×、淡色）
flutter test test/widget_test.dart --name 'reader centers the title repeated' # C-04：卷末尾題同樣置中＋綠色
flutter test test/widget_test.dart --name 'byline'            # C-02/C-06：作譯者標記只出現一次
flutter test test/widget_test.dart --name 'styles the byline of a downloaded volume' # C-16：離線形態（過 normalizeArchiveHtml）也靠右小字淡色；C-17：窄畫面＋32px 作譯者不換行
flutter test test/widget_test.dart --name 'repeated hits'           # 卷名兩筆命中各自定位、只高亮一次
flutter test test/widget_test.dart --name 'reader jumps to the exact offline source offset' # 離線位移就是整卷位移（無頁首補丁）
flutter test test/sidx_test.dart                                   # 索引跳過／邊界（卷題、卷末尾題、作譯者、夾注）
flutter test test/offline_scan_test.dart                            # 離線位移與 layout 一致
```
> 已知**與本樣本集無關**的舊失敗：`test/widget_test.dart --name 'online search keeps loading batches while scrolling'`
> 在 `HEAD`（`git archive HEAD` 乾淨副本）也重現失敗（`Found 0 widgets with text containing 第二批經`），
> 不要為了它改渲染代碼，也不要把它當成回归。

### 3.2 真資料核對（改樣式／排版時至少跑一次，兩份資料源都要）
```bash
# 1) 線上：/stable/juans（逐行 lb、逐字 token、空 noteAnchor）
curl -s "https://cbdata.dila.edu.tw/stable/juans?work=T0152&juan=1" \
  | python3 -c "import json,sys;open('/tmp/t0152_online.html','w').write(json.load(sys.stdin)['results'][0])"
# 2) 離線 ZIP：download/html（裸文字、段落級 lineInfo、noteAnchor 內含可見 [n]）
curl -s -o /tmp/T0152.zip "https://cbdata.dila.edu.tw/stable/download/html/T0152.html.zip" \
  && mkdir -p /tmp/t0152 && unzip -o /tmp/T0152.zip -d /tmp/t0152
```
把 HTML 丟給 `parseScriptureHtml()` 印出每行的 `role`／`headingLevel`／`linehead`／`footnotes`，
再用 widget 測試（`flutter test`，**不能**用 `dart run`：`reader_layout.dart` 需要 Flutter VM）
印出卷題／作譯者的 caret 左右緣。本輪實測基準：
- T0152 線上：`六度集經卷第一@9` mid=324.0（卷首）、`@787` mid=324.0（卷末 p.6a20）；作譯者片段 caret 508.08→585.92，`#8C7B66`／15.2px。
- T0152 離線 ZIP：卷首 `@12` mid=324.0、卷末 `@514` mid=324.0。
- T0001 離線卷1：`byline(長安釋僧肇述)` → `volumeTitle(佛說長阿含經卷第一)` → `byline(後秦弘始年佛陀耶舍共竺佛念譯)` → `volumeTailTitle(同名)`；`layout.text` 內**不含** `[6][6]`，且仍含「如鳥遊虛空」。
- 測離線形態時，**先過 `normalizeArchiveHtml(raw, 'T03n0152')` 再喂 `parseScriptureHtml()`**（store 裡存的就是改寫後的內容）；
  直接餵 ZIP 原文會得到 `role=byline` 的假好消息（C-16）。
- 探測離線路徑時用環境變數（`--dart-define` 在 `flutter test` 下不會進 `ScriptureVolumeStore` 判定）：`OFFLINE=1 flutter test …`。
- widget 測試裡一定要裝**記憶體版** `ScriptureVolumeStore`：真的 store 走 `path_provider` platform channel，在 fake async 下會卡死且**不發 HTTP 請求**（症狀是 spinner 一直轉／`pumpAndSettle timed out`）。

### 3.3 建議落地成「真資料黃金測試」（這才是「批量」的重點）
1. 存樣本：`test/fixtures/html/T0001_001.online.html`、`T0001_001.archive.html`、
   `T0152_001.online.html`、`T0152_001.archive.html`（由第 1 節的 curl 取得，逐字不動）。
2. 新增 `test/html_conflict_cases_test.dart`：把上面每張卡片的 **HTML 片段**寫成 table-driven 資料，
   每案斷言三件事：
   - 解析層：`role` / `headingLevel` / `linehead` / `footnotes(label,offset,verseCellIndex)` / `inlineNotes` / `scriptRuns`；
   - layout 層：`buildScriptureTextLayout(...).text` 含不含金字元（標記只出現一次、行距、置中 placeholder `\n\uFFFC`）；
   - 渲染層：`interactivePassageText` 的 span 樹裡該行有／沒有 `color`、`fontSize`，以及 caret 的左右緣（置中或靠右要**量實圖位置**，不能只驗 span 結構）。
3. 每案都要有 online／archive **兩份輸入**跑同一組斷言；兩份結果不同時（例如 C-11 星號），
   在卡片裡明確寫「離線預期為 0」，不要讓測試去遷就單一資料源。
4. `tool/` 下留一支可印出各卡片解析結果的腳本（只依賴 `package:xuefo/scripture/parser.dart`，
   用 `dart run` 跑；注意 `reader_layout.dart` 依賴 Flutter，不能進 `dart run` 腳本，只能進 widget 測試）；
   腳本是暫用探測器，跑完刪掉，不要留在 repo。

### 3.4 新增案例的規則
一張卡片必須齊備：① 逐字 HTML（保留單／雙引號原樣）② 出處（作品、卷、行號、CBETA 版本）
③ 當今實測結果 ④ 期望 ⑤ 它保護的歷史 bug（附 commit）⑥ 改了會壞什麼。
缺 ⑤⑥ 的卡片沒有價值——這裡的所有衝突都是「修 A 壞 B」留下的。

---

## 4. 未決項目（下次碰 HTML 解析時先清掉）
- C-14：帶表格的經（`<table>`／`bip-table-row`）在離線 ZIP 下的標記重複風險，沒有樣本。
- C-12：悉曇／蘭札 `siddam`/`ranjana` 的真資料片段（`char=`＋`code=`）未入庫，目前只有代碼與測試合成資料。
- 兩套資料源的 class 形態**尚未**觀察到 `div.byline`／標記挂在子節點上的寫法：
  T0152（線上＋ZIP）、T0001（23 筆 byline／44 筆 juan）、T0220（616／1198）全部是
  `<p class="byline">` 與 `<p class='juan'>`，所以原本計畫的「解析容錯（class 打在子節點也認）」已**取消**。
  若將來遇到別的寫法，再開一張卡片並補真資料樣本，不要提前加寬鬆匹配。
- `.sidx` 角色相容性：`ScriptureLineRole.values` 的下標被寫進離線索引（uint16），
  `navigationAnchor` 現在**不再由解析器產生**（卷末尾題改用 `volumeTailTitle`），
  但列舉值必須留著，舊離線包的 `role=3` 才不會錯位或拋出範圍錯誤。
