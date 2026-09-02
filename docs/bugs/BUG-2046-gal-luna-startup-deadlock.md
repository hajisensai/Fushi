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
  - **根因位置**：在 hook DLL（`native/galgame_hook/hook/`）8/28→9/2 之间新增/改动的加锁路径；精确 `file:line` 需要 PDB 或对源码定位 RVA `0xfc82`。用户本轮明确要求不看 hook 代码，故**到此为止，未继续定位**。
- **[ ] ① 未修复** — 待用户确认是否允许进入 hook 代码定位 RVA `0xfc82` 的临界区。修法方向：该锁不得在 LunaHook 可能挂起全线程的窗口里被游戏主线程持有/等待（要么 hook 侧改成无锁/try-lock 快路径，要么 injector 把 LunaHook 注入推迟到主线程越过启动期临界区之后）。
- **[ ] ② 未加自动化测试** — 应加：native 层对该锁的「持锁期间不得调用可能被 detour 的 API」守卫；复现脚本 `tmp/trials.sh`（12 s 采样线程数判 RUN/HANG）可作真机回归配方。
- **备注**：
  - 另一份现场：`TenShiSouZou_R18\tenshi_sz.1DD378C521AE607.crash.dmp`（2026-08-29 16:00，与 `voice_hook_runtime/de323cc291c6453c` 创建同一分钟）是**退出时**崩溃：`ExitProcess → LdrShutdownProcess → 插件 9e322b5684e1.dll!DLL_PROCESS_DETACH` 访问违例，彼时 `LunaHook32` + `fushi_voice_hook` 驻留。是卸载顺序问题，与启动无关，另案。
  - 「转区后注入失败」的字面报告按本条判 **❌ 未复现**；真 bug 是上述死锁。
  - 复现材料：`C:\Users\wrds\.claude\jobs\b80c6b49\tmp\{trials.sh,run_probe.sh,hangstack.txt,stack.txt,crash.txt}`（任务目录会被清理，需要时另存）。
