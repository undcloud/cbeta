# app_update 模块说明

> 最后核对：`lib/app_update/app_update.dart`。

## 职责

APK 自更新：从 Gitee Release（`undclouds/cbeta`）检查新版本、下载、
请求安装权限并拉起安装器。

## 关键 API

- `fetchLatestGiteeRelease()`：读 Gitee `latest` API，返回 `AppUpdateInfo`
  （版本号、按 ABI 匹配的附件直链 `_giteeLatestDownloadBase`，
  `deviceAbis()` 决定优先 arm64 等）；
- `isNewerVersion(latest, current)`：版本比较，支持 `v1.2.3`、`1.0.0+4`，缺段视为 0；
- `downloadUpdateApk(onProgress)`：下载到临时目录并回报 0.0–1.0 进度；
- `launchApkInstaller(path)`：MethodChannel `xuefo/app_updater`（PackageInstaller +
  FileProvider）→ 失败退回 `open_filex`；缺权限时抛
  `InstallPermissionRequiredException`，由调用方弹 `InstallPermissionAction`
  三选对话框（取消／去設定／繼續），`openInstallPermissionSettings()` 跳系统授权页；
- `UpdateProgressDialog`：下载进度对话框。

## 状态与持久化

- SharedPreferences key：`pending_update_apk_path`、`pending_update_version`
  （安装被中断后下次启动补拉起，由 `main.dart` 消费）——**保留旧 key，不要改名**。

## 调用方

首页 `home/home_page.dart` 负责检查更新时机与「立即更新」流程；
`SettingsButton` 的更新角标数据也来自首页。
