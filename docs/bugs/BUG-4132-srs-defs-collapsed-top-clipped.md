## BUG-4132 · 复习卡窄版式背面释义上沿被切（第一条释义的词典卡头 / 词头不在画面里）
- **报告**：2026-11-02 / 2026-11-06（开发者反馈 mCu20adBXg、ARhuDLRX-_，同一现象；Android OnePlus 363x792@3.5，3.3.0-debug.23025 / 3.3.0-debug.23880；正文空，只有截图）。
- **真实性**：✅ 现象真实，**根因未定**（证据不足，见下）。
  - **截图量出来的事实**：两张图都是 Fushi 卡片窄版式背面，主释义处于收起态（底部渐隐）。原生例句卡下沿到释义区可见上沿正好是一个 `s.gap`（16 lp，≈31 物理像素 @ 截图比例），即 WebView 在 Flutter 里的位置正确。但 WebView 可见区第一行就是 `.fc-dict`（米色）中段：外壳 `body{padding:16px}`、主词典卡头（`.fc-dict-label`，min-height 34）和词头行都不在，两张图都少了约 70–80 lp，与外层滚动位置无关（ARhu 外层在顶，mCu 外层已下滚）。
  - **排除项**：
    - 不是 BUG-4038 的窗口化（`SrsDefsScrollWindow` / `srsPageWindowScript`，47076879cf，2026-11-04）引起的回归：mCu20adBXg 的版本是 11-02 的包，早于该提交。
    - 不是收起框 `.fc-gloss--clamp`（`packages/fushi_anki/templates/fushi_card/styling.css:843`，`overflow:hidden`）自身被滚：那样 `body` 的 16px 上边距和收起框圆角会留在可见区顶部，截图里没有（像素取样：WebView 上沿第一行就是米色 + 被切的字形）。
    - 「展开全文」在 ARhu 图里看不到不是独立 bug：那张图外层在顶，收起框底部渐隐已压到发音键 / 评分栏后面，按钮在它下面、屏外；mCu 图外层下滚后按钮正常出现。
    - 浮动「🔊1」「🔊2」压在释义 / 「其他词典」标题上不是独立 bug：它们是底栏上方的浮动重播键（7e5d788d83 起与评分行对齐），内容从它们下面滚过；窄版式滚动底部留了 `_bottomInset`，最后一行能滚出来。
  - **剩下两种解释，现有证据分不开**：
    1. **页面文档有自己的滚动偏移**。窄版式释义 WebView 的高度 = 页面上报的 `body` 高度（`fushi/lib/src/pages/implementations/srs/srs_card_face.dart:340`），视图与内容等高时文档不可能有偏移；要有偏移就得视图比文档矮，并且有东西滚了文档。可能的时机：正面预热时视图是一屏高（`srs_fushi_card_view.dart:1228` 的 Offstage `SizedBox`），翻面后 `AnimatedContainer`（`srs_fushi_card_view.dart:1305`）高度动画期间；平台视图认领横向拖 / 长按（`srs_card_face.dart:305`），拿到触摸序列后 Chromium 会连纵向一起滚。但没有找到让文档在动画结束后仍比视图高的代码路径。
    2. **平台视图层面的偏移**。两张图对应的包都还带着 Hybrid Composition 下的 `LAYER_TYPE_HARDWARE`（d7a016abd7 去掉，2026-11-06 14:04 合入 develop，晚于两个包）。释义 WebView 高度远超屏高（约 1100 lp × 3.5 ≈ 3850 物理像素，屏 2772），全尺寸离屏层的绘制原点出偏差会是这个样子（页面 scrollY 仍为 0）。
  - **缺的证据**：出现时页面的 `scrollY` / `scrollHeight` / `innerHeight`、visual viewport 偏移，以及平台视图的 Flutter 尺寸。没有 Android 真机 / 模拟器，本轮拿不到。
- **[ ] ① 未修复**：根因没定，不硬改。本轮只加了取证：`srsCardMetricsScript`（`srs_card_face.dart:351` 起）在跟内容等高的页面（非窗口态）出现文档偏移、元素内 `scrollTop` 或 visual viewport 偏移时，每页报一次现场，宿主记诊断 `SrsWebCardFace.pageOffset`（带 cardId、scrollY、scrollHeight、innerHeight、body 高度、上报高度、偏移元素、visual viewport、平台视图 Flutter 尺寸）。
  - **下一步怎么判**：在含本提交（且含 d7a016abd7）的包上复现：
    - 现象消失 → 解释 2（硬件层），本条记为 d7a016abd7 修复；
    - 现象仍在且日志有 `SrsWebCardFace.pageOffset` → 解释 1，按日志里的偏移来源（文档 / 哪个元素）修；
    - 现象仍在但没有这条诊断 → 页面没偏移，问题在平台视图合成，需要真机抓 `dumpsys` / 布局边界。
- **[x] ② 已加自动化测试**（取证脚本的行为，不是修复）：`fushi/test/srs/srs_card_page_offset_probe_test.dart`，node 在假 DOM 上真执行 `srsCardMetricsScript`：
  - 没有偏移的滚动事件（换卡回顶）不报；窗口态（宿主钉位置）不报；
  - 文档偏移、收起框元素内偏移各报一次，字段齐全；同一页不重复报。
- **备注**：未在 Android 真机复测（本轮无设备）。
