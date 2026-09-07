# Siglus 引擎级适配阶段审查

## Scope

- 日期：2026-09-07。
- 实现 worktree：`D:\codehibiki\.worktrees\codex-siglus-engine-adapter`；基线 `ec7807328a6bd66830885cbb0812fd19770678d0`。
- 本轮仅处理 Windows Siglus，用户明确指定其为第一优先引擎。x86/x64 helper 均构建，但新结构识别限定 x86 ABI，不宣称存在 Siglus x64 引擎实现。
- 总体 16 引擎覆盖审计是独立提交 `53242297ad`，报告为 `docs/reviews/2026-09-07-galgame-engine-audit.md`。本报告只跟踪 Siglus 阶段，不表示其他引擎已经适配完成。
- 规则依据：根 `CLAUDE.md`、`native/galgame_hook/CLAUDE.md`、`docs/agent/galgame-hooking.md`、`docs/agent/review-process.md`。
- 本报告仅保存身份、计数、结构和验证元数据，不收录游戏台词、截图或游戏载荷。

## Proved：代码路径与离线验证

### 从样本白名单到两套 ABI 的结构证明

旧入口先按 Anemoi 和 Summer Pockets Reflection Blue 的 SHA/RVA profile 匹配，未知 hash 即使结构兼容也进不了 lookup 安装。当前实现分别解析 `LunaScenario` 与 `NativeEcxTextUnion` 两套 x86 ABI：每套独立查找 glyph/text/input 入口及调用关系，只有恰好一套完整证明成立才接受；两套同时匹配、两套都失败或部分结果拼不成完整契约均拒绝。

已知 hash 仅用于核对结构解析所得 anchors 是否和既有测量一致，不再直接选中生产 profile。不能以改 exe 文件名或补 hash 条目代替结构准入。

相关源码：

- `native/galgame_hook/hook/adapters/siglus_autoprofile.h`：LunaScenario 签名、函数边界、调用关系和文本/字形 ABI。
- `native/galgame_hook/hook/adapters/siglus_native_autoprofile.h`：NativeEcxTextUnion 独立结构、字符串复制、glyph writer 和键输入关系。
- `native/galgame_hook/hook/adapters/siglus_lookup.inc`：`ResolveSiglusLiveFamily`、`SameSiglusMeasuredAnchors`、`IsSiglusLookupProfileMatched` 生产接线。

NativeEcxTextUnion 不依赖保护壳是否保留 USER32 import descriptor：从独立键循环解析 sampled-key slot，再将 slot 实际内容和当前进程具名 `user32!GetKeyState` 导出精确比较。LunaScenario 使用自己的具名 import 校验。两个 ABI 不能互借部分 anchors。

### 从固定 1920×1080 到实际 Gameexe 设计尺寸

两套 ABI 分别通过 renderer 初始化路径和窗口归一化路径交叉确定同一个 Gameexe 配置指针槽。读取该对象 `+0x7c/+0x80` 的设计宽高，并验证范围、指针可读性和所属 section。生产 profile 发布后保持不变；安装/健康轮次重新读取设计尺寸，尺寸无效或改变时撤销 sensor/输入盾，并由 worker 退役 provider、关闭命中输入和清除点击目标，而不是继续套用旧坐标。

相关源码：`siglus_viewport.h`、`siglus_native_viewport.h`，以及 `siglus_lookup.inc` 的 `ReadSiglusDesignSize`、`InstallSiglusLookupSensor`、`ProcessSiglusLookupTick`。窗口客户区尺寸与 Gameexe 设计尺寸是两个坐标域，不能混为一个常量。

### 保护壳 loaded-image 边界

原版 Anemoi 的运行期失败路径暴露出另一条边界：某些节的 on-disk raw 载荷尺寸大于实际加载映像；按 `max(SizeOfRawData, VirtualSize)` 构造扫描范围会在进入结构扫描前拒绝。

当前通过 `siglus_image.h` 的 `OpenSiglusLoadedImage` 显式选择 VirtualSize 范围策略，保留完整映像 bounds、可执行节可读性和 section 重叠拒绝；不截短坏范围，不改变其他 adapter 的默认策略。VirtualSize 为零的节仅使用通过 bounds 检查的 raw extent。该变化是 Siglus 的 loaded-image 解释，不是允许扫描映像外内存。

### pending 必须由 worker 推进

lookup identity 使用 unknown/pending/matched/final-rejected 状态；扫描持有者与等待者区分，`0/2` 都按 pending 处理。pending 时通用输入盾继续预留 GetKeyState，旧文本 locator 不得抢先修改待解析入口。

`SiglusAdapter::InstallText` 记录 `text_pending_`；`ProcessPendingEvents` 在 worker 上继续推进，不依赖用户是否打开 lookup。成功后文本 Hook 使用已解析入口；最终拒绝才允许已有 text-only fallback，且不会因此发布 geometry。相关接线在 `native/galgame_hook/hook/adapter_registry.inc`、`generic_input_shield.inc` 和 `adapters/text_render_adapter.inc`。

## Findings 与拒绝边界

| 编号 | severity / status | 根因或边界 | 处置与验证 |
|---|---|---|---|
| HBK-AUDIT-SIGLUS-001 | 高 / 已实现，运行时验收未完成 | 旧 hash/RVA 硬门阻断兼容 build | 两套独立结构解析，已知 hash 仅一致性校验；双匹配拒绝 |
| HBK-AUDIT-SIGLUS-002 | 高 / 已实现，完整 UI 验收未完成 | 保护壳 raw extent 不能代表 loaded-image 范围 | Siglus 显式选择 VirtualSize，完整 bounds/readability/overlap 检查 |
| HBK-AUDIT-SIGLUS-003 | 中 / 已实现，真实生命周期仍需验证 | startup pending 后文本安装未必再次推进 | worker 继续 `text_pending_`；pending 不抢 patch；成功或最终拒绝后完成文本安装尝试 |
| HBK-AUDIT-SIGLUS-004 | 中 / 已实现，尺寸切换运行时未证明 | 固定设计尺寸无法代表不同兼容 build | 两链解析 Gameexe；无效或变化时撤销，不修改已发布 profile |
| HBK-AUDIT-SIGLUS-005 | 高 / 用户报告 SPRB 输入屏蔽/风险握手阻塞，待定位 | 最终 Anemoi 有命中与词典；SPRB 用户报告必须确认风险才能推进下一句，现有 hit 计数不能证明可用 | 用户不接受手动确认风险作为解决方案；先同步最新上游再沿真实输入屏蔽/风险握手定位。Anemoi 受焦点干扰的关闭检查仍未证明 |

负向验证包括：缺失/重复签名、全可执行节范围的第二候选、错误调用目标、错误栈清理/对象偏移、跨 ABI 误匹配、非 x86 架构、错误键 slot/真实导出不符、两条 Gameexe 链指向不同槽、数据节里的伪签名、无效设计尺寸、越界/重叠/不可读的 loaded section。未知 hash 的正向证明仍须满足完整 ABI 结构；测试不能用 fixture expected 反向构造生产准入结果。

新增定向测试文件：

- `native/galgame_hook/tests/siglus_autoprofile_test.cpp`
- `native/galgame_hook/tests/siglus_native_autoprofile_test.cpp`
- `native/galgame_hook/tests/siglus_viewport_test.cpp`
- `native/galgame_hook/tests/siglus_native_viewport_test.cpp`
- `native/galgame_hook/tests/siglus_loaded_image_test.cpp`

现有 `siglus_lookup_test.cpp` 与 `adapter_structure_test.py` 增加 pending、生产双 resolver、哈希不直通、动态尺寸撤销和 worker 推进守卫。源码守卫不能替代真实输入行为验证。

## 验证记录

以下构建与完整 native 测试结果由本轮集成主代理提供；报告编写子任务没有重新执行构建，避免与正在进行的真机验收竞争。

| 检查 | 本轮结果 | 能证明的范围 |
|---|---|---|
| Windows x86 完整构建 | 通过，退出 0 | x86 编译与链接 |
| Windows x64 完整构建 | 通过，退出 0 | x64 helper 编译与链接及未支持 ABI 的平台边界 |
| x86 CTest | 67/67 通过，退出 0 | 当前离线 native 测试集合 |
| x64 CTest | 67/67 通过，退出 0 | 同上，不代表 Siglus x64 runtime 支持 |
| manifest | 23 项通过，退出 0 | 支持状态、冻结声明与生成文档契约 |
| adapter structure | 39 项通过，退出 0 | 生产接线与结构守卫 |
| workflow | 6 项通过，退出 0 | 工具工作流契约 |
| replay | 通过，退出 0 | 本轮离线 replay 路径；不代替真实音频/配对/制卡 |

metadata 子任务另已执行 `python tools/generate_engine_support.py`、`--check`、23 项 manifest 测试与两文件 `git diff --check`，均退出 0。`engine-support.yaml` 的 text/lookup 能力仍是 `implemented_unverified`；历史 audio、verified_games、冻结 claim、legacy limitations 前三项与 allowlist hashes 未变。

## 原版样本身份与 prototype 阶段

| 样本 | 身份 | 本报告允许引用的范围 |
|---|---|---|
| Anemoi 正式版 | x86；SiglusEngine `1.1.141.3`；原始路径 `D:\anemoi\anemoi (正式版)\SiglusEngine.exe`；SHA-256 `D94C94EB132FB1FCD6C20F35DD16552ED1301708B7A83DE07B275AD26C97D059` | 本轮原始路径、prototype 与最终宿主会话元数据 |
| Summer Pockets Reflection Blue 原版 | x86；SiglusEngine `1.1.134.0`；原始路径 `D:\sprb\Summer Pockets Reflection Blue\SiglusEngine.exe`；SHA-256 `190DF9A72929BD6B6327E773952B5C507C69052BC6D3FF16A4868BD1FF1791FD` | 身份取自现有 profile 与本轮 process.json；最终宿主会话有 hit，尚无主代理可见词典佐证 |

用户明确排除两份 SPRB 汉化版本：它们不进入本轮测试、运行证据或支持结论。本文不引用任何中文改版结果。

历史 prototype 会话为 Anemoi PID `18980`、`prototypev2`：`text_writes=1`，采集文本与当时可见日语台词一致；本文不保存该文本。lookup diag 为 `0xFFC00003`，主代理提供的符号化结论包括 profile/sensor/glyph/key 和 geometry 已观察。该十六进制值不由本报告手拆，也不当作一个“整体成功”标志。最终宿主会话结果见下节，不能把历史 prototype 的未准入状态写成当前状态。

同一 prototype 的 `geometry provider=0/0`、`hit=0`；当时 host shield 尚未接入。因而仅能记录已发生的传感器、文本与几何观察，不能写成 provider 已就绪、输入可用、词典已显示或制卡已通过。应分别保留以下边界：

- 文本观察：本轮 prototype 有正向元数据。
- sensor/glyph/key/geometry 观察：主代理已符号化报告。
- provider 准入、host shield 和 hit：prototype 尚未通过。
- 本轮音频捕获、逐句配对与真卡写入：没有同会话 E2E 证明，不从历史音频支持外推。

## Final runtime：已观察事实与当前限制

本节事实由集成主代理在最终 DLL 与 Fushi 宿主会话中提供。process 身份文件只读保存在主 checkout 的 `.codex-test/siglus-engine-adapter/`；未将台词、截图或游戏载荷加入本文。

| 组件 | 最终身份 |
|---|---|
| x86 hook DLL SHA-256 | `23872E06C4369D63F668FCD038241DB87162036272109F6FD77B6A76694EE94E` |
| x86 helper SHA-256 | `C19796C6B455F7A5E7ECAD54C47C7AB6D7FA456B1F5C9C0C7396CDF4D1C74D7C` |
| 实际 Fushi runtime 缓存目录 | `C:\Users\Wight\AppData\Roaming\Fushi\Fushi\voice_hook_runtime\904db39a82ae1136\x86\` |

Anemoi 最终会话：游戏 PID `42500`，父 PID `71688`，启动时间 `2026-09-07 12:24:52.282596 +08:00`；Fushi host PID `30868`，helper PID `22908`；选定正文线程 ID `10635026222130768`。首次点击游戏原文后出现 `hit=1`、provider kind/id=`2/3`，主代理实际看到词典显示，文本计数保持 `1`。这一记录证明该会话已经越过宿主 provider 准入并完成一次点击命中与词典呈现；不能外推为完整关闭/制卡 E2E。

Anemoi 随后的关闭检查使用了 game window 与 related popup 截图流程，受到 sky 自动焦点切换干扰，文本计数变为 `2`。该操作不能隔离用户关闭词典与自动化前台切换的影响，因此**不能判断真实关闭通过或失败**。只读代码路径显示前台切换可能触发 hide，这只是候选解释，尚未证明是本次现象的原因；不能据此归因或宣称修复。

原版 SPRB 最终会话：游戏 PID `21400`，父 PID `70876`，启动时间 `2026-09-07 12:33:51.267647 +08:00`，路径取自 `.codex-test/siglus-engine-adapter/sprb-host-final/process.json`。该会话由宿主附着同一最终 DLL；用户正在实际操作，并选择正文线程 ID `2763381163615380983`，线程名 `SiglusEngine3`，该线程包含 speaker。主代理提供的 `12:35` 快照记录 provider kind/id=`2/3`、`hit=8`、ready 字段 `0xE4`、fault=`0`。这些计数只记录为原始观测字段，不凭掩码升级证据；目前尚无主代理可见词典的独立佐证，不写成 SPRB 查词呈现或关闭已验证。本文不引用具体文本或不确定的 glyph 数量。

Anemoi evidence 台账的 verify 退出 `2`，当前缺准确注入 timestamp。已观察的命中/词典呈现不能填补时序证据缺项，台账不能视为 release-eligible；text/lookup 仍保持 `implemented_unverified`，不提升任何能力状态。

随后用户反馈：**SPRB 必须点击确认风险才能推进下一句**，要求先拉取上游代码继续开发，不接受手动确认风险。当前首个失败边界为输入屏蔽/风险握手，先前 hit 不代表可用。已 fetch 两个 remote，确认 `upstream/develop` 包含去除风险门的 `f7277a3fe3` 和残留清理 `562e29061d`；当前基线尚不包含它们。下一步先保存本轮快照，再合入 upstream/develop；此处不预告合并或修复完成。

## Not proved

尚未证明 Anemoi 在无截图/焦点干扰条件下关闭词典时正确吞掉对应 down/up 并恢复游戏输入；SPRB 有有效 hit 计数，但尚缺主代理可见词典佐证，且最新用户反馈指出实际推进台词受风险确认阻塞。上述数据没有证明两套 ABI 的输入行为可用，更没有证明任意 build、尺寸切换或输入事务序列都正确。

本轮仍无“当前文本 → 对应音频 → 画面 → 真卡写入”的同会话 E2E，音频、paired、card 不从历史支持或本轮文字命中外推。准确注入 timestamp 缺项仍须补证，不能通过调整 evidence gate 或 allowlist 绕过。

兼容范围仍由两套已识别的 x86 ABI 结构决定，不覆盖任意 Siglus 版本、保护壳、UI 自定义或 x64 引擎。最终 DLL 的部分运行时事实也不等于引擎支持升级。

## Next gate / Next Scope

当前第一个未通过边界是 **SPRB 输入屏蔽/风险握手**。按用户要求保存阶段快照后同步 upstream/develop，整合已有的风险门移除，再沿原版路径验证不需确认风险即可正常推进剧情及查词。

Anemoi 关闭事务保留为未证明的后续验证项，不再将“等待用户确认风险/自行绕过”作为当前推进方案。本阶段交接完成后文件交由集成主代理接管，后续同步、修复与验证结果由其追加。音频、配对、制卡和引擎支持升级仍不在已通过结论内。
