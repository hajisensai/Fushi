## BUG-4372 · Android 低内存机跑 ASR 被系统杀（无内存门槛）
- **报告**：2026-11-10（应用内反馈 jbTZ4GIEyU，ZTE A103ZT / Android 12，崩溃报告「closed by the system for low memory x2」）
- **真实性**：✅ 真 bug。反馈日志：后台转录 m4b 有声书时进程 malloc 30 s 内 77 MB → 1390 MB、RSS 540 MB → 1.6 GB，前台被 lmkd 杀两次。根因：`fushi/lib/src/asr_host/asr_host.dart` 的 `createAsrTranscriptionService`（所有生产入口的唯一装配点）直接返回上游 `AsrTranscriptionService`，`start()` 在任何平台都不看设备内存就建 ORT 会话起转录；手机上的「跑不跑得动」只体现在模型说明文案 `asrModelFitFor`（`asr_model_catalog.dart:126`）里，没有任何门槛。
- **[x] ① 已修复** — 新增 `fushi/lib/src/asr_host/asr_memory_gate.dart`：Android 读 `/proc/meminfo`（MemTotal / MemAvailable）与 `/proc/self/status`（VmRSS），余量 = min(物理内存 × 0.4 − RSS, MemAvailable)，估算峰值 = 模型字节 × 3 + 600 MB（按本反馈实测标定）；`MemoryGatedAsrTranscriptionService.start` 在打开模型目录 / 起 isolate 之前判定，放不下抛 `AsrInsufficientMemoryException`（本地化说明 + 同语言同素材里放得下的更小模型）。`createAsrTranscriptionService` 改返回它，弹层 / 自动转录队列 / 视频字幕 / 控制通道一处全覆盖。
- **[x] ② 已加自动化测试** — `fushi/test/asr/asr_memory_gate_test.dart`（估算 / 余量 / 判定 / 建议模型 / `/proc` 解析 / start 在碰模型目录前拦下 / 生产装配点返回带门槛服务）。
- **备注**：有声书自动转录队列（`audiobook_auto_transcribe.dart`）缺模型时先过同一道门槛再下载，跑不动的机器不白下模型（复核补）。
