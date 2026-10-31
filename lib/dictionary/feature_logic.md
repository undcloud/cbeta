# dictionary 模块说明

> 最后核对：`lib/dictionary/dictionary_sticky_headers.dart`（服务层
> `fodict_service.dart`、目录 `fodict_catalog.dart`、下载
> `fodict_download_manager.dart`、旧页 `dictionary_page.dart`）。

## dictionary_sticky_headers.dart

两个词典吸顶头 widget（原先位于 `main.dart`）：

- `DictionaryStickyHeader`：「選擇佛經 → 詞典」tab 内当前词条的吸顶显示；
- `HomepageDictionaryStickyHeader`：首页搜索框下方的词条速览区
  （随滚动折叠，delegate 为 `HomepageDictionaryHeaderDelegate`）；
- `cleanFodictDefinition`：去掉词条定义中的 `<br>`、括注等噪声；
  `fodictDefinitionSnippet`：截断为速览长度（默认 80 字）。

两者都通过 `dictionary/fodict_service.dart` 读取已下载词库，显示经
`displayText` 跟随简繁设定。

## 注意

- `dictionary_page.dart` 的 `DictionarySearchPage` 是无引用的旧页面，
  现行词典入口是「選擇佛經 → 詞典」；
- 词库文件较大，勿在 widget 测试里同步加载（资产加载约定见根 AGENTS.md）。
