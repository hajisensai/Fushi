## BUG-2531 · 竖屏读数行自己另画一块遮罩：底栏遮罩看着缺了进度显示那一层高度
- **报告**：2026-09-14（用户：「底栏遮罩少了进度显示的那层高度……竖屏做到最底部并且居中」，附横屏截图：播放条那块半透明遮罩到读数行上沿就断了，读数行是另一块底）
- **真实性**：✅ 真 bug。读数独立成行时底部是**两块**各自铺底的面，不是一块：
  - 播放条经 `_wrapBottomChromeBar` 画，`bottom: _separatePlaybackStatus ? _statusFooterPaintedBand : 0`（`fushi/lib/src/pages/implementations/reader_fushi/chrome.part.dart:1546`）——它坐在读数行的带**之上**，自己的 `ColoredBox` 只有播放条那一行高；
  - 读数行由 `_buildStatusFooter` 另起一个 `Positioned(bottom: 0)` 画，里面又是一个 `ColoredBox`（同文件 :2750）。

  两块同色遮罩在悬浮态下是半透明的（`_chromeSurfaceColor(floating: true)`），而它们底下的正文并不一样多（读数那块底下正文已被 chrome inset 推走），同一个颜色画出来深浅不一，底部看着就像缺了一层高度。读数那时还贴在右角，与上面一排居中的传输键错开成两个重心。
- **[x] ① 已修复** — 读数行并进底栏那块遮罩：`_statusFooterInBottomBar`（`reader_fushi_page.dart`）为真时读数是 `_wrapBottomChromeBar` 里 Column 的**最后一行**，底栏整体贴屏底、背景一路盖到底，`_buildStatusFooter` 那一层不再画（否则同一串读数上下两份）。同时 `ReaderStatusFooter.centered` 让这一行居中，与上面居中的传输键同一个重心。底栏整条不画时（默认布局无播放条、底栏槽位为空）读数照旧自己贴屏底右端——右下角是它与顶部进度 pill 共用的视觉基线。
- **[x] ② 已加自动化测试** — `fushi/test/reader/reader_status_footer_test.dart` 的 widget 用例 `centered: 读数并进底栏那块遮罩时居中，不再贴右角`（真 pump 后量图标左缘到进度右缘的中点落在整条中点上、不再贴右缘 16）；`fushi/test/reader/reader_desktop_chrome_test.dart` 的源码守卫 `compact playback leaves footer and system inset outside its surface` 扩到钉住新装配（底栏 `bottom` 的两分支、Column 里的 `_buildStatusFooterRow(centered: true)`、`_buildStatusFooter` 的让位条件、`_statusFooterInBottomBar` 的组成）。
- **备注**：设备肉眼复测竖屏原始路径待补（本轮只有 widget 层证据）。
