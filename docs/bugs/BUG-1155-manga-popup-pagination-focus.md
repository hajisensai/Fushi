## BUG-1155 · 漫画查词弹窗吞掉滚轮和左右翻页
- **报告**：2026-07-27（用户：）
- **真实性**：✅ 真 bug。Windows WebView2 实测：12–13 页查词后方向键不再翻页，
  Esc 会退出阅读器。根因有三处：
  1. `hibiki/lib/src/media/manga/reader/manga_hibiki_page.dart:959` 原先在
     `isDictionaryShown` 时直接忽略键盘事件，而且 Flutter `Focus` 只包正文，
     查词原生 WebView 是其 sibling；
  2. 正文 WebView 与查词 WebView 都可能持有 Windows 原生键盘焦点，不能依赖平台
     视图把按键稳定冒泡回 Flutter；
  3. `hibiki/lib/src/pages/base_source_page.dart:594` 的全屏查词遮罩会命中弹窗外
     的滚轮，但此前没有 pointer-signal 转发钩子。
- **[x] ① 已修复** —
  - 左右键、Esc 收口为同一漫画输入策略；查词显示时左右键先关弹窗再翻页，Esc
    只关弹窗；
  - 漫画正文 WebView 与查词 WebView 都安装捕获阶段的导航键桥接，按键直接回调
    漫画宿主；查词侧为显式 opt-in，不改变其它查词表面；
  - Flutter `Focus` 扩大到正文、chrome、词典整棵子树作为兜底，并用 60ms 同动作
    去重避免原生桥与 Flutter 同时回报造成连翻；
  - 查词遮罩增加滚轮信号钩子，漫画宿主关闭弹窗后按滚动方向翻页。
- **[x] ② 已加自动化测试** —
  `hibiki/test/pages/manga_hibiki_page_test.dart` 覆盖查词态左右键/Esc、滚轮方向和
  正文 JS 桥；`hibiki/test/pages/base_source_page_barrier_swipe_close_test.dart`
  覆盖遮罩滚轮信号；`hibiki/test/pages/dictionary_popup_inline_html_memo_test.dart`
  覆盖查词 WebView 桥的开关、幂等 guard 与捕获键集合。
- **备注**：Windows 真应用使用
  `Sieger （ジーガー） 2026-27 最新スキーギア厳選カタログ.epub` 复测：
  普通右键 12–13→14–15；查词后左键 14–15→12–13、右键 12–13→14–15；
  查词后下滚 14–15→16–17、上滚 16–17→14–15；Esc 仅关闭查词弹窗并保持
  14–15 页。定向 analyze 通过，相关 24 个测试全部通过。
