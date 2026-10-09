## BUG-3215 · iPad 上 Lapis 卡片播放按钮孤零零落在左下角
- **报告**：2026-10-09（用户：iPad 上 Anki 卡片排版差，播放按钮孤零零地落在左下角）
- **真实性**：✅ 根因已定位，未修。Fushi 随包的 Lapis 模板（`packages/fushi_anki/lib/src/lapis_note_type.dart`）默认
  `--mobile-audio-buttons: "fixed"`，AnkiMobile 给 `<html>` 加 `.mobile`（iPad 同样是 mobile），于是
  `#lapis[data-audio-buttons="fixed"] .audio-buttons { position: fixed; bottom: 0; left: 0; }`（以及 `.mobile .audio-buttons` 同款规则）
  把播放按钮钉到屏幕左下角。这是上游 Lapis 为手机单手拇指区设计的默认值，在 iPad 宽屏上就成了孤零零的左下角按钮。
- **[ ] ① 未修复** — 现有绕法：Fushi「Lapis 样式编辑器 › 音频按钮位置」选 header（会同时写 `--audio-buttons` 与 `--mobile-audio-buttons`）。
  改默认（例如只在窄屏手机上 fixed、平板宽度回 header）会改动上游 Lapis 默认行为，且只影响新写入/更新的笔记模板，待所有者决定。
- **[ ] ② 未加自动化测试** —
- **备注**：
