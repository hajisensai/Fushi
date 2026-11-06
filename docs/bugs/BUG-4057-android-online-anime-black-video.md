## BUG-4057 · Android 在线动画源视频全部黑屏（只有播放器界面）
- **报告**：2026-11-03（反馈 l0Cygl4B2X，标题「all anime」，正文印尼语：「所有动画视频都没有画面，换成 skia 或 default 也一样全黑，只有播放器界面」；vivo V2157 / Android 14（SDK 34）/ arm64 / app 3.0.0+1001976302，界面语言 en、系统 ja_JP，0 张截图）
- **真实性**：❓ 未复现，证据不足以定位，不改代码。
  - 本条被分到「刮削」组是误分：诉求是**播放**（在线动画源取流后的画面），与刮削 provider / AniDB 限流无关。
  - 日志（最后 400 行）里与视频相关的只有两条 `VideoFushi.remoteSubtitle`：在线动画源
    （Mihon 动画扩展，`AnimeSourceVideoClient.getRemoteVideoSubtitle`
    `fushi/lib/src/media/video/online/anime_source_video_client.dart:483`）的外挂 `.vtt` 字幕下载
    HTTP 403——只影响字幕，不会让画面变黑。其余是 Google Drive 同步断网、Mihon 漫画源 523 /
    InterruptedIOException、`getLatestAnime` UnsupportedOperationException（某扩展不支持「最新」列表），
    都与画面无关。日志里**没有任何 `[VIDEO-DIAG]` 行、没有 mpv 打开 / 首帧 / 纹理握手记录**，
    无法区分下面几种互斥的根因：
    1. **渲染合成层**（BUG-535 / BUG-597 那一类：解码出帧但 Flutter 纹理不出画）。用户说「换 skia /
       default 也一样」——app 内已无渲染后端开关（五端全线 Impeller，`docs/agent/rules-detail.md#impeller`），
       这里大概率指 Android 开发者选项里的 HWUI 渲染器，它不改变 Flutter 引擎自己的后端，所以这句话
       排除不了也坐实不了合成层问题。
    2. **取流 / 分片层**：伪装成图片的 HLS 分片（BUG-2609，中继剥前缀
       `fushi/lib/src/utils/net/hls_relay_normalizer.dart`）或分片扩展名白名单
       （BUG-2630，FFmpeg `extension_picky`）在某个扩展 / CDN 上没覆盖到时，表现是起播即 EOF 或无画面。
    3. **只发生在某一个扩展**：日志里的 CDN 只有一个（字幕域名同一家），「所有动画」可能就是「这个扩展的所有集」。
  - 无同型号真机、无该扩展的真流，本轮无法复测。
- **[ ] ① 未修复** — 需要的证据（任一即可推进）：同一集播放时的完整诊断日志（含 `[VIDEO-DIAG]`
  texture id / wid / vo / 首帧行）、有没有声音、进度条是否走动 / 是否一开就到片尾、所用扩展名称；
  本地视频文件是否同样黑屏（区分合成层与取流层）。
- **[ ] ② 未加自动化测试** — 根因未定位。
- **备注**：未复现；不属于刮削域。2026-11-05 真机复现尝试见下。
- **2026-11-05 真机复现尝试（未复现）**：
  - **反馈原始附件补读**（只读拉取，`.codex-test/bug4057/fb-detail.json` / `fb-log.txt`，3868 行，10-04～11-03）：`meta.app_version=3.0.0+1001976302` 即 **10-17 的正式版 v3.0.0**，早于 c22f68d75af（10-25「Impeller everywhere」）。那一版 Android 默认就走 Skia（BUG-597 第 2 步的「未设置 → 关 Impeller」），播放器里还有「切 Skia」入口——用户说「换成 skia / default 也一样黑」＝**在 Skia 下同样黑**，所以这条与 Impeller 合成层无关，也和当前 develop 的渲染栈（全线 Impeller、10-24 换过的 rdisc1 / bluray-menu libmpv jar）不是同一套。`device=vivo V2157`、`os_version=PD2166F_EX_A_8.10.20`、窗口 876x393（横屏）；公开 Geekbench 记录里 V2157 的主板是 `k6833v1_64`（MT6833 / 天玑 700，GPU 通常是 Mali-G57，**未核实**）。日志里与画面相关的只有：10-18 一次连串 78 条 `Failed to open http://player.zilla-networks.com:443/segs/<id>/00N.html.`（分片请求本身打不开）、10-20 / 10-29 各 3 条 `Could not open codec.`；11-01～11-03（报告前几天）只有外挂 `.vtt` 字幕 403，没有任何播放器错误。旧记录里要的 `[VIDEO-DIAG]` 行已经不存在——那套埋点在 5ee9db4d20c 整体删除，现在对应的是「设置 › 系统与关于 › 诊断 › 视频 / 查词诊断日志」开关 + 「导出视频诊断日志」（统一时间轴 + libmpv verbose `video_mpv_log.txt`）。
  - **真机**：小米平板 5（`21051182C`，Snapdragon 860 / Adreno 640，Android 17，序列号 `43f8ed58`），upstream/develop `df8bddcd161` 本地编的 arm64 debug 包，以临时 `applicationIdSuffix ".pvtest"` 与用户装机包并行安装（该行未提交；测完已卸载，用户包 `3.3.0-debug.23480` 未动）。导入本地 APK 装 yuzono 仓库的 KickAssAnime 14.63 / AnimeKai (Unoriginal) 16.10 / AnimeGG 14.2 / AnimeOnsen 14.10，打开视频诊断日志后逐个播第 1 集：
    - KickAssAnime《Mashle》Ep1：HLS、`.jpg` 名裸 TS 分片（libmpv 日志 `Option extension_picky=0 was set due to known FFmpeg bugs`），`Using hardware decoding (mediacodec-copy)`、`VO: [gpu] 1920x1080`、`Initializing GPU context 'android'`；logcat `VideoOutput: onSurfaceAvailable` + `newGlobalRef`（SurfaceProducer 握手成功）——**出画**（`kaa-play1.png`）；
    - AnimeKai《Sakamoto Days》Ep1（伪装 PNG 前缀分片，BUG-2609 那家）——**出画**（`kai-play1.png`）；
    - AnimeGG《Bleach》Ep1（直链 mp4，640x480）——**出画**（`gg-play1.png`）。
  - **排除了什么**：当前 develop 在 Adreno 上，在线源的取流（HLS / 伪装分片 / 直链 mp4）→ mediacodec-copy 硬解 → libmpv `vo=gpu` → SurfaceProducer 纹理 → Flutter 合成全链路正常，不是「在线源通用」问题。
  - **排除不了什么**：① 用户的 GPU 族（大概率 Mali）——BUG-597 的 Mali-G76 黑屏就是同类机型专属，Adreno 上测不出；② 用户的版本（3.0.0 + Skia + 旧 libmpv jar）与当前 develop 差一整套渲染栈，本机不能降装 3.0.0（用户包是 3.3.0，降版本会清数据）；③ 本机 Flutter 日志在两个进程里都先后打印 `Using the Impeller rendering backend (Vulkan)` 与 `(OpenGLES)`，实际合成后端没有从日志定下来，Vulkan 外部纹理路径是否覆盖到**不确定**。
  - **下一步需要的证据**（任一即可推进）：用户升级到 ≥ 10-25 的调试版 / 下一正式版后是否仍黑；若仍黑，打开「视频 / 查词诊断日志」复现一集后「导出视频诊断日志」（看 `vd` 是否 `Using hardware decoding` / `Could not open codec`、`VO: [gpu]` 是否出现、有没有 `VideoOutput: onSurfaceAvailable`）；本地视频是否同样黑；所用扩展名。证据：`.codex-test/bug4057/`（截图、`kaa-mpv.txt`、`kaa-logcat1.txt`、`last-mpv.txt`、`fb-log.txt`、`tools/ui.py`）。
