## BUG-1655 · 查词浮窗振假名显示过小（疑双重 0.5em 缩放）
- **报告**：2026-08-15（用户：截图，视频页查词浮窗「練習」词头上的「れんしゅう」与 glossary 逐字振假名都显得偏小；追问「是不是界面大小、字体大小没吃」）
- **真实性**：❌ **未复现（代码无缺陷）**。两条怀疑都沿真实路径核到底，都不成立；真实原因是设计值本身偏小，已按用户要求作为产品调整放大（见 ①）。

  **怀疑 A：双重 0.5em 缩放 → 不成立。** 最初怀疑 `rt { font-size: 0.5em }` 与 `.ruby-rt { font-size: 0.5em }` 两级相乘成 0.25em，并用 Edge headless 探针"测到" `getComputedStyle(rt).fontSize = 6.5px`。**那个测量是错的**——探针只把 popup.css 的 934–1010 行拼进页面，而抵消这层缩放的 `:where(…) .ruby-rt rt { font-size: 1em }` 在 1034 行，被截在提取范围外。用完整 popup.css 重测（`git show HEAD:…`，HEAD = `5e2763c907`）：

  | 场景 | base | `.ruby-rt` 盒 | `rt` | rtW / reserveW / unitW |
  |---|---|---|---|---|
  | 词头 `.expression` | 26px | 13px | **13px** | 26.0 / 26.0 / 26.0 |
  | glossary 逐字 ruby | 16px | 8px | **8px** | 16.0 / 16.0 / 16.0 |

  `rt` 恰为 base 的 0.5em，三个宽度完全对齐。BUG-1487（`4abd13f715`）把注音定位盒挪到 `<span class="ruby-rt">` 时，**同一个提交**就补了 `.ruby-rt rt { font-size: 1em }`，从一开始就防住了双重缩放。

  **怀疑 B：界面大小 / 字体大小没吃到 → 不成立。** 浮窗缩放走 `document.documentElement.style.zoom = 界面大小 × 词典字号/16`（`DictionaryPopupWebViewState.popupContentZoom`，A−/A+ 与 Ctrl+滚轮共用 `__fushiPopupZoomStep`）。CSS `zoom` 等比缩放一切，汉字与假名同步放大，比例恒为设计值，不存在"越调越小"。**用用户原图像素复核**：假名墨迹带 y=367–383（17px）、汉字墨迹带 y=390–425（36px），比 0.47；假名墨迹约占字号 0.72、汉字约 0.88，故 0.5em 字号比对应的墨迹比正是 0.41–0.47 —— 与实测吻合，缩放链完好。
- **[x] ① 已按产品需求调整** — 非缺陷修复，是用户要求的尺寸调整：振假名 `0.5em → 0.6em`。四个值必须同步，缺一个就出几何 bug：
  - `.ruby-rt` `font-size: 0.6em` —— 尺寸的唯一真实来源；
  - `:where(…) rt` bare fallback 同值 —— postProcessRuby 没包裹到的裸 `<ruby>` 走这条；
  - `.ruby-reserve` 同值 —— in-flow 孪生体，宽度预留必须等于实际渲染宽度（BUG-850），分叉会撑开汉字或让相邻注音重叠；
  - `.ruby-unit` `padding-top: 0.55em → 0.66em` —— 上方预留带（≈ 字号 ×1.1），不抬高的话 0.6em 的注音会顶出预留带撞上一行（BUG-108/363）。

  Edge headless 实测改后几何：词头 rt 15.6px、rtW=reserveW=unitW=31.2 三者对齐、预留带 17.2px > 盒高 15.6px 不溢出；glossary rt 9.6px、19.2/19.2/19.2 对齐。逐字 ruby 行内容宽 120→137.6px（+15%，放大注音必然同比撑宽汉字占位，0.7em 会到 +29%，故取 0.6em）。已按三镜像纪律同步两份 vendor popup.css 并重跑 `generate-content-css.mjs`（三份 popup.css 与两份 content.css 各自 byte-identical）。
- **[x] ② 已加自动化测试** — `fushi/test/pages/popup_ruby_single_scale_guard_test.dart`（5 条）+ 改造既有 `popup_glossary_ruby_hspacing_guard_test.dart`。要点是**锁不变量而不是锁字面量**：振假名倍率是可调产品值，所以守卫不再硬编码 `0.5em`（旧 hspacing 守卫就是这么写的，会随产品调整误红），改为锁死四者的关系——注音盒字号必须是 em；bare fallback 与 `.ruby-reserve` 必须**等于**注音盒；`.ruby-unit` 预留带必须 **>=** 注音盒字号；以及任何会落到被 `.ruby-rt` 包裹的 `<rt>` 上的字号都必须有归一化规则抵消（防双重缩放回归——这条契约此前无测试覆盖）。

  变异实测三轮，全部精确捕获并指名违规值：① 删掉 `.ruby-rt rt { font-size: 1em }`（重现真正的双重缩放）→ 红；② 只调注音盒、预留带留在 0.55em → 红（报「预留带 0.55em 必须 >= 注音盒 0.6em」）；③ 只调注音盒、`.ruby-reserve` 留在 0.5em → 新旧两条守卫同时红。每轮还原后 sha256 与变异前一致。
- **备注**：Ruby 几何无法 headless 渲染，几何证据取自 Edge headless（与 Windows WebView2 同 Blink 引擎）的 `getComputedStyle` + `getBoundingClientRect`。**教训**：拿源码片段拼探针时，被截掉的规则会让测量结果看起来完全可信却完全错误——要么引完整样式表，要么先确认相关选择器全在提取范围内。想再调大到 0.7em：改 popup.css 那四个值（0.7em ×3 + padding-top 0.77em），同步两份 vendor popup.css，重跑 `generate-content-css.mjs`，守卫无需改动。
