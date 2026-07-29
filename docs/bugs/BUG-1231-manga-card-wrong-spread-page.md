## BUG-1231 · 漫画双页模式制卡图片取错成跨页首页
- **报告**：2026-07-29（用户：制卡图片选择错误）
- **真实性**：✅ 真 bug。漫画页容器已有精确的 0-based `data-page`，但
  `hibiki/lib/src/reader/reader_selection_scripts.dart:1102` 构造选区 payload
  时没有读取页码；制卡侧
  `hibiki/lib/src/media/manga/reader/manga_hibiki_page.dart:1883`
  又只把当前 spread 首页写入 `_currentPageImagePath`，并在
  `onMineFromPopup` 无条件使用它。因此 RTL 双页中点击左侧第二张页图的 OCR，
  句子和查词来自左页，卡图却必然取右侧 spread 首页。
- **[x] ① 已修复** — `f1fa0fb4b`：选区 payload 从命中 OCR 元素最近的
  `.manga-page[data-page]` 携带 `mangaPageIndex`；漫画页在打开查词前解析并保存
  该精确页的本地文件，制卡只使用这张图。仅旧 payload 没有页码时才回退当前
  spread 首页；显式页码对应文件不可用时宁可不附图，也不再配错另一页。异步页
  文件解析带 generation 守卫，旧点击不能覆盖后来的选择。
- **[x] ② 已加自动化测试** — `f1fa0fb4b`：
  `hibiki/test/pages/manga_selection_dispatch_test.dart:92` 建立包含两张不同
  文件内容的双页 payload，断言选择第二页只解析第二张且越界 fail-closed；
  同文件还守卫页码先进入制卡状态、空选区不改状态，以及新旧 payload 的图片
  回退边界。selection JSON 与 WebView payload 分别由
  `reader_selection_data_test.dart`、`manga_overlay_html_test.dart` 覆盖。
- **备注**：相关 51 项 Flutter 测试全部通过，Windows debug 构建成功。
  修复版在实际 RTL 跨页 `50–51` 分别点击右页与左页 OCR，两个页面均能独立命中
  并打开查词。没有点击“+”写测试卡，以免污染用户 Anki；图片归属由两张不同
  文件的回归测试覆盖。`flutter analyze --no-pub` 未产生代码诊断，Flutter
  3.44 analysis server 因 LSP JSON 响应截断崩溃。
