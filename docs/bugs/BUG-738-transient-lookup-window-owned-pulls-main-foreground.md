## BUG-738 · 悬浮字幕点词瞬态查词窗owned·Z序连带把主窗拉前台
- **报告**：2026-07-12（用户：悬浮字幕点词时 app 主窗被拉到前台；面板窗也不该把主窗拉前台）
- **真实性**：✅ 真 bug（根因 `hibiki/windows/runner/flutter_window.cpp` 瞬态 `global_lookup_window_->ShowAt` / `PrewarmWebView` 传 `GetHandle()`=主窗 HWND 当 owner）
- **[x] ① 已修复** — 瞬态窗 owner 改 `nullptr`（showAt + prewarm 两处），与面板窗一致（commit 待填）
- **[x] ② 已加自动化测试** — `hibiki/test/lookup/global_lookup_transient_no_owner_guard_test.dart`（源码扫描守卫，3 用例，`flutter test` 绿）
- **备注**：

### 根因

app 外查词覆盖窗有两个 `GlobalLookupWindow` 实例：瞬态查词窗（`global_lookup_window_`，悬浮字幕点词/全局热键/面板点释义弹的跟光标卡片）与常驻剪贴板面板（`clipboard_panel_window_`）。真机第 4 轮已发现 **owned 顶层窗（owner=主窗 HWND）的 Z 序变更会连带把 owner 主窗拉到前台**，当时把**面板**改成无 owner 修好，但**瞬态窗被刻意"保持 owned"**（`flutter_window.cpp` 旧注释："短命窗，随主窗收纳是合理语义"）。

代价即用户症状：悬浮字幕点词（Windows 上优先走瞬态覆盖窗 `lookupText`，`lyrics.part.dart:_lookupFromFloatingLyric` → `tryFloatingLyricGlobalLookup`）时，瞬态窗 owned by 主窗 → 弹出的 Z 序变更把主窗拽到前台，盖住底下的游戏/视频，违反覆盖窗「绝不夺前台」契约（design §5 guarantee 3，native 覆盖窗本身全程 `NOACTIVATE`、无 `SetForegroundWindow`——夺前台**只**来自 owner 连带）。

注：面板窗已无 owner，激活它（`SetActivatable(true)`，为滚轮不穿透）只让面板窗自身前台、不连带主窗；用户"面板也不该拉主窗"的诉求已被无 owner 满足。悬浮字幕**回落路径**（覆盖窗不可用时 `bringPendingLookupToFront`）拉主窗是正确的——那时结果只能进主窗词典 tab，不在本 bug 范围。

### 修复（用户否决「随主窗收纳」取舍：不夺前台 > 随主窗收纳）

`flutter_window.cpp` 瞬态实例两处 owner `GetHandle()` → `nullptr`：
- `global_lookup_window_->ShowAt(..., nullptr)`
- `global_lookup_window_->PrewarmWebView(..., nullptr)`（须与 showAt 一致，否则 BUG-737 的 `ForgetDeadWindow` 重建时 owner 漂移）

瞬态窗短命且 `arm_dismiss_hooks=true`（前台切换即 `ForegroundHookProc`→`Hide`），主窗最小化=前台切换=瞬态窗自关，故"随主窗收纳"语义仍在，无孤儿悬浮窗回归。

### 待验证

- Windows 真机：听书时主窗最小化/置后台，点悬浮字幕上的词 → 卡片弹在光标处、**主窗不被拉到前台**；再验热键 Ctrl+Alt+D、面板点释义同样不夺前台。
- 相邻回归：主窗最小化时瞬态卡片仍随之收起（前台钩子自关）；BUG-737 死窗重建路径不受 owner 改动影响。
