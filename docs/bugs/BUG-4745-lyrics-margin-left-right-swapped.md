## BUG-4745 · 歌词模式横排左右边距写反
- **报告**：2026-11-15（用户：开发者 shishamo，应用内反馈 a6XkWp0Ot4，Windows）
- **真实性**：✅ 真 bug。CSS `padding` 四值简写顺序是「上 右 下 左」，横排分支两条路径都把左边距填进第 2 位（右）、右边距填进第 4 位（左）：
  首屏生成 `fushi/lib/src/media/audiobook/lyrics_mode_html.dart:340-341`（`${marginLeft…}vw` 在第 2 位、`${marginRight…}vw` 在第 4 位，旁边 :330-335 算好的 `padLeft` / `padRight` 横排没用上）；
  热更新 `__lyricsApplyContainerPadding`（同文件 :1919，`lv` 在第 2 位、`rv` 在第 4 位）。竖排分支两条路径顺序本来就对。
- **[x] ① 已修复** — 横排与竖排共用同一组 `padLeft` / `padRight`，首屏 CSS 只拼一次四值（第 2 位右、第 4 位左）；JS 热更新横排改成第 2 位右边距、第 4 位左边距。
- **[x] ② 已加自动化测试** — `fushi/test/media/audiobook/lyrics_margin_sides_test.dart`：按 CSS 语义解析四值简写，横竖排的首屏 CSS 与 node 真跑的热更新 JS 都断言左边距落在 padding-left、右边距落在 padding-right（修复前横排两条红）。
- **备注**：反馈的后半句「竖排不能调节间距」本条未改：竖排的上 / 下边距（行内方向，决定列长）在 Edge headless 实测会缩短列、生效；左 / 右边距在竖排是主轴（滚动方向），只叠在 45vw 的滚动居中余量上，跟随滚动把当前句居中到视口中线时看不出效果——横排的上 / 下边距是同一结构（叠在 45vh 余量上）。要让主轴边距「看得见」得先定语义（把跟随锚点收进边距内的窗口 / 裁出空白条 / 竖排改成别的设置项），属于取舍，留维护者拍板。WebView 真机未复测。
