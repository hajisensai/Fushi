## BUG-1502 · 视频画质增强嵌入设置重复嵌套卡片
- **报告**：2026-08-11（用户：Wight）
- **真实性**：✅ 真 bug。`SettingsSchemaSection` 已为 `SettingsCustomItem` 创建外层 `AdaptiveSettingsSection` surface，而 `VideoShaderManagerView.build` 又无条件创建三张同类 surface，形成外卡套内卡和三段额外底部间距（`fushi/lib/src/pages/implementations/video_shader_dialog.dart`）。
- **[x] ① 已修复** — `5cd768687b` 增加显式 `embedded` 模式：视频设置侧栏复用 schema 外层卡片，内部只渲染三个标题组及行分隔线；独立着色器页面继续使用原分组卡片。
- **[x] ② 已加自动化测试** — 更新 `fushi/test/pages/video_player_settings_master_detail_guard_test.dart`，守卫嵌入调用必须启用扁平模式、三个分组仍存在且独立模式保留 `AdaptiveSettingsSection`。按用户要求未执行测试。
- **备注**：用户要求跳过所有测试，本次未运行测试、构建或实机视觉回归。
