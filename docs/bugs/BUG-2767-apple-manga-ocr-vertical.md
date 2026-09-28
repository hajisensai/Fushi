## BUG-2767 · Apple 系统 OCR 漏读竖排漫画气泡
- **报告**：2026-09-29（用户：「苹果漫画 ocr 识别很快但是漏了很多气泡」）
- **真实性**：✅ 真 bug。`fushi/apple/FushiSystemOcr.swift` 整页一次 `VNRecognizeTextRequest`，而这个请求**不读竖排**（Apple DTS，开发者论坛 thread 772972）：竖排气泡被横着跨列读成 `よ暖炎急号`、`恐えな 夫ぶツ` 这类拼盘。macOS 27 上对 21 页真实日漫（Mihon 阅读缓存，1115–1403 × 1600–2048）实测，以同页 Google Lens 结果为基准：
  | 方案 | 文字块命中 | 字召回 | 单页耗时（M 系 Mac） |
  |---|---|---|---|
  | 现状 `VNRecognizeTextRequest` 整页 | 18.6% | 7.4% | ~100 ms |
  | 同上 + `minimumTextHeight` 0.01 / 0.005 | 18.6% | 7.4% | — |
  | 同上 + 整页旋转 90°（`.left` / `.right`） | ≤9.2% | ≤5.3% | — |
  | 同上 + 3×4 切片 | 25.5% | 8.1% | ~450 ms |
  | `RecognizeDocumentsRequest`（iOS/macOS 26）整页 | 82.1% | 52.0% | ~200 ms |
  | 同上 + 按行切 3 片 + 跨片合并（本修复） | **87.1%** | **68.6%** | ~500 ms |

  「快但漏」正是老请求的特征：它根本没在读竖排，调阈值、放大、旋转都救不回来。Lens 基准里含振假名，真实上限约 85%。
- **[x] ① 已修复** — `8bd70b95962`。
  - Apple 原生（`FushiSystemOcr.swift`）：iOS 26 / macOS 26 起改走 `RecognizeDocumentsRequest`（`#if compiler(>=6.2)` + `#available` 双门控，同 `FushiSpeechTranscriber.swift`），按 Dart 下发的 `tiles` 逐片裁剪识别，行坐标加回片左上角、带 `tile` 下标；更早的系统保留老路径并忽略切片（对老请求几乎无收益、耗时三倍）。
  - 平台无关的切片层 `packages/fushi_engine/lib/ocr/ocr_page_tiling.dart`：`planOcrPageTiles`（按目标片高 768 / 片宽 1536 规划、10% 且 ≥48px 重叠、至多 12 片）+ `mergeTiledOcrLines`（截断行让位给别片完整版 → 跨切线两截按「前尾 = 后头」拼接，容忍切边上各 2 个读错的字，对不上按重叠区中线切 → 全局去重）。对不带 `tile` 的结果恒等，所以 Android（ML Kit 暂未实现切片）行为不变。
  - Dart 装配：`system_ocr_channel.dart` 契约加 `tiles` / `tile`、抽出唯一竖排判据 `inferSystemOcrVertical`；`system_ocr_manga_service.dart` 按页图**原始像素**尺寸（只读文件头）规划切片、识别后合并再组页；引擎签名换代 `system_ocr_v2_*`，旧的劣质逐页缓存不再命中。
  - 调研结论（未采纳的方向）：Chimahon 是 Android 上的 Mihon 分支，OCR 用 Lens / 设备端 Lens / PaddleOCR，只对超高页做重叠切条 + 边界去重（本修复的切片与之同形）；行→气泡归组它移植了 owocr 的算法，mokuro 用 comic-text-detector 块 + 按字号/方向/距离合并行。本仓展示层（`manga_overlay_html.dart`）已有按几何邻接把块聚成整句、识别注音的那一套，系统 OCR 继续「一行一块」交给它，不另写第二套聚类。
- **[x] ② 已加自动化测试** — `fushi/test/ocr/ocr_page_tiling_test.dart`（切片规划 + 合并，拼接用例取自 Vision 真实逐片输出）、`fushi/test/media/manga/ocr/system_ocr_manga_service_test.dart`（`tile`/`tiles` 通道契约、按原始尺寸规划、整卷跨切线拼回、签名换代）、`fushi/test/build/apple_system_ocr_guard_test.dart`（新请求双门控、切片坐标回写、`tile` 键两端一致）。
- **备注**：未在 iPhone 真机上跑；验证是在 macOS 27 上把生产版 `FushiSystemOcr.swift` 与 Flutter 类型桩一起编译，走真实 `handle(recognize)` 入口跑 21 页、再经 Dart 合并对 Lens 打分（上表最后一行即该链路的结果）。测试机神经引擎编译服务满载时出现过单页 30 s+ 的离群值（`ANECompilerService` 争用，磁盘 99% 满），不争用时稳定 0.5 s/页；若真机首用也出现模型准备的长延迟，会撞上 Dart 侧 30 s 单页超时。Android ML Kit 已能接收 `tiles`（被忽略），是否实现切片需先在真机量召回再定。
