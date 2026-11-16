## BUG-4735 · 详情页「继续观看」扩展 FAB 长标题画出按钮外、不省略（MD3）
- **报告**：2026-11-16（用户：应用内反馈 ERvD_oEfQp，Windows debug 包，MD3 主题）
- **真实性**：✅ 真 bug。`MediaDetailResumeFab`（`fushi/lib/src/media/detail/media_detail_kit.dart:2524`）给 `FushiFab` 套了 `maxWidth: 280` 并让文字 `maxLines: 1 + ellipsis`，但 `FushiFab` 的 MD3 分支（`fushi/lib/src/utils/components/glass/fushi_expressive_controls.dart` 原 `FloatingActionButton.extended(icon:, label:)`）把图标和文字原样交给 material_ui 的扩展 FAB，后者用 `_ChildOverflowBox` 以无约束 `BoxConstraints()` 布局内部 Row（material_ui 1.11.0 `floating_action_button.dart:584` / `:727`），父级宽度上限传不进去，文字的省略永远不触发；按钮本身被夹到 280 宽，文字居中后从两侧画出药丸外。Apple 分支自己排了 `Flexible`，不受影响。
- **[x] ① 已修复** — `FushiFab` MD3 扩展态改由 `_FushiFabExtendedContent` 自己排「图标 + 间距 + Flexible 单行省略文字」，外层按 `LayoutBuilder` 取到的父级 maxWidth 减左右 extendedPadding 收口，整行作为 `label` 交给扩展 FAB（不再传 `icon`）。所有带文字的 FushiFab 调用方一并受益。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/glass/fushi_expressive_controls_test.dart`：「扩展 FAB 长文字在父级宽度上限内省略，不画出按钮外」（修复前红：文字左缘 306.7 < 按钮左缘 504）、「扩展 FAB 短文字仍按内容收窄」。
- **备注**：同条反馈里「首页悬停气泡弹出太快」属 UI 取舍，已上拍板台，本条不处理。真机 / Windows 桌面肉眼复测未做。
