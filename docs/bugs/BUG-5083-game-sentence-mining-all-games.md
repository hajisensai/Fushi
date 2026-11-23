## BUG-5083 · GSM 式全游戏台词制卡：非 Hook 游戏没有连续台词流可制卡
- **报告**：2026-11-21（用户：应用内反馈 fMicnouU6V ⑤「像 GameSentenceMiner 那样在所有游戏里直接从台词制卡」，拍板台「做」；同类 wkU3PmrlF0）
- **真实性**：✅ 功能缺口。现状：能 Hook 的 galgame 有台词流、台词浮窗与制卡；其它游戏只有一次性的全局屏幕 OCR 查词（`ShortcutAction.globalExternalScreenOcr`，`fushi/lib/src/lookup/global_lookup_controller.dart`），没有「固定区域连续 OCR → 台词历史 → 带截图 / 音频制卡」的链路。
- **[x] ① 已修复（第一期）**（PR #4088，拍板台 v5GSgDau9u，spec `docs/specs/2026-11-22-game-ocr-line-stream-design.md`；2026-11-23 巡检核对后补记）— Windows 台词工作台新增「OCR 识别台词」起点：选窗口、在截图上框台词区域（`fushi/lib/src/mining/gal_ocr_region_picker.dart`），之后定时截窗、画面变化且稳定才 OCR（`fushi/lib/src/mining/gal_ocr_line_source.dart` / `gal_ocr_recognizer.dart`），Rust 核心 `native/fushi_compute/src/ocrline.rs` 做变化检测、去重与打字机续写合并，出句进现有台词流，浮窗、字数、逐句系统回录、截图制卡全部沿用；全程不注入。第二期（持续截窗提帧率、按游戏记区域、小字预处理、OCR 行游戏内嵌查词、AI 操作路由、动画图标致帧不稳）另记 BUG-5141。
- **[x] ② 已加自动化测试** — `native/fushi_compute/src/ocrline.rs`（Rust 单测）、`packages/fushi_compute/test/ocr_line_test.dart`、`fushi/test/mining/gal_ocr_line_source_test.dart`、`fushi/test/mining/gal_ocr_session_test.dart`、`fushi/test/mining/gal_ocr_region_picker_test.dart`。
- **备注**：Windows 优先；不碰 galgame Hook 的引擎适配边界（`docs/agent/galgame-hooking.md`）。
