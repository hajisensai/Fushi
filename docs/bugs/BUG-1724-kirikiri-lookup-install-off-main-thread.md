## BUG-1724 · kirikiri-lookup-install-off-main-thread

- **报告**：2026-08-19（用户：游戏内查词开着玩《天使☆騒々 RE-BOOT!》时，游戏弹 KiriKiri 的 `Fatal Error / Access Violation` 对话框）
- **真实性**：✅ 真 bug。根因 `native/galgame_hook/hook/adapters/kirikiri_adapter.inc:5312`（旧 `PollKirikiriLookupInstall()` 整段在 HookWorker 线程上调引擎 API）
- **[x] ① 已修复** — `RunKirikiriLookupInstallOnMainThread()` 把安装挪回引擎主线程；worker 侧只登记意图
- **[x] ② 已加自动化测试** — `native/galgame_hook/tests/kirikiri_lookup_source_guard_test.py`
  （`test_install_never_calls_engine_from_hook_worker` / `test_main_thread_install_checks_thread_identity_first` + 6 条变异用例）

### 现场

- 游戏：`tenshi_sz.exe`，**KiriKiri Z 1.2.0.3**，x86，客户区 3840×2096（我这台 3840×2160 减任务栏 = 最大化窗口）
- Fushi：`2.1.1-debug.11810`，hook DLL 构建于 2026-08-17 17:34
- 注入确认：进程内同时加载 `fushi_voice_hook.dll` / `LunaHook32.dll` / `textrender.dll`

引擎自己写下的取证（`savedata/`，已归档到 job tmp）：

- `Kirikiri1.2.0.3-20260819-001341-204160-165556.dmp`（KiriKiri 的硬件异常 dump，带异常上下文）
- `hwexcept.log`、`krkr.console.log`

异常上下文：

```
ExceptionCode: c0000005 (Access violation), 读地址 0x00000000
eip = tenshi_sz+0x16a672     eax=00000000  ecx=edi=0x438(=1080)

00d9a66b  mov  eax, dword ptr [ebx+44h]   ; 取对象 +0x44 的成员指针
00d9a672  mov  ecx, dword ptr [eax]       ; ← 读它的 vtable，eax 为 NULL
00d9a676  call dword ptr [ecx+1Ch]        ; 虚调用
```

`ebx` 的 RTTI 解出来是 **`tTVPBasicDrawDevice`**（KiriKiri 绘制设备）。调用链：
`user32!DispatchMessageW`（消息 `0x113` = **WM_TIMER**）→ 窗口过程 → 4 层 TJS 递归 →
`+0xc8efc` → `+0x11ce3b` → `+0x10e497`（一个连判两次空的小分发器）→ `+0x16a672`（此处不判空）。

时间线（`krkr.console.log` 的时钟比墙钟快 1 小时，已用两个独立锚点校准）：

```
00:13:33  游戏启动
00:13:40  Startup script ended
00:13:41  ★ AV，KiriKiri 写 dump
00:13:43  我们的 fushiLookupField 连抛 6 次 TJS 异常 + "[HibikiLookup] sensor installed"
```

崩了之后游戏看起来还在跑，是因为 `MessageBox` 自带模态消息循环，WM_TIMER 仍在派发。

### 根因

查词传感器的安装/重试点 `PollKirikiriLookupInstall()` 跑在 **HookWorker 后台线程**上。静态调用链：

```
HookWorker (dll_main.cpp:465, while(!g_stop){ registry.Poll(); Sleep(...); })
  -> AdapterRegistry::Poll()              (adapter_registry.inc:350)
  -> kirikiri_.ProcessPendingEvents()     (adapter_registry.inc:184)
  -> ProcessKirikiriVoiceTasks()          (kirikiri_adapter.inc:161)
  -> PollKirikiriLookupInstall()          (kirikiri_adapter.inc:162)
```

（在崩溃进程里抓到的**线程 1 实栈**印证了这条链：`fushi_voice_hook` → `CreateToolhelp32Snapshot`，正是这个 worker。）

它在那个后台线程上直接调了三类引擎 API：

| 调用 | 性质 |
|---|---|
| `exporter->QueryFunctionsByNarrowString(...)` | 读引擎导出表 |
| `TJSAllocVariantString(bootstrap)` | **从 TJS 全局变体字符串池分配** |
| `TVPAddContinuousEventHook(...)` ×2 | **写引擎每帧遍历的回调容器** |

KiriKiri 的 TJS 堆、连续事件回调容器、图层树和绘制设备都只归引擎主线程，没有任何内部同步，
而主线程每帧都在遍历/分配它们。于是 worker 的写入与主线程并发 —— 无同步的并发修改。

设计**本意是对的**：`g_lookup_bootstrap_state`（0/1/2/3）和注释「先登记此回调，下一次引擎事件循环
再在游戏主线程执行一次 bootstrap」表明 bootstrap **脚本执行**确实被正确放到了主线程回调里。
漏掉的是「登记回调」这个动作本身，以及它前面的字符串分配和导出表查询 —— 这三步仍留在 worker 上。

**诚实边界**：上述跨线程引擎调用可以证明（静态调用链 + 实栈双证）。但从「跨线程改 TJS 堆 / 回调表」
到「`tTVPBasicDrawDevice+0x44` 恰好读成 NULL」这条具体腐化路径，我没有逐指令还原 ——
竞态型内存腐化本来就会在无关位置浮现。这一点不当成已证。

### 实测因果

复现夹具：`injector --launch` 拉起游戏 → `fushi_voice_lookup_probe <pid>` 立刻把
`lookup_enabled` 置 1（等价于 Fushi 会话激活时的 `setEnabled` 重推）→ 对游戏窗口做
最大化/还原/改尺寸的循环 → 看 `savedata/` 是否出现新的 `Kirikiri*.dmp`。

| 组 | 结果 |
|---|---|
| 修复前，带 hook + 缩放 | **9 次崩 1 次**；崩溃的指令地址、寄存器、9 层栈帧与用户现场**完全一致** |
| 对照，不带 hook + 同样缩放 | **5 次 0 崩** |
| 修复后，带 hook + 缩放 | 见下方"验证" |

崩溃是竞态，命中率低；单看次数统计功效不足，主证据是「跨线程引擎调用确实存在」这一结构事实，
次数只作旁证。

### 修复

`kirikiri_adapter.inc`：

1. `PollKirikiriLookupInstall()`（HookWorker）降级成**纯意图登记**，一个引擎调用都不剩，
   只置 `g_lookup_install_requested`。
2. 新增 `RunKirikiriLookupInstallOnMainThread()`，承载全部引擎调用；它**先核对线程身份**
   （`ResolveKirikiriEngineMainThreadId()` vs `GetCurrentThreadId()`）再往下走。
3. 主线程接缝 = 引擎自己在主线程上调进来的 detour：`Detour_TVPCreateIStreamStub`、
   `Detour_TVPCreateBinaryStream`、`HandleV2Link`。**仍在函数内自查线程身份**，因为
   KiriKiri 也会在后台线程开流（声音流式读取），只靠"在 detour 里"不足以断定主线程。
4. `ResolveKirikiriEngineMainThreadId()` 取"拥有本进程顶层可见窗口的线程"，解析不出来时
   返回 0 → 安装**失败关闭**。这顺带修掉了另一半问题：原来安装可能发生在引擎还没把窗口和
   绘制设备立起来的时候。

副作用（已知、可接受）：安装时机从"开关置 1 后约 0.75s"变成"窗口出来 + 下一次引擎开流"，
实测约 6.5s（游戏本身启动就要 ~7s，即窗口一就绪就装）。游玩期 KAG 持续开流，重装延迟可忽略。

### 验证

- x86 / x64 两个架构 `fushi_voice_hook` 均编译通过。
- 功能未回归：修复后 `lookup_diag` 仍依次点亮 `expression_ready` → `sensor_installed` →
  `geometry_observed`，`text_writes` 正常增长。
- 守卫：`kirikiri_lookup_source_guard_test.py` 106 项全绿；对**真文件**做变异（把
  `g_lookup_add_continuous(` 塞回 worker 入口）确认守卫真红，还原后 sha256 与变异前一致
  （`4d69dcab…9ae378`）。
