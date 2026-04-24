# hibiki（Hoshi Reader Android）

基于 jidoujisho fork 的日语沉浸式阅读器，对标 iOS [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader)、https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md 。核心：EPUB + Yomitan 词典 + Anki 制卡 + 有声书同步。

## 仓库结构

- 仓库根：`d:\APP\vs_claude_code\hibiki\`
- Flutter app：`hibiki/hibiki/`（子目录，非根）
- 计划文档：根目录下 `AUDIOBOOK_SYNC.md`、`SUBTITLE_TO_EPUB_PLAN.md` 等
- 遗留 / 参考：`legacy/`、`chisa/`

## 当前状态

界面的中文和英文混用，未完全遵守语言设置

## 核心技术栈

- Flutter **3.41.6** / Dart 3.11.4（固定，见 `project_build_env` 记忆）
- WebView：ッツ (ttu) Ebook Reader 渲染 EPUB
- 存储：Isar（词典、阅读进度、SrtBook / Audiobook / AudioCue 等）+ Hive（部分偏好）
- NLP：MeCab + Ve（分词 + deinflection）
- 制卡：AnkiDroid API（AnkiConnect 为后续可选）
- 平台最低：Android 8.0（API 26）

## 关键文件（当前仓库，非 jidoujisho 原位置）

- 阅读器入口：`hibiki/hibiki/lib/src/pages/implementations/reader_ttu_source_page.dart`
- 书架：`reader_ttu_source_history_page.dart`
- 有声书桥：`lib/src/media/audiobook/audiobook_bridge.dart`
- 字幕 parser：`lib/src/media/audiobook/{srt,lrc,vtt,ass}_parser.dart`
- 字幕导入 UI：`lib/src/media/audiobook/srt_import_dialog.dart`（命名沿用 srt，实际四格式通用）

## ttu-ebook-reader fork

- **位置**：本机 `/d/ttu-fork/`（本地独立 git 仓库，**不是** hibiki 的 submodule）
- **分支**：`hibiki-patches-v2`（旧 `hibiki-patches` 基于 ttu-ttu kit-v1 已弃用）
- **上游**：`kamperemu/ebook-reader`（后续维护版，SvelteKit v2；remote 名 `kamperemu`）
- **远程（hibiki 私有 fork）**：`origin` → `https://github.com/hdjsadgfwtg/ttu-fork`
- **产物去向**：`pnpm build` 后，`apps/web/build/` 整套拷入 `hibiki/hibiki/assets/ttu-ebook-reader/`（保留手动维护的 `fonts/` 子目录）
- **补丁清单与构建细节**：见 [`docs/ttu-fork-notes.md`](docs/ttu-fork-notes.md)（每个 `feat/fix(reader): [hibiki] ...` commit 都列了 why）
- **当前已落地补丁（v2 单 commit 合并）**：`__ttuGoToSection` / `__ttuCurrentSection` / `__ttuSectionCount` / `__ttuGetToc` / `__ttuBookmarkPage` / `__ttuScrollToCharOffset` / `__ttuGetColumnGap` / `__ttuScrollToPos` API、`sectionChanged` console 事件、删除原生 reader chrome（顶部工具栏 + 底部进度条）、`avoidPageBreak` default 翻 true（`autoBookmark` 上游已默认 true）、continuous 模式滚动同步 `currentSectionIndex$`、`scrollTo` 加入 PageManager 接口

**何时改 fork，而非在 hibiki 侧注 CSS/JS**：凡是**动 ttu WebView DOM 结构、原生 UI chrome、全局 JS API**的改动，都优先走 fork 源码。理由：(1) 外部 CSS `display:none` 会随 Svelte hydrate / 重渲染失效；(2) 改正文相关样式（padding / margin / line-height 等）会让文字布局"乱动"；(3) fork 里改一次，rebase 上游就自然带上，比 Flutter 侧打 hack 干净。hibiki 侧只负责：WebView 容器尺寸（`Positioned.fill` 给播放栏让路）、SafeArea、JS 桥接消费 ttu 暴露的 API。

## 开发原则

- 不从零重写，在现有代码上删减 / 重构
- 遇到问题先定位，不回退到简化版
- 每个 PR 聚焦单一模块，commit 信息说明"为什么"
- 修改流程三步缺一不可：**analyze → 编译 APK → commit → 改版本号**（见 feedback 记忆）
- 字幕格式（SRT/LRC/VTT/ASS）统一走 EPUB 渲染，不做字幕列表 UI
- **ttu WebView 的 DOM / 原生 UI / JS API 在 `/d/ttu-fork/` 改源码 + 重 build，不在 hibiki 侧注 CSS/JS 强改**（见上节）

## 已知坑

- Isar 已停止维护，暂继续使用；`build_runner 2.4.4` 与当前 Flutter / Dart 不兼容，`.g.dart` 需手写或用独立脚本生成
- 11 个 pub cache 包需打 v1 embedding 补丁（见 `project_build_env` 记忆）
- MeCab 字典打包走 Android NDK
- ッツ reader 运行在 WebView，需验证 Android WebView 版本兼容

## 语言

回复和思考均使用中文，中文回复！中文回复！中文回复！