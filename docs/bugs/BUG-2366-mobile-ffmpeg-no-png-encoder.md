## BUG-2366 · 移动端 ffmpeg-kit 无 png 编码器，静图降级链把注定失败记成用户可见错误
- **报告**：2026-09-09（用户：「浏览器插件 Android 的话看后制卡貌似 FFmpeg 有问题」——口头报告，未附 toast 原文/截图/设备型号/站点）
- **真实性**：✅ 真 bug（两条独立缺陷，均为**静态硬证据**定性；用户主诉的具体症状未取得复现材料，见「范围声明」）。

### 现场取证（本机，纯静态，未执行任何移动端二进制）
入库 AAR `third_party/ffmpeg_kit_flutter/android/libs/ffmpeg-kit.aar`：

1. **内嵌 configure 串**（`jni/arm64-v8a/libavutil.so` 明文）尾部：
   ```
   … --enable-libx264 --disable-sdl2 --enable-openssl --disable-zlib --disable-mediacodec --enable-gpl
   ```
2. **`libavcodec.so` 的动态未定义符号表**（NDK 28 `llvm-nm -D --undefined-only`，共 347 条）里
   `deflate*` / `inflate*` / `zlibVersion` **一条都没有**；`d` 开头的全部只有
   `dlopen@LIBC` / `dlclose@LIBC` / `dlsym@LIBC`。
   ffmpeg 的 png 编解码器（`libavcodec/pngenc.c` / `pngdec.c`）硬依赖 zlib 的 `deflateInit2_`，
   符号不在即**编译期就没编进来** → **Android（iOS 同配方）根本没有 png 编码器**。
   - 判据纪律：先前用 `strings | grep -x png` 得到的 "YES" 是**假证据**——ffmpeg 的
     codec descriptor 表（`codec_desc.c`）无论编解码器是否启用都会编进二进制。
   - 同批取证还纠正了两处：AAR 只带 `arm64-v8a` / `armeabi-v7a`（**无 x86_64**，纯模拟器
     场景整条炸，真机不受影响）；TLS 后端实为 `--enable-openssl` 而非
     `desktop_audio_clipper.dart` 注释所写的 gnutls（陈旧注释，cert-pin 补丁确已覆盖
     openssl 后端，`tls_pin_sha256` 字符串在 `libavformat.so` 里）。

### 根因
1. **事实性错误（源头）** —— `fushi/lib/src/mining/immersion_mining_request.dart`
   `MiningStillFormat` 的文档注释（修前）白纸黑字写着「入库的 `ffmpeg-min` 配方 ENCODERS
   含 `png`，**移动端 ffmpeg-kit 的 min 包同样含 png**；链路是给『配方漂了/别的构建』兜底，
   **不是给现状兜底**」。与入库二进制正好相反。桌面那半句是对的，移动端那半句是错的，
   于是后续所有关于「png 那次尝试是罕见兜底」的推理全部建立在错误前提上。

2. **控制流被抄了两份，其中一份漏了规矩（真正的缺陷）** ——
   `MiningStillFormat.encodeAttempts` 的降级循环在两处各写了一遍：
   - `fushi/lib/src/mining/immersion_mining_engine.dart` `tryStartFrame`（修前 `:398`）
   - `fushi/lib/src/mining/immersion_capture_channel.dart` `transcodeClipToCapture`（修前 `:340`）

   动图链 `extractAnimatedClipWithFallback`（`immersion_mining_engine.dart:149`）早就立过规矩
   并写明了理由：「还有降级尝试在后面 → 这次失败是预期内的能力探测，只记诊断日志（否则
   捆绑 ffmpeg 缺编码器时，**每制一张卡都往用户可见错误日志里塞一条「错误」**）」。
   两条静图链**一处都没有**这条规矩——而且是结构性做不到：
   `FrameExtractor`（`immersion_mining_engine.dart:83`）与
   `ClipFrameExtractor`（`immersion_capture_channel.dart:62`）两个 typedef 里压根没有
   `diagnosticOnly` 参数，尽管真身 `extractVideoFrameViaFfmpeg`
   （`fushi/lib/src/utils/misc/desktop_audio_clipper.dart:779`）**一直都有**这个参数。

   合并后果：移动端用户把「制卡静图格式」设成 PNG 后，**每制一张卡**都先跑一次注定失败的
   ffmpeg，再退回 JPEG 成功出卡。封面不丢、卡能出，但那次预期内的失败被原样写进用户可见
   错误日志（与 BUG-1867「best-effort 失败刷进用户错误日志」同型）。

### 范围声明（不含糊）
用户主诉是「Android 上浏览器插件制卡 FFmpeg 有问题」，但未提供 toast 原文、设备（真机/模拟器）
或站点。上面两条是沿真实代码路径排查时查实的**真缺陷**，但**都属于「降级后仍能出卡」**，
不构成制卡失败。若用户的实际症状是**制卡整个失败**，那另有其因，最可能的位置是：
Android 上 YouTube / bilibili 两条扩展制卡分支是 `requireAudio: true`
（`app_model.dart` 的 `_mineYoutube` / bilibili 分支），ffmpeg 抽音频一失败即整卡 abort、
**没有任何降级**；届时 toast 会带上 BUG-1664 加的根因摘要
（`ffmpeg exit N; executable=ffmpeg-kit; stderr=…`），凭那一行可直接定位。本条不替它结案。

- **[x] ① 已修复** —
  - 把「按 `encodeAttempts` 逐个尝试 + 非末次标 `diagnosticOnly`」收成**唯一**原语
    `extractStillWithFallback`（`immersion_mining_engine.dart`，与既有
    `extractAnimatedClipWithFallback` 同构，返回 `StillFrameExtraction` 记录以让扩展名
    跟随**实际编成**的格式）；两条静图链改为共用它，各自那份循环删除。
  - `FrameExtractor` / `ClipFrameExtractor` 两个 typedef 补上 `bool diagnosticOnly`
    （真身早已支持，只是没被接出来）；`transcodeClipToCapture` 里的 crop 包装闭包同步透传。
  - 两个 typedef **未**合并：录制片段那条必须额外下发 `decodeFromStart`，硬合成一个
    只会在调用点长出假参数。共用的是控制流，不是参数表。
  - 修正 `MiningStillFormat` 的文档注释为实测事实，并写明「想让移动端真支持 png，唯一办法
    是构建机重编 ffmpeg-kit 时加 `--enable-zlib` 并重新 vendor」。
  - 提交 `c8c85ce0ff`。
- **[x] ② 已加自动化测试** —
  - `fushi/test/tools/ffmpeg_kit_mobile_recipe_guard_test.dart` 新增组「BUG-2366：png 编码
    能力与 Dart 侧假设一致」：①配方仍含 `--disable-zlib` 且不含 `--enable-zlib`；
    ②`libavcodec.so` 里 `deflateInit2_`/`deflateEnd`/`inflateInit_` 一条都扫不到，并以
    「`libx264` 必须扫得到」作反证防假绿。哪天构建机改成 `--enable-zlib`，这组立刻变红，
    强制回来重审 Dart 侧假设，而不是让注释与二进制继续无声漂开。
  - `fushi/test/mining/mining_still_format_test.dart`：假抽取器记录每次尝试收到的
    `diagnosticOnly`，两条静图链各断言 `[true, false]`；另加**源码守卫**「lib/ 下
    `MiningStillFormat.encodeAttempts` 只许有一个执行点且必须在
    `immersion_mining_engine.dart`」——挡住第三条链路明天再抄一遍循环（这正是本 bug 的根因形状）。
- **备注**：
  - 未做真机验证（用户已定：真机验证取消）。移动端 png 编码器缺失是**静态可判定**的
    （符号表 + configure 串），不依赖真机；`diagnosticOnly` 语义由单测钉住。
  - 顺带查实但**本轮未改**：`desktop_audio_clipper.dart` `buildFfmpegRemoteInputArgs`
    的注释说自编 ffmpeg-kit 是 `--enable-gnutls`，实际是 `--enable-openssl`（陈旧注释，
    补丁两个后端都覆盖，无功能影响）。
  - `MiningAnimatedFormat.encodeAttempts` 目前有两个执行点（`immersion_mining_engine.dart`
    与 `galgame_window_gif.dart`），是既有状态，不在本轮范围。
