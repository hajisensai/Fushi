## BUG-1923 · 查词弹窗静息加号可见位置比同排图标低
- **报告**：2026-08-29（用户：「我感觉制卡弹窗的加号的位置是不是还是低了」——BUG-1895 修完大小后的第二次反馈，这次指的是**位置**不是大小）
- **真实性**：✅ 真 bug，实测偏低 3.5px。Edge headless 4x 像素测量（引完整 `fushi/assets/popup/popup.css` + 真实 `.entry-header > .header-buttons` 结构，同排放一枚 18px 实心方块作几何基准）：18px 基准方块墨迹中心 y=64.00、openInAnki SVG 64.00、favorite SVG 63.75、audio SVG 65.00，而制卡 `+` 是 **67.50**。同时 `getBoundingClientRect` 显示所有按钮盒 `cy` 全是 64.00 —— **按钮盒是精确居中的，偏的只有字形墨迹在 line box 里的位置**。
  根因 `fushi/assets/popup/popup.css:446`（`.mine-button:not(.duplicate) { font-size: 30px }`）：静息 `+` 是文本字形（TODO-1325 应用户要求保留 `+` / `✓` / `✓↩` 文本标记，不走 SVG），BUG-932 起就靠放大 font-size（18px → 24px → 30px）去凑相邻 1em SVG 的可见轮廓。这条路把「可见大小」和「可见位置」绑死在同一个字号上，而字形的垂直位置根本不由布局决定，只由字体度量决定：
  > 墨迹中心相对行几何中心的偏移 = (ascent − descent) / 2 − 数学轴

  逐字体实测（同一探针，只换 font-family）：**Segoe UI Symbol 与 Segoe UI 同为 +0.125em**、DejaVu Sans +0.066em、Roboto ≈ +0.02em、Arial 0.000em。也就是说 Windows 上 `+` 天生就比同排图标低 0.125em，而且**字号越大偏得越多**：24px 偏低 3.0px，BUG-1895 为补大小改到 30px 后变成偏低 3.75px —— 上一轮修大小的同时把偏低量放大了 0.75px，所以用户会说「还是低了」。
- **[x] ① 已修复** — 静息 `+` 不再由字形绘制：`-webkit-text-fill-color: transparent` 让文本只保留语义与盒尺寸，可见的十字改由 `::before` / `::after` 两条以按钮 padding box 为参照 `translate(-50%, -50%)` 绝对居中的矩形拼出（与 `.entry-current .entry-header::before` 的纯 CSS 三角同法，零字体依赖），臂长 0.467em / 臂宽 0.067em（= 30px 下的 14px / 2px，14px 与相邻 favorite SVG 的可见轮廓实测等高；用 em 才跟随弹窗内容缩放）。这样可见大小与可见位置都不再受任何平台字体度量影响。
  **不选「再调一次字号」或「加一个 translateY 常量」的原因**：补偿量随平台实际命中的字体在 0 ~ 0.125em 之间变（Windows 命中 Segoe UI Symbol = 0.125em，Android 兜底 Roboto ≈ 0.02em，Arial = 0），把 Windows 补正就会把 Arial/Roboto 那类本来就居中的字体反向补歪 —— 这是同一个 bug 的第三轮，必须断掉对字形度量的依赖而不是再加一层补偿。
  `font-size: 30px` 保留：它现在只决定按钮盒宽高、进而决定标题行行高，与加号可见大小/位置都无关。修后实测 `+` 墨迹中心 **64.00**（偏差 **+0.00px**）、墨迹高仍 14.00；`getBoundingClientRect` 逐项与修前一致（`entry-header h=44`、`header-buttons h=40`、`mine-button x=341.47 w=28.53 h=40`）=> **零布局变化**。已同步 app 弹窗真源 + 两处扩展 vendor `popup.css` 字节镜像，并重新生成两份 scoped `content.css`（`sync-mirrors.mjs --check` 报「镜像一致 ✓」）。
  提交：`fushi/assets/popup/popup.css` 及其 4 份镜像。
- **[x] ② 已加自动化测试** — `fushi/test/dictionary/popup_mine_button_visual_guard_test.dart` 与 `tools/browser-extension/popup-mine-button-visual.test.js` 双层锁同一组不变式，且**把 `content.css` 一并纳入扫描面**（原守卫只扫 3 份 `popup.css`，抓不到「改了真源忘了重新生成 content.css」）：① 静息块必须 `-webkit-text-fill-color: transparent`（字形不参与呈现）；② `::before`/`::after` 共享块必须齐备 `position:absolute` + `top/left:50%` + `translate(-50%,-50%)` + `background:currentColor`；③ 横臂与竖臂**互为转置**且必须用 `em`（改一条忘改另一条 → 红；改成绝对 px → 红）；④ 静息块本体**不得**出现 `translate/translateY`（锁死「回退成加补偿常量」这条老路）；⑤ JS 侧 `textContent` 仍是 `+`/`✓`/`✓↩` 文本标记。
  **变异实测**：Node 层 6 个变异（删 text-fill-color / 竖臂写成同向 / 删 translate 居中 / 回退 translateY 常量 / 臂尺寸改 px / 只改真源不重生成 content.css）**全部 CAUGHT**；Dart 层独立再验 3 个关键变异**全部 CAUGHT**；每次变异后按 sha256 锚点回滚（不用 `git checkout`），回滚后两层守卫均恢复绿。
  另：`popup_cards_nav_icon_guard_test.dart` #8 的断言（静息块 font-size > 18px）仍成立且保留，但其「靠字号决定加号可见大小」的理由已过时，注释同步改写成「font-size 现在只决定盒宽高/行高」。
- **备注**：
  - 已制卡 `✓`（`.duplicate`，18px）与最新可改 `✓↩`（`.latest`，15px）**未改动**，实测仍分别偏低 1.50px / 1.12px —— 那是同一类字形度量偏差的既有行为，量级远小于加号的 3.5px，且只在制卡后出现，本轮不扩大范围。若后续用户也反馈这两个，同法可解。
  - 验证方式是 Edge headless（Blink）4x 像素测量，与 app 内 WebView2（同为 Blink）渲染栈一致；Android WebView / iOS WKWebView 未真机复测，但本修复的关键正是**让可见结果不再依赖平台字体**，跨端差异面因此收窄而不是扩大。
  - `-webkit-text-fill-color` 在 Blink 与 WebKit 均受支持，覆盖全部目标 WebView（Android WebView / WebView2 / WKWebView）。
