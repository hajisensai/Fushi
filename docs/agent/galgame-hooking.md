# Galgame Hook 引擎适配 SOP

本流程用于 Hibiki 的日语学习制卡功能：从用户本地、合法取得的游戏中采集当前文本、逐句语音和画面，供用户制作 Anki 卡片。它不用于复制或分发游戏内容。

总设计见 [design.md](../specs/galgame-mining/design.md)，阶段计划与完成证据见 [engine-adapter-plan.md](../specs/galgame-mining/engine-adapter-plan.md)，当前支持状态以 hibiki-hook 的 `engine-support.yaml` 为唯一真相源。

## 1. 边界与开工条件

- native 采集组件在独立仓库 `hajisensai/hibiki-hook`，不得重新放回 Hibiki，也不得编进 `Hibiki.exe`。
- Hibiki 仓只负责稳定 IPC 的消费、文本与音频配对、制卡 UI、支持矩阵副本和本 SOP。
- 两仓分别使用独立 worktree 和提交；Hibiki worktree 先运行 `tool/setup_worktree.ps1`，并按根 `CLAUDE.md` 登记 ownership。
- 先记录游戏名、版本、exe 架构、启动器与真实游戏进程关系、原始失败路径；没有真实样本证据时只能标记 `implemented_unverified`，不得写成“已支持”。
- 不收集、提交或上传游戏 exe、脚本、图片、语音、归档密钥等受版权或敏感内容。诊断包也遵守同一边界。

下文命令均在 hibiki-hook 根目录运行。Windows 入口统一为：

```powershell
powershell -ExecutionPolicy Bypass -File tool/galhook.ps1 <command> ...
```

## 2. 从用户报告到脱敏诊断包

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

## 3. 创建一个适配骨架

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

## 4. 离线 replay

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

## 5. native 与 Hibiki 验证门

hibiki-hook 至少执行：

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

## 6. 真实游戏验收与证据

离线测试通过后，回到用户报告的原始路径和启动方式验证。启动器型游戏同时验证子进程发现；带保护壳的游戏若只能“正常启动后附着”，要记录为明确的进程策略，不能改写成随启动注入成功。

每个支持声明至少记录：

- 游戏、引擎、版本、exe/module SHA-256 和 x86/x64；
- 原始启动路径、注入/附着方式、实际游戏 PID 与子进程关系；
- 文本来源/线程选择，以及音频命中层；
- 一次完整“显示台词 → 捕获对应语音 → 截图 → 真卡写入”的结果；
- 原始逐句资源时的格式、大小/哈希一致性证据；否则明确说明是否含混音；
- 失败、降级与已知限制，以及证据日期。

证据只保存元数据、哈希、结构化事件和必要截图；截图先检查个人信息与版权范围，禁止把游戏素材作为测试资产提交。随后更新 hibiki-hook 的 `engine-support.yaml`，运行生成器更新 `docs/engine-support.md`，再同步 Hibiki 的只读矩阵副本。状态只能按证据从 `implemented_unverified` 提升为已验证。

## 7. 提交与交接

native 能力、Hibiki 消费端和进度文档分别提交，避免把无行为变化重构与能力扩展混成一个提交。交接报告列出两仓提交哈希、全部验证命令、真实样本证据、仍未验证项和后续候选。许可方面，文本优先复用隔离分发的 LunaHook（GPLv3）；资源格式可参考 GARbro（MIT），保留必要署名与许可证；禁止 vendoring NonCommercial 或其他受限许可的二进制和数据。
