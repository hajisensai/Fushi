## BUG-1330 · 浏览器扩展远端制卡（YouTube/Netflix）不吃制卡图片格式偏好，恒出 GIF

- **报告**：2026-08-01（用户：TODO-2503）
- **真实性**：✅ 真 bug。PR#630 让制卡封面动图默认 AVIF 并把「顶格档参数」下沉到
  `MiningAnimatedFormat` 自身，但**只接了 app 内视频与 galgame 两条链路**。浏览器扩展的
  远端制卡入口 `_AppModelRemoteLookupService.mineImmersion` 从没读过这条偏好，YouTube /
  Netflix 制出来的卡一律是 GIF，用户拍板的默认在扩展侧完全没落地。

  根因是**同一个偏好在这条链路上被截断了三次**，且三处必须一起改（只改一处会把
  BUG-1039 打回来）：

  1. `hibiki/lib/src/models/app_model.dart:6035`（改动前）——
     `MiningMediaCompression.resolve(imageTier:, audioTier:)` 不传 `format:`，落到形参
     默认 `MiningAnimatedFormat.gif`。顶格档（imageTier=3）的动图参数由格式自己声明，
     于是用户选了 AVIF 也只拿到 GIF 的封顶值 12fps/960px，吃不到 24fps/1440px。
  2. `hibiki/lib/src/models/app_model.dart:6077`（YouTube 分支，改动前）——
     构造 `ImmersionMiningRequest` 时不传 `animatedFormat:`，值对象默认 gif →
     引擎 `tryGif` 的尝试链只有 `[gif]`，AVIF/WebP 分支永不触发。
  3. `hibiki/lib/src/mining/immersion_capture_channel.dart:125`（Netflix 录制片段，改动前）
     —— `transcodeClipToCapture` 直接调 `extractClipGifViaFfmpeg`，输出路径**硬编码**
     `'${dir.path}/clip.gif'` 且不传 `format:`，也没有「首选格式失败降级 GIF」的链；
     配套 `:93` 的 `providedCoverName` 同样硬编码 `'netflix_clip.gif'`。

  ⚠️ **不能只修 ①**：那个 `compression` 被 YouTube 与 Netflix 两个分支共用，而 Netflix
  这侧写死 GIF。单给 `resolve` 传 format，就会把 AVIF 顶格档的 24fps/1440px 喂进 GIF
  编码器 —— 那正是 BUG-1039 实测「48.9 秒 / 54 MB / 撞 120 秒超时 / AnkiConnect 卡死」
  的配置。**格式与编码参数必须成对传递**。

  附带确认：`ImmersionCaptureChannel.capture`（Netflix native 后台软解实例）全仓**无任何
  native 实现**（`app.hibiki.reader/immersion_capture` 在 cpp/kt/swift 里零命中），恒抛
  `MissingPluginException` 走截图降级，故不需要改 wire 契约。

- **[x] ① 已修复** — 把「降级链」下沉进格式自身，并把三处调用点接上同一个值：
  - `hibiki/lib/src/mining/immersion_mining_request.dart` 新增
    `MiningAnimatedFormat.encodeAttempts`（`gif → [gif]`，其余 `→ [self, gif]`），与
    `maxTierFps`/`maxTierWidth` 同一手法：降级链是格式的属性，不是各调用点各写一遍的
    三元表达式（改动前视频引擎、gal 窗口各持一份拷贝，Netflix 那条压根没有）。
  - `hibiki/lib/src/mining/immersion_mining_engine.dart` 新增共享的
    `extractAnimatedClipWithFallback`（返回 `AnimatedClipExtraction = (path, format)`）：
    逐个尝试 `format.encodeAttempts`，**每次尝试的 fps / 宽度 / 输出扩展名一律取自
    `attempt` 自己**（`capFps`/`capWidth`/`fileExtension`），非末次失败只记诊断日志。
    引擎 `tryGif` 与 Netflix `transcodeClipToCapture` 现在共用这一份，不再各持一份会
    漂开的循环。
  - `hibiki/lib/src/mining/immersion_capture_channel.dart`：`transcodeClipToCapture` 收
    `format` 形参并走上面的共享链，输出路径改成不含扩展名的前缀 `'${dir.path}/clip'`；
    `ImmersionCaptureResult` 新增 `animatedFormat` 字段记录**实际产出格式**（镜像
    galgame 侧 `GalWindowAnimatedCapture` 的 `(bytes, format)`）；`buildImmersionRequest`
    的封面名改成 `'netflix_clip.${cap.animatedFormat.fileExtension}'`。按「用户所选」
    拼名会写出 `.avif` 里装 GIF 字节的卡（Anki 按扩展名判 MIME → 封面不显示）。
  - `hibiki/lib/src/models/app_model.dart` `mineImmersion`：读一次
    `_appModel.videoMiningAnimatedFormat`，同一个值同时喂给 `resolve(format:)`、
    YouTube 的 `ImmersionMiningRequest(animatedFormat:)`、Netflix 的
    `transcodeClipToCapture(format:)`。
  - 移动端：`ffmpeg-kit` 永远不会有 libsvtav1/libwebp，选 AVIF/WebP 必然失败。降级由
    `encodeAttempts` 兜底，且**换格式的同时换参数**（GIF 那次重新 `capFps`/`capWidth`
    到 12/960），输出扩展名也换成 `.gif`，不会产出打不开的文件。
  - 提交：见本分支 `fix/immersion-mining-format`。

- **[x] ② 已加自动化测试** — `hibiki/test/mining/remote_mining_animated_format_test.dart`
  （新增）+ `hibiki/test/mining/immersion_capture_channel_test.dart`（扩展）：
  - `encodeAttempts` 值域（avif/webp → `[self, gif]`；gif → `[gif]`）。
  - `extractAnimatedClipWithFallback`：首选成功时扩展名/参数取自首选格式；首选失败降级
    GIF 时**参数一并换回 GIF 封顶值**（24/1440 → 12/960）——「只换格式不换参数」的
    变异必红（BUG-1039 陷阱）。
  - `transcodeClipToCapture`：注入假抽取器，验证格式跟随 `format:` 形参、产出路径扩展名
    与之一致、`ImmersionCaptureResult.animatedFormat` 带回**实际**格式（含降级场景）。
  - `buildImmersionRequest`：封面名跟随 `cap.animatedFormat`，不再恒 `.gif`。
  - 源码扫描守卫：`app_model.dart` 的 `mineImmersion` 必须把
    `videoMiningAnimatedFormat` 同时传给 `resolve` / `ImmersionMiningRequest` /
    `transcodeClipToCapture` 三处，且 `immersion_capture_channel.dart` 不得再出现
    `clip.gif` / `netflix_clip.gif` 硬编码。

- **备注**：本次不含 TODO-2504（降级探测无缓存、移动端每卡多付一次必然失败的编码调用）。
  另发现远端链路同样没有透传 `videoMiningImageMode`（动图 vs 静态帧），属同类断链但不在
  本次范围。
