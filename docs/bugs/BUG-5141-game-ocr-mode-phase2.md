## BUG-5141 · OCR 游戏模式第二期：持续截窗、按游戏记区域、小字预处理、游戏内嵌查词、AI 操作路由
- **报告**：2026-11-22（拍板台 `v5GSgDau9u`「希望添加基于 OCR 的游戏模式」第一期的剩余项；同子系统 BUG-5083）
- **真实性**：✅ 功能缺口（第一期已落地：spec `docs/specs/2026-11-22-game-ocr-line-stream-design.md` §6）。剩余：
  1. **每帧新建 WGC 会话 + 编 PNG**：`fushi/lib/src/mining/gal_ocr_line_source.dart` 的泵经
     `WindowCaptureChannel.captureWindow`（`fushi/windows/runner/window_capture.cpp` `CaptureWindowPng`，每次新建 WGC 会话、
     首帧最长约 1.5 s、WIC 编 PNG），再在 Rust `ffc_ocrline_feed_png` 解码。要在 runner 加持续 WGC 会话、只回框内 BGRA，
     省掉编解码与会话建立（目标 ≥4 fps、单帧 <10 ms）。
  2. **识别区域只记一份全局**（偏好 `gal_ocr_region`）：应按游戏（`GalCaptureMemory` / galgames.id）记。
  3. **小字放大 / 二值化预处理**：低分辨率游戏上 Windows OCR 识别率差；可选「按字色阈值化」（MisakaTranslator 思路），
     预处理放 Rust `ocrline.rs`。
  4. **游戏内嵌查词**：OCR 行没有 Hook 行的屏上文字几何，游戏画面内弹查词卡（适配成功第③条）对 OCR 行暂不提供；
     可用 OCR 的行框（`SystemOcrTextLine.rect`）映射回客户区坐标实现。
  5. **AI 操作目录**：`fushi/lib/src/ops/ctl_game_routes.dart` 补 `start_ocr` / `set_ocr_region` 路由与 `op_descriptions_game.dart` 描述。
- **[ ] ① 未修复** — 第一期 PR 见拍板台 `v5GSgDau9u` 结单记录。
- **[ ] ② 未加自动化测试** — 第一期测试：`native/fushi_compute/src/ocrline.rs`（Rust 单测）、`packages/fushi_compute/test/ocr_line_test.dart`、
  `fushi/test/mining/gal_ocr_line_source_test.dart`、`fushi/test/mining/gal_ocr_session_test.dart`。
- **备注**：只做 Windows（与 galgame 制卡同车道），不注入、不碰 Hook 适配边界。真机（联网游戏 / 模拟器窗口）未验。
