## BUG-209 · 手机闪退实为Windows WGC FramePool teardown崩溃
- **报告**：2026-06-12（用户报「又闪退了」，指认 Windows 桌面版 hibiki-windows-b1f960290）
- **真实性**：✅ 真 bug。根因 `packages/flutter_inappwebview_windows/windows/custom_platform_view/texture_bridge.cc:196`（`frame_pool_ = nullptr` 在 teardown 当下释放帧池唯一强引用）。

### dump 真实崩溃栈（决定性证据）
两份 minidump（`hibiki.exe.8952.dmp` 6/12 0:11、`hibiki.exe.99916.dmp` 6/11 22:10）崩溃签名完全一致：

```
0xc0000005 ACCESS_VIOLATION, read @ 0x0, rcx=0
GraphicsCapture!TypedEventHandler<Direct3D11CaptureFramePool,IInspectable>::operator()+0x15
  00007fff`505df0d5 488b01  mov rax,qword ptr [rcx]   ; rcx=0 -> 读 null delegate 的 vtable
GraphicsCapture!winrt::impl::delegate<...>::Invoke+0x54
GraphicsCapture!TypedEventHandler<...>::operator()+0x27
GraphicsCapture!winrt::impl::invoke<...>+0x25
GraphicsCapture!winrt::event<...>::operator()<...FramePool,nullptr_t>+0x6e   ; 读 [framepool+0x60] event 成员
GraphicsCapture!Direct3D11CaptureFramePool::FirePresentEvent+0x62
GraphicsCapture!<lambda...>::<lambda_invoker_cdecl>+0x66
CoreMessaging!Microsoft::CoreUI::Dispatch::DeferredCall::Callback_Dispatch+0x2d5
CoreMessaging!...DispatchLoop / EventLoop / UserAdapter::WindowProc
user32!UserCallWinProcCheckWow -> DispatchClientMessage
win32u!NtUserGetMessage -> user32!GetMessageW -> hibiki+0xae89 (WinMain 消息泵, 线程0)
```

内存取证：`framepool` 对象所在页（含 `+0x60` event 成员、delegate 数组、sender 对象，地址 0x296ef49aa40 / 0x296ef49aa48 / 0x29650200f40）**整片 unmapped 显示 `????`** —— 即 `FirePresentEvent` 执行期帧池对象本身已被释放回收。

`FirePresentEvent` 反汇编开头：`+0x14 cmp byte ptr [rcx+129h],0`（closed-flag）-> `+0x1c jne +0x88`（已 Close 则跳过 event fire 早返回）。`event::operator()` 是标准 WinRT event：先 `mov rax,[r14]`（读 `framepool+0x60` 的 `m_targets`）再 `lock inc [rax]` 拷快照遍历。**帧池内存已释放 -> 读到野 delegate 数组 -> null delegate abi 指针 -> 崩**。

### 根因
帧池用 `Direct3D11CaptureFramePool::Create`（非 FreeThreaded），其 `FrameArrived` 作为 **deferred call** 排进创建线程（UI 线程）的 CoreMessaging DispatcherQueue（USER32 message-only window 经 GetMessage/PeekMessage 派发）。WebView `dispose`（`in_app_webview_manager.cpp:76 webViews.erase`）在同一 UI 线程同步触发 `~TextureBridge`。`StopInternal` 的 `frame_pool_ = nullptr` 释放唯一强引用 -> 帧池立即析构。**已排队但未派发的 deferred FirePresentEvent 不持帧池强引用**（dump 实证页已 unmapped），它在帧池析构后才 fire -> UAF -> null delegate AV。

### 前几次为何没根治
- `a0f31988e`（BUG-113，显式 Close+release）：诊断对了机理，但仍在 teardown 当下释放帧池，在途 deferral 仍 UAF。
- `1d0ed56fe`/`458099882`（shared callback_state 失效化 / retain handler）：崩点在 GraphicsCapture.dll 内部 `event::operator()`，到达我们 lambda 之前，失效化够不着。
- `8a773ab60`（#5 drain-hop，DispatcherQueue Low 优先级 hop 判排空）：deferred FirePresentEvent 与 TryEnqueue 任务不保证 FIFO 互序，revoke 后计数失明。
- `8a7f226ba` / 当前 develop 第七修（不显式 Close，赌 deferral 持强引用延后析构）：**dump 决定性反证——deferral 不持强引用，帧池在 FirePresentEvent 运行期已释放**。
- `7b1eac397`（BUG-163，sever frame_available_ registrar）：处理的是另一条边（late frame 触碰 registrar），够不着 GraphicsCapture 内部 null delegate。
- 共性盲点：都在「判断/依赖在途 deferral 的时机或引用」，但 dump 证明这些假设都不成立。

### 修复（最强不变量，无时机赌注）
teardown 顺序：`session.Close()` -> `remove_FrameArrived(token)` -> `frame_pool.Close()`（同步设 closed-flag）-> 帧池 ComPtr **move 进进程级代际 retired 列表保活**，只释放比当前 teardown 早 >=2 代的条目（两次 teardown 之间 UI 线程必跨完整消息循环，2 代前帧池的在途 deferral 必已派发完）。双保险：(1) Close 的 closed-flag 让在途 FirePresentEvent 在 `cmp [pool+129h]` 早返回 no-op，永不读 event 成员；(2) 代际延迟使释放只发生在跨越完整消息循环之后。帧池内存在「可能有在途 deferral」的窗口内永不释放 -> 崩溃因果上不可能。常驻最多 1-2 个已 Close 退役帧池，不累积。

- **[ ] (1) 未修复** —
- **[ ] (2) 未加自动化测试** —
- **备注**：dump 用 `cdb.exe`（Windows Kits 10 Debuggers）分析。Windows-only 原生崩溃，host 单测无法跑 WGC，自动化测试用 C++ 源码扫描守卫钉死 teardown 不变量 + Dart 守卫测试。重编 + 真机复现见报告。
