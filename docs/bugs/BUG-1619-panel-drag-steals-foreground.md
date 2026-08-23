## BUG-1619 · 拖剪贴板查词面板顶栏把主窗抢到前台
- **报告**：2026-08-14（用户：拖动剪切板弹窗的顶栏的时候，总是会把 fushi 主界面拉到前台）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/focus/fushi_focus_controller.dart:293` `ensureFocus()`——被动焦点修复在**主窗不在前台**时仍 `requestFocus`，Flutter 引擎把它翻译成 `SetFocus(FlutterView)`，Win32 语义下 `SetFocus(子窗)` 连带激活其顶层窗口，于是主界面盖住用户正在用的游戏 / 浏览器。
- **[x] ① 根因修复** — commit 见本文件所在分支：`ensureFocus()` 增加**窗口级**前台判据并在被挡下时记账，主窗回到前台由 `_handleFocusChange` 补一次修复；`PageFocusOwnership.reclaim(appResumed)` 与首页 `_reclaimHomeFocusIfOwned` 同判据（进程级 `resumed` 同样会被辅助窗夺焦误触发）；`DesktopForegroundGuard.isMainWindowForeground()` 为新增判据。
- **[x] ② 已加自动化测试** — `fushi/test/focus/background_focus_repair_test.dart`（3 例：挡下 / 放行 / 补票）+ `fushi/test/focus/resumed_focus_reclaim_guard_test.dart`（6 例，含类名常量与 runner 逐字符一致的源码扫描）。两处判据与补票逻辑均做过变异实测：分别删掉即有对应用例转红。
- **[x] ③ 根治层（第二轮）** — 逐点判据穷举不完（用户随后报「复制文本也会被拉到前台」，那条链路在全仓 16 处 `requestFocus` 里定位不到），故在 app 根部立结构性不变量：`MainWindowFocusGate` —— 主窗不拥有 OS 焦点时整棵 Flutter 焦点树不可聚焦，任何 `requestFocus` 都是 no-op。配套两级恢复：关门前记录 primaryFocus、开门后精确还给它；还不回去（如 app 在后台启动、路由 ModalScope 在关门期间挂载被挡）则由闸门自己把焦点交进子树。
- **备注**：真机验收在用户真实数据根上完成（诊断构建 schemaVersion 86 == 库 user_version 86，无迁移）。

### 根治层：为什么是根部不变量而不是逐点判据

三层根因里只有第三层是我们的：① Win32 硬语义 `SetFocus(子窗)` 连带激活顶层窗口；② Flutter 引擎为 IME/键盘无条件对 FlutterView 调 `SetFocus`；③ Fushi 在主窗不在前台时仍发起焦点请求。①② 改不了（除非 fork engine 或 IAT hook `user32!SetFocus`——后者会让 IME 状态错乱且每次引擎升级都可能崩，不采纳）。

第三层落在哪一层实现，决定了它是补丁还是根治：逐点判据要求穷举所有入口，而复制那条至今没定位到；根部不变量让「某处 requestFocus 抢了前台」这个特殊情况**不存在**。

真机 A/B（隔离实例，同一套按键序列）：

| 版本 | 按键到达 Flutter | 开门后 primaryFocus |
|---|---|---|
| 闸门启用、无兜底 | ✅ | `View Scope`（退到最外层，页面焦点体系失效） |
| 闸门禁用（对照） | ✅ | `_ModalScopeState Focus Scope` |
| **闸门 + 两级恢复** | ✅ | **`FocusNode`（子树内具体节点）** |

门开关序列与焦点恢复实测：`CLOSED`(后台启动) → `OPEN`(激活主窗，兜底交接) → `CLOSED`(切走) → `OPEN`(切回，精确恢复到同一个 FocusNode)。

### 根因

桌面版 Fushi 是**多顶层窗口**进程：主窗之外还有剪贴板查词面板（`FushiGlobalLookupWindow`，`SetActivatable(true)`）、app 外查词覆盖窗、悬浮歌词 / 台词窗。Flutter 的焦点模型只认「一个 view」，Dart 侧任何焦点请求最终都会被引擎翻译成 `SetFocus(FlutterView)`。

完整链路（真机抓到 `win32u!NtUserSetFocus` 调用栈；`SetForegroundWindow` 断点全程未命中，故**不是**显式唤前台）：

```
拖面板顶栏结束
  → native WM_EXITSIZEMOVE → windowMoved
  → ClipboardPanelController 写 clipboard_panel_rect
  → PreferencesRepository.notifyListeners()
  → 首页重建 → FushiFocusTarget 重新 register()
  → FushiFocusController.scheduleRepair() → postFrame → ensureFocus()
  → requestFocus → 引擎 SetFocus(FlutterView)
  → Win32：SetFocus(子窗) 连带激活顶层窗口 = 主窗被抬到前台
```

复现前提（缺一不可，这也是隔离环境长期复现不出来的原因）：主窗**非最小化**、主窗此前被激活过（Dart 焦点落在主窗内）、前台是别的 app。

判据必须是**窗口级**的：真机日志里被挡下的那些 `ensureFocus`，前台窗口是 `FushiGlobalLookupWindow` 且 `mine=true`——沿用既有的进程级判据 `isForegroundOwnedByCurrentProcess()` 会直接放行。

BUG-1455 修的是同一症状的另一条支路（主窗 `WM_ACTIVATE` 里的 `SetFocus(child_content_)`），它拦的是「面板夺焦那一刻」；本 bug 的抢焦点发生在拖动中途与松手后，由引擎主动发起，那条门控结构上拦不住。

### 验证

- 真机（用户真实数据根，Chrome 持有前台）：修复前 `after drag: mainZ=5 rivalZ=7 fg=主窗`（主界面盖住 Chrome）；修复后 `mainZ=7 rivalZ=6 fg=面板`，主窗 Z 序全程不动。
- 带打点构建实测：拖动结束瞬间 `ensureFocus` 被判据挡下 8 次；主窗切回前台后 `deferred repair -> replayed` + `ensureFocus proceeding`（补票闭环，快捷键不会死）。
- `flutter test test/focus/` 73 例全绿（既有 70 + 新增 3）；`test/sync/` + `test/pages/` 4948 例全绿；`flutter analyze`（含 test）No issues found。
