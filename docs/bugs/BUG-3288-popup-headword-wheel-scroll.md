## BUG-3288 · 查词弹窗词头放得下仍可被滚轮纵向滚动
- **报告**：2026-10-12（反馈 #iWrP3Jprt1，Windows：「查词弹窗里面的词头可以被滚轮滚动，即使他位置够」）
- **真实性**：✅ 真 bug，已复现。`fushi/assets/popup/popup.css` 的 `.expression-scroll` 只声明 `overflow-x: auto`，按 CSS 规则另一轴 computed 成 `auto`。注音预留（`.expression` 的 0.66em padding-top）只顾顶部；M3E 词头 `line-height: 1.2` 的行盒比 Yu Gothic UI 的内容区矮，底部溢出。Edge 无头实测（真实 popup.css + m3e-tokens.css，36px 「気配」）：`scrollHeight 69 / clientHeight 67`，computed `overflow-y: auto` → 滚轮可把词头拨动 2px。
- **[x] ① 已修复** — `.expression-scroll` 显式 `overflow-y: hidden`：与 `auto` 同为滚动容器、裁切范围不变（视觉零差异），但不可被用户滚动，滚轮落回弹窗正文；长词头横向滚动不变。三镜像 popup.css 同步、两份扩展 content.css 由 `generate-content-css.mjs` 重新生成。修后同一探针 computed `overflow-y: hidden`。提交 `f504aaf832`。
- **[x] ② 已加自动化测试** — `fushi/test/dictionary/popup_headword_wheel_scroll_bug3288_test.dart`（规则守卫：横向 auto、纵向 hidden，且没有别的 `.expression-scroll` 规则把纵向改回可滚）；三镜像一致由 `browser_extension_popup_parity_guard_test.dart` 守。
- **备注**：字体几何在 flutter test 里渲染不出来，故守卫规则本身；复现证据为 Edge 无头 DOM 探针。
