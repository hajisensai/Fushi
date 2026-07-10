## BUG-685 · 竖排跟随句高亮激活时整段列平移（active 态 line-height:1 改写盒模型）
- **报告**：2026-07-10（用户，TODO-1371；两图对比：跟随句高亮激活时其后所有列整体平移）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/reader/reader_content_styles.dart:651`（修复前）：
  `.hoshi-sasayaki-cue.hoshi-sasayaki-active { line-height: 1 !important }`。有声书跟随高亮
  逐句 toggle 该 class（`reader_pagination_scripts.dart` `highlightSasayakiCue`），这是激活路径上
  **唯一**的布局属性改写。竖排 writing-mode 下行盒厚度就是列厚：当书籍 CSS 的段落 strut < 1em
  （行距设成小于字号，如 `p{line-height:0.9}` 或 px 行距小于用户放大后的字号）时，激活句行盒被
  `line-height:1` 增厚，其后所有列随播放逐句平移；横排同理是行下移。对照的查词高亮走 CSS Custom
  Highlight（`reader_selection_scripts.dart` `::highlight`）纯绘制层着色、零布局影响，所以两种高亮
  「位置机理不同」。
  - **line-height:1 的来历**：`7674ae703`（BUG-643，cherry-pick 自 a3aefaad19）为「iOS WebKit 竖排
    inline 背景盒按行盒宽度绘制」的假设加的保险；但该 iOS 真机复测在 BUG-643 里始终未完成，而
    1em 窄条宽度本就由同提交的 `_highlightLaneCss` `background-size: 1em 100%`（纯绘制层）硬性
    保证，与 line-height 无关——去掉 line-height 不会让 BUG-643 的「高亮条变宽」复活。
  - **探针证据**（离屏 headless Chrome/Blink，与 WebView2/Android WebView 同内核；真实生成 CSS
    修前/修后对照，`.codex-test/todo1371/column_shift_probe.mjs` + `column_shift_probe_output.txt`）：
    书籍 CSS `p{line-height:0.9}` 时，修前激活致其后各列 x 整体 −3.4px（横排 y +3.4px），清除后归零；
    修后全场景 0.00px；默认 strut（继承 1.65）下修前/修后渲染坐标逐列相同（普通书零行为变化）。
- **[x] ① 已修复** — `hibiki/lib/src/reader/reader_content_styles.dart` 删除 active 规则中的
  `line-height: 1 !important`，active 态只保留绘制层属性（color / lane 变量 / lane 背景条）。
  若 iOS WebKit 竖排带位置日后实测有偏，按注释用 `background-position`（绘制层）修正，禁止改回
  line-height。
- **[x] ② 已加自动化测试** — `hibiki/test/reader/reader_content_styles_test.dart`：
  ① 原「active 必须 line-height:1」断言翻转为「active 块禁止出现 line-height」；
  ② 新增 `active highlight blocks are paint-only in both writing modes`：扫描两种书写模式生成 CSS
  中所有运行时 toggle 高亮块（`-active` / `::highlight()` / `.hoshi-dict-highlight`），属性必须落在
  纯绘制 allowlist（color/background-*/text-decoration-*/box-decoration-break）内，任何盒模型/排版
  属性直接判红。
- **备注**：
  - 已跑 `flutter test test/reader/reader_content_styles_test.dart test/reader/ruby_highlight_guard_test.dart`（含 BUG-643 lane 守卫、BUG-110/123/125 ruby 分流守卫）全绿；lane 选择器、`background-size: 1em 100%`、`left center` 钉位均未改动。
  - BUG-643 的 iOS 真机复测遗留项不受本修复影响（band 宽度由 background-size 保证）；其文档已补指向本条。
