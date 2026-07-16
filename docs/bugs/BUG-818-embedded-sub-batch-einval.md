## BUG-818 · 内嵌字幕批量抽取 ffmpeg exit -22：一条不可解码轨拖垮整批

- **报告**：2026-07-16（用户贴日志：`extractEmbeddedSubtitlesViaFfmpeg ffmpeg exit -22; executable=D:\APP\Hibiki\ffmpeg.exe; stderr=Error opening output files: Invalid argument`，来自 `prewarmEmbeddedSubtitleCache`）。
- **真实性**：✅ **真 bug（build 配置 + 本机 ffmpeg 精确复现）**。根因链：
  1. 桌面捆绑 `D:\APP\Hibiki\ffmpeg.exe` 是 Hibiki 的 `--disable-everything` 精简 build（`tool/ffmpeg-min/build-ffmpeg-min.sh`，实测 `-buildconf` 确认），**字幕解码器只有** `ass,ssa,subrip,webvtt,movtext,text`，muxer 只有 `srt,ass,webvtt`。
  2. `subtitleFormatForCodec`（`video_subtitle_source.dart:261`）是 **fail-open**：除已知位图字幕（pgs/dvd/dvb/xsub）外，所有 codec 一律映射到 `.srt`。于是精简 build 解不了的文本类内封轨（真实世界：`eia_608`/CEA-708 隐藏字幕、`dvb_teletext`、`hdmv_text_subtitle`、`ttml`、`sami`…）照样进入抽取集合。
  3. BUG-104 把抽取改成**单条命令一次 `-i` 多 `-map` 抽全部轨**（`buildFfmpegMultiSubtitleArgs`）。ffmpeg 在解首包前**先绑定所有输出**；只要有一条轨绑不上（`no decoder found` → `Error binding an input stream` → `AVERROR(EINVAL)` = exit -22），**整条命令在写任何文件前中止** → 同批里好的 subrip/ass 轨一并丢失。`extractEmbeddedSubtitlesViaFfmpeg` 里 `written` 为空 → `_reportFfmpegFailure` 打出用户贴的那行。净效果：**含一条异种字幕轨的视频，一条内封字幕都抽不出**，且每次预热都刷这条错误日志。
  - **本机精确复现**（`ffmpeg -i tt.mp4 -map 0:s:0 t0.srt -map 0:s:1 t1.srt`，tt.mp4 = mov_text 好轨 + ttml 坏轨，跑捆绑精简 build）：
    ```
    [sist#0:2/ttml] Decoding requested, but no decoder found for: ttml
    [sost#1:0/subrip] Error binding an input stream
    Error opening output file t1.srt.
    Error opening output files: Invalid argument   ← 与用户日志逐字一致
    ```
    好轨 `t0.srt` 落盘 **0 字节**（整批被拖垮）；单独抽 `-map 0:s:0` 则 exit 0、正常产出——证明「批量」才是放大器。
- **[x] ① 根因修复** — 提交 901b0d977。不掩盖症状，改**批命令的全有全无缺陷** + **别把好轨陪葬**：
  - `desktop_audio_clipper.dart` `extractEmbeddedSubtitlesViaFfmpeg`：批量单趟命令若没产出全部请求轨（`written.length < outputs.length`），**对缺失轨逐条重抽**（`buildFfmpegSubtitleArgs`，复用 size-scaled 超时）。坏轨此时**单独失败**（在绑定期即挂、不读整个容器，很快），好轨照常落盘。批量仍是全好轨常态的快路径，重抽只在失败时触发。
  - `desktop_audio_clipper.dart` 负缓存：逐条重抽若返回**确定性非零、非超时**退出码（= 该 build 解不了这个 codec），在输出旁写 `<out>.unsupported` 哨兵（常量 `kUnsupportedEmbeddedSubtitleSentinelSuffix`）。**超时（`returnCode == null`）绝不写哨兵**——那是大交错容器 IO 争用下的瞬态失败（BUG-104），必须保持可重试。
  - `video_subtitle_source.dart` `_extractAllEmbeddedSubtitles`：读侧跳过带哨兵的轨，避免每次预热都重读整个（可能几十 GB）容器 + 重刷日志。哨兵住在按 size+mtime 键控的缓存目录里，原地换文件即失效重抽。
  - 仅当**所有**请求轨都抽不出（`written` 全空）才 `_reportFfmpegFailure`；被逐条重抽救回一部分的批量算成功、不再刷错误日志。
- **[x] ② 自动化测试** — 提交 901b0d977：
  - `hibiki/test/utils/desktop_audio_clipper_test.dart`（BUG-818 组，注入伪 backend 复刻精简 build 语义：mixed `-map` → EINVAL 且零产出；单轨可解码 → 落盘 exit 0）：① 一条不可解码轨不再拖垮好轨（批 EINVAL → 逐条 fallback，好轨落盘、坏轨丢弃）② 全好轨单趟成功、不触发 fallback（`runCount == 1`）③ 全不可解码 → 空结果、无产出文件。
  - `hibiki/test/media/video/video_subtitle_source_test.dart`：① **瞬态超时**（`returnCode null`）预热失败清 in-flight、手动选择可重试（超时不进负缓存）② **确定性失败**（exit 1）被负缓存、手动选择不再重读容器。
- **备注**：视频/字幕/桌面精简 ffmpeg。`flutter analyze` 改动文件 0 issue；`test/utils/desktop_audio_clipper_test.dart` + `test/media/video/video_subtitle_source_test.dart` 全绿。移动端 ffmpeg-kit 是全量 build（解码器齐全），本修复对其无害（全好轨走快路径）。**真机/桌面复测待用户**：用带 CEA-608/teletext 等异种字幕轨的视频，应能正常抽出其余 srt/ass 轨、且不再每次预热刷 exit -22。
