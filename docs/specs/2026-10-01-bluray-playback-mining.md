# 蓝光原盘播放与制卡

## 使用路径

导入可读取的 BDMV 目录后，库里的标题以 `BDMV/PLAYLIST/*.mpls` 为稳定身份。
播放仍复用既有播放器：完整单片段可以直接播放 M2TS，其余按 MPLS IN/OUT 组成 EDL。
缺失 CLPI 时也按 MPLS 截取，避免播放、章节、外挂字幕与制卡出现不同零点。
这里描述直接播放标题的路径：支持匹配到播放配置的 AACS 1 光盘及加密目录副本，
不增加 ISO 挂载。原盘交互菜单使用独立导航会话（`bd://menu` 由 libbluray 直接读盘，
不经下面的 AACS 内容解码会话），见
[蓝光原盘交互菜单](2026-10-08-bluray-original-menu.md)。

## 加密输入

Windows、macOS、Linux、Android 和 iOS 共用 `AacsContentDecoder` 与
`AacsMediaSession`，不依赖平台专用解密 DLL。根据 `Unit_Key_RO.inf` 的 SHA-1
精确匹配配置中的 VUK，解出 CPS unit keys，再逐个 6144 字节单元解密。明文必须通过
32 个 TS 同步字节校验，错误配置或损坏数据不会作为可播放数据返回。

优先使用用户已有 KEYDB 或应用私有缓存；需要时从 LibreELEC 官方配置文档引用的
FindVUK 数据库经固定 HTTPS 地址下载。下载不包含程序，不跟随重定向，限制压缩包
大小、条目和解压大小；配置与密钥仅保存在本机，不进入 Git、卡片、日志或同步数据。
缺少该盘配置、网络失败、格式不支持分别给出可读错误。AACS 2、BD+、光驱认证及
总线加密不由该内容解码器处理。

解密在独立 isolate 里进行，通过随机能力 URL、仅回环监听的 HTTP Range 输入供
播放器和 FFmpeg 读取。读写有背压，seek 对齐解密单元后按请求切片，不整盘导出。
MPLS、播放进度和卡片来源仍持久化原文件身份。换片、取消、释放媒体句柄和退页时
关闭会话；保护盘的原生文件日志关闭，Dart/FFmpeg 日志中的临时 URL 脱敏。

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
- `aacs_content_decoder_test.dart`：独立 AES 已知向量、CPS 切换及错误密钥。
- `aacs_configuration_test.dart`：精确盘 ID、配置来源、TLS、缓存及压缩包限制。
- `aacs_stream_relay_test.dart`：Range、并发 seek、关闭、损坏输入、日志脱敏。
- `aacs_native_media_test.dart` / `aacs_real_disc_itest.dart`：显式提供用户光盘与本机
  KEYDB 路径后，验证真实加密媒体输出及真实应用播放；默认不会访问用户光盘。

桌面 FFmpeg 配方新增滤镜后，Windows 与 macOS 入库二进制必须同时刷新，
`ffmpeg_min_vendored_recipe_guard_test.dart` 是发布前的硬检查，不能只改配方。

### 本轮实测与待验

Windows 入库 FFmpeg/FFprobe 已重编，完整 `smoke-test.sh` 通过；使用该 FFmpeg
运行真实两阶段制卡（先抽 AAC，再与 MPLS 视频合成）通过，包含 H.264 B 帧、
非关键帧截取与跨片段接缝。Windows 实际应用集成测试通过：原盘标题和导出的 MP4
均能打开，时长与跳转位置符合预期。Flutter 全量分析、引擎 234 项测试通过；
字幕相关旧守卫更新后与原生制卡测试合跑 21 项通过。

加密输入新增实测使用用户 E 盘：多个离散位置与官方 libaacs 输出逐字节一致，
真实帧、音频和同步 MP4 输出通过。发现随包 FFmpeg 缺少 `pcm_bluray` 后补入配方；
桌面二进制统一由 CI 构建与验收，Android/iOS 现有组件已包含该解码器。
其他系统的共享代码与编译能力，不等于已经完成对应设备验收；移动端、整部电影
尾部的性能，以及 ASR 模型实际转录到最终 Anki 落卡的设备端全流程仍需分别验证。
