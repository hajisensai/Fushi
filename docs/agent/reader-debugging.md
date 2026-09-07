# 阅读器调试

> [CLAUDE.md](../../CLAUDE.md) 的子文档。当前 EPUB 阅读器路径与调试约定。

## 当前阅读器构成

- 页面：`fushi/lib/src/pages/implementations/reader_fushi_page.dart`，类 `ReaderFushiPage`（3242 行主体 + `reader_fushi/` 下 8 个域 part 文件 `audiobook` / `caret` / `chrome` / `lookup` / `lyrics` / `mining` / `navigation` / `webview`，共 9583 行：WebView 拦截 + JS 分页引擎 + 有声书同步）。
- source：`fushi/lib/src/media/sources/reader_fushi_source.dart`，类 `ReaderFushiSource`。
- JS / CSS：`fushi/lib/src/reader/` 下 `reader_pagination_scripts.dart`、`reader_content_styles.dart`、`reader_selection_scripts.dart`、`reader_caret_scripts.dart`。
- **JS 桥接全局叫 `window.fushiReader`**（2026-08 已从旧名 hoshiReader 改名；其余 hoshi 前缀运行时符号已在 W5 批次清完）；字级焦点用 `window.fushiCaret` + Dart `ReaderCaretRouter`。
- 当前阅读器问题**不要**去上游 ttu fork 仓库改。

## TTU 命名残留 vs 迁移代码

- `reader_ttu` key、`setTtu*` 方法、`ttuBookId` 列、`ttu_*` i18n 只是**旧数据兼容残留**，不代表还有 TTU 阅读器。改这些 key/方法名前，必须先确认是否会破坏旧书籍、偏好、书签、阅读位置或迁移。
- 旧 TTU 迁移代码已移除（develop `90c37b472`：`TtuMigrationServer`、`TtuIdbReader`、`assets/ttu-ebook-reader` 均已删除）。当前阅读器渲染/交互问题按 reader_fushi 路径修。

## 调试约定

- 书页空白、图片缺失、间距异常、播放栏遮挡等渲染问题，先查布局、overlay、page margin、WebView 可视区域、正文内容区域、资源拦截和 `window.fushiReader` 状态；不要一上来假设是图片解码或缓存坏了。
- 有声书播放栏问题必须**同时**看 Flutter 控件边界和 WebView/正文边界。重点记录 WebView bounds、正文 TextView/Image bounds、播放栏按钮 bounds；正文延伸到播放栏区域下方就是布局 inset 问题。
- 还原/跳转/跟随音频问题优先检查真实 reader 状态和 cue 位置：`_currentChapter`、章节内 progress、保存的 `ReaderPosition`、当前句文本和 `window.fushiReader` 的恢复/分页状态。已有保存位置时，位置数据优先于归一化文本匹配，文本匹配只能做 fallback。
- 页面恢复问题重点看 `_readerContentReady`、`_restoreInFlight`、`onLoadStop`、`_navigateToChapter*()`、`window.fushiReader.restoreProgress()`、`_readerSetupScript` 和分页脚本；不要只看 WebView 有内容就断言恢复完成。
- 遇到 WebView renderer crash、资源 404、CacheStorage 或旧资源症状，要区分当前资源拦截、旧迁移资产和用户设备缓存；不要加 TTU dummy 文件或用清数据掩盖真实升级问题。
- 调试 DOM/JS 用 Chrome DevTools Protocol 或 WebView inspection 读 DOM、console、JS 变量和布局尺寸；截图只能证明视觉现象，不能替代 DOM/边界数据。

## Headless Chrome 探针（真渲染、本机跑）

CI 跑不到真 WebView，分页 / 连续 shell 的落点、重锚、字号变化这类**真渲染**行为只能靠 `tool/reader_pitch_headless/*.mjs`（puppeteer-core + 本机 Chrome，`npm install` 一次装依赖，`CHROME_PATH` 可覆盖路径）。shell 自 2026-08 起是运行时工厂（`window.__fushiShells.<mode>(C)`），裸 shell 不能自举——探针必须吃 `reader_headless_shell_dump_test.dart` 写到 systemTemp 的**完整引擎产物** `fushi_engine_{paginated,continuous}.html`，在页面里按真实装配顺序 `window.__fushiInstallShell(C)` 安装（C 至少含 `vnMode / continuousMode / dartPageWidth / dartPageHeight / chromeTopInset / chromeBottomInset / initialCharOffset / initialProgress / initialFragment / sentenceAudioCues`），load 时自动 boot `initialize()`。范例：`font_shrink_reanchor_probe.mjs`（BUG-2205：改字号重锚后页首字不得越过锚字）、`visible_range_probe.mjs`（ReadUnitLedger：逐页 `fushiProgressDetails()` 的 `[start,end)` 单调且并集覆盖全章）、`audiobook_reveal_progress_probe.mjs`（BUG-2228：逐 cue `highlightSentenceAudioCue(id, true)` 后 cue 首字落在回传 `[start,end)` 内；引擎产物不含 setup 脚本的 `__fushiApplyReaderMargins`，探针须桩掉它）。仍读旧 `fushi_shell_*.html` 的老探针需要按同样方式改造后才能跑。

## 平台特例

- **Windows WebView2** 阅读器/字级焦点本身不坏；caret 测试失败常因书架里残留 lyrics-mode 旧书 → seed/打开一本全新分页书（`book_entry_fushi://book/<id>`）复测。
- 桌面端 debug 跑断言（release 不报），注意 `Expanded`-in-trailing 类布局陷阱。

## 手工验证清单

阅读器手工验证至少覆盖：封面图片页、长文本竖排页、有声书播放栏显示时的底部正文、播放/暂停、上一句/下一句、跟随音频跳转、章节开头/末尾跨章节、导入后首次打开、重启 App 后恢复位置。
