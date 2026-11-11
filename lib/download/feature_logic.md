# download 状态面板 UI 说明

> 最后核对：`lib/download/download_status_ui.dart`（下载逻辑本体见本目录
> `download_manager.dart` 等）。

## 职责

「下載管理」弹层与其入口按钮——把 `DownloadManager` 的进度状态可视化。

## 关键成员

- `showDownloadStatusPanel(context)`：全屏弹层；`_downloadStatusPanelOpen`
  全局单例标记，重复调用不会叠两层；
- `showOfflineDataManager(context)`：通过 `common/app_nav.dart` 的
  `navigatorKey` 取 rootContext 再打开面板（通知栏入口用）；
- `DownloadInfoButton`：首页工具栏图标，监听各下载 manager，
  进行中闪烁，点击打开面板；
- `DownloadStatusPanel`：CBETA 与镜像两种方式互斥，共用同一个
  「經文下載」进度区（暂停/继续/进度条）；CBETA 显示部/卷与当前经卷，
  镜像按下载字节或解压作品数显示，完成后显示镜像版本与 ZIP 位置。
  `formatDownloadBytes` 供各处格式化字节。
- 下载任务失败时显示失败作品编号，便于区分 CBETA 数据服务未提供的作品。
- 面板底部（非网页版）有「搜尋索引（除錯）」：清除索引只删派生档
  `cbeta_sidx/`（经卷 `.json` 不动），重建是逐卷增量重建，用来量测索引
  效果而不必重新下载经文；由 `searchIndexDebugEntriesVisible` 控制显隐，
  调试结束后改成 `false` 即隐藏。
- 面板会显示 `IndexUpdateService` 的背景「搜尋索引更新」进度（准备中／
  重建中／完成／失败）。APP 升级后若代码索引版本高于本机
  `cbeta_sidx_index_version`，启动时会自动在背景重建；下載或經文更新
  进行中时暂停，两者结束后再继续。

## 注意

- 面板销毁时经 `onDisposed` 重置单例标记；
- 通知与角标遵循「无常驻闪爖动画」惯例，进度变化靠 `AnimatedBuilder`
  监听 manager notifier。
- 每卷经文写完（`_storeVolume`）就把索引建置工作交给
  `offlineIndexQueue`，下载/更新结束前 `flush()`；`.json` 仍是真相源，
  写档会让旧段记录因戳记不符而失效，由队列在背景追加新记录。首次离线
  搜索因此不再承担两万多卷的建索引成本。
- 背景索引重建与下载/更新共用段锁，不会互相破坏；但重建会在每批（64 卷）
  前检查 `DownloadManager`／`UpdateManager`，有下载或更新时先暂缓，避免
  抢 worker 与拖慢用户主动发起的下载。
- 索引重建进行中时，`scripture/index_update_notification.dart` 会沿用下载
  同一个前景服务显示「正在更新搜尋索引」，让 App 退到背景后进程较不易被
  回收；下载或经文更新正在使用通知时它完全不插手，避免互相覆盖或提早
  停掉前景服务。返回键改为 `moveTaskToBack`（见 `lib/home/feature_logic.md`），
  不会销毁 Activity，任务可在背景继续。
- 除錯「清除索引」不会重設版本標記；清空後由第一次搜尋逐卷補回，或按
  「重建索引」完整重建並寫回目前版本。
- 离线经文下载及内容更新优先使用每部作品一个压缩档，只有压缩档缺卷时才
  回退逐卷 API，避免对 CBETA 服务批量发起大量请求。压缩档内容可能落后于
  网页 `/stable/juans` 数据（例如 T0001 的卷题行标及 `star` 校勘锚点）；
  这是已知离线/网页差异，不要为追平网页而改成全量逐卷请求。

### 卷號以壓縮檔為準

- 經目標題只提供「卷數」（`(N卷)`），`CatalogCache._juanList()` 因此只能推定
  `1..N`；但有 80 部作品沿用原書卷次（例如 `D8679` 標題 1 卷、壓縮檔是第 4 卷，
  `B0088` 標題 158 卷、實際卷號 55–212）。
- `DownloadManager` 下載完整部壓縮檔後，會用壓縮檔檔名解析出的真實卷號覆寫
  該作品的預期卷號，並持久化到 `DownloadStore` 的 `work_juans.json`；完成判定、
  待下載卷數與部分下載統計都以這份真實卷號為準。
- 真實卷號不在 `1..N` 內也能下載完成；逐卷 API 只補壓縮檔缺少的真實卷，
  不再對不存在的 `1..N` 卷號反覆請求。
- 尚未下載過的作品仍先用 `1..N` 粗估，第一次下載成功後即校正並保存。
- 壓縮檔下載改用「連續 90 秒沒有資料」判定斷線，不再限制整體時長；
  B0088（3.98 MB）在 23 KB/s 線路約需 173 秒，舊的整體 90 秒逾時會每次中斷。
- 壓縮檔失敗或回傳空包時，改用 `/stable/works/toc` 解析真實卷號再逐卷補齊，
  不會再對 `1..N` 的假卷號發請求。
- 統計口徑：`downloadedWorkCount` 是「至少一卷」的作品數；
  `completeWorkCount`（完整）與 `partialWorkCount`（部分）分開呈現，避免與
  未完成清單相加時重複計算部分下載作品（例如 4858 + 80 = 4938 的假象）。

### 經目更新（只差分清單，不猜測經文內容是否變動）

- 面板按鈕為「更新經目」，只刷新部類、冊別、作譯者、朝代四份清單
  （`CatalogUpdateService`），不再逐部請求 `/stable/changes`。
- 更新後以作品 id 做集合差分：新增的作品靜默下載，下架且本機曾下載的作品
  只寫入提示、不刪除本機經卷。
- 新增作品先 `HEAD` 一次 `html/<work>.html.zip`：404 代表 CBETA 沒有 HTML 版，
  記為「無 HTML 版」略過；其餘錯誤記為失敗並繼續下一部。差分只相信集合，
  作品在部類間移動不會被誤判成新增／下架。
- 舊經目為空時不做差分，避免把整份清單誤判成新增而觸發全藏下載。
- 下架提示保存在 `cbeta_orphaned_works`，使用者按「知道了」才清除。
- 新增作品下載失敗會記在 `cbeta_update_retry_works`；下次更新即使經目清單
  沒變，也會先重試這批作品，成功後自動移除記號。
- 更新任務 schema 升到 v2；舊版「重新檢查全部已下載作品」的任務會被丟棄，
  避免升級後重下既有經卷。
- 經文內容更新暫停：清單檔沒有逐部修改時間；ZIP 頁尾的「發行日期」是
  整包重蓋（所有作品同一月份），不能用來判斷單部是否修訂。`LocalVersion`
  仍記錄下載當下的 etag 與 release，等 CBETA 提供可靠時間來源再接內容更新。

### 搜尋索引的 dirty 記號

- 下載或經目更新寫入新經卷後呼叫 `IndexUpdateService.requestUpdate()`，
  持久化 `cbeta_sidx_dirty`。下次 `startIfNeeded()` 即使索引格式版本沒變，
  也會做一次逐卷增量核對（已符合戳記的卷會跳過），完成後由
  `markCurrentVersion()` 清除記號。
- 逐卷 `.sidx` 仍由 `offlineIndexQueue` 即時建立；dirty 標記只保證離線重啟後
  不會漏掉「格式版本未變但內容已新增」的情況。

### 数据源限制：`[＊]` 星号校勘

- 网页 `/stable/juans` 的 HTML 带 `<a class="noteAnchor star">`，阅读器会
  显示 `[＊]`；可下载 ZIP（`x2h_for_download.rb` 管线）与文本下载 ZIP 会把
  `<app type="star">` 整体去掉，因此离线经卷的对应位置（如 T01, no. 1,
  p. 2a17 / 2a21）没有星号，只有带正文的 `<note type="star">` 可能保留。
  这是数据源本身的差异，不是解析器丢字。
- 文本下载 ZIP 的差异**不在本 App 内修正**：不要改动该数据源，也不要按
  「疑似校勘位置」重建 `[＊]`。星号锚点没有可靠的行内定位，启发式补回会
  产生假标记；因此离线阅读、离线索引都只呈现压缩档实际带有的内容。
- 若以后需要离线星号，只能依赖 CBETA 在压缩档里补回 `<app type="star">`，
  或改走逐卷 `/stable/juans`；后者会批量请求 CBETA 服务，不采用。

### `normalizeArchiveHtml()` 會改寫離線 HTML 的存儲形態

下載器把壓縮檔內每一卷的 HTML 存進 `ScriptureVolumeStore` 之前做兩件事：

- `<span class='lineInfo' line='X'></span>` → `<span class="lb" id="<prefix>_pX">…</span>`，
  讓只有段落級錨點的離線檔案也能有行首標記與行號跳轉；
- 壓掉 `>\s*\n\s*<` 的標籤間空白，避免每個換行都變成多出來的空行。

副作用（改這裡要知道）：原本的 `lineInfo` 常常是 `<p class="byline">` 等段落的**第一個子節點**，
改寫後就變成段落內部的 `lb`；解析器遇到 `lb` 會先 `flushLine()`，
所以 `flushLine()` 必須只在「真的產生了行」時才重置 `role`／`headingLevel`／`paragraphEnd`，
否則離線經卷的卷題與作譯者會退化成普通正文行（靠左、黑色、字同正文）。
相關回歸：`test/scripture_render_test.dart` 的
`keeps the paragraph role when a line anchor heads the paragraph`、
`test/widget_test.dart` 的 `styles the byline of a downloaded volume`；
樣本與由來登記在 `test/html_conflict_cases.md` 的 C-16。
