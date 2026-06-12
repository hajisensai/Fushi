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

- **[x] ① 第八修已实现（但被新 dump 反证不彻底，见下「第九修」）** —— texture_bridge.cc 代际 retired 列表 + closed-flag 双保险（commit afaf8c95e）。Windows release 重编 √ Built hibiki.exe 通过；启动 smoke 无新 GraphicsCapture 崩溃。
- **[x] ② 已加自动化测试** —— 源码扫描守卫 hibiki/test/widgets/texture_bridge_stop_guard_test.dart（断言 teardown 顺序 Close+retire 不变量），绿。Windows 原生 WGC host 单测跑不了，故用源码守卫钉死 teardown 不变量。
- **备注**：dump 用 `cdb.exe`（Windows Kits 10 Debuggers）分析。Windows-only 原生崩溃，host 单测无法跑 WGC，自动化测试用 C++ 源码扫描守卫钉死 teardown 不变量 + Dart 守卫测试。重编 + 真机复现见报告。

### 第九修（代际释放 -> 永久保活，TODO-168/169/170，2026-06-12）

**第八修为何不彻底（决定性新证据 hibiki.exe.81504.dmp）**：用户报「书籍查词时复制词典内容触发滑动关闭 -> hibiki 立刻崩溃」（电脑端）。新 dump `C:\Users\wrds\AppData\Local\CrashDumps\hibiki.exe.81504.dmp`（2026-06-12 11:35:24 崩溃）来自 **含第八修的包 `hibiki-windows-a8ff069a7`**（`lmvm hibiki` 实证 Image path + git `merge-base --is-ancestor 8bd69cc2d a8ff069a7` 确认含第八修），仍崩**同一偏移 0xf0d5**（`GraphicsCapture!TypedEventHandler<Direct3D11CaptureFramePool,IInspectable>::operator()+0x15: mov rax,[rcx]`，rcx=0，null delegate）。三铁证证明崩溃帧池根本没被第八修保活住：

1. 崩溃帧池 `0x2205274af10` 内存 **MEM_FREE**（`!vprot` 返回 `No containing memory region found`）—— 所有强引用归零，**不在 retired-list 里**（保活的帧池引用计数 >0，绝不会 free）。
2. closed-flag `[pool+0x129]` 读到 **0**（崩在 `event::operator()`，越过了 `FirePresentEvent+0x1c` 的 `cmp byte ptr [rcx+129h],0; jne +0x88` 早返回；反汇编实证 WGC `IClosable::Close` 在 `+0x65` 设 `mov byte ptr [rdi+129h],1`）—— 帧池呈「未 Close」态（实为内存已 free，closed-flag 字节随对象消失读到野值 0）。
3. 崩溃栈（线程 0，`~* k`）是消息泵正常派发一个 deferred FirePresentEvent（`CoreMessaging!DeferredCall::Callback_Dispatch -> FirePresentEvent`），**无任何 hibiki teardown 帧**，其余线程全在 `NtWaitForSingleObject` —— 延迟 UAF，与触发操作（滑动关闭）解耦，是早先某次 WebView dispose 留下的在途 deferral 此刻才 fire。

**根因机理**：第八修把 Close 后的帧池 move 进 retired-list，但**按「代」延迟释放**（第 N 次 teardown 释放第 N-2 次的帧池），赌「两次 teardown 之间 UI 线程必跨过完整消息循环 -> 老帧池在途 deferral 已派发完」。81504 dump 反证这是个**会输的时机赌注**：用户快速连续查词时多次 teardown 在数百毫秒内完成，而 DispatcherQueue 里老帧池的 deferred FirePresentEvent 仍积压未 fire；代际逻辑提前 `erase`/Release 老帧池 -> 内存 free -> 在途 deferral fire 时读 free 内存 -> 进 `event::operator()` 读野 m_targets -> null delegate -> 崩。**closed-flag 双保险只在帧池内存有效期内成立**；代际逻辑一旦 Release 帧池，closed-flag 随内存一起消失，双保险失效。根因 `packages/flutter_inappwebview_windows/windows/custom_platform_view/texture_bridge.cc` 的 `RetiredFramePoolRegistry::Retire`（旧代际 erase 逻辑）。

**查词弹窗滑动关闭触发路径**：`SwipeDismissWrapper`（`hibiki/lib/src/utils/misc/swipe_dismiss_wrapper.dart`）的横向滑动命中阈值 -> `onDismiss`。reader 弹窗走「visible=false 复用 WebView（不 dispose）」语义，video 弹窗走「移除 OverlayEntry -> WebView dispose -> `~CustomPlatformView` -> `texture_bridge_->Stop()` -> StopInternal -> WGC teardown」。但 dump 是延迟 UAF：崩溃发生在消息泵派发**早先排队**的 deferral，不是滑动关闭那一刻新触发的 teardown —— 滑动关闭只是当时正在跑消息泵、恰好派发到那个迟到 deferral。手机端是 Android（无 WGC），其闪退是另一路径（查词弹窗 dispose），不在本 native 修范围。

**第九修（唯一不依赖时机的因果不变量：永久保活）**：把 `RetiredFramePoolRegistry::Retire` 的「代际 erase 释放」改为**只 push、绝不主动释放**（永久保活）。已 Close 帧池的全部 D3D/GPU 资源随 `CloseInternal -> ResetD3DResources`（反汇编实证）释放，退役帧池只剩一个小 COM 壳（几百字节）。帧池内存永久有效 -> closed-flag `[pool+0x129]` 永久 = 1 -> 任何迟到的 deferred FirePresentEvent 在 `FirePresentEvent+0x1c` 永久早返回 no-op，永不读 event 成员/delegate 表。**不再有「内存被释放」的窗口**，null-delegate UAF 在因果上不可能发生。代价：每次 WebView teardown 常驻一个已 Close 小 COM 壳（GPU/服务端资源已随 Close 释放），是有界小泄漏（teardown 频率有界，进程退出随 OS 回收），是 WGC API 不提供「排空 deferral」同步原语下的必要兼容代价。删除 `kRetiredGenerationGap` / `generation_counter_` / `RetiredFramePool` struct / `std::remove_if` erase 块，简化数据结构为 `std::vector<com_ptr<...>>` 只增不减。

- **[x] ① 第九修已实现** —— `texture_bridge.cc` `RetiredFramePoolRegistry` 改永久保活（只 `push_back`，删全部代际/erase 逻辑）；StopInternal 的 Close session -> remove_FrameArrived -> Close pool -> Retire 顺序不变，注释更新为永久保活因果不变量。commit `063824f48`。
- **[x] ② 自动化测试已更新** —— `hibiki/test/widgets/texture_bridge_stop_guard_test.dart` 改写为永久保活契约：**禁止** `kRetiredGenerationGap` / `generation_counter_` / `std::remove_if` 回潮、`RetiredFramePoolRegistry` 类体内**禁止** `.erase(`、必须 `push_back` 保活；保留全部既有契约（Close 顺序、`remove_FrameArrived` 断源、不显式 Close 之外的回潮禁令、FreeThreaded/TryEnqueueWithPriority/QuietHops/DrainHops/PendingCaptureTeardown 禁令）。`flutter test test/widgets/texture_bridge_stop_guard_test.dart` 绿。
- **验证**：①守卫测试绿 ②`flutter build windows --release` 编译验证（见提交说明）③**Windows 真机复现验证（查词弹窗滑动关闭反复触发 -> 不再崩 GraphicsCapture）待 PM/用户**——崩溃为延迟 UAF，host 单测跑不了 WGC，只能用户真机 Release 反复跑「开 EPUB/视频 -> 查词 -> 复制/滑动关闭弹窗 -> 反复」收口。
- **诚实标注的不确定点**：①永久保活的「有界小泄漏」假设依赖「teardown 频率有界」——极端重度用户长时间高频开关 WebView 会线性累积小壳（每个几百字节），需真机内存监控确认增长可接受（不是无界爆炸，但确实只增不减直到进程退出）。②dump 81504 是含第八修的包，证明第八修代际释放失败是确定的；但「永久保活能根治」是因果论证（closed-flag 永久有效 -> 迟到 deferral 永久早返回），**未经真机 Release 反复触发实测确认崩溃消失**——这是本类延迟 UAF 的固有验证局限，前八修均栽在「论证对了但真机仍复发」，本修虽消除了所有时机赌注，仍需真机收口。
