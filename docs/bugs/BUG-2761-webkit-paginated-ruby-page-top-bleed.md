## BUG-2761 · Mac/iOS 分页每页首行振假名画到上一页底部
- **报告**：2026-09-28（用户：「mac 的阅读下一页和上一页的振假名都会溢出」，截图为页底孤零零一串被切掉下半的「じゅうこう」）
- **真实性**：✅ 真 bug（WebKit 专属，分页模式）。根因 `fushi/lib/src/reader/reader_content_styles.dart` 的 `_webKitRubyAnnotationCss`：BUG-2472 给 `<rt>` 的负 `margin-block-start` 让注音不占行盒高度，而注音比根行盒上半 leading 高（22 号、行高 1.65：注音约 10px，leading 约 6px）。页中间的行没事（注音悬在上一行的下半 leading 里），但**页顶那一行**的注音伸出本列内容盒顶。WebKit 多列按流线程坐标所在列分列绘制、非首列顶边不外扩：伸出的那截注音被本列裁掉（本页首行注音只剩下半截），又落在上一列的流区间里，画在上一页底部（用户截图）。Blink 按行片段所在列绘制，不受影响。
  - 实测（Mac 27.2 WKWebView，Swift 小程序加载生产 macOS 正文 CSS + 80 段带注音正文，逐页截图并用 `Range.getClientRects` 量每个注音盒）：改前横排 21 处、竖排 9 处注音盒跨两列（bounding rect 横跨上一列到本列、高 = 整列高），截图与用户所见一致；标准 / quirks 模式相同。
  - 排除的修法：去掉负边距（回到 BUG-2472，段落多出 8–13px）；`p { padding-top: R; margin-top: -R }` 在章首不被截断、第一段被拽进页边，且覆盖书自带的段落边距。
- **[x] ① 已修复** — `_webKitPaginatedRubyReserveCss`：Apple 端分页模式给 `p` 块首 `padding-block-start: R`，由 `p::after { display:block; margin-block-end: -R }` 抵消；这条负边距穿过段尾与下一段上边距折叠，页中两者相抵（段落位置与改前逐像素相同、书的段落边距照常参与折叠），段落落在页顶时分栏处边距被截断、R 留下来装注音。R = `max(0, 0.65 − (行高 − 1)/2)` em（1.65 → 0.325em、1.0 → 0.65em、≥ 2.3 不发）。连续滚动与 VN 不发。Mac 复测横/竖 × 标准/quirks × 行高 1.65/1.0 八组：跨列注音 0，页中段落间距与改前一致（章首整体下移 R），注音相对基字位置不变。
- **[x] ② 已加自动化测试** — `fushi/test/reader/vertical_ruby_line_box_contain_guard_test.dart`「BUG-2761」：iOS / macOS 分页两种书写方向必有等量的块首预留与 `p::after` 负块尾边距；连续 / VN / 行高 2.4 与 Android / Windows / Linux 不发；行高越小预留越大。去掉修复后该用例红。
- **备注**：同一截图里用户还提到「振假名离正文远」。BUG-2724（PR #1685，09-27 合入）的负 `margin-block-end` 在本次 Mac 探针里注音盒与基字内容区重叠 2px、视觉紧贴，未复现「远」；若用户的 Mac 包早于 09-27 则仍是旧行为。
