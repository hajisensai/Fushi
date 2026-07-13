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
- **[ ] ① 未修复** — 待让 `auto` 全平台解析为 MD3、迁移隐藏旧值，并让根
  `MacosWindow` 与 `HomePage` 共用 `isMacosPlatform(context)` 门控。
- **[ ] ② 未加自动化测试** — 待增加五平台 auto 矩阵、隐藏持久值迁移与 macOS
  根壳负向守卫。
- **备注**：Cupertino/macOS 实现保留但入口暂时隐藏；修复完成前不得把当前启动
  成功误报成 UI 问题已解决。设备复测需重新构建并确认最左侧原生栏消失。
