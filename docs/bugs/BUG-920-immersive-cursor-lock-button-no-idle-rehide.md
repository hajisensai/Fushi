## BUG-920 · 沉浸模式鼠标光标与沉浸退出按钮静止时不隐藏（缺「空闲重隐」路径，除非把鼠标移到别处）

- **报告**：2026-07-19（用户：沉浸模式鼠标没办法隐藏，那个沉浸模式的按钮也没办法隐藏，除非切鼠标到别的地方）
- **真实性**：✅ 真 bug。根因在 `hibiki/lib/src/pages/implementations/video_hibiki/controls_visibility.part.dart:316`（`_pokeLockButton` 的 2s 自动淡出定时器**只**清 `_lockButtonVisible`，既不重隐 OS 光标、也不释放 hover 保活 `_lockButtonHovered`）+ `_applyControlsVisibilityFromMediaKit`（OS 光标隐藏唯一权威）在沉浸态只被门控 state 变化驱动、静止时不重跑。
- **根因**：沉浸态下 media_kit 控制条被 `IgnorePointer` + 门控（`_immersiveLocked`）整体关掉，`_mediaKitControlsVisible` 不再翻 → `_applyControlsVisibilityFromMediaKit`（`_setCursorHidden(!visible && !_hasVideoOverlay)`）**只在进沉浸那一刻跑一次**把光标隐藏。之后真实鼠标移动经 `_handleVideoControlsHover` 调 `_setCursorHidden(false)` 唤回光标，就**再没有任何「静止超时」路径**把光标重新隐藏 → 光标常驻。
  - 沉浸退出按钮同理：`_lockButtonHoverKeepAlive`（TODO-388/BUG-294）在鼠标进按钮置 `_lockButtonHovered=true`、**只 onExit 才清**。鼠标静止悬在按钮上时无 onHover 续命，2s 定时器把 `_lockButtonVisible` 打成 false，但可见性判据 `_lockButtonVisible || _lockButtonHovered` 因 `_lockButtonHovered` 仍为真被顶死 → 按钮永不淡出。
  - 「移到别处才隐藏」= 光标移出按钮触发 `onExit` 清 `_lockButtonHovered`（按钮淡出）+ 光标几何回视频区（media_kit `hideMouseOnControlsRemoval` / 顶层 `cursor:none` 层再次生效）两件事凑巧同时发生，与用户描述吻合。
- **[x] ① 根因修复** — 提交 9a8dbe64f。
  - `controls_visibility.part.dart` `_pokeLockButton` 定时器回调补上缺失的「空闲重隐」路径（单函数改动，不动按钮可见性公式 / 两条渲染路径）：2s 无操作后，桌面 `if (_isDesktopVideoControls)` 内 ① 重跑 `_applyControlsVisibilityFromMediaKit()` 按门控 / overlay 重隐光标；② **光标真被隐藏时**（`if (_cursorHidden.value)`）再释放 `_lockButtonHovered`，让按钮随光标同步淡出。
  - 消除特殊情况：`_lockButtonHovered` 保活的语义本是「鼠标正**可见地**悬在按钮上、别在光标正下方凭空消失」（BUG-294）；光标既已隐藏，该保活前提消失，故释放它 = 让按钮随光标一起干净淡出。光标仍可见时（`_hasVideoOverlay` 强制光标可见，如字幕列表 / 侧栏）**不**清 hover → **保 BUG-294**，按钮不在可见光标下消失。鼠标再移动经 keep-alive onHover 重新置 `_lockButtonHovered=true` 唤回按钮、`_handleVideoControlsHover` 同步唤回光标。
  - 移动端无 OS 光标语义：桌面门控块整体跳过，`_lockButtonVisible` 自然淡出行为完全不变。
- **[x] ② 自动化测试** — 提交 9a8dbe64f：`hibiki/test/pages/video_immersive_idle_rehide_guard_test.dart`。media_kit controls 跑不了 headless（与既有 `video_immersive_cursor_hide_guard` / `video_immersion_button_hover_guard` 同理），故用源码扫描守卫锁死 `_pokeLockButton` 定时器回调内的两不变量：① 静止超时重跑 `_applyControlsVisibilityFromMediaKit`（空闲重隐光标）；② 光标真隐藏时释放 `_lockButtonHovered`（按钮随光标同步淡出），且整块桌面门控 `_isDesktopVideoControls`。同时反向钉死不得退回「定时器只清 `_lockButtonVisible`」。
- **备注**：真机复测由验证代理执行——桌面沉浸模式下鼠标静止 2s，光标与沉浸退出按钮应一起隐藏；打开字幕列表 / 侧栏时鼠标悬在按钮上不应凭空消失（保 BUG-294）；鼠标再移动应唤回二者。
