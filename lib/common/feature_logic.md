# common 模块说明

> 最后核对：`lib/common/app_nav.dart`、`lib/common/text_patterns.dart`。

## 职责

存放跨模块共享的最小公共设施，避免各模块互相依赖。

## 文件

- `app_nav.dart`：全局 `navigatorKey`。`main.dart` 的 `MaterialApp` 挂载它；
  通知栏「打开下载管理」等脱离页面上下文的入口通过它取 rootContext。
- `text_patterns.dart`：热点路径上复用的已编译 `RegExp`（空白折叠、经文
  work id、卷内文件号、引文行号、HTML 标签等）。只构造一次，供 reader、
  search、dictionary 等模块共享，不要在循环里重新 `new RegExp`。

## 注意

- 本模块不 import 任何业务模块，保持叶子依赖。
