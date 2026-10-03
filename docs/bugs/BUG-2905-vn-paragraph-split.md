## BUG-2905 · VN 模式同一段落被切成两屏（悬挂标点 / 切点禁则）
- **报告**：2026-10-03（用户：iOS 竖排 VN 读『やはり俺の青春ラブコメはまちがっている。』，「そう思ったのは俺だけではないらしく」独占一屏，下一屏以「、庇護欲をそそる姿に…」开头；要求 Windows 与 Mac 都验证）
- **真实性**：✅ 真 bug，两个根因：
  1. **WebKit 悬挂标点（iOS / macOS）**：正文 CSS `fushi/lib/src/reader/reader_content_styles.dart:532` 的 `hanging-punctuation: allow-end`（仅 WebKit 实现）让行尾「、」悬出列底；VN 屏盒 `.fushi-vn-screen` 在行内方向末端 `overflow: hidden`、没有余量，切屏量尺 `renderedTextFitsBounds`（`fushi/lib/src/reader/reader_visual_novel_scripts.dart:1583`）如实判「、」溢出 → 二分 `splitScreenToViewport`（同文件 `:1610`）退到「、」之前。于是一屏本装得下的段落被切成「…らしく」+「、庇護欲…」。真书（part0035，393×852、40px 竖排）在 Playwright WebKit 上复现：全章 281 屏里 24 屏以「、」「。」开头；Chromium 同条件 262 屏。
  2. **切点不避禁则（全平台）**：段落真装不下时，二分只认「装得下」，切点落在哪个字上全凭运气——段落恰好多出一个「。」就切出孤零零的「。」屏，「…しょうな！」」切成「…しょうな！」+「」」。Chromium（Windows WebView2 同内核）同一章仍有 2 屏这样开头。
- **[x] ① 已修复** — ① VN 布局 CSS 给 `.fushi-vn-content, .fushi-vn-content *` 加 `hanging-punctuation: none !important`（只作用于 VN，翻页 / 滚动仍保留悬挂）；② `splitScreenToViewport` 定下切点后经 `viewportSplitKinsokuBoundary` 只往回退：下一屏不得以行首禁则字开头、本屏不得以开括号收尾（与 `line-break: strict` 同一套禁则，做法同「追い出し」）；退过本屏起点仍无合规切点（连续禁则字比一整屏还长）时放弃禁则、用二分的最宽切点，不退到每屏一个字。修复后 WebKit 与 Chromium 都是 262 屏、0 屏以禁则字开头，目标段落同屏，逐屏拼回与整章源文一致。
- **[x] ② 已加自动化测试** — `fushi/test/reader/vn_split_kinsoku_behavior_test.dart`（CSS 生成器断言 VN 规则存在且排在正文规则之后；node 真跑生产切点方法，七组切点用例）+ 真书探针 `fushi/integration_test/reader_vn_paragraph_split_probe_itest.dart`（真 app 导入真书、VN 逐屏扫描禁则起首 / 越界 / 文本连续 / 目标段同屏，并记录翻页与滚动模式下 `hanging-punctuation` 未受影响）。两条单测都经变异验证能各自抓回归。
- **备注**：
  - 三种 view mode：CSS 规则只命中 VN 的 `.fushi-vn-content`，切点逻辑只在 VN 切屏路径；翻页 / 滚动不经这两处，真书探针在这两种模式下记录正文 `hanging-punctuation` 计算值（WebKit 仍为 `allow-end`）。
  - 逐屏越界检查按非空白字符判：行尾全角空格按规范悬挂出行盒（不可见），按整个文本节点的矩形判会在 Chromium 下误报 2 屏「越出屏底 8px」，修复前后一致，不是正文越界。
  - 真 app 验证（2026-10-03，真书导入 → 竖排 40px → VN 开 part0035，探针 `reader_vn_paragraph_split_probe_itest.dart`）：**macOS**（1440×822）与 **Windows**（1424×919）均 249 屏、0 屏在段中以禁则字开头、0 处正文越出屏盒、逐屏拼回与整章源文一致（9696 字）、目标段「そう思ったのは…声援が飛ぶ。」整段在第 154 屏；macOS 下 VN 内容盒 `hanging-punctuation` 为 `none`、翻页 / 滚动正文仍为 `allow-end`（WebView2 不支持该属性，三种模式均为空）。
