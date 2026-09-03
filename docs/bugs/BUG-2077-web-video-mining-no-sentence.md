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
  - `fushi/lib/src/models/app_model.dart:7795` 的 bilibili 分支 `mediaSource: null`，封面走
    `providedCoverBytes`（扩展在制卡那一刻取的解码帧，落名 `web_shot.jpg`）→ 引擎那段
    `if (coverPath == null)` 的封面阶梯（`fushi/lib/src/mining/immersion_mining_engine.dart:398`）
    **整段不被求值**。所以选「字幕开头截图」的用户拿到的仍是**制卡时刻**那一帧。与 Netflix 那条路的
    BUG-1416 同形状（须在「产字节这一层」按偏好分流），但 B 站这边要在**扩展侧**按 `cueStartMs`
    重新取帧才能根治，属另一件事。
    - **订正（2026-09-03，PR#1172 复审）**：初稿在这里写「选 PNG/WEBP 的拿到的仍是 jpg」——**不成立**。
      `stillFormat` 在这条路上是**真生效**的：`providedCoverBytes` 那条短路会按它重新编码
      （`immersion_mining_engine.dart:297` 的 `cardScreenshotEncodingFor(req.stillFormat)`），
      扩展给的 JPEG 字节会被转成用户所选格式。恒不生效的只有 `imageMode`（连带 `animatedFormat`）——
      `mediaSource` 为 null ⇒ 抽动图/抽起点帧的前置守卫都失败，服务端路径无 `stillFallback` ⇒ 抽当前帧
      也失败，何况阶梯整段根本不被求值。这两个参数已在复审前置 ① 里从该分支删除：留着不只是死代码，
      还会**稀释按段切片的源码守卫**——`fushi/test/mining/remote_mining_image_mode_test.dart` 用
      「方法起点 → `ImmersionCaptureResult cap =`」切 YouTube 段，bilibili 段正夹在中间，本段每多一份
      同名字面量，就让「删掉 YouTube 那份真正生效的透传」照样绿（实测存活变异 D4；`animatedFormat`
      对 `remote_mining_animated_format_test.dart` 同形）。该分支现由
      `fushi/test/mining/remote_mining_bilibili_branch_guard_test.dart` 守（requireAudio / 零负窗前置门 /
      来源前缀 / mediaSource / 两个恒不生效参数不得回流，五条均已变异实测）。
  - **普通网页只要 DOM 里有任意一个 `<video>`，它的解码帧就会成为卡面图，并把整张卡改道成「视频卡」**
    （2026-09-03 PR#1172 复审补记，**实测**而非推断，现状已钉住、本条不改行为）：
    - 实测链路（在受控 vm 里真跑 `bridge-shim.js`）：普通网页 `fushiSite()==='other'` ⇒
      `fushiClipSource()` 返回 **`null`**——它只看 `location`（`tools/browser-extension/subtitle-providers.js:71`），
      **根本不去 DOM 找 `<video>`**，页面有没有广告视频对它零影响。所以扩展这一侧走的仍是「立即出卡」
      分支，发出的 wire type 恒为 `'mine'`（扩展侧不存在 `mineImmersion` 这种消息类型）。
    - 改道发生在 **Dart 侧**：`fushi/lib/src/sync/immersion_mine_payload.dart` 的 `isImmersion` 只要
      `screenshotBytes != null` 即为真 ⇒ `fushi/lib/src/sync/fushi_remote_api_handlers.dart:195` 把
      `/api/mine` 从 `mineEntry`（纯文本）转进 `mineImmersion()` ⇒
      `fushi/lib/src/mining/immersion_capture_channel.dart` 硬写 `source: AnkiMiningSource.video`、
      封面命名 `web_shot.jpg`、页面标题进 `{document-title}`。
    - **真正由本 PR 引入的变化不是路由，是「立即出卡这条路现在会尽力附带媒体」**：普通网页在换判据之前
      （`site !== 'youtube' && site !== 'netflix'`）也走同一条分支，只是那时一张图都不发、`isImmersion`
      恒假。现在 `frame-capture.js` 的取帧目标是 `document.querySelector('video')`——**文档序第一个**
      `<video>`，不问它是不是用户在看的那个。于是广告位 / 背景视频 / 内嵌视频的画面成了本卡封面。
    - 现状测试：`tools/browser-extension/web-video-mine.test.js` 的
      「普通网页带一个无关 `<video>`：解码帧与页面标题照发（现状，非期望行为）」。此前该文件只测了
      「普通网页**没有** video」。两条变异实测（删掉 `msg.screenshotBase64 = ...` / 删掉
      `msg.documentTitle = ...`）都能把它打红。
    - 要改行为的话根因在 `tools/browser-extension/frame-capture.js` 的
      `document.querySelector('video')`：取帧目标应与「用户此刻在看/查词的那个媒体」绑定，而不是文档序
      第一个 video。**另开 bug，不在本条范围**。
  - B 站多音轨按 `bandwidth` 最大取；Dolby/FLAC 分别在 `dash.dolby.audio` / `dash.flac.audio`，不在
    `dash.audio` 数组里，所以现在选不到。这是**靠 B 站 API schema 兜着**、不是代码不变式。
