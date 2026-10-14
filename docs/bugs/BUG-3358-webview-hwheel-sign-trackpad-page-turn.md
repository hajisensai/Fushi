## BUG-3358 · WebView横向滚轮符号反了致触控板翻页方向反
- **报告**：2026-10-14（应用内反馈 794gISjvgV，Windows 11 触控板：「触摸板的小说阅读方向反转，试过反转音量键 / 反转滑动翻页 / 反转键盘左右键几个开关，都对触摸板没用」）
- **真实性**：✅ 真 bug，两处根因：
  1. `packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview.cpp` `sendScroll` 横向分支：入参是「内容移动量」（Dart 侧传 `-scrollDelta` / 触控板 `panDelta`），纵向正好对上 `WM_MOUSEWHEEL`「正 = 向上」，但 `WM_MOUSEHWHEEL` 的约定相反（正 = 向右，Flutter 引擎 `flutter_window.cc:787` 与 Chromium 都按此解释），横向原样下发 ⇒ 倾斜滚轮向右滚成向左、触控板两指横滑内容逆着手指走、DOM `deltaX` 符号反。
  2. `fushi/lib/src/pages/implementations/reader_fushi/webview.part.dart` 的 `onWheelPaginate` handler：横向 `deltaX>0` 一律当前进，不看书写方向（竖排 vertical-rl 书页往左排），也不认任何反转开关——触控板两指横滑本质是滑动翻页，却走了滚轮约定。
- **[x] ① 已修复** — ① 原生横向分支取反后再 `SendMouseInput(HORIZONTAL_WHEEL)`；② 新增纯谓词 `readerWheelTickIsForward`（`fushi/lib/src/shortcuts/reader_space_override.dart`）：纵向 / 鼠标滚轮维持 TODO-737 不读开关；横向鼠标按「视口往书页前进一侧滚」；横向触控板按 `swipeLeftIsForward(invertSwipeDirection, rtl)` 折算，「反转滑动翻页方向」从此也管触控板。默认开关下竖排净行为不变（两处符号互相抵消），横排触控板 / 倾斜滚轮由反向改为正向。
- **[x] ② 已加自动化测试** — `fushi/test/reader/reader_wheel_page_turn_direction_test.dart`（象限表 + 开关确实反转触控板）；`fushi/test/reader/reader_mouse_paging_boundary_guard_static_test.dart`（handler 方向只经谓词、`invertSwipeDirection` 只作谓词实参）；`fushi/integration_test/webview_wheel_units_itest.dart` 新增真 WebView2 横向符号用例（倾斜滚轮向右 ⇒ deltaX>0；触控板两指向左 ⇒ deltaX>0）。
- **备注**：原生符号修正同时影响所有 Windows WebView 的横向滚动（查词弹窗宽表格、滚动模式竖排的触控板横滑——BUG-2830 写的「按原生方向跟手」此前在 Windows 上其实逆着手指）。真机触控板未验证；2026-10-14 `run_windows_itest.ps1` 真 WebView2 实跑通过：倾斜滚轮向右一档 DOM deltaX = +100，触控板两指向左 40 逻辑像素 DOM deltaX 合计 +60（dpr 1.5）。
