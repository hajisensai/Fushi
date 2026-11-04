## BUG-4069 · macOS 应用外截屏识字 4K 屏要一分钟以上才出行框，点字查词总是「ー」
- **报告**：2026-11-02（应用内反馈 Eemf0HOZhj，macOS 27.0.1，Mac16,10，4K 显示器，3.3.0-debug.23079）
- **真实性**：⚠️ 现象可信，根因在本机（Windows）**无法实测**，静态核对结论如下；需要用户拍板方案，见「需拍板」。
  - **两条 OCR 路径本来就不是同一个引擎**：桌面截屏识字一律走系统 OCR（`DesktopSystemBallActionTarget.recognize` → `MethodChannelSystemOcr`，`fushi/lib/src/floating_ball/app_floating_ball_host.dart:282-286`，修前行号），不读漫画 OCR 引擎偏好；用户说的「本机 CTC / Google Lens」是漫画 OCR 的引擎设置（`MangaOcrEngineId.localOnnx` / `googleLens`，出厂默认 localOnnx，`fushi/lib/src/media/manga/ocr/manga_ocr_engine.dart:35`），对截屏识字**不生效**。所以「漫画几秒、截屏几分钟」比的是 CTC/Lens 和 Apple Vision 两个不同引擎。
  - **macOS 26+ 截屏识字的识别方式**：`fushi/apple/FushiSystemOcr.swift:138-163` 走 `RecognizeDocumentsRequest`（文档版面分析：段落 / 表格 / 列表 + 语言校正），截屏这条不下发 `tiles`，整块屏一次识别（4K = 3840×2160 ≈ 8.3MP，原始 Retina 像素，`FushiDesktopScreenOcr.swift:39-46`）。漫画系统 OCR 是按 ≤1536×768 的切片识别（`system_ocr_manga_service.dart:217-231`），BUG-2767 实测单片 0.5 s 级。
  - **推测（未验证）**：一分钟以上的时间花在 `RecognizeDocumentsRequest` 对一整屏高密度网页 UI（几百行 + 表格结构）的版面分析上。Dart / Swift 两侧其它环节（SCScreenshotManager 截图、PNG 编码、通道传输）静态看都是秒级以内，找不到分钟级的代码路径；但没有 macOS 26+ 设备，不能确认。
  - **点字查词总是「ー」**：截图里查词卡左缘对齐「鉄廻城砦の灰花 通常版【全年齢向け】」行框、卡顶紧贴该行下沿，即命中的是这一行首字附近，但查出来是「ー」。沿代码核对：冻结层点击（`FushiDesktopScreenOcr.swift:319-326`，pt × backingScaleFactor = 截图像素）、行框（同一截图像素、左上原点）、Dart 命中测试（`screen_ocr_picker.dart:45-96`，`scale: 1`）、取后缀查词（`app_floating_ball_host.dart` `_onDesktopScreenOcrTap`）坐标系一致，Windows 同一段 Dart 有端到端测试（`integration_test/desktop_ball_screen_ocr_itest.dart`）。最可疑的是 macOS 26+ `RecognizeDocumentsRequest` 的 `paragraph.lines[].transcript` 与 `boundingRegion` 在这种 UI 截图上对不上（例如行框对、文本是别的元素），但**没有证据**——用户日志尾部没有任何截屏识字的记录。
- **[ ] ① 未修复** — 本分支只做了取证（不改行为，提交 452b8f3941）：`_desktopScreenOcr` 把「截图+传图耗时 / 识别耗时 / 图尺寸 / PNG 字节数 / 行数」记进诊断日志（`floating_ball.screen_ocr_timing`），点字时记「落点 / 命中行框 / 是否竖排 / charIndex / 该行识别原文前 32 字」（`floating_ball.screen_ocr_tap`）。下一份带日志的反馈即可分清：慢在哪一段；「ー」是识别文本本身错（transcript 与框不对应）还是命中 / 查词错。
- **[x] ② 已加自动化测试（只覆盖取证）** — `fushi/test/floating_ball/app_floating_ball_host_test.dart`「反馈 Eemf0HOZhj：识别分段耗时与点中的那行原文记进诊断日志」。速度与查词结果本身未加测试（根因未定）。
- **需拍板（不擅自决定）**：
  1. 截屏识字要不要跟随用户的 OCR 引擎偏好（本机 CTC / Google Lens / 系统 OCR）？跟随 = 与漫画一致、用户说的设置真正生效，但本机 CTC 是逐列竖排模型，对横排网页 UI 未必合适，Lens 要上传整屏截图（隐私）。
  2. macOS 26+ 截屏识字改用 `VNRecognizeTextRequest`（快、横排 UI 准，但不读竖排）还是保留 `RecognizeDocumentsRequest` 并改成切片识别（与漫画同一套 `planOcrPageTiles` + `mergeTiledOcrLines`）？
  3. 用户提议的「先拖一个选区再识别」：桌面冻结层加框选（只识别选区，速度与准确度都更好），属产品新交互。
- **备注**：没有 macOS 26/27 设备，速度与「ー」两条都没在真机复现；以上推测项均已标明。取证提交只加诊断日志，不改识别、命中与查词行为。
