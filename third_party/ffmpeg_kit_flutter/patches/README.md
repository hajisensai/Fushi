# ffmpeg-kit TLS 证书指纹钉扎补丁

## 背景（BUG-891）

移动端自编 ffmpeg-kit 是 **min 变体，不含 gnutls**，导致把 `https://` 流 URL 交给
ffmpeg（远端视频制卡句子音频 / GIF / 帧封面）时报 `Protocol not found`。见
`docs/bugs/BUG-891-remote-mining-audio-tls.md`。

修复分两部分：
1. **重编时加 `--enable-gnutls`**（补齐 https/tls 协议）。
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
| gnutls | `tls_gnutls.c` | Android / iOS / Linux 桌面（ffmpeg-min `--enable-gnutls`） |
| SecureTransport | `tls_securetransport.c` | macOS 桌面 |
| SChannel | `tls_schannel.c` | Windows 桌面 |

openssl 后端本项目未编译，未打补丁。

## 应用方式（Mac 重编 ffmpeg-kit 时）

补丁基于 **ffmpeg 6.0**（arthenica ffmpeg-kit 6.0.3）。在 ffmpeg 源码根应用：

```bash
cd ~/ffmpegkit-build/ffmpeg-kit/src/ffmpeg
patch -p1 < <本目录>/ffmpeg-tls-pin-sha256.patch
# 然后 android.sh / ios.sh 加 --enable-gnutls 重编
```

桌面 ffmpeg-min（`tool/ffmpeg-min/`）重编时同样在其 ffmpeg 源码根应用本补丁，
使 Windows/macOS/Linux 桌面也走真钉扎（否则桌面维持上游默认 `tls_verify=0`
的「接受任意证书」——能通但不钉扎）。

## 用法

```
ffmpeg -tls_pin_sha256 <64位hex，可带冒号> -i https://自签主机/... ...
```

指纹格式：证书 DER 的 SHA-256，小写/大写均可，冒号与空白忽略。
