## BUG-209 · 手机闪退实为Windows WGC FramePool teardown崩溃
- **报告**：2026-06-12（用户报「又闪退了」，指认 Windows 桌面版 hibiki-windows-b1f960290）
- **真实性**：✅ 真 bug。根因 `packages/flutter_inappwebview_windows/windows/custom_platform_view/texture_bridge.cc:196`（`frame_pool_ = nullptr` 在 teardown 当下释放帧池唯一强引用）。**第十修重开（2026-06-14，TODO-305，「看有声书闪退」）**：第九修永久保活只覆盖 `StopInternal` 一条路径，漏了 `Start()` 重入覆盖 + `OnFrameArrived` resize `Recreate` 两条帧池丢弃/替换路径（详见文末「第十修」）。**第十二修重开（2026-06-16，TODO-439）**：v0.9.0.5025 仍崩同一 `GraphicsCapture.dll` `0xf0d5`，崩溃池对应 `create-pool` 后没有 `stop/retire/dtor`，说明保活还必须覆盖 active/running pool，而不能只覆盖 retire 后的 closed pool。**第十三修重开（2026-06-17，TODO-453 作为 TODO-439 新证据）**：用户日志已包含 `active-retain`，前三轮 teardown 完整闭合，最后一轮停在 `retire` 后、`retire-close` 前，失败窗口缩到 `RetireFramePoolLocked()` 内部的 remove/Close/registry/handler release 收口段。**第十四修重开（2026-06-17，TODO-463/TODO-465）**：0.9.15 日志停在 `retire-remove-start`，dump 显示 Close 后裸 `remove_FrameArrived` 在已关闭 pool 上抛 `RO_E_CLOSED/0x80000013` 未捕获，阻断 `retire-register` 与 `handler-release-done`。

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

- **[x] ① 第九修已实现** —— `texture_bridge.cc` `RetiredFramePoolRegistry` 改永久保活（只 `push_back`，删全部代际/erase 逻辑）；StopInternal 的 Close session -> remove_FrameArrived -> Close pool -> Retire 顺序不变，注释更新为永久保活因果不变量。commit `0a089484a`（哈希更新提交见其后续 commit）。
- **[x] ② 自动化测试已更新** —— `hibiki/test/widgets/texture_bridge_stop_guard_test.dart` 改写为永久保活契约：**禁止** `kRetiredGenerationGap` / `generation_counter_` / `std::remove_if` 回潮、`RetiredFramePoolRegistry` 类体内**禁止** `.erase(`、必须 `push_back` 保活；保留全部既有契约（Close 顺序、`remove_FrameArrived` 断源、不显式 Close 之外的回潮禁令、FreeThreaded/TryEnqueueWithPriority/QuietHops/DrainHops/PendingCaptureTeardown 禁令）。`flutter test test/widgets/texture_bridge_stop_guard_test.dart` 绿。
- **验证**：①守卫测试绿 ②`flutter build windows --release` 编译验证（见提交说明）③**Windows 真机复现验证（查词弹窗滑动关闭反复触发 -> 不再崩 GraphicsCapture）待 PM/用户**——崩溃为延迟 UAF，host 单测跑不了 WGC，只能用户真机 Release 反复跑「开 EPUB/视频 -> 查词 -> 复制/滑动关闭弹窗 -> 反复」收口。
- **诚实标注的不确定点**：①永久保活的「有界小泄漏」假设依赖「teardown 频率有界」——极端重度用户长时间高频开关 WebView 会线性累积小壳（每个几百字节），需真机内存监控确认增长可接受（不是无界爆炸，但确实只增不减直到进程退出）。②dump 81504 是含第八修的包，证明第八修代际释放失败是确定的；但「永久保活能根治」是因果论证（closed-flag 永久有效 -> 迟到 deferral 永久早返回），**未经真机 Release 反复触发实测确认崩溃消失**——这是本类延迟 UAF 的固有验证局限，前八修均栽在「论证对了但真机仍复发」，本修虽消除了所有时机赌注，仍需真机收口。

### 第十修（永久保活只覆盖 StopInternal -> 扩展到所有帧池路径，重开 BUG-209，TODO-305，2026-06-14）

**第九修为何仍崩（新 dump 取证 + 第九修的覆盖盲点）**：用户报「Windows 看有声书闪退」。新崩溃 dump（cdb 分析 hibiki.exe，版本 `0.7.2.4720`，**已含第九修永久保活 commit `0a089484a`**）签名与前九修**逐字一致**：`ExceptionCode c0000005`（ACCESS_VIOLATION），`GraphicsCapture!TypedEventHandler<Direct3D11CaptureFramePool,IInspectable>::operator()` 在 null delegate 上 fire（`rcx=0`，`mov rax,[rcx]`），栈 = `CoreMessaging DeferredCall::Callback_Dispatch -> GraphicsCapture!Direct3D11CaptureFramePool::FirePresentEvent -> null delegate`，无 hibiki teardown 帧 = 延迟 UAF。

**决定性证据**：触发 FirePresentEvent 的帧池内存全 `????`（MEM_FREE）——这个帧池**没被第九修的永久保活住**。永久保活的帧池引用计数 >0 绝不会 free。结论：**第九修的永久保活只覆盖了 `StopInternal` 这一条帧池销毁路径，漏了另外两条非 StopInternal 的帧池丢弃/替换路径**，崩溃帧池正是从漏掉的路径裸释放的。

**第九修漏掉的两条帧池路径（根因 file:line）**：

1. **`Start()` 重入覆盖**（`texture_bridge.cc:147` `frame_pool_ = CreateCaptureFramePool(...)`，旧基线行号）。`CustomPlatformView::HandleMethodCall` 的 `setSize` 分支（`custom_platform_view.cc:323` `texture_bridge_->Start()`）**每次 resize/setSize 都调 `Start()`**，不止首帧。`is_running_` 守卫只挡「已成功 `StartCapture` 后的重入」。但若上一轮 `Start()` 在 `CreateCaptureSession` 失败（`:179-183` return，不设 `is_running_`）或 `StartCapture` 失败（`:190` return，不设 `is_running_`）后早返回，此时 `frame_pool_` 已被赋值且已 `add_FrameArrived` 注册了句柄，而 `is_running_` 仍为 `false`。下一次 `setSize -> Start()` 越过 `is_running_` 守卫，直接在 `:147` 用新池**覆盖** `frame_pool_` ComPtr -> 旧池最后强引用归零、内存 free（= dump 的 MEM_FREE），但旧池仍挂着已注册的 FrameArrived，其在途 deferred FirePresentEvent 在旧池 free 后才 fire -> 读 free 内存的 event 成员 -> null delegate -> 同一崩点。

2. **`OnFrameArrived()` 的 resize 路径**（`texture_bridge.cc:302` `frame_pool_->Recreate(...)`，旧基线行号）。`NotifySurfaceSizeChanged() -> needs_update_ = true -> OnFrameArrived` 里对同一帧池调 `Recreate` 复用 COM 对象、只换内部 back buffer。但 `Recreate` 会同步拆掉旧池的内部 present 基建（旧 swap-chain / present 子对象），而此前已排进 UI 线程 CoreMessaging 队列、尚未 fire 的 deferred FirePresentEvent 仍指向被拆的旧内部状态 -> 之后 fire 时读已释放的 event 成员 -> null delegate -> 同一崩点。`Recreate` 完全不走第九修的「Close 设 closed-flag + 退役保活」。有声书场景查词弹窗 / WebView 高频开关 + 阅读器布局变化使 setSize（path 1）和 resize（path 2）都更密集，故复发率更高。

**第十修（把永久保活不变量扩展到所有丢弃/替换帧池的路径）**：把「断源（`remove_FrameArrived`）-> Close 设 closed-flag -> 移交退役注册表永久保活」三步收敛进单一 `RetireFramePoolLocked()`（`texture_bridge.cc`），并让**所有**会丢弃/替换帧池的路径都走它：
- `StopInternal()` —— Close session 后调 `RetireFramePoolLocked()`（第九修已覆盖，重构为复用同一 helper，行为不变）。
- `Start()` —— 在覆盖 `frame_pool_` 前先调 `RetireFramePoolLocked()` 退役保活可能残留的旧池（修路径 1）。
- `OnFrameArrived()` resize 分支 —— **删除裸的帧池 Recreate 调用**，改走新增的 `RecreateFramePoolLocked()`：先 `RetireFramePoolLocked()` 退役保活旧池 + Close 旧 CaptureSession，再 `CreateAndStartFramePoolLocked()` 建全新干净帧池 + 新会话（修路径 2）。

抽出 `CreateAndStartFramePoolLocked()` 共用「建池 + 挂 FrameArrived + 建 CaptureSession + StartCapture」给 `Start()` 与 `RecreateFramePoolLocked()`，确保 resize 用与首帧创建完全相同的 WGC 线程模型 / delegate 注册（不回潮 FreeThreaded）。因果不变量升级为：**任何曾经 add_FrameArrived 的帧池，从此一律退役保活、永不裸释放**，故 null-delegate UAF 在因果上不可能发生。GPU 子类 `TextureBridgeGpu::StopInternal` 不受影响（仍委托基类）；resize 时 GPU 目标 `surface_` 由 `EnsureSurface` 按 size 变化自愈，与帧池重建解耦。

- **[x] ① 第十修已实现** —— `texture_bridge.cc` 新增 `RetireFramePoolLocked` / `CreateAndStartFramePoolLocked` / `RecreateFramePoolLocked`，`StopInternal` / `Start` / `OnFrameArrived` 三路径统一走退役保活，删除裸的帧池 Recreate 调用；`texture_bridge.h` 加三个方法声明 + BUG-209 注释。commit 见提交说明。
- **[x] ② 自动化测试已更新** —— `hibiki/test/widgets/texture_bridge_stop_guard_test.dart` 加：`StopInternal` 必须调 `RetireFramePoolLocked`、`RetireFramePoolLocked` 体内三步顺序（断源 -> Close -> Retire -> 置空）、`Start` 覆盖前必须 `RetireFramePoolLocked`、**禁止裸的 `frame_pool_->Recreate(`**、`OnFrameArrived` resize 必须走 `RecreateFramePoolLocked`、`RecreateFramePoolLocked` 必须「先退役旧池再建新池」。保留全部既有契约。`flutter test test/widgets/texture_bridge_stop_guard_test.dart` 绿。
- **验证**：①守卫测试绿 ②Dart 侧 `flutter analyze` 无新 error ③`flutter build windows`（native 编译验证，见提交说明）④**Windows 真机复现验证（看有声书 -> 反复查词/开关弹窗 WebView -> 不再崩 GraphicsCapture）待 PM/用户**——host 跑不了 WGC，守卫测试是最强可落地证据。
- **诚实标注的不确定点**：①本修消除了「帧池被裸释放而在途 deferral 仍在途」的**全部已知**窗口（StopInternal/Start 重入/resize 三条），但与前九修一样，「能根治」是因果论证（所有曾 add_FrameArrived 的帧池永久保活 -> closed-flag 永久有效 -> 迟到 deferral 永久早返回），**未经真机 Release 反复触发实测确认崩溃消失**——这是本类延迟 UAF 的固有验证局限。②若真机仍崩，需用户提供**崩溃当下的精确 minidump**（`%LOCALAPPDATA%\CrashDumps\hibiki.exe.*.dmp`）+ 出包版本号，按前九修方法（cdb `!vprot` 验崩溃帧池内存状态 + `[pool+0x129]` closed-flag + `~* k` 全线程栈）确认崩溃帧池是否仍 MEM_FREE，以定位是否还有第四条漏网的帧池路径。③永久保活的有界小泄漏假设不变（每次 teardown/Start 重入/resize 常驻一个已 Close 小壳，进程退出随 OS 回收）。

### 第十一修（结构化原生日志 + minidump 安装 + 会话生命周期可观测加固，方案B，TODO-398，2026-06-15）

**为什么需要**：前十修每次都「论证对了根因但真机 Release 仍复发」。本类延迟 UAF 的崩溃帧无任何 hibiki teardown 帧，**唯一可靠取证手段是 minidump + cdb 反汇编**——但前十修全靠用户系统 WER 偶然在 `%LOCALAPPDATA%\CrashDumps` 留下的 dump，多次复发都因「这次没留 dump / 不知道是哪个帧池 / 不知道崩前发生了哪些帧池退役」而无法对照。Release 下 `windows/utils/log.h` 的 `debugLog` 整体由 `NDEBUG` 门控（Release 是 no-op），texture_bridge.cc 既有日志只写 `std::cerr`（无 console 时不可靠），**Release 没有任何 WGC 生命周期日志**。用户要求「加点日志根治」，本修兑现为「让 Release 崩溃能自证根因」。

**改动（不动第十修的帧池保活逻辑，纯加可观测性 + 取证基建）**：

1. **新增独立结构化原生日志 `WgcLog`（始终编译）**——`packages/flutter_inappwebview_windows/windows/utils/wgc_log.{h,cpp}`。与 `debugLog` 隔离（不动其 NDEBUG no-op 语义，避免全 fork 日志噪声爆炸）：始终编译、专写 WGC 生命周期。每行格式 `<ISO8601 UTC> tid=<线程id> evt=<事件> pool=0x<帧池指针> <detail>`，用裸 Win32 `CreateFileW`/`WriteFile`（崩溃 filter 路径零 CRT/STL 堆分配），写进固定路径 `%LOCALAPPDATA%\Hibiki\wgc_capture.log`（native 自决，不依赖 Dart 下发——避免「下发前 capture 已发生」的时机赌注；LocalAppData 始终可写无 Program Files 权限问题）。文件超 512KB 自动截断保留尾部。

2. **texture_bridge.cc 关键生命周期点埋点**——`create-bridge` / `dtor` / `start`（含 is_running 态）/ `create-pool`（记录新池指针）/ `createSession-fail` / `startCapture-fail`（第九/十修指出的「静默早返回」点补可观测）/ `recreate` / `stop` / `retire`（**核心取证证据**：记录被退役保活的帧池指针——崩溃帧池指针若能在 retire 行找到 = 已保活，找不到 = 又有漏网路径裸释放，直接定位第四条漏洞）。`OnFrameArrived` 仅在 `TryGetNextFrame` **失败**时写 `frame-getfail`（成功路径每帧 fire，**禁止每帧刷盘**——守卫测试钉死）。

3. **进程级 minidump 安装**——`hibiki/windows/runner/crash_dump.{h,cpp}`，`main.cpp` 在 `CoInitializeEx` / Flutter engine 之前调 `InstallCrashDumpHandler()`：`SetUnhandledExceptionFilter` + 动态加载 `MiniDumpWriteDump`，把 dump 主动写进 `%LOCALAPPDATA%\Hibiki\crashdumps\hibiki-<pid>-<tick>.dmp`（与 wgc_capture.log 同根，便于一次性打包上传），**不再赌系统 WER**。写完自家 dump 后**链回前一个 filter**（保存 `g_previous_filter`），不抢占 Flutter engine 既有 crash handler。dump 类型 `MiniDumpWithThreadInfo | IndirectlyReferencedMemory | UnloadedModules`——足够 cdb `!analyze -v` 解 GraphicsCapture 偏移 + `!vprot` 验崩溃帧池内存状态，体积可控便于上传。

4. **Dart 折入上传链路**——`hibiki/lib/src/utils/misc/wgc_capture_log.dart`：启动时（`ErrorLogService.init` 之后）把上次运行残留的 WGC 日志读出折进 `ErrorLogService`（用户在「错误日志」页即可看到 + 经现有 `uploadLogToServer` 上传），读后清空文件（滚动语义，与导入面包屑「读后清」一致）。两端硬钉同一确定路径 `%LOCALAPPDATA%\Hibiki\`（Dart 读环境变量 `LOCALAPPDATA`，native 用 `SHGetKnownFolderPath(FOLDERID_LocalAppData)`），无 bundle id 推测、无 MethodChannel 时序耦合。

- **[x] ① 已实现** —— 新增 `wgc_log.{h,cpp}`（始终编译结构化日志）、`crash_dump.{h,cpp}`（minidump 安装）、`wgc_capture_log.dart`（Dart 折入）；texture_bridge.cc 10 处生命周期埋点；CMakeLists（plugin + runner）加新源文件；main.cpp 安装 handler + main.dart 折入。commit 见提交说明。
- **[x] ② 已加自动化测试** —— `hibiki/test/utils/wgc_capture_log_test.dart`（Dart 行为：路径定位 + 读后清滚动语义，host 可跑）+ `hibiki/test/widgets/wgc_capture_logging_guard_test.dart`（源码守卫：日志始终编译不被 NDEBUG 门控、关键生命周期点埋点、FrameArrived 成功路径不每帧写、crash dump handler 在 CoInitializeEx 前安装且链回前一个 filter、Dart 折入上传链路）。`flutter test` 两文件 10 例全绿；既有 `texture_bridge_stop_guard_test.dart` 仍绿（埋点未破坏第十修保活契约）。
- **验证**：①Dart 侧 `flutter analyze --no-pub` 4 文件 0 issue + 上述测试全绿。②**原生 C++ 改动（wgc_log / crash_dump / texture_bridge 埋点 / 两个 CMakeLists）host 无法编译验证**——需 Windows `flutter build windows --release` 真机构建。③**真机取证待用户**：装新 Release 包，复现原始失败路径（看有声书 / 开 EPUB → 反复查词 / 开关弹窗 WebView → resize），崩溃后取 `%LOCALAPPDATA%\Hibiki\wgc_capture.log`（崩前帧池 create/retire/stop/recreate 时间线 + pool 指针）+ `%LOCALAPPDATA%\Hibiki\crashdumps\*.dmp`（cdb `!analyze -v` + `!vprot` 验崩溃帧池指针是否在 wgc_capture.log 的 retire 行出现过）。
- **诚实标注**：本修**不修复崩溃本身**（第十修已逻辑闭合所有已知帧池裸释放窗口，逐行复核 `~TextureBridge`/`Start`-fail/`Recreate`-fail 三路径在第十修后都经 `RetireFramePoolLocked` 兜底退役保活，无新增 UAF），而是**为「若仍复发」提供决定性自证证据**：日志记录崩前帧池生命周期 + 崩溃帧池指针，minidump 记录精确崩点。若真机仍崩，可凭这两份证据立即判定「崩溃帧池是否走了退役保活」，定位是否还有第十修漏网的第四条帧池路径——终结「论证对了真机仍复发但拿不到证据」的循环。

### 第十二修（active frame pool 从 create 起强保活，TODO-439，2026-06-16）

**复发证据**：本机 `D:\APP\vs_claude_code\hibiki\.codex-test\todo-439-wgc-20260616\summary.md` 记录，`hibiki.exe 0.9.0.5025` 仍崩在同一签名：`GraphicsCapture.dll` `c0000005` offset `0xf0d5`，栈为 `Direct3D11CaptureFramePool::FirePresentEvent -> TypedEventHandler::operator()+0x15`，`rcx=0`。崩溃 pool `0x1ebe1f96148` 能与 captureLog 第二轮 `create-pool` 对应；dump 中该 pool 已 `MEM_FREE`，但日志没有该 pool 的 `stop` / `retire` / `dtor`，只有 `start running=1` 与 `recreate-skip-samesize`。

**第十一修后的新结论**：第十修和第十一修已经把 Stop/Recreate/失败重入等退役路径打通，但进程级强引用仍只在 `RetireFramePoolLocked()` 后建立。TODO-439 的日志反证：崩溃池不是「已 retire 的 closed pool」，而是一个 active/running pool 在没有退役日志的情况下失去最后强引用或被裸释放。因此唯一不变量需要再上移：**任何即将注册 `FrameArrived` 的 pool，从 `CreateCaptureFramePool` 后立刻进入进程级 registry 强保活，直到进程退出都不会 `MEM_FREE`**。`RetireFramePoolLocked()` 仍负责 `remove_FrameArrived`、`Close` 帧池释放 GPU 资源、设置 closed-flag，并保留 closed pool 永久保活。

**第十二修实现**：
- **[x] ① 根因修复** —— `RetiredFramePoolRegistry` 新增 active retained 列表和 `RetainActive()`；`CreateAndStartFramePoolLocked()` 在 `create-pool` 后、`add_FrameArrived` 前立即 `RetainActive(frame_pool_)`，并写 `active-retain` 日志。这样 `start running=1` 早返回、同尺寸 `recreate-skip-samesize`、或未来发现的非 retire 裸释放路径，都不能让曾注册 `FrameArrived` 的 active pool 变成 `MEM_FREE`。Stop/Recreate 仍走 `RetireFramePoolLocked()` Close session/pool 释放 GPU 资源，不恢复 FreeThreaded，不恢复裸 `frame_pool_->Recreate(`。
- **[x] ② 自动化测试** —— `hibiki/test/widgets/texture_bridge_stop_guard_test.dart` 加 TODO-439 守卫：建池后必须 `create-pool -> RetainActive -> active-retain -> add_FrameArrived`；registry 必须有 active retain 存储；Stop 必须写 `handler-release`，Retire 必须写 `retire-close`，析构必须写 `dtor-enter` / `dtor-exit`。先红后绿。

**验证边界**：源码守卫和 Windows debug 插件目标构建能证明契约与本轮 native 插件编译成立；完整 `flutter build windows --debug` 本机卡在 CMake install prefix 指向 `C:/Program Files/hibiki` 的权限问题，非本轮 C++ 编译错误。WGC 延迟 UAF 的真正消失仍需 Windows Release/Debug 实机反复走原路径（看有声书 / EPUB -> 反复查词 / 弹窗开关 / resize）并结合 `%LOCALAPPDATA%\Hibiki\wgc_capture.log` 与 crash dump 收口。active registry 会让每个曾建池的 COM 壳保留到进程退出；active 状态下 GPU 资源本来就仍属当前池，Stop/Recreate 时仍显式 Close 释放 GPU 资源，残留是进程级小 COM 壳引用增长。

### 第十三修（TODO-453 日志把失败窗口缩进 RetireFramePoolLocked，2026-06-17）

**复发证据**：TODO-453 是 TODO-439 的同链路新证据，不作为独立新 bug 并行施工。用户日志已经出现 TODO-439 新事件 `active-retain`、`retire-close`、`handler-release`、`dtor-enter`、`dtor-exit`，说明用户运行到含第十二修日志的版本；前三轮 pool teardown 都完整闭合。最后一轮 `pool=0x22d401dd7b8` 在 `create-pool -> active-retain -> recreate-skip-samesize` 后，只记录到 `stop` 和 `retire`，缺 `retire-close`、`handler-release`、`dtor-enter`、`dtor-exit`。本机未找到对应新 crash dump，无法直接按 cdb 核 `GraphicsCapture.dll+0xf0d5` 与 FramePool 内存状态；当前根因判断来自 WGC 结构化日志的收口缺口。

**新根因窗口**：第十二修证明 active pool 已从 create 起保活，问题不再是 create 后未 retain。现有代码在 `RetireFramePoolLocked()` 中先写 `retire`，再 `remove_FrameArrived`，最后才 `IClosable::Close` 写 `retire-close`。TODO-453 停在 `retire` 后、`retire-close` 前，说明风险已缩到 remove/Close 之间。若 `remove_FrameArrived` 内部触发/重入已排队的 `FirePresentEvent`，此时 closed-flag 还没设置，迟到事件仍可能进入 event fire；即使没有崩，缺少 remove/Close/registry/handler release 前后日志也无法判断到底卡在哪个 HRESULT 或 COM 调用里。

**第十三修实现**：
- **[x] ① 根因修复** —— `RetireFramePoolLocked()` 调整为先 `IClosable::Close` 设置 closed-flag，再 `remove_FrameArrived`，最后 `RetiredFramePoolRegistry::Retire(std::move(frame_pool_))`。这样 remove 期间任何迟到/重入 `FirePresentEvent` 都会先因 closed-flag no-op，不再在 event 表仍可变时进入 null-delegate 路径。`Close` / `remove_FrameArrived` 的 HRESULT 均记录；失败不短路退役保活，继续把 pool 移进 registry，避免半拆状态。
- **[x] ② 自动化测试** —— `texture_bridge_stop_guard_test.dart` 改为要求 `retire-close-start -> Close -> retire-close/retire-close-fail -> retire-remove-start -> remove_FrameArrived -> retire-remove/retire-remove-fail -> retire-register-start -> Retire -> retire-register`；同时要求 `handler-release -> handler-release-done`。`wgc_capture_logging_guard_test.dart` 补守新日志事件。两项均先红后绿。

**验证边界**：本轮仍未拿到 TODO-453 对应 crash dump；若用户再复发，新日志应能精确区分停在 `retire-close-start` 前、Close 内部、remove 内部、registry 移交或 handler release 前后。合格日志不只要求 active retain，还要求每个 pool 最终有 `retire-close`（或 `retire-close-fail`）、`retire-remove`（或 `retire-remove-fail`）、`retire-register`、`handler-release-done`、`dtor-exit`，并且 crash dump 不再出现 BUG-209 的 `GraphicsCapture.dll+0xf0d5` 签名。

### 第十四修（Close 后 remove best effort，TODO-463/TODO-465，2026-06-17）

**复发证据**：0.9.15 的三段 captureLog（TODO-463 两段、TODO-465 一段）均完整写到 `retire-close-start -> retire-close hr=0x00000000 -> retire-remove-start`，随后没有 `retire-remove`、`retire-register-start`、`retire-register`、`handler-release-done`。对应 dump（例如 `hibiki.exe.140208.dmp` / `hibiki.exe.100408.dmp`）显示 `GraphicsCapture!Direct3D11CaptureFramePool::CheckClosed` 在 `remove_FrameArrived` 内抛 `RO_E_CLOSED/0x80000013`，异常未被 native plugin 捕获后走 terminate/abort。第十三修先 Close 压住了旧的 remove/Close 窗口，但也暴露出新的 API 契约：已 Close 的 WGC frame pool 不能再裸 remove。

**第十四修实现**：
- **[x] ① 根因修复** —— `RetireFramePoolLocked()` 保持先 Close 设 closed-flag，再把 `remove_FrameArrived` 改成 best effort：返回 `S_OK` 记录 `retire-remove`，返回或抛 `0x80000013` 记录 `retire-remove-closed`，其它 HRESULT 记录 `retire-remove-fail`；没有 token 时记录 `retire-remove-skipped`。所有分支都清 token 并继续 `retire-register-start -> RetiredFramePoolRegistry::Retire(std::move(frame_pool_)) -> retire-register -> frame_pool_=nullptr`，随后 `StopInternal()` 继续 `handler-release -> handler-release-done`。
- **[x] ② 自动化测试** —— `hibiki/test/widgets/texture_bridge_stop_guard_test.dart` 增加 Close 后 remove 必须受 `try/catch (const winrt::hresult_error&)` 保护、必须记录 `retire-remove-closed` / `retire-remove-skipped`、异常后仍继续 registry 保活；`hibiki/test/widgets/wgc_capture_logging_guard_test.dart` 增加新日志事件守卫。

**验证边界**：源码守卫能证明 Close 后 remove 不再因 `winrt::hresult_error` 阻断退役流程，Windows release 构建能证明 native 编译通过。真正验收仍需用户或 PM 在 Windows 上走原始路径复测：若再次生成 `wgc_capture.log`，合格日志应在 `retire-remove-start` 之后继续出现 `retire-remove-closed`（或 success/fail/skip）、`retire-register`、`handler-release-done`，不应再停在 `retire-remove-start`。

### 第十五修（TODO-468/TODO-472：remove-before-close 生命周期重构，2026-06-17）

**第十四修为何只是止血**：TODO-463/TODO-465 的 `892a711` 能避免 Close 后 `remove_FrameArrived` 抛 `RO_E_CLOSED/0x80000013` 时直接 terminate，但它把 `retire-remove-closed` 当成可接受正常路径，成功释放 handler/token 之前已经 Close pool。用户明确不接受“崩溃和小泄漏二选一”：正常路径必须既不崩，也不长期 retained delegate。

**第十五修实现**：
- **[x] ① 根因修复** —— `texture_bridge.cc/.h` 把 `frame_pool`、`capture_session`、`FrameArrived` token、handler、callback state、size/generation、retiring/removed/closed 状态聚合为 `WgcFramePoolLifetime`。`TextureBridge` 只持当前 active lifetime；进程级 `FramePoolLifetimeRegistry` 用单一 `lifetimes_` 列表从 create 起保活对象，并用 lifetime 状态计算 `active=N retired=N`，不再用无语义 `active_`/`retired_` 双列表重复持有。
- **[x] ② 正常退役顺序** —— `RetireFramePoolLocked(reason)` 先写 `state-inactive` 并断开 callback state，再在 frame pool 仍 open 时 `remove_FrameArrived(token)`；成功后清 token、释放 handler 并写 `handler-release-done`；随后 Close `capture_session`、Close `frame_pool`；最后 `MarkRetired(lifetime)`，写 `registry-size active=N retired=N` 与 `retire-register-done`。正常日志应看到 `remove-before-close-done` 早于 `pool-close-start`，不再出现 `retire-remove-closed`。
- **[x] ③ handler 栈内退役** —— FrameArrived handler 进入时自持 lifetime 并设置 `in_handler`；如果 resize 或 stop 在该回调栈内触发退役，不直接 remove，而是写 `retire-defer-in-handler` 并把 finalize 投递到创建该 pool 时记录的同一 `DispatcherQueue` 下一拍，避免 event 迭代重入。
- **[x] ④ fail closed** —— `remove` 失败时写 `remove-before-close-fail` 或 `remove-before-close-closed-unexpected`，保留 token/handler/pool 作为异常证据，不假装释放；随后仍关闭 session/pool 并把 lifetime 标为 retired 保活，避免崩溃和半拆状态。
- **[x] ⑤ 自动化测试** —— `texture_bridge_stop_guard_test.dart` 改为守住新顺序、handler 栈内 defer、单一 lifetime registry、禁止裸 `frame_pool_->Recreate(` / 裸 `frame_pool_ = nullptr` / `retire-remove-closed` 正常路径；`wgc_capture_logging_guard_test.dart` 改为要求 `remove-before-close-*`、`handler-release-*`、`session-close-*`、`pool-close-*`、`registry-size` 等日志，且断言 `remove-before-close-done -> handler-release-done -> pool-close-start`。

**验证边界**：源码守卫和 Windows native `ALL_BUILD` 已证明本轮 C++ 编译链接通过；`flutter build windows --release` 仍在 `INSTALL.vcxproj` 阶段因安装前缀权限失败，非本轮 native 编译错误。真正用户级验收仍需 Windows 上反复走原始路径（视频退出、WebView 弹窗/阅读器 resize），检查 `%LOCALAPPDATA%\Hibiki\wgc_capture.log`：正常退役应有 `remove-before-close-done`、`handler-release-done`、`pool-close-done`、`registry-size active=... retired=...`，不得出现 `retire-remove-closed` 或 `remove-before-close-fail`；同时不应再产生 `GraphicsCapture` `c0000409/RO_E_CLOSED` dump。
