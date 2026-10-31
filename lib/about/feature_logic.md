# about 模块说明

> 最后核对：`lib/about/about_dialog.dart`。

## 职责

「關於」对话框。入口：`showAbout(context)`（首页设定选单调用）。

## 内容结构

- `AboutSection`：分区标题 + 内容；
- 三段介绍文字（App 简介、CBETA 来源、更新说明），可一键复制全文
  （`_aboutIntroductionText` 拼接）；
- `AboutLink`：外部链接（Gitee 仓库、CBETA 官网），走 `url_launcher`；
- `AboutLabelText`：开发者 / 微信聯絡等键值行。

## 注意

- 所有文案经 `displayText` 跟随简繁设定；新增文案请沿用本模块的
  `Text`（`widgets/display_text.dart`），不要直接用 material 的 `Text`。
