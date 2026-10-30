# 学佛 - CBETA 佛典阅读

基于 CBETA API 开发的免费开源佛典阅读与检索 Android 应用。经卷与 41 部佛学字典可下载到本地，离线单机运行；无需注册，不搜集任何隐私信息。

## 功能

- 全文搜索与 AI 语义搜索：支持 CBETA 全文检索，简体输入自动转繁体
- 经目浏览：部类、册别、作译者、年代、经目查询多种浏览方式
- Goto 查询：支持 CBETA 行号和引文格式直接定位
- 离线使用：经卷与 41 部佛学字典一键下载到本地，断网单机可用
- 阅读体验：书签、上次阅读位置、字体、行高、背景、简繁切换
- 特殊文字：内置 CBETA 悉曇、兰札与补充字体，可显示《梵語千字文》等经典中的悉曇／兰札字符与生僻汉字

## 下载

**arm64-v8a（多数 Android 手机）**  
https://gitee.com/undclouds/cbeta/releases/download/latest/app-arm64-v8a-release.apk

所有版本：https://gitee.com/undclouds/cbeta/releases

## 隐私

无需注册、无广告、不搜集任何个人信息。网络请求仅用于搜索、经文更新与字典下载；已下载内容断网后完全可用。

## 数据来源

经文与检索数据来自中华电子佛典协会（CBETA）  
数据服务：https://cbdata.dila.edu.tw

## 字体

CBETA 的悉曇（梵書）与兰札字符并非独立 Unicode 编码，而是「形似汉字码位 + 专用字体替换字形」的方案。App 随包内置三种 CBETA 字体：

- Siddam.ttf（悉曇体，约 3.9MB）
- Ranjana.ttf（兰札体，约 0.4MB）
- CBETASupplement.ttf（补充字体，约 10MB，兼作生僻汉字兜底）

已知限制：

- 偈颂（经文中以表格格子里呈现的 verse 块）走独立渲染路径，若悉曇／兰札字符出现在偈颂格子内，暂不换用专用字体，只显示 fallback 汉字；
- 复制/引用悉曇字时，剪贴板中的是其 fallback 汉字码位（与 CBETA 网页版行为一致），粘贴到未安装悉曇字体的环境中会显示为汉字；
- 简繁切换会对显示文字做逐码转换，极少数悉曇 fallback 字符若存在简繁对应关系，切到简体时可能脱离悉曇字体的码位而显示为汉字。

## 开发信息

- 开发者：undcloud
- 开源项目：https://gitee.com/undclouds/cbeta
- 微信联系：undcloud

## 授权

本项目采用 GNU General Public License v3.0（GPL-3.0）

Copyright (C) 2026 undcloud

第三方数据（CBETA 经文、字体等）遵循各自原有的授权条款。
