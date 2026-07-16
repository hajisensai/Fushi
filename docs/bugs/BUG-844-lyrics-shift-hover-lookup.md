## BUG-844 · 歌词模式不支持Shift/悬停查词
- **报告**：2026-07-16（用户：）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/pages/implementations/reader_hibiki/webview.part.dart:2031-2063`（歌词页就绪分支只注入行级 caret 脚本，不注入正文 `_buildReaderSetupScript`）+ `hibiki/lib/src/media/audiobook/lyrics_mode_html.dart`（独立文档只挂 tap/pointer 点击查词，无 mousemove 悬停查词监听、无 `window.__hoverAutoLookup`）。正文的 Shift-悬停/纯悬停查词监听器只活在正文文档（`webview.part.dart:1214-1223`），歌词整页替换后彻底缺失 → 歌词模式只能点击查词，Shift-悬停与纯悬停自动查词全失效。附带 `lyrics_mode_html.dart` 的 `selectText` 重写只声明 `(x,y,maxLen)`、丢弃第 4 个 `fromHover` 实参，导致就算补上悬停也会命中空白误 fire `onTapEmpty`、同词悬停被 toggle。
- **[x] ① 已修复** — 三处根因修复，提交见备注：
  - `lyrics_mode_html.dart`：新增 `document` 上 `mousemove` 监听，镜像正文 `webview.part.dart` 语义（`e.shiftKey || window.__hoverAutoLookup` 门控 + 64px² 位移阈值 → `callHandler('onShiftHover', x, y)`）。Dart `onShiftHover` 已 `_selectTextAt(fromHover:true)`，在歌词文档命中被重写的 `selectText`（写 `__lyricsCueContext`），与点击查词同源。
  - `lyrics_mode_html.dart`：`selectText` 重写改为 `function(x,y,maxLen,fromHover)` + `origSelectText.apply(this, arguments)` 原样透传 `fromHover`，悬停命中空白/同词不再误触发 `onTapEmpty`/toggle。
  - `webview.part.dart`：歌词页就绪时调 `_applyHoverAutoLookupLive()` 下发 `window.__hoverAutoLookup` 初值，纯悬停查词从进入歌词那刻即生效（Shift-悬停不依赖此全局）。
- **[x] ② 已加自动化测试** — `hibiki/test/media/audiobook/lyrics_mode_html_test.dart` 新增 `BUG-844 hover lookup parity` group：断言生成 HTML 含 mousemove→onShiftHover 监听、Shift/hoverAutoLookup 门控、64px² 阈值、`selectText` 透传 `arguments`（不再硬编码 3 参调用）。
- **备注**：Shift/悬停查词与点击查词都在歌词独立文档内经同一 `hoshiSelection.selectText` 管线，cue 元数据一致。拖选查词（选区手柄）是正文独立大功能，歌词模式按 cue 点/悬停查词，本次不纳入。提交哈希：见 PR。
