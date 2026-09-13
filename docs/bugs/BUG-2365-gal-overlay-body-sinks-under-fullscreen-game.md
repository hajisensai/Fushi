## BUG-2365 · galgame 全屏后台词浮窗正文窗沉到游戏底下（顶条还在、文字没了）
- **报告**：2026-09-09（用户：游戏切全屏后「显示不了字幕」；追问后确认是「字幕栏顶条还在，文字没了」）
- **真实性**：✅ 真 bug。根因 `fushi/windows/runner/floating_lyric_window.cpp`（正文窗从无周期性置顶重申）
  vs `fushi/windows/runner/hook_toolbar_window.cpp:735/745/749`（工具条窗每次 Sync 都无条件重申）。

### 根因

穿透态下台词浮层是**两个窗口**：

| 窗口 | 谁重申 Z | 频率 |
|---|---|---|
| 独立逃生工具条窗 `HookToolbarWindow` | `Sync()` 里无条件 `SetWindowPos(HWND_TOPMOST)`（连「无需重绘」的早退分支里也做，注释点名 BUG-951 不变式） | **每次渲染**（每条台词） |
| 台词正文窗 `FloatingLyricWindow` | 只有 `Show` / `ClampCurrentPositionToWindowMonitor` / WM_DPICHANGED / `SetTopmost`（📌 按钮） | **事件驱动，全屏切换不在其中** |

galgame 切全屏时会把游戏窗口抬进置顶带（KiriKiri / Siglus 等引擎的常规动作）。同一置顶带内是
「最后一次 `SetWindowPos` 的赢」——**这不是独占全屏那条 OS 硬限制**，BUG-1479 已在查词卡上确认过
同一机制并给出结论（见 `global_lookup_window.cpp` `HandleMessage` 的 WM_TIMER 注释）。

于是全屏那一刻两个窗口一起被压到游戏底下，**下一帧工具条自己爬回来，正文窗永远留在底下**：
用户看到的正是「顶条还在、文字没了」。`DispatchControlAction` 里 📌 的注释早就写明
「Re-pinning 是被别的窗口爬过去之后回来的路」——问题是它**只有手动那一条路**。

### 修复

- **[x] ① 已修复** — 正文窗拿到与查词卡同形状的 800ms 置顶守卫
  （`kTopmostGuardTimerId` + `ReassertTopmost` / `StartTopmostGuard` / `StopTopmostGuard`，
  `floating_lyric_window.cpp`）。两条纪律：
  - `topmost_` 为假（用户按 📌 主动取消置顶）时早退——守卫不得把显式意图顶回去；
  - 重申后立刻 `SyncPassThroughToolbar()` 把逃生工具条重新顶到正文之上（BUG-951 不变式）。

  同时避免与查词卡的守卫互抢：卡片自己也每 800ms 重申置顶（BUG-1479），两边都抢置顶带最顶
  会让卡片周期性闪到浮窗底下。新增 `GlobalLookupWindow::TopmostCeilingHandle()` +
  `FloatingLyricWindow::SetTopmostCeilingProvider()`，有可见卡片时正文窗**插在卡片正下方**
  （仍在全屏游戏之上，因为卡片的守卫保证卡片在游戏之上），没有卡片时才抢最顶。
  有声书悬浮字幕与 galgame 台词浮窗是同一个类的两个实例，两处都接了天花板。

- **[x] ② 已加自动化测试** — `fushi/test/native/gal_overlay_topmost_guard_static_test.dart`
  （4 条源码守卫：定时器真接线、pin 语义早退、让位天花板 + 工具条回顶、两个实例都接天花板）。

### 备注

- 这条与 BUG-1479（查词卡被 galgame 盖住）是**同一个机制的两个受害者**；当年只修了卡片。
- `test/native` 是改 `windows/runner/*.cpp` 的真实爆炸半径，按功能域挑测试结构上挑不到。
- 尚未在真实全屏 galgame 上复测（原始失败路径的真机验证缺口），仅有编译 + 源码守卫。
