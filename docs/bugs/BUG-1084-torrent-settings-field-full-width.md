## BUG-1084 · 下载设置输入框在宽屏详情面板被拉满整宽
- **报告**：2026-07-25（用户：4K 全屏截图，「下载」设置里 qBittorrent 分类 / 下载限速 / 最大连接数 / 内存占用上限 / 监听端口等方框宽度堆满整个内容区）
- **真实性**：✅ 真 bug。设置详情面板按用户拍板（2026-07-22）填满整宽不限宽（`hibiki/lib/src/settings/settings_home_page.dart:332` 注释），而 `TorrentSettingsSection` 根 Column 用 `CrossAxisAlignment.stretch`，`_text` 里的 `TextFormField` 会吃满给定宽度（`hibiki/lib/src/pages/implementations/torrent_settings_section.dart:109`），两者叠加导致 4K 下每条输入框拉到 ~3000px。
- **[x] ① 已修复** — `_text` 给输入框自身包 `Align(左对齐) + ConstrainedBox(maxWidth: 480)`（`torrent_settings_section.dart` `_kFieldMaxWidth`）：只限输入框，开关行/分段按钮/说明文字仍占满整宽，面板级整宽形态不动；窄面板（小于上限）输入框仍占满可用宽度。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/torrent_settings_field_width_test.dart`：宽面板（2400px）断言所有 `TextFormField` 宽度 ≤480 且左对齐；窄面板（400px）断言仍填满可用宽度。
- **备注**：不复刻 UI 巡检 PR-5 被回滚的面板级 960 限宽——那次限的是整个详情面板（右侧大片空白被用户打回），这次只限输入控件本身。
