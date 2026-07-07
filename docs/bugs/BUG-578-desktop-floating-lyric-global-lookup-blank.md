## BUG-578 · 桌面悬浮字幕点词全局查词覆盖窗空白/不出现
- **报告**：2026-07-07（用户：TODO-1268）
- **真实性**：✅ 真 bug（根因 `hibiki/lib/src/lookup/global_lookup_controller.dart:353` 的 `lookupText`；对照 `_onHotKey` `:294`）
- **[x] ① 已修复** — `global_lookup_controller.dart` `lookupText` 在 `_lookupExternal` 前补上被 `_onHotKey` 独享的 TODO-1079(D) 前置复位（`await GlobalLookupChannel.hide(notify:false)`），提交见分支 `todo1268-floating-lyric-lookup`
- **[x] ② 已加自动化测试** — `hibiki/test/lookup/floating_lyric_lookup_reset_guard_test.dart`（源码扫描守卫：`lookupText` 必须先 `await hide(notify:false)` 复位再 `_lookupExternal`，与 `_onHotKey` 保持一致）
- **备注**：

### 现象
Windows 桌面听有声书时，点悬浮字幕条（`floating_lyric_window.cpp`）上的日文词，867 app 外全局查词覆盖窗**空白/不弹出**。全局热键 `Ctrl+Alt+D` 查词一切正常。

### 真机日志证据（`<systemTemp>/hibiki_glookup.log`，用户真实运行）
同一会话（2026-07-06 21:22 启动、同一 build、同一 prewarm）：
- **热键路径**（22:08:37 `込みました`）：`searched → js:overlaySize(30ms) → reveal(box)` —— host 正常渲染+回传，卡片正常显示。
- **悬浮字幕路径**（22:25:30 起 29 次 `lookupText`）：`lookupText → searched → showAt → autoread → reveal: READY-SAFETY`。**全程零 host 消息**（无 `overlaySize`/`popupRendered`/`favoriteCheck`），只能靠 450ms READY-SAFETY 兜底翻可见 —— 覆盖窗空白。首个孤立点击（有 469ms 静默窗口）同样拿不到 `overlaySize`，排除“单纯太快”。

`renderPopup` 在所有分支都会发 `popupRendered`（`popup.js:2564+`），故“零 host 消息”= host 帧根本没渲染完成/握手，而非 popup.js 抛错。

### 根因
两条触发都汇入同一个 `_lookupExternal`（渲染管线本身没问题，热键已证明其可用）。差异只在**前导时序**：
- `_onHotKey`（`:294`）：`GlobalLookupChannel.hide(notify:false)` → **await 异步选区抓取（UIA/剪贴板，~100–370ms 真事件循环让路）** → `_lookupExternal`。
- `lookupText`（`:353`，悬浮字幕/程序化入口）：**零让路**直接 `_lookupExternal`。

`_lookupExternal` 内部虽也 `hide(notify:false)`（TODO-1079 D）但**未 await**、紧接着 `searchDictionary`(~15ms) → `render(beginLookup)` → `showAt` → `renderStack`。热键靠选区抓取的长让路，让原覆盖窗的 hide→show 过渡与 host content-ready 门在渲染前充分沉降；悬浮字幕点词零让路 + 用户常见的**快速连点**（日志里每秒多次 `lookupText`）叠加，令并发/复用的覆盖窗 reveal 状态与 host 门被踩踏，`overlaySize` 从不发出 → 覆盖窗只走 READY-SAFETY 空白兜底。

设计注释（`:304-308`）声称 `_lookupExternal` 内部 hide “keeps the programmatic lookupText path equally clean”，真机证据证否：程序化路径并不 clean。

### 修复
`lookupText` 在 `_lookupExternal` 前补 `await GlobalLookupChannel.hide(notify:false)`，与 `_onHotKey` 前导复位对齐：await 平台线程真正完成 SW_HIDE + unhook（同时让一次事件循环），把覆盖窗收敛到已知隐藏态、连点之间干净复位，再进入 `_lookupExternal` 重开。`notify:false` 保证该 between-lookups 复位不被当成用户关窗（TODO-1233，避免误恢复暂停视频）。

### 待验（真机）
覆盖窗是 native WebView2 窗口，headless 测不了（原作者在 `floating_lyric_global_lookup_guard_test.dart` 亦如此标注）。需真机：桌面开有声书 → 显示悬浮字幕 → 连点多个词 → 覆盖窗每次都出现且有词卡内容（观察 glog 出现 `js:overlaySize`/`reveal(box)` 而非仅 `READY-SAFETY`）。
