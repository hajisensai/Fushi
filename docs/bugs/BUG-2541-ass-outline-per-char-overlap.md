## BUG-2541 · ASS 描边逐字叠画啃进相邻字填充、细描边被夹下限（字重随窗口变）
- **报告**：2026-09-14（Discord 用户 moonbeam：「the main sub's font weight seems to change with the window size」，主对白为斜体带描边的常规 fansub 样式）
- **真实性**：✅ 真 bug，两处。① 尊重 .ass 时每个字符各自 `Stack(描边 Text, 填充 Text)`（`video_subtitle_overlay.dart` `_buildSubtitleChar`），后一个字的描边画在前一个字的填充**之上**；斜体 / 紧排 / 负字距时相邻字形重叠，黑描边啃进前字的白填充，笔画看着变粗，重叠量随字号与亚像素位置变——窗口一缩放「字重」就跟着变。libass 先合成整行描边位图再叠整行填充位图。② `_resolveStroke` 把缩放后的描边宽 `clamp(0.5, 24)`，小窗口里 Outline 随字号一起缩小的作者意图被下限截断，描边相对字身越缩越粗。
- **[x] ① 已修复** — `_buildCueBox` 对确有描边的 cue 整行两遍绘制：描边遍（含 `\shad` 阴影 / `\blur` 辉光）整行垫底、填充遍整行压顶，两遍同样式同约束几何同构，命中登记 / 查词高亮 / 光标环只在填充遍；`\bord0` 全行或无描边基线仍单遍（零差异）。描边宽只夹上限 24（`math.min`），细描边照实缩放。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_subtitle_outline_two_pass_test.dart`（树序 = 绘制序：3 字的描边层全部先于填充层，且同字两遍矩形重合；显示高 200 / PlayResY 1080 下 Outline 0.3 → stroke 0.111 不被抬成 1.0）；`video_subtitle_span_scale_test.dart` 同步为两遍期望。
- **备注**：默认外观（不尊重 .ass 的柔和投影）仍单遍，投影是半透明软边、跨字叠加不可辨；如日后有报告再收进两遍路径。
