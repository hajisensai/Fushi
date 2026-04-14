项目：Hoshi Reader Android — 基于 jidoujisho 的日语沉浸式 EPUB 阅读器
背景
Hoshi Reader 是一个 iOS 原生（Swift/SwiftUI，面向 iOS 26）的日语 EPUB 阅读器，核心卖点：

纵书（縦書き）和横书（横書き）支持
Yomitan 兼容的弹窗词典（含 deinflection）
支持所有 Yomitan term / frequency / pitch 词典格式
支持 Yomitan 在线和本地音频源
AnkiConnect Android 集成制卡
Lapis 兼容（书架同步协议）
轻量、快速、专注阅读体验

jidoujisho 是一个 Flutter/Dart 编写的安卓端全功能日语沉浸学习套件（GPL-3.0），包含：

基于 ッツ Ebook Reader 的 EPUB/HTMLZ 阅读器（WebView 渲染）
Yomichan / Migaku / DSL 词典导入和查词
视频播放器（VLC）、YouTube、浏览器等多媒体源
AnkiDroid 制卡集成
数据库：Isar + Hive
NLP：Ve + MeCab（日语形态分析）

目标
从 jidoujisho 仓库 fork，大幅精简为一个专注 EPUB 阅读 + 词典查词 + Anki 制卡的安卓应用，对标 Hoshi Reader 的功能和体验。命名为 Hoshi Reader Android（或自定名称）。
架构策略
Phase 1：剥离与精简

移除不需要的媒体源：删除 YouTube player、VLC video player、browser media source、lyrics 相关代码。只保留 Reader（ッツ Ebook Reader WebView）作为唯一媒体源。
移除不需要的外部服务：ChatGPT 集成、Bing 图片搜索、Forvo/JapanesePod101 音频搜索、ImmersionKit/Massif/Tatoeba 例句、Uta-Net 歌词。
精简 UI：主界面从 jidoujisho 的多 tab 架构（Player / Reader / Dictionary / Browser）简化为：书架（Library）→ 阅读器（Reader）→ 词典弹窗（Popup Dictionary）。
保留核心依赖：

ッツ Ebook Reader WebView（EPUB 渲染核心）
Isar / Hive（词典和阅读进度存储）
MeCab + Ve（日语分词和 deinflection）
AnkiDroid 接口（制卡）



Phase 2：对齐 Hoshi Reader 功能

词典系统重构：

保留 Yomichan 词典导入（jidoujisho 已有），确认支持 term bank、frequency、pitch accent 数据
参考 Hoshi Reader 的 deinflection 逻辑（基于 Yomitan 的 deinflect.json 规则），与 jidoujisho 现有的 MeCab 分词结果交叉验证
弹窗 UI 参考 Hoshi Reader 的卡片式设计：词条 → 读音 + pitch → 释义 → frequency 标签 → Anki 按钮


AnkiConnect Android 支持：

jidoujisho 原本通过 AnkiDroid API 直接制卡。增加对 AnkiConnect Android 的支持作为备选方案
制卡模板应包含：word、reading、glossary、sentence（上下文句子）、sentence_reading、audio（如有）


阅读器增强：

纵书模式：ッツ Ebook Reader 本身支持纵书，确认此功能正常工作并在设置中暴露切换
选词交互：点击/长按/拖选文本 → JavaScript bridge → Flutter 侧触发词典查询。参考 jidoujisho 现有的 reader_page.dart 中 WebView JS 通信逻辑
阅读进度：按字符数计算进度，持久化到 Isar
书签与高亮：可选功能，jidoujisho 部分已有


音频支持：

支持 Yomitan 格式的在线音频源（如 JapanesePod101 URL 模板）
支持本地音频源（用户自行放置的音频文件包）


Lapis 协议（可选/后续）：

Hoshi Reader 支持 Lapis 书架同步，如需对齐可后续实现



Phase 3：UI/UX 打磨

设计语言：Material 3 / Material You，跟随系统主题
书架界面：网格/列表视图，显示封面、标题、作者、阅读进度
阅读器界面：沉浸式全屏，底部/顶部滑动呼出控制栏（字体大小、纵横切换、主题、亮度）
词典弹窗：底部弹出 Sheet，支持上滑展开更多释义，左右滑动切换词典
设置页：词典管理（导入/排序/删除）、Anki 连接配置、阅读偏好、外观主题

技术要点

语言：Dart (Flutter)，所有函数加类型注解
最低 Android 版本：Android 8.0 (API 26)
关键文件定位（jidoujisho 仓库）：

lib/media/media_sources/reader_media_source.dart — Reader 媒体源入口
lib/media/media_type.dart — 媒体类型定义
lib/dictionary/ — 词典导入、查询、格式解析
lib/anki/ — AnkiDroid 集成
lib/language/japanese/ — 日语 MeCab 分词、deinflection
lib/creator/ — 制卡界面和逻辑
assets/ — ッツ Ebook Reader 的 web assets


需要注意的坑：

jidoujisho 使用 Isar 数据库（已停止维护），考虑是否迁移到 Drift/SQFlite 或继续使用
ッツ Ebook Reader 在 WebView 中运行，需确保 Android WebView 版本兼容
MeCab 的 Android NDK 编译和字典文件打包
Structured-content Yomichan 词典目前 jidoujisho 不支持，Hoshi Reader 也可能不支持，可作为后续目标



开发原则

不要从零重写，从 jidoujisho 现有代码删减和重构
遇到功能不工作时，先调试定位问题，不要回退到简化版本
每个 PR 聚焦一个模块的变更（如"移除视频播放器"、"重构词典弹窗 UI"）
优先保证核心链路可用：打开 EPUB → 选词 → 查词 → 制卡