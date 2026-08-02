## BUG-1420 · 桌面 ffprobe 从未被构建或捆绑，内封字幕字体与音频元数据在干净机器上静默失效
- **报告**：2026-08-02（用户：qqbotxiaoxiao）
- **真实性**：✅ 真 bug。根因 `tool/ffmpeg-min/build-ffmpeg-min.sh:113` 传 `--disable-ffprobe`，
  而 Dart 侧 `hibiki/lib/src/media/video/ffmpeg_backend.dart:257-279` 的
  `resolveFfprobeExecutable()` 一直按「覆盖 > **程序旁捆绑** > PATH」设计，注释更明写
  「打包时与 ffmpeg 并排塞进各桌面产物」——**配方与消费方各说各话**，ffprobe 从来没有
  被编出来过，也就从来没被任何桌面产物捆绑过。桌面上该函数恒返回字面量 `'ffprobe'`，
  落到 PATH 查找。

  两个真实消费方都因此在**未装系统 ffmpeg 的机器上恒失效**，且都是静默的：
  - `hibiki/lib/src/media/video/subtitle_embedded_fonts.dart:269-290`
    `_enumerateFontAttachments()` → `Process.start` 抛 `ProcessException` → 就地
    `catch` 返回空列表（第 284-287 行，且**有意不记日志**，见其 260-268 行注释）→
    ASS 字幕永远退回系统字体 fallback，用户看到的字形与制作组意图不符。
  - `hibiki/lib/src/utils/misc/desktop_audio_clipper.dart:637-656`
    `extractAudioMetadataViaFfprobe()` → 同样 `ProcessException` → 返回 null →
    有声书导入的标题/作者/专辑永远退回文件名兜底。

  「静默降级」正是这个 bug 活了这么久没人报的原因：两处的兜底都是**正确的**（缺
  ffprobe 确实该降级而非崩溃），错的是「ffprobe 本就不该缺」。

  另注：Windows 是唯一捆绑了 ffmpeg 的平台（`release-desktop.yml` 的
  `Install vendored ffmpeg-min runtime into Windows bundle`），但它只拷 `ffmpeg.exe`
  与两个 MinGW DLL，即使编出了 ffprobe 也不会被装进产物——所以本 bug 需要配方与装配
  两处同时修。macOS 侧连 ffmpeg 都没捆绑，见 [BUG-1421](BUG-1421-macos-release-no-bundled-ffmpeg.md)。

- **[ ] ① 未修复** — 配方改 `--enable-ffprobe`（`tool/ffmpeg-min/build-ffmpeg-min.sh`）；
  `.github/workflows/ffmpeg-min.yml` 产出 `ffprobe(.exe)` artifact；`release-desktop.yml`
  的 Windows / macOS 装配步把 ffprobe 与 ffmpeg 一起拷进产物；重新 vendor 二进制。
- **[ ] ② 未加自动化测试** — `tool/ffmpeg-min/smoke-test.sh` 加两条**真实调用形态**断言
  （`-show_format` 读 format.tags、`-select_streams t -show_streams` 列附件流），
  覆盖两个消费方各自的参数形状；`hibiki/test/tools/ffmpeg_min_vendored_recipe_guard_test.dart`
  扩到 ffprobe 二进制存在性 + 配方一致性。
- **备注**：与「三条 FFmpeg 链各自为政」同源——配方 / 产物 / 装配 / 消费四处没有单一
  真相源，任一处漏掉都不会红。BUG-1058（movtext 漏 vendor）是同一根因的另一个表现，
  当时只给 Windows 的 ffmpeg 补了守卫，ffprobe 与 macOS 无人看管。
