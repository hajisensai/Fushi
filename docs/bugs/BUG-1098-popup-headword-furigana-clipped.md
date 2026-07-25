## BUG-1098 · 查词弹窗词头的假名（furigana）被垂直压扁 / 裁掉
- **报告**：2026-07-26（用户：查词弹窗上面那个词的注音被削掉一截，有的词好好的，有的词只剩半行）
- **真实性**：✅ 真 bug（两条并列根因，缺一不成立；沿 popup.css / popup.js 真实渲染路径验证）
  1. **词头零垂直预留**：`hibiki/assets/popup/popup.css:241-244` 的 `.expression rt { font-size: 13px }` 是词头注音的**全部**样式——没有 `line-height`、没有 `padding-top`、没有定位，读音直接溢出 `.entry-header` 的行盒。词头 ruby 由 `hibiki/assets/popup/popup.js:575-587` `buildFuriganaEl()` 造成**裸** `<ruby>/<rt>`（不带任何 class），因此也进不了 `popup.js:3114` `postProcessRuby()`——它当年只扫 `.glossary-content ruby`。释义正文早在 BUG-108/363/722/850 就拿到了 zoom 免疫的 em 预留（`popup.css` 的 `.ruby-unit{line-height:1;padding-top:0.55em}` + 绝对定位 `rt{top:0;font-size:0.5em}` + `.ruby-reserve` 横向孪生），而 `docs/bugs/BUG-108.md:4` 明写「headword 仍走自己的 `.expression rt`，不受影响」——词头是当年主动划出范围的。
  2. **溢出方向不可达**：`hibiki/assets/popup/popup.css:180-196` 的 `.expression-scroll{overflow-x:auto;scrollbar-width:none}`。CSS 规范下一轴非 `visible` 会把另一轴 computed 成 `auto`，该盒于是成为滚动容器；而滚动容器的**顶部**溢出永远够不到（`scrollTop` 不能为负），溢出的注音是被永久 **CLIP**，不是「可以滚过去」。`docs/bugs/BUG-775-ext-expression-scroll-scrollbar.md:10` 当年写的「保留 overflow-y:auto，注音溢出几像素仍可滚不裁切」**是错误结论**，本条已在该文件与 `popup.css` 注释里更正。
  - **为什么只有部分词被削**：`popup.js:586` `return segments.length === 1 && segments[0][1];` → `popup.js:2420-2426` 只在 `needsScroll` 为真时才套 `.expression-scroll`。单段带注音 = 纯汉字词（気配 / 邂逅 / 逢瀬），正是 galgame 高频查的名词；`食べる` 这类切两段的不套 wrapper，故不裁。
- **[x] ① 已修复** — 见本分支提交（不引入新机制，把词头并入释义体那套已验证的 per-base 单元）：
  - `hibiki/assets/popup/popup.js:3114` `postProcessRuby()` 选择器扩到 `'.glossary-content ruby, .expression ruby'`，词头 ruby 也拿到 `.ruby-unit` 包装 + `.ruby-reserve` 横向零高孪生（读音比汉字宽时不再侧向压邻字）。
  - 同函数加幂等门：已是 `.ruby-unit` 的 base 跳过。`renderPopup` 先 `postProcessRuby(firstEntry)` 再 `postProcessRuby(container)`（container 含 firstEntry），首词条本来会被走两遍、套出双层 `.ruby-unit` 叠两份 `padding-top`——这条既有隐患顺带堵上。
  - `hibiki/assets/popup/popup.css`：`:where(.glossary-group, .glossary-content)` 的 `ruby` / `.ruby-unit` / `rt` / `.ruby-reserve` 四条作用域各加 `.expression`；`.expression rt` 只留 `-webkit-user-select:none`（词头是 `onLinkClick` 点击目标）。删掉的 `font-size:13px` 等价于 `.expression`（26px）的共享 `0.5em`——像素不变，但从此随 `popupContentZoom` 等比缩放，不再让溢出量随 zoom 线性放大。
  - `.expression-scroll` 保留 `overflow-x:auto`（长词头仍要能横滚）；注音不再溢出，隐式 `overflow-y` 自然无害。注释已更正 BUG-775 的错误判断。
  - 三镜像同步：`hibiki/assets/browser_extension/vendor/{popup.css,popup.js}`、`tools/browser-extension/vendor/{popup.css,popup.js}` 复制到位，并重跑 `node tools/browser-extension/scripts/generate-content-css.mjs` 重新生成两份 `content.css`。
    - **勘误（本 PR 审查修复）**：首版提交里这两份 `content.css` 其实是漂移版本（各多出 15 行空行），`--check` 报 OUT OF SYNC——上面原写的「`--check` 已通过」当时并不属实。已重跑生成器重新生成并提交，两份产物 md5 一致且 `node tools/browser-extension/scripts/generate-content-css.mjs --check` 现报 in sync。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/popup_headword_ruby_reserve_bug1098_test.dart`（8 例全绿）：
  - 四条共享 ruby 规则的 `:where(...)` 作用域必须同时含 `glossary-group` / `glossary-content` / `.expression`；
  - 预留必须是 em `padding-top` + `line-height:1`，`rt` 必须 `position:absolute` + `top:0` + em 字号；
  - `.expression rt` 不得再声明 px 字号（`(0,1,1)` 会盖掉零特异性的 `:where(...) rt`），但必须保留 `user-select:none`；
  - `postProcessRuby` 选择器含 `.expression ruby`，且对已包好的 base 幂等；
  - 三镜像 `popup.css` / `popup.js` 字节一致，两份 `content.css` 确实带上 `.expression` 作用域（既有 parity 守卫只收集以 `.` 开头的选择器，`:where(...)` 规则漏在它的网外，这里补齐）。
  - 既有 `hibiki/test/pages/popup_glossary_ruby_lineheight_guard_test.dart`（释义体）与 `hibiki/test/build/browser_extension_popup_parity_guard_test.dart`（三镜像）同批跑通，无回归。
- **备注**：ruby 几何在无头环境渲染不出来，守卫的是规则存在与作用域；**词头注音的最终观感仍需真机肉眼复测**（Windows 悬浮查词窗 + 浏览器扩展各一次）。
  另：`hibiki/windows/runner/global_lookup_window.cpp:1055-1069` 的 composition 路径设了 `put_RasterizationScale(dpi/96)` + `put_ShouldDetectMonitorScaleChanges(FALSE)`，而 windowed 回退路径 `:1126-1183` 两项都没设、全文也没有 `WM_DPICHANGED` 处理——多屏 / 非 100% 缩放下亚像素取整误差会被放大。这是**放大器不是根因**（本次 em 预留后即便有取整误差也只是几分之一像素的位移，不会再裁掉整行），且改动涉及 WebView2 控制器生命周期 + 必须 AMD/多屏真机验证，本轮不动，另开跟进。
