## BUG-478 · 查词弹窗明鏡补足行开引号被inline float/position推到右上角错位(BUG-435同根·非<a>元素未覆盖回归)
- **报告**：2026-06-30（用户：TODO-1022）
- **真实性**：✅ 真 bug。明鏡词典 structured-content 里非 `<a>` 的文本元素（补足◆行开引号「所在的 span/div）携带 inline `float`/`position` 被推到行右上角错位。这是 BUG-435（见 [BUG-435-dict-glossary-link-misplaced.md](BUG-435-dict-glossary-link-misplaced.md)）的回归——当年的 CSS 兜底只命中文本链接 `<a class="gloss-sc-a">`，非 `<a>` 的 span/div 落在作用域之外。
  - 污染源：`hibiki/assets/popup/popup.js:516` `setStructuredContentElementStyle` 无白名单，把词典节点自带 inline `style`（含 `float`/`position:absolute|fixed`）原样落到 `element.style`。
  - 渲染链路：`renderStructuredContent` 在 `hibiki/assets/popup/popup.js:1351-1353` 对任意 tag 建 element 并加 class `gloss-sc-${tagName}`（span 即 `gloss-sc-span`，div 即 `gloss-sc-div`），`node.style` 经 `hibiki/assets/popup/popup.js:1396-1398` → `setStructuredContentElementStyle` 落 `element.style`。
  - BUG-435 兜底缺口：`hibiki/assets/popup/popup.css:1039` 的 `.structured-content a.gloss-sc-a { float:none!important; position:static!important; display:inline; }` 作用域只命中 `<a class="gloss-sc-a">`，明鏡引号所在的 `gloss-sc-span`/`gloss-sc-div` 不被命中 → 再次错位。
- **[x] ① 已修复** — 延续 BUG-435 的纯 CSS 兜底范式，把中和 `float`/`position` 的作用域扩到 structured-content 下带 `gloss-sc-*` 类的 span/div：`hibiki/assets/popup/popup.css:1057-1062`
  ```css
  .structured-content span[class*="gloss-sc-"]:not(.gloss-image-link),
  .structured-content div[class*="gloss-sc-"]:not(.gloss-image-link) {
      float: none !important; position: static !important; display: inline;
  }
  ```
  铁律排除（同 BUG-435 当年顾虑）：①`:not(.gloss-image-link)` 显式排除图片链接（TODO-859/350 图片合法依赖 position/float）；②ruby/rt 用 `<ruby>`/`<rt>` 真标签渲染（class `gloss-sc-ruby`/`gloss-sc-rt`），不是 span/div，本就在选择器之外；③第二条还原规则 `hibiki/assets/popup/popup.css:1063-1072` 把 `.gloss-image-link` 内部、ruby/rt 内部嵌套的 span/div 的 `float`/`position` `revert` 回去，确保图片/振假名内部布局零回归。未动 `a.gloss-sc-a` 行为，未动例句折叠。提交见分支 fix-1022-popup-quote-misplace（集成 owner 落地后定稿 SHA）。
- **[x] ② 已加自动化测试** — node-vm 行为测试 `hibiki/test/pages/popup_glossary_link_scope_test.js`：新增喂 `tag:"span"`（`style.float:right`/`position:absolute`）与 `tag:"div"`（`position:fixed`/`float:left`）structured-content 节点，断言渲染后 class 为 `gloss-sc-span`/`gloss-sc-div`、inline 逃逸样式复现，且被新 CSS 规则中和；反向断言 `.gloss-image-link` 元素 + `<ruby>`/`<rt>` 节点不被新规则命中。Dart 源码守卫 `hibiki/test/pages/popup_glossary_link_scope_test.dart`：断言 popup.css 新规则存在、覆盖 span+div、含 `:not(.gloss-image-link)` 排除、且有 image-link/ruby/rt 还原规则。先撤修复验红（`0 !== 1` exactly one rule）再绿。提交见分支 fix-1022-popup-quote-misplace（集成 owner 落地后定稿 SHA）。
- **备注**：与 BUG-435 同根，仅未覆盖分支（非 `<a>` 元素）。真机弹窗渲染像素验证缺口（bg 环境弹窗截图可能白框）待用户在真实 app 上确认明鏡补足行开引号已回到 inline 流。
