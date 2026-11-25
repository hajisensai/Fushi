## BUG-4172 · 复习卡窄版式背面释义上沿被切（第一条释义的词典卡头 / 词头不在画面里）
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
- **[x] ① 已修复**（06febc214b，根因与修法见下方「2026-11-10 复发取证」）。首轮（根因没定，不硬改）只加了取证：`srsCardMetricsScript`（`srs_card_face.dart:351` 起）在跟内容等高的页面（非窗口态）出现文档偏移、元素内 `scrollTop` 或 visual viewport 偏移时，每页报一次现场，宿主记诊断 `SrsWebCardFace.pageOffset`（带 cardId、scrollY、scrollHeight、innerHeight、body 高度、上报高度、偏移元素、visual viewport、平台视图 Flutter 尺寸）。
  - **下一步怎么判**：在含本提交（且含 d7a016abd7）的包上复现：
    - 现象消失 → 解释 2（硬件层），本条记为 d7a016abd7 修复；
    - 现象仍在且日志有 `SrsWebCardFace.pageOffset` → 解释 1，按日志里的偏移来源（文档 / 哪个元素）修；
    - 现象仍在但没有这条诊断 → 页面没偏移，问题在平台视图合成，需要真机抓 `dumpsys` / 布局边界。
- **[x] ② 已加自动化测试**（取证脚本的行为，不是修复）：`fushi/test/srs/srs_card_page_offset_probe_test.dart`，node 在假 DOM 上真执行 `srsCardMetricsScript`：
  - 没有偏移的滚动事件（换卡回顶）不报；窗口态（宿主钉位置）不报；
  - 文档偏移、收起框元素内偏移各报一次，字段齐全；同一页不重复报。
- **备注**：未在 Android 真机复测（本轮无设备）。

### 2026-11-10 复发取证 → 根因定为「解释 1」的视觉视口版（NoerCpP877；同簇 cQFqqg193s）

- **报告**：2026-11-09（开发者反馈 NoerCpP877「前面一张卡往下翻，下一张也被往下翻，而且回不去」、cQFqqg193s「长按复制和实际位置不符，并且缺少按钮」；Android OnePlus CPH2747 363x792@3.5，3.3.0-debug.24790，含 d7a016abd7 与本条取证）。
- **取证**：`SrsWebCardFace.pageOffset` `…#defs: {"scrollY":0,"scrollHeight":1811,"innerHeight":1811,"body":1811,"reported":1811,"inner":null,"vv":[58.857,58.857,306.29,1]} view=404x1811`。即硬件层（解释 2）已排除、文档 / 元素都没偏移，偏移在**视觉视口**：平台视图与内容等高（1811 lp，远高于屏），Chromium 的视觉视口（306 lp）比布局视口小，在布局视口里面滚了 58.9 lp，卡面整体上移、顶部被切（与截图里少掉的 70–80 lp 同量级）。
- **根因**（`fushi/lib/src/pages/implementations/srs/srs_card_face.dart`）：卡面所有「回顶」都只调 `window.scrollTo`——换卡 `__fushiSrsSetCard`（`kSrsCardShellScript`，`q.innerHTML = html; window.scrollTo(0, 0);`）与窗口态 `srsPageWindowScript`（:265 起）。`scrollTo` / `scrollY` 只对应布局视口，视觉视口偏移原样留着；外壳页跨卡复用（换卡不重载文档），偏移带到下一张卡；窄版式平台视图不认领纵向拖（`srsCardFaceGestureRecognizers(scrollsInPage: false)`），用户也滚不回来。偏移最可能由长按选词 / 拖选区手柄时 Chromium 的自动跟手滚动产生（cQFqqg193s 同一操作）。
- **① 修复（视觉视口，06febc214b）**：新增 `kSrsVisualViewportPinScript`（外壳页里排在换卡脚本之前装）：卡面页面不变式「未缩放时视觉视口与布局视口原点重合」。偏移 ≥ 1px 时把钉在布局视口原点（按根节点 `zoom` 折算）的隐藏锚点 `scrollIntoView({block:'start',inline:'start',behavior:'instant'})`——scrollIntoView 走根视口（布局 + 视觉两层），布局视口已在锚点上，只剩视觉视口回 0。时机：视觉视口 `scroll` / `resize`、`selectionchange`、换卡、窗口态钉位置。缩放中、选区未收起（拖手柄时让 Chromium 跟手）、焦点在可编辑元素上（软键盘）时不动。
- **① 修复（选区菜单，cQFqqg193s，06febc214b）**：卡面 `InAppWebView` 原来无条件 `disableContextMenu: true`，长按选中后没有任何复制入口。改为 `disableContextMenu: !isMobilePlatform`：Android 混合渲染且不传 `contextMenu` 时 fork 直接走系统 ActionMode（`third_party/flutter_inappwebview_android/.../InAppWebView.java` `startActionMode`），iOS 是系统编辑菜单；桌面照旧关（有 Ctrl/Cmd+C；WebView2 / WKWebView 原生右键菜单带「刷新」，会把外壳页重载成空卡）。没有另做 Fushi 自绘选区工具栏：系统菜单在两套平台上即原生视觉，且不需要和平台视图坐标做映射。
- **取舍（没做的那条）**：「窄版式释义 WebView 限高到一屏、页内滚动并认领纵向拖」能从结构上让视觉视口不可能比布局视口小，但 BUG-4038 记过这条路：平台视图认领纵向拖后外层滚动交不回去（释义占满屏时标题区 / 页脚够不着），回到嵌套滚动的老问题；本轮按不变式钉视觉视口，不改滚动所有权。
- **② 测试（复发轮）**：`fushi/test/srs/srs_card_visual_viewport_pin_test.dart`——node 在假 DOM 上真执行复位脚本（现场数值 offsetTop 58.9 → 复位、<1px 不动、缩放不动、选区在时不动且收起后复位、输入框聚焦不动、幂等不重挂、窗口态锚点按 zoom 折算、`srsPageWindowScript` 钉完位置即复位）；换卡脚本在 `scrollTo(0, 0)` 后复位的顺序断言；外壳页装载顺序；`InAppWebViewSettings` 里 `disableContextMenu: !isMobilePlatform` 的源码守卫。测试未在本分支运行，统一在合并后验证。
- **备注**：未在 Android 真机复测。选区手柄与高亮错位（cQFqqg193s）推测与视觉视口偏移同源（Chromium 按视觉视口偏移画手柄、合成按平台视图位置），本修复落地后需真机复看；仍错位再按「超高平台视图被外层整体平移」（BUG-3982 备注）的坐标映射查。复现时 `SrsWebCardFace.pageOffset` 取证仍保留（每页一次，现在应当只在复位前报出瞬时值）。
