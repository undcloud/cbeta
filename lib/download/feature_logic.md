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
- `DownloadInfoButton`：首页工具栏图标，监听 `downloadManager`，
  进行中显示进度角标，点击打开面板；
- `DownloadStatusPanel`：总体进度、当前经卷、暂停/继续/取消、
  完成后可跳转已下載經卷；`formatDownloadBytes` 供各处格式化字节。
- 下载任务失败时显示失败作品编号，便于区分 CBETA 数据服务未提供的作品。
- 面板底部（非网页版）有「搜尋索引（除錯）」：清除索引只删派生档
  `cbeta_sidx/`（经卷 `.json` 不动），重建是逐卷增量重建，用来量测索引
  效果而不必重新下载经文；由 `searchIndexDebugEntriesVisible` 控制显隐，
  调试结束后改成 `false` 即隐藏。

## 注意

- 面板销毁时经 `onDisposed` 重置单例标记；
- 通知与角标遵循「无常驻闪爖动画」惯例，进度变化靠 `AnimatedBuilder`
  监听 manager notifier。
- 每卷经文写完（`_storeVolume`）就把 `.sidx` 建置工作交给
  `offlineIndexQueue`，下载/更新结束前 `flush()`；`.json` 仍是真相源，
  写档会先删掉旧索引，由队列在背景重建。首次离线搜索因此不再承担
  两万多卷的建索引成本。
- 离线经文下载及内容更新优先使用每部作品一个压缩档，只有压缩档缺卷时才
  回退逐卷 API，避免对 CBETA 服务批量发起大量请求。压缩档内容可能落后于
  网页 `/stable/juans` 数据（例如 T0001 的卷题行标及 `star` 校勘锚点）；
  这是已知离线/网页差异，不要为追平网页而改成全量逐卷请求。

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
