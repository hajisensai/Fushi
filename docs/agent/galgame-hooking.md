# Galgame Hook 引擎适配 SOP

本流程用于 Hibiki 的日语学习制卡功能：从用户本地、合法取得的游戏中采集当前文本、逐句语音和画面，供用户制作 Anki 卡片。它不用于复制或分发游戏内容。

总设计见 [design.md](../specs/galgame-mining/design.md)，阶段计划与完成证据见 [engine-adapter-plan.md](../specs/galgame-mining/engine-adapter-plan.md)，当前支持状态以 `native/galgame_hook/engine-support.yaml` 为唯一真相源。

## 1. 边界与开工条件

- native 采集组件在本仓 `native/galgame_hook/`（源码已合仓）。**产物边界不变且是硬规则：绝不编进 `Hibiki.exe`**，只由根 `.github/workflows/voice-hook-helper.yml` 单独构建成 `voice_hook_<arch>.zip` 发布，app 按需下载解压到 `voice_hook/<arch>/`。
- 合仓的依据：迁出独立仓库的真正根因是「主仓库那份 workflow 不在默认分支、无法 workflow_dispatch」，合仓后 workflow 就在 develop 上，问题消失；而「必被杀软报毒」经实测证伪（Defender 签名 1.455.357.0 对全部文件与 zip 零检出，同轮 EICAR 阳性对照正常报出，见 hibiki-hook#8）。国产杀软未验证，若被拦按误报处理。
- 消费端（IPC 消费、文本与音频配对、制卡 UI）与 native 采集实现现在同仓，**改 IPC 契约必须两侧在同一个 PR 里落地**——这正是合仓要消除的版本不同步。引擎支持矩阵唯一真相源是 `native/galgame_hook/docs/engine-support.md`（由同目录 `engine-support.yaml` 自动生成），不得另存副本。
- 一引擎一任务、一独立 worktree；批量引擎任务只负责排队和汇总，不在同一实现任务里交叉试错。worktree 先运行 `tool/setup_worktree.ps1`，并按根 `CLAUDE.md` 登记 ownership。
- 先记录游戏名、版本、exe 架构、启动器与真实游戏进程关系、原始失败路径；没有真实样本证据时只能标记 `implemented_unverified`，不得写成“已支持”。
- 不收集、提交或上传游戏 exe、脚本、图片、语音、归档密钥等受版权或敏感内容。诊断包也遵守同一边界。

下文命令均在 `native/galgame_hook/` 下运行。Windows 入口统一为：

```powershell
powershell -ExecutionPolicy Bypass -File tool/galhook.ps1 <command> ...
```

## 2. 身份、阶段与证据台账

写任何 Hook 或配对代码前，先按用户报告的原始安装目录、原始启动入口和原始操作顺序跑一遍，并为本次会话保存以下台账。路径可在对外诊断包中脱敏，但本机验证时必须能据此确认实际加载对象。

| 类别 | 必填事实 |
|---|---|
| 样本身份 | 游戏/版本、原始启动入口、exe SHA-256、x86/x64 |
| 进程身份 | 启动器 PID → 实际承载窗口/文本/音频的游戏 PID、父子关系、最终镜像路径 |
| 组件身份 | 实际加载的 helper、Hook DLL、关键引擎/中间件 module 的绝对路径、版本与 SHA-256 |
| 生命周期 | 启动、发现真实 PID、注入/附着、helper ready、IPC ready、module load、首次资源访问、首次文本与首次音频的单调时间 |
| 原始失败路径 | 用户从哪里启动、何时 attach/早注入、执行哪句/哪个动作、预期与实际停在哪一阶段 |

会话阶段固定分开记录，不能用一个 `ready` 或十六进制总状态代替：

| 阶段 | 最小通过证据 |
|---|---|
| `process_found` | 已确认真实游戏 PID/镜像/架构，不是 relay、launcher 或即将退出的父进程 |
| `helper_ready` | 对应架构和哈希的 helper/DLL 已在目标会话就绪 |
| `ipc_ready` | IPC 契约/版本匹配且生产者、消费者仍存活 |
| `text_ready` | 真实台词从选定线程到达，系统/UI 伪影已排除 |
| `resource/pcm_ready` | 真实播放动作产生资源事件或非静音 PCM；模块/imports/Hook installed 不算 |
| `paired` | 同一个稳定 event ID 的文本与对应语音完成配对，未用 latest/string fallback 冒充 |
| `e2e_verified` | 原始路径完成台词、对应语音、画面与真卡写入；原始资源另有字节哈希一致性 |

能力证据也要逐级写清：`candidate`（仅静态特征）→ `observed`（真实运行事件）→ `captured`（取得可验证字节/PCM）→ `voice_classified`（证明是角色语音、混音或 BGM/SE）→ `hash_verified`（适用时与源 entry 一致）→ `e2e_verified`。这些是台账证据等级，不替代 `engine-support.yaml` 的状态枚举；在原始路径 E2E 前，manifest 仍只能是 `implemented_unverified`。

每轮只处理原始路径上**第一个未通过阶段**：先复现并冻结其上游证据，只修改该边界所需的 profile/adapter/消费状态机，随后从原始路径重跑。不得同时根据 imports、引擎名或相似 DLL 猜多个下游 Hook；共享中间件只有在 profile 明确限定数据契约并有跨引擎负向测试时才能启用特例。

## 3. 从用户报告到脱敏诊断包

先在用户原始安装路径运行静态 probe：

```powershell
powershell -ExecutionPolicy Bypass -File tool/galhook.ps1 probe 'D:\Games\Title\game.exe' --output build\title-probe.zip
```

默认 ZIP 只包含 `diagnostic.json` 与 `README.txt`。`diagnostic.json` 记录相对且脱敏的文件清单、大小/扩展名、PE 架构与 imports、能力摘要；不会复制 exe、脚本、图片、语音或其他游戏载荷，根路径写为 `<game-root>`。交付诊断包前仍要人工检查 ZIP 成员和 JSON，确认没有用户名、绝对路径或游戏内容。

需要动态证据时，可在用户明确同意且游戏已运行后追加进程或现有 trace：

```powershell
powershell -ExecutionPolicy Bypass -File tool/galhook.ps1 probe 'D:\Games\Title\game.exe' --pid 1234 --trace build\capture-trace.json --output build\title-live-probe.zip
```

动态 probe 只归纳进程树、已加载模块、线程/资源/音频格式和能力状态。Hook Code、文本内容、资源字节不会进入默认包；若排障确实需要内容，应在仓库外单独取得用户授权并做最小化脱敏，绝不提交真实内容。

分析顺序：

1. 确认实际承载游戏的进程与 PE 架构，而非只看启动器。
2. 用 imports、运行时模块、资源扩展名和哈希与 `engine-support.yaml` 比对。
3. 按“原始逐句资源 → 解码器/中间件 → 引擎 API → XAudio2/DirectSound → 进程 Loopback”选择最靠前的可行音频层。
4. 文本优先复用 LunaHook；引擎特例必须收在独立 bridge/profile/adapter，不把逻辑塞回 worker 主干。

其中 imports、文件名和模块存在只用于产生候选，必须用运行时事件、捕获字节和原始路径动作逐级升级证据。相同中间件 DLL 不代表不同引擎具有相同 datasource、回读、加密或生命周期契约。

## 4. 创建一个适配骨架

引擎 id 使用小写字母、数字和下划线：

```powershell
powershell -ExecutionPolicy Bypass -File tool/galhook.ps1 new example_engine --hibiki-root 'C:\src\hibiki'
```

命令会拒绝覆盖已有文件，并生成或注册：

- `profiles/example_engine.json`
- `hook/adapters/example_engine_profile.h`
- `hook/adapters/example_engine_adapter.inc`
- native CTest 与合成 replay fixture
- registry 的受管 include/startup/shutdown/module/fields 片段
- 指定 `--hibiki-root` 时的 Dart fixture 与测试骨架

生成后结构守卫自动执行，没有跳过验证的命令行开关；适配器也自动进入 CMake/CTest。骨架只是待实现状态，先在 profile 与 `engine-support.yaml` 标记 `implemented_unverified`，再完成 `probe/install/capabilities/onModuleLoaded/shutdown/diagnostics` 所需实现。不要在回调里做文件 IO、解析、编码、IPC 等阻塞操作：回调只能向有界事件复制固定大小或有上限的数据并立即返回，队列满时丢弃；重组、读取、配对和转码放到 worker。

## 5. 离线 replay

把最小化、合成或获准脱敏的事件保存成 JSON 后运行：

```powershell
powershell -ExecutionPolicy Bypass -File tool/galhook.ps1 replay tests\fixtures\workflow_replay.json
```

fixture 包含 `config`、按时间排序的 `events` 和 `expected`。至少覆盖：

- 选中线程之外的文本被过滤；
- 相同文本在去重窗口内只产生一次；
- 配对优先级为 resource、PCM、loopback；
- resource 晚到仍能替换较低优先级候选；
- `session_end` 清理未配对状态，后续会话不串数据。

不要把真实台词、语音字节或可还原游戏内容放进 fixture。失败时修 profile、adapter 或公共配对状态机，不通过延时、重试、吞异常或 fixture 特判绕过。

## 6. native 与 Hibiki 验证门

在 `native/galgame_hook/` 下至少执行：

```powershell
python tools/generate_engine_support.py --check
python tools/generate_luna_profiles.py --check
python tests/engine_support_manifest_test.py
python tests/adapter_structure_test.py
python tests/galhook_workflow_test.py
cmake -S . -B build-x64 -A x64
cmake --build build-x64 --config Release
ctest --test-dir build-x64 -C Release --output-on-failure
cmake -S . -B build-x86 -A Win32
cmake --build build-x86 --config Release
ctest --test-dir build-x86 -C Release --output-on-failure
```

若改动 Hibiki 的 Dart/Flutter 消费端，则在 `hibiki/` 下按根规则执行 `dart format .`、相关定向测试，再执行完整 `flutter test` 与 `flutter analyze`。工具自身崩溃要原样记录，不能当作代码通过；可补充 `dart analyze` 的有效结果，但不能伪装成完整 analyze。

任何必需命令、双架构构建、replay、定向测试或完整测试被跳过、崩溃或因环境阻塞时，逐项记录命令和原因；该能力只能停在 `implemented_unverified`。Loopback 通过只证明降级链可用，不能替代引擎 Hook、逐句配对或纯人声验证。

## 7. 真实游戏验收与证据

离线测试通过后，回到用户报告的原始路径和启动方式验证。启动器型游戏同时验证子进程发现；带保护壳的游戏若只能“正常启动后附着”，要记录为明确的进程策略，不能改写成随启动注入成功。

每个支持声明至少记录：

- 游戏、引擎、版本、exe/module SHA-256 和 x86/x64；
- 原始启动路径、注入/附着方式、实际游戏 PID 与子进程关系；
- 文本来源/线程选择，以及音频命中层；
- 一次完整“显示台词 → 捕获对应语音 → 截图 → 真卡写入”的结果；
- 原始逐句资源时的格式、大小/哈希一致性证据；否则明确说明是否含混音；
- 失败、降级与已知限制，以及证据日期。

证据只保存元数据、哈希、结构化事件和必要截图；截图先检查个人信息与版权范围，禁止把游戏素材作为测试资产提交。随后更新 `native/galgame_hook/engine-support.yaml`，运行生成器更新 `native/galgame_hook/docs/engine-support.md`（唯一真相源，不得另存副本）。状态只能按证据从 `implemented_unverified` 提升为已验证。

## 8. 提交与交接

native 能力、Hibiki 消费端和进度文档分别提交，避免把无行为变化重构与能力扩展混成一个提交。交接报告列出两仓提交哈希、全部验证命令、真实样本证据、仍未验证项和后续候选。许可方面，文本优先复用隔离分发的 LunaHook（GPLv3）；资源格式可参考 GARbro（MIT），保留必要署名与许可证；禁止 vendoring NonCommercial 或其他受限许可的二进制和数据。
