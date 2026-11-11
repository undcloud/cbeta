# mirror 全量镜像说明

> 最后核对：`lib/mirror/`（服务器端见仓库 `server/`）。

## 职责

从自架 ECS 镜像（`/cbeta/html_full.zip`，内含全部 CBETA 作品的
`<WORK>.html.zip`）一次性下载并导入全部经卷，作为 CBETA 逐部下载的
替代路径；CBETA 逐部下载/更新仍保留并作为默认回退。

## 文件

- `mirror_config.dart`：Gitee `config/mirror_server.json` + 24h
  SharedPreferences 缓存；`loadCached()` 启动时无网读取，`load()` 强制刷新。
- `mirror_identity.dart`：持久化随机 device id（`mirror_device_id`）与
  每次导入的 session id，用于服务器按设备限流与去重统计。
- `mirror_models.dart`：`MirrorProbe`（HEAD 结果）、`MirrorLocalState`
  （prefs `mirror_local_state`）、导入阶段/进度与字节格式化。
- `mirror_service.dart`：HEAD 探测与断点续传下载（`Range` + 引号化
  `If-Range`、200 重启、416/429/503 处理、90s 无数据超时）。
- `mirror_storage.dart`：MethodChannel `xuefo/mirror_storage`，负责私有
  临时目录、剩余空间、MediaStore 导出 `Download/Fodian`、公有 ZIP 回拷。
- `mirror_stats.dart`：尽力上报 `start` / `download_complete` /
  `import_complete` / `failed` 到服务器 SQLite。
- `mirror_importer.dart`：单例 `mirrorImporter`，编排探测 → 续传下载 →
  流式解压 → 批量导入 → 导出 ZIP → 保存本地状态。

## 导入流程

1. `start({force})`：CBETA 下载/更新进行中则拒绝；刷新配置并 HEAD 探测。
2. `MirrorLocalState.matchesProbe`：先比 ETag+size，再比 release，最后比
   size；已是最新则直接返回。
3. 检查剩余空间（`probe.size * 5`，覆盖私有 ZIP + 解压 HTML）。
4. `_prepareZip`：优先复用私有 ZIP；否则尝试从公有
   `Download/Fodian` 回拷；最后才断点续传下载。503 人数满、429 重下过频
   会读 `Retry-After` 退避重试。
5. `_importZip`：`InputFileStream` + `ZipDecoder().decodeStream` 流式读外层
   ZIP，逐 `<WORK>.html.zip` 读入内存并 `clear()`；每 12 部或 8 MB 交给
   `Isolate.run` 解压/规范化，再 `downloadManager.importVolumes(...,
   persist:false, flushIndex:false)`；每 48 部 `flushImportProgress()`，
   避免 `versions.json` 的 O(n²) 重写。
6. 导入结束统一 `flushImportProgress()`、`offlineIndexQueue.flush()`、
   `indexUpdateService.requestUpdate()`，随后把私有 ZIP 导出到公有目录
   并删除私有副本，最后上报 `import_complete`。

## 入口与状态

- `work_picker/work_picker_page.dart`：在部类、册别、作译者、年代、经目
  等入口点击下载图标时都会弹窗，让用户选择「CBETA 按部」或
  「一鍵下載全部」；CBETA 进入原来的勾选流程，镜像则立即下载全部佛典，
  与勾选数量无关。镜像不可用或已是最新时，「一鍵下載全部」置灰并给出
  原因；取消弹窗不会启动任何下载。
- `download/download_status_ui.dart`：CBETA 与镜像互斥，面板只保留一个
  「經文下載」进度区，共用暂停/继续按钮与进度条；镜像模式按下载字节
  或解压作品数显示进度，完成后在空闲状态显示全量镜像版本、卷数与 ZIP
  位置。导入期间禁用经目更新与 CBETA 续传。
- `main.dart`：启动 `initialize()`；`indexUpdateService.isBusy` 与
  `indexUpdateNotification.otherTaskActive` 纳入 `mirrorImporter.isImporting`。

## 约束

- 不申请存储权限：Android 10+ 用 MediaStore，旧版用应用私有外部目录；
  需要额外导出时走 SAF。
- 明文 HTTP 依赖 `AndroidManifest.xml` 的 `usesCleartextTraffic="true"`。
- 服务器单进程 gthread，内存中的令牌桶与并发计数因此全局有效（默认
  300 KB/s、全局 2、单 IP 2、单设备 1、10 分钟内最多 3 次全新开始）。
- 私有 ZIP 与公有 ZIP 的版本以 `MirrorLocalState` 与逐卷
  `LocalVersion.release` 记录，不依赖服务器 manifest。
