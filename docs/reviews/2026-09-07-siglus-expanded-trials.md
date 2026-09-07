# Siglus 官方体验版扩展审查（2026-09-07）

## Scope

本轮在 `codex/siglus-upstream-adapter` 独立 worktree 中扩展七份官方发布的体验版样本，仅处理 Windows Siglus。x86/x64 是 helper 的构建架构；本轮识别的游戏均为 x86，不代表存在已验证的 Siglus x64 游戏适配。

本报告区分原文件静态结构、既有 v23 会话、诊断对照和新增 v24 所有权握手。总体支持状态仍为 `implemented_unverified`，不修改 `engine-support.yaml`。此前 SPRB、Anemoi 的阶段证据见 [原阶段报告](2026-09-07-siglus-engine-adapter.md)，不能替代本轮新 DLL 的验收。

报告仅收录版本、哈希、计数、结构关系和操作结果。下文本机证据名均相对于 `.codex-test/siglus-engine-adapter/`，不纳入真实游戏载荷、台词、反汇编片段或私有绝对路径。

## Proved

### 官方分发来源与下载完整性

七份下载均已完成解压和 ZIP CRC 检查。前三份还核对了发布方提供的 MD5；其余四份没有取得官方预期 MD5，不能将本机计算摘要称为“官方摘要校验通过”。下表 SHA-256 是下载包的本机计算值，与下一表的游戏 EXE 摘要不同。来源和摘要以下载目录中的同名 `.verification.json` 为本机依据。

| 样本 | 分发地址 | 官方 MD5 校验 | 下载包 SHA-256 |
|---|---|---|---|
| Rewrite 体验版 Ver.2.00 | [发布方链接镜像](http://dl.studio-ramble.com:8081/300/201103/RewriteTE_Ver200.zip) | 通过 | `c6595f3a7c6ce1ff943cc70cee1af907abe0e68400c16779213bec980a7d5dee` |
| Angel Beats! -1st beat- 体验版 1.10 | [发布方链接镜像](https://rocketpad.xii.jp/item/key/angelbeats/AngelBeats-1st-_TrialEdition_ver1.10.zip) | 通过 | `8347a55b9d9dbaa4140e7e6f744661f1236a35cf2c1ccfed78a89a1092fafe3a` |
| LOOPERS PLUS 体验版 | [VisualArt's 分发](https://va-trialdist.azureedge.net/trial-loopers-plus.zip) | 通过 | `a1504738b3f81d333662dd914188bba29ce354ac0d888768f404500d4473bd4c` |
| 月の彼方で逢いましょう 体验版 | [DLsite 官方体验版分发](https://trial.dlsite.com/professional/VJ013000/VJ012598_ana_trial.zip) | 无官方预期值 | `37f9c566e0a1db735c5b6681e75d4af839cf31b0e6d427a754b93d8cabdc4ebf` |
| LUNARiA 体验版 | [DLsite 官方体验版分发](https://trial.dlsite.com/professional/VJ015000/VJ014985_trial.zip) | 无官方预期值 | `7395269e4e1408a40c3c026a38d6731e515c9c0dbed28c9bcd80631ebb9ac8d5` |
| 終のステラ 体验版 | [DLsite 官方体验版分发](https://trial.dlsite.com/professional/VJ016000/VJ015604_trial.zip) | 无官方预期值 | `c591417a951bb420d16a43bf7fe05f8ca4d0bf196bf826993edbdb2568ebf6c2` |
| LOOPERS 原版体验版 | [Key 分发](http://dlsv.product.jp/key/loopers/loopers-trial.zip) | 无官方预期值 | `7163c87e83422e5ccc154adc360942373aa319559facabb5eceff4c55d75972a` |

### 七份原始 EXE 的身份与静态边界

以下均为各样本 `StartData/GameData/SiglusEngine.exe`，而非启动器；Rewrite 文件资源版本 `1, 0, 4, 0` 在表中规范显示为 `1.0.4.0`。

| 样本 | 架构 / EXE 版本 | EXE SHA-256 |
|---|---|---|
| Rewrite | x86 / 1.0.4.0 | `6e01827e8d9427d0cf5fb4933224865e8cff22bc78ae8264c15cdd5584f77253` |
| Angel Beats! | x86 / 1.1.80.4 | `c09a0a415f2333fff53fe648245a268c6b15e9e40074d9c18ba0bed5c21dd0ee` |
| LOOPERS PLUS | x86 / 1.1.140.8 | `49bac0ac8d3520554220f7cd7dd289d3f740fb3b1740bc108138f253a77de1c7` |
| 月の彼方で逢いましょう | x86 / 1.1.134.0 | `1a1067098727530e11cb522aa21ae784db681138f675a12f15efa116f2f61316` |
| LUNARiA | x86 / 1.1.137.0 | `96ce09a5fac59d6911248020f8d03d7ff5263baefe703f1bb9a038366975f4e2` |
| 終のステラ | x86 / 1.1.137.0 | `b3d0bc77fd043c93e5ea469cf05341a541de425ea76afc295c5f5d85984526c5` |
| LOOPERS 原版 | x86 / 1.1.137.0 | `7fd6e190b5ed01901f70654264df6a029296f90438fbd587b9f876b198e22dfb` |

| 样本 | LunaScenario 严格静态结果 | NativeEcxTextUnion / viewport 边界 |
|---|---|---|
| Rewrite | 共同 glyph 唯一入口签名计数为 0，首门失败 | 同一首门失败；散落的 return 签名不构成 ABI 证明 |
| Angel Beats! | glyph 唯一、栈为 `0xdc`；本家 DialogueCall 计数为 0 | native DialogueCall 同样为 0；现有完整 profile 不接受 |
| LOOPERS PLUS | DialogueCall 计数为 0 | 原 native 文本和 glyph 链可识别，旧 input/viewport 编译布局不匹配；新增完整结构对和 v24 所有权握手后，默认宿主附着及有限查词序列通过 |
| 月の彼方で逢いましょう | 完整生产纯 resolver 通过；配置槽 RVA `0x7ac370` | native 首结构门失败：glyph 栈 `0xec`，本家要求 `0xdc` |
| LUNARiA | 完整生产纯 resolver 通过；配置槽 RVA `0x7ad350` | 同上 |
| 終のステラ | 完整生产纯 resolver 通过；配置槽 RVA `0x7ad350` | 同上 |
| LOOPERS 原版 | 完整生产纯 resolver 通过；配置槽 RVA `0x7ad350` | 同上 |

“完整生产纯 resolver 通过”指将原 PE 文件节复制到本机私有、不可执行的内存映射后，调用生产 `OpenSiglusLoadedImage`、具名 GetKeyState import 解析、`ResolveSiglusFamilyProfile` 和 `ResolveConfigSlot`。除了唯一签名，还检查函数内有界 return、对象 ABI、调用目标和 IAT 关系；没有执行游戏字节、访问运行进程或安装 Hook。配置槽不是运行时设计尺寸，仍须在原始会话重读 `+0x7c/+0x80`。

Native 的真实导出绑定无法由原文件证明。分析工具即使提供非零分析 token，也只用于定位后续结构门；上述四份 Luna 正例没有进行 synthetic IAT 替换。任何对私有映射的假导出替换只能记为 `syntheticcorroboration`，不得升级为 runtime。

静态依据：`rewrite-trial-static.json`、`official-trials-static.json`、`tsukikana-static.json`、`tsukikana-static-production-resolver.json`、`three-official-trials-static.json`。末项同时保存冻结生产头的 SHA-256，避免仅凭分支 HEAD 忽略尚未提交的解析器修改。

### LOOPERS PLUS 编译变体与所有权竞争

本轮修改 `siglus_native_autoprofile.h` 与对应测试，新增完整 input 编译布局：main-call 栈槽、键循环对齐指令、键状态表及左键读取必须成组匹配；独立 message-up 分支、跳转表目标和释放调用与键循环消费路径相互确认。不得由两个布局各借半组，也不得只凭 IAT 内容或可执行地址猜 GetKeyState。

`siglus_native_viewport.h` 与对应测试新增独立 renderer/normalize 结构对。两个分支必须全局唯一、引用同一可读可写非执行配置槽；完整旧组与新组同时匹配、孤立半组、错槽或角色错误均拒绝。没有扩大旧签名的通配范围，也没有按游戏名、hash、固定 RVA 或固定分辨率选择变体。动态设计宽高仍重读配置对象 `+0x7c/+0x80`。证据为 `loopers9544-input-proof.json`、`loopers-plus-live-viewport.json` 及合成负向测试。

同一 v23 DLL `485a90ee79613bcaa5a869e6a3800616112593cd25a8bf1307c692fa7ce396de` 的两次原路径会话暴露了 [BUG-2233](../bugs/BUG-2233-siglus-text-hook-ownership-race.md)：

| 会话 | 操作与结果 | 证明范围 |
|---|---|---|
| PID 28384 | 正常启动、普通宿主附着；完整 profile 未匹配，观察时文本入口已被修改 | 默认安装顺序存在入口所有权竞争；不能仅凭晚期 E9 的目标断言是谁首先修改 |
| PID 50588 | 重新沿原始 Start.exe 启动；同 DLL 以 `--hold --no-luna` 对照，完整 profile 匹配并产生第一条原生正文 | 独立 native ABI 的可行性；没有接宿主查词界面、没有启用几何，也没有真实词条或制卡证明 |

`--no-luna` 是定位竞争的实验变量，不是要求用户使用的适配方案。依据为 `loopers28384-live-gates.txt`、`loopers50588-native-only.log`、`loopers50588-native-only-probe.log`。

新增 IPC v24 在尾部追加 Siglus 文本所有权：`Pending` 只能转为 `NotApplicable`、`NativeOwned` 或 `LunaAllowed`。DLL Ready 和音频 ACK 不再授权 Luna 抢先扫描；worker 在原生 Hook 已启用且 original 有效之后发布 NativeOwned，LunaScenario 或确定失败则放行 Luna，hydration 未决由 worker 继续推进。宿主 helper 的既有 hold 轮询读取终态，重附着保留驻留决定，不重置所有权。

MinHook 初始化失败、正常关闭和 Ready 通知失败均有 Pending 终结路径；Ready 失败还清除 `hooked`，防止后续 helper 把已退出的 worker 映射当成可复用会话。非 Siglus、音频 ACK、guarded hook 移除确认及恢复主线程的原有顺序保留。代码接线位于 `include/siglus_text_owner.h`、`voice_hook_ipc.h`、`adapter_registry.inc`、`text_render_adapter.inc`、`dll_main.cpp`、`injector_main.cpp`，回归包括 `siglus_text_owner_test.cpp` 和生产结构守卫。

### 已观察的 v23 有限查词序列

LUNARiA 原路径正常启动后，PID 50536、helper 12212、宿主 33084 使用上述 `485a90...` DLL 与 IPC v23。游戏原默认字体在本机不可用，操作员在游戏自身配置中选择 MS Gothic 后继续。初选的 EmbedSiglus2 是开场字幕线程；切换到与常规对白一致的 SiglusEngine3（显示后缀 `#0d43`）后，主代理实际观察到点击“独走”显示新明解真实词条、窗外关闭不推进、再次同处点击推进。

该有限序列见 `lunaria-v23-evidence.json`。此前 seq 1 虽有命中和 present 日志，操作员没有确认清晰可见的浮窗；约 11 秒后宿主因短暂 native 不可用撤销准入并关闭。该早期现象根因仍未确定，不能因后续选对线程成功就宣称已证明线程选择是唯一原因，也不能把它归因于 v24 所有权修复。

SPRB、Anemoi 仅保留旧 v23 的真实词条和关闭/推进证据（`sprb-v23/`、`anemoi-v23/`）；本报告不将其视为新 v24 DLL 已回归通过。

### 已完成的离线检查

| 检查 | 结果 | 本机日志 |
|---|---|---|
| 最终 owner 版本 Windows x64 native 构建、CTest、组包 | 退出 0，72/72 | `siglus-owner-final-distribution.log`、同名 `.exit.txt` |
| 最终 owner 版本 Windows x86 native 构建、CTest、组包 | 退出 0，72/72 | 同上 |
| 宿主 IPC 契约定向测试 | 10/10 | `siglus-owner-host-contract.log` |
| 新 Windows 宿主完整构建与 helper 安装 | 退出 0，Release 构建 34.5 秒 | `siglus-owner-windows-build.log`，同名 `.exit.txt` 为 0 |
| manifest / Luna profile 生成检查 | 均退出 0 | 本机检查日志 |
| manifest / 结构 / workflow 定向测试 | 22/22、40/40、6/6 | 本机检查日志 |
| SOP Python 合成 replay | 退出 0，三种配对路径、去重和过滤通过 | 工具是独立 Python 模型，不能当作 Dart/native 生产状态机 replay 或真实游戏制卡证据 |

### 默认 v24 运行证据与新边界

最终 owner 构建实际 DLL SHA-256 为 `eef92ede7c8c10cb88ad7a68e67784c9ad335f729713def14b3213f517743488`，helper 为 `613f6d384bfe88ac854d594e33ff21076621b964b84c447743e2fc1471f76cfd`，宿主 EXE 为 `afec6dcf9191b4259dfe465ca4e2cf73f6249f67ea93c1debe0beedf8ab39cd5`。两架构分发包 SHA-256：x86 `d7634bfaff2ec9dbf3abd7bae3d955c1f9749e86668d18c8ef4fea0e890c8a9d`，x64 `0d1abf2bf2b1a1309a424e18585d5de5e0525c682f130254ec71acf26590c4ad`。

LOOPERS PLUS 从原版 Start.exe 经启动菜单进入 PID 35760，宿主 58124 正常附着、helper 14640 使用默认 `--luna-pchooks`，没有 `--no-luna`。实际 IPC v24 的 owner 为 NativeOwned=2，进程仅加载本项目 Hook DLL，没有 LunaHook32 模块。完整 profile、原生正文线程和有效 glyph hit 已观察，命中时 geometry/text generation 同为 23。实际新明解释义可见；窗外点击关闭且原句保留，下一次同处点击才推进。不需要风险确认或手工校准。

本机 `loopers-plus-v24-evidence.json` SHA-256 为 `780070d9d0978a75d3428a968fa3cb1f21e35bd1336e567baa95b3ef8ab0a516`，`verify-evidence --require-stage observed` 退出 0，release_eligible=false。晚期 provider 已退役后的残留 hit 标量没有计入有效命中。

終のステラ正常原始启动进入 PID 37120，helper 71740 使用相同 v24 bundle；owner=LunaAllowed=3，实际 LunaHook32 和本项目 DLL 均已加载，严格 LunaScenario profile、正文和真实新明解词条可见。但此次有限序列没有通过关闭/推进门：词典在显示约 10 秒后，宿主因瞬间撤销 native 准入先主动关闭，随后一次点击推进。[BUG-2234](../bugs/BUG-2234-siglus-partial-redraw-retires-popup.md) 记录了同句 glyph 重绘跨 worker tick 导致整个 provider 退役的根因。不能把已提前关闭之后的点击误写成 shield 漏 up，也不能将这次运行记为完整查词交互通过。

该失败会话本机台账 `stella-v24-failure-evidence.json` SHA-256 `a4f8c1050fa3fd81517851d8f66d571bed5750f3dc9fd72c78b461c710a25c21`，observed 校验退出 0。

### 同句重绘修复

BUG-2234 在 `SiglusLookupLayoutState` 中分开“当前正文曾形成完整布局”与“最新字形批次可点击”。第一次完整前不认领 provider；同句重绘不完整时保留健康 provider，但立即撤销 click target。逻辑 generation 在同句相同布局恢复后保持，独立 snapshot_epoch 则使跨越不完整批次的旧按下不能在恢复后提交。新正文、窗口/设计尺寸/传感器或会话失效清除能力；宿主撤销逻辑和其他 provider 仲裁未放宽。

修复后完整分发构建退出 0，x86/x64 CTest 各 72/72；结构守卫 41/41，manifest 22/22、workflow 6/6、两项生成检查及合成 replay 通过。最终 DLL SHA-256 `6f18f98cb239c7825cf3ec3c68a0b1af75d86c38ffd18cf28c672347d8a4a86c`，x86 分发包 `dedbcfa6daf16b55567161aca2822322ebff06289e361382560158951b450acd`，x64 包 `24e9dfa43e53e14c66886c2ca6e37202a6fde09409521bc5b69d3cb3773e2c17`。宿主 IPC 未再次改变，使用已通过构建的同一 v24 EXE；生产安装脚本核对新源码 fingerprint 后将新 helper 安装进 bundle。

終のステラ重新从原版 Start.exe 进入 PID 36724，宿主 24584、helper 31648 正常附着最终 DLL，owner=LunaAllowed。选定干净 EmbedSiglus 正文后，两次分别点击原词均显示新明解；首次词典从 16:30:23.144850 持续到操作员于 16:31:51.464567 关闭，期间未发现准入撤销或自动 dismiss。两次窗外关闭均保留原句，第二次关闭后的下一次普通点击才进入下一句。两弹窗关闭之后的新句边界仍有准入变化，未将其隐去。一次截图 crop 失败后重新选择同一游戏窗口确认词典已显示，没有重复补点。

本机 `stella-v24-redraw-evidence.json` SHA-256 为 `0eb76b1c35e9c6bce6665f68efac7534f26102d7e634cbd287aa85ab1226e3ff`，observed 校验退出 0、release_eligible=false。本轮证明修复后的有限查词交互，不证明任意重绘节奏下零丢点击，也不升级音频/制卡支持。

### 最终 DLL 的新增原路径回归

实现已提交为 `781e80dd64`。LOOPERS 原版从原始 Start.exe（PID 53888）经 StartMenu（5352）进入游戏 29784；宿主 24584、helper 19356 使用最终 `6f18f9...` DLL、IPC v24、LunaAllowed=3。游戏自身字体配置使用已安装的 MS Gothic。初选 EmbedSiglus2 出现重复渲染文本后，操作员改选干净 EmbedSiglus；不能将此记为自动选线程验证。点击原词显示真实新明解，词典从 16:40:06.418638 保持到 16:41:15.110862，窗外关闭保留原句，下一次点击正常推进。本机 `loopers-original-v24-evidence.json` SHA-256 `0bc021160b3531836511922f736d0a7f8d12e008e4d1f30f4ad4d9f7691eb116`，observed 校验退出 0。

LOOPERS PLUS 最终 DLL 回归从原始 Start.exe（55616）经 StartMenu（23664）进入游戏 70708；宿主 24584、helper 59804 默认附着，owner=NativeOwned，实际模块只有本项目 DLL，没有 LunaHook32。有效命中 seq 1、source [15,+1]/25、geometry/text generation 20/20、设计尺寸 1920×1080。词典从 16:56:22.452557 保持至 16:57:01.108357，窗外关闭不翻页，下一次点击显示第二句。本机 `loopers-plus-v24-redraw-evidence.json` SHA-256 `2e5f32cd1f3c681d8af4ed7d2732fc1bbd0e734a5b7b89f804f8236d251e57aa`，observed 校验退出 0。该会话 TextSlot 计数只有 1 时 lookup.text_generation 已为 20，暴露布局 generation 与正文事件身份混用的制卡契约问题；查词交互通过不能替代制卡身份验证。

月の彼方で逢いましょう重跑正确原版启动路径，Start.exe 34472 经 StartMenu 73228 进入游戏 67724，显示日语 Windows 环境检测对话框，未进入正文、未附着 helper。操作员正常确认退出，不是进程自行崩溃。本机 `tone-start-gate-metadata.json` SHA-256 `c7886566a0190113e1c0b55849360d48b2914c35c025867012870f61d83ef787`。此前重复实例提示不再是当前首门。

Locale Emulator loader 修补在独立分支提交 `891ead87d23b`，针对 loader 链表 sentinel 被误当模块的问题，四项针对性测试通过；没有完成可分发 DLL 构建或原始游戏运行验收，未合入本分支，不视作三个旧版样本的环境阻塞已解除。

### 音频身份与宿主后续失败边界

LUNARiA 从原版 Start.exe 33116 经 StartMenu 7460 进入游戏 59820，宿主 24584、helper 25996 使用上述 `6f18f9...` DLL 与 LunaAllowed=3。选定干净 EmbedSiglus 之后，当前正文全局 seq 为 369。九个实际导出 Ogg 与原 OVK 唯一索引 entry 的完整 SHA-256 相等，`lunaria59820-resource-metadata.json` 摘要 `72820973b8d210da363874ba2271f55e9c38b05992040f17078345038fa99627`。

原生 VOICE 重放一次后新增同一源 entry 的资源文件（旧文件尾缀 166452），正文 seq 369 保持不变；导出与源 entry 和此前导出完全同 hash。后续实际查找结构证实 166452 是采样数、member ID 是 125、offset 是 769065、长度为 70860，旧导出尾缀不能作为成员身份。差分 `lunaria59820-replay-comparison.json` 摘要 `7b4e38b8db621f76d6304b74f75a40e328e63bd7b6cf70a475c0be2d211fd3cd`。现有资源任务没有正文事件 ID，VoiceClip/引擎 PCM 仍为 0，没有以相邻时间或 game_resource 标志升级为 paired。该缺口记录为 [BUG-2237](../bugs/BUG-2237-siglus-voice-resource-without-dialogue-event.md)。

[BUG-2235](../bugs/BUG-2235-siglus-ovk-export-failure-reported-captured.md) 的导出失败虚报 Captured 修正在 `ea810ec399` 提交，x86 生产 DLL 构建退出 0，结构守卫 42/42；没有向用户磁盘注入故障。[BUG-2236](../bugs/BUG-2236-siglus-lookup-layout-generation-as-text-event.md) 的真实 TextSlot 事件身份修正整合为 `aae432e86e`，原分支 x86 DLL 构建及定向 CTest 1/1 通过；整合后结构守卫 43/43。它仍不创建不存在的原生音频请求身份。

此后 LUNARiA 旧 DLL 会话的有效 hit 3（generation 12/12）没有宿主 present：Windows Event1000 确认宿主 PID 24584 于 17:11:31.893062 在 flutter_windows.dll+0x3e735 发生 c0000005，随后同位置 c000041d。用精确匹配 GUID/age 的本地 Flutter PDB 只读分析，定位到 `FlutterPlatformNodeDelegate::ChildAtIndex` 对 `GetUnignoredChildAtIndex` 空结果调用 `id()`；MSAA 路径为 GetTargetFromChildID → get_accChild → oleacc/UIAutomationCore。虽然上层已检查子节点数，dump 缺少节点/委托 heap 页，尚不能证明失效的具体时序。旧 [BUG-2231](../bugs/BUG-2231-windows-uia-flutter-host-crash.md) 经相同符号定位在 GetStringAttribute → get_accValue，不能合并为相同内部根因。本机 `host24584-crash/findings.md` SHA-256 为 `97c157ebf68b87ed5b3bf8e1bd3140556e1dd9d351a7f214dec0107ceeb5ac6e`。未修改 Flutter SDK、关闭可访问性或改系统设置。游戏/helper 仍存活；该失败没有计入新版 DLL 查词通过，更没有执行真卡。

### 正文身份修正的集成构建

当前集成代码为 `16ea0045fa`，包含 `aae432e86e` 的 TextSlot 身份修正和弹窗 occurrence 绑定：首次精确 event seq 唯一命中后固定行 ID，空白折叠导致 seq 更新仍保持同一 occurrence；会话、窗口、线程变化或行删除后拒绝，不回退到同文或最新行。五份相关 Flutter 定向文件共 72/72 通过；纠正文件路径后的五项 Flutter analyze 退出 0、无问题，首次错误路径退出 1 与独立 Dart analyzer 的工具崩溃均保留，不计为通过。

整合后的 Windows x86/x64 分发构建退出 0、CTest 各 72/72。x86 Hook DLL 为 `7312efb15f2fe6e55e8b3110dcead4cd0f4b7c5d0336adfbdf00f45d5dc920a8`，build / ZIP 成员 / bundle 相同；x86 包 `fe263deee6935fcd7532ace1821df3f7d0042d53ce55f5aaea0acbc5f4ca0850`，x64 包 `ddf69a6d2b1a46c701d184f0eb0b35e88c952990b76badce7186be4c21f0fdb9`。Windows Release 构建退出 0、耗时 129.3 秒，实际 Dart AOT `Release/data/app.so` SHA-256 为 `7e5ee854823ac243096116a92f53065be901c52b2d962094e2782979f3d1204a`；EXE hash 未变，不能单凭 EXE hash 证明 Dart 更新，也没有旧 AOT hash 的变化对比。完整本机构建记录 `identity-build-metadata.json` SHA-256 `9dcaf00c301f2714537537aa95e73268428444255a2266f94c4a4a36c497db86`。上述游戏运行证据仍使用各自明确记录的旧 DLL，尚不能计为这个新构建的运行验收。

本轮补充离线门：两生成器退出 0；manifest 22/22、结构 43/43、workflow 6/6、evidence 16/16。SOP Python replay 的 9 事件通过，但它是独立模型；另直接调用生产 `GalHookSessionController` 的 RealLive 合成 replay 单项 1/1 通过，仍不证明 Siglus 实机音频身份。vendor 校验首次因 Windows PowerShell 环境缺少 Get-FileHash 退出 1，保留该失败；本机 pwsh 7 下四个 DLL 哈希校验退出 0。本机 `identity-offline-gates/metadata.json` SHA-256 为 `fbd6f790a7cc38f633eb5c4155db9a8990b1ac9efd3249d1bd31a738aa6087f4`。

身份修正构建的补充原路径观察：LOOPERS PLUS PID 10836、helper 27980、宿主 59356 实际使用 `7312ef...` DLL。18:19:51 的有效 hit 引用真实 TextSlot seq 1，而 geometry_generation 为 22，两个身份已分离；18:20 新明解词典可见。首次窗外输入被辅助窗口遮挡而未发送，不能记为关闭通过。用户暂停后恢复时已到另一台词；截至 18:34:53 的独立 UI 序列重新打开新明解，窗外点击只关闭并保留原句，下一次同处点击推进。本机台账保留两段各自限制；后一段未采集新的 seq，不用于声称该台词音频配对或制卡成功。

### 消息与语音来源的接线

`641f55d0a1` 的消息/正文裸入口 observer 冻结同次 owner 和调用帧票据，worker 写入实际 seq；`afa45073e2` 将该 TextSlot 实际提交时间传给 typed 音频，避免排队延迟被宿主的 1500 ms 检查拒绝。`6c61fad5a0` 独立验证语音 key 的归档/成员运算及 OggOpen 参数调用链：SPRB、LUNARiA、終のステラ、LOOPERS 原版、月の彼方で逢いましょう五个原版结构通过，另四个样本拒绝。该静态证明不直接打开音频配对。

`e866ec70a8` 的来源 observer 校验实际 OggOpen 调用帧、reader/vtable、两份 key、路径、offset 与 length，并只向有界队列复制元数据。worker 核验规范文件、索引全域成员唯一性、文件身份及 SHA-256 索引摘要，再以实际 seq 输出。`e2b144fc3f` 在真实 writer/export/binding 路径验证文件名和字节、错误来源、无声、读取/写入/关闭故障以及独立摘要冲突。首轮完整分发 x86/x64 CTest 各 79/79、退出 0，但审查发现相对路径延迟解析的 CWD 竞态，因此该轮没有安装到宿主或游戏。`4c4d80b4b3` 随后拒绝相对、盘符相对、根相对和不完整 UNC，并以真实 A/B 同名文件切换 CWD 测试验证；原版若仅提供相对路径，音频来源门仍会拒绝。

### 新原生消息构建的 LUNARiA 原路径闭环

`5c931c2558` 整合消息、实际提交时间、独立来源及严格路径校验。最终 Windows x86/x64 分发各 79/79、退出 0；实际 x86 DLL 为 `cb34c479177d06344c5fb8163d21bbcae5b6de88039804395c1ec5ece6afaec9`，helper 为 `4939c27ce31fbc782d302d6d3bf866ec521b2fef2b081ac860c575f9e03451d3`。x86 ZIP 为 `516226c9f08c73061dd24b143a2edbf640a4763a621d9e25cb2f98b5a9765aa0`，x64 ZIP 为 `b15d0fa1cadc5e884c3849dceab42d33d81f2f2e73d7eca1dbc603a6f5fe0900`；构建、随包及实际 runtime 哈希一致。Dart AOT 仍为前述 `7e5ee854...`，IPC 仍为 24。本机完整构建元数据为 `message-voice-final-build.json`。

LUNARiA 从原版 Start.exe 16340 经 StartMenu 71952 进入游戏 71920（19:01:01.213734），宿主 72108（19:06:24.036708）正常附着，helper 32264 于 19:07:42.853316 启动，runtime 为 `fd3ea506936a0903/x86`。游戏实际加载上述 DLL，无 LunaHook；IPC owner 为 NativeOwned，message/scenario/OggOpen 三入口均跳入本项目 DLL，voice request 原入口保持不变。此前宿主 71020 被测试命令以 Hidden 启动而没有可操作窗口；同一 EXE 改用 Normal 后出现可见窗口，不将此测试启动方式错误记作宿主崩溃或适配失败。

普通正文出现后只有原生 `SiglusEngine message` 线程，线程 ID `8423289862878541`。首句真实 TextSlot `seq1 / tick951860281` 对应文件 `951860281_fushi_textseq1_z0101.ovk_125.ogg`；源归档 member125 唯一，offset769065、length70860，源 entry 与导出 SHA-256 均为 `a503a711f1635c30cba74ca06d2c10f99599f30bd999364bf30aa263d2ec7e99`。首次选线程回捞该句时工作台仍显示仅文本；源码确认历史恢复未执行资源配对，此消费缺口另行修复，不能因原生导出成功忽略。

选线程后的有声句 `seq11 / tick952081921` 导出 `952081921_fushi_textseq11_z0101.ovk_131.ogg`，源 member131 唯一、offset839925、length60106，源与导出 SHA-256 均为 `1b87eb99938dc3b9b5e7fd6b8a43bdab0372a7f49c81f9bab3c1a63aed947f89`。工作台显示该行 `game_resource`、音频就绪与准确文件名，点击播放后按钮进入播放状态。Ogg/Vorbis 为 44100 Hz 单声道、3.334785 秒，完整解码退出 0、非静音；这些事实不替代人工听辨或纯人声分类。

同句游戏正文点击显示真实新明解词条，首次从 19:20:07.863432 保持至 19:21:25.073060 的窗外关闭，原句不推进。第二次查词于 19:21:37.635847 显示；点击制卡后实际 Anki note `1788780108844` 于 19:21:48.844 写入一张卡。只读回查该 note，Sentence 去 HTML 后与真实 seq11 逐字相同，SentenceAudio 与源 OGG 按生产 `-vn -ac 1 -ar 44100 -c:a aac -b:a 128k` 转码的 59089 字节 ADTS 完全同 SHA-256（`874c4dc3e6bf81b2529af4e9190991e59c8e2ee27a9d85bcadcc6d59a4bd375c`）。AAC 完整解码为 148480 个采样帧，约 3.366893 秒；ADTS 的 ffprobe 估计时长不当作精确值。实际卡图 SHA-256 为 `156671b528b777308aa39414c039a743452ede2f7c4b61ab2a148af92ece9f91`，主代理查看实际图片，确认对应制卡时同句游戏画面且不含词典弹窗。第二次弹窗于 19:24:24.415502 窗外关闭，原句保持，再次同处点击才推进。没有风险确认或手工几何校准。

本机 `message-lunaria71920-runtime.json` 仅保存身份、标量、哈希和观察边界，未提交游戏正文、图片、音频或归档载荷。这一条会话已实测正文、逐句原始资源、内嵌查词、画面及真卡之间的关联；尚未覆盖重复句、读档、重播、更多编译 family 或 x64 游戏，不据此提升整个 Siglus 的支持声明。无声旁白没有借用前句原生资源，工作台的 Loopback 行仍明确标记降级。

### 首次选择线程的历史资源恢复

`98884fa55e` 修复 [BUG-2240](../bugs/BUG-2240-selected-thread-history-resource-pairing.md)：历史回捞保留原始 seq/tick，仅查询对应事件桶及其时间校验；已经导出的资源当场配对，晚到资源保留同一严格所有权，不从无标记时间候选或最新资源借用。两份消费端定向测试共 69/69，含 6 项新增行为回归；focused analyze 无问题、退出 0。错误工作目录造成的首轮测试失败及本机分析器环境故障均保留在日志中，未计为通过。

Windows Release 重建退出 0、139.2 秒，使用与此前运行环境相同的 Flutter3.44.0/Dart3.12.0。新宿主 EXE SHA-256 `4729c2e4d786ecb48564a27e638b3755f58c15bfded062ebb0f546ca56ad8375`，AOT `58b17978f2bdd4a1fbfaeabecc9bf7b6a4ba433015653448a297aa711c3c29b0`；native DLL 不变。宿主73120于19:37:48.014009启动，helper4636于19:38:53.268942附着同一游戏71920。约19:39:27手动选择同一原生线程后恢复八条历史，seq11即时显示原来的逐句资源，邻接无声行保持仅文本；期间没有推进或重播。seq1已被八槽缓冲覆盖，本次不宣称恢复了seq1。本机证据追加在同一 runtime 元数据台账。

### NativeEcx 消息身份的原路径诊断

LOOPERS PLUS 原版由 Start.exe34172（19:42:32.505292）经 StartMenu40196 进入游戏41020（19:43:02.300446），新宿主73120及helper67832（19:43:55.579549）默认附着。实际游戏为1.1.140.8/x86，EXE SHA-256 `49bac0ac8d3520554220f7cd7dd289d3f740fb3b1740bc108138f253a77de1c7`；实际DLL仍为上述`cb34c479...`，IPC24/NativeOwned，无Luna模块。诊断只记录调用帧、对象字段和哈希，不导出游戏正文或语音。

前两批64个标量事件中，七条有声调用链均证明同次 voice request、写后key提交、outer、NativeText和surface的关系。原EBX为outerESP−4，NativeText的ECX为outerESP+0xc，EDI为对应owner；调用者保存槽、返回地址及surface向量关系全部一致。请求阶段的旧owner语音字段不能代替本次请求key，资源链也不能套用旧message family的EBP偏移。

病房场景的下一批在首次outer发现owner改变后按计划立即清除断点，没有把旧堆对象当成当前正文对象。第四批沿真实调用记录新owner，观察到四组完整无声O→N→R：每段旁白先清语音字段到`UINT32_MAX`，随后两次outer分别提交两个文本片段，期间没有voice request或key提交。两次outer复用相同栈地址，因此一次性票据必须随每次outer进入重新生成，不能以owner、key或ESP相等来复用正文事件。无声与有声的outer调用者不同，固定有声caller会漏掉旁白。主代理在同一时段实际观察到两段无角色名旁白；尚未观察到同一句有声语音对应多个文本片段。

四批本机台账分别为`lp41020-native-message-runtime.json`（SHA-256 `45260f0459d372b21c77b29b1170ba7c3dcc23cd00eace8384f65d13eb36f5a7`）、`lp41020-native-message-batch2-runtime.json`（`b755e6b726acafd521a375bfde3636c613a92031b901fa2e5602fa8669d87484`）、`lp41020-native-message-batch3-runtime.json`（`3cf5863089c68ab80f50e99b91cf29b6a7f12779f46fc386453217bab6f99727`）及`lp41020-native-message-batch4-runtime.json`（`e8213da8589e1d89643f145f6abe3e1019b81da04acd1d885e63052e80fe7d98`）。首次清理耗时130.623秒，超过120秒目标，事实保留；后三批分别89.685、28.924、79.113秒，均在90秒以内。调试器退出码1没有被写成命令通过；每批均另行确认Detached、没有调试器附着且原入口字节恢复。

### NativeEcx 消息生产接线与原路径回归

`3bc00e6a2f` 引入独立严格消息profile与一次性调用票据。生产observer用裸入口保存原寄存器、TLS票据和SEH隔离，将有界正文复制到既有worker队列，沿实际TextSlot提交seq/tick发布查词身份。Anemoi的surface/renderer结构不同，严格拒绝该新增路径并保留原NativeExact文本fallback；没有扩大为两个游戏都已具备新版语音。

整合审查发现 [BUG-2242](../bugs/BUG-2242-siglus-native-rollback-reenables-retained-hook.md)：内层已启而外层失败时，保留trampoline的入口不能交给普通HookFn再次启用；内层被他人预先创建也必须阻止回退。生产安装故障测试修复前失败，修复后通过。首轮两架构82/82通过的分发因这项审查发现没有安装；修复后重新完整构建，两架构仍各82/82，结构守卫47/47。最终x86 ZIP SHA-256 `4aa4555ee0a5f879deb361431e19f026638e919fc7bd1579c106e0801045b22e`，x64 ZIP `079c9049127042e881dd3c9c4140480769f6700bef2edeef506fa4264f6cbc63`；实际x86 DLL `139ee7e19e25dab3233474824d1b4bcf2c83927a8d83cbc0746e7d933a8ff220`。生产安装脚本退出0，Dart AOT不变。

原版LOOPERS PLUS在空白一号槽保存当前进度后正常退出41020；从Start.exe49952、原启动菜单进入新游戏32232（父72132，20:31:08.951001）。中间启动菜单的创建时间未采集，不补造。宿主73120于20:33:02.297发起默认附着，helper54796（20:33:02.818636）和实际DLL使用新runtime `e9de04f59549e4ef/x86`，IPC24/NativeOwned，无Luna模块。20:35:09.312读取原版存档后，实际原生message线程`10752811405284080`产生正文seq2/tick956677859。

20:36:46.068点击正文显示真实新明解词条，hit引用真实seq2而geometry generation为16。20:37:34.304窗外点击只关闭词典、原句保留；20:37:49.443下一次点击才推进到seq3/tick956836562。未要求风险确认或校准。此时新版source模块尚未接线，不把这一条文本/查词回归写成逐句音频或真卡通过。本机元数据为`native-message32232-runtime.json`；宿主线程目录显示的历史计数129没有作为IPC计数证据，实际推进前全局text_count为2。

## NativeEcx 原资源接线与 LOOPERS PLUS 真卡（21:03）

`e335a94106` 新增独立资源 ABI 后，生产 source observer 按已准入 message family 分派；NativeEcx 从保存的原 EBX 取得资源调用栈，不沿用旧版 ESI/EBX 的 offset/length 含义。完整 profile 证明 voice→resource→kind3→成员行→OggOpen 后才启用该分支，后续沿用真实事件编号、稳定绝对路径、文件身份与唯一索引核验。独立纯解析器审查和接线审查均无生产阻断；接线的合成测试直接执行真实 naked thunk 与队列，但未单独模拟 live installer 的完整 family 分派。

完整分发退出0，x86/x64各83/83，真实x86 source回调测试183项、纯资源测试365项，结构47/47，manifest/profile生成检查通过。x86 ZIP `0ca1498a95aff98617b5963214390b2e60e8bd47fa85ef07db0c2dc0f5beb2b6`，x64 ZIP `6ada60df64053d03b13939b76406e49298daf9a939376fb51142fa50640cb3d4`；x86 DLL `df4f00e531ee764ba5e6a4811552e9dde7de5c40dd964a5a69fe6d5cbd6fb36c`，x64 DLL `6aa6a9f311247c540c36691895317e532b6f3f4a30d75a996b518b25dd54b6f3`。安装脚本退出0。首次手动profile检查误用不存在的脚本名，改用实际`generate_luna_profiles.py --check`退出0；不把误命令当通过。

原始Start55156→StartMenu71768→SiglusEngine68684（20:51:05.427566），宿主73120于20:51:39.910默认附着，helper9876与实际DLL位于`be4639f98e9bcf3a/x86`，IPC24、owner2、无Luna模块。20:52:26.397原生读取slot001，产生seq2/tick957714921与`957714921_fushi_textseq2_z1001.ovk_363.ogg`。此资源71737字节，与原始z1001.ovk唯一member363（offset6818446、sample_count150270）逐字节哈希一致：`1abaf11d9f01eb8bbbbcdb292430ecd5b44cb5b8152ff6f5b92293306c94d78d`。解码44100Hz mono、150270帧、3.407483秒且非静音；这不等于额外证明纯人声分类。

20:54:19.418直接点击游戏正文显示词典，hit引用seq2/geometry17。20:54:46.436经真实弹窗制卡，Anki note`1788785687383`、card`1788785687384`已写入。正文去除标记后的UTF-16哈希与实际IPC seq2完全一致；句音46987字节AAC与该原音按生产参数转码完全相同，SHA-256 `9686f249683b651326f9cec4f4671d17ed5a53c48e29ec1850d726842ceaf1a2`；配图50194字节，实际查看为同句游戏画面且无查词弹窗。本机完整元数据：`native-source68684-runtime.json`、`lp68684-textseq2-resource-verification.json`、`lp68684-card-verification.json`；没有入库游戏载荷。为核对句子新增的本机只读digest工具先因UTF-8编译参数缺失失败，随后因生产Interlocked读helper要求写权限而自身崩溃；改用x64有界只读快照后退出0，没有改变游戏映射权限或游戏状态。

21:00:13.392首次窗外点击只关闭弹窗，21:00:27.518下一点才推进seq3。21:01:54.366重复读取同一存档，产生同文新seq4/tick958282875；原音以新的`textseq4`文件导出且哈希与seq2相同，宿主对应行也引用该新文件。21:02:22.790同词再次查词引用seq4/geometry55。不过21:02:34.757第二次窗外关闭后出现seq5推进，尚需复现和输入屏蔽路径审计，不能宣称重复交互全部通过。

## Not proved

- `6f18f9...` v24 DLL 在 LOOPERS PLUS、LOOPERS 原版和終のステラ有有限查词交互证据；LUNARiA、SPRB 和 Anemoi 的旧 v23 证据不能互换为该构建验收；更不能将任何旧会话替换成最新 `7312ef...` 身份修正构建的验收。
- Rewrite 与 Angel Beats! 的原路径启动停在日语 Windows / Locale Emulator 边界，尚无正常正文会话。LE 相关源码修补尚未 runtime 验证；不能通过修改游戏二进制、清 mutex 或绕过启动条件制造成功。
- 月の彼方で逢いましょう的原路径重跑停在日语 Windows 环境检测，静态通过不能升级为正常正文会话。
- LUNARiA的seq11和LOOPERS PLUS上述seq2分别在各自明确的DLL会话形成正文、对应原始资源、当前画面与真卡关联；其他样本及编译family不因此升级。Loopback、音频纯净性与跨版本兼容性仍分开记录。
- 未宣称任意 Siglus build、任意字体/排版或全部 galgame 引擎已支持；未知布局和歧义仍须拒绝。

## Next gate

当前先复查LOOPERS PLUS重复同词查词后窗外点击的意外推进。Anemoi仍拒绝完整Native message布局，需要从正常原路径启动后的实际映像定位首个结构差异；不能扩大签名制造通过。整段文本聚合及有声多片段未证明，不凭同owner/key/栈地址拼接。LUNARiA的重复句/读档/重播及旧样本启动门仍未验证；独立LE源码修补不能替代原始游戏会话。
