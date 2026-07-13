## BUG-775 · macOS 自动/MD3 仍套原生侧栏形成双壳
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
- **[x] ① 已修复** — `be3693f31` 让 `auto` 在五个平台统一解析为 MD3；
  `63b12d03b` 将隐藏的 Cupertino/macOS/未知持久值迁移为 `auto`；`3593b3647`
  让根 `MacosWindow` 与 `HomePage` 共用 `isMacosPlatform(context)` 门控，默认 MD3
  不再创建最外层 macos_ui Sidebar。`f644ffec6` 让 adaptive route 必须携带主题上下文，
  避免显式隐藏 renderer 的测试能力被物理平台误判；`7413d0e50`、`33f45dbee` 用数据库
  CAS 与本地 revision 守卫迁移旧值，旧异步重读不会覆盖用户刚做出的新选择。
- **[x] ② 已加自动化测试** — `61b67684d` 与 `3593b3647` 覆盖五平台 auto 矩阵、
  缺失 extension、旧值加载/刷新持久迁移、设置入口隐藏，以及 macOS 根壳的负向守卫。
  另有确定性并发屏障测试覆盖 migration reload 与 setter 交叠。2026-07-13 最新相关数据库/
  ThemeNotifier 回归 84/84 通过，定向 analyze 零问题，最终只读复审无 Critical/Important。
- **备注**：Cupertino/macOS renderer 仅保留为隐藏内部能力。真实 macOS debug 构建
  到达 `[Hibiki] init: DONE`；窗口证据 `/tmp/hibiki-md3-window-20260713.png` 已人工检查，
  只剩 MD3 应用内导航，用户指出的最左侧原生栏/边框已消失。
