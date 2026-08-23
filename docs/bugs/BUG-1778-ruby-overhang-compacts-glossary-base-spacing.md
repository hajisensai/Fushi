## BUG-1778 · 振假名横向预留拉开正文汉字间距
- **报告**：2026-08-23（用户：）
- **真实性**：✅ 真 bug。`fushi/assets/popup/popup.css` 的 `.ruby-reserve` 是带 `width:max-content` 的 in-flow 隐藏孪生体，会把每个 `.ruby-unit` 从汉字宽度扩到振假名宽度；例如 `体<rt>からだ</rt>` 因三个假名比一个汉字宽而在正文两侧制造明显空隙，与参考图的紧凑正文不同。
- **[x] ① 已修复** — `.ruby-reserve` 改为 `position:absolute` 脱离 inline flow；保留 `.ruby-unit` 的逐基字锚点、`.ruby-rt` 居中和 `padding-top` 纵向预留，让注音允许自然悬出但不再撑开正文。同步 app、浏览器扩展 vendor 与生成的 content.css。
- **[x] ② 已加自动化测试** — 更新 `fushi/test/pages/popup_glossary_ruby_hspacing_guard_test.dart` 和 `popup_ruby_single_scale_guard_test.dart`，锁定 `.ruby-reserve` 必须绝对定位、不得参与正文横向排版。
- **备注**：浏览器安全策略拒绝加载本地 `data:` 对照页，未绕过；按用户此前要求不运行测试或 analyze，以 Windows Debug 构建作编译/打包验证，真实浮窗由用户目测。
