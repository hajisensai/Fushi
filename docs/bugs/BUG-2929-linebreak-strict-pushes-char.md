## BUG-2929 · 正文 line-break strict 让「たった」「コート」把前一个字推到下一列
- **报告**：2026-10-04（用户：两张截图，竖排列尾「た|った」「コ|ート」被整体推进下一列，上一列末尾留空）
- **真实性**：✅ 真 bug。正文 grid CSS 写的是 `line-break: strict`（`fushi/lib/src/reader/reader_content_styles.dart:544`，修复前）。`strict` 与 `normal` 唯一的差别就是 CJ 类（小书き仮名 っャュョ… 与长音 ー）也禁止出现在行首，于是列尾遇到「っ」「ー」时浏览器把前一个字一起推到下一列。日文书籍排版（JIS X 4051 的常规处理与主流电子书阅读器）不把小假名 / 长音当行首禁则。VN 分屏量尺的行首禁则表（`reader_visual_novel_scripts.dart:1674`）也照 `strict` 收了这些字，两边一致地错。
- **[x] ① 已修复** — 正文改 `line-break: normal`；VN 分屏 `lineStartProhibitedChars` 去掉小假名与 ー，与正文同口径（句读点、括号闭合、々 等真行首禁则保留）。（提交见 git log：`fix(audiobook,reader): fold small kana when matching ruby readings; line-break normal (BUG-2928, BUG-2929)`）
- **[x] ② 已加自动化测试** — `fushi/test/reader/vn_split_kinsoku_behavior_test.dart` + `.js`：Node 真执行 VN 分屏禁则，用例 ③ 改为断言「っ」「ー」可落在行首、不再回退切点；同文件在翻页 / 滚动 / VN 三种配置下都跑（3 个测试）。`reader_content_styles_test.dart` 全绿。
- **备注**：三模式：`line-break` 写在三种模式共用的正文 grid CSS 上，翻页 / 滚动 / VN 同一条规则生效；VN 额外由分屏量尺禁则表对齐。三模式下均跑过上面的行为测试；未在真机 WebView 上重放截图那两页（本机无用户那本书）。
