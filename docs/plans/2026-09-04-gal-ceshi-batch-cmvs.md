# 计划与台账：ceshi 批量适配 · CMVS（Purple Software / クロノクロック 体験版v2）

日期：2026-09-04。分支 `worktree-gal-cmvs-chronoclock`（base `origin/develop@4128d7c420`，**不**堆叠在 KiriKiri 两条分支上——CMVS 与它们没有共享改动）。
上一批：KiriKiri Z tenshi_sz（PR #1205）、经典 KAG3 Fate RN（`2026-09-04-gal-ceshi-batch-classic-kag3.md`，BUG-2116/2118/2121）。

## 用户验收标准（不变）

1. 高通用性；一引擎一任务、一独立 worktree。
2. 游戏内查词：单击字形弹卡；悬浮 + Shift 弹卡。
3. 悬浮字有高亮块；点击后整个词在台词里保持高亮，卡片收起后回到悬浮高亮。
4. 点卡片外关闭卡片时台词不推进。
5. 制卡带视频（动图覆盖整句）+ 整句音频（按句从游戏资源直提，不是系统混音）。
6. 尽量不看 hook 代码；真正的 hook 缺口必须修，不能用降级冒充。
7. 窗口模式与全屏各验一次。

## 样本身份（SOP §2，静态，2026-09-04，桌面被占用未启动游戏）

| 类别 | 事实 |
|---|---|
| 样本 | `chronoclock-trial\クロノクロック・体験版v2\`（目录名在本机以 CP932→GBK 乱码显示，路径本身可用），Purple Software クロノクロック 体験版 v2.00（2015-03-20，`update.log` UPDATE_VER=1.00） |
| exe | `cmvs32.exe` x86 sha256 `c5e715d98b56468df0a3d6bd8ec263b72bab736e0ad004de4e443a54c470ddad`（1.7 MB，段 `.text/_TEXT64/.rdata/.data/.rsrc`）；`cmvs64.exe` x64 sha256 `aa89205a61c7078a167f9e6668eea2e4328bdd5c9cbcdd6f45b238cf475acea2`（1.2 MB）。两者并列、无启动器，原始路径 = 用户双击任一。另有 `cmvsConfig32/64.exe` 设置器 |
| 模块 | `mog2x32.dll` sha256 `6b8dc960f581963bae671ebab81832df0e39a43656875eb65a6b547df1faaf70`、`mog2x64.dll` `c51ba0c33e0153492b6cb2688701b35f0ddae309828fc21a7631ac54abb5b205`（Purple MOG2 图像库，exe 静态导入） |
| imports | ADVAPI32 / COMDLG32 / GDI32 / IMM32 / KERNEL32 / MSACM32 / SHELL32 / USER32 / VERSION / **WINMM** / **DSOUND**（x86 版）/ d3d9 / d3dx9_24..42（动态挑版本）/ dinput8 / mog2x*。音频 API 只有 DirectSound |
| 资源 | `data\pack\*.cpz` 14 个，全部 **CPZ6** 魔数（`voice.cpz` 41.9 MB + `voice2.cpz` 13.9 MB = 语音；`script.cpz` 0.8 MB；`se.cpz`）；`data\pack\start.ps3`（`PS2A` 脚本入口）；`data\music\*.ogg` 明文 BGM；`data\video\*.cmv` |
| 配置 | `cmvs.cfg` 首节 `[CMVS_SYSTEM_MAIN]`、`SCRIPT_INIT_PATH=data\pack\`；`initial.cfg` `[CMVS_INIT_CFG]` TITLE/REG=`Purplesoftware\chronoclocktr` |
| 文本层候选 | vendored LunaHook32/64 均含 `EmbedCMVS`（32 位另有 `EmbedCMVS_2`）引擎钩 → `luna_hook` candidate |
| 音频层候选 | DirectSound 源 PCM（`GenericWindowsAudioAdapter`，引擎无关）→ `xaudio2_or_directsound_pcm` candidate；逐句资源需在 CPZ6 解密读取后取字节，位置只能真机定 |
| 脱敏 probe 包 | worktree `native/galgame_hook/build/probes/chronoclock{32,64}.zip`（不入库） |

## 本轮交付（静态，implemented_unverified）

- `galhook.ps1 new cmvs --fushi-root` 生成骨架并登记 registry 片段（`generated/*.inc`、CMake、admission 汇总）。
- `hook/adapters/cmvs_profile.h`：结构身份 = exe 同级 `cmvs.cfg` 前 256 字节含 `[CMVS_SYSTEM_MAIN]` **且** `data\pack\*.cpz` 至少一个 `CPZ` 魔数；两样缺一不匹配。`MatchesCmvsLayout(dir)` 接目录参数供测试；exe 名/哈希只入台账不做判据（Purple 正式版会改 exe 名）。
- `hook/adapters/cmvs_adapter.inc`：id `cmvs`，capabilities `kText | kPcmAudio`，不自带 hook（文本交 LunaHook EmbedCMVS，PCM 交通用 DirectSound 适配器），`install()` 只表示身份成立。查词传感器未做（admission 默认 EngineUnsupported）。
- `profiles/cmvs.json`：两 exe + 两 dll 哈希、text/pcm true、resource false、real_sample 证据。
- `engine-support.yaml` 新增 `cmvs` 条目（detection 七项均带 real_sample 证据；text luna_hook / audio directsound_pcm + loopback 均 implemented_unverified；三条 known_limitations），`docs/engine-support.md` 由生成器重生成。
- 测试：`tests/cmvs_adapter_test.cpp` 真临时目录四种布局（完整含 BOM+空行前缀 → 匹配；只 cfg / 后缀对魔数错 / 节名错 → 不匹配）+ 进程级为假；变异实测（魔数判据改恒真 → 用例 3 红，还原绿）。`fushi/test/mining/cmvs_pairing_test.dart` + fixture（生成器骨架，钉 unverified）。

## 验证记录（2026-09-04）

- `adapter_structure_test` 38 / `engine_support_manifest_test` 22 / `galhook_workflow_test` 6 / `evidence_contract_test` 16 / `assert_liveness_guard_test` 2 / `lookup_presenter_wiring_guard_test` 33 / `kirikiri_lookup_source_guard_test` 126 全 OK；`generate_engine_support --check` / `generate_luna_profiles --check` OK。
- `tools/build_distribution.ps1` exit 0（19:13）：`voice_hook_x86.zip` sha256 `276e2787dca29d29c1d7d4a5bacc6a0644b77e316df7a89ece440c25a75d4c44`、`voice_hook_x64.zip` `628cc8c8c055567b587ee588b146bf9878cb10d2fe04569922ee2fa7894dd185`；ctest x64 56/56、x86 56/56；`fushi_cmvs_adapter_test` 两架构直跑 ok。
- `flutter test test/mining/cmvs_pairing_test.dart --no-pub` 1/1（冷 worktree 首跑 native assets 失败，带小写 `http_proxy` 重跑即过）；`dart analyze` 该文件无问题。
- 真机门：**未跑**（用户全程在用桌面）。

## Proved / Not proved / Next gate

- **Proved**：样本静态身份完整；结构身份判据在合成布局上正确且 fail closed；骨架编译进两架构 helper 并进 CTest；manifest 通过证据门。
- **Not proved**：`process_found → helper_ready → ipc_ready → text_observed（EmbedCMVS 线程）→ pcm_observed（DirectSound）→ paired → card_e2e` 一个都没跑；CPZ6 语音资源层不存在。
- **Next gate**（桌面空闲时）：把本分支 helper 打进 worktree 构建（`tools/install_into_bundle.ps1`）→ `launch_fushi_iso2.ps1` 隔离实例 → 库内「添加游戏」指向 `cmvs64.exe`（原始路径；x86 版第二轮）→ 启动 → 探针核 `hooked=1`、adapter diagnostics 里 `cmvs probe=1 installed=1` → 工作台看文本线程列表有无 `EmbedCMVS` → 推进到有声句看「游戏资源音频/PCM」是否出 DirectSound 段。第一个不过的边界决定下一轮 native 改动；过了再做验收 2→7（查词传感器 CMVS 未做，预期停在验收 2）。

## 队列其余（本轮盘点更新）

- `manosaba_Ver1.0.3`：已从 4 卷 rar 解压到 `ceshi\manosaba_Ver1.0.3\`（7.0 GB；Unity IL2CPP：`GameAssembly.dll` + `manosaba_Data` + D3D12），走既有 `unity_il2cpp`，只需真机。
- ceshi 目录里还有交接队列没列的：`STEINS.GATE.REBOOT/`、`[150924][hibiki works] PRETTY×CATION2 …`（未盘点引擎）、`AngelBeats-1st-_TrialEdition_ver1.10.zip`。
- 其余同 classic-kag3 台账：アマカノ3（artemis_pfs x64）、Sakura Swim Club（Ren'Py 英文）、AngelBeats trial（Siglus）、昨日魔女（Unity 汉化）、ISO 类未挂载。

## 恢复指引

- worktree `D:\APP\vs_claude_code\hibiki\.claude\worktrees\gal-cmvs-chronoclock`，分支 `worktree-gal-cmvs-chronoclock`（基底 develop，可独立开 PR）。
- 脚本：`C:\Users\wrds\.claude\jobs\81491d86\tmp\{build_cmvs,guards_cmvs,mutate_cmvs}.sh`、身份脚本 `cc_identity.py`；真机驱动沿用 `C:\Users\wrds\.claude\jobs\a188f70d\tmp\launch_fushi_iso2.ps1` + `C:\Users\wrds\.claude\jobs\3f9f84ac\tmp\drive\galdrive.ps1`。
- 构建坑同前：bash 里 unset 小写代理再跑 `build_distribution.ps1`；`flutter test` 反过来要小写 `http_proxy` 才能下 native assets；`setup_worktree.ps1` 在 PowerShell 里要先把 `C:\Program Files\Git\bin` 加进 PATH（apply-patches 调 bash）。
