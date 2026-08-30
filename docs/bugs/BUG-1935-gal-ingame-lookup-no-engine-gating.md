## BUG-1935 · 内嵌查词在 Siglus/白2 上 hash 钉定不中时静默失效且无任何提示

- **报告**：2026-08-29（用户：附加不行、要用 Fushi 启动才行；但 Siglus 用 Fushi 启动也不行，白色相簿2 也不行，换启动模式也不行。追问「PR #1030 这个没做吗」）
- **真实性**：✅ 真 bug（诊断/回显缺失）。功能**已实现**（PR #1030，2026-08-28 合并，merge `4e0fdbf0fc`），用户现象由两层原因叠加造成，两层都与启动模式无关。

  ### 第一层：用户手上的版本里根本没有这个功能

  | 发布 | 时间 | 基底 |
  |---|---|---|
  | `v2.2.1-beta.12447`（最新 beta） | 2026-08-26 09:10Z | develop @ `ec43136` |
  | `v2.1.1`（最新正式版） | 2026-08-15 | — |
  | `fushi-debug-rolling` | 停在 2026-08-10 | develop @ `e880296` |
  | **PR #1030 合并** | **2026-08-28 11:40Z** | — |

  铁证：`git ls-tree ec43136 native/galgame_hook/hook/adapters/siglus_lookup.inc` **无输出**——最新 beta 的基底里连该文件都不存在。**GitHub 上没有任何一个已发布包含 #1030**。用户在旧包上测 Siglus/白2 内嵌查词，必然什么都不发生；同一个包里 KiriKiri 查词是有的（早就合入），这与用户「KiriKiri 那套经验（必须 Fushi 启动、附加不行）成立，换到 Siglus 就全不行」的描述完全自洽。

  ### 第二层：即使更新，也只认 3 个精确 exe SHA-256，其余 fail closed

  PR #1030 自述：「Siglus remains a fail-closed profile registry」「A different or patched executable fails closed」。

  | 引擎 | 白名单 exe（SHA-256） | 位置 |
  |---|---|---|
  | Siglus | anemoi 正式版 SiglusEngine **1.1.141.3** x86 `D94C94EB…C97D059`（另接受其 Enigma 虚拟化 `.org` 自读视图 `28FD4B91…CC59A486`） | `native/galgame_hook/hook/adapters/siglus_lookup.h:50` |
  | Siglus | Summer Pockets Reflection Blue SiglusEngine **1.1.134.0** x86 `190DF9A7…FF1791FD` | `native/galgame_hook/hook/adapters/siglus_lookup.h:71` |
  | Leaf/AQUAPLUS（白2） | 唯一一个实测 WA2 x86 exe `005E7110…C17409ED` | `native/galgame_hook/hook/adapters/leaf_aquaplus_profile.h:47-49` |

  - 命中判据**只看 exe 的 SHA-256**，文件名/目录/pak 一律不参与（`leaf_aquaplus_adapter.inc:439-463`；profile 头注释 `leaf_aquaplus_profile.h:18-20` 明说 `WA2.exe` 这个名字不足以准入）。
  - 不中即在 `ProcessSiglusLookupTick()`（`siglus_lookup.inc:1220-1234`）/ `ProcessLeafAquaplusLookupTick()`（`leaf_aquaplus_adapter.inc:2655`）的头几个 `if` 直接 return，**全程零日志、零 UI 提示**。
  - hash 门在**注入完成之后**才求值 → 这解释了「换启动模式也不行」：`--launch` / `--pid` 只影响注入时机，对准入判定没有任何影响。
  - 除 hash 外还有一长串 AND 门：x86 编译期门（`siglus_lookup.inc:7`、`leaf_aquaplus_adapter.inc:2442`）、`lookup_enabled != 0`、字节签名校验（51 字节 opcode）、`user32!GetKeyState` / `GetAsyncKeyState` hook、白2 侧还要 D3D9 设备指针非空 + vtable 槽 17/65/83 全 hook 成功（`leaf_aquaplus_adapter.inc:2479-2500`）。任一失败同样静默。
  - **游戏更新/打补丁会直接失效**：`engine-support.yaml:1898-1905` 自述「A game update or different executable hash disables the selected text, geometry and sampled-input offsets until that build is measured independently」。

  ### 可落地的 bug：整条链没有任何用户可见的失败回显

  - `AdapterCapability`（`native/galgame_hook/hook/adapter.h:7-12`）只有 `kNone/kText/kResourceAudio/kPcmAudio`，**没有 lookup 位**；`SiglusAdapter::capabilities()`（`adapter_registry.inc:76-80`）与 `LeafAquaplusAdapter::capabilities()`（`leaf_aquaplus_adapter.inc:2767-2771`）都不表达查词能力。
  - Siglus 侧补了 4 个 admission 分型位（`include/voice_hook_ipc.h:591-594`），**但 Leaf 侧没有对应 admission 位**（只往 `FushiLeafD3DTraceV1.reserved` 写私有 bitmask，不写 `lookup_diag`）。
  - `lookup_diag` / `lookup_hit_count` 在 `fushi/lib/**/*.dart` **零命中**——Dart 根本不读诊断，UI 无从显示。
  - 设置开关 `game.ingame_lookup` 只有 `Platform.isWindows` 门，**无引擎/能力门控**（`fushi/lib/src/settings/settings_schema_game.dart:88`），pref 默认 **true**（`fushi/lib/src/models/preferences_repository.dart:2051`，注释还停在「KiriKiri in-game lookup」）。
  - 一致性缺陷：`SiglusAdapter::diagnostics()` 上报 `hook_diagnostics`，`LeafAquaplusAdapter::diagnostics()` 上报 `lookup_diag`（`leaf_aquaplus_adapter.inc:2796-2799`）——同一个 `AdapterDiagnostics::flags` 字段两边语义不同。

  **结论**：用户看到的「怎么都不行」是「版本没到 + hash 不中」两层静默失败叠加，产品把这两种情况都呈现成了「坏了」。

- **[x] ① 已修复（静默失效这条）** — 把「查词准入结论」建模成协议里的一等状态，全链路回显。
  - **v19 契约**：`SharedHeader` 尾部纯追加 `lookup_admission` / `lookup_admission_seq` / `lookup_executable_sha256`，`kSharedVersion` 18→19（`native/galgame_hook/include/voice_hook_ipc.h`）。用**单值枚举** `LookupAdmissionState`（Unknown / EngineUnsupported / IdentityRejected / IdentityAccepted / SensorInstalled）而不是再加 `lookup_diag` 位：后者是粘滞累积的诊断位（"曾经发生过"）且 32 位已用满，而准入是状态机的当前状态——用位能表达出「既 IdentityRejected 又 SensorInstalled」这种不存在的状态，读侧只能按一个没人维护的优先级去猜。
  - **能力位**：`AdapterCapability` 加 `kIngameLookup`；`EngineAdapter::lookupAdmission()` 默认返回 `EngineUnsupported`，所以 **12 个不带传感器的 adapter 一行都没改**。声明能力，而不是让每个 adapter 逐个否认。
  - **单点汇总**：`AdapterRegistry::PublishLookupAdmissionSummary()` 取 probe 命中者中的最高进展，跨进程只有一个写者。`generic_audio` / `text_render` / `loopback` 的 `probe()` 恒真（横切能力，不声称引擎身份），排除在外——否则任何游戏在引擎识别成立前都会先被误判成不支持，开关先灰后亮。
  - **Unknown 不是终态**：Leaf/SGRE 的 `probe()` 本身就是精确 exe hash 门，「白2 的另一个发行版」没有任何 adapter 会认领，状态会永远停在 Unknown（界面上就是永远"正在判定"）。模块表扫完仍无人认领即收敛为不支持/未识别。
  - **host 回显**：runner 读准入并经既有 `gal_hook_text` 通道推事件；准入被挡住且注入侧没填摘要时，host 自己按 pid 缓存地算游戏 exe 的 SHA-256（`fushi/windows/runner/voice_hook_reader.cpp`）。设置页显示原因 + 一行可复制的 exe 摘要（`fushi/lib/src/settings/settings_schema_game.dart`）。
  - **开关不置灰**：能力信息只进副标题。开关是全局偏好（用户意图），准入是当前会话能力，两者正交；默认值为 true，置灰只会造出"引擎不支持时反而关不掉"的死状态。
- **[x] ② 已加自动化测试** —
  - native：`tests/lookup_ipc_contract_test.cpp` 新增 v19 纯追加形状守卫（含 4 字节对齐断言——防有人把 `pack(8)` 改成 `pack(1)` 后 Interlocked 落在未对齐地址上静默撕裂）、准入往返 / 幂等不推进 seq / 未知状态值落回 Unknown / 无 NUL 摘要有界读、摘要十六进制格式化；`tests/native_loopback_policy_test.cpp` 的尾部形状守卫按 v19 更新。
  - Dart：`fushi/test/lookup/gal_ingame_lookup_contract_test.dart` 6 条（逐字段解码、线上值逐值对应、未知值回落、只有 engineUnsupported/identityRejected 挡住查词且用 `values.length == 5` 逼新状态显式表态、会话换代复位、同内容不重复通知）；`fushi/test/tools/voice_hook_ipc_contract_test.dart` 加 v19 守卫。
  - 实跑结论：x86+x64 hook DLL 构建通过；native CTest 18/18；Python 结构守卫 8/8；`flutter analyze` No issues found；`FLUTTER TEST VERDICT: PASSED - 1396 tests ran`（test/lookup test/settings test/i18n test/tools）。
- **[ ] ③ 仍未做（不属本 bug，另开任务）** — 让**用户这台机器上的游戏**真的能查词，取决于他的 exe 是否进白名单：
  1. **发一个含 PR #1030 + 本次改动的构建**，否则用户无从验证（当前已发布包最新是 08-26 的 beta，早于 #1030）。
  2. 用户按新 UI 复制出 exe 的 SHA-256 报回来后，才谈得上为那个版本测 RVA、加 profile。
  3. **文档**：`docs/agent/galgame-hooking.md` 全文 `lookup|查词` 仍零命中，适用范围（KiriKiri Z 带 textrender.dll / Ren'Py / SGRE 单游戏 / Siglus 2 个 exe / WA2 1 个 exe）没有记载，同类误判会反复发生。
- **备注**：
  - **本单第一版结论全错，已整体重写**。首版在**落后于 origin/develop 的主 checkout 工作区**上 grep，得出「Siglus 从来没有查词传感器」「`LookupHitSlot` 只有 3 处」「白2 就是 SiglusEngine」等结论，全部作废。当前树实际有 **5 处**写 `LookupHitSlot`（`kirikiri_adapter.inc:5318` / `renpy_lookup.inc:603` / `sgre_lookup.inc:924` / `siglus_lookup.inc:1159` / `leaf_aquaplus_adapter.inc:2571`）。教训：调查前必须 `git fetch` 并对 `origin/develop` 取证。
  - **订正**：白色相簿2 **不是** SiglusEngine，而是独立引擎 `leaf_aquaplus`（`engine-support.yaml:1771-1782`，Leaf/AQUAPLUS 自研 Windows runtime，`d3d9.dll`/`dsound.dll`/`*.pak`），与 Siglus（`Gameexe.dat`/`Scene.pck`/`koe/*.ovk`）判据不相交，两个 adapter 不存在互抢（`adapter_registry.inc:515-562` 顺序调用全部 adapter，无 else/break/独占）。
  - #1030 自述 `implemented_unverified`：「no tests were run for this submission, per user request」「the full test suite was not run」；白2 的 late attach 亦为 `implemented_unverified`，被接受的路径用的是 suspended launch（`engine-support.yaml:1852-1861`）。Siglus 侧 injector 有专门规避：`CREATE_SUSPENDED` 早注入会触发 Enigma Internal Protection Error，故改为「启动后等游戏窗口再延迟附着」（`injector_main.cpp:2006-2011`、`:2409-2420`）。
