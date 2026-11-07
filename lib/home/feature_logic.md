# home 模块说明

> 最后核对：`lib/home/home_page.dart`。

## 职责

App 主页 `ScriptureSearchPage`（类名沿用历史，实为首页状态机）：
五个搜索入口的调度、结果渲染与路由。

## 主要状态与流程

- 输入框用共享的 `search/search_input.dart`（实时候选面板）；
  提交规则、候選不掃描本地經文等见 `lib/search/feature_logic.md`；
- 关键词搜索：调 `search/search_api.dart` 的 `fetchSearchBatch` 分页拉取，
  结果经 `widgets/result_widgets.dart` 分组渲染，滚动续传（`_SearchBatch` 语义见该文件）；
- 离线搜索：`search/passage_resolver.dart` 的 `searchOfflineCatalog` /
  `searchLocalCatalog` 扫本地经卷；
- Goto：仅首页判断，`resolveGotoPassage` 解析行号后直接开阅读器；
- 入口跳转：AI `ai/ai_search_page.dart`、经目/作译者
  `work_picker/work_picker_page.dart`（`showWorkPicker`）、
  词典头 `dictionary/dictionary_sticky_headers.dart`；
  注意「全文搜索」现行实现就是首页本身，`search/full_text_search_page.dart`
  为未被引用的旧页面（见 `lib/search/feature_logic.md`）；
- 书签与最近阅读：`reader/reader_store.dart` 的 `loadBookmarks` /
  `readingHistoryKey`，`HomeHistorySection` 分页展示；
- 自动更新：`app_update/app_update.dart`。启动时 `_checkForAppUpdate(promptIfAvailable: true)`
  检查一次；有新版本会在首帧后自动弹窗（每次启动最多一次），弹窗展示
  Gitee Release 描述清洗后的「更新內容」。自动弹窗点「取消」会持久关闭后续自动提示
  （`auto_update_prompt_enabled=false`），只能从设置手动检查/更新；手动更新成功
  下载一次后恢复自动提示。检查结果同时喂给 `SettingsButton`，设置弹层底部的
  更新按钮常显：有新版绿色、无新版灰色，可手动复查。
- Android 根页面返回键：不结束行程，改由 `PopScope` 调用
  `common/app_lifecycle.dart` 的 `moveTaskToBack()` 把整个 Task 退到背景；
  有搜尋結果時仍先清空搜尋。下載、經文更新、重建索引因此可繼續在背景執行。

## 注意

- 新增首页功能请放独立 widget/函数，不要再堆进 `home_page.dart`
  （拆分前它是 12k 行的 `main.dart`，勿重蹈覆辙）；
- 路由到阅读器统一 `MaterialPageRoute(builder: … ScriptureReaderPage …)`。
