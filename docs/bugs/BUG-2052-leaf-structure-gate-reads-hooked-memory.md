## BUG-2052 · 白2 身份结构门扫的是被 LunaHook 改写过的进程内存，导致点击穿透+语音降级
- **报告**：2026-09-03（用户：点击还是会穿透点到下一句 / 白色相簿好像有问题音频都降级了）
- **真实性**：✅ 真 bug，根因 `native/galgame_hook/hook/adapters/leaf_aquaplus_adapter.inc`
  的 `IsLeafAquaplusProfileMatched()` 二进制结构校验读 `GetModuleHandleW(nullptr)` 的**进程内存**
- **[x] ① 已修复** — 结构校验改读磁盘上的原始映像（`LOAD_LIBRARY_AS_IMAGE_RESOURCE`，按节对齐、
  不执行代码、不施加重定位），并给 `LoadedPeImage` 增加 `absolute_base` 让绝对 VA 操作数按首选
  基址解码。提交见文末。
- **[x] ② 已加自动化测试** —
  `native/galgame_hook/tests/adapter_structure_test.py::test_leaf_structure_gate_reads_the_pristine_file_not_process_memory`
  （源码扫描守卫，两处变异各自验证：① 改回读 `module` ② 让 `absolute_base` 渗回 `AddressToRva`，都会报错）

### 现象

同一台机器、同一份 WA2.exe、同一条启动路径：

- 游戏内查词点击**穿透到游戏**，直接翻到下一句，查词卡不出；
- 语音整场降级到系统 Loopback；
- 且**时好时坏**——有的会话两样都正常。

### 根因

`IsLeafAquaplusProfileMatched()` 的第二层（二进制结构校验）在**进程内存**里扫五处唯一掩码模式：
`text_traversal` / `raster_draw` / `input_poller` / `embed_loop` / `d3d9_device`。

其中 `embed_leaf_hook_rva = 0x0512bf` 的 profile 注释就写着 `selected HSX0:0 hook at
VA 0x004512bf` —— **那正是我们自己指定给 LunaHook 打文本 hook 的地址**。Luna 的 detour 一落下，
那段字节就不再匹配掩码模式，`FindUniquePatternInExecutableSections` 命中数变 0：

```
structure_matched = ... && embed.count == 1u && ...   // 恒假
```

于是 `probe()` 恒假 → 准入汇总里没有任何 adapter 认领 → 收敛成 `EngineUnsupported`；
`install()` 里 `InstallLeafAquaplusD3DTrace()`（几何 provider）、`InstallLeafSampledInputShield()`
（`GetAsyncKeyState` 护盾）、`TryHookLeafAquaplusResourceAudio()`（LAC 原声）第一道门就全部返回 false。
**点击穿透**和**语音降级**是同一个根因的两个表现。

时好时坏的原因是竞态：Luna 的 H-code hook 在它**观测到第一句输出**时才装上，而结构门只跑一次
（`g_leaf_exact_binary_structure_state` 永久缓存）。谁先谁后决定整场会话的命运。

`text_traversal_rva` / `raster_draw_rva` 更是 `InstallLeafAquaplusD3DTrace()` 里**我们自己**要 hook
的地址，今天只因结果被永久缓存、不会重扫，才没暴露同一个问题。

### 实机证据

带 BUG-2051 修复的 DLL（`hook_module_sha256=5f543760…`）会话 pid 28828：

```
exe_sha256=005e7110…09ed        ← 与 profile 钉定值一致
lookup_admission=1              ← EngineUnsupported
xaudio2=0x000020CC              ← LeafIdentityHashMatched + LeafStructureRejected
                                   + LeafEmbedAnchorMissed（**只有 embed 这一组**）
hook_diagnostics=0x00001C01     ← 含 kDiagLunaOutputObserved（Luna 的 hook 已装上）
geometry=0/0 status=0  hits=0   ← 几何 provider 从未上线
```

独立佐证：实机 `ReadProcessMemory` 与磁盘逐字节比对 6 个锚点，**只有 embed_loop @0x0512BF 不一致**。
而更早那两个语音正常的会话（21356/26604）`kDiagLunaOutputObserved` **未**置位、embed 字节与磁盘一致
——Luna 还没来得及打 hook，结构门就过了。两条证据互相独立，指向同一结论。

### 修复

身份是「这个 exe 是不是那份被测量过的构建」——那是**文件**的属性，不是当前进程内存的属性。
结构校验因此改为映射磁盘上的那一份来扫。

`LOAD_LIBRARY_AS_IMAGE_RESOURCE` 明确不施加重定位，所以绝对 VA 操作数仍编码首选基址，而读字节
要用映射地址：两者必须分开。为此 `LoadedPeImage` 增加 `absolute_base`，且**只**作用于
`DecodeAbsolute32ImageAddress`。

> ⚠️ 这一点踩过：最初把 `absolute_base` 直接塞进共享的 `AddressToRva`，结果 4 个
> `MatchesRel32CallEndingAt` 整片假失败——rel32 算出来的是映射内地址，必须按 `image.base` 换算。
> 离线校验器在改动进真机之前就抓到了这个。

离线用仓库真实 helper 对用户这份 WA2.exe 复跑整条结构门：**failures=0**（18 项 section 角色 +
5 个唯一模式（RVA 与绝对操作数逐位相同）+ 9 个 call return site）。

- **备注**：本条只恢复被这道门挡掉的三个传感器。是否把 `engine-support.yaml` 里白2 的查词能力
  升级，仍须回到原始启动路径完成「显示台词 → 对应语音 → 截图 → 真卡写入」E2E 后再定。
  相关：[[BUG-2051]]（同一函数第一层的永久缓存缺陷，先修的那条）。
