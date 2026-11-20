## BUG-4755 · 原盘正片阶段按返回越级退出整个原盘会话，应先回盘菜单
- **报告**：2026-11-16（用户：维护者自提，应用内反馈 58EoAZOXVN；拍板台 58EoAZOXVN 拍「做」：「我看视频和退出 bd 有鸡毛关系……你根本性修复」）
- **真实性**：✅ 真 bug（层级错位）。原盘会话的层级是「正片全屏 → 正片窗口 → 盘菜单 → 详情页」，但返回链只认两级：
  `fushi/lib/src/media/video/disc/disc_session_controls.dart:96` 的 `resolveDiscSessionBack` 只有「呼出控制栏 / 退出会话」两个出口，
  且 `fushi/lib/src/pages/implementations/video_fushi/disc_menu.part.dart:203` 的 `_discSessionShowBarOnBack` 在正片阶段（`_discSessionSurfaceActive` 为假）直接放行，
  于是 `fushi/lib/src/pages/implementations/video_fushi_page.dart:8632` 的 `_handleBackOrExit` 落到 `_exitVideoPage()`——正片窗口里按 Esc / Android 返回 / 手柄 B / 控制条返回键，
  跳过「盘菜单」这一级直接退出整个原盘会话回详情页（全屏下第一次按退全屏，第二次就整盘退出）。
- **[x] ① 已修复** — `resolveDiscSessionBack` 改成层级表：新增 `DiscSessionBackRoute.returnToMenu`，入参 `onMenu` / `barVisible` / `menuCallAllowed`；正片阶段返回回盘的顶层菜单（BD `bd_menu_call` / DVD Root 菜单），盘不允许调菜单（UO 屏蔽 / 无顶层菜单）时才退会话。页面侧 `_discSessionBackRoute` 单点取判据，`_discSessionReturnToMenuOnBack` 接进 `_handleBackOrExit`（全屏路由里的返回仍只退全屏，不越级）；菜单调用被盘拒绝时按层级表下一级退出会话并记日志。`_exitDiscSession`（按住退出 / Cmd+W / 「退出原盘」）设 `_discSessionExitRequested` 后不经回菜单这一级。提交见分支 `dec/bd-esc-layered-back`。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/disc/disc_session_controls_test.dart`（层级表：正片 → 回菜单、盘禁菜单 → 退出、菜单阶段原语义）；`fushi/test/pages/video_disc_session_wiring_guard_test.dart`（`_handleBackOrExit` 里回菜单在退页之前、全屏路由不回菜单、判据取 `videoDiscMenuKeyAllowed`）。
- **备注**：真机 / 实盘复测未做（本轮不做真机验证）：待在 Windows 实盘上验「正片全屏 Esc → 退全屏 → Esc → 回盘菜单 → Esc 呼出控制栏 → Esc 退出」。
