## BUG-5610 · glass-toggle-tile-dialog-fills-height
- **报告**：2026-11-28（用户：Windows 开发构建，Apple / 玻璃设计，YouTube 请求通知权限时「允许 www.youtube.com 使用通知？」对话框被拉成几乎整窗高的窄长条：标题在顶、「记住对此网站的选择」悬在正中、按钮在底）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/utils/components/glass/fushi_glass_toggles.dart` `_GlassToggleTileState.build` 的行体 `Align(alignment: centerStart, child: body)` 没给 `heightFactor`：`Align` 在有界高度下撑满上限。`FushiAlertDialog` 的默认内容外壳 `FushiDialogContentScroll`（`fushi_dialog_content_scroll.dart`）按「放大上限后高度跟着变大 = 吃满型」判型，这一行被判成吃满型、拿到整段视口高，于是整个对话框被拉到窗口高，行内容居中在正中。只在玻璃（Apple）分支；M3E 分支走原生 `CheckboxListTile` / `ListTile`，高度固定，不受影响。
- **[x] ① 已修复** — `_GlassToggleTile` 的 `Align` 加 `heightFactor: 1`：行高取内容高、由已有的 `minHeight`（44/58/76）托底，宽度仍撑满。共用 `_GlassToggleTile` 的 `FushiCheckboxListTile` / `FushiRadioListTile` / `FushiSwitchListTile` 一并修好。调用点（`web_browser_permissions.dart` `_askPermission`）不改。全仓直接把这三种行当 `FushiAlertDialog.content` 的只有这一处；包在 `Column` 里的用法拿到的是无界高度，原本就不撑满。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/glass/fushi_toggle_tile_dialog_height_test.dart`：M3E 与玻璃两套设计 × 复选 / 单选 / 开关三种行直接当对话框 content，断言行高 ≤72、标题顶到按钮底 < 窗口高 40%；设 `FUSHI_TEST_SHOT_DIR` 时把渲染像素存 PNG。去掉修复后玻璃三条全红。
- **备注**：
