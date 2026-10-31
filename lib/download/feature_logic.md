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

## 注意

- 面板销毁时经 `onDisposed` 重置单例标记；
- 通知与角标遵循「无常驻闪爖动画」惯例，进度变化靠 `AnimatedBuilder`
  监听 manager notifier。
