# Galgame 管理与 Hook 监控界面需求（实现前）

> 日期：2026-07-19
> 状态：需求分析与草图；本轮不实现 Flutter 页面。
> 参考：`references/ReinaManager` 固定于 `72b8ca255d6e874539a6bfe71029a369debf6c0a`，仅作产品与交互参考。
> 路径说明：本文证据表中的 `native/galgame_voice_hook/...` 是迁出前历史锚点；当前 native 实现在独立仓 `hajisensai/hibiki-hook`，新实现应按 [Galgame Hook 引擎适配 SOP](../agent/galgame-hooking.md) 从 `hook/adapters/`、`injector/` 与 `include/` 定位。

## 1. 结论先行

Hibiki 需要的不是先复刻一个完整 ReinaManager，而是把两个层次接起来：

1. **捕获会话管理（当前优先）**：游戏进程、窗口、文本 hook、音频 hook / loopback、音轨、截图、句音匹配和 Anki 出卡必须在一个可观测、可恢复的会话里。
2. **游戏资料管理（长期入口）**：封面、标题、exe、引擎、启动方式、hook 配置、标签、最近游玩和验证记录按游戏持久化；以后再扩展在线元数据、存档和统计。

侧边栏应新增一个明确叫 **“游戏”** 的一级模块。Windows 宽屏建议顺序固定为：

`书架 → 视频 → 游戏 → 查词 → 设置`

“捕获台 / 诊断 / 游戏库”不再各占一个侧边栏项，而是同一“游戏”模块内部的视图：

- **游戏首页**：沿用现有书架 / 视频模块风格的默认入口，对应草图 D。
- **捕获台**：从游戏首页的“捕获工作台”、继续捕获卡或游戏卡进入，对应草图 A。
- **诊断**：开发 / 兼容性排查界面，对应草图 B。
- **游戏详情 / 库的高密度变体**：配置归档与高级库视图，对应草图 C。

实现顺序应是“会话控制器与可观测性 → 一级‘游戏’入口 + 首页骨架 → 捕获台 → 诊断 → 游戏配置 / 在线元数据与统计”。游戏首页可以先用本地 exe 与验证状态落地，但不能让封面墙掩盖 hook 失败、静默降级、音轨误选和切 tab 停会话的问题。

## 2. 当前真实状态

### 2.1 已经能工作的链路

- 外部窗口制卡已有文本、窗口 GIF / PNG、音频编码和 Anki 出口；`TexthookerPage.onMineEntry` 串起画面、音频与 `ImmersionMiningEngine`（`hibiki/lib/src/pages/implementations/texthooker_page.dart:112-168`）。
- `EngineHookGalAudioSource` 已有 attach / launch 两种模式，launch 可按 exe 位数选择 helper、等待注入并打开共享内存（`hibiki/lib/src/mining/galgame_audio_source.dart:245-454`）。
- 当前目标分支已把 KiriKiri 语音 OGG dump 接回制卡：按文本时间戳窗口筛候选、排除 BGM / SE 前缀、转 AAC，并优先于共享内存 PCM 与 loopback（`galgame_audio_source.dart:159-190,609-645`；`galgame_audio_encode.dart:169-221`；`texthooker_page.dart:456-497`）。这是一条真实可用的新 backend，不再是断路。
- 文本行带单调序号与同一时钟的时间戳，可按句抓 clip / utterance；页面还做了最多 200 句的“出现即锁定”音频与时间戳缓存（`texthooker_page.dart:65-78,314-356`）。
- native 已能枚举活跃音频源，包含格式、平均 buffer、能量、创建顺序和 clip 数；Dart 已有“选语音轨 / 排除 BGM 轨”的会话内字段（`hibiki/windows/runner/voice_hook_reader.h:41-53,86-101`；`galgame_audio_source.dart:560-583,720-750,788-833`）。
- 2026-07-18 的交接记录已给出真实 Hibiki 宿主内全链抓音验证，以及 4 个游戏实际出卡证据（`docs/specs/galgame-mining/handoff.md:21-53`）。

### 2.2 仍不能对用户承诺的部分

- **不能用“引擎 hook”一个绿标代表干净人声**。共享内存的 KiriKiriZ DirectSound 输出仍是软件混音，与 loopback 等价（`handoff.md:27-29,47-53`）；当前新增的“原始 OGG + 时间戳配对”才可能给出混音前语音，而且只应在已有真机证据的游戏 / 引擎配置上显示“纯人声已验证”。其它引擎仍可能不命中并回退 loopback。
- **逐引擎校准仍未完成**。C.3 的 callsite / 引擎内部 per-channel 覆盖没有落地，自动能量选源可能把 BGM 当语音（`handoff.md:17,139-157`）。
- **完整 UI 路径仍缺焦点驱动真机走查**。原生文件选择、波形 / 出卡等完整用户路径不能因为底层集成测试通过就标成已验证（`handoff.md:47`）。
- **错误原因被压扁成 null**。启动、注入、IPC、等待格式、OGG 匹配 / 转码和 PCM 抓取均大量 fail-open；这对不打断游戏是对的，但管理界面必须保留失败阶段与 fallback 原因，不能只显示“可用 / 不可用”（`galgame_audio_source.dart:356-550,573-750`）。

### 2.3 当前 UI / 生命周期的结构性问题

- hook 会话、timer、音轨选择和句音缓存都由 `TexthookerPage` 的 State 持有（`texthooker_page.dart:49-78`）。
- 页面 `dispose` 会停止音频源、文本轮询并清空缓存（`texthooker_page.dart:103-109,284-297`）。
- Home shell 明确让 texthooker tab 切走即销毁（`hibiki/lib/src/pages/implementations/home_page.dart:833-885`）。因此只在现页增加监控卡片仍会导致切到游戏库 / 设置后整个捕获会话终止。
- 现页只有“外部窗口模式”“拉起游戏”“清空”和一个绑定窗口条（`texthooker_page.dart:601-654`），看不到注入阶段、实际 fallback、文本源、音轨、音量、最后一条音频、OGG 配对偏移、匹配结果和失败历史。
- `TexthookerService` 只有无时间戳、无来源的 `List<String>`；WS client 虽连接多个端口并重连，却不公开每个 endpoint 的连接状态、最后错误与最后消息时间（`hibiki/lib/src/sync/texthooker_service.dart`；`texthooker_ws_client.dart`）。

### 2.4 开始做管理 UI 前的 P0 阻塞

本轮只分析、不顺手改这些问题；但若不先修，监控界面展示的数据会从源头不可信。

| 阻塞 | 已复核证据 | UI / 实现要求 |
|---|---|---|
| 完整台词没有进入点词制卡 payload | 台词行只把被点的 `word` 送进 popup（`hibiki/lib/src/pages/implementations/texthooker_page.dart:591-599,733-773`）；popup 的 `buildMinePayload` 没有 `sentence`（`hibiki/assets/popup/popup.js:1254-1315`）；WebView handler 原样转成 map（`hibiki/lib/src/pages/implementations/dictionary_popup_webview.dart:1200-1224`），但 galgame 制卡、纯人声时间戳与音频缓存查找都读取 `fields['sentence']`（`texthooker_page.dart:146-159,456-482`）。空 / 旧句未命中还会退到“最近一句”，重复文本也会覆盖字符串 key | 先给台词稳定 ID 与完整文本，查词只改变 expression；制卡、OGG 配对、音频缓存和 UI 行均按 event ID 关联，禁止用 sentence string 或 latest fallback 冒充正确配对 |
| “停止”不等于卸载 hook | Dart `stop()` 关闭映射后直接 `Process.kill()` helper（`hibiki/lib/src/mining/galgame_audio_source.dart:752-763`）；injector 只有正常离开 hold 后才 `ShutdownLunaHook`（`native/galgame_voice_hook/injector/injector_main.cpp:680-702`）；游戏内 DLL 明确常驻到进程退出（`native/galgame_voice_hook/hook/dll_main.cpp:1775-1796`），所以停止监听后 DLL 与 OGG dump 仍可能继续到游戏退出 | 增加 graceful stop / detach / disable IPC、heartbeat、orphan 与 dump 生命周期检测；在此之前按钮只能诚实写“停止监听 / 结束 helper”，不能宣称已卸载或完全停止游戏内 hook |
| 文本轮询有重入与丢行窗口 | 页面用固定 400ms timer，未做 in-flight 互斥（`hibiki/lib/src/pages/implementations/texthooker_page.dart:299-337`）；reader 会跳过尚未完整提交的 slot，而页面仍把 cursor 推到 header count | 轮询串行化，cursor 只推进到实际确认的最大 seq；公开 gap / overwrite / duplicate 计数 |
| 制卡没有稳定任务串行化 | PCM 临时目录按 `pcm.length`、OGG 转码目录按 `oggPath.hashCode` 命名，并都在 finally 递归删除（`hibiki/lib/src/mining/galgame_audio_encode.dart:140-162,177-221`）；页面没有 mining mutex / queue | M0 引入 `MiningJob` 队列和真正唯一的 job temp 目录；界面显示 match → capture → encode → upload 各阶段 |
| 纯人声 OGG 已接线，但匹配能力仍缺结构化证据 | 当前同步扫描全局 temp 目录，文件名没有 PID / session，按固定 `[T-330ms,T-130ms]` 窗口与前缀启发式选一个 OGG；旧 DLL 在停止监听后继续落盘时可能污染新会话。另无候选置信度和已消费标记，失败会静默落到 PCM / loopback（`galgame_audio_source.dart:145-190,609-702`；`native/galgame_voice_hook/hook/dll_main.cpp:1180-1195`；`texthooker_page.dart:456-497`） | dump 路径 / 索引携带并校验 PID + session ID；把 backend、候选数、实际 offset、置信度、排除原因、转码结果和 fallback 原因放进事件；规则按游戏 / 引擎版本保存，只有真机验证过的 profile 标“纯人声已验证” |
| 画面与台词不是同一事件快照 | 当前点击制卡时才抓 10 帧 GIF / PNG，旧台词得到的是点击时画面；抓 GIF 后才取音频，时差进一步扩大 | `GalCapturedLine` 出现时记录稳定时间与可选轻量缩略图；UI 明示各媒体时间戳 / delta，允许用户替换 |

另有 helper 安装 / 版本 / hash / 签名预检、多进程 launcher→实际游戏 PID 重定向、黑帧检测与目标 HWND 重用校验等兼容性项，进入 M0 的 preflight 与诊断事件，不靠 toast 一次性带过。

## 3. 产品对象与边界

### 3.1 四个核心对象

| 对象 | 作用 | 关键字段 |
|---|---|---|
| 游戏配置 `GalGameProfile` | 跨会话保存一个游戏的事实 | 标题、封面、exe、exe SHA、位数、引擎、启动 / attach 策略、窗口匹配、音轨签名、标签 |
| 捕获会话 `GalHookSession` | 管一轮游戏运行与捕获生命周期 | profile、PID、HWND、helper、文本源、音频源、会话阶段、开始时间、降级原因 |
| 捕获事件 `GalHookEvent` | 可诊断的时间线 | 时间、severity、stage、code、摘要、技术详情、是否可重试 |
| 台词条目 `GalCapturedLine` | 让文本、音频与制卡状态可追踪 | seq、文本、来源、hook 时间、收到时间、实际音频 backend、纯度等级、候选数 / offset、匹配音轨、音频时长 / 峰值、fallback、出卡结果 |

### 3.2 当前不做

- 不在 M0 接入 VNDB / Bangumi / YmGal / Kungal，也不先做全量封面墙、评分和剧情介绍。
- 不复制 ReinaManager 的 React / Tauri 组件或素材；只吸收信息架构和成熟交互。
- 不承诺所有游戏都能得到干净语音；能力以会话实际探测结果显示。
- 不让 UI 直接操纵 native channel；统一经过会话控制器，避免页面切换产生第二路注入或并发读共享内存。

## 4. 核心用户流程

### 4.1 首次添加并启动

1. 选择 exe，自动读取标题、图标、32 / 64 位、SHA；用户可补封面和引擎标签。
2. 健康检查 helper 是否存在且位数匹配，明确说明注入组件与杀软风险。
3. 默认推荐“由 Hibiki 启动并早注入”；对已启动游戏提供 attach，但提示可能漏过启动期创建的音频设备。
4. 启动后自动找 PID / 主窗口，逐步显示 `启动 → 注入 → IPC → 文本 → 音频 → 窗口 → Anki`。
5. 命中原始 OGG 配对时显示“纯人声 OGG（已验证 profile）”及 offset；只命中共享内存 PCM 时显示其真实混音能力和格式；未命中时允许显式切到 loopback，并保留 fallback 原因。

### 4.2 游玩中监控与制卡

1. 捕获台持续显示最近台词；每行独立显示“文本已到 / 音频匹配 / 画面可抓 / 已出卡”。
2. 右侧健康栏显示当前进程、窗口、文本源、音频源、Anki 与 helper 状态。
3. 波形 / 电平用于判断是否有声，不用装饰性假波形；标明来源是 paired OGG、engine PCM、process loopback 还是 system loopback，并区分“已验证纯人声 / 混音 / 未知”。
4. 用户可试听最近一句、重选语音轨、标记 BGM、测试截图、生成测试卡。
5. 快捷键出卡时，结果回写到对应台词行；失败不丢上下文，可展开技术原因后重试。

### 4.3 失败诊断

1. 点击任一黄色 / 红色状态进入诊断视图并自动过滤相关阶段。
2. 时间线保留 launch 参数（脱敏）、目标 / 实际 PID、位数、helper 退出码、hook 标志、PCM 格式、fallback 决策和最近错误。
3. 音轨表显示创建顺序、格式、能量、buffer、clip 数；允许试听、设为语音、排除为 BGM。
4. 一键导出诊断包时默认不含游戏文本、截图和音频；用户明确勾选才包含隐私内容。

## 5. 捕获会话状态模型

建议状态机：

`idle → resolving → launching/attaching → injecting → openingIpc → waitingSignals → running`

旁路状态：

- `degraded`：仍可工作，但使用 loopback、无文本 hook、无窗口或无 Anki。
- `error`：主目标不可继续，必须重试 / 换模式。
- `stopping`：关闭轮询、IPC 与 helper；“停止捕获”和“结束游戏”必须是两个动作。

健康项至少包含：

| 健康项 | 最少状态 | 需要展示的事实 |
|---|---|---|
| 游戏进程 | 未启动 / 启动中 / 运行 / 已退出 | exe、PID、位数、启动方式 |
| 游戏窗口 | 未找到 / 已绑定 / 丢失 / 重绑定中 | HWND、标题、尺寸、最近抓帧 |
| helper | 缺失 / 位数不符 / 注入中 / 已注入 / 退出 | arch、版本、退出码 |
| 文本 | 未连接 / 等待 / 活跃 / 超时 / 错误 | 来源、最后行时间、总行数、覆盖 / 丢失数 |
| 音频 | 未开 / 等待 / 活跃 / 静音 / fallback / 错误 | 实际 backend、纯度证据、格式、peak / RMS、最近 OGG / clip、fallback 链 |
| 句音匹配 | 未匹配 / 自动 / 手选 / 过期 / 失败 | event ID、候选数、offset / confidence、轨道、时长、缓存是否命中 |
| 截图 | 未绑定 / 可抓 / 最近失败 | 最近缩略图、耗时、错误码 |
| Anki | 未配置 / 可用 / 写入中 / 失败 | deck、最近一次结果、耗时 |

## 6. 实现 UI 前必须补的可观测性

1. 把 session ownership 从 `TexthookerPage` 上提到 Riverpod controller / app 级 service；页面只订阅状态和发 intent。
2. 用不可变 `GalHookSessionState` 公开阶段、能力、fallback 原因、格式、PID / HWND 和最后错误；禁止继续只用 `PcmFormat?` / `null` 表达所有失败。
3. 把 `TexthookerService` 的字符串列表升级成结构化行，并保留兼容 getter；记录来源、seq、两个时间戳、匹配 / 制卡状态。
4. WS client 对每个 URL 暴露 `connecting / connected / retrying / stopped`、最后错误和最后消息时间。
5. native status 增加只读指标：音频总写入 / 覆盖计数、文本写入 / 覆盖计数、last packet age、peak / RMS；采样指标不能在音频回调里加锁或做 IO。
6. 音轨选择从裸 `source_ptr` 提升为“会话 pointer + 可持久化签名（orderIndex、format、buffer 特征）”；下次启动只做候选匹配并要求可回退。
7. 所有自动 fallback 产出结构化事件，例如 `engine_hook_timeout → system_loopback`，默认 UI 显示黄色而不是伪装成完全成功。

## 7. 信息架构与布局

### 顶层

新增稳定身份的 `HomeTab.games`，侧栏 label 逐字使用“游戏”，图标建议 `sports_esports_outlined`。它位于视频与查词之间，不用视觉 index 代替 enum 身份。游戏模块内部包含：

- **首页 / 游戏库**：游戏配置、启动入口、继续捕获、捕获概览、兼容性待处理。
- **捕获工作台**：当前台词、音频 / 画面预览、快捷动作、健康状态。
- **兼容性诊断**：阶段时间线、音轨、指标、日志和导出。
- **游戏详情**：exe / 引擎 / 启动策略 / hook 配置 / 最近验证 / 制卡统计；在线元数据以后补。

会话状态常驻顶部窄条；切到其它 Hibiki tab 后仍在后台运行，并在导航图标显示绿色 / 黄色 / 红色小点。用户必须显式点击“停止捕获”，页面切换不应隐式停止。

现有 `HomeTab.texthooker` 与 `TexthookerPage` 的能力逐步折入 `HomeTab.games` 内部，不再同时保留一个重复的“文本钩子”侧栏项。整个“游戏”入口不应依附 `texthookerEnabled` 才出现；游戏资料、普通启动和历史始终可用，只让实验性捕获动作受开关和 Windows 平台门控。当前条件 tab 的证据在 `home_page.dart:40-54`。

当前代码的实现接缝也应一次改全：`HomeTab` 枚举与可见顺序在 `hibiki/lib/src/pages/implementations/home_page.dart:38-55`，导航图标 / 文案的唯一映射在 `:96-128`，Windows rail / 窄窗底栏在 `:733-829`，页面映射在 `:890-906`；macOS 根壳还在 `hibiki/lib/main.dart:1469-1475` 复用同一列表。实现时同步更新 `hibiki/test/pages/home_page_tabs_test.dart:71-115` 的顺序守卫，不能只在 Windows rail 中插一个视觉项。

### 游戏首页对齐现有模块

草图 D 直接复用用户截图中视频页的层级：

1. 页头大标题“游戏”，右侧使用同尺寸的 outlined action pills：添加游戏、扫描目录、捕获工作台、游戏统计。
2. 标题下方用状态 chips + 设置 / 排序 / 筛选小图标，不另造一套重型二级导航。
3. 第一排左侧是“继续捕获 / 继续游戏”，右侧是“捕获概览”，与视频页的“继续观看 + 观看活动”同构。
4. 下方走书架 / 视频已有的响应式卡片网格；封面比例可以按游戏资料用 3:4，但 footer、状态、焦点和空状态沿用 Hibiki 组件。
5. 游戏卡只显示能帮助行动的徽标：全链验证、混音可用、仅 Loopback、需诊断、路径失效；不把评分和在线元数据放在当前优先层。

### 宽度适配

- `>= 1280dp`：三栏捕获台（台词 / 预览 / 健康）。
- `840-1279dp`：健康栏折入右侧 drawer，预览置于台词上方。
- `< 840dp`：本功能为 Windows 桌面实验项，仍允许单栏查看，但启动 / 注入配置不以移动端为首要目标。
- 所有主操作进焦点序列；列表项、音轨和状态卡使用 Enter 确认，避免只有 hover 才出现的动作。
- 台词列表先让“一整行”成为焦点目标，上下键移动、Enter 打开、`Ctrl+Enter` 制卡；不能让 Tab 依次穿过 500 行中的每个日语词。新台词不抢焦点，关闭详情后焦点回原行。
- 现有 `_onLines` 每次都跳到列表底部（`texthooker_page.dart:553-560`）；新界面改成“跟随实时”开关，用户查看旧句时只累计未读数。

### 可复用的 Hibiki 组件

- 游戏首页直接沿用 `HomeVideoPage.build` 的 `PopScope → FileDrop → DesktopContentLayout(kind: readerShelf) → Column` 骨架（`hibiki/lib/src/pages/implementations/home_video_page.dart:1588-1630`），避免另建一套页面壳。
- 视频页 action pills、继续区 / 概览与响应式网格分别见 `home_video_page.dart:2381-2420,1717-1940,2579-2600`；游戏卡沿用稳定 focus ID、选中态、封面 / 徽标 / footer 范式（`:2652-2786`），竖封面宽度则按书架而不是 16:9 视频卡计算。
- 页面 / 分组 / 卡片 / selected / overlay 的语义面和圆角、间距直接走 `hibiki_design_tokens.dart:53-237`。
- 标准页头、聚焦卡片 / 列表、日志复制与懒加载可复用 `hibiki_material_components.dart:21-306,1608-1920,2286-2401`。
- supporting pane 与 compact / medium / expanded 断点走 `platform_utils.dart:68-102,223-275`；Windows 最小窗仍按 `desktop_window_placement.dart:19-28` 的 360×480 考虑。
- 空 / 错状态复用 `hibiki_placeholder_message.dart:4-74`，KPI 复用 `stat_kpi_strip.dart:29-99`。
- 游戏库可沿用书架的响应式 `SliverGridDelegateWithMaxCrossAxisExtent`（`reader_hibiki_history_page.dart:1126-1135`）和现有封面卡的焦点 / footer / 徽标结构，而不是复制 ReinaManager 的固定列数。
- 页内“游戏库 / 实时监控”可按 `HibikiSelectableChip`（`hibiki_material_components.dart:575-677`）与 `TagFilterBar` 的视觉骨架（`tag_filter_bar.dart:64-183`）实现，但不要直接耦合书籍 tag provider；所有卡片、状态行和动作使用稳定的 `home-game-*` focus ID。

## 8. ReinaManager 的取舍

### 值得复用的产品思路

- 封面库 + 搜索 / 筛选 / 排序，适合承载长期游戏配置。
- 详情页把启动、路径、元数据、标签、存档和统计聚合到一个游戏对象。
- 首页的“继续游戏 / 最近玩过 / 活动”适合以后改造成“继续捕获 / 最近验证 / 最近出卡”。
- 批量导入目录、游玩会话记录和本地自定义字段适合 M1 / M2。
- 上游真实路由是 Home / Libraries / Collection / Settings，详情页再聚合统计、简介、编辑、存档、评价和收藏（`references/ReinaManager/src/providers/router.tsx:67-100`；`references/ReinaManager/src/pages/Detail/DetailPage.tsx:482-554`）。
- 上游用“原始游戏事实 → 派生 GameIndex → ID 过滤 → 虚拟化封面网格”的分层避免整库反复 IPC / 转换；Hibiki 可对应成 `GalGameProfile → 派生索引 → UI ID 列表`，但实时会话事件必须单独存放（`references/ReinaManager/src/utils/game/gameIndex.ts:9-18,102-136,176-224`；`references/ReinaManager/src/components/Cards/VirtualCardsGrid.tsx:34-100`）。
- 目录批扫能过滤 installer / crash handler、剪枝已导入目录并挑候选 exe；Hibiki 可在此基础上补 PE 位数、exe SHA、窗口匹配和 helper arch（`references/ReinaManager/src-tauri/src/game/scan.rs:23-29,105-147,220-268,402-490`）。

### 不直接照搬

- ReinaManager 面向收藏与启动，页面的成功标准是“能找到并启动游戏”；Hibiki 当前成功标准是“文本、音频、画面、句音配对和 Anki 都可验证”。
- 大面积 hero、封面墙和复杂在线元数据在监控阶段会挤占实时信号与错误信息。
- ReinaManager 的 Tauri / React / MUI / Zustand / SeaORM 技术实现不能进入现有 Flutter / Riverpod / Drift 架构。
- 上游为 AGPL-3.0；只借鉴交互，不复制代码、图标、截图和角色素材。
- 上游所谓进程“Hook”实际是每 200ms 看前台窗口并累计游玩时间，不是文本 / 音频 hook（`references/ReinaManager/src-tauri/src/game/monitor/windows.rs:460-486`），不能复用其术语或健康模型。
- 上游从自己的 launch 流进入 monitor，缺少 Hibiki 所需的早注入与 attach 双路径；它的“停止游戏”还会结束候选 PID 集合，Hibiki 必须把“停止捕获”和“结束游戏”拆开并对后者二次确认（`references/ReinaManager/src-tauri/src/game/launch/windows.rs:346,416`；`references/ReinaManager/src-tauri/src/game/monitor/windows.rs:138-181`）。
- 上游 README 与实际 6 个 metadata adapter 已有漂移，且没有 UI test 脚本；固定子模块只能作参考，不能成为 Hibiki 需求真相源。

## 9. 三版草图的定位

### D：Hibiki 原生游戏首页（推荐一级入口）

- 入口导向：外壳、页头、继续区、活动卡和网格都与当前书架 / 视频模块同构。
- 优点：加入侧边栏后不显得像另一款独立应用；普通启动、资料管理和捕获状态共用一个入口。
- 缺点：这里只显示摘要，实时台词和深度错误仍要进入 A / B。

### A：捕获控制台（推荐工作界面）

- 任务导向：顶部是启动 / attach / 停止 / 测试卡，中心是实时台词与句音状态，右侧是健康链。
- 优点：普通用户一眼知道“现在能不能挖”；兼顾少量开发信息。
- 缺点：深度排查仍需进入诊断页。

### B：数据流诊断台（开发模式）

- 诊断导向：阶段时间线、实时指标、音轨表、事件日志同屏。
- 优点：最适合当前逐引擎开发和验证，能发现静默 fallback / BGM 误选 / 环形覆盖。
- 缺点：信息密度高，不适合作为日常默认页。

### C：游戏库融合（长期入口）

- 资料导向：ReinaManager 式本地游戏库，每张卡显示 hook 配置与最近验证健康；右侧抽屉启动当前会话。
- 优点：多游戏、多引擎配置清晰，长期使用价值高。
- 缺点：若先做会掩盖底层可观测性缺口，故排在 A / B 之后。

对应 SVG：

- `docs/design/galgame-hook-manager-wireframe-d-hibiki-game-home.svg`
- `docs/design/galgame-hook-manager-wireframe-a.svg`
- `docs/design/galgame-hook-manager-wireframe-b.svg`
- `docs/design/galgame-hook-manager-wireframe-c.svg`

预览：

![草图 D：Hibiki 原生游戏首页](galgame-hook-manager-wireframe-d-hibiki-game-home.svg)

![草图 A：捕获控制台](galgame-hook-manager-wireframe-a.svg)

![草图 B：数据流诊断台](galgame-hook-manager-wireframe-b.svg)

![草图 C：游戏库融合](galgame-hook-manager-wireframe-c.svg)

## 10. 分期与验收门

| 阶段 | 交付 | 验收重点 |
|---|---|---|
| M0 | 会话 controller、结构化状态 / 事件、`HomeTab.games` + 首页 D、捕获台 A、诊断 B 基础 | 侧栏顺序和其它模块一致；切 tab 不停会话；每次 fallback 有原因；无声音 / 无文本可被看见；停止幂等 |
| M1 | `GalGameProfile`、完整本地游戏库 / 详情、启动策略与音轨签名持久化 | 同一游戏二次启动可复用配置；exe 变化可检测；错误配置可安全回退 |
| M2 | 元数据、集合、游玩 / 出卡统计、存档入口 | 网络失败不影响本地启动和捕获；隐私与 NSFW 设置明确 |
| M3 | 逐引擎校准工具与兼容性数据库 | 每个“干净语音”结论有游戏 / 引擎 / 版本 / 真机证据，不用营销性绿标代替验证 |

实现 M0 前应先写 controller / state 的纯逻辑测试；完成页面后按仓库规则走 Windows 真 app、键盘焦点驱动，并至少覆盖：早注入成功、attach 漏 hook、engine→loopback fallback、文本无数据、音轨误选后手动修正、切 tab 保活、游戏退出与 helper 异常退出。
