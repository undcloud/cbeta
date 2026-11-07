# app_update 模块说明

> 最后核对：`lib/app_update/app_update.dart`。

## 职责

APK 自更新：从 Gitee Release（`undclouds/cbeta`）检查新版本、下载、
请求安装权限并拉起安装器。

## 关键 API

- `fetchLatestGiteeRelease()`：读 Gitee `latest` API，返回 `AppUpdateInfo`
  （版本号、按 ABI 匹配的附件直链 `_giteeLatestDownloadBase`，
  `deviceAbis()` 决定优先 arm64 等）；`releaseName` 与 `releaseNotes`
  直接来自 API 的 `name` / `body`（即 Release 描述，用于更新弹窗）；
- `releaseNotesForDisplay(raw)`：把 Release 描述的 Markdown（标题、粗体、
  链接、图片、行内代码、HTML）清成可直接显示的纯文字；
- `AppUpdateCheckResult` / `AppUpdateCheckStatus`：区分「有新版」「已最新」
  「检查失败」，供设置面板反馈按钮状态与提示；
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
- `auto_update_prompt_enabled`（默认 true）：启动自动更新提示开关。
  自动弹窗点「取消」后写 false，之后启动只静默检查、不再弹窗；
  手动完成一次更新（复用缓存 APK 或下载成功）后写回 true。
  对应 `loadAutoUpdatePromptEnabled()` / `saveAutoUpdatePromptEnabled()`。

## 调用方

首页 `home/home_page.dart` 负责检查更新时机与「立即更新」流程：
启动时检查一次（有新版自动弹窗，每次启动最多一次），
设置弹层底部按钮可随时手动复查（见 `settings/feature_logic.md`）。
