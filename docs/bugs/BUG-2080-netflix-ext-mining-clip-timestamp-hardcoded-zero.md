## BUG-2080 · 浏览器扩展 Netflix 制卡的片段时间窗恒为 0，卡上永远显示不出时间
- **报告**：2026-09-03（PR #1161「卡片 Details 栏带上截取片段的时间窗」的代码审查副产物，不是用户报告）
- **真实性**：✅ 真 bug。**缺口有两处，立案时只看到了一处**。① 服务端 `fushi/lib/src/mining/immersion_capture_channel.dart` 的纯函数 `buildImmersionRequest` 把 `clipStartMs`/`clipEndMs` 硬编码成 0；② **浏览器扩展从来不发这两个键**——`tools/browser-extension/content.js` 的 `mineClip` 消息只带 `cueStartMs`/`mineAtMs`，`background.js` 的 `/api/mine` body 同样没有（对比 `mineYoutube` 分支一直发着 `clipStartMs`/`clipEndMs`）。**立案时引作根因证据的 `app_model.dart` `netflixVideoId` 分支是一条死分支**：扩展从不发 `netflixVideoId`（本仓 `BUG-1416` 已记载），且 `app.fushi.reader/immersion_capture` 这个 MethodChannel 全仓无 native 实现。于是 `{clip-timestamp}` 对 Netflix 用户**结构性恒空**
- **[x] ① 已修复**（两处缺口都补；**E2E 未验**——见文末「未验证的部分」）— **扩展侧**：队列项与 `cueStartV` 成对存下 `cueEndV`，`mineClip` 与 `/api/mine` body 补发 `clipStartMs`/`clipEndMs`（取**字幕窗**，不是带 ±200ms 录制余量的 `startV`/`endV`）；**服务端侧**：`hasRange` 从「窗非空」收敛成「窗非空 **且** 有可裁的源」，`clipStartMs`/`clipEndMs` 回归单一语义（卡面时间窗），`buildImmersionRequest` 原样透传。分支 `fix/clip-window-vs-extract-intent`
- **[x] ② 已加自动化测试** — `tools/browser-extension/mine-clip-timestamp-wire.test.js`（**wire 行为**：在 vm 里真跑 `background.js`，断言两端窗进 `/api/mine`、老队列项两键都不发、半个窗两键都不发；外加 `content.js` 取值侧断言「发的是字幕窗不是录制余量窗」）、`fushi/test/mining/immersion_capture_channel_test.dart`（纯函数：窗透传 + 「有窗但抽取意图为假」防回退守卫 + 无窗 payload）、`fushi/test/mining/immersion_mining_engine_test.dart`（引擎：Netflix 形状带非零窗时中止矩阵不变）
- **备注**：与 PR #1161 同域但独立。该 PR 新增的 `{clip-timestamp}` 占位符在本地视频 / YouTube / 互联转发三条路上都通，唯独浏览器扩展的 Netflix 路不通。

### 为什么不是一行改（原始论断 + 实测修正）

把 `clipStartMs: 0, clipEndMs: 0` 直接换成 `p.clipStartMs ?? 0, p.clipEndMs ?? 0` 会让
`hasRange`（当时定义为 `clipEndMs > clipStartMs`）对 Netflix 由恒 false 变成 true。立案时
据此判断会改变既有制卡行为，涉及两处：

- `immersion_mining_engine.dart:437-441` TODO-1303 的无音频中止判据
  （`viaProvidedBytes = providedCoverBytes != null && !hasRange`）；
- `immersion_mining_engine.dart:410` `degradedToStill = req.hasRange`。

**修复时实测推翻了这个论断的一半**（记录在此，避免下一个人继续照着错的前提设计）：

把 `hasRange` 临时改成天真形态（`=> hasClipWindow`）后跑 `test/mining/ test/anki/
test/pages/video_mining_context_guard_test.dart test/sync/forwarded_mine_payload_test.dart`
共 **1529 条，只红 1 条**，且那一条是本次新加的防回退守卫；TODO-1303 中止矩阵与
`degradedToStill` 的既有用例**全绿**。逐点复核原因：

- `:410` 在 Netflix 下**不可达**——`:289` 在进入帧降级阶梯之前就用 `providedCoverBytes`
  写好了 `coverPath`，`if (coverPath == null)` 的 switch 整段跳过。
- `:437/:440` 两种定义下**中止结论相同**：naive 走 `hasRange` 腿，收敛后走
  `viaProvidedBytes` 腿，`requireAudio && audioPath == null` 时都中止。

唯一真正会分叉的形状是「**无 mediaSource/audioSource + 有 stillFallback + 非零窗**」
（`tryCurrentFrame` 只判 `req.stillFallback == null`，**不判 `src`**，所以那条路能在无源时
出封面）。该组合**当前生产不可达**：全仓只有一个调用点设 `stillFallback`
（`fushi/lib/src/pages/implementations/video_fushi/lookup_mining.part.dart:383`，应用内视频
页），而那里 `mediaSource = controller.miningSource = _miningSourceOverride ?? videoPath`
在播放中不可能为 null；Netflix 的 `buildImmersionRequest` 则从不设 `stillFallback`。

**结论**：一行改在今天是行为中性的，但它把「有窗」永久等同于「要裁」，让上面那条分叉
路径变成一颗定时炸弹——下一个既无源又给 stillFallback 的调用方会静默走进区间抽取。
所以仍按下面的方案 2 收敛语义，而不是只填数字。

### 修复方向（择一，动手前先定）

1. **拆语义**（推荐）：给 `ImmersionMiningRequest` 加一对只喂 `AnkiMiningContext` 的显示用字段，`immersion_mining_engine.dart:470` 处 `?? clipStartMs` 回落；`hasRange` 与抽取路径一个字节不动。改动小、零行为变更，代价是多一对字段（要在字段注释里把两个语义的分工写死，否则就是又造一个「同一数字两层两语义」）。
2. **收敛 `hasRange`**：把「引擎要不要裁」从「时间窗非空」改成一个显式的意图字段（如 `mediaSource != null && 有区间`），再让时间窗只表示卡面语义。更干净，但要重新审 TODO-1303 的中止矩阵和 `degradedToStill`，属于独立改动，不该塞进 #1161。

无论哪条，都必须补 `buildImmersionRequest` 的纯函数断言（Netflix payload 带窗 → request 带窗）+ 引擎那两条 `hasRange` 分支的回归用例。

### 最终采用：方案 2（收敛 `hasRange`）

方案 1（另加一对只喂 `AnkiMiningContext` 的显示字段）被否——它正是本条注释自己警告的
「又造一个同一数字两层两语义」，只是把冲突从一对字段挪到两对字段。

实际改动（`fix/clip-window-vs-extract-intent`）：

- `immersion_mining_request.dart`：拆成两个判据。`hasClipWindow => clipEndMs > clipStartMs`
  （纯几何，卡面语义，与 `AnkiHandlebarRenderer.formatClipTimestamp` 同判据）；
  `hasRange => hasClipWindow && (mediaSource != null || audioSource != null)`（抽取意图）。
  后半截与两处抽取点各自已有的前置守卫同源——引擎里 `src = mediaSource`、
  `audioSrc = audioSource ?? src`，`:313` 与 `:506` 本来就先判 `== null`，这条只是把那半个
  判据从调用点提到定义里。
- `immersion_capture_channel.dart`：Netflix 请求原样透传 `p.clipStartMs / p.clipEndMs`。
- `immersion_mining_engine.dart:467` 注释订正：卡面窗判据与 `hasClipWindow` 同语义，
  **不是** `hasRange`。

**「无可观测行为变更」的依据（独立审查订正过一次，原枚举是错的）**：

原先写的是「双 null 来源两端恒是 0」——**漏了 `fushi/lib/src/pages/implementations/web_video_fushi_page.dart`
的网页流媒体队列卡**，那里 `mediaSource`/`audioSource` 都是 null 而 `clipStartMs/clipEndMs`
是**真实字幕 cue 窗**，收敛前后 `hasRange` 由真变假。结论仍成立，但理由是另外两条：
该调用点显式 `requireAudio: false`（掐死 `:437/:440` 的中止条件），且没有 `stillFallback`
（`:410` 的 `coverPath` 恒 null，不可达）。另外两处双 null 来源（Netflix 前台、galgame
外部窗口）两端才是恒 0。

另外，`|| audioSource != null` 那一支已按审查意见删掉：全仓唯一生产 `audioSource` 的
`youtube_clip_miner.dart` 里 `mediaSource` 是**非空类型**，「有 audioSource 无 mediaSource」
在生产中造不出来，实测删掉它 3943 条全绿——是个没有调用点、没有测试、没有语义的析取项。
两个抽取点（`:313`/`:508`）自己已判过源，改用 `hasClipWindow` 只问窗几何。

### 未验证的部分（不要据此宣称「已修好」）

**从未有一次真机 Netflix 制卡观察到卡面出现 `HH:MM:SS - HH:MM:SS`。** 现有证据全部是：
单元测试（wire 行为 + 纯函数 + 引擎）、静态追链、变异实测。链路的每一段都被钉住了，
但「装上扩展、开一集 Netflix、制一张卡、卡上真的有时间」这一步没做——需要浏览器扩展
环境 + Netflix 会话。按仓库纪律，这条在补上真机复测前不得对外宣称已修复。

### 已知残留：`{clip-timestamp}` 在两条扩展来源上语义不一致

Netflix 路现在发的是**字幕窗**（`cueStartV`/`cueEndV`），而 YouTube 路
（`content.js` 的 `mineYoutube`）发的是 `q.startV`/`q.endV`，即**带 ±200ms 录制余量的窗**。
两者截断到秒后最多差 1 秒。根子是 YouTube 那两个数在该路径上兼着**抽取参数**
（服务端拿去 ffmpeg 裁），不是纯显示值——也就是本条 bug 消灭的「同一数字两层两语义」
在 YouTube 路上原封不动。要统一得给 YouTube 另加一对显示用 wire key，属独立改动。
