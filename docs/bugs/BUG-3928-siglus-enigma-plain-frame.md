## BUG-3928 · Rewrite+（Enigma 保护的 SiglusEngine）不识别引擎：内嵌查词要等 120 秒后才放行 Luna，且查词不可用
- **报告**：2026-10-31（用户：适配 Rewrite+ 时发现文本要等约两分钟才出现、内嵌查词不可用）
- **真实性**：✅ 真 bug。Rewrite+（SiglusEngine 1.1.101.0，x86，Enigma Protector）走的是 LunaScenario 家族，但两处结构判据把它挡在门外：
  1. `native/galgame_hook/hook/adapters/siglus_lookup.inc:349`（修复前）`luna_matched = key_iat != 0 && ...`：Enigma 的 API 模拟把导入表换成私有替身，镜像里没有 `user32!GetKeyState` 的导入名，`FindGetKeyStateImport` 恒为 0，家族直接判不匹配。
  2. `siglus_autoprofile.h` 的家族特征只覆盖「对齐栈帧」一代代码（SPRB 等）；Rewrite+ 编译出的是「普通栈帧」一代：剧情入口尾部、字符串 ABI、输入入口（`55 8B EC 51 …`）、主输入调用、按键轮询循环（`8B 1D slot … FF D3`）、左键消费点都不同，配置对象的设计尺寸也在 +0x64/+0x68 而非 +0x7c/+0x80，节头被合并成单个 `CODE|EXECUTE|READ` 节。
  家族判不出 → `IsSiglusLookupProfileMatched` 每 500 ms 重扫，直到 `siglus_lookup.inc:600` 的 120 秒上限才判 miss，这期间原生文本所有者一直 pending、LunaHook 不放行；之后也没有可用的查词档案。
- **[x] ① 根因修复** — `44e962369d`。按引擎结构而非标题/哈希扩展判据：
  - `siglus_autoprofile.h`：抽出 `ScenarioInputCodegen`，对齐栈帧 / 普通栈帧两代代码各一套完整特征（`AlignedFrameCodegen` / `PlainFrameCodegen`），两者必须恰好命中一个；新增 `ResolveSiglusFamilyProfileWithUnnamedKeySlot`，在镜像没有 `GetKeyState` 导入名时报出按键轮询循环读取的槽位 `get_key_state_slot_rva`，交给调用方做实时证明。
  - `siglus_lookup.h`：`SiglusInputEntryAbi` 与普通栈帧输入入口特征。
  - `siglus_viewport.h`：`ResolvePlainFrameConfigSlot`，要求渲染状态初始化与截图缓冲分配（被调函数内 `imul`×4）两处独立引用同一全局；保护壳合并节头后节属性不能证明「数据」，只要求可读，真伪由两处引用 + 实时读出合法设计尺寸证明。
  - `siglus_lookup.inc`：`VerifyProtectorKeyStateSlot`（槽值是已提交、可执行、`MEM_PRIVATE` 的替身，且 CapsLock / NumLock / ScrollLock 切换位与真 `GetKeyState` 一致）；`RedirectSiglusProtectorKeyStateSlot` 以 CAS 改写该槽指向共享的 `Detour_SiglusGetKeyState`，原值先发布；槽被他人改回时健康检查失败、撤销查词（失败关闭，不重新接管）；设计尺寸读取改为按家族给定偏移读。
- **[x] ② 自动化测试** — `native/galgame_hook/tests/siglus_autoprofile_test.cpp`（普通栈帧正向 / 组件各自移位 / 消费点歧义 / 未命名槽两代都报出槽位、命名路径拒绝 / 槽不可读拒绝 / 两代同时完整时拒绝）、`native/galgame_hook/tests/siglus_viewport_test.cpp`（`PlainFrameConfigSlot`：正向、合并节头仍可解析、两处引用槽不一致、分配缺失或越窗、调用出镜像、重复锚点、非法槽位、非 x86）。x86 / x64 CTest 全绿，`tools/run_guards.ps1` 全绿。
- **[x] ③ 原生文本接管（不再放行 LunaHook）** — `7c7d1cbc7b`。首轮真机发现：家族认出后文本所有者仍判给 Luna（普通栈帧没有消息档案），Luna 开出大量高频线程、要用户手选、选错会卡住界面；而原生消息捕获一旦安装，按 `siglus_voice_export.inc` 的门，没有资源映射证明就不做语音配对，所以文本与语音必须一起适配：
  - `siglus_message_profile.h`：`ResolvePlainFrameMessageProfile`（按 `input_entry_abi` 分派）。普通栈帧的消息入口**直接**调用剧情入口（没有对齐栈帧那一代的 surface 包装函数），要求入口内恰好一处直调、返回点落在完整 surface 片段的固定位置；语音入口 / 写回、prepare 两处 clear 调用同样按完整片段与调用边判定。新字段 `direct_scenario_call`。
  - `siglus_message_capture.h`：票据直调分支——剧情入口时 EBP 必须正是已武装消息入口自己的帧（`entry_esp-4`），返回地址必须是消息入口内的直调返回点；对齐与直调两种布局互斥、混用一律失败关闭。
  - `siglus_resource_mapping.h`：`ResolvePlainFrameResourceMappingProfile`。语音请求 / 播放 / 资源 / 格式化 / 归档打开 / 归档读取六个函数是普通栈帧专有的完整片段；构建器、拼接、CRT、WideAssign、Ogg 三件与对齐一代共用。资源帧布局不同：键副本 `-0x100`、路径 `-0x74`、读取器 `-0x110`，offset 在 EBX、length 只在帧局部 `-0xec`。保护壳合并节头后字面量与 vtable 位于可执行节，`WideLiteral` 只在这条路径上放宽节属性，身份由固定操作数位置 + 精确内容证明。
  - `siglus_voice_source.h`：`SiglusVoiceSourceLayout::length_frame_displacement`，非零时 offset 取 EBX、length 必须与帧局部一致。
- **[x] ④ 原生接管测试** — `tests/siglus_message_profile_test.cpp`（普通栈帧正向 / 组件移位 / 入口内第二处直调 / 直调目标不对 / surface 出界 / 剧情尾部变异 / 语音写回出界 / prepare 调用错 / 重复入口；对齐 ABI 下同一镜像不命中）、`tests/siglus_message_capture_test.cpp`（`TestDirectTicket`：直调帧正向、外来帧、返回地址、所有者变化、两种布局互斥）、`tests/siglus_resource_mapping_test.cpp`（`TestPlainFrame`：合并节头正向、全部调用边改向、归档函数片段变异、13 个字面量、kind=3 / 行成员 +8 / 步长 0x10 / length 局部、重复片段、两代互不接纳）、`tests/siglus_voice_source_test.cpp`（`TestPlainFrameSource`）。x86 143 / x64 139 项 CTest 全绿，`tools/run_guards.ps1` 全绿。离线镜像：Rewrite+ 消息入口 `0x2233e0`、直调返回 `0x2234eb`、语音 `0x222bd0`、资源 `0x1db9b0`、OggOpen `0x2b3800`、载荷返回 `0x1dc15e`；HF 全部不命中。真机未跑。
- **[x] ⑤ 原生线程自动选中、GDI 兜底让位** — 待提交。真机复测（2026-11-01）：原生接管生效（不再起 Luna，`SiglusEngine message` 正常出句），但仍弹「完成捕获设置」，且多一条 `GDI fallback`（存档界面日期的逐字重绘伪影）。根因两处，均为 Siglus 引擎级、对 anemoi 等同样生效：
  - `siglus_message_capture.inc` 写环时 hook code 传 `nullptr`，而消费端只自动选中 `ENGINE:` 前缀线程（`texthooker_service.dart` `isEngineExactTextThread`），原生消息线程因此永远要用户手选（anemoi 能直接显示靠的是之前记住的选择）。改为 `ENGINE:SIGLUS:message`。
  - GDI 兜底只在第一句原生台词写出后才让位（`luna_active` 置位在写环成功处），载入存档时的日期绘制早于第一句，于是被当成一条线程登记。改为原生消息钩子组安装成功即置位。
  - 测试：`tests/siglus_message_capture_test.cpp`（生产写环带 `ENGINE:SIGLUS:message`；安装成功置位、安装失败不置位）。x86 / x64 CTest 与守卫全绿。
  - 副作用：之前手选并记住过 Siglus 原生线程的游戏，记忆指纹按旧的线程名记录，换成 hook code 后对不上，会再弹一次选择框；选一次后重新记住。
- **备注**：离线用 Rewrite+ 内存镜像验证：家族 `abi=1`、槽位 RVA `0x5ed4bc`、配置槽 `0x6d3e30`（实测 1280×720）；HF（Rewrite Harvest festa!，1.0.17.19）为负样本，全部不命中。真机门（不再等 120 秒、内嵌查词、鼠标与触摸点击查词不推进）尚未跑，支持状态保持 `implemented_unverified`。HF 是另一种代码形态，需另行分析。
