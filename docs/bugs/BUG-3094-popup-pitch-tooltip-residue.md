## BUG-3094 · 视频查词弹窗词典名提示框残留关不掉
- **报告**：2026-10-09（用户：视频查词弹窗里鼠标悬停「N 本辞典」后出现的「NHK, アクセント辞典, 大辞林第四版…」提示框残留在画面上关不掉）
- **真实性**：✅ 真 bug（代码路径确认，未在真机复现截图之外的场景）。根因 `fushi/assets/popup/popup.js` `createPitchGroup`：音调合并行的「N 本辞典」药丸用原生 `title` 显示来源名单。Windows WebView2 的原生 title 提示是独立的 Win32 顶层弹窗，不属于文档；视频页查词浮层关掉 / 热槽 WebView 被藏起时它不随文档消失。
- **[x] ① 已修复** — 改为 `data-sources` + `aria-label`，悬停提示由 popup.css `.pitch-dict-count[data-sources]::after` 画在文档里，随文档一起消失；点击展开来源药丸不变。提交 `b18d1207ab`（PR `pr/dict-popup-style`）。
- **[x] ② 已加自动化测试** — `fushi/test/pages/popup_pitch_merge_identical_test.js`（断言无 title、data-sources / aria-label 为来源名单）、`fushi/test/pages/popup_dict_style_1009_guard_test.dart`。
- **备注**：词典结构化内容自带的 `title`（词典作者写的悬停说明）仍是原生提示，本次未动。
