## BUG-5083 · GSM 式全游戏台词制卡：非 Hook 游戏没有连续台词流可制卡
- **报告**：2026-11-21（用户：应用内反馈 fMicnouU6V ⑤「像 GameSentenceMiner 那样在所有游戏里直接从台词制卡」，拍板台「做」；同类 wkU3PmrlF0）
- **真实性**：✅ 功能缺口。现状：能 Hook 的 galgame 有台词流、台词浮窗与制卡；其它游戏只有一次性的全局屏幕 OCR 查词（`ShortcutAction.globalExternalScreenOcr`，`fushi/lib/src/lookup/global_lookup_controller.dart`），没有「固定区域连续 OCR → 台词历史 → 带截图 / 音频制卡」的链路。
- **[ ] ① 未修复** — 需要新子系统：用户框定游戏文本区 → 定时截取 + 变化检测 + OCR 去重成台词流（按「Rust 胖核心」放 native，Dart 只收事件流）→ 接入现有 texthooker 台词会话与制卡（截图取当时画面，音频取系统回录缓冲）。工作量大，须先出 spec，未在 fMicnouU6V 的 PR 里做。
- **[ ] ② 未加自动化测试** — 修时补：变化检测 / 去重的离线回放测试、制卡字段装配测试。
- **备注**：Windows 优先；不碰 galgame Hook 的引擎适配边界（`docs/agent/galgame-hooking.md`）。
