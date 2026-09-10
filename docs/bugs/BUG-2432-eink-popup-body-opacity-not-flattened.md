## BUG-2432 · 墨水屏弹窗只压了按钮 opacity，正文侧十几处静息半透明与亚像素位移漏网
- **报告**：2026-09-10（用户：「查词框显示发虚」，与 [BUG-2430](BUG-2430-reader-lookup-popup-loses-eink-theme.md) 同一条报告）
- **真实性**：✅ 真 bug —— 根因 `fushi/assets/popup/popup.css` 的 `html.eink` 覆盖块：它的通配压平
  规则只覆盖 `border-radius` / `box-shadow` / `text-shadow` / `transition` / `animation`，opacity 那条
  单独规则**只列了顶部四个动作按钮**（`.audio-button` / `.favorite-button` / `.open-anki-button` /
  `.mine-button`，注释写的是「静息态 0.5 opacity 在墨水屏上是抖动灰」）。
  但同一份 CSS 里，**正文与标签**上还有十几处同性质的静息半透明，全部漏网：
  `.dict-label`（词典名，10px + `opacity: 0.7`，最糊的一处）、`.glossary-group > summary::before`
  （折叠三角 0.5）、`.deinflection-tag::before`（`«` 分隔符 0.55）、`.pitch-entries > li::after`（0.6）、
  `.pitch-transcription-tag`（0.85）、`.no-results` / `.no-results-icon`（0.7 / 0.5）、
  `.kanji-card-dict`（0.6）、`.ctx-adjust-button`（0.85）、`.mined-action-subtitle`（0.75）、
  `.sentence-context-picker` 的 label / stepper / count（0.6 / 0.55 / 0.5）、`.clear-draft-button`（0.45）。
  **半透明黑字 = 灰字**，而墨水屏没有足够灰阶去表现，只能抖动——这正是「发虚」的直接形态，与那条
  已有规则的注释是同一个理由，只是当初没扫全。
  另有一处亚像素位移 `.mine-button.duplicate { transform: translateY(0.5px); }`：0.5px 把字形推到半个
  物理像素上，同样只能糊成两行。`html.eink` 的通配块关了 `transition`/`animation`，**没关 `transform`**。
- **[x] ① 已修复** —— 在 `html.eink` 块里补两条规则（三镜像逐字节同步：`assets/popup/`、
  `assets/browser_extension/vendor/`、`tools/browser-extension/vendor/`，并重跑
  `generate-content-css.mjs` 重建两份 `content.css`）：
  - 上列 14 个正文/标签选择器统一 `opacity: 1`，层次改由字号 / 描边 / 位置承担——这正是 Hoshi
    Reader Android 弹窗的做法（它的正文一律零 opacity、纯 `#000`/`#fff`，21:1，清晰度全靠「不制造
    灰」而不是任何增锐手段；见下方对照结论）。
  - `html.eink .mine-button.duplicate { transform: none; }` 只归零这一条亚像素位移；整数位移
    （`.audio-button` 的 1px）落点仍是整像素，不受影响。
  - **刻意不动三类**：`:active`/`:hover` 的即时反馈、`:disabled` 与 `.audio-unavailable` 的失效态
    （弱化本身就是它要传达的信息）、`.audio-hint` 那种 `opacity: 0` 的隐藏态（压平会让提示常驻）。
    因此没有用通配 `html.eink * { opacity: 1 }`——那会把这三类一起连坐。
- **[x] ② 已加自动化测试** —— `fushi/test/build/popup_css_eink_guard_test.dart` 新增一条
  `html.eink flattens resting body opacity and subpixel transforms`，对三份 popup.css 镜像逐一断言：
  存在 `.dict-label` 与 `.glossary-group > summary::before` 的 eink 压平、存在
  `.mine-button.duplicate` 的位移归零，以及**反向**断言不存在通配 `html.eink * { opacity`
  （防止将来有人图省事一把连坐 disabled / 隐藏态）。
- **备注**：
  - 与 Hoshi 的对照结论：该仓库**没有任何**墨水屏 / 灰阶 / 增锐代码（无 `-webkit-font-smoothing`、
    无 `text-rendering`、无 `setLayerType`、无 `textZoom`/`initialScale`、弹窗零动画零缩放）。它清晰
    的原因只有三条减分项清单：三层不透明纯色背景、自管深色方案绕开 WebView 的 algorithmic
    darkening、正文颜色不带任何 opacity。本条修的就是第三条。
  - 未采纳的一条：Fushi 弹窗 WebView 是 `transparentBackground: true`（`dictionary_popup_webview.dart:1694`），
    而 Hoshi 是三层不透明纯色底。透明合成层会让 Chromium 从 LCD subpixel AA 退回灰阶 AA，理论上
    也会让文字变淡——但 Fushi 的 body 在 eink 下本就是不透明纯白/纯黑，是否真触发需要真机像素比对，
    且透明底是弹窗圆角透出所依赖的，改动爆炸半径大，故本轮不动，留作后续单独验证。
  - 同理未动的还有：内容缩放走的 CSS `zoom` 是 `toStringAsFixed(4)` 的任意小数
    （`popup_settings_injection.dart:808`，`zoom = appUiScale × 字号/16`），会让 1px 边框/下划线落在
    分数像素上。这条跨平台且改动面大（会动到所有平台的弹窗尺寸表现），需要真机测量后单独处理。
