## BUG-2765 · 漫画统一引擎探测漏了系统 OCR：auto 永远用不上 Apple Vision，显式选择不校验可用性
- **报告**：2026-09-29（用户：苹果平台的漫画模块的 OCR 可以添加使用苹果自家的 OCR）
- **真实性**：✅ 真 bug。Apple Vision 的原生通道早已在（`fushi/apple/FushiSystemOcr.swift`，iOS / macOS 的
  `AppDelegate` 均已注册），但漫画各入口共用的引擎探测没把它接进去：
  - `fushi/lib/src/media/manga/manga_ocr_engine_probe.dart:44`（`MangaOcrEngineAvailability.capabilities`）
    只列 localOnnx / googleLens / externalMokuro / pairedHost，**不列 systemOcr**。
    `resolveMangaOcrEngine`（`ocr/manga_ocr_engine.dart:136`）的 auto 回退顺序里排着 systemOcr，但能力表里
    查不到它，于是 auto 永远落不到它上：Apple 设备没下本地 manga-ocr 模型时，阅读器「整卷 OCR」、作品页批量
    OCR、下载完成钩子一律报「没有可用引擎」，装完即用的 Vision 只有在设置里手动选才用得上。
  - 同文件 `:87` `isUsable(systemOcr)` 恒 `true`（注释「向导单独探测，这里不替它作答」），显式选了系统 OCR
    时阅读器 / 作品页 / 下载钩子不经可用性校验就排任务；没有原生侧的平台（Windows / Linux）会排一个必失败
    的任务。
  - 向导（`manga_ocr_wizard_dialog.dart`）单独异步探测系统 OCR、不参与默认引擎解析，所以向导里 auto 也默认
    不到 Vision。
- **[x] ① 已修复** — commit `cce509ad6fb`
  - `manga_ocr_engine_probe.dart`：`probeMangaOcrEngines` 探测 `systemOcrRunner.isAvailable()`（抛异常 /
    超过 `kSystemOcrProbeTimeout` 5 秒按不可用——向导整块引擎选择器等这次探测，原生侧不应答不能拖住所有
    引擎），能力表加入 systemOcr（离线、零上传、支持增量），`isUsable(systemOcr)` 改为「runner 在且原生侧
    答可用」。阅读器 / 作品页 / 下载钩子 / 向导读的是同一份判据，一处修好全部入口生效。
  - `manga_ocr_wizard_dialog.dart`：删掉单独的 `_probeSystemOcr`，`_systemAvailable` 从统一探测结果取，
    auto 默认引擎因此能解析到系统 OCR。
  - auto 顺序不变：本地模型就绪时仍优先本地模型（竖排气泡质量更好），系统 OCR 是其后的零下载兜底。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/manga_ocr_engine_probe_system_ocr_test.dart`
  - auto + 无本地模型 + 系统 OCR 可用 → systemOcr（前台解析与后台 `resolveBackgroundMangaOcrEngine` 都是）；
    本地模型就绪 → 仍 localOnnx；原生侧答不可用 → auto 为 null、显式偏好也不放行；探测抛异常 / 不应答
    （fakeAsync 推到超时）→ 不可用且不拖垮其余引擎；不给 runner → 既不提供也不可用。
  - 回归：`manga_module_ocr_entry_engines_test.dart` 三条入口测试用生产装配（真平台通道，测试绑定下永不
    应答），不加超时时会 `pumpAndSettle timed out`——这正是旧代码把系统 OCR 拆出去单独探测的原因；有了超时
    上限后恢复绿。
- **备注**：未在 Apple 真机 / 模拟器复测（本机 Windows）。Vision 通道本身的契约由既有
  `test/build/apple_system_ocr_guard_test.dart` 与 `test/media/manga/ocr/system_ocr_manga_service_test.dart`
  覆盖；Vision 对漫画竖排气泡与手写拟声词的识别质量明显弱于 manga-ocr，它的定位仍是兜底档。
