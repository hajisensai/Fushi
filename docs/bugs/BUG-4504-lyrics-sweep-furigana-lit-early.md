## BUG-4504 · 歌词模式逐字扫过时振假名起句即点亮、先于基字
- **报告**：2026-11-15（用户：应用内反馈 08Xq7QfGE4，Android）
- **真实性**：✅ 真 bug。合成器扫过方案里底层 `.tx` 画成未读色，但 `fushi/lib/src/media/audiobook/lyrics_mode_html.dart:642`（修前）单独给 `.tx rt` 钉了 `color: var(--ly-current)`；同时 `_lySweepBuild`（修前 `:1576`）收字形矩形时把 rt 整段跳过（注释「两层都是当前色」），窗口条带按基字算、盖不全注音。结果振假名从起句就整排是已读色，不跟基字扫。这条规则是旧 background-clip 渐变实现（c59ee0be980 之前）遗留的兼容写法，换成窗口方案后已无必要。只涉及来源自带的 `<ruby>` 显示，不引入任何自动注音。
- **[x] ① 已修复** — 删掉底层 `.tx rt` 的当前色覆盖，注音与基字同为未读色；`_lySweepBuild` 把 rt 字形矩形单独收集（rp 照旧跳过），`__lyricsSweepLines(rects, vertical, rubyRects)` 把每个注音并进它所注的那一行（行内方向重叠、交叉方向最近），扩展该行的交叉方向范围与行内范围后再算条带，上层当前色副本窗口因此连注音一起扫亮，进度与基字同步。横排 / 竖排同一套逻辑。
- **[x] ② 已加自动化测试** — `fushi/test/media/audiobook/lyrics_sweep_compositor_test.dart`：横 / 竖排各断言文档里不再有把 `.tx rt` 钉成 `--ly-current` 的规则；DOM 桩加 rt / rp 文本节点，断言注音不另起一行、首行窗口条带外扩到盖住注音；纯函数用例断言注音并入所注行（竖排注音在列右侧、横排在行上方）且相邻行中线按注音外缘计算。
- **备注**：像素级效果需在真 WebView（Android / WebView2 / WKWebView）上目测，本轮未上真机。
