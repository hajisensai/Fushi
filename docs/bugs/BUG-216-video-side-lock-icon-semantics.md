## BUG-216 · 视频侧边锁按钮图标语义反了
- **报告**：2026-06-12（用户：）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/pages/implementations/video_hibiki_page.dart` `_buildSideLockButton` 的图标三元 `Icon(locked ? Icons.lock_open_outlined : Icons.lock_outline)`——锁定（沉浸态）时显示「开着的锁」，是「动作提示」语义（点这能解锁），与用户「锁住=闭锁」的状态预期相反。同页 OSD（`_toggleImmersiveLock`：锁定用 `lock_outline` 闭锁 / 解锁用 `lock_open_outlined`）、Android `FloatingLyricService.java`、Windows `floating_lyric_window.cpp` 都已是正确状态语义，只有视频侧边按钮这一处反了。
- **[x] ① 已修复** — 图标三元改为状态语义 `Icon(locked ? Icons.lock_outline : Icons.lock_open_outlined)`（锁住→闭锁、未锁→开锁），并同步更新 `_buildSideLockButton` 上方设计注释（否则后人按旧注释翻回去）。tooltip（locked → 点击解锁）保持动作语义不动；上下文菜单固定动作图标、悬浮字幕两端已正确，均不动。提交见 git log（TODO-153）。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/video_immersive_lock_guard_test.dart` 新增用例「侧边锁按钮图标用状态语义」：断言图标为 `locked ? lock_outline : lock_open_outlined`、防回归倒回旧反向、tooltip 仍动作语义。原断言旧反向语义的用例已改为新语义（修复后旧用例本会变红）。
- **备注**：纯源码守卫自动验收，无需真机；视觉差异由用户观感确认即可。
