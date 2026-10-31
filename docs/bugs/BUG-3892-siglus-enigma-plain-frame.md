## BUG-3892 · Rewrite+（Enigma 保护的 SiglusEngine）不识别引擎：内嵌查词要等 120 秒后才放行 Luna，且查词不可用
- **报告**：2026-10-31（用户：适配 Rewrite+ 时发现文本要等约两分钟才出现、内嵌查词不可用）
- **真实性**：✅ 真 bug。Rewrite+（SiglusEngine 1.1.101.0，x86，Enigma Protector）走的是 LunaScenario 家族，但两处结构判据把它挡在门外：
  1. `native/galgame_hook/hook/adapters/siglus_lookup.inc:349`（修复前）`luna_matched = key_iat != 0 && ...`：Enigma 的 API 模拟把导入表换成私有替身，镜像里没有 `user32!GetKeyState` 的导入名，`FindGetKeyStateImport` 恒为 0，家族直接判不匹配。
  2. `siglus_autoprofile.h` 的家族特征只覆盖「对齐栈帧」一代代码（SPRB 等）；Rewrite+ 编译出的是「普通栈帧」一代：剧情入口尾部、字符串 ABI、输入入口（`55 8B EC 51 …`）、主输入调用、按键轮询循环（`8B 1D slot … FF D3`）、左键消费点都不同，配置对象的设计尺寸也在 +0x64/+0x68 而非 +0x7c/+0x80，节头被合并成单个 `CODE|EXECUTE|READ` 节。
  家族判不出 → `IsSiglusLookupProfileMatched` 每 500 ms 重扫，直到 `siglus_lookup.inc:600` 的 120 秒上限才判 miss，这期间原生文本所有者一直 pending、LunaHook 不放行；之后也没有可用的查词档案。
- **[x] ① 根因修复** — 未提交（待提交后补哈希）。按引擎结构而非标题/哈希扩展判据：
  - `siglus_autoprofile.h`：抽出 `ScenarioInputCodegen`，对齐栈帧 / 普通栈帧两代代码各一套完整特征（`AlignedFrameCodegen` / `PlainFrameCodegen`），两者必须恰好命中一个；新增 `ResolveSiglusFamilyProfileWithUnnamedKeySlot`，在镜像没有 `GetKeyState` 导入名时报出按键轮询循环读取的槽位 `get_key_state_slot_rva`，交给调用方做实时证明。
  - `siglus_lookup.h`：`SiglusInputEntryAbi` 与普通栈帧输入入口特征。
  - `siglus_viewport.h`：`ResolvePlainFrameConfigSlot`，要求渲染状态初始化与截图缓冲分配（被调函数内 `imul`×4）两处独立引用同一全局；保护壳合并节头后节属性不能证明「数据」，只要求可读，真伪由两处引用 + 实时读出合法设计尺寸证明。
  - `siglus_lookup.inc`：`VerifyProtectorKeyStateSlot`（槽值是已提交、可执行、`MEM_PRIVATE` 的替身，且 CapsLock / NumLock / ScrollLock 切换位与真 `GetKeyState` 一致）；`RedirectSiglusProtectorKeyStateSlot` 以 CAS 改写该槽指向共享的 `Detour_SiglusGetKeyState`，原值先发布；槽被他人改回时健康检查失败、撤销查词（失败关闭，不重新接管）；设计尺寸读取改为按家族给定偏移读。
- **[x] ② 自动化测试** — `native/galgame_hook/tests/siglus_autoprofile_test.cpp`（普通栈帧正向 / 组件各自移位 / 消费点歧义 / 未命名槽两代都报出槽位、命名路径拒绝 / 槽不可读拒绝 / 两代同时完整时拒绝）、`native/galgame_hook/tests/siglus_viewport_test.cpp`（`PlainFrameConfigSlot`：正向、合并节头仍可解析、两处引用槽不一致、分配缺失或越窗、调用出镜像、重复锚点、非法槽位、非 x86）。x86 / x64 CTest 全绿，`tools/run_guards.ps1` 全绿。
- **备注**：离线用 Rewrite+ 内存镜像验证：家族 `abi=1`、槽位 RVA `0x5ed4bc`、配置槽 `0x6d3e30`（实测 1280×720）；HF（Rewrite Harvest festa!，1.0.17.19）为负样本，全部不命中。真机门（不再等 120 秒、内嵌查词、鼠标与触摸点击查词不推进）尚未跑，支持状态保持 `implemented_unverified`。HF 是另一种代码形态，需另行分析。
