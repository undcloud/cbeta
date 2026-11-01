# dictionary 模块说明

> 最后核对：`lib/dictionary/dictionary_sticky_headers.dart`（服务层
> `fodict_service.dart`、key 索引 `fodict_key_index.dart`、目录
> `fodict_catalog.dart`、下载 `fodict_download_manager.dart`、旧页
> `dictionary_page.dart`）。

## dictionary_sticky_headers.dart

两个词典吸顶头 widget（原先位于 `main.dart`）：

- `DictionaryStickyHeader`：「選擇佛經 → 詞典」tab 内当前词条的吸顶显示；
- `HomepageDictionaryStickyHeader`：首页搜索框下方的词条速览区
  （随滚动折叠，delegate 为 `HomepageDictionaryHeaderDelegate`）；
- `cleanFodictDefinition`：去掉词条定义中的 `<br>`、括注等噪声；
  `fodictDefinitionSnippet`：截断为速览长度（默认 80 字）。

两者都通过 `dictionary/fodict_service.dart` 读取已下载词库，显示经
`displayText` 跟随简繁设定。

## fodict_key_index.dart：词典 key 索引

搜索框候选面板要显示 `字典 N`（每个候选在词典 key 里的命中条数，见
`lib/search/feature_logic.md` 9.2）。这件事只需要 key，不需要释义，
所以单独一层：

- **计数语义**：单位是**条目**，同一术语被两部词典各收一次算 2 笔。
  早期实现用 `Set` 合并所有词典的 key 做跨词典去重，那是实现的副作用
  而不是需求（无文档、无测试），去掉之后统计就不必物化整批 key 并集。
- **三份缓存，由便宜到昂贵**：内存 `FodictKeyIndex` →
  `<词典目录>/_keys/<id>.keys` sidecar → 解析 `.dat` 重建。
  `_loadKeyIndex` 依这个顺序走；只有最后一条路才碰 `.dat`。
- **不共用语义缓存**：释义仍走 `FodictService._cache`（LRU 只有 2 条）。
  两边分开前，统计要扫全部词典，会把字典分区刚读进来的正文全部挤出 LRU，
  于是下一次搜索两边都在重解析同一批 `.dat`（冷启动的主要成本）。
  key 很小（实测 9 部词典的 sidecar 共 1.8 MB，只占 `.dat` 的 3%），
  所以 key 索引不设上限。
- **`.keys` 格式**：标头 24 B（magic `FODK`、格式版本、条目数、blob 长度、
  来源戳记）+ 位移表（条目数 + 1 个 u32）+ UTF-8 key blob。用位移表而不是
  分隔符，是因为全文式词典的 key 允许含换行。读回时校验戳记、blob 长度、
  位移单调与 UTF-8 完整性，任何一项不符就回传 null 去重建。
  `.dat` 才是真相源，`.keys` 可随时删。
- **新鲜度**：`fodictSourceStamp` = 「大小 × 黄金比例常数 + 修改时间」的低 32 位，
  与经卷索引 `sidxSourceStamp` 同一手法，一次 `stat` 就够；注意 `File.stat()`
  对不存在的文件不抛异常，要按 `type` 判。内建 030 的 `.dat` 在 `assets/` 里
  既不可写也删不掉，直接用打包长度当戳记（随 APK 固定）。
- **解析规则不能分叉**：`parseFodictKeys` 与整本解析 `parseFodictData` 共用
  `_parseFodictEntries`。全文式词典（011／018 那类）的 key 是从正文句读切出来、
  同名还会延长截断位置的，规则一旦分叉，`字典 N` 就会和字典分区的结果互相对不上。
  分开的意义只在于不必把十余 MB 释义跨 isolate 复制回来。
- **孤儿回收**：sidecar 统一放 `<baseDir>/_keys/`，词典目录被
  `deleteInstalled` 整包删除时它不会跟着走，所以 `getDictionaries` 重新列目录时
  按当前已安装 id 清一次。`_keys` 这个名字不是合法词典 id
  （首字符要求字母数字），服务层与下载管理器的目录扫描都会忽略它。
- **实测耗时**（9 部词典、去重后 75302 条 key，本机 `flutter test` 环境）：
  改写前「整本解析 + 并集 + 小写化」435 ms、每次扫描 10 ms；
  改写后首次建 sidecar 278 ms、App 重启后 30 ms、同进程重复统计 12 ms。
- 测试计数：`debugFodictKeyParses`（真的解析过几次 `.dat`）与
  `debugFodictFullDictionaryLoads`（载入过几次含释义的整本），
  由 `test/fodict_key_index_test.dart` 用来钉住「统计不读正文、sidecar 命中不再解析」。
## 注意

- `dictionary_page.dart` 的 `DictionarySearchPage` 是无引用的旧页面，
  现行词典入口是「選擇佛經 → 詞典」；
- 词库文件较大，勿在 widget 测试里同步加载（资产加载约定见根 AGENTS.md）。
- 单元测试要收窄范围时传 `dictionaryIds`，否则 `getDictionaries` 会连内建 030
  一起列出（枚举时要 `rootBundle.load` 那份 5.8 MB 资产以取长度）。
