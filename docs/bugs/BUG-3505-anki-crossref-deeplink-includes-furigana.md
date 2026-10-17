## BUG-3505 · anki-crossref-deeplink-includes-furigana
- **报告**：2026-10-17（用户：Anki 卡片上释义里「See also 歯が立たない」带振假名的跳转链接，点开后 Fushi 查词框里是「歯はが立たたない」，振假名被一起搜了；怀疑别处也有同样问题）
- **真实性**：✅ 真 bug。制卡导出时 `rewriteExportedGlossaryAnchors`（`fushi/assets/popup/popup.js:1436`，三镜像同行）用 `anchor.textContent` 作 `fushi://lookup?word=` 的词，结构化内容链接里的 `<rt>` 读音（以及 `<rp>`、postProcessRuby 克隆的 `.ruby-reserve` 孪生体）全拼进去了。弹窗内点击同类链接早在 BUG-2456 改走 `linkVisibleBaseText`，导出路径漏改。同形漏网点还有 `fushi/assets/popup/definition.js:453-455`（BUG-2456 前的旧写法；`definition.html` 当前在 `lib/` 下无加载点）。其余 `textContent` 用法经扫查均为显示 / 定位用途，不是取查词词条。
- **[x] ① 已修复** — `rewriteExportedGlossaryAnchors` 改用 `linkVisibleBaseText(anchor)`（三镜像 `fushi/assets/popup`、`fushi/assets/browser_extension/vendor`、`tools/browser-extension/vendor` 同步）；`definition.js` 退回可见文本时同样只取基字（本地 `linkBaseText`，同一过滤集）。
- **[x] ② 已加自动化测试** — `fushi/test/anki/exported_glossary_anchor_deeplink_test.js` 场景 H：`<ruby>歯<rp>(</rp><rt>は</rt><rp>)</rp><span class="ruby-reserve">は</span></ruby>が…` 导出后深链必须是 `word=歯が立たない`；变异实测改回 `textContent` 时该场景红（actual 为「歯(は)はが立(た)たたない」）。
- **备注**：已经做好的旧卡片里 href 是制卡时烤进去的，修复只影响此后新制的卡；旧卡需要重新制卡（或在 Anki 里重新生成该字段）才会变正确。
