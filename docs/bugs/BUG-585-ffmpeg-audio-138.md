## BUG-585 · 制卡句子音频 ffmpeg exit -138（googlevideo connect 阶段网络超时）
- **报告**：2026-07-07（用户日志：`extractAudioSegmentViaFfmpeg ffmpeg exit -138; executable=D:\APP\Hibiki\ffmpeg.exe; ffmpeg version n7.1.5`）
- **真实性**：✅ 真 bug（TODO-1290）。根因在 `hibiki/lib/src/utils/misc/desktop_audio_clipper.dart:39`（`buildFfmpegRemoteInputArgs` 的重连开关集不完整）。
- **根因**：`-138` 不是缺编码器/muxer，也不是 app 崩溃——是 **远端 http(s) googlevideo 流在打开/连接阶段的 TCP/TLS 网络错误**（Windows/mingw errno 138 = `ETIMEDOUT`，连接超时；代码 line 35 早有实测注释 `Error number -138 opening input`）。
  - 制卡句子音频经 `extractAudioSegmentViaFfmpeg` → `buildFfmpegClipArgs`，对 http(s) 输入已 `buildFfmpegRemoteInputArgs` 预置 `-reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5`。但 `-reconnect`/`-reconnect_streamed` 只在 **流传输中断 / EOF** 时重连，**不覆盖 connect 阶段的网络错误**。短音频段每次都新开一条 googlevideo 连接、更常在 open 阶段撞上超时 → 直接返回 `-138` 硬失败。
  - ffmpeg-min 二进制（n7.1.5）网络支持已编入（recipe `--enable-network` + http/https/tcp/tls），本 bug 与 ffmpeg-min recipe 无关、**无需重编二进制**。
  - Dart 侧兜底早已到位：非零退出码 → 删半成品 → `_reportFfmpegFailure` 上报 → `return null`，制卡继续（卡片无音频而非崩溃）。所以「不炸整个制卡」已满足，本修复补的是「让音频真抽出来」。
- **[x] ① 根因修复** — 提交 <COMMIT>。`buildFfmpegRemoteInputArgs` 补 `-reconnect_on_network_error 1`：让 ffmpeg http 协议在 connect 阶段 TCP/TLS 错误（含 `-138`/ETIMEDOUT）上自动重连，配合已有 `-reconnect_delay_max 5` 退避预算。单点改动，惠及全部 remote 抽取器（音频/GIF/帧/封面），remote-only、对本地输入零影响。选项 ffmpeg ≥4.3 即有，n7.1.5 已带。
- **[x] ② 自动化测试** — `hibiki/test/utils/desktop_audio_clipper_url_input_test.dart`（提交 <COMMIT>）。纯函数守卫：① `buildFfmpegRemoteInputArgs` 对 http(s) 含 `-reconnect_on_network_error 1`（成对）② 本地输入不含 ③ 用户报错的句子音频命令 `buildFfmpegClipArgs` 也带该开关且置于 `-i` 前。
- **备注**：TODO-1290。connect 阶段网络韧性属外部不可控（googlevideo 间歇丢连），补的是 ffmpeg 自身重连契约缺口；真机验收需在网络抖动/YouTube 制卡下复测，见提交报告「真机验收口径」。
