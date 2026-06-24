## BUG-421 · 明鏡第三版 styles.css @media at-rule 被作用域前缀污染导致整块失效
- **报告**：2026-06-25（用户：TODO-812）
- **真实性**：✅ 真 bug，根因 `hibiki/assets/popup/dict-media.js:46`（`constructDictCss` 把第一个 `{` 之前的整段当选择器列表逐个加 `[data-dictionary="X"]` 前缀，对 `@media (max-width: 500px)` 这类 at-rule 前言也照加，产出非法的 `[data-dictionary="X"] @media (...) { ... }`，浏览器丢弃整个 @media 块）。明鏡第三版 styles.css 唯一 at-rule 是 `@media (max-width: 500px)`（gaiji 图响应式宽度），故该词典图片在窄屏尺寸样式失效；Hoshi-Reader-Android 在对应位置用「外层块 + CSS 原生嵌套」注入 dictStyle，at-rule 不被破坏，故同一本明鏡显示正常。

  连带证伪（非 bug，不改）：
  - CJK data-key 展开：`カナ`→`data-scカナ`（popup.js:1352 `isCJK?'':'-'` 特例去连字符），与 Hoshi-Android 完全一致；明鏡 styles.css 的 `[data-sc-カナ]`（带连字符）那条仅 `font-size:1.2em`，两边都不命中、影响轻微，且改动会破坏该特例本要修的 daijisen，偏离基准——不动。
  - gaiji 图字段：明鏡 structured-content img 节点是标准 `{tag:"img", path:"gaiji/...svg"}`，`createDefinitionImage`（popup.js:790/888）读 `path` 正确；`data.src` 只是数据属性不是图源——不动。
- **[x] ① 已修复** — `hibiki/assets/popup/dict-media.js` `constructDictCss` 识别 at-rule：条件组（@media/@supports/@container/@layer/@scope）前言原样保留、对内部规则递归加前缀；其它 at-rule（@font-face/@keyframes/@page）整块透传不前缀；语句型 at-rule（@import/@charset/...）原样输出。单点修复覆盖全部 5 个调用点（popup.js:597/719/2078/2210、definition.js:503）。
- **[x] ② 已加自动化测试** — `hibiki/test/utils/misc/popup_dict_css_atrule_scope_test.js`（node 行为：喂明鏡真实 @media 片段断言前言不被污染/内部仍作用域化/普通选择器无回归/@keyframes·@font-face 体不前缀/@import 透传/CJK data-key 契约）+ `hibiki/test/utils/misc/popup_dict_css_atrule_scope_test.dart`（拉起 node + 源码级守卫，CI 无 node 也守住）
- **备注**：最终显示需用户真机（明鏡导入后查词）验收 @media 窄屏图片样式生效；headless 已证 CSS 生成端正确。
