# ai 模块说明

> 最后核对：`lib/ai/ai_search_page.dart`（网络层 `ai_search_service.dart`、
> 模型 `ai_chunk.dart`）。

## ai_search_page.dart

`AiSearchPage(initialQuery)`：AI 语意搜索独立页面。

- 输入复用 `search/search_input.dart` 的共享输入框；
- 流程：`AiSearchService.search` 取回 `AiChunk` 列表（附相关经文与出处）
  → 流式生成答案（`retrieving`/`generating` 两阶段）；
- `_requestToken` 竞态防护：新请求使旧响应失效，`dispose` 时 `aiService.cancel()`；
- 点击 chunk 出处跳 `reader/ScriptureReaderPage`；
- 显示文案走 `displayText` / 自定义 `Text`，跟随简繁设定。

## 已知事项

- 服务地址与请求头见 `cbeta_api_headers.dart`；
- 相关测试：`test/ai_service_test.dart`（网络层 mock），页面级交互在
  `test/widget_test.dart`。
