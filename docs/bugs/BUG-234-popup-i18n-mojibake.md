## BUG-234 · 查词弹窗「底部停靠」等 zh-CN 文案乱码（GBK→Latin1）（TODO-289）

- **报告**：2026-06-13（用户：查词弹窗"瞬时滚动"下面那个配置项显示乱码）
- **真实性**：真 bug。`hibiki/lib/i18n/strings_zh-CN.i18n.json` 第 1507-1514 行有 8 个 key 的简体中文值被以 GBK 字节按 Latin-1 错误解码（mojibake），写入后存成乱码字符（如 `popup_bottom_docked` 存成 `"µײ¿¹̶¨µ¯´°"`）。slang 把 JSON 值原样生成进 `strings.g.dart`，运行时直接渲染乱码。"瞬时滚动" = `popup_instant_scroll`，其下方紧邻的 `popup_bottom_docked` / `popup_bottom_docked_hint` 就是用户看到的乱码项。
- **根因**：`hibiki/lib/i18n/strings_zh-CN.i18n.json:1507`-`:1514` 的 8 个 key 值为 mojibake：`backup_export_categories_title` / `backup_export_categories_hint` / `backup_category_dictionary` / `backup_category_books` / `backup_category_audiobooks` / `backup_category_fonts` / `popup_bottom_docked` / `popup_bottom_docked_hint`。其余 zh-CN 文案正常，说明是某次编辑这一段时的编码事故，而非系统性问题。
- **[x] ① 已修复**：对照英文源 `hibiki/lib/i18n/strings.i18n.json` 同 key 的语义，把这 8 行的乱码值改回正确简体中文（如 `popup_bottom_docked`→「底部停靠查词弹窗」、`popup_bottom_docked_hint`→「将查词弹窗固定为屏幕底部一条整宽面板，而不是跟随被查词的位置。」，backup 系列按英文译）。只改已存在 key 的 zh-CN 值，不新增/删除 key。改完跑 `dart run slang` 重新生成 `strings.g.dart`（17 语言 key 完整、无报错），再 `dart format` 生成文件。
- **[x] ② 已加自动化测试**：`hibiki/test/i18n/zh_cn_mojibake_guard_test.dart` 扫描 `strings_zh-CN.i18n.json` 全部叶子值，断言任何中文 UI 文案值都不含 Latin-1 扩展乱码区间（` `-`ÿ` 等典型 mojibake 字符如 `µ` `×` `Ô` `É`），且本次受影响的 8 个 key 必须含 CJK 字符（`[一-鿿]`）。撤回修复时该测试转红。
- **备注**：纯数据/文案修复，不涉及代码路径；真机渲染只需确认弹窗设置项显示正常即可。
