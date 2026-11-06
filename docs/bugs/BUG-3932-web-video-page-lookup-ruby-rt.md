## BUG-3932 · 网页视频页取词混入 ruby 注音 <rt>
- **报告**：2026-11-01（用户：应用内反馈 flt5vvT-5X）
- **真实性**：✅ 真 bug。`fushi/assets/web_video/web_video_page_lookup.js` `scan()` 只取命中文本节点自身（`c.node.data`），不跳过 `<rt>`：悬停注音会查假名，句子被 `<ruby>` 截成单个 `<rb>` 段。
- **[x] ① 已修复** — 3fb26618d9（块内按文档序拼正文、剔除 rt/rp，命中注音不查）
- **[x] ② 已加自动化测试** — `fushi/test/media/video/web_video_page_lookup_js_test.dart`
- **备注**：未在真实站点复测。
