## BUG-5073 · 切 Profile 后统计日界仍按旧 Profile 的值直到重启
- **报告**：2026-11-21（审查外部 PR #3980 时发现：它新增的随 Profile 偏好 `stats_week_start` 照抄日界的镜像做法，切 Profile 后同样不生效；追下去日界本身在 develop 上就有这个问题）
- **真实性**：✅ 真 bug（沿代码路径核实，未在设备上复现）。`stats_day_reset_hour` 不在 `ProfileKeys._excludedPrefKeys`，随 Profile 快照切换；进程里真正生效的是镜像 `FushiDatabase.statDayResetHour`，只在 `AppModel._applyStatDayResetHour()`（`fushi/lib/src/models/app_model.dart:13274`）里写，调用点只有主进程 / 弹窗进程初始化与 `setStatDayResetHour`。切 Profile 的路径 `profileViewModelProvider.onApplied` → `AppModel.refreshPrefCache()`（`app_model.dart:6189`，修复前）只 `prefsRepo.refreshFromDb()`，不重新镜像：新 Profile 的「今天」、统计窗口与新写入的统计日 key 一直按旧 Profile 的日界，直到重启。`:popup` 的 `refreshPrefCacheIfChanged` 也走同一函数。
- **[x] ① 已修复** — `refreshPrefCache()` 在 `refreshFromDb()` 之后调 `_applyStatDayResetHour()`（偏好缓存每次整体重载都重新镜像；#3980 若合入，它的 `StatWindow.weekStartDay` 挂在同一个 apply 函数里，随之生效）。
- **[x] ② 已增加自动化测试** — `fushi/test/models/stat_day_reset_hour_refresh_guard_test.dart`：源码扫描钉死 `refreshPrefCache` 方法体在 `refreshFromDb()` 之后调 `_applyStatDayResetHour()`（`refreshPrefCache` 碰没初始化的媒体源 / 主题 / Anki 后端，宿主单测驱动不了，`app_model_pref_refresh_gating_test` 同样整段覆写）。去掉修复即红。
- **备注**：设备上「两个 Profile 设不同日界 → 切换 → 看今日统计」的复测没做。
