## BUG-2046 · 9/2 构建 fushi_voice_hook 与 LunaHook 装 hook 时同一临界区死锁：游戏启动无窗口（用户报「转区后 DLL 注入失败」）
- **报告**：2026-09-02（用户：wrds）
  - 原话：「游戏模块：1、转区以后 dll 注入会失败」，并声明「此行为与 hook 无关」。
- **真实性**：✅ 现象真实，但**报告里的两个前提都不成立**：不是「转区」引起的，也不是「注入失败」。
  - **注入每一趟都成功**：本机 `fushi_voice_injector.exe --launch … --hold --wait-ms 30000 --japanese-locale --luna-hook-profile …`（Fushi 同款参数）在三个 x86 目标（`tenshi_sz.exe` ×2 / `屋上の百合霊さんフルコーラス.exe`）上共 20+ 趟，**每趟**都打出 `OK hooked pid=… hooked=1` 与 `[luna] LunaHook32.dll 已注入 → [luna] connected`，包括最后卡死的那几趟。Locale Emulator 路径（`LeCreateProcess` → `CreateRemoteThread(LoadLibraryW)` 早注入）没有任何失败。
  - **转区不是变量**：同一游戏不带 `--japanese-locale` 也复现卡死（1/4），带的复现 3/8；`auto` 档在本机（ACP=936）对每个 32 位游戏都转区，所以用户只可能在「已转区」标记下看到失败，把它归因给转区是观察面导致的。
  - **真正的变量是 helper 构建版本**：
    | helper | 转区 | LunaHook | 趟数 | 12 s 内出窗口 |
    |---|---|---|---|---|
    | 8/28 构建（`voice_hook_runtime/de323cc291c6453c/x86`，injector sha `d1b279f2…`） | 有/无 | 开 | 7 | 7/7 |
    | 9/2 构建（`D:\APP\Hibiki\voice_hook\x86`，随 2.2.4-debug.13075 安装，injector sha `9262604a…`） | 有/无 | 开 | 12 | **8/12**（卡死 4 趟：8 线程 / 26 MB / 无窗口，永不恢复） |
    | 9/2 构建 | 有 | `--no-luna` | 1 | 1/1 |
    两个构建之间 `LunaHook32.dll` / `LunaHost32.dll` / `LoaderDll.dll` / `LocaleEmulator.dll` **sha256 完全相同**，差异只在 `fushi_voice_hook.dll` 与 `fushi_voice_injector.exe`（对应 develop `4125386daa`→`46563e5df4`，injector 只改了 40 行 IPC 字段初始化，hook 目录改动 2 万行：`module_settle.h` / `generic_input_shield.h` / KiriKiri lookup 等）。
  - **卡死态线程栈**（x86 cdb attach，pid 47032，`tmp/hangstack.txt`）：
    ```
    #0 (游戏主线程, suspend=2)  ntdll!RtlEnterCriticalSection ← fushi_voice_hook+0xfc82 ← tenshi_sz+0x46915 ← … ← tenshi_sz+0x23975a
    #6 (LunaHook32 工作线程)      ntdll!RtlEnterCriticalSection ← fushi_voice_hook+0xfc82 ← LunaHook32+0xbc7f ← …(hook 安装链) ← LunaHook32+0x10eb4
    #7                            ntdll!RtlUserThreadStart (suspend=2，从未跑起来)
    ```
    主线程与 LunaHook 的 hook 安装线程在 **`fushi_voice_hook.dll` RVA `0xfc82` 处同一个 `EnterCriticalSection` 调用点**互等；主线程另带一次真实挂起（suspend=2，其余线程都是 cdb 的 1），符合 MinHook 式「挂起全线程 → 打补丁」窗口里再进 hook DLL 的锁。injector 随后打 `[luna] disconnected`。
  - **根因（用户随后允许进 hook 代码，已定死）**：`fushi_voice_hook+0xfc82` 反汇编 = `native/galgame_hook/hook/adapters/siglus_adapter.inc` 的 `Detour_CloseHandle`（kernel32!CloseHandle 的 detour，所有引擎共用），它顺序调十个 `Forget*`，其中 Tyrano / BGI / ElfAi6 / Leaf / Hunex / Siglus 六张句柄表的 `Forget*` 各自 `EnterCriticalSection(&g_cs)`（`g_cs` = 0x690515d0，与 push 的地址一致）。而 **CloseHandle 正是 MinHook `Freeze()` 在 `SuspendThread` 了其它所有线程之后还会调的 API**（`third_party/minhook/src/hook.c:439` 关 OpenThread 句柄；LunaHook32 内嵌的是同一份 MinHook）。cdb 读锁体：`LockCount=0xFFFFFFF9, RecursionCount=0, OwningThread=0` —— **无人持有**，但一个等待者已被唤醒（低两位 `01`）却是被 Freeze 挂起的主线程，它拿不到锁就不会再唤醒下一个等待者（LunaHook 线程）。不是锁序死锁，是「挂起了正在拿锁的线程，再去拿同一把锁」。8/28 构建里这条 detour 只摘 8 张表且 Leaf/Hunex 两张（9/2 新增）不存在，窗口窄到 7 趟没撞上；本质缺陷早就在。
- **[x] ① 已修复** — 规则只有一条：**CloseHandle detour 可达的代码不得阻塞**。新建 `native/galgame_hook/hook/tracked_handle_table.h`（reserved 占位 → 写字段 → 发布 handle 的无锁协议 + per-slot `seq` 防撕裂读，Forget 清掉**全部**同值槽位），把上述六张表的 `Remember*/Copy*/Is*/Forget*` 全部接上去、彻底退出 `g_cs`（Artemis / CatSystem2 / Malie 三张表本来就是这套写法，现在一份实现十张表共用）。`Detour_CloseHandle` 头上写明禁令。injector 未改。x86 `cmake --build` 零告警，ctest 53/53；x64 `fushi_voice_hook.dll` 与两个相关单测编译通过、2/2 绿（x64 完整 ctest 被 `unity_audio_extract` 要求 .NET 8 而本机只有 6.0.428 的 NETSDK1045 阻断，与本改动无关、干净 develop 同样阻断，见 BUG-1092 备注）。真机（同一游戏、同款参数、含 `--japanese-locale` + LunaHook）：修复前 9/2 构建 **4/36 卡死**；修复后本地构建 **70/70 起窗**（40 趟 12 s 单采 + 30 趟 12/20/30 s 复采，0 卡死；按 11% 的历史命中率，70 趟零命中的概率约 0.03%）。
- **[x] ② 已加自动化测试** — `tests/tracked_handle_table_test.cpp`（往返 / 无效句柄 / 同值原位重写不占第二槽 / 表满 / Forget 清全部同值槽 / 奇数 seq 跳过 + 撕裂读拒绝 / reserved 占位不被匹配，CTest 注册）；源码守卫 `tests/close_handle_detour_lockfree_guard_test.py`（解析 `Detour_CloseHandle` 体 → 找到每个被调函数的定义 → 断言无 `EnterCriticalSection/AcquireSRWLock/Wait*/Sleep/std::mutex`，且 `Forget*` 必须走 `ForgetTrackedHandle` 或裸 Interlocked CAS；≥ 8 个被检函数否则判空转），已登记 `tools/run_guards.ps1`。**变异实测**：给 `ForgetTyranoAsar` 塞回 `EnterCriticalSection(&g_cs)` → 守卫 exit 1；精确还原后 sha256 与变异前一致（`e7d42342c5538fbb…`）。
- **备注**：
  - 另一份现场：`TenShiSouZou_R18\tenshi_sz.1DD378C521AE607.crash.dmp`（2026-08-29 16:00，与 `voice_hook_runtime/de323cc291c6453c` 创建同一分钟）是**退出时**崩溃：`ExitProcess → LdrShutdownProcess → 插件 9e322b5684e1.dll!DLL_PROCESS_DETACH` 访问违例，彼时 `LunaHook32` + `fushi_voice_hook` 驻留。是卸载顺序问题，与启动无关，另案。
  - 「转区后注入失败」的字面报告按本条判 **❌ 未复现**；真 bug 是上述死锁。
  - 复现材料：`C:\Users\wrds\.claude\jobs\b80c6b49\tmp\{trials.sh,run_probe.sh,hangstack.txt,stack.txt,crash.txt}`（任务目录会被清理，需要时另存）。
