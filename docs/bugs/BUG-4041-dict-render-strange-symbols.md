## BUG-4041 · 词典释义里出现奇怪符号
- **报告**：2026-11-04（反馈 #dyDC7zou8x，Android Xiaomi 23116PN5BC，3.3.0-debug.23213：「如图所示，红圈内的字符出现了奇怪的符号」。截图第二轮单独导出）。
- **真实性**：✅ 真 bug，与 BUG-4040 同一根因。第一轮因截图未随导出判为未复现；第二轮拿到截图 `dyDC7zou8x_s0.jpg`：词典是 新明解国語辞典 第八版，红圈是词头【漁る】上的表外音訓标记「︽」压在汉字上，被当成了「奇怪的符号」。
  - 标记结构：`<ruby>…<rt><span style="font-size: 2em">︽</span></rt></ruby>`（jitenbot 转换）。
  - 根因与 BUG-4040 相同：`fushi/assets/popup/popup.css:1764` 的 `.ruby-rt rt` 归一只管 `<rt>` 本身，不管它的后代，于是 2em 的 span 长出 0.66em 预留带，盖住基字。
  - 同一截图里「あさり[二]」处的黑底方块是新明解自带的 `rect` 图（单色图片），按词典原意渲染，不是 bug。
- **[x] ① 已修复**（与 BUG-4040 同一提交）— `fushi/assets/popup/popup.css:1778` 规则 `.ruby-rt rt * { font-size: 1em !important }`（限定在 `:where(.glossary-group, .glossary-content)` 作用域内）。
- **[x] ② 已加自动化测试** — `fushi/test/pages/popup_ruby_rt_descendant_scale_guard_test.dart`（与 BUG-4040 共用）。
- **备注**：未在 Android 真机复测。
