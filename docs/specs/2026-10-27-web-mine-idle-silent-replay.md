# 网页视频制卡队列：空闲自动制卡 + 静音重放（Windows）

日期：2026-10-27　状态：已实现（本 PR）　范围：Windows 网页视频播放页（Netflix 等需要逐句重放的站点；YouTube 走直裁流，不进队列）

## 背景

网页档点「制卡」只入队（`web_mine_queue`，schema v90），之后要用户手动点「制作队列中的卡片」：
页面换成可捕获的内置档，逐句 seek → 播 → 截帧 → 从 WASAPI loopback 环形缓冲回取音频。
两个问题：

1. **不会自动做**，用户以为空闲时会自动制卡。
2. **重放外放声音**，而且 loopback 录的是默认渲染端点的整机混音：用户同时放的音乐 / 通话也会被录进卡里。

不能简单把网页静音：EME（Widevine）内容的声音 Web Audio / `captureStream` 拿不到，只能在系统层录；
网页一静音，系统层就没有东西可录。

## 可行性实验（真实测量）

Probe 与 harness 源码不入库（scratchpad），结论如下。音源 = 独立进程循环播放 440 Hz 正弦；
「process loopback」= `ActivateAudioInterfaceAsync(VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK)` +
`PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE`；「扬声器侧」= 同时对默认渲染端点做系统 loopback。
`tone` = 440 Hz 能量占比（纯度，满音量基线 ≈ 0.987 / 1.000）。

| 条件（目标进程音频会话 `ISimpleAudioVolume`） | process loopback | 扬声器侧 |
|---|---|---|
| 满音量（-26 dBFS 音） | peak 0.04999，tone 0.987 | 混入用户别的声音（peak 0.40） |
| `SetMute(TRUE)` | **全 0** | 无此音 |
| `SetMasterVolume(0)` | **全 0** | 无此音 |
| 0.1 / 0.01 / 1e-3 / 1e-4 | peak 精确 ×0.1 / ×0.01 / …，tone 不变 | 同比例变小 |
| **1e-5** | peak 4.9988e-7，**tone 0.987310（无损）** | **100% 包被标 `AUDCLNT_BUFFERFLAGS_SILENT`** |
| 1e-6 | peak 4.9988e-8，tone 0.987340（无损） | 100% 静音包 |
| -60 dBFS 音 @ 1e-6（绝对值 1e-9） | rms 6.8884e-10，tone 0.987185（无损） | 100% 静音包 |

结论：

- process loopback **在会话音量之后**取样（静音 / 0 音量直接没数据），所以「静音会话 + process loopback」不可行；
  WebView2 `IsMuted`（Chromium 把流改投内部 muting sink、根本不进系统）同理不可行。
- 但会话音量是**线性浮点增益**，process loopback 的 float32 流在 1e-6 量级仍逐位还原。
  → **把目标进程树的会话压到 1e-5（-100 dB），采集侧乘 1e5 还原**：扬声器侧被引擎判为静音，录音无损。
- process loopback 天然只录目标进程树：用户别的声音不会再混进卡里（顺带修掉了旧方案的串音）。
- 实测 Fushi 的 WebView2 浏览器进程（`msedgewebview2.exe`）是 `fushi.exe` 的子进程，能按
  `NtQueryInformationProcess(ProcessCommandLineInformation)` 读命令行里的 `--user-data-dir`
  精确认出**内置档**那一套（与全局查词 / 漫画等其它 WebView2 环境区分开）。
- 端到端（真 runner 源码 `audio_loopback_capture.cpp` 编进 harness）：silent 模式扬声器侧 96000/96000 帧静音，
  回取 rms 3.5340e-2 / peak 4.9988e-2 / tone 1.000000，与非 silent 逐位一致；停止后会话音量还原为 1。
- **激活之后才出生的子进程也在录制范围内**（Chromium 的音频服务进程按需拉起，这条决定方案成立与否）：以 harness
  自身为目标、激活后再 `CreateProcess` 拉起音源，非 silent 回取 tone 1.000000；silent 时该子进程会话以满音量出生
  （对照组扬声器侧 440 Hz 幅度 0.047），靠 `OnSessionCreated` 当场压低，扬声器侧从第一个 2 s 窗口起 100% 静音包，
  回取仍无损。
- 不能压低**采集方自己**的会话：harness 把自己放进目标树时回取被再衰减一遍（3.53e-7 而非 3.53e-2）。native 一律
  跳过本进程 pid（Fushi 本身也不在 WebView2 浏览器进程树里，实际不会触发，仅作防线）。
- silent 采集在跑时 `restoreDucked` 直接返回 0（否则会把有意的压低还原、站点外放）。

### 实测到的风险

**Windows 按可执行文件持久化会话音量。** probe 有一轮在音源进程退出后才去还原（会话已不存在、还原落空），
下一次启动的同名进程就从 1e-6 起步。对我们意味着：

- 静音重放中途 Fushi 被杀 → 内置档 WebView2 下次开播仍是 -100 dB。兜底：内置档页面第一次开播时调
  `restoreDucked`（目标树里音量 ≤ 1e-4 的会话还原到 1.0；没人会手动调到 -80 dB）；采集开始时把已在压低值上的
  会话的「原音量」记为 1.0。
- 持久化键是可执行文件（`msedgewebview2.exe` 是所有 WebView2 应用共用的运行时），**极端情况下**（重放中途
  崩溃且下次 Fushi 开播前）别的 WebView2 应用新建的音频会话也可能从压低值起步。窗口只在「重放中崩溃」到
  「下次在 Fushi 里开播」之间；已在 PR 里写明。
- 同一机制的正面作用：重放期间 Chromium 新建的音频会话（音频服务进程按需起）会直接从压低值起步；再加
  `IAudioSessionNotification::OnSessionCreated` 即时压低 + 250 ms 兜底重扫，空窗内的满电平样本（放大后会削顶）
  按静音写入。

process loopback 需要 Windows 10 build 20348+（消费版即 Windows 11）；更早的系统激活直接失败。

## 方案

### native（`fushi/windows/runner/audio_loopback_capture.*`，method channel `app.fushi.reader/audio_loopback`）

- `start` 不带参数 = 原系统混音（galgame 路径，行为不变）。
- `start {userDataFolder, silent}` = 进程树模式：在本进程子进程里找 `--user-data-dir` 为该目录（或其 `EBWebView`）
  的 WebView2 浏览器进程 → process loopback（固定 48k 立体声 float32，`AUTOCONVERTPCM`）；`silent` 时先压低该树
  所有渲染端点上的会话再握手返回。失败带 `code`：`target_not_found` / `unsupported` / `busy`（另一种来源在跑）/
  `start_failed`。
- `stop` 先停采集、再还原会话音量（还原那一刻的满电平样本不进缓冲）。
- `restoreDucked {userDataFolder}`：崩溃残留兜底，见上。
- 平台插件与 method channel 按 CLAUDE.md 留在 runner（C++），不进 Rust 胖核心；调用粒度是「一轮重放一次 start /
  每句一次 grabRecent」，与改动前相同。

### 空闲判定（`fushi/lib/src/mining/web_mine_idle.dart`）

**「空闲」= 网页播放页开着且用户已暂停（本页没在播）、队列非空、整台机器连续 2 分钟没有键鼠 / 触控输入。**

选它而不是「用户离开播放页后」的理由：

- 重放需要一个加载着该站点的内置档 WebView。离开播放页 = 页面销毁，要另起一个隐藏宿主；隐藏 / 被遮挡的 WebView2
  会被 Chromium 降帧、后台视频轨优化会停解码，截帧不可靠。在用户留下的页面里原地跑最稳。
- `GetLastInputInfo` 是整机判据（与锁屏 / 屏保同一信号）：用户切到别的程序干活也算「在用电脑」，不会被抢页面；
  我们驱动播放器不产生输入事件，不会自己把自己「唤醒」。
- 不另判「Fushi 有没有别的媒体在播」：process loopback 只录内置档 WebView2 进程树、只压低它的会话，Fushi 里同时
  放的音乐既不会被录进卡，也照常出声。

让位：跑的期间 500 ms 一查，空闲时长变短（= 来了一次输入）就请求停止——当前这句录完即停（最长一句 cue 长 + 8 s），
剩下的留在队列，下一次攒满 2 分钟再继续。只用静音录音：起不来（系统不支持 / 找不到进程）就整轮放弃并告知，
**绝不在用户不在场时退回会外放的整机混音**；手动点「制作队列中的卡片」仍保留退回整机混音的旧行为。

宿主位置：不另开窗口、不抢焦点（从不激活 Fushi 窗口）。内置档在原页跑；窗口宿主档 / 原生播放器页的网页档
（4K，帧不可截）空闲时原地换到内置档跑，跑完 / 让位后换回原档（`returnHostingAfterMining`）。

### 可见性

内置档画面顶部一枚状态胶囊（`web_mine_auto_status.dart`，交叉淡入 + 自上滑入，时长走 `fushiMotionDuration`）：
跑的期间「空闲自动制卡中 3/10 · 有任何操作即暂停」；结束后留「成功 N / 失败 M（/ 队列还剩 K）」直到用户关掉
（人不在电脑前，Toast 早过期了）。截帧走 WebView2 自己的 CapturePreview，不含 Flutter 叠层，胶囊不会进封面。
换档交接的那一轮改发 Toast（胶囊会随页消失）。

## 未验证 / 已知缺口

- Netflix 实站端到端（内置档登录态 + 真 EME 音轨 + 2 分钟空闲触发）未在真机跑；音频链路的结论来自上面的独立
  进程实测与真 runner 源码 harness，未在 Chromium 音频服务进程上复测压低 / 还原。
- 被遮挡 / 最小化的 Fushi 窗口里重放的截帧行为未验证（用户空闲时窗口状态不受我们控制）。
- 极端崩溃场景下其它 WebView2 应用的音量残留，见上。未实测 Chromium 的 WASAPI 输出是否带 `AUDCLNT_STREAMFLAGS_NOPERSIST`（若带，残留问题本身不存在）。
- native 采集是进程单例、不带引用计数：同来源二次 Start 复用、任一方 Stop 即停。现有换页路径（交接页先 stop 再换页）不会撞上。
