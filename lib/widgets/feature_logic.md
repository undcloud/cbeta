# widgets 模块说明

> 最后核对：`lib/widgets/display_text.dart`、`lib/widgets/result_widgets.dart`。

## display_text.dart（重要约定）

- 自定义 `Text` / `Text.rich` 与 Flutter 的 `Text` **同名**。拆分前整个
  `main.dart` 靠顶层声明遮蔽 material 的 `Text`；拆分后所有使用裸 `Text(`
  的文件必须：
  1. `import 'package:flutter/material.dart' hide Text;`
  2. `import '../widgets/display_text.dart';`
- `displayText(text, [context])`：按 `scriptureDisplaySettings.showSimplifiedText`
  做简繁显示转换；`displayInlineSpan` 递归转换 span 树。自定义 `Text`
  内部即调用它们，因此**新增 UI 一律用本文件的 `Text`，不要用 material 的**，
  否则文字不跟随简繁设定。
- `DisplaySelectableText`：可选中版本，同样走显示转换。

## result_widgets.dart

搜索结果展示层的共享 widget，被首页、全文搜索、AI 搜索、阅读器复用：

- `HomeBrand`：品牌头（首页与阅读器顶栏）；
- `SearchField` / `SearchPrompt` / `NoResults`：搜索输入行、提示与空结果；
- `CatalogSearchMatch`：经目查询单条命中；
- `WorkStickyHeader` + `WorkStickyHeaderDelegate`：结果列表按作品分组的吸顶标题；
- `JuanResultGroup` / `PassageResultTile` / `SearchResultCard`：卷分组、段落条目与结果卡片；
- `resultWorkKey` / `groupResultsByWork`：把同一部作品跨卷的结果合并为一组
  （以 `T0001n0001` 形式的工作 id 分组，见 `common/text_patterns.dart`）。

## 注意

- 显示文字一律跟随简繁设定（见根目录 AGENTS.md「搜尋功能規則」）。
