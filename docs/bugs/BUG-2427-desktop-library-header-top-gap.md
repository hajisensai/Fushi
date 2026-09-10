## BUG-2427 · 桌面端库页页头顶部留白过大（手机端修复未同步）
- **报告**：2026-09-10（用户：截图圈出 Windows 书架页窗口标题栏与 tab 行之间的大片空白，「电脑顶端空了好多，没和手机同步修复吗」）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/utils/components/fushi_material_components.dart:1821`（修复前）：`FushiPageHeader` 的 `resolvedTop` 把「页头主位是嵌入的分段 tab 行」这一维**只在窄窗时**纳入判据——
  ```dart
  resolvedTop = narrowWindow && titleWidget != null ? 0 : ... : (narrowWindow ? page : page + 8);
  ```
  BUG-2402（`af61028627`）给手机端归零时写的理由是「Embedded tabs already own a touch-height row」，这条理由与窗口宽度无关，但当时只落在窄窗分支，桌面宽窗继续吃 BUG-376 时代为**纯文字大标题**定的 `spacing.page + 8 = 28`。
  桌面实测叠加：`FushiDesktopTitleBar.height = 32`（`fushi_desktop_title_bar.dart:37`，占真实布局高度）+ 28 多余顶距 + MD3 `TabBar` 自带 13 居中留白 = tab 文字上沿 73px，且后 41px 随 `FushiAppUiScale` 放大（1.25/1.5 时约 92/111）。
  受影响页面 15 个（全部传 `customTitle` 的库页）：书架/漫画书架、视频库、发现、视频资源发现、导入/来源（书·视频）、漫画来源/发现/在线目录、各模块设置分区、下载中心、游戏库/导入/首页/工作台/诊断。查词页、浏览器扩展页、全局设置页走纯文字 `title` 分支，不受影响也不应受影响。
- **[x] ① 已修复** — 去掉 `narrowWindow &&` 限定，判据收成「页头主位是 tab 行 → 顶距恒 0」，与窗口宽度无关；纯文字标题的三档不变。桌面 tab 行遂紧接 32px 自绘标题栏，与手机「SafeArea 让出状态栏后紧接 tab 行」同源。真机实测（Windows 离屏 itest）：`tabRow.top=32.0`、`gapUnderTitleBar=0.0`、tab 文字上沿 `44.7`（手机端对应值 47）。提交见本条目所在 PR。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/mobile_navigation_header_spacing_test.dart`：
  - `wide header drops the title margin too`（宽窗 900，tab 行 dy == safe-area inset，即无额外顶距）——**替换**原 `wide header retains its title margin`（`greaterThan(47)`）。那条守卫钉的正是本 bug 的错误写法，不是真不变式。
  - `wide header keeps the title margin for a plain text title`（新增，宽窗纯文字标题仍为 `page + 8 = 28`）——防止这次归零溢出到大标题页头。
- **备注**：本轮只修顶距。左上 `NavRailBrandButton`（64 + 8×2 = 80 高，`nav_rail_brand_button.dart:56`）比右侧 46 高的 tab 行高出一大截，是「左上一个大方块、右侧一片空」观感的另一半成因；缩它要动 `kAdaptiveNavRailWidth`，影响所有页面左侧布局，用户本轮明确选择不做。
