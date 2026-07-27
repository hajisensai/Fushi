## BUG-1138 · 漫画高频翻页跨窗口时丢失输入
- **报告**：2026-07-27（用户：高频翻页、突然查词、缩放后继续高频翻页）
- **真实性**：✅ 真 bug。旧 `_onMangaTurn` 在窗口 `loadData` 期间遇到
  `_navigating` 会直接返回；词典 WebView 收起时还有一次原生 HWND 焦点交接，
  且原去重只按“动作 + 时间”判断，可能把消息批量到达的真实连续按键当作双报。
  根因位于 `hibiki/lib/src/media/manga/reader/manga_hibiki_page.dart:72`、
  `:969`、`:1079`。
- **[x] ① 已修复** —
  - `MangaTurnQueue` 累积快速输入的净位移并串行排空；
  - 图片页改为稳定的 lazy strip，翻页不再销毁 WebView 文档；
  - 词典弹窗在按键 burst 停止 180ms 后再收起；
  - 去重改为只过滤 Flutter / WebView 两个不同通道对同一按键的双报，同一通道的
    高频真实按键不会按时间丢弃。
- **[x] ② 已加自动化测试** —
  `hibiki/test/pages/manga_hibiki_page_test.dart:444` 用受控
  `Completer` 覆盖异步期间的混合方向输入与净位移排空。
- **修复提交**：`c3be39d63`
- **备注**：
  - 修复前 Computer Use：32–33 页输入
    `→→→→←←→→→→`，预期 44–45，实际只到 36–37。
  - 修复后在真实《Sieger 2026-27》、120% 缩放、词典弹窗打开时，以 70ms
    间隔输入 `←×6 →×3 ←×2`，46–47 精确落到 36–37；滚轮前后翻页也通过。
