## BUG-835 · 制卡句子音频失败toast只显示ffmpeg版本banner看不到真因
- **报告**：2026-07-15（用户：截图报「导出卡片失败：sentence audio export failed: ffmpeg exit 1」）
- **真实性**：✅ 真 bug（诊断截断）。根因 `hibiki/lib/src/media/video/ffmpeg_backend.dart:83`（旧 `_summarizeFfmpegOutput` 从**头**截 500 字）。
- **[x] ① 已修复** — 提交 `4688c4a48`（PR #151）
- **[x] ② 已加自动化测试** — `hibiki/test/media/video/ffmpeg_backend_test.dart`（failureSummary surfaces the tail error line, not the leading banner）
- **备注**：

### 现象
Android 阅读器/有声书划词制卡时 toast 弹「导出卡片失败：sentence audio export failed: ffmpeg exit 1; executable=ffmpeg-kit; attempted=ffmpeg-kit; stderr=ffmpeg version n6.0 ... configuration: --cross-prefix=... --prefix=/Users/shfaifsj/ffmpegkit-build/... 」——`stderr=` 后面**全是 ffmpeg 的 version + configuration banner**，在 configuration 中途被截断，用户和 in-app 日志都看不到 ffmpeg 到底为什么 exit 1。

### 根因
句子音频经 `TtsChannel.extractAudioSegment` → `extractAudioSegmentViaFfmpeg`（`desktop_audio_clipper.dart`）→ 移动端 `KitFfmpegBackend`（进程内 ffmpeg-kit）。失败时上报 `FfmpegRunResult.failureSummary`，其 stderr 部分由 `_summarizeFfmpegOutput` 生成：

```dart
final String oneLine = output.trim().replaceAll(RegExp(r'\s+'), ' ');
return '${oneLine.substring(0, maxLength)}...';   // maxLength=500，从头截断
```

ffmpeg 的日志**开头恒是 banner**（`ffmpeg version` / `built with` / `configuration:` / `-i` 输入信息），`-hide_banner` 只去版本行不去 configuration。移动端自编 ffmpeg-kit 的 configuration 字符串极长（几百个 `--enable-*`），500 字全被它吃满，**真正的失败行（`Conversion failed!` / `Encoder not found` / `Invalid data` 等，在日志末尾）永远被截掉**。

这与视频制卡 TODO-910 修过的完全是同一类问题——视频侧 OSD 早已改用 `extractFfmpegFailureReason`（从尾段扫真因行），但那个抽取器只在 `video_clip_exporter.dart` 里，**共享的 `FfmpegRunResult.failureSummary`（音频裁剪 + reader 制卡走这条）从未受益**，仍旧从头截断。

### 修复
把 `extractFfmpegFailureReason` 的正准实现搬到最底层 `ffmpeg_backend.dart`（与 `FfmpegRunResult` 同文件、无依赖），`video_clip_exporter.dart` 改为 `export ... show extractFfmpegFailureReason` 保持旧调用点/测试不变，`audiobook_clip_export.dart` 直接从 `ffmpeg_backend.dart` 取。`_summarizeFfmpegOutput` 改为：先 `extractFfmpegFailureReason(output)` 抽末尾真因行，抽不出才退化整段压平，再折单行限长。noise 过滤补上 `ffmpeg version` 前缀（旧版只滤 `built with`/`configuration:`/`lib`）。

改动文件：
- `hibiki/lib/src/media/video/ffmpeg_backend.dart`（+`extractFfmpegFailureReason`，`_summarizeFfmpegOutput` 改尾段抽取）
- `hibiki/lib/src/media/video/video_clip_exporter.dart`（删本地重复定义，改 `export` 转口）
- `hibiki/lib/src/media/audiobook/audiobook_clip_export.dart`（import 改从 ffmpeg_backend 直取）

一处修复同时惠及：reader 划词制卡 toast、视频/有声书片段合成日志、桌面音频裁剪日志——全走同一个 `failureSummary`。

### 验证
- `flutter analyze`（全项目）无 issue。
- `flutter test test/media test/build/ffmpeg_min_clip_muxer_guard_test.dart test/mining/immersion_mining_ffmpeg_integration_test.dart`：2605 passed / 2 skipped。
- 新增守卫：超长 banner + 尾段 `Conversion failed!` 的日志，`failureSummary` 必含尾段真因、不含 `ffmpeg version` / `configuration:`。

### 后续
本修复解决的是「看不到真因」这一诊断截断根因。ffmpeg-kit 本次 exit 1 的**具体**原因（编码器/容器/输入解码）需用户在装了本修复的版本上复现，读新的（真因可见的）toast/日志再定位；届时可另开跟进。
