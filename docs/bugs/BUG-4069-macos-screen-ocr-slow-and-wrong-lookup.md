## BUG-4069 · macOS 应用外截屏识字 4K 屏要一分钟以上才出行框，点字查词总是「ー」
- **报告**：2026-11-02（应用内反馈 Eemf0HOZhj，macOS 27.0.1，Mac16,10，4K 显示器，3.3.0-debug.23079）
- **真实性**：⚠️ 现象可信，根因在本机（Windows）**无法实测**，静态核对结论如下；方案已由用户拍板（见下）。
  - **两条 OCR 路径本来就不是同一个引擎**：桌面截屏识字一律走系统 OCR（`DesktopSystemBallActionTarget.recognize` → `MethodChannelSystemOcr`，`fushi/lib/src/floating_ball/app_floating_ball_host.dart:282-286`，修前行号），不读漫画 OCR 引擎偏好；用户说的「本机 CTC / Google Lens」是漫画 OCR 的引擎设置（`MangaOcrEngineId.localOnnx` / `googleLens`，出厂默认 localOnnx，`fushi/lib/src/media/manga/ocr/manga_ocr_engine.dart:35`），对截屏识字**不生效**。所以「漫画几秒、截屏几分钟」比的是 CTC/Lens 和 Apple Vision 两个不同引擎。
  - **macOS 26+ 截屏识字的识别方式**：`fushi/apple/FushiSystemOcr.swift:138-163` 走 `RecognizeDocumentsRequest`（文档版面分析：段落 / 表格 / 列表 + 语言校正），截屏这条不下发 `tiles`，整块屏一次识别（4K = 3840×2160 ≈ 8.3MP，原始 Retina 像素，`FushiDesktopScreenOcr.swift:39-46`）。漫画系统 OCR 是按 ≤1536×768 的切片识别（`system_ocr_manga_service.dart:217-231`），BUG-2767 实测单片 0.5 s 级。
  - **推测（未验证）**：一分钟以上的时间花在 `RecognizeDocumentsRequest` 对一整屏高密度网页 UI（几百行 + 表格结构）的版面分析上。Dart / Swift 两侧其它环节（SCScreenshotManager 截图、PNG 编码、通道传输）静态看都是秒级以内，找不到分钟级的代码路径；但没有 macOS 26+ 设备，不能确认。
  - **点字查词总是「ー」**：截图里查词卡左缘对齐「鉄廻城砦の灰花 通常版【全年齢向け】」行框、卡顶紧贴该行下沿，即命中的是这一行首字附近，但查出来是「ー」。沿代码核对：冻结层点击（`FushiDesktopScreenOcr.swift:319-326`，pt × backingScaleFactor = 截图像素）、行框（同一截图像素、左上原点）、Dart 命中测试（`screen_ocr_picker.dart:45-96`，`scale: 1`）、取后缀查词（`app_floating_ball_host.dart` `_onDesktopScreenOcrTap`）坐标系一致，Windows 同一段 Dart 有端到端测试（`integration_test/desktop_ball_screen_ocr_itest.dart`）。最可疑的是 macOS 26+ `RecognizeDocumentsRequest` 的 `paragraph.lines[].transcript` 与 `boundingRegion` 在这种 UI 截图上对不上（例如行框对、文本是别的元素），但**没有证据**——用户日志尾部没有任何截屏识字的记录。
- **拍板（2026-11，哈吉）**：截屏 OCR 独立有模型设置，改成和 AI 一样——默认跟随全局，想改的自己改；同时按根因修慢与「ー」。
- **根因**：
  1. **设置不生效**：桌面截屏识字写死系统 OCR（修前 `fushi/lib/src/floating_ball/app_floating_ball_host.dart:1056` `engine: Platform.isLinux ? _localScreenOcr() : null`，`null` = `MethodChannelSystemOcr`），不读全局 OCR 引擎偏好 `manga_ocr_engine_preference`——用户在 OCR 设置里选的本机 CTC / Google Lens 对截屏识字从来不生效，所以「漫画几秒、截屏几分钟」。
  2. **慢**：macOS 26+ 的系统 OCR 不分调用方一律走 `RecognizeDocumentsRequest`（修前 `fushi/apple/FushiSystemOcr.swift:138-163`），截屏不切片，对一整块 4K 屏（8.3MP、几百行界面文字）做文档版面分析（段落 / 表格 / 列表）。这条路径是为漫画竖排气泡选的（BUG-2767），截屏是横排界面文字，用不上版面分析。
  3. **「ー」**：命中测试多行框重叠时取面积最小的那一行（修前 `fushi/lib/src/floating_ball/screen_ocr_picker.dart:57-66`）。识别器把文字行下的下划线 / 分隔线读成一条扁长的「ー」行、压在文字行下半截上时，它面积更小，点这一行任何字都命中「ー」——与截图「查词卡左缘对齐行框左端、卡顶贴着行下沿」吻合（锚点是整条「ー」行的框）。⚠️ 这条是按截图几何 + 代码路径推断，没有带取证日志的反馈实证；另外整行等分（macOS 不给词框）本身也会让点字偏几个字。
- **[x] ① 已修复**：
  - 截屏识字引擎设置（`screen_ocr.engine`，`fushi/lib/src/ocr/screen_ocr_engine.dart`）：默认「跟随全局（当前全局引擎）」，可单独选本地 ONNX / 设备自带（仅 macOS / Windows）/ Google Lens；设置在「悬浮球」页（桌面）。跟随全局时：全局 Lens / 设备自带照用；本机模型 / 自动 / 外部 mokuro / 互联服务端按「自动」解析——本机模型已下载用它，没下载且平台有系统 OCR 时用设备自带（出厂全局就是本机模型，没下模型的桌面用户截屏识字照旧开箱可用）。
  - 宿主按解析结果选识别器（`_resolveScreenOcrEngine` / `_screenOcrRecognizer`）：本机模型 `LocalScreenOcr`（三桌面通用，不再只给 Linux）、设备自带 `MethodChannelSystemOcr(screenText: true)`、Lens `GoogleLensScreenOcr`。Lens 上传要本机单独同意（新同意场景 `GoogleLensDisclosureScene.desktopScreens`，设备本地键 `screen_ocr_google_lens_disclosure_version`）；没同意时截屏前在主窗里问，这次不截。诊断日志 `floating_ball.screen_ocr_timing` 加 `engine=`。
  - Apple：截屏识字下发 `purpose: screen`，原生不分系统版本一律走 `VNRecognizeTextRequest`（只做行识别，不做文档版面分析），并按字问框回传 `words`（与 BUG-4367 Windows 词框同一通道字段，Dart `SystemOcrTextLine.segments`）；漫画等其它调用方不变。代价：设备自带不读竖排，竖排游戏文字在截屏识字引擎里选本机模型。
  - 本机模型与 Lens 的截屏识字也带逐字框：`systemOcrPageFromRecognition` 把 `OcrRecognition.glyphBoxes` 切到各行作词框；Lens 一段一行、逐字框作词框（`systemOcrPageFromMokuro`）。点字统一走 BUG-4367 的词框定位；词框选取改按平面距离（Lens 一段跨多行显示，只比阅读方向会点到上一行）。
  - 命中测试多行重叠：先要落点真在框里，再取落点离行中线最近的一行（横排看上下、竖排看左右），最后才比面积。
- **[x] ② 已加自动化测试**（未在本分支运行，统一在合并后验证）：
  - `fushi/test/ocr/screen_ocr_engine_test.dart`：设置存储值、跟随全局 / 单独指定 / Linux 无系统 OCR 的解析表；`MethodChannelSystemOcr(screenText: true)` 下发 `purpose: screen`，其它调用方不带。
  - `fushi/test/floating_ball/screen_ocr_geometry_test.dart`「screenOcrHitTest 多行框重叠」：「ー」下划线行压在文字行下半截时点字身命中文字行（修前命中「ー」）、容差行排在真包含行之后、竖排按左右。
  - `fushi/test/ocr/google_lens_screen_ocr_test.dart`：Lens 结果转行与逐字词框、点跨行段落第二行的字不落到第一行、乱序字框不发词框、Lens 语言取 OCR 设置。
  - `fushi/test/ocr/local_screen_ocr_test.dart`：本机模型字格切成行内词框（含行首空白偏移）、乱序字格不发词框。
  - `fushi/test/floating_ball/app_floating_ball_host_test.dart`：跟随全局 + 模型没下载 → 设备自带且 `screenText`、日志带 `engine=systemOcr`；单独选 Lens / 全局 Lens → Lens 识别器；Lens 未同意 → 先在主窗问、不截屏。
- **未验证**：没有 macOS 26/27 设备，`VNRecognizeTextRequest` 在 4K 截屏上的实际耗时、`boundingBox(for:)` 逐字框的质量、以及「ー」是否就是下划线 / 分隔线被读成一行，都没在真机上复现确认；Swift 改动未在本机编译（Windows）。取证日志（BUG-4069 首轮加的 timing / tap）保留，下一份反馈可核对。
- **历史**：首轮（提交 452b8f3941）只加取证日志，不改行为；本轮按拍板实现。
