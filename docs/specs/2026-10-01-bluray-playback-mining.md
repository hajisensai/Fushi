# 蓝光原盘播放与制卡

## 使用路径

导入可读取的 BDMV 目录后，库里的标题以 `BDMV/PLAYLIST/*.mpls` 为稳定身份。
播放仍复用既有播放器：完整单片段可以直接播放 M2TS，其余按 MPLS IN/OUT 组成 EDL。
缺失 CLPI 时也按 MPLS 截取，避免播放、章节、外挂字幕与制卡出现不同零点。
这里描述直接播放标题的路径，不负责 ISO 挂载或加密光盘解密。
原盘交互菜单使用独立导航会话，见
[蓝光原盘交互菜单](2026-10-08-bluray-original-menu.md)。

PGS 是画面字幕，仍由播放器显示。字幕菜单增加「语音识别生成字幕」，无文本 cue
时也能使用；识别前抽取当前所选音轨，完成后生成独立 SRT，复用外挂字幕的加载、
查词和制卡路径。原来的字幕文件不覆盖。ASR 取消、换集或播放器替换后不会把结果
挂到另一集；重新定时已有字幕同样使用当前音轨。

## 同一时间轴

`BlurayFfmpegBackend` 装配在 `resolveFfmpegBackend()`，给制卡、ASR、探测和片段
导出提供相同的 MPLS 输入契约。普通视频参数保持原样；MPLS 被展开为本次调用专属
的 ffconcat 文件，输入 seek/时长先与 PlayItem 相交，实际解码只涉及选中的片段。

MPEG-TS seek 未必落在可解码关键帧。当前实现从所选片段的物理开头读起，使用包上的
时间元数据和 `select/aselect` 剔除 IN/OUT 外的解码帧，再归零到标题窗口。
不把第一段的文件时间当成整张盘的播放时间，也不预先转码整张盘生成巨大缓存。
代价是长 M2TS 靠后位置可能需要解码较长前缀；CLPI CPI 索引优化尚未实现，不能把
短素材测试外推为长电影的性能保证。

片段导出强制重编码音视频以保持剪辑边界。生成的 MP4 沿普通视频链路直接播放。
桌面临时清单在 FFmpeg 完成后清理；超时先回收进程再删除。移动端原生解码和
ffmpeg-kit 取消完成的设备验证另需执行。

## 验证

- `bluray_source_test.dart`：单/多片段、缺 CLPI、章节与 EDL 时间域。
- `bluray_ffmpeg_input_test.dart`：输入窗口、映射、字幕/图片、资源清理。
- `bluray_ffmpeg_native_test.dart`：显式设置 `FUSHI_TEST_FFMPEG` 后生成红蓝两段
  MPEG-TS，验证非关键帧起点、跨缝画面、完整音频和同步 MP4。
- `video_speech_subtitle_generation_guard_test.dart`：无字幕入口、所选音轨和异步归属。
- `bluray_playback_mining_itest.dart`：真实应用打开 MPLS 标题与导出的 MP4。
  先用 native 测试的 `FUSHI_BLURAY_FIXTURE_ROOT` 保留合成素材，再以同名 dart-define
  传入集成测试；不触碰用户媒体库。

桌面 FFmpeg 配方新增滤镜后，Windows 与 macOS 入库二进制必须同时刷新，
`ffmpeg_min_vendored_recipe_guard_test.dart` 是发布前的硬检查，不能只改配方。

### 本轮实测与待验

Windows 入库 FFmpeg/FFprobe 已重编，完整 `smoke-test.sh` 通过；使用该 FFmpeg
运行真实两阶段制卡（先抽 AAC，再与 MPLS 视频合成）通过，包含 H.264 B 帧、
非关键帧截取与跨片段接缝。Windows 实际应用集成测试通过：原盘标题和导出的 MP4
均能打开，时长与跳转位置符合预期。Flutter 全量分析、引擎 234 项测试通过；
字幕相关旧守卫更新后与原生制卡测试合跑 21 项通过。

macOS 运行库尚未重编（构建机不可达），因此配方一致性守卫仍失败，本分支不应
推送或合入发布分支。移动端、真实商业盘素材、整部电影尾部的性能，以及 ASR 模型
实际转录到最终 Anki 落卡的设备端全流程尚未验收；当前验证覆盖播放、媒体提取、
字幕接线与合成文件，不把这些缺口计作通过。
