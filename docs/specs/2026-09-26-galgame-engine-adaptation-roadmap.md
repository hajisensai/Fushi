# Galgame 引擎适配路线图（2026-09-26）

按「玩家多 → 小众」逐个引擎推进，一直做下去。本文件是**排期与验收口径**，引擎支持状态的唯一真相源仍是 `native/galgame_hook/engine-support.yaml`，操作流程见 [docs/agent/galgame-hooking.md](../agent/galgame-hooking.md)。

## 1. 两条硬规则（根 `CLAUDE.md`）

1. **只做引擎级适配**：修的是引擎 / 引擎变体的通用判据与生命周期，不加按 exe 哈希、文件名、标题写死的特判。判据取自引擎结构特征，并用同引擎多个版本的样本 + 他引擎负向样本验证。
2. **适配成功 = 四条同时满足**（在用户原始启动路径上）：
   - ① **文本**：选定线程是干净正文；
   - ② **音频**：拿到与该句对应的语音（引擎资源或 PCM；纯 Loopback 不算）；
   - ③ **内嵌查词**：游戏画面内弹出 Fushi 查词卡；
   - ④ **点击查词不推进**：点台词里的词能查到该词，且这次点击不推进剧情。
   缺一条只报「部分适配」并写明缺哪条。

## 2. 排序口径

- 优先级 = 该引擎覆盖的**作品数 × 中文学日语玩家里的常见度**。下表是按社区常见度的估计，**待用实际数据校准**（Fushi 游戏库里的 exe 引擎分布、发现源下载量）；校准后直接改本表顺序。
- 同一优先级内，先做「离四条最近」的引擎（已 partial 的优先于未实现的），尽快把可用面铺开。
- 一引擎一任务、一独立 worktree（SOP §1）。每个引擎至少覆盖**两个不同年代 / 发行形态的样本**（光盘版 + Steam 版、原版 + 汉化版、老版本 + 新版本），避免只修好一个构建。

## 3. 现状基线（2026-09-26，来自 engine-support.yaml）

| 状态 | 引擎 |
|---|---|
| verified | SiglusEngine、Unity IL2CPP、XAudio2/DirectSound 通用采集 |
| partial | KiriKiri2 / KiriKiri Z、TyranoScript、Artemis、CatSystem2、Malie、QLIE |
| implemented_unverified | RealLive、BGI/Ethornell、CMVS、elf AI6、Ren'Py、Unity Mono、Leaf/AQUAPLUS、HUNEX GGE、smash/fzmedia、SGRE、Unreal、AOS/SFA |
| 未实现（只有通用文本 / Loopback） | YU-RIS、FVP（Favorite）、Softpal/Unison、NeXAS、Majiro、AliceSoft System4、EntisGLS、Livemaker、NScripter/ONScripter、Escu:de、ExHIBIT 等 |

游戏内查词几何来源：KiriKiri、Ren'Py 有运行时布局；Siglus、Leaf、HUNEX、SGRE、smash、CMVS 有引擎精确布局；其余引擎只有手动校准（`attached_calibrated`），③④ 基本都还没打通。

## 4. 路线图

### P0 · 跨引擎前置（先做，所有引擎受益）

| 项 | 内容 | 为什么先做 |
|---|---|---|
| BUG-2710 | KiriKiri 查词关卡后下一次点字被吞一次 | 查词交互的共性时序（卡片可见性应答），很可能不止 KiriKiri |
| BUG-2703 | 日文命名的 SE 被当语音候选 | 语音 / SE 分类要换成引擎级信号（播放通道 / 归档），各引擎都会遇到 |
| 制卡 E2E 装置 | 驱动宿主 `mine` + 假 AnkiConnect，形成每引擎一条命令的「四条 + 真卡」验收脚本 | 让每个引擎的验收可重复、可比 |
| 启动路径 | BUG-2126（LE + x86 崩）、BUG-1192（SteamStub 需正版样本） | 光盘版 / Steam 版差异大多卡在启动层 |
| 引擎识别表 | 对用户库 / 下载库里的 exe 做静态引擎识别并统计分布 | 用真实数据校准第 2 节的排序 |

P0 进展（2026-09-26 晚）：

- **BUG-2710**：宿主层已排除——同一套直连卡 + 系统钩子在 CLANNAD（Siglus）上按原序列四连击，关卡后第一击正常出卡；问题收窄到 KiriKiri 注入侧。宿主点击状态与注入侧 submit 发布结局的诊断日志已加，待 KiriKiri 样本复现。
- **制卡 E2E 装置**：真机驱动 `fushi/integration_test/gal_realgame_driver_itest.dart` 新增 `fakeanki` 与 `accept4 <x> <y> [ox oy]`。游戏停在一句对白上后，一条命令依次判 ① 文本 ② 非 Loopback 语音 ③ 点字出卡 ④ 不推进 ⑤ 关卡不推进 ⑥ 关卡后再点能出卡（BUG-2710 回归）⑦ 写进假 AnkiConnect 的卡带台词 / 语音 / 图片，末行 `verdict=full|partial`。已过定向 analyze，**尚未在真游戏上跑过**（本轮可用样本都被其它会话占用）。
- **样本**：本机现存 galgame 只剩 CLANNAD、SGRE、WoH，且各有会话在用；KiriKiri 样本需要重新取得。Steam 版千恋＊万花（AppID 1144400，用户已拥有、只装了成人补丁）装上后可同时解 BUG-2710 与 BUG-1192（正版 SteamStub 样本）。

### P1 · 主流引擎（玩家最多）

| 顺序 | 引擎 | 当前 | 缺哪条 | 下一步 |
|---|---|---|---|---|
| 1 | **KiriKiri2 / KiriKiri Z**（柚子社、Palette、FSN RN 等） | partial；千恋＊万花光盘版原版四条通过（PR #1673） | 其它变体未逐一过四条 | 按变体各取样本：经典 KAG3（K2/BCB）、KAGEX（2016 柚子社）、msgwin 插件型（2023 柚子社）、Palette（9-nine）；汉化加壳 exe、Steam 版各一 |
| 2 | **SiglusEngine / RealLive**（Key / VisualArt's） | Siglus verified 1 款；RealLive 未验证 | RealLive ①–④；Siglus 多作品的 ③④ | Siglus 再补 Rewrite、Summer Pockets 一类；RealLive 取老版本 Key 作品 |
| 3 | **Unity**（IL2CPP / Mono，新作与 Steam 作品） | IL2CPP verified；Mono 未验证 | Mono 全部；两者的 ③④ 只有手动校准 | 先 Mono 的 ①②，再做 TextMeshPro 运行时布局取几何 |
| 4 | **BGI / Ethornell** | 未验证 | ①–④ | 取两款不同年代作品建台账；几何从引擎渲染边界取 |
| 5 | **CatSystem2** | partial | ③④ | 从 CS2 的文本绘制边界取几何 |
| 6 | **Artemis** | partial | ③④ | 同上；覆盖 PC 与移植构建 |

P1 进展（2026-09-27，分支 `claude/galgame-p1`；样本一律经 Fushi 发现源「真红小站」下载）：

| 引擎 / 样本 | ① 文本 | ② 语音 | ③ 查词 | ④ 不推进 | 状态与下一步 |
|---|---|---|---|---|---|
| KiriKiri Z · 千恋＊万花 光盘版（KAGEX） | ✅ | ✅ | ✅ | ✅ | accept4 `verdict=full`，含真卡写入 |
| KiriKiri Z · PARQUET 2021（ゆずソフトSOUR，msgwin 插件登记但不画正文） | ✅ EmbedKrkrZ | ✅ game_resource（opus/ogg） | ❌→已修 | ❌→已修 | BUG-2721 修复已提交，**待宿主复验** accept4 |
| KiriKiri2 · 夏空カナタ（2008） | — | — | — | — | 下载包自带汉化补丁（正文乱码），不作样本；已删 |
| RealLive · planetarian Kinetic Novel（2004，脚本打进 .pak，语音 NWK） | 待宿主 | ✅ 运行时导出 `Z0001.nwk_529.wav` | 缺几何 | 缺几何 | 新增结构识别 + NWK/NWA 解码（离线 856/856 条）；③④ 需 RealLive 字形几何 provider |
| SiglusEngine · planetarian HD Steam | — | — | — | — | 下载包为汉化 + Steam 模拟器，无日文 Scene.pck，不适合；需另取日文 Siglus 样本 |
| CMVS | — | — | — | — | BUG-2718：runner 白名单漏 id 16，精确布局 hit 被丢；已修并加三处镜像守卫，无样本未真机 |
| BGI / CatSystem2 / Artemis / Unity | — | — | — | — | 已选样本（放課後しっぽデイズ / グリザイアの有閑 / アマナツ PE / デスマッチラブコメ！），下载随宿主被内存回收中断；三者 ③④ 需各自的引擎字形几何 provider（现只有手动校准） |

宿主注意：驱动测试原 45 分钟超时会杀掉宿主与内存里的下载队列（旧的「exit 79」），已改 6 小时。

### P2 · 常见但覆盖面较窄

| 顺序 | 引擎 | 当前 | 下一步 |
|---|---|---|---|
| 7 | QLIE | partial | ③④ |
| 8 | Malie | partial | ③④ |
| 9 | CMVS（Purple Software） | 未验证（已有精确布局） | 原始路径过四条 |
| 10 | elf AI6 | 未验证 | ①–④ |
| 11 | YU-RIS | 未实现 | 新 adapter：文本 / 语音资源边界 |
| 12 | FVP（Favorite） | 未实现 | 新 adapter |
| 13 | Softpal / Unison | 未实现 | 新 adapter |
| 14 | NeXAS | 未实现 | 新 adapter |
| 15 | Ren'Py | 未验证 | ①–④（已有运行时布局） |
| 16 | TyranoScript / NW.js | partial | ③④（WebView 路线） |

### P3 · 小众 / 老引擎 / 单品牌引擎

Majiro、AliceSoft System4、EntisGLS、Livemaker、NScripter/ONScripter、Escu:de、ExHIBIT、AOS/SFA、Unreal，以及已有单品牌精确 profile、待原始路径验收的 Leaf/AQUAPLUS、HUNEX GGE、smash/fzmedia、SGRE。按 P0 的库分布统计决定先后。

## 5. 每个引擎的固定流程

1. **取样本**：优先官方体验版或小体积版本，下到 D 盘，测完删除；每个引擎至少两个不同版本 / 发行形态。
2. **身份台账**：exe 路径 / SHA-256 / 架构、启动器与真实进程关系、壳与 TLS 回调、关键模块（SOP §2）。
3. **原始路径逐关**：按 `process_found → helper_ready → ipc_ready → text → resource/pcm → paired → 查词几何 → 点击消费` 逐关推进，只修第一个未通过的边界。
4. **引擎级修复**：判据来自引擎结构；配跨引擎负向样本或负向测试。
5. **验收**：Fushi 宿主（`gal_realgame_driver_itest`）走原始路径，四条逐条留证据（台词、音频后端、查词卡截图、点击前后台词计数）；能写卡的再补一张真卡。
6. **落账**：`docs/bugs/` 一 bug 一文件；`engine-support.yaml` 只有四条 + 真卡齐全才升级状态，否则只加测量记录。

## 6. 完成度看板（随适配推进更新）

| 引擎 | ① 文本 | ② 音频 | ③ 查词卡 | ④ 点击不推进 | 已验样本 |
|---|---|---|---|---|---|
| KiriKiri Z（KAGEX，千恋＊万花光盘原版） | ✅ | ✅ | ✅ | ✅ | 1 |
| KiriKiri Z（喫茶ステラ原版 / 汉化版） | ✅ | ✅（资源） | 未测 | 未测 | 2 |
| 其余引擎 | 见第 3 节 | | | | |
