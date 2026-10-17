# 统一 FFmpeg：播放器与制卡共用一份（2026-10-17）

## 结论

全平台只有**一份 FFmpeg 配方**：同一个版本、同一套补丁、同一份能力下限。每个平台上，播放器（libmpv）和制卡 / 导出 / ASR / 转码（ffmpeg 命令）**链接同一份 FFmpeg 产物**。能播的就能制卡，两边不会再因为 FFmpeg 版本或组件不同而能力漂移。

- 真相源：`tool/ffmpeg-unified/`
  - `recipe.env`：FFmpeg `n9.0.1`（commit `bf1b838f`，arthenica/FFmpeg 的同名 tag 指向同一个 commit）+ FFmpegKitNext `v9.0.0`
  - `patches/ffmpeg/`：所有平台都打的 FFmpeg 补丁（`prepare_ffmpeg_src.sh` 用 `git am` 逐个**提交**，FFmpegKitNext 构建前会 `git checkout` 部分目录，未提交的改动会被静默还原）
  - `patches/ffmpeg-kit-next/`：FFmpegKitNext 补丁
  - `capabilities.json`：制卡 / 导出 / ASR / 转码要求每个平台都具备的组件（下限；构建本身是完整组件集，不用 `--disable-everything`）
  - `verify_ffmpeg_capabilities.py`（桌面：直接运行产物检查）、`mobile/verify_mobile_outputs.py`（移动端：读二进制字节）
- 许可：GPLv3（`--enable-gpl` + x264），与 Fushi 本身一致。

## 为什么要统一

统一前有四份 FFmpeg：Windows 播放器用 MSYS2 的 9.0.1（全量），桌面制卡用 ffmpeg-min 7.1.5（白名单精简），Android / Apple 播放器用 6.1.6（无编码器、无 GPL），移动端制卡用 ffmpeg-kit 6.0。由此出现的问题：

- 能播不能制卡、制卡能力各平台不一致：桌面缺 `crop` 滤镜、缺 `matroska` / `s16le` / `wav` 封装器、缺一批文本字幕解码器；移动端缺 png 编码器、缺 AV1 编码器。
- 证书钉扎补丁（BUG-891）只打在移动端 ffmpeg-kit 上，桌面 ffmpeg-min 不认 `-tls_pin_sha256`。
- iOS 进程里同时加载 `Avcodec.framework`（6.1.6）和 `libavcodec.framework`（6.0）两份 libavcodec。
- 体积：Windows 多带约 52 MB ffmpeg-min，Android 的 libmpv.so 里静态塞了一份 FFmpeg。

## 补丁

| 补丁 | 作用 | 生效平台 |
|---|---|---|
| 0001 `avformat/tls` | `-tls_pin_sha256` 证书指纹钉扎，覆盖 openssl / gnutls / schannel / securetransport / mbedtls 五个后端。FFmpeg 8 起 `tls_verify` 默认为 1，所以设置了 pin 时由共享的 `ff_tls_open_underlying` 关掉 CA / 主机名校验，交给握手后的指纹比对；Android 的 OpenSSL 没有可用的 CA 包，并且系统证书目录用旧式（MD5）哈希命名，按目录查找认不出，所以逐个读入系统证书 | 全部 |
| 0002 `avutil/log` | 主 / 副日志回调：FFmpegKit 锁定主回调之后，libmpv 再调 `av_log_set_callback` 只会设到副回调；主回调把不属于任何会话的消息（会话 0）转交给副回调。否则二者谁后设就会抢走对方的日志（FFmpegKit 会话靠日志拿 ffmpeg 输出） | 全部（只有 Android / iOS 同一进程里两边并存） |
| 0003 `avcodec/videotoolbox` | iOS 上 10-bit 片源硬解改输出 BGRA（GLES 没有 10-bit 纹理）。来自 media-kit 的 libmpv-darwin-build | iOS |
| kit 0001 `ffmpegkit` | FFmpegKit 改用 0002 的主回调接口；会话 0 的消息转给 libmpv | Android / iOS |

已作废的旧补丁：`dash_base_url_escape`（9.0.1 上游已修复）、`vp9_videotoolbox` 解码器（mpv 的 VideoToolbox 硬解用的是标准 vp9 解码器的 `hw_configs`，不需要这个独立解码器）。

## 各平台形态

| 平台 | FFmpeg 产物 | 播放器 | 制卡 / 导出 |
|---|---|---|---|
| Windows x64 | `tool/ffmpeg-unified/windows/build_ffmpeg_msys2.sh`：configure 与 MSYS2 `mingw-w64-ffmpeg 9.0.1-3` 一致（去掉 whisper / librsvg / frei0r / libcaca / openal），shared，装到私有前缀 | `tool/bluray/build_libmpv.ps1` 链接该前缀；`package_libmpv.py` 把依赖闭包统一改名为 `fbd*.dll` | 同一个打包目录里的 `ffmpeg.exe` / `ffprobe.exe`，依赖同一套 `fbd*.dll`；随 `runtime-files.cmake` 自动装到 `fushi.exe` 旁边 |
| Android（arm64-v8a / armeabi-v7a / x86_64） | `.github/workflows/ffmpeg-unified-mobile.yml` → FFmpegKitNext `android.sh`（GPL、x264 / libvpx / opus / dav1d / SVT-AV1 / libwebp / openssl / libxml2 / MediaCodec / zlib） | `hajisensai/libmpv-android-video-build` 的 `fushi/unified-ffmpeg` 分支：`libmpv.so` 动态链接 AAR 里的 `libav*.so` | `third_party/ffmpeg_kit_next_flutter`（AAR 里同一批 `.so`） |
| iOS | 同一个 workflow → `ios.sh --xcframework`（VideoToolbox / AudioToolbox / zlib / bzip2） | libmpv-darwin-build 链接 `libav*.xcframework`（`@rpath`） | `ffmpeg_kit_next_flutter` 的 pod 自带这批 xcframework |
| macOS arm64 | 与 iOS 同源的 FFmpeg framework | `Mpv.framework` 链接它 | `ffmpeg` / `ffprobe` 程序链接同一套 framework |
| Linux / 无头服务端 | 系统 FFmpeg（播放器与 CLI 本来就共用） | 系统 libmpv | 系统或配置指定的 `ffmpeg` |

## 编码与解码策略

- 编码一律用软件编码器（x264 / libvpx-vp9 / SVT-AV1 / libwebp / libopus / aac）：同体积画质更好、支持按 CRF 控制质量、跨设备输出一致；规格（profile / level）写得规范，AnkiDroid / AnkiMobile / QQ 都能打开。
- 解码优先用硬件（Android MediaCodec、Apple VideoToolbox、Windows d3d11va / nvdec 等），dav1d 等软件解码器兜底。

## 落地实测（2026-10-17）

| 平台 | 产物来源 | 体积变化 | 实测 |
|---|---|---|---|
| Windows | 本机 MSYS2：`build_ffmpeg_msys2.sh` → `build_libmpv.ps1`（与以往 libmpv 一样是本地构建） | 运行时 123 → 103 个文件、174 → 160 MB；另删 ffmpeg-min 两个 exe（约 48 MB） | 打包后在只有系统目录的 PATH 下：能力下限、`smoke-test.sh` 全部制卡 / 导出 / 转码形态、`probe_libmpv`（TrueHD / Lua）、mkv dump-cache、`-tls_pin_sha256` 端到端（pin 正确能开、错误 / 不带被拒）、公网 HTTPS（FFmpeg 8+ 默认校验证书） |
| Android | `ffmpeg-unified-mobile.yml` run 39034160156；libmpv：`libmpv-android-build-fushi` run 39037350491（分支 `fushi/unified-ffmpeg` 452510d） | libmpv jar 约 9 → 3 MB / ABI；AAR 30 → 44 MB（多了 x86_64、SVT-AV1、WebP、libxml2、zlib、MediaCodec） | 产物字节守卫：configure、编解码器自证串、补丁标记、Android CA、16 KB 对齐；libmpv `DT_NEEDED libavcodec.so`、不含自带 FFmpeg 符号 |
| iOS | run 39032008713；libmpv：`libmpv-darwin-build` run 39034287620（`fushi/unified-ffmpeg` 0f29c43） | libmpv 包 28 → 9.4 MB；进程内只剩一份 libavcodec | 产物字节守卫；`verify_darwin_archive.py` 拒绝打包 FFmpeg、要求链接 `@rpath/libavcodec.framework` |
| macOS | run 39032008713；libmpv 同上 | libmpv 包 21.9 → 4.6 MB（只出 arm64）；FFmpeg 布局包 15.5 MB（替代 ffmpeg-min 的 28 MB） | CI Mac 上按 `fushi.app/Contents` 布局跑能力下限 + `smoke-test.sh`；libmpv 宿主探测：TrueHD、蓝光协议、碟片菜单、渲染 API |

尚未做的真机验证：Android / iOS / macOS 真机上的播放与制卡（本机只有 Windows），尤其是 Android 15+ 16 KB 页设备、iOS 10-bit HDR 硬解（补丁 0003）、移动端「边播放边制卡」时的日志分流（补丁 0002）。

## 版本升级流程

1. 改 `recipe.env`（FFmpeg tag + commit；FFmpegKitNext tag + commit）。
2. 在新版本上重新应用 `patches/ffmpeg/*.patch`，有冲突就手工移植，`git format-patch` 重新导出。
3. 重编全部平台的产物（Windows 本机、移动端 CI、Darwin CI、Android libmpv CI），全部重新 vendor。
4. 跑 `fushi/test/tools/ffmpeg_unified_*` 守卫。
