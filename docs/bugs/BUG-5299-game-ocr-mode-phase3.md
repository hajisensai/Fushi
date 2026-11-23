## BUG-5299 · OCR 游戏模式第三期：持续截窗直出框内像素、OCR 行的游戏内嵌查词
- **报告**：2026-11-23（拍板台 `v5GSgDau9u`「希望添加基于 OCR 的游戏模式」第二期 BUG-5141 拆出的剩余两项；spec `docs/specs/2026-11-22-game-ocr-line-stream-design.md` §6）
- **真实性**：✅ 功能缺口（第一 / 二期已落地：固定区域连续 OCR 台词流、易变格稳定判据、小字放大 / 二值化、按游戏记设置、AI 操作路由）。剩余：
  1. **每帧新建 WGC 会话 + 编 PNG**：`fushi/lib/src/mining/gal_ocr_line_source.dart` 的泵经
     `WindowCaptureChannel.captureWindow`（`fushi/windows/runner/window_capture.cpp` `CaptureWindowPng`，每次新建 WGC 会话、
     首帧最长约 1.5 s、WIC 编 PNG），再在 Rust `ffc_ocrline_feed_png` 解码。要在 runner 加持续 WGC 会话（帧池常驻、
     只回最新帧框内 BGRA，复用 `CaptureCore` 的 Magpie / 缩放源窗口 / 客户区裁框判据，不另写一套），Rust 加
     `ffc_ocrline_feed_bgra`（已裁好的框，省掉 PNG 编解码），目标 ≥4 fps、单帧 <10 ms。持续会话要跟窗口生命周期
     （最小化 / 关窗 / 换分辨率）重建，且必须在真机 + Magpie 超分窗口上验，不能只靠单测。
  2. **OCR 行的游戏内嵌查词**：OCR 行没有 Hook 行的屏上文字几何，游戏画面内弹查词卡（适配成功第③条）对 OCR 行
     暂不提供。做法：识别结果保留行框（`SystemOcrTextLine.rect`，坐标在**预处理后**的图上——第二期起送 OCR 的图可能被
     整数倍放大，需要 Rust 在 `ffc_ocrline_feed_*` 的 meta 里交出放大倍数，或改由 Rust 把行框映回裁框坐标），再按
     识别区域映回客户区，接入 `GalAttachedTextController` 的几何提供者；注意 `gal_attached_no_ocr_guard_test`：
     查词扫描面不得直接 import OCR 包，几何要经 mining 层的中立数据结构交过去。
- **[ ] ① 未修复** — 只做 Windows，与 galgame 制卡同车道；不注入、不碰 Hook 适配边界。
- **[ ] ② 未加自动化测试** — 第 1 项 runner 侧只能真机验；Rust `feed_bgra` 与行框映射可单测。
- **备注**：真机（联网游戏 / 模拟器窗口）未验。
