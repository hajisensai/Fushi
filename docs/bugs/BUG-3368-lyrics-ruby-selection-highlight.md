## BUG-3368 · 歌词模式查词高亮漏掉带注音的字
- **报告**：2026-10-14（用户：Windows 竖排歌词模式截图，「歌词模式高亮有问题，win和mac都要测试通过」——查「烏滸がましい」，高亮只盖住「がましくて」，带振假名「おこ」的「烏滸」没有底色）
- **真实性**：✅ 真 bug，Windows 与 macOS 都有。歌词页复用阅读器选区脚本，`highlightSelection`（`fushi/lib/src/reader/reader_selection_scripts.dart:2466`）对 `<ruby>` 里的字不进 `::highlight`、也不包 span，只给 ruby 元素挂 `fushi-selection-ruby-active`（BUG-110：竖排防双绘），背景由页面 CSS 画。阅读器 CSS（`reader_content_styles.dart:924`）有这条规则，歌词页（`fushi/lib/src/media/audiobook/lyrics_mode_html.dart`）只写了 `::highlight(fushi-selection)` 与 `.fushi-dict-highlight`，于是 ruby 基字永远透明，只亮后半截。
- **[x] ① 已修复** — `lyrics_mode_html.dart` 补 `ruby.fushi-selection-ruby-active`（底色 `--ly-hl`，当前行文字色 `--ly-hl-text`，与 `::highlight(fushi-selection)` 同色）；无主题页的运行时换色 `__lyricsUpdateStyle` 一并改写这两条规则。
- **[x] ② 已加自动化测试** — `fushi/test/media/audiobook/lyrics_selection_highlight_css_test.dart`：从真实选区脚本 `highlightSelection` 里抽出所有高亮类名（`classList.add` / `className`），断言歌词页横竖排 `<style>` 都给它们画背景；脚本以后新增高亮类同样会被咬住。修前缺 ruby 规则，该文件红。
- **备注**：
  - 真引擎像素验证（页面 = 生产 `LyricsModeHtml.generate`，竖排 / 横排、MD3 覆盖层主题、截图里同句 cue 加 `<ruby>烏滸<rt>おこ</rt></ruby>`，调真 `fushiSelection.highlightSelection(7)` 模拟查词「烏滸がましくて」）：
    - Windows：Edge 156 headless（Chromium，与 WebView2 同引擎）。修前竖排精确复现用户截图（只亮「がましくて」），修后「烏滸がましくて」整段底色；横排同。
    - macOS 27.2：真 WKWebView（Swift 小程序 `takeSnapshot`）。修前 ruby 计算背景 `rgba(0,0,0,0)`、截图同用户；修后 `rgb(30,90,110)`，横竖排整段底色。
  - 未在 Fushi app 本体里点真书复测。
