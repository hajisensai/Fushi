## BUG-3249 · 首页头像只在初始化读一次 Profile 名且吞掉排行榜刷新异常
- **报告**：2026-10-10（PR #2030 审查遗留疑点）
- **真实性**：✅ 真 bug。`_HomeAvatarPill` 只在 `initState` 里读一次激活 Profile 名（`fushi/lib/src/pages/implementations/home_dashboard_page.dart:203`），首页常驻，改名或切换激活 Profile 后首字圆 / 无障碍名一直是旧的；`refreshSelf` 的失败被 `onError: (Object _) {}` 静默吞掉（`home_dashboard_page.dart:222`），违反「禁止吞异常」。
- **[x] ① 已修复** — 订阅 drift `tableUpdates`（`profiles` + `preferences` 两表：改名 / 导入 / 删除，以及切换激活写 `active_profile_id`），每次写入重读名字，带代次防乱序、名字真变才 setState，dispose 时取消订阅；`refreshSelf` 失败记进 `ErrorLogService`（`HomeAvatarPill.refreshSelf`），UI 照旧退回首字圆。提交 fix(home): keep the avatar pill in sync with profile renames and switches
- **[x] ② 已加自动化测试** — `fushi/test/pages/home_dashboard_page_test.dart`「BUG-3249 头像跟随 Profile 改名与切换」（修复前红）。
- **备注**：没有直接 watch `profileViewModelProvider`：首页先于设置页建它会提早触发 `ensureDefaultProfile` 写库，且要求 Anki / 平台服务装配齐全；表级变更流是 BUG-3148 已采用的同一真相源。
