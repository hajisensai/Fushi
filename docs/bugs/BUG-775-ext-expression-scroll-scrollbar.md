## BUG-775 · 扩展弹窗词头旁多出迷你滚动条：标准scrollbar-color继承使::-webkit-scrollbar隐藏失效
- **报告**：2026-07-12（用户：「这个有个多余的滚动条」，截图=词头（語+振假名）右侧、音频/收藏/制卡按钮左边有一个 ▲●▼ 迷你竖滚动条。两张截图（BUG-752 修复前后）都有 → 预存缺陷，非 BUG-752 回归）
- **真实性**：✅ 真 bug。根因三链条（`hibiki/assets/popup/popup.css:172-180` 修复前）：
  1. 词头容器 `.expression-scroll { overflow-x:auto }` —— 按 CSS 规范单轴非 visible 时另一轴 computed 变 `auto` → 该盒子**可竖向滚动**；词头是原生 ruby（注音在基字上方），行盒度量差几像素就竖向溢出 → 出现竖滚动条；
  2. 滚动条本应被 `.expression-scroll::-webkit-scrollbar { display:none }` 藏住，但主题滚动条块在弹窗根上设了标准属性 `scrollbar-color`（**可继承**，传入 .expression-scroll）——Chromium 121+ 规定元素只要有标准 scrollbar 属性生效就**禁用整套 `::-webkit-scrollbar` 伪元素** → `display:none` 失效；
  3. app 内 WebView2 用 Fluent **overlay** 滚动条（静止不可见）侥幸看不到；扩展跑在真 Chrome 经典滚动条模式 → 深色圆 thumb（`--text-color`）+上下箭头按钮渲染成 ▲●▼，挤在 header 按钮左侧。
  - 复现证据：无头 Chrome harness（shadow DOM + 真 content.css + entry-header/expression-scroll/ruby 同构 DOM，`max-height` 模拟真实字体度量下的几像素溢出）→ 按钮左侧出现与用户截图一致的 ▲●▼；计算样式 `scrollbarColor=rgb(...) rgba(0,0,0,0)`（继承已生效）、`overflowY=auto`。
- **[x] ① 已修复** — `popup.css` `.expression-scroll` 增加标准属性 `scrollbar-width: none`（Chromium 121+/Firefox 通用，且不受继承的 scrollbar-color 干扰；滚轮/拖动滚动能力不变，与原 `::-webkit-scrollbar{display:none}` 意图一致）；三镜像同步 + `generate-content-css.mjs` 重新生成两份 content.css。修复后 harness 复测：同样强制溢出下滚动条消失（`offsetWidth==clientWidth`）。提交：见本分支（与 BUG-752 同 PR#56）。
- **[x] ② 已加自动化测试** — `hibiki/test/build/browser_extension_popup_parity_guard_test.dart` 新增通用守卫：扫描 popup.css 里所有 `X::-webkit-scrollbar{display:none}` 隐藏点，断言每个 X 必须同时带 `scrollbar-width: none`，否则报 BUG-775 说明。
- **备注**：词头竖向可滚（overflow-y 派生 auto）本身保留；本修只消灭「可见的多余滚动条」。
  ⚠️ **本条当年写的「注音溢出几像素时仍可滚不裁切」是错误结论，已由 BUG-1098 更正**：滚动容器的**顶部**溢出永远够不到（`scrollTop` 不能为负），溢出到行盒上方的 `<rt>` 是被永久 CLIP，不是「可以滚过去」。这句错误判断正是 BUG-1098「词头假名被压扁/裁掉」拖了这么久没被发现的直接来源。BUG-1098 已把词头 ruby 并入释义体那套 em `padding-top` 预留（`.ruby-unit` + 绝对定位 `rt`），词头不再溢出，本条保留的 `overflow-y` 从此真正无害。用户已装副本已热更（content.css + popup.css 镜像），需 `chrome://extensions` 重载扩展生效。
