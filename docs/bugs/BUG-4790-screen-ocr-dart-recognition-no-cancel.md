## BUG-4790 · Android 截屏识字交给 Dart 识别期间没有取消出口，识别慢时悬浮球一直藏着
- **报告**：2026-11-17（用户：PR #3615 合入后的遗留缺陷复核——「截屏识字时原生侧等 Dart 回话没有出口」中「Lens 网络卡住 / 本机模型初始化卡住、用户没有可以取消的界面」这一部分）
- **真实性**：✅ 设计缺口（代码路径确认，未复现卡死）。现状：
  - `fushi/android/app/src/main/java/app/fushi/reader/ScreenOcrService.java:628` `recognize` 把帧交给 Dart 识别期间，选取层还没画出来，流程锁（`ScreenCaptureRequestActivity` 的 `flowActive`）持有、悬浮球 `setCaptureHidden(true)`。非保持会话时 `releaseCapture`（`:583`，`:608` `stopForeground(STOP_FOREGROUND_REMOVE)`）已撤掉前台通知，此刻**没有任何通知或界面**能取消；保持会话时通知里的「停止」走 `stopSessionNow`（`:464`），流程未结束时只清 `keepSession`、不收尾。
  - Dart 侧 `fushi/lib/src/floating_ball/app_floating_ball_host.dart` `_androidRecognizeScreenOcrFrame` 对 `target.recognize`（本机模型 / Lens）没有取消令牌。Lens（`fushi/lib/src/media/manga/ocr/google_lens_ocr_service.dart:49`）各阶段有 60 秒超时，不会无限挂；本机模型首次加载 / 推理没有上限，但也是有限时间。所以实际是「可能等一两分钟、期间无法取消」，不是永久卡死（永久卡死的引擎销毁路径已在 BUG-4789 修掉）。
- **[ ] ① 未修复** — 这轮修不了：要新增用户可见的取消入口（识别期间重新挂前台通知并带「取消」动作，或在屏幕上给一个可点的取消层），属于 UI / 交互形态变更，需维护者定；Dart 侧还要给本机模型 / Lens 识别加可取消令牌并让原生的取消透传过去，跨原生 + Dart 两端，本机无法跑 Gradle 与真机验证。
- **[ ] ② 未加自动化测试** — 待 ① 定案后补：原生取消动作 → `finishFlow` 的 JVM 测试，与 Dart 侧取消令牌的 widget 测试。
- **备注**：不靠原生侧加超时掩盖（会把慢但正常的本机模型首次加载误判成失败）。
