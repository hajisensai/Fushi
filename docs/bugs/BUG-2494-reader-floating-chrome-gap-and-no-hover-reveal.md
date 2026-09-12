## BUG-2494 · 悬浮控制栏：顶部常驻空带 + 控制栏不自动恢复
- **报告**：2026-09-13（用户：「开启悬浮控制栏后，还是会有不知道是安全区还是固定边距在上面。并且底栏也有问题。而且没有自动恢复」，附 Windows 阅读器截图）
- **真实性**：✅ 真 bug，三处根因：
  1. 顶部空带：`fushi/lib/src/reader/reader_desktop_chrome.dart` 的 `readerDesktopHeaderReserve`
     在 BUG-2387（2026-09-09）删掉了 `floating → 0` 特例，悬浮态也恒定预留 48px 顶栏高并经
     `--chrome-top-inset` 下发正文——顶栏收起后那 48px 就是一条常驻空带（不是安全区）。
     用户 2026-09-13 拍板悬浮态语义为「隐藏满屏、唤出覆盖」。
  2. 不自动恢复：唤出通道只有点空白 / 顶部 6px 悬停热区（`chrome.part.dart` 旧
     `_buildHoverRevealLayer`）/ 快捷键，鼠标在正文区移动碰不到热区。
  3. 死路：`reader_chrome_floating.dart` 的 `bottomBarVisible` / `readerVnBlankTapAction`
     在悬浮态先读 `chromeExpanded`（`_showChrome`）；挤压态收起过一次再切悬浮开关，
     它以 false 残留 → 任何唤出通道都翻了 `transientVisible` 却一像素不画。
- **[x] ① 已修复** — `031b46e54e`：`floating → 0` 恢复 + 悬浮态顶栏/底栏/状态行半透明
  覆盖（`readerChromeSurfaceColor`）；`bottomBarVisible` / VN 分派悬浮态只读
  `transientVisible`；鼠标移动唤出（Flutter 腿 `Listener.onPointerHover` + JS 腿
  `mousemove` → `onPointerHoverReveal`，按 `hostOwnsWebViewPointerInput` 互斥，纯函数
  `readerHoverRevealAction`），删 6px 热区；停在栏上不 re-arm（`_chromeHovered`）。
- **[x] ② 已加自动化测试** — `fushi/test/reader/reader_desktop_chrome_test.dart`
  （reserve 悬浮 → 0 契约）、`fushi/test/reader/reader_chrome_floating_test.dart`
  （`bottomBarVisible` 悬浮态不读 `chromeExpanded`、`readerHoverRevealAction` 真值表）、
  `fushi/test/reader/vn_blank_tap_chrome_reveal_bug1195_test.dart`（VN 同口径）、
  `fushi/test/pages/reader_bottom_chrome_gate_static_test.dart`（纯函数硬门文本）；
  itest `fushi/integration_test/reader_header_overlap_bug2387_itest.dart` 契约改为
  「悬浮态 inset == 系统顶 inset、唤出恰好覆盖 48px」。
- **备注**：同一批（`docs/specs/2026-09-13-reader-chrome-overhaul.md`）还做了有声书 / 统计
  改右侧侧栏、底栏读数精简为 `m:ss` + 进度条 + `xx.x%`、屏底 2px 进度线、插图册章节分组
  网格、阅读器按钮可视化布局（`ReaderControlLayout`）。BUG-2387 的「不盖字」契约现只对
  挤压态成立。
