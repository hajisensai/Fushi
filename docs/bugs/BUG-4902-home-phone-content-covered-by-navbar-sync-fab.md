## BUG-4902 · 首页（手机）复习卡被浮动导航栏压住、同步悬浮球盖住内容
- **报告**：2026-11-15（用户：拼贴审查设计稿 #home H3「复习卡被浮动导航栏压住，同步悬浮球盖住内容」）
- **真实性**：✅ 真 bug。沿代码路径查：
  1. 同步悬浮球 = 外壳的「后台任务」FAB：`fushi/lib/src/pages/implementations/home_page.dart:4036`（upstream/develop
     行号；`if (_hasBackgroundTasks && !_shellFabHostedByBar) _buildBackgroundTasksFab()`）对首页也无条件画，MD3 手机
     叠在悬浮底栏 FAB 正上方（`_buildBackgroundTasksFab` 的 stacked 分支），后台同步一跑就是十几分钟，正好压在首页
     「今日 / 复习」卡上。
  2. 列表末尾的留白其实已含底栏高度（Scaffold `extendBody` 把悬浮底栏并进 body 的 `MediaQuery.padding.bottom`，
     `_buildRedesignedDashboard` 末尾 `card + bottomInset + homeFabClearance`），滚到底不被盖；「压住」是首屏静止态：
     主块 + 横滑条 + 整宽「今日」大卡把复习卡挤到首屏底，MD3 底栏区域没有渐隐，卡被拦腰硬切在底栏下。
- **[x] ① 已修复** — ① 首页不再挂「后台任务」FAB（`homeBackgroundTasksOnAvatar`，
  `home_background_tasks_scope.dart`）；外壳经 `HomeBackgroundTasksScope` 把数据源与明细入口广播下去，首页头像
  （`_HomeAvatarPill`）外圈画分段进度环（同步中转动）、有失败时右上角红点，有任务 / 失败时点头像打开后台任务明细。
  ② 首屏变短：「继续」改单行等尺寸横滑（H1）、今日 / 复习合成并排两格 104 高小统计块（H2）。③ MD3 手机内容底部
  加渐隐（`homeBottomFadeGradient`：从底栏上沿开始淡、到底栏中线全透明，只落在底栏占的那一段），末尾留白仍是底栏 + 安全区 + 间距。
  提交哈希：收尾阶段统一提交后补。
- **[x] ② 已加自动化测试** — `fushi/test/pages/home_collage_widgets_test.dart`「H3 头像同步状态」组：只有首页由头像
  承载（其余 tab 照旧画 FAB）、任务 → idle / running / failed 状态、底部渐隐的起止位置。
- **备注**：真机像素观感（MD3 手机底栏渐隐、头像外圈环 / 红点）未在设备上复测，收尾阶段补。
- **2026-11-23 修复 ① 被维护者撤回（有意接受的回归）**：拍板台 design-avatar-combo-placement 选方案 a——头像只管
  账户、首页恢复右下「后台任务」FAB（`home_page.dart` 的 `_hasBackgroundTasks && !_shellFabHostedByBar`，不再豁免首页），
  头像外圈环 / 红点与 `home_background_tasks_scope.dart` 删除。维护者在「入口放顶栏动作组」与「照旧右下」之间明确选了
  右下，接受同步期间 MD3 手机上 FAB 叠在底栏上方、可能压住首屏底部卡片。② 首屏变短与 ③ 底部渐隐保留。
