# hibiki（Hoshi Reader Android）

基于 jidoujisho fork 的日语沉浸式阅读器，对标 iOS [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader)、https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md 。核心：EPUB + Yomitan 词典 + Anki 制卡 + 有声书同步。

## 仓库结构

- 仓库根：`d:\APP\vs_claude_code\hibiki\`
- Flutter app：`hibiki/hibiki/`（子目录，非根）
- 计划文档：根目录下 `AUDIOBOOK_SYNC.md`、`SUBTITLE_TO_EPUB_PLAN.md` 等
- 遗留 / 参考：`chisa/`（旧 jidoujisho 参考见[上游仓库](https://github.com/arianneorpilla/jidoujisho)）

## 当前状态

界面已完成 i18n（17 语言），通过 Slang 框架管理；Creator labels 保留英文稳定标识，UI 通过 getLocalisedLabel 动态翻译

## 核心技术栈

- Flutter **3.41.6** / Dart 3.11.4（固定，见 `project_build_env` 记忆）
- WebView：ッツ (ttu) Ebook Reader 渲染 EPUB
- 存储：Isar（词典、阅读进度、SrtBook / Audiobook / AudioCue 等）+ Hive（部分偏好）
- NLP：MeCab + Ve（分词 + deinflection）
- 制卡：AnkiDroid API（AnkiConnect 为后续可选）
- 平台最低：Android 7.0（API 24）

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

## 持续审查规则

- 用户要求审查项目、继续审查、风险审计或类似任务时，默认进入持续审查模式；不要只在聊天里输出一次性总结。
- 持续审查报告写入 `docs/reviews/YYYY-MM-DD-project-review.md`。如果目录不存在，先创建 `docs/reviews/`。
- 每一轮审查都追加到同一个报告文件，不覆盖历史内容。每轮至少包含：
  - `Scope`: 本轮检查的文件、路径、提交范围或用户路径。
  - `Findings`: 按 `HBK-AUDIT-XXX` 编号列出问题；每个问题必须包含 `severity`、`status`、相关文件/行号、根因、影响、修复建议和验证方式。
  - `Next Scope`: 下一轮继续审查的范围。
- 审查顺序默认按风险走，而不是按提交或文件名散步：数据库/迁移 -> 启动初始化 -> 阅读器状态 -> 字典导入/native FFI -> 音频 cue -> WebView/缓存 -> UI 假状态。
- 审查阶段只写报告和修复建议，不改业务代码；除非用户明确要求“开始修”“逐条修”或等价指令。
- 如果审查或手工验证发现已复现回归，必须同步更新 `docs/REGRESSION_BUGS.md`，并把截图、UI XML、logcat 或 bounds 证据放到 `.codex-test/` 后在报告中引用。
- 报告结论必须区分“代码路径审查发现的风险”“已经复现的 bug”“已验证通过的修复”。没有跑过验证时，不要写成已通过。

## 提交规则

- 每次完成代码、文档、测试或审查报告修改后，默认提交本轮改动。
- 提交前必须先运行与改动匹配的最小验证；如果验证因环境、工具链或既有无关错误阻塞，必须在最终回复和提交说明中明确说明。
- 提交前必须检查 `git status --short`，只 stage 本轮相关文件；工作区已有的无关改动不得纳入提交。
- 提交前运行 `git diff --cached --check`。
- 提交信息要简洁说明真实改动，例如 `docs: add continuous review rules` 或 `fix(reader): preserve restore position`。
- 提交后再次检查 `git status --short`，并在回复中说明本次提交哈希和仍然存在的无关未提交改动。

## 已知坑

- Isar 已停止维护，暂继续使用；`build_runner 2.4.4` 与当前 Flutter / Dart 不兼容，`.g.dart` 需手写或用独立脚本生成
- 11 个 pub cache 包需打 v1 embedding 补丁（见 `project_build_env` 记忆）
- MeCab 字典打包走 Android NDK
- ッツ reader 运行在 WebView，需验证 Android WebView 版本兼容

## 语言

回复和思考均使用中文，中文回复！中文回复！中文回复！
