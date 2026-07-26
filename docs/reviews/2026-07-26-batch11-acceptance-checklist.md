# 批次 11 真机验收清单（需要真实 galgame / 真实 Magpie）

> 生成日期：2026-07-26。对应已合入 `develop` 的 BUG-1094 / 1096 / 1100 / 1101 / 1102 与
> 「逐行选轨」功能项。这批改动**全部只做过编译 + 单测/源码守卫，没有任何真机验证**，
> bug 文件里逐条写着「真机验收未做」。本清单是把这些缺口翻译成用户可照做的步骤。
>
> 能离屏自动化的部分（BUG-1095 字号设置项、BUG-1098 词头注音、v56 迁移）已单独验过，
> 不在本清单内。BUG-1097（WebView2 状态栏）也列在这里 —— 它需要肉眼看浮窗左下角。

## 0. 通用前置（每次验收都先做一遍）

1. **不要用开发版 app 打开生产库**。本批含 Drift schema v55 → v56；开发构建把库升到 v56 后，
   旧版 app 再打开会触发降级保护（不会毁库，但会拒绝启动）。用正式发布的构建，
   或事先备份 `D:\APP\HIBIKI_date\support\hibiki.db`。
2. 打开日志页：**设置 → 系统 → 诊断 → 「错误日志 (N)」**。
   落盘文件在 `C:\Users\<用户名>\Documents\error_log.txt`（512KB 滚动）。
3. 打开事件页：**游戏 tab → 顶部 chip「兼容性诊断」→ 页面最下方「会话事件」卡**。
   右上可切「全部事件 / 警告及错误」。这是本批大部分判据的主观察面（内存环形缓冲，重启即失）。
4. **把 app 窗口拉宽到 ≥ 840px**。捕获工作台的状态卡在窄窗下是 `compact` 版，
   **不显示降级原因行** —— BUG-1100 的核心判据在窄窗下根本不出现，别误判成「没修好」。
5. 进入路径：底部/侧栏 **「游戏」tab** → 顶部四个 chip：首页 / 游戏库 / **捕获工作台** / **兼容性诊断**。

---

## 1. BUG-1100 · 降级后第一句语音能否真切回引擎 PCM

**这条是本批最重要的一条**：修复前「降级」是终态，永远回不去。

**操作步骤**

1. 捕获工作台 → 「启动并捕获」，用**原始安装路径**启动你平时玩的那个 galgame（不要用副本 / 不要手动先开游戏再附着，除非你要单独验附着路径）。
2. 游戏起来后、**在播放第一句语音之前**，立刻看状态卡。
3. 让游戏播放第一句语音（点到有配音的台词）。
4. 再看状态卡。

**预期现象**

| 时刻 | 状态卡副标题（阶段 · 后端 · 格式） | 降级原因行 | 右侧 pill |
|---|---|---|---|
| 第一句语音之前 | `降级运行 · 系统 Loopback（混音） · …` | **「引擎语音钩子已装好，但游戏还没播放过语音。暂时用系统混音，出现第一句语音后会自动切回引擎语音。」** | 已降级 |
| 第一句语音之后 | `运行中 · 引擎 PCM · 48000 Hz · 2 ch · …` | **消失** | 可用 |

关键点：
- 降级原因行**必须是上面那句人话**，不能再是裸的内部代码 `engine_pcm_unavailable`（那是修复前的表现）。
- 切回引擎 PCM 后，**台词列表不得被重放**（不能突然涌出一堆已经看过的历史台词、序号不得回退）。
  这是修复里刻意避开 `_activateEngine` 的原因，也是最容易出错的地方。

**失败时看哪里**

- 会话事件卡搜 `audio.engine_pcm_late_ready`（severity=success，summary
  `Engine PCM became available and is now the primary audio source`，details 带 pid / sampleRate / channels）。
  - **没有这条事件** → 升格根本没触发。多半是 `_refreshReadinessThrottled` 没跑到，
    或 `readyPcmFormat` 一直为空（引擎 hook 装上了但 native 从没上报有效 PCM 格式）。
  - **有这条事件但 UI 没变** → 是 UI 绑定问题，不是采集问题。
- 状态卡副标题的**后端名**是真相：`引擎 PCM` / `系统 Loopback（混音）` / `游戏资源音频` / `纯人声 OGG` / `无音频源`。
- 如果一直停在 `降级运行`：先确认引擎 hook 真装上了（诊断页管线卡 / 端点卡），
  再确认这个游戏引擎真的走 PCM 路径而不是资源音频路径。

**分阶段记录**（不要把这些混成一个「成功」）：
`process_found → helper_ready → ipc_ready → text_ready → pcm_ready → paired → e2e_verified`。
本条只验到 `pcm_ready` + UI 跃迁；逐句配对是下一条。

---

## 2. BUG-1101 · 降级模式下逐行语音是否还配到上一句 / 冻结窗口够不够长

修复把逐行 Loopback 抓取从「台词到达时立刻向后抓 8s」改成「等 4s 再抓 `4s + 1s preRoll`」，
窗口等价于 `[t0 - 1s, t0 + 4s]`。**4000ms 是经验值，不是硬事实——这条验收的目的之一就是回调它。**

**操作步骤**

1. 让会话处于**降级 / 系统 Loopback** 模式（后端显示 `系统 Loopback（混音）`）。
   若你的游戏总能升格到引擎 PCM，可以在 ⋮「更多」里确认「允许音频降级」已勾选，
   或选一个引擎 hook 不支持的游戏。
2. 正常推进剧情，连续过 **10 句以上**有配音的台词。
3. 对其中 3~5 句分别制卡（点台词里的词 → 查词浮窗 → 制卡 +），然后在 Anki 里逐张回放音频。

**预期现象**

- 每张卡的音频**是这句本身**，不是上一句。修复前是**每一句都配上一句**（设计必然，不是抖动）。
- 语音较长的句子（> 4 秒）**不能被截断**。如果发现句尾被切，说明默认 4000ms 冻结窗口对你的游戏太短，
  **请把实际单句语音长度报回来**（例如「大部分单句 5~7 秒」），这是回调默认值的唯一依据。
- 快速点击跳过时不应出现「音频缺失」大面积报错。

**失败时看哪里**

- 会话事件搜 `audio.loopback_line_locked`（info，`System loopback audio was locked to the captured line`，
  details 带 `lineId` / `backMs`）。
  - `backMs` **应该是 5000**（= 冻结延迟 4000 + preRoll 1000）。
  - 若制卡提前收束，`backMs` 是「实际已等待时长 + 1000」，会小于 5000 —— 这是正常的。
- 搜 `audio.loopback_freeze_exception`（error，`Delayed loopback freeze failed`）→ 冻结任务本身炸了。
- 台词卡上的「已降级」元数据行会显示 `fallbackReason` 原始代码，可用来判断这句走的哪条路径。

---

## 3. BUG-1102 · 音轨面板在引擎 PCM 下选轨是否真生效 / 非引擎下是否真置灰

修复的判据从「音轨列表空不空」换成「后端是不是引擎 PCM」。

**操作步骤（A：非引擎 PCM，控件应该是只读的）**

1. 让会话跑在**系统 Loopback** 或**游戏资源音频**后端。
2. 进「兼容性诊断」→「活跃音轨」卡。

**预期**
- 卡里**必须**出现一段解释文字（即使音轨列表非空 —— 修复前只有列表为空时才显示）：
  - 资源音频 → 「游戏资源音频模式按句直接提取原始语音文件，不经过 PCM 音轨环……」
  - 系统回环 → 「系统回环捕获的是整机混音单流，无法枚举独立音轨。」
  - 其它非引擎后端 → **「只有当前音频后端是「引擎 PCM」时，选轨/排除才会真正影响取音。当前后端下方列表只读。」**
- 「自动选择」radio **不渲染**。
- 每个 tile 的「设为语音轨」「标记为 BGM」两个钮**置灰不可点**；**「试听」仍然可用**（它显式传 sourcePtr，是用户判断哪条是语音的手段）。
- `音频段 0` 的轨**仍留在列表里**（用户需要知道它存在），但整行置灰并追加标注 **「近窗内没有片段」**。

**操作步骤（B：引擎 PCM，选轨应该真影响取音）**

1. 让会话升格到 **引擎 PCM**（见第 1 条）。
2. 音轨列表里挑一条，先「试听」确认它是语音（不是 BGM）。
3. 点「设为语音轨」。
4. 继续推进 3~5 句台词并制卡，回放确认音频来自你选的那条轨。
5. 再对一条明显是 BGM 的轨点「标记为 BGM」，确认后续取音不再混入它。

**失败时看哪里**
- 点「设为语音轨」弹 toast「选择语音轨需要引擎 Hook 会话处于活动状态」→ engine 实例不在。
- 弹 toast「只有当前音频后端是「引擎 PCM」时……」→ 说明按钮本该被禁用却被点到了（**这是 bug，请报**）。
- 会话事件搜 `audio.line_track_*` 系列（见下一条）。

---

## 4. 逐行选轨（新功能 `setLineVoiceTrack`）

**入口不是长按**：捕获工作台的**实时台词列表里，每一行卡片右上角的小图标钮**
（`Icons.multitrack_audio_outlined`，18px），tooltip **「为这句选择语音轨」**。

**按钮不出现的三个前提**（缺一就不渲染，先排查再报 bug）：
1. 会话有 engine source（`hasEngineSource`）；
2. `audioTracks` 非空（去诊断页确认列表真的有轨）；
3. 这一行属于当前会话（历史行没有）。

**操作步骤**
1. 找一句音频配错 / 缺失的台词，点它右上角的音轨图标。
2. 弹窗标题应为 **「这句台词的语音轨」**，每行显示 `语音 N · Hz · ch` + `音频段 N · 能量 X`，右侧有播放钮。
3. 先试听挑对那条，再点选。

**预期**
- 成功 toast **「已把该轨的语音绑定到这句」**；该行音频芯片变「音频就绪」，
  后端变 `engine_pcm`，`fallbackReason` 变 `manual_track_override`。
- 该轨在这句附近没取到语音 → toast **「这条轨在该句附近没有取到语音」**（不是静默失败）。
- 音轨列表为空 → toast「尚无音轨数据」。
- **用户裁决优先**：选完轨后，BUG-1101 的延迟冻结**不得**在几秒后把它盖回混音。
  验法：选完轨等 10 秒再制卡，确认音频还是你选的那条。

**失败时看哪里**（会话事件卡）
- `audio.line_track_selected`（success，`User-selected voice track locked to the line`，details 带 lineId / sourcePtr）= 成功。
- `audio.line_track_unavailable`（warning，`Per-line voice-track override needs a live engine session and a hooked line timestamp`）。
- `audio.line_track_empty`（warning，`The selected track has no PCM around this line`）。
- `audio.line_track_exception`（error，`Per-line voice-track grab failed`）。

---

## 5. BUG-1094 · 手动补录 ⏺ 的 20 秒窗口够不够用

修复把「补录窗口时长」与「回取长度上限」拆开：窗口 8s → **20s**；
回取上限从错误的 8000ms 改成真实的环形缓冲容量 **60000ms**（native `kRingSeconds = 60`）。

**操作步骤**
1. 捕获工作台工具栏 **⋮「更多」→「显示 Hook 文本浮窗」**。
2. 浮窗上一排 8 个按钮，第二个是 **⏺**（第一个是 ↺ 重播）。点 ⏺。
3. 切回游戏，在游戏里点「重播当前语音」。
4. 回来看结果（或再点一次 ⏺ 提前收束）。

**预期**
- 点 ⏺ 立刻 toast **「录音中——请在游戏里重播这句语音」**，浮窗 ⏺ 按钮**高亮**，
  该行音频芯片变「匹配中」。
- **20 秒**内切窗口 + 在游戏里点重播来得及（修复前只有 8 秒，来不及）。
  如果 20 秒仍然不够，请报回实际需要多久。
- 结果 toast：**「补录语音已绑定到这句」** / **「补录窗口内没有录到声音」** /
  **「补录需要系统声音采集可用」**。
- **新台词到达即收束**（新增行为）：录音期间如果你在游戏里翻了页、引擎 hook 吐出新台词，
  补录会**立即结束**并落盘已录到的部分。
  ⚠️ **重点关注误伤**：某些引擎是**打字机式逐字重发**同一句台词的。如果你的游戏属于这类，
  补录可能一开就被"新台词"立刻掐掉 —— 这是必须报回来的真问题（判据只认引擎 hook 台词，
  不认剪贴板 / 外部 WS 通道）。

**失败时看哪里**（会话事件）
`audio.recapture_started` / `audio.recapture_locked` / `audio.recapture_exception` /
`audio.recapture_line_unavailable` / `audio.recapture_source_unavailable`。

---

## 6. BUG-1096 · 装了 Magpie 的机器上捕获是否只剩一个鼠标指针

修复两条：① 按窗口属性 `Magpie.SrcHWND` 把 Magpie 缩放窗解析回**源窗口**；
② 把 WGC 光标抑制的 HRESULT 写进 diagnostics（以前静默吞掉，是盲区）。

**前置**：必须让 Magpie **处于正在缩放的状态**（只安装不缩放不会出现重定向 —— 判据是窗口属性，不是类名）。

**操作步骤**
1. 用 Magpie 缩放你的 galgame。
2. 捕获工作台工具栏 ⋮「更多」→ 勾选 **「外部窗口挖矿」**。
3. 正文顶部出现窗口绑定条，点它选窗口。
   **观察点 A**：列表里应该显示**游戏本身的标题**，不是 `Magpie` 之类的缩放窗标题。
4. 在台词列表里点一个词 → 查词浮窗 → 点**制卡 (+)**。这是唯一触发画面捕获的路径
   （封面优先 GIF：10 帧 / 帧隔 120ms / 宽 480，产物 `external_window.gif`；GIF 失败回退单帧 PNG）。
5. 到 Anki 里看这张卡的封面。

**预期**
- **观察点 B（本条核心）**：GIF / 截图里**只有一个鼠标指针**。
  ⚠️ 说明白：游戏**自绘**的光标是画面内容本身，任何捕获 API 都剥不掉。
  本次修的是「Magpie 补画的那一个」和「WGC 合成的那一个」。所以正确的验收预期是
  **「从两个变成一个」**，不是「一个都没有」。
- 错误日志页（设置 → 系统 → 诊断 → 错误日志）应能搜到：
  ```
  window capture diagnostics: capture target redirected: Magpie scaling window -> source window (Magpie.SrcHWND)
  ```
  tag 是 `captureWindowGifBytes` 或 `galHookMineLine`。

**失败时看哪里**
- 搜不到 `Magpie.SrcHWND` → 重定向没触发。确认 Magpie 真在缩放；
  另外 Magpie 的这个窗口属性是**稳定契约**，若你用的是很旧/很新的 Magpie 分支可能没有这个属性。
- 搜到 `IGraphicsCaptureSession2 unavailable (needs Windows 10 build 19041+); WGC cursor NOT suppressed hr=0x…`
  → 你的系统版本太老，光标抑制 API 不可用（这不是回归，是平台限制，但请把 hr 值报回来）。
- 搜到 `put_IsCursorCaptureEnabled(false) failed hr=0x…` → 抑制调用真失败了，**请报 hr 值**。
- 制卡后封面是 `.png` 而不是 `.gif`，且日志里有 `gif encode failed: …` → ffmpeg 编码失败（另一条问题）。
- 制卡的是**历史行**时日志会有
  `stale scene: mining historical line {id}; captured frame is the current window, not the frame at that line`
  —— 这条不是 bug，是提醒你抓的是当前画面。

> 另注：`MagpieInstaller`（自建 Magpie fork 按需安装器，PR#426）目前**在 `lib/` 里零调用方**，
> 属于「阶段一：安装器已落地但未接线」。所以**不要**去 app 里找「安装 Magpie」按钮，没有。
> 它的日志也只走 `debugPrint('[magpie] …')`，不进错误日志页。

---

## 7. BUG-1097 · 查词浮窗左下角还有没有 `https://hibiki.popup/...`

native C++ 已用 `flutter build windows --debug` 真编译验证，但**肉眼复测未做**。

**操作步骤**
1. 在 galgame 台词浮窗（或任何 app 外查词场景）里点一个词，拉起**桌面全局查词浮窗**。
2. 找一条 **Yomitan 结构化内容的词典内链**（释义里可点的交叉引用词条）。
3. **把鼠标悬停在那个链接上**（不要点），盯住浮窗的**左下角**。

**预期**
- 左下角**不再**出现 `https://hibiki.popup/popup.html?query=…&wildcards=off` 这条灰色地址预览。
- 点击该内链的跳转行为**不变**（href 保留着，改的只是预览条）。

**失败时看哪里**
- native 日志（`ReportOverlayError`）会记 `put_IsStatusBarEnabled(FALSE) failed` + HRESULT。

> ⚠️ **已知残留（本次修复未覆盖）**：`put_IsStatusBarEnabled(FALSE)` 只加在 runner 自有的
> `GlobalLookupWindow`（app 外浮窗 / 剪贴板面板）。**app 内**的查词弹窗走的是
> `flutter_inappwebview_windows` fork，那条路径全仓找不到任何
> `IsStatusBarEnabled` 设置 —— 所以在**阅读器 / 视频页 / 词典 tab 的 app 内弹窗**里
> hover 词典内链，**理论上状态栏仍会出现**。请顺手在 app 内弹窗也 hover 一次并汇报，
> 这决定要不要给 fork 也补一刀。

---

## 8. 回归对照（这批改动可能误伤的相邻功能）

| 检查项 | 预期 |
|---|---|
| 有声书**歌词条**的字号 | 仍随窗口高度缩放（BUG-1095 只把 hook 模式解耦，歌词条行为刻意不变） |
| galgame 台词浮窗拖高 | 现在是**多显示几行**，不是把同样两行放大 |
| 台词装不下时 | 顶端对齐（保住阅读起点，只丢句尾）；装得下时仍垂直居中 |
| 已有游戏的启动命令行 | v56 迁移后 `launch_args` 回填空串 = 不发任何 `--arg`，与旧版逐字节相同 |
| 剪贴板复制（自己在别的 app 里 Ctrl+C） | **已知取舍**：面板上正挂着你点出来的释义时，只刷新句子横幅、不自动整句重查。点新横幅里的词或按全局热键可强制重查 |

---

## 9. 汇报格式

每条请按这个格式回报，方便直接落回 bug 文件：

```
条目：BUG-1101
游戏：<游戏名 / 引擎>
阶段：process_found ✅ / helper_ready ✅ / ipc_ready ✅ / text_ready ✅ / pcm_ready ❌ / paired — / e2e —
现象：<实际看到什么>
事件/日志：<会话事件 code 或 error_log.txt 里的原文行>
结论：通过 / 不通过 / 阻塞（阻塞在哪一步）
```

任何一步被跳过或阻塞，就只能标 `implemented_unverified`，**不能**记成「已支持 / 已修好」。
