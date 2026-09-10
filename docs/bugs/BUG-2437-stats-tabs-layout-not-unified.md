## BUG-2437 · 统计中心阅读 tab 独有页面级限宽，四个 tab 布局不统一
- **报告**：2026-09-10（用户：「阅读的布局不统一修一下，还是要做成自适应统一布局」「所有界面都要统一」，附四个 tab 的截图）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/pages/implementations/reading_statistics_page.dart:518-520`（修复前）——只有阅读 tab 在 `_buildContent` 外面套了一层 `Center + ConstrainedBox(maxWidth: _kMaxContentWidth /* 1040 */)`，总览 / 观看 / 游戏三个 tab 都是裸 `CustomScrollView`。2000px 宽的桌面窗口上横着切 tab，只有阅读 tab 的时段卡、30 天柱面、会话流缩在中间一条，左右各留一大片空白。顺带查出同一类不统一还有两处：① 顶栏动作行四种排列（总览无「清空」、观看 / 游戏无「目标」）；② 时段卡副行四种形状（游戏 tab 只有「游玩次数」一行，见 [BUG-2438]）。
- **[x] ① 已修复** — 删掉阅读页那层 `Center + ConstrainedBox` 与随之变死的 `_kMaxContentWidth` 常量（`_kWideBreakpoint` 保留：它另有用途，决定「分析」折叠区里今日环与速度摘要是否并排）。宽屏排布交给各区块自己的 `LayoutBuilder`（`buildStatPeriodSummaryGrid` 按实际列宽判两列 / 单列 / 紧凑内边距），不再靠页面级硬上限。顶栏统一成四个 tab 逐颗同形：目标 → 刷新 → 清空全部统计；总览的「清空」= 阅读 / 观看 / 游戏三个域各清一次（`_confirmAndClearAll`）。
- **[x] ② 已加自动化测试** — `fushi/test/pages/statistics_center_static_test.dart` 的 `group('四个 tab 统一')` 三条：四个 tab 文件里都不许再出现 `_kMaxContentWidth`；四个 tab 的顶栏按钮存在且顺序一致；四个 tab 的会话区块都传 `onEdit` / `onClearAll` 且走唯一入口。另有真机像素验收 `fushi/integration_test/stats_center_layout_itest.dart`（播三域事实后逐 tab 抓 `captureFlutterFrame`）。
- **备注**：布局是纯排布，回潮时任何功能测试都不会红，所以守卫必须是源码级 + 像素级两层。改这一片时踩到的两条，记下来省得下次重踩：
  - **会话行的 `trailing` 只有一颗按钮的宽度预算**。往里加第二颗（编辑铅笔）会在 400dp 手机宽下把标题挤回单行省略——正是 BUG-2417 报的那条回归，守卫 `test/pages/stat_session_list_test.dart` 的「长标题排到第二行」当场变红（实测 448dp 才放得下两颗）。所以编辑入口做成**整行 onTap**，不是第二颗图标按钮。
  - **`Scrollable.ensureVisible` 在 `testWidgets` 里必须 `duration: Duration.zero`**。带时长的版本返回「动画结束才完成」的 future，await 它会等不到自己驱动的帧，整条集成测试卡到 8 分钟超时（不带滚动时同一条只要 59 秒）。
