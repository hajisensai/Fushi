# ffmpeg-kit 重编说明与 TLS 证书指纹钉扎补丁

> 移动端的 Android AAR / iOS xcframework 都是**手工在构建机编好再拷进本仓**的，配方
> 不随产物走。可复现配方见本目录的 `build_x264_*.sh`，能力守卫见
> `hibiki/test/tools/ffmpeg_kit_mobile_recipe_guard_test.dart`（它会在二进制与 Dart 侧
> 契约脱节时当场红，并指明该重跑哪个脚本）。

## 重编 ffmpeg-kit（TODO-2357 起：必须带 x264）

当前入库产物的 configure 关键开关：**`--enable-gpl --enable-x264 --enable-openssl`**。

- **为什么要 x264**：片段导出全平台统一 H.264。此前移动端退到 libavcodec 原生 `mpeg4`
  （MPEG-4 Part 2），其 Simple/ASP 规格上限远低于导出用的 1080×1920，libavcodec 既不
  clamp 也不写正确 profile/level → 严格硬件解码器有权拒绝，而 ffmpeg 仍 exit 0，
  形成**静默产出打不开的文件**。硬件编码器不是替代路：iOS 配方 `--disable-videotoolbox`、
  Android `--disable-mediacodec`，且当前 FFmpeg 6.0 **根本没有** `h264_mediacodec`
  编码器（那是 6.1 才加入的）。
- **许可**：`--enable-gpl` 让产物从 LGPLv3 变为 **GPLv3**。Hibiki 自身即 GPL-3.0，两者
  一致；`android.sh` / `ios.sh` 会自动写入 `LICENSE.GPLv3` 与 `license_x264.txt`。
  桌面 `tool/ffmpeg-min/build-ffmpeg-min.sh` 早已同样处理。
- **务必保留 `--enable-openssl`**：min 变体默认不含任何 TLS 后端，漏掉它会让远端制卡的
  `https://` 输入回到 `Protocol not found`（BUG-891）。**并在重编前重新应用下面的
  cert-pin 补丁**——补丁打在 ffmpeg 源码上，不随 configure 走。

现成脚本（构建机 `~/ffmpegkit-build/`，内容与本目录下入库副本一致）：

```bash
./build_x264_android.sh   # android.sh --enable-gpl --enable-x264 --enable-openssl \
                          #   --disable-x86 --disable-x86-64 --api-level=24
./build_x264_ios.sh       # ios.sh --enable-gpl --enable-x264 --enable-openssl --xcframework
```

⚠️ **iOS 需要 `nasm`**：x86_64 模拟器切片的 x264 用 x86 SIMD 汇编，缺 nasm 会在
`Building x86-64 platform` 那步报 `(*) nasm command not found` 而失败——**而 arm64 /
arm64e 切片会先成功**，很容易误判成"iOS 编好了"。装法：`brew install nasm`，并确保
`/opt/homebrew/bin` 在构建脚本的 `PATH` 里（入库脚本已包含）。Android 侧不需要
（arm 走 gas-preprocessor）。

产物落点与 vendor 回本仓的位置：

| 产物 | 构建机路径 | 仓内位置 |
|---|---|---|
| Android AAR | `prebuilt/bundle-android-aar/ffmpeg-kit/ffmpeg-kit.aar` | `../android/libs/ffmpeg-kit.aar` |
| iOS xcframework | `prebuilt/bundle-apple-xcframework-ios/*.xcframework` | `../ios/Frameworks/` |

vendor 之后**必须**跑一遍 `ffmpeg_kit_mobile_recipe_guard_test.dart`：它静态抠二进制内嵌的
configure 串与 libavcodec 里的 `libx264` / `x264 - core` 符号，确认"配方声明的"和"真链进去的"
一致，并复核 cert-pin 补丁与 GPL 许可文件未回退。

## 背景（BUG-891）

移动端自编 ffmpeg-kit 是 **min 变体，不含任何 TLS 后端**，导致把 `https://` 流 URL 交给
ffmpeg（远端视频制卡句子音频 / GIF / 帧封面）时报 `Protocol not found`。见
`docs/bugs/BUG-891-remote-mining-audio-tls.md`。

修复分两部分：
1. **重编时加 TLS 后端**——移动端用 **`--enable-openssl`**（openssl 自包含，无 libiconv/
   gmp/nettle/autotools 依赖链，构建可靠；arthenica 的 `--enable-gnutls` 会拖入 libiconv
   的 gnulib/autogen 泥潭，实测在本工具链构建失败）。桌面 ffmpeg-min 各平台维持其原后端。
2. **应用本补丁 `ffmpeg-tls-pin-sha256.patch`**——给 ffmpeg 的 TLS 层加一个
   `tls_pin_sha256` AVOption，做**证书 SHA-256 指纹钉扎**：握手后取对端叶证书 DER、
   算 SHA-256、与传入的指纹比对，命中才接受（绕过 CA/hostname，正好对自签），不命中
   硬失败；不传 pin 时行为与上游一致。

只加 gnutls 不打补丁也能让 https 通，但那是 ffmpeg 默认的 `tls_verify=0`（**接受任意
证书**，可被 MITM）。本补丁把它升级成「只认钉扎证书」，逐字对齐 app 现有的 TOFU 钉扎
（`hibiki/lib/src/sync/tls/hibiki_tls_identity.dart` 的 `fingerprintOf()` = DER 的
sha256），因此**不是安全降级，是真钉扎**。Dart 侧只对已 TOFU 钉扎的 Hibiki 自签主机
传 `-tls_pin_sha256 <fp>`（公网源不传，保持默认）。

## 覆盖后端

`ff_tls_check_cert_pin`（共享助手，`libavformat/tls.c`，用 libavutil `av_sha`）+ 各后端
握手后调用点：

| 后端 | 文件 | 用于 |
|---|---|---|
| OpenSSL | `tls_openssl.c` | **Android / iOS**（自编 ffmpeg-kit `--enable-openssl`） |
| gnutls | `tls_gnutls.c` | Linux 桌面（ffmpeg-min `--enable-gnutls`） |
| SecureTransport | `tls_securetransport.c` | macOS 桌面 |
| SChannel | `tls_schannel.c` | Windows 桌面 |

## 应用方式（Mac 重编 ffmpeg-kit 时）

补丁基于 **ffmpeg 6.0**（arthenica ffmpeg-kit 6.0.3）。在 ffmpeg 源码根应用：

```bash
cd ~/ffmpegkit-build/ffmpeg-kit/src/ffmpeg
patch -p1 < <本目录>/ffmpeg-tls-pin-sha256.patch
# 然后 android.sh / ios.sh 加 --enable-openssl 重编
```

桌面 ffmpeg-min（`tool/ffmpeg-min/`）重编时同样在其 ffmpeg 源码根应用本补丁，
使 Windows/macOS/Linux 桌面也走真钉扎（否则桌面维持上游默认 `tls_verify=0`
的「接受任意证书」——能通但不钉扎）。

## 用法

```
ffmpeg -tls_pin_sha256 <64位hex，可带冒号> -i https://自签主机/... ...
```

指纹格式：证书 DER 的 SHA-256，小写/大写均可，冒号与空白忽略。
