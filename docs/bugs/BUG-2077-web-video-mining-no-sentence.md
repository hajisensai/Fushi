## BUG-2077 · 网页视频制卡：卡里没有例句、没有封面
- **报告**：2026-09-03（用户：B 站外挂字幕页制卡，卡上既没有句子也没有截图）
- **真实性**：✅ 真 bug。根因 `tools/browser-extension/bridge-shim.js`（修前）里制卡分流的判据写成**站点名枚举**
  `site !== 'youtube' && site !== 'netflix'`，把三件互相正交的能力绑死在一个 if 上：
  ① 有没有可裁的原始流 ② 有没有当前字幕行 ③ 能不能取当前解码帧。
  于是 bilibili.com（②③ 俱全、只缺①）整个落进「普通网页」分支，那条分支只发 `{fields, sentence}`，
  而 `sentence` 只从 Netflix 的字幕 DOM 直读、读不到就退回弹窗内选区 → 卡上没有句子；画面明明就在
  `<video>` 里，这条路一张图都不发 → 卡上没有封面。每加一个站点就得改一处 if，正是应该被数据结构
  消掉的特殊情况。
- **[x] ① 已修复** — 判据从站点名换成**能力**：`fushiClipSource()`（`tools/browser-extension/subtitle-providers.js:45`）
  返回 `{kind, id, mode}`，`mode==='queue'` 才入队批量剪辑，其余一律**立即出卡**并尽力附带媒体：
  例句取整轨/DOM 当前行，封面取 `<video>` 的**当前解码帧**（`tools/browser-extension/frame-capture.js`，
  不是截屏），bilibili 再带上 `{bvid, 分P, 时间窗}` 让服务端从原始 DASH 音轨裁句子音频
  （`fushi/lib/src/mining/bilibili_clip_miner.dart`）。
- **[x] ② 已加自动化测试** — `tools/browser-extension/web-video-mine.test.js`（分流 + 例句 + 封面 + 时间窗，
  在受控 vm 里真加载 `bridge-shim.js`）、`tools/browser-extension/clip-source.test.js`（`fushiClipSource`
  能力判据 + 裁切窗边距原语）、`tools/browser-extension/frame-capture.test.js`（取帧不变式 + DRM 降级）、
  `fushi/test/mining/immersion_mining_engine_test.dart`（分离音轨物化判据两个方向）、
  `fushi/test/mining/immersion_capture_channel_test.dart`（来源判据原语）。
- **备注**：本条随 PR #1172 落地。四条一并收在这里，都是同一个「站点名当判据」根因的分支：
  1. **物化判据收回到原因上**：`range=` 查询参数分片是 googlevideo 的**限速绕行**，判据过去写成形状
     （「`audioSource` 非空且是远端 http」）。别的站点的分离音轨走进来，`range=` 被忽略后每一片都返回
     整个文件，会把同一个流反复下满 `maxBytes`。现按 host 判：`audioSourceNeedsRangeMaterialization`
     （`fushi/lib/src/utils/misc/desktop_audio_clipper.dart:110`），非 googlevideo 直接对 URL `-ss` 裁。
  2. **DRM 黑帧**：`frame-capture.js` 文件头承诺「SecurityError 与全黑帧**两种都判失败**」，实现却只处理了
     前一种。EME 硬解路径下 Chrome 典型行为是画黑帧而不污染 canvas → 用户静默得到一张纯黑封面的卡。
     现加 `getImageData` 抽稀采样（8×8=64 点）+ **保守**判据 `fushiSamplesAreUniformBlack`：必须
     「全部低于亮度阈值 **且** 逐通道零方差」才判失败，正常暗场景（带编码噪声/渐变）不会被误伤；
     代价是真正淡出到纯黑的那一帧也会退成纯文本卡（纯黑封面本无信息，这个方向的误判无害）。
     **未在真实 DRM 站点上验证**：需要真机浏览器 + 付费账号，本机无法复现 Chrome 在 Widevine/PlayReady
     下究竟抛异常还是画黑帧。此处只保证「若真画出常量黑帧则判失败」，不宣称已覆盖某个具体站点。
  3. **裁切窗边距两条路不同源**：入队批量剪辑写死 `startV-200 / endV+200`，立即出卡发的是**裸 cue 窗**
     → 同一句话在两条路上被裁成不同长度，叠上 DOM 字幕轮询粒度，B 站句子音频开头容易被切掉一点。
     现收成一个原语 `fushiClipWindowWithMargin`（`tools/browser-extension/subtitle-providers.js`），
     两条路同源；`cueStartMs`（静态帧「字幕开头」档定位那一帧用）仍是**真句首**，不带边距。
  4. **失败提示语硬编码 Netflix**：兜底失败分支写死「Netflix 制卡失败」，而 `manifest.json` 已把
     primevideo / amazon.\* / hulu.jp / tver.jp / bilibili.tv 纳入范围，它们 `fushiClipSource()` 返回 null
     → 走同一条兜底路 → 失败时用户看到「Netflix 制卡失败」。现与封面命名共用同一个判据原语
     `immersionPayloadFromNetflix`（`fushi/lib/src/mining/immersion_capture_channel.dart`），
     非 Netflix 来源报「网页视频 制卡失败」，日志 tag 也分成 `Anki.mineImmersion.web`。
- **已知未覆盖（不在本条修复范围，如实记录）**：
  - `fushi/lib/src/models/app_model.dart` 的 bilibili 分支给引擎传了 `imageMode` / `stillFormat`，但同分支
    `mediaSource: null` 且恒带 `providedCoverBytes` → 引擎的封面阶梯不会被求值，封面**恒是扩展在制卡那一刻
    取的 JPEG**（`web_shot.jpg`）。选「字幕开头截图」的用户拿到的是制卡时刻的帧；选 PNG/WEBP 的拿到的仍是 jpg。
    与 Netflix 那条路的 BUG-1416 同形状（须在「产字节这一层」按偏好分流），但 B 站这边要在**扩展侧**按
    `cueStartMs` 重新取帧才能根治，属另一件事。
  - B 站多音轨按 `bandwidth` 最大取；Dolby/FLAC 分别在 `dash.dolby.audio` / `dash.flac.audio`，不在
    `dash.audio` 数组里，所以现在选不到。这是**靠 B 站 API schema 兜着**、不是代码不变式。
