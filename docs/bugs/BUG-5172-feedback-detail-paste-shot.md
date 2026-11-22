## BUG-5172 · 反馈详情页追加截图只能选相册，没有「粘贴图片」与 Ctrl+V
- **报告**：2026-11-21（用户：应用内反馈 Andv5A4gh6）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/feedback/feedback_detail_page.dart:172`（原 `_addShot`）只走 `pickGalleryImageFile()`；按钮行（原 :333-353）只有「追加截图」「追加视频」，页面也没挂 Ctrl+V。提交页（`feedback_compose_page.dart` 的 `_pasteFromClipboard` / `feedback-paste-image` / `_onKey`）早有剪贴板入口 `readFeedbackImagesFromClipboard`（`feedback_common.dart`），详情页的追加入口没接这套共用能力，两处行为不一致。
- **[x] ① 已修复** — 详情页「取图 → 追加」收成一个 `_appendShots(d, source)`（按剩余截图名额取图再 `addScreenshots`），相册与剪贴板两个来源共用；新增「粘贴图片」按钮（`feedback-detail-paste-shot`，`FushiIcons.paste` + `FushiPressScale`，文案复用 `feedback_compose_paste_image`），没图 / 读失败提示 `feedback_compose_paste_none` / `feedback_compose_paste_failed`；在 `HardwareKeyboard` 上挂 Ctrl / ⌘+V（只认最上层路由、能追加时才收，不吃按键，回复框照常粘贴文字）。快捷键判定抽成 `isFeedbackPasteShortcut`（`feedback_common.dart`），提交页与详情页共用。名额计算抽成 `_shotsUsed` / `_shotRoom`，按钮显隐与粘贴上限同一口径。
- **[x] ② 已加自动化测试** — `fushi/test/feedback/feedback_pages_test.dart` 组「反馈人详情：从剪贴板追加截图」：在 `clipboard_image` 通道打桩，点「粘贴图片」传成下一个截图槽位 s1；剪贴板没图时提示且不上传；Ctrl / ⌘+V 同样追加。去掉按钮 / 快捷键时对应用例红。
- **备注**：无。
