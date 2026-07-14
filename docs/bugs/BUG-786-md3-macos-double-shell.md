## BUG-786 · macOS 自动/MD3 仍套原生侧栏形成双壳
- **报告**：2026-07-13（用户截图；拉取 `hajisensai/hibiki` 最新
  `develop@b177f858b` 后再次要求启动并现场指出最左侧原生边框/侧栏仍存在）
- **真实性**：✅ 真 bug。当前 macOS debug 构建已沿真实路径复现，证据截图为
  `/tmp/hibiki-launch-20260713.png`。
  - **根因 1**：`hibiki/lib/src/utils/adaptive/adaptive_platform.dart:28-77` 在
    `auto` 下仍把 iOS 解析成 Cupertino、把 macOS 解析成 macos_ui（未转换页面还
    回退 Cupertino），违反“所有平台自动均为 MD3”。
  - **根因 2**：`hibiki/lib/main.dart:1431-1474` 只判断裸物理平台
    `TargetPlatform.macOS`，无条件把整个 Navigator 包进
    `MacosWindow + buildHibikiMacosSidebar`，完全绕过设计系统。
  - `hibiki/lib/src/pages/implementations/home_page.dart:628-640` 又正确按
    `isMacosPlatform(context)` 选择内部页面壳；因此 MD3 内层 navigation rail 与
    错误的外层 Apple Sidebar 同时渲染，形成截图中的双壳。
  - **残留根因 3**：移除外层 Apple Sidebar 后，
    `hibiki/lib/src/pages/implementations/home_page.dart` 的 MD3 桌面布局仍在 rail 与
    内容之间硬插入 `VerticalDivider(thickness: 1, width: 1)`；它继承
    `DividerThemeData.color = colorScheme.outlineVariant`，形成用户复验时指出的整高
    1px 左侧边框。
- **[x] ① 已修复** — `be3693f31` 让 `auto` 在五个平台统一解析为 MD3；
  `63b12d03b` 将隐藏的 Cupertino/macOS/未知持久值迁移为 `auto`；`3593b3647`
  让根 `MacosWindow` 与 `HomePage` 共用 `isMacosPlatform(context)` 门控，默认 MD3
  不再创建最外层 macos_ui Sidebar。`f644ffec6` 让 adaptive route 必须携带主题上下文，
  避免显式隐藏 renderer 的测试能力被物理平台误判；`7413d0e50`、`33f45dbee` 用数据库
  CAS 与本地 revision 守卫迁移旧值，旧异步重读不会覆盖用户刚做出的新选择。
  `cb21ebae3` 删除 MD3 rail 外额外绘制的 `VerticalDivider`，导航面与内容面现在无
  Apple 风格侧栏分隔线。
- **[x] ② 已加自动化测试** — `61b67684d` 与 `3593b3647` 覆盖五平台 auto 矩阵、
  缺失 extension、旧值加载/刷新持久迁移、设置入口隐藏，以及 macOS 根壳的负向守卫。
  另有确定性并发屏障测试覆盖 migration reload 与 setter 交叠；
  `cb21ebae3` 又在 `test/macos/macos_shell_static_test.dart`、
  `test/focus/rail_right_enters_content_test.dart` 与真 macOS
  `integration_test/macos_shell_screenshot_test.dart` 增加“无 rail divider”及焦点回归守卫。
  2026-07-13 最新相关数据库/ThemeNotifier 回归 84/84 通过，残留边框修复快速回归 8/8、
  真 macOS 集成 1/1、定向 analyze 零问题，最终只读复审无 Critical/Important。
- **备注**：Cupertino/macOS renderer 仅保留为隐藏内部能力。用户复验旧截图后指出仍有
  rail 右侧 1px 边框，已按残留根因 3 修正；真实 macOS 集成测试到达
  `[Hibiki] init: DONE`，新 framebuffer 截图
  `macos_home_shell.png` 已人工检查：只剩无分隔线的 MD3 应用内导航。
