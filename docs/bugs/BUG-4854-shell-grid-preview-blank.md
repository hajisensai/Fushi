## BUG-4854 · 外观设置「封面网格」预览卡整块空白
- **报告**：2026-11-15（用户：Windows 桌面，设置 › 外观 › 主题，「库页布局」两张选择卡里「封面网格」那张预览是空白的）
- **真实性**：✅ 真 bug（本分支新加的预览，未进 develop）。根因 `fushi/lib/src/settings/shell_style_preview.dart` 旧 `_PreviewCover.build`（改前第 141 行 `final Widget fallback = ColoredBox(color: color);`）+ 旧 `_GridPreview` 的行 `Row`（改前第 360 行，默认 `crossAxisAlignment: center`）：网格每格是「Expanded → ClipRRect → 无子的 ColoredBox」，`Row` 的交叉轴居中只给格子松高度约束，无子的 `ColoredBox` 取 `constraints.smallest` → 高 0；封面图未解码 / 已解码的 `Image` 在松约束下也不铺满。于是 5 × 2 网格全是 0 高格子、整块空白。拼贴预览没事是因为它的色块显式套了 `SizedBox.expand`。
- **[x] ① 已修复** — `_PreviewCover`（shell_style_preview.dart:138）恒用 `SizedBox.expand` 铺满父级、解码前先露色块（`frameBuilder`）；`_GridPreview`（:355）的列 / 行都 `CrossAxisAlignment.stretch`（:376 / :382），格子拿到紧约束。每格带 `shell-preview-grid-cell-<i>` key 供测试定位。提交哈希：未提交（委托方禁止 git 写操作）。
- **[x] ② 已加自动化测试** — `fushi/test/settings/shell_style_preview_layout_test.dart`：设置页三行（360 / 800 / 1460 宽）与升级弹窗大卡（360 / 800 / 1460 宽）都断言 `shell-preview-grid-cell-0` 存在且宽高 > 2。
- **备注**：需 Windows 真机肉眼复看 设置 › 外观 › 主题 的「封面网格」迷你示意（本轮未起 app，调试实例由主会话热重载）。
