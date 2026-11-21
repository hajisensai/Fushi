## BUG-5055 · import-section-block-inherits-outer-scheme
- **报告**：2026-11-21（用户：书架「导入书」对话框的书名 / 作者输入字、设备端转录弹层的语言 / 模型下拉值几乎看不见，「加速」分段选中 / 未选配色反了；浅色、暗色模式都有）
- **真实性**：✅ 真 bug。导入对话框从「导入书」反色主方式块弹出，子树主题是外层深色块的局部配色（`FushiBlockColorScope`，onSurface = 浅色）；表单色块 `ImportSectionBlock`（`fushi/lib/src/media/import/import_dialog_blocks.dart:764`）自己画同色相浅底，却没下发自己的块配色，块里的 `TextField` / `GamepadMenuDropdown` / `FushiSegmentedButton` 读到的仍是外层主题，浅字压浅底。同文件的 `ImportPickBlock` / `ImportPickTile` 早已包 `FushiBlockColorScope`，只有表单块漏了。暗色模式下块色深浅对调，同样错配。
- **[x] ① 已修复** — `ImportSectionBlock` 整块包 `FushiBlockColorScope(colors: 块配色)`，块内字段 / 下拉 / 分段钮及从块里弹出的菜单都按块配色派生。
- **[x] ② 已加自动化测试** — `fushi/test/media/import/import_section_block_scheme_test.dart`：浅 / 暗两种明暗，深色外层块里放表单块，断言块内主题 onSurface / surface 与输入字颜色取表单块配色。
- **备注**：
