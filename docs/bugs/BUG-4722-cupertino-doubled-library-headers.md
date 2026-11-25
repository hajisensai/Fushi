## BUG-4722 · Cupertino 下外壳标题条与库页页头大字重复显示页名
- **报告**：2026-11-16（应用内反馈 4s8SaBMfyY，iOS 3.3.0-debug.27417 截图：视频库顶部先一行小字「Video」，下面又一行带徽标的大字「Video」）
- **真实性**：✅ 真 bug。外壳给 tab 的页面名（`homeShellTitleFor`，经 `FushiShellTitleScope` 下发）同时被两处画：
  - 库页根 overlay `masthead: true`，重设计外壳（`shellRedesignActive`，非墨水屏恒真，含 Apple）下页头大字用它画页名行：`fushi/lib/src/utils/components/fushi_floating_chrome.dart:852`（`mastheadLayer`）、`:1800`（取 `shellTitle` 当页名）。
  - 外壳大标题条 `_buildShellTitleBar` 也画它：`fushi/lib/src/pages/implementations/home_page.dart:1763`（修复前为 `_shellTitleFor`）。MD3 下库页 tab 的外壳条从不按行摆（`home_page.dart:1697` `overlayTitle = !apple && …`，窄窗不叠、宽窗并进工具栏行），所以没露出来；Apple 下外壳条恒在内容上方按行画，于是同名两行。
  - 分诊建议「让 `homeShellTitleFor` 对库页返回 null」不可取：页头大字的页名就取自这个下发值（`test/pages/home_shell_title_compact_test.dart` 也钉着库页必须非 null），返回 null 会让页名整行消失 / 退回 `video_library_shell.dart` 的兜底名。
- **[x] ① 已修复** — 把「外壳下发的页面名」与「外壳条自己画的页名」拆成两个判据：新增 `homeShellBarTitleFor`（`home_page.dart:4644`），重设计外壳下挂页头大字的库页 tab（书 / 漫画 / 视频 / 游戏 / 音乐 / 浏览 / 浏览器；串流接收形态的游戏库是普通页头除外）返回 null，其余与 `homeShellTitleFor` 一致。外壳条标题、Apple「后台任务」bar button 与 `_backgroundTasksHostedByChrome` 都改取这一份，外壳条不画时入口退回右下 FAB、不丢。MD3 行为不变。
- **[x] ② 已加自动化测试** — `fushi/test/pages/home_shell_bar_title_masthead_test.dart`（修复前 2/5 红：`Expected: null Actual: 'Books'`、后台任务入口 `Expected: false Actual: true`）；`fushi/test/pages/home_scrape_entry_placement_test.dart` 源码守卫改钉 `_shellBarTitleFor` 同源。
- **备注**：未在 iOS 真机 / 模拟器复测原始截图路径（本机 Windows）；Apple 下库页顶部改由页头大字独占，与 MD3 窄窗同一版面。
