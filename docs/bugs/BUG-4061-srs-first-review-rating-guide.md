## BUG-4061 · 首次复习不说明四个评分按钮
- **报告**：2026-11-04（用户：应用内反馈 qQA11YJLQF「第一次复习时解释一下四个评分按钮」）
- **真实性**：✅ 需求成立（功能缺口）。复习页答案栏 `_buildAnswerBar`（修前 `fushi/lib/src/pages/implementations/srs/srs_review_page.dart:2711`）只有评分按钮行，没有任何首次引导。
- **[x] ① 已实现** — 新增 `fushi/lib/src/pages/implementations/srs/srs_rating_guide.dart`：答案面评分行上方一张 `FushiInlineNotice`，四行（或「隐藏困难 / 简单」时两行）按 `srsRatingColors` 配色说明每个按钮，错峰入场；「知道了」持久化偏好 `srs_rating_guide_dismissed`，偏好没就绪时不显示。i18n `srs_rating_guide_*` 经 i18n_sync 加。提交 `8c314354e4`。
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_rating_guide_test.dart`（真实偏好库 + 复习页：答案面出现四行且在评分按钮上方；点「知道了」写偏好、重开不再出现；隐藏困难 / 简单只剩两行；偏好未就绪不显示）。
- **备注**：未做真机 / 桌面肉眼复测。
