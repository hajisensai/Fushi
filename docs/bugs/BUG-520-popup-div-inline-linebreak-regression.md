## BUG-520 · 查词弹窗分行全坏+图标重合（BUG-478一刀切display:inline回归）
- **报告**：2026-07-02（用户：明镜单语的分行坏了，双语的也是，图标还重合了，比之前修复的时候更严重了）
- **真实性**：✅ 真 bug。BUG-478 的修复本身就是根因：`8efea32f6` 在 `hibiki/assets/popup/popup.css` 加的一刀切规则
  ```css
  .structured-content span[class*="gloss-sc-"]:not(.gloss-image-link),
  .structured-content div[class*="gloss-sc-"]:not(.gloss-image-link) {
      float: none !important; position: static !important; display: inline;
  }
  ```
  把 `display: inline` 强加给**所有** `gloss-sc-div`。structured-content 里 `div` 是真实标签（`hibiki/assets/popup/popup.js` renderStructuredContent 对任意 tag 建元素并落 class `gloss-sc-${tagName}`），词典（明鏡单语、双语词典一样）就是靠 div 的 UA block display 分行——author 级 `display:inline` 覆盖 UA 默认值，所有 div 塌成 inline → **分行全坏**；整行内容挤到一行后，行高为 0 的 inline-block 图标容器（`.gloss-image-container` line-height:0）与相邻文本互相侵占 → **图标重合**。`position:static !important` 还杀掉了词典合法的 `position:relative` 字形微调。
  - 家族真正根因（BUG-435 → BUG-478 → 本条共祖）：`popup.js` `setStructuredContentElementStyle` 无白名单，把词典节点自带 inline `float` / `position:absolute|fixed` 原样落到 `element.style`。上游 Yomitan 按 schema 白名单下发样式，这两族属性从不落地；我们两轮都在 CSS 层打补丁，第二轮补丁范围失控炸掉正常布局。
- **[x] ① 已修复** — 修在污染源头，删掉 CSS 补丁：
  - `hibiki/assets/popup/popup.js`：新增 `isFlowEscapingStructuredContentStyle`，`setStructuredContentElementStyle` 应用词典 inline style 前丢弃 `float`/`cssFloat`（任何值）与 `position:absolute|fixed|sticky`（`position:relative` 及其 top/left 偏移不脱离文档流，保留）。
  - `hibiki/assets/popup/popup.css`：删除 BUG-478 的一刀切规则及其 revert 伴随规则；保留窄作用域 `a.gloss-sc-a` 规则（它还兜住词典自带 styles.css 对 `<a>` 的 float/position——BUG-435 的次要成因，且 `<a>` 本就是行内元素零副作用）。
  - 浏览器扩展 vendor 快照（`tools/browser-extension/vendor/popup.js` + `hibiki/assets/browser_extension/vendor/popup.js`，两份受字节一致守卫）同步补同一源头过滤——扩展没吃到一刀切 CSS 所以没炸分行，但同样带着 BUG-478 的源头逃逸。
  - 提交见分支 worktree-fix-popup-div-inline-regression（集成落地后定稿 SHA）。
- **[x] ② 已加自动化测试** —
  - node-vm 行为测试 `hibiki/test/pages/popup_glossary_link_scope_test.js` 重写为新契约：a/span/div 携带 float/absolute/fixed/sticky 渲染后不落 `element.style`（先撤修复验红：`'absolute' !== undefined`，修复后绿）；`position:relative`+top 保留；div 无任何强加 display；**BUG-520 守卫**——遍历 popup.css 全部规则，任何命中裸 gloss-sc-div/span 的规则不得含 `display:inline` 或 `float:none!important`/`position:static!important`；a.gloss-sc-a 规则仍在且不命中图片链接；`.gloss-image-link` 仍由 popup.css 拿 `position:relative`。
  - Dart 源码守卫 `hibiki/test/pages/popup_glossary_link_scope_test.dart`：断言 popup.js（app + 扩展 vendor）带源头过滤、过滤只丢 absolute|fixed|sticky、popup.css 不再含任何 `span/div[class*="gloss-sc-"]` 一刀切选择器。
  - 设备验收 itest `hibiki/integration_test/dict_popup_ctxmenu_glossary_verify_itest.dart` 探针改为调用真渲染管线 `renderStructuredContent`：真引擎 computed-style 断言源头过滤生效、div display=block、两 div 垂直堆叠（分行像素不变量）、relative 保留、裸 div float 不被 CSS 中和、图片链接 position:relative 零回归。
- **备注**：BUG-478 的原始症状（明鏡补足◆行开引号错位）由源头过滤继续修着——该引号 span 的 float/absolute 现在根本不落地。教训：这一族 bug 的修复层级应是数据入口（样式白名单），不是渲染后的 CSS 反补。
