## BUG-721 · 剪贴板面板关闭后被永久暂停：第二个词出不来
- **报告**：2026-07-11（用户：「第一个关掉了，第二个就出不来了」，剪贴板去向=panel）
- **真实性**：✅ 真 bug（根因 `hibiki/lib/src/lookup/clipboard_panel_controller.dart` `update` 的 `if (paused && request.origin != DesktopLookupOrigin.hotkey) { drop }` 门 + `hidePanel(pause:true)`）
- **[x] ① 已修复** — 整条移除 `paused` 门：删 `paused` 字段、`update` 里的 paused-drop、`hidePanel` 的 `pause` 参数。关面板 = 藏窗（`_visible=false`），下一条剪贴板复制经 `update` 的 `!_visible` 分支无条件 `_showPanel` 重开。用户 2026-07-11 拍板「下一次复制重新弹出面板」。提交见分支 `worktree-fix-transient-lookup-latestwins`
- **[x] ② 已加自动化测试** — `hibiki/test/lookup/clipboard_panel_controller_test.dart` 源码扫描守卫改写：钉住 `bool paused` 字段移除、`request.origin != DesktopLookupOrigin.hotkey` 丢弃门移除、`update` 在 `!_visible` 时重开、`hidePanel()` 无参且不设阻塞标志
- **备注**：与最初报的覆盖窗/瞬态 bug（[BUG-578](BUG-578-desktop-floating-lyric-global-lookup-blank.md)）**无关**——瞬态光标查词 close→reopen 在 +624 构建实测每次都正常（真机 glog `hotkey→reveal(box)→dismissed→hotkey→reveal(box)`）；本条是**面板去向**独有的暂停语义。

### 现象
Windows 桌面剪贴板查词去向设 `panel`（Floating panel）。剪贴板复制第一个词 → 面板弹出正常；**点面板栏 × 关掉后**，再复制词 → 面板**不再弹出**，日志刷 `panel: paused — drop DesktopLookupOrigin.clipboard`。

### 真机日志证据（`<systemTemp>\hibiki_glookup.log`，用户真实运行 2026-07-10~11）
- `23:42:49 panel: shown` → 用户点 × 关面板 → `23:48:20 / 23:54:14 panel: paused — drop DesktopLookupOrigin.clipboard`：关面板后每次复制都被丢弃。
- 对照同段瞬态路径（hotkey Ctrl+Alt+D）：`23:18:16 lookup→showAt(atCursor)→overlaySize→reveal(box)` → `dismissed` → `23:18:29 lookup→reveal(box)` **第二次照常弹出**，证明 close→reopen 只有面板去向坏、瞬态没坏。

### 根因
`ClipboardPanelController`：`hidePanel({pause:true})`（面板栏 × 与 root 卡 × 都调它）把 `paused=true`；`update` 开头 `if (paused && request.origin != DesktopLookupOrigin.hotkey) { glog('paused — drop'); return; }` 把之后所有非 hotkey（=剪贴板）事件丢弃，直到 `Ctrl+Shift+D`（origin=hotkey）才 `paused=false` 解除。设计本意是「× 后别再打扰、想要再按 Ctrl+Shift+D」，但用户预期是「关掉当前卡，下一条复制自然重开」，于是体验成「第二个词出不来」。

### 修复
移除整个 `paused` 特例（好品味：消除特殊情况，而不是加分支）：删 `bool paused` 字段、`update` 的 paused-drop 块、`hidePanel` 的 `pause` 参数。关面板只 `_visible=false`+藏窗；下一条剪贴板 `update` 见 `!_visible` 直接 `_showPanel` 重开。想彻底静默面板走设置里的剪贴板查词总开关 / 切换去向，不再靠这个隐藏暂停门。`Ctrl+Shift+D` 仍可手动唤面板（只是不再承担「解除暂停」的特殊角色）。

### 待验（真机）
面板是 native WebView2 窗口，headless 测不了。需真机：剪贴板去向设 panel → 复制词（面板弹）→ 点面板栏 × 关掉 → 再复制词 → 面板**重新弹出**并显示新词（glog 出现 `panel: shown` + `panel: updated`，不再是 `panel: paused — drop`）。
