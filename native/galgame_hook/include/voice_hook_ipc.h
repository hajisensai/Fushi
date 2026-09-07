#ifndef FUSHI_VOICE_HOOK_IPC_H_
#define FUSHI_VOICE_HOOK_IPC_H_

#include <windows.h>

#include <cstdint>
#include <cstring>
#include <string>

#include "luna_version.h"
#include "thread_preview_ipc.h"

// galgame 一键制卡 C 阶段（docs/specs/galgame-mining）—— 引擎级 voice hook 的**进程间契约**。
//
// 部署红线：这套 injector + hook DLL 是**独立可选 helper 组件**，和 `hibiki.exe` 物理隔离、
// 分离分发（`CreateRemoteThread`/`WriteProcessMemory` 注入必被杀软启发式报毒，编进本体会污
// 染整个 app 的分发口碑）。Hibiki 主进程把 injector 当子进程拉起、通过下面这块共享内存消费
// 干净语音 PCM——被标记的注入代码只待在这个隔离组件里。
//
// 数据流（混音前的干净语音轨）：
//   game.exe 内的 hook DLL：在 XAudio2/DirectSound 把语音送进混音**之前** memcpy 进环形缓冲
//     → 只在音频回调里 memcpy + 更新 write_pos（零阻塞：写盘/编码/IPC 全部移出回调，爆音红线）
//   共享内存：header + 紧随其后的 PCM 环形缓冲
//   Hibiki host（经 injector）：读环形缓冲最近 N 毫秒 → 波形选区 → 制卡出口（复用 A 阶段流水线）
namespace fushi_voice_hook {

// 共享内存魔数 'HVH1'（小端）与当前契约版本。跨进程读到不匹配即拒绝，防旧/坏映射。
constexpr uint32_t kSharedMagic = 0x31485648;  // 'H''V''H''1'
// v2：在 v1 音频环形之外加「文本环」(hook 抓的台词行) + 「语音 clip 索引」(按句切的语音片段)。
// 全自动制卡：文本 hook 出一句 + voice hook 出对应那条语音 clip → 按时间戳配对 → 点+一键出卡。
// v6：在 clip 索引之后再加「loopback 混音环」+「时间戳↔环位置标记表」。作为没有引擎专属纯人声
//     hook 的游戏（Atelier Kaguya、未识别引擎等）的**兜底**——WASAPI loopback 抓系统渲染端点的
//     最终混音（voice+BGM），按文本时刻抽窗口做卡。与引擎级纯人声路径并存，互不干扰。
// v9：合并 v8 的引擎诊断/Unity 资源事件与 v6 的 loopback 环。
// v10：文本槽追加事件类型，透传 Luna ThreadCreate，使尚无台词的候选线程也可被选择。
// v11：显式声明稳定 IPC、Luna bridge ABI 与 vendored Luna 版本，host 可在读数据前拒绝错配。
// v12：追加「线程预览区」，并取消 injector 自动替用户选线程。
//     旧结构里文本环是**唯一**的文本出口，同时伺候两个诉求相反的消费者：语音配对要高信噪的
//     单条线程，线程选择器要每条线程都有样本。二者共用一块 256 槽全局 FIFO，于是"让所有 hook
//     都发布"必然把配对候选挤出环（kExpired → 降级 loopback，即 BUG-1159 的失败链），这才是
//     BUG-1193 真正的根因——不是门控本身。v12 把两个消费者拆到两块内存：
//       * 文本环（Ring A）：语义不变，仍只发布**当前生效线程**的行，配对路径逐字节不受影响；
//       * 线程预览区（本区）：每条线程各占**固定槽位**，只留最近一行。Luna 与游戏内
//         native adapter 使用互斥槽分区，跨进程 writer 不会争抢同一槽。
//     预览区按线程分槽而不是全局 FIFO，所以逐字重绘型 hook 只能覆盖它自己的槽，**物理上挤不掉
//     别的线程**——"挤压"从"要小心防"变成结构上不可能，这正是自动赢家门控得以退役的前提。
// v13：文本区从**一块 256 槽全局 FIFO**改成**按线程分道**，并取消采集期的选定线程过滤。
//     v12 只把"线程选择器"这个消费者搬进了按线程分槽的预览区；文本环本身仍是全局 FIFO，
//     它当时不被挤爆，只是因为**同一时刻只有一条线程在写**（未选定就一行都不发），不是
//     结构上挤不动。所以"放开非胜出线程"在 v12 上依然会复现 BUG-1159 的失败链：逐字重绘型
//     hook 几秒刷穿 256 槽 → 配对候选被挤出环 → kExpired → 整段降级 system_loopback。
//     v13 让每条线程写**自己那条道**，道内覆盖只吃掉自己的旧行，物理上挤不掉别人：
//       * 道下标与线程预览槽下标**取同一个值**，认领沿用预览区那套跨进程互斥分区
//         （Luna 在 injector 进程用低段，游戏内 native adapter 用高段），认领逻辑只有一份；
//       * TextSlot::seq 仍是**全局发布序**（host `pollText(fromSeq)` 契约逐字节不变），
//         新增 lane_seq 作道内完成标记；
//       * selected_text_thread_id 从"采集期过滤器"降级为"消费期指定"：native 不再丢弃任何
//         行，只由消费方（host 的文本消费点、游戏内 kirikiri 配对候选扫描）决定取哪条道。
//         这同时解开了旧方案的死结——Dart 回写选定线程不再等于让 native 重新开始丢行。
// v14：追加**游戏内查词区**（hit / input / frame 三通道，见下方 kLookup* 与 LookupHitSlot）。
//     纯追加：放在布局最尾，前面所有区偏移逐字节不动；lookup_region_offset==0 即"本会话
//     没有此区"，旧 host 读到 v14 映射也不会错位（版本号仍会先挡，这只是纵深防御）。
// v15：追加游戏内卡片的**截图抑制确认**：host 发布 kLookupFrameCaptureSuppress 后，hook
//     在游戏线程隐藏 card/highlight，并等到下一次 continuous callback 才回写
//     lookup_frame_applied_seq。host 只有看到该确认才能抓游戏窗口；发布成功不等于游戏渲染树
//     已经干净，拿普通 dismiss 的 MethodChannel 返回值当屏障会稳定把 popup 拍进卡片图片。
// v16：在头部最尾追加 injected WASAPI loopback 的 fail-closed 控制/确认。旧实现只门控
//     Hibiki 宿主进程里的 loopback，却让游戏内 DLL 一加载就无条件创建另一个系统混音捕获线程；
//     cleanOnly/resourceOnly 因而仍会录音。request_seq 最后发布请求，applied_seq 最后确认
//     Stop/Release/线程退出；版本不匹配时 DLL 拒绝映射，旧 helper 不能绕过默认 deny。
// v17：在头部最尾追加**本次注入所用 hook DLL 的 SHA-256**（`hook_module_sha256`）。
//     写者是创建该映射的 injector（只在新建映射、memset 清零之后写一次）；读者是**下一次**
//     injector——它见到已存在的映射时，拿 header 里这条记录跟本次请求 DLL 现算的摘要比。
//     为什么磁盘摘要不够：驻留身份判据先比路径，路径不等直接 kPathMismatch，所以能走到
//     摘要比较时两条路径已经相等；此时若两侧都用 Sha256File 读磁盘，读的是同一个文件，
//     摘要恒等，kDigestMismatch 永不可达。而这道门要挡的恰恰是「Fushi 自更新把磁盘上那份
//     DLL 换成新构建、游戏进程里仍驻留旧映像」——路径没变、磁盘上是新文件，磁盘里根本
//     不含「进程里驻留的是哪个构建」这条信息。它只存在于当初完成注入的那一方，所以必须
//     由注入者在建映射时留档。纯尾部追加：前面各区偏移逐字节不动。
// v18：`LookupInputSlot::keys` 的**取值语义**换成 WebView2 的
//     COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS（Shift=4 / Ctrl=8 / 没有 Alt 位），
//     不再是旧的 Shift=1 / Ctrl=2 / Alt=4 自定义压缩表。布局一字节没动，正因为如此
//     才必须靠版本号挡：v17 helper + v18 host 时，玩家按住 Shift 会被 host 读成
//     kLookupInputVirtualKeyLeftButton 塞给 SendMouseInput，move 事件被 WebView2
//     当成拖拽，症状是「按住 Shift 划过卡片就开始拖选」而不是任何显式错误。
//     BUG-1881 已经证明「Windows Debug 构建残留旧 helper」是真实发生过的场景，所以
//     这种**同布局、异语义**的变更同样要升版本：跨进程契约的版本号锁的是解释方式，
//     不只是偏移。升到 18 之后旧 helper 建的映射会在三处既有门被拒（host 的
//     ProtocolMatches、DLL 的 header 校验、injector 的驻留映射复用判据）。
// v20：本版把两条并行开发的 v19 合成一版。它们各自都叫 v19，但布局不兼容——
//     一条是尾部纯追加（偏移不动），另一条改了 LookupHitSlot 步长与 SharedHeader
//     长度。停在 19 就意味着任一边的旧 helper 建的映射会被三处版本门判成「对得上」，
//     然后按错误偏移读；读到的不是空值而是垃圾。所以合并即升版本，两边内容都在：
//
//     (a) 查词命中槽增加几何 provider、UTF-16 source span、文本/几何代际、坐标域与
//     书写方向；SharedHeader 尾部追加单一几何 provider 状态和统一输入盾 request/status
//     控制块。命中仍是单槽 latest-wins，但只能经 GeometryProviderRegistry 发布：payload
//     先写，seq 最后写，禁止不同 provider 的文本和几何拼接。输入盾 request_seq 同 v16
//     loopback 使用最高位写令牌；状态先发布 required/ready/observed/fault/status，
//     applied_seq 最后确认。
//
//     (b) 尾部追加查词准入区（lookup_admission / lookup_admission_seq /
//     lookup_executable_sha256）。host 拿 admission 决定「开关要不要置灰、给用户看
//     什么原因」，旧 helper 建的段那三个字节区是**未初始化内存**而不是
//     kLookupAdmissionUnknown，读它等于拿垃圾值去误导用户。
//
//     (c) 新增 xaudio_diagnostics2：原 xaudio_diagnostics 的 32 位在本次合并中被
//     两边的新引擎位同时要走（HUNEX HFA 5 位 + SGRE 家族/锚点 3 位，而低 27 位早已
//     占满）。按本结构体既有先例（reserved_luna 满了之后另立 reserved_hook_diagnostics）
//     另立一个字，而不是拓宽——拓宽要改 InterlockedOr 的原子写路径与每个读侧。
// v21：`lookup_geometry_admission_flags` 的 0x2 位从 v20 的保留位变成
//     NativeInputAllowed。lookup_enabled 只负责让文本/几何传感器继续工作；
//     native provider 即使已经被 registry 选成 Ready owner，也只有在 host
//     通过风险准入并显式发布这一位后才可吞掉游戏点击。
//     布局和偏移完全不变，但解释方式已经改变：v20 hook 只认识
//     AttachedReady，v21 host 则依赖 0x2 对语义输入消费与 native hit 发布做
//     fail-closed 门控。同布局、异语义仍必须升版（与 v18 的
//     LookupInputSlot::keys 完全同理），否则旧 helper 会被版本门误判兼容，
//     host 以为已撤销输入而驻留 DLL 仍继续消费。
//  v22 — BUG-2136 引擎层原点双向面。SharedHeader 尾部在 v19 摘要之后**纯追加**了
//     12 个 32 位字（hook→host 的行包围盒 + 设计分辨率 + 字形数，host→hook 的
//     解出原点 + seq）。**布局变了就必须升版**：`hook/dll_main.cpp` 与
//     `injector/injector_main.cpp` 都用 `sizeof(SharedHeader)` 现算 ring / region
//     基址，新旧混装会整体差 48 字节，而版本门本会放行——症状是跨进程读到完全
//     错位的数据，不报错。
//  v23 — adapter 运行期读数（BUG-2149）。SharedHeader 尾部**纯追加**一张
//     `AdapterReportSlot adapter_reports[kAdapterReportSlots]` + count + seq。
//     动机：`AdapterDiagnostics`（id/applicable/installed/flags）每个 adapter 都实现了，
//     但全仓只有 `tests/adapter_contract_test.cpp` 在读——运行期没有任何消费方，于是
//     **任何引擎**都答不出「我的 adapter 到底有没有被选中并安装」。CMVS 台账里那条
//     Next gate「探针 cmvs probe=1 installed=1」读不出来，不是探针失败，是这个只写
//     接口的表现。
//     槽里带**自己的 id 字符串**而不是按注册顺序编号：顺序编号在有人往
//     `hook/generated/adapter_*.inc` 中间插一行时会整体错位，而且**不报错**——
//     读数看着正常，说的却是另一个 adapter。
//     与 v22 同理，布局变了就必须升版（两侧都用 `sizeof(SharedHeader)` 现算 ring /
//     region 基址，新旧混装会整体错位而版本门本会放行）。
constexpr uint32_t kSharedVersion = 23;
constexpr uint32_t kStableIpcVersion = 1;

// BUG-1882 — SGRE 的鼠标输入走 DirectInput immediate state，不经过普通
// Win32 mouse-message 队列。direct galCard 因此需要一条很窄的跨进程发布面：
//
//   * injected SGRE adapter 先把 Required 置 1，声明该精确游戏不允许退回已经
//     证伪的 HHOOK-only 路径；GetDeviceState detour 真正就绪后才最后提交 Ready；
//   * Fushi 看到 Required 但没有 Ready 时 fail closed；只有 Ready 同时存在才把
//     当前 direct popup HWND 发布到游戏 HWND；
//   * detour 只接受仍存在、且 owner 正是游戏 HWND 的该 popup，随后仅清
//     DIMOUSESTATE2::rgbButtons，绝不碰 lX/lY/lZ。
//
// HWND 自带进程崩溃生命周期：Fushi 退出后窗口会被系统销毁，注入侧即使看到陈旧
// property 也会因 IsWindow/GW_OWNER 校验而 fail open，不会把游戏永久锁死。这里没有
// 改 SharedHeader 布局，所以不升 kSharedVersion；两端共享名字只是为了杜绝手抄漂移。
inline constexpr wchar_t kSgreDirectInputShieldReadyProperty[] =
    L"Fushi.SGRE.DirectInputShield.Ready";
inline constexpr wchar_t kSgreDirectInputShieldRequiredProperty[] =
    L"Fushi.SGRE.DirectInputShield.Required";
inline constexpr wchar_t kSgreDirectInputShieldWindowProperty[] =
    L"Fushi.SGRE.DirectInputShield.Window";
inline constexpr uintptr_t kSgreDirectInputShieldReadyValue = 1u;
inline constexpr uintptr_t kSgreDirectInputShieldRequiredValue = 1u;

// Exact anemoi/Siglus uses GetKeyState(VK_LBUTTON) as an immediate sampled
// input source.  WH_MOUSE_LL can remove Win32 mouse messages, but it cannot
// change that physical key-state sample, so the direct WebView route needs the
// same fail-closed Required -> Ready -> Window publication shape as SGRE.  Keep
// a distinct property namespace: the admitted hook ABI is GetKeyState rather
// than DIMOUSESTATE2, and an old host that only understands SGRE must not
// mistake one contract for the other.
inline constexpr wchar_t kSiglusSampledInputShieldReadyProperty[] =
    L"Fushi.Siglus.SampledInputShield.Ready";
inline constexpr wchar_t kSiglusSampledInputShieldRequiredProperty[] =
    L"Fushi.Siglus.SampledInputShield.Required";
inline constexpr wchar_t kSiglusSampledInputShieldWindowProperty[] =
    L"Fushi.Siglus.SampledInputShield.Window";
inline constexpr uintptr_t kSiglusSampledInputShieldReadyValue = 1u;
inline constexpr uintptr_t kSiglusSampledInputShieldRequiredValue = 1u;

// Exact WHITE ALBUM2 / Leaf-AQUAPLUS samples GetAsyncKeyState directly.  A
// low-level mouse hook can swallow the corresponding Win32 messages, but it
// cannot hide the physical high/low bits from that poller.  Give this distinct
// ABI its own Required -> Ready -> Window namespace while reusing the host's
// sampled-input transaction lifetime.  Unknown Leaf builds never publish
// Required because executable admission remains hash-pinned in the adapter.
inline constexpr wchar_t kLeafAquaplusSampledInputShieldReadyProperty[] =
    L"Fushi.LeafAquaplus.SampledInputShield.Ready";
inline constexpr wchar_t kLeafAquaplusSampledInputShieldRequiredProperty[] =
    L"Fushi.LeafAquaplus.SampledInputShield.Required";
inline constexpr wchar_t kLeafAquaplusSampledInputShieldWindowProperty[] =
    L"Fushi.LeafAquaplus.SampledInputShield.Window";
inline constexpr wchar_t kLeafAquaplusSampledInputShieldTailRequestProperty[] =
    L"Fushi.LeafAquaplus.SampledInputShield.TailRequest";
inline constexpr wchar_t kLeafAquaplusSampledInputShieldTailAckProperty[] =
    L"Fushi.LeafAquaplus.SampledInputShield.TailAck";
inline constexpr uintptr_t kLeafAquaplusSampledInputShieldReadyValue = 1u;
inline constexpr uintptr_t kLeafAquaplusSampledInputShieldRequiredValue = 1u;

// Exact HUNEX/GGE profiles also sample GetAsyncKeyState directly. Keep a
// distinct namespace from Leaf/AQUAPLUS: both adapters own the same USER32
// export, but their executable admission and detour callsites are unrelated.
// The tail request/ack pair keeps the sampled low bit hidden until the engine
// has observed a later neutral poll, so a lookup click cannot advance the
// game after the popup has already been dismissed.
inline constexpr wchar_t kHunexGgeSampledInputShieldReadyProperty[] =
    L"Fushi.HunexGge.SampledInputShield.Ready";
inline constexpr wchar_t kHunexGgeSampledInputShieldRequiredProperty[] =
    L"Fushi.HunexGge.SampledInputShield.Required";
inline constexpr wchar_t kHunexGgeSampledInputShieldWindowProperty[] =
    L"Fushi.HunexGge.SampledInputShield.Window";
inline constexpr wchar_t kHunexGgeSampledInputShieldTailRequestProperty[] =
    L"Fushi.HunexGge.SampledInputShield.TailRequest";
inline constexpr wchar_t kHunexGgeSampledInputShieldTailAckProperty[] =
    L"Fushi.HunexGge.SampledInputShield.TailAck";
inline constexpr uintptr_t kHunexGgeSampledInputShieldReadyValue = 1u;
inline constexpr uintptr_t kHunexGgeSampledInputShieldRequiredValue = 1u;

// smash/fzmedia (TYPE-MOON smash framework, GLFW30 window) consumes clicks in
// a GWLP_WNDPROC subclass of the game window rather than in a sampled-state
// detour, but it declares the same Required/Ready/Window contract so the host
// keeps one publication lifetime: Required = the runtime is installed and
// expects the host to wait for Ready; Ready = the subclass is live and
// swallowing client-area left down/up while a card is published in Window.
// No tail handshake: message consumption has no sampled low bit to drain.
inline constexpr wchar_t kSmashFzmediaSampledInputShieldReadyProperty[] =
    L"Fushi.SmashFzmedia.SampledInputShield.Ready";
inline constexpr wchar_t kSmashFzmediaSampledInputShieldRequiredProperty[] =
    L"Fushi.SmashFzmedia.SampledInputShield.Required";
inline constexpr wchar_t kSmashFzmediaSampledInputShieldWindowProperty[] =
    L"Fushi.SmashFzmedia.SampledInputShield.Window";
inline constexpr uintptr_t kSmashFzmediaSampledInputShieldReadyValue = 1u;
inline constexpr uintptr_t kSmashFzmediaSampledInputShieldRequiredValue = 1u;
inline constexpr uint32_t kLeafAquaplusSampledInputLeftButton = 0x1u;
inline constexpr uint32_t kLeafAquaplusSampledInputRightButton = 0x2u;
inline constexpr uint32_t kLeafAquaplusSampledInputMiddleButton = 0x4u;
inline constexpr uint32_t kLeafAquaplusSampledInputButtonMask = 0x7u;
// Cross-process completion notification sent by the injected Leaf detour after
// every requested GetAsyncKeyState low bit has been observed and a later raw-0
// sample proves the transaction tail is drained. WM_APP is fixed at 0x8000.
inline constexpr uint32_t kSampledInputShieldReleaseWindowMessage = 0x8053u;

inline constexpr uint32_t MakeLeafAquaplusSampledInputTailToken(
    uint32_t generation, uint32_t buttons) {
  return ((generation & 0x1fffffffu) << 3u) |
         (buttons & kLeafAquaplusSampledInputButtonMask);
}

inline constexpr uint32_t LeafAquaplusSampledInputTailButtons(
    uint32_t token) {
  return token & kLeafAquaplusSampledInputButtonMask;
}

// v16 native loopback policy/control ABI. Only the exact value 1 authorises
// creation of the loopback worker; zero and every unknown value are deny.
constexpr uint32_t kNativeLoopbackDeny = 0;
constexpr uint32_t kNativeLoopbackAllow = 1;
constexpr uint32_t kNativeLoopbackStateStopped = 0;
constexpr uint32_t kNativeLoopbackStateStarting = 1;
constexpr uint32_t kNativeLoopbackStateRunning = 2;
constexpr uint32_t kNativeLoopbackStateStopping = 3;
constexpr uint32_t kNativeLoopbackStateFailed = 4;
constexpr uint32_t kNativeLoopbackRequestWriteInProgress = 0x80000000u;
constexpr uint32_t kNativeLoopbackRequestSequenceMask = 0x7fffffffu;

// loopback_diag is sticky observation only; policy truth lives in the four
// v16 fields below. 0x20 is set immediately before IAudioClient::Initialize,
// so a remote probe can distinguish "thread existed" from the
// privacy-sensitive AUDCLNT_STREAMFLAGS_LOOPBACK call.
constexpr uint32_t kLoopbackDiagWorkerEntered = 0x00000001u;
constexpr uint32_t kLoopbackDiagDeviceReady = 0x00000002u;
constexpr uint32_t kLoopbackDiagCaptureStarted = 0x00000004u;
constexpr uint32_t kLoopbackDiagNonSilentPacket = 0x00000008u;
constexpr uint32_t kLoopbackDiagSilentPacket = 0x00000010u;
constexpr uint32_t kLoopbackDiagInitializeAttempted = 0x00000020u;
constexpr uint32_t kLoopbackDiagUnknownFormat = 0x00000040u;
constexpr uint32_t kLoopbackDiagFailed = 0x00000080u;
constexpr uint32_t kLoopbackDiagPolicyStopObserved = 0x00000100u;
// allow 请求的策略确认没在注入预算内到达：injector 已按「能力未就绪」降级继续
// （文本 hook 照常安装），worker 仍可能稍后自行 ack 成 running。置位只说明
// 「这次注入没等到确认」，不代表 loopback 永远起不来（BUG-2131）。
constexpr uint32_t kLoopbackDiagPolicyAckTimeout = 0x00000200u;

// 环形缓冲保留时长（秒）。C 阶段语音轨常见 48k 立体声 float32；60s 上界 ≈ 23MB。
// 32 位游戏地址空间有限，共享内存映射进游戏进程也吃它的地址空间——故设硬上界。
constexpr uint32_t kRingSeconds = 60;
constexpr uint32_t kMaxRingBytes = 64u * 1024u * 1024u;  // ≤64MB（spec C 阶段预算）

// 文本事件区（v13 按线程分道）：kTextLaneCount 条道，每道 kTextLaneSlotCount 个槽循环覆盖。
// 每槽固定 kTextSlotBytes 字节（TextSlot 头 + 紧跟的文本字节）。v6 保留 Luna ThreadParam /
// hook 名称与 hookcode；v10 再透传 Luna ThreadCreate，使尚无已发布台词的 TextRender 等线程
// 也能先出现在选择器里。
//
// kTextSlotCount 保留为**总槽数**（供整区尺寸计算与 host 的"最多能回溯多少条"上界），语义从
// "全局 FIFO 长度"变成"所有道加起来的容量"——它不再参与寻址，寻址一律走 TextLaneSlotAt。
constexpr uint32_t kTextLaneSlotCount = 8;
constexpr uint32_t kTextLaneCount = kThreadPreviewCount;  // 与预览槽同下标同分区
constexpr uint32_t kTextSlotCount = kTextLaneCount * kTextLaneSlotCount;
constexpr uint32_t kTextSlotBytes = 2048;
constexpr uint32_t kTextHookNameChars = 64;
constexpr uint32_t kTextHookCodeChars = 128;
constexpr uint32_t kTextSourceUnknown = 0;
constexpr uint32_t kTextSourceGdi = 1;
constexpr uint32_t kTextSourceLuna = 2;
constexpr uint32_t kTextSourceUnityTmp = 3;
constexpr uint32_t kTextSourceSiglus = 4;
constexpr uint32_t kTextSourceSgre = 5;
// smash/fzmedia (TYPE-MOON "smash" framework: Fate/stay night REMASTERED family)
// exact text published by the native KAG text-layer layout hook.
constexpr uint32_t kTextSourceSmashFzmedia = 6;
constexpr uint32_t kTextEventLine = 0;
constexpr uint32_t kTextEventThreadDiscovered = 1;
// Some Luna engine hooks expose scenario text and system controls from the
// same hook face but keep them separated by ThreadParam.ctx. Consumers must
// not apply the usual same-face fallback to lines carrying this flag. Bit 0 is
// already used by thread-discovery events for Luna's embedable attribute.
constexpr uint32_t kTextEventFlagExactThreadContext = 0x00000002u;

// 语音 clip 索引：最近 kClipCount 条语音片段的位置记录（按 source voice / DirectSound buffer
// 的一次提交切一条；galgame 一句台词≈一条语音）。指向音频环形里的 [ring_offset, byte_len)。
constexpr uint32_t kClipCount = 1024;  // clip 索引环：128≈仅2秒历史不够重建整句语音，扩到 ~16秒

// hook DLL 完成首次 XAudio2/DirectSound 导出 hook 安装后置位。launch 模式在恢复游戏主线程
// 前等待此位，避免游戏抢先创建音频引擎导致整局都没有可配对的 source voice。
constexpr uint32_t kDiagStartupAudioHooksReady = 0x00000001u;
constexpr uint32_t kDiagUnityIl2CppHooksReady = 0x00000002u;
constexpr uint32_t kDiagUnityIl2CppClipCaptured = 0x00000004u;
constexpr uint32_t kDiagUnityIl2CppPlaybackObserved = 0x00000008u;
constexpr uint32_t kDiagUnityIl2CppGetDataRejected = 0x00000010u;
constexpr uint32_t kDiagUnityResourceExtractorReady = 0x00000020u;
constexpr uint32_t kDiagUnityResourceExtracted = 0x00000040u;
constexpr uint32_t kDiagUnityResourceExtractFailed = 0x00000080u;
constexpr uint32_t kDiagUnityTmpTextHooksReady = 0x00000100u;
constexpr uint32_t kDiagUnityNaninovelTextHookReady = 0x00000200u;
constexpr uint32_t kDiagLunaHostReady = 0x00000400u;
constexpr uint32_t kDiagLunaConnected = 0x00000800u;
constexpr uint32_t kDiagLunaOutputObserved = 0x00001000u;
constexpr uint32_t kDiagLunaInjectFailed = 0x00002000u;
constexpr uint32_t kDiagSiglusExactTextHookReady = 0x00004000u;
constexpr uint32_t kDiagSiglusExactTextObserved = 0x00008000u;
constexpr uint32_t kDiagFfmpegResourceHooksReady = 0x00010000u;
constexpr uint32_t kDiagFfmpegResourceCaptured = 0x00020000u;
constexpr uint32_t kDiagVisualArtsOvkHooksReady = 0x00040000u;
constexpr uint32_t kDiagVisualArtsOvkCaptured = 0x00080000u;
constexpr uint32_t kDiagKirikiriVorbisOpenHookReady = 0x00100000u;
constexpr uint32_t kDiagFfmpegVoiceResourceObserved = 0x00200000u;
constexpr uint32_t kDiagTyranoAsarHooksReady = 0x00400000u;
constexpr uint32_t kDiagTyranoAsarVoiceCaptured = 0x00800000u;
constexpr uint32_t kDiagBgiArcHooksReady = 0x01000000u;
constexpr uint32_t kDiagBgiArcVoiceCaptured = 0x02000000u;
constexpr uint32_t kDiagArtemisPfsHooksReady = 0x04000000u;
constexpr uint32_t kDiagArtemisPfsVoiceCaptured = 0x08000000u;
constexpr uint32_t kDiagCatSystem2PcmHooksReady = 0x10000000u;
constexpr uint32_t kDiagCatSystem2PcmVoiceCaptured = 0x20000000u;
constexpr uint32_t kDiagMalieLibpHooksReady = 0x40000000u;
constexpr uint32_t kDiagMalieLibpVoiceCaptured = 0x80000000u;

// reserved_hook_diagnostics is a secondary engine-I/O trace word. Malie uses
// it to distinguish handle discovery, async reads, and mapped views without
// consuming the saturated primary hook_diagnostics bitset.
constexpr uint32_t kDiagMalieArchiveHandleTracked = 0x00000001u;
constexpr uint32_t kDiagMalieReadRangeObserved = 0x00000002u;
constexpr uint32_t kDiagMalieMappingTracked = 0x00000004u;
constexpr uint32_t kDiagMalieMappedRangeObserved = 0x00000008u;
constexpr uint32_t kDiagMalieVoiceRangeQueued = 0x00000010u;
constexpr uint32_t kDiagQlieVorbisHooksReady = 0x00000020u;
constexpr uint32_t kDiagQlieVorbisOpenObserved = 0x00000040u;
constexpr uint32_t kDiagQlieVorbisPcmCaptured = 0x00000080u;
constexpr uint32_t kDiagQlieVorbisFloatHookReady = 0x00000100u;
constexpr uint32_t kDiagQlieVorbisFloatPcmCaptured = 0x00000200u;
constexpr uint32_t kDiagUnityTextScanReady = 0x00000400u;
constexpr uint32_t kDiagUnityUiTextClassFound = 0x00000800u;
constexpr uint32_t kDiagUnityUiTextMethodFound = 0x00001000u;
constexpr uint32_t kDiagUnityUiTextHookReady = 0x00002000u;
constexpr uint32_t kDiagUnityTextMeshClassFound = 0x00004000u;
constexpr uint32_t kDiagUnityTextMeshMethodFound = 0x00008000u;
constexpr uint32_t kDiagUnityTextMeshHookReady = 0x00010000u;
constexpr uint32_t kDiagUnityAudioClassFound = 0x00020000u;
constexpr uint32_t kDiagUnityAudioResourceMethodsFound = 0x00040000u;
constexpr uint32_t kDiagUnityAudioPcmMethodsFound = 0x00080000u;
constexpr uint32_t kDiagUnityAudioPlaybackMethodFound = 0x00100000u;
constexpr uint32_t kDiagUnityAudioPlaybackHookReady = 0x00200000u;
constexpr uint32_t kDiagUnityHooksDeferredUntilWindow = 0x00400000u;
constexpr uint32_t kDiagElfAi6ArcHooksReady = 0x00800000u;
constexpr uint32_t kDiagElfAi6ArcVoiceCaptured = 0x01000000u;
constexpr uint32_t kDiagElfAi6ArcHandleTracked = 0x02000000u;
constexpr uint32_t kDiagElfAi6ArcReadObserved = 0x04000000u;
constexpr uint32_t kDiagElfAi6ArcOggObserved = 0x08000000u;
constexpr uint32_t kDiagElfAi6ArcVoiceQueued = 0x10000000u;
constexpr uint32_t kDiagElfAi6ArcTaskRejected = 0x20000000u;
// XAudio2 可直接接收 Microsoft ADPCM，由引擎内部解码。4-bit 源不能冒充 PCM 写共享环；
// hook 回调只复制进有界队列，工作线程解码成 16-bit PCM 后再发布。
constexpr uint32_t kDiagXAudioAdpcmObserved = 0x40000000u;
constexpr uint32_t kDiagXAudioAdpcmPcmCaptured = 0x80000000u;

// XAudio2 lifecycle/queue diagnostics use the original v1 protocol-reserved
// word.  This does not change SharedHeader size or any region offset: old hosts
// continue to ignore the zero-initialized word, while new probes can distinguish
// "no Submit" from bounded-queue pressure, stale lifetime invalidation, decode
// rejection, and deferred-operation commit.  These are sticky observation bits;
// exact counters remain process-local atomics so audio callbacks never perform
// logging or other I/O.
constexpr uint32_t kXAudioDiagQueueReady = 0x00000001u;
constexpr uint32_t kXAudioDiagJobQueued = 0x00000002u;
constexpr uint32_t kXAudioDiagDescriptorExhausted = 0x00000004u;
constexpr uint32_t kXAudioDiagArenaExhausted = 0x00000008u;
constexpr uint32_t kXAudioDiagBufferRejected = 0x00000010u;
constexpr uint32_t kXAudioDiagRegistryMiss = 0x00000020u;
constexpr uint32_t kXAudioDiagStaleInvalidated = 0x00000040u;
constexpr uint32_t kXAudioDiagDecodeRejected = 0x00000080u;
constexpr uint32_t kXAudioDiagPcmPublished = 0x00000100u;
constexpr uint32_t kXAudioDiagFlushObserved = 0x00000200u;
constexpr uint32_t kXAudioDiagDestroyObserved = 0x00000400u;
constexpr uint32_t kXAudioDiagDeferredQueued = 0x00000800u;
constexpr uint32_t kXAudioDiagDeferredExhausted = 0x00001000u;
constexpr uint32_t kXAudioDiagCommitObserved = 0x00002000u;
constexpr uint32_t kXAudioDiagSubmitFailed = 0x00004000u;
constexpr uint32_t kXAudioDiagUnsupportedFormat = 0x00008000u;
constexpr uint32_t kXAudioDiagRegistryExhausted = 0x00010000u;
constexpr uint32_t kXAudioDiagCommitFailed = 0x00020000u;
constexpr uint32_t kXAudioDiagCommitQueueExhausted = 0x00040000u;
// 至少发布过一条**取自引擎归档**的压缩语音资源（当前只有 SGRE 的 voice_body.bin）。
// 与 kXAudioDiagPcmPublished 不同，这是 resource-audio 就绪证据：即使配对时刻没有
// 活跃 PCM clip，host 也可以优先用它。
//
// 「byte-exact」到什么层次，必须说准（SOP 第 7 节的 hash_verified 是按这个判的）：
//   * fmt / dpds / 压缩负载三块**逐字节**取自归档，与源 entry 一致；
//   * 但发布出去的 `.xwma` **文件**不逐字节等于归档里的任何一段——归档存的是无头
//     chunk，RIFF 外壳是本进程合成的。所以能宣称的是「负载哈希一致」，不是「文件
//     哈希一致」；要上 hash_verified 必须比对负载而不是整文件。
constexpr uint32_t kXAudioDiagGameResourcePublished = 0x00080000u;
// 由运行时 fmt/dpds 重建并发布的**通用** xWMA 资源（没有引擎归档可比对的引擎）。
// 与上面那位分开的理由：那位能宣称负载逐字节等于源 entry，这一位不能——fmt 是本
// 进程按 XAudio2 报的源格式合成的。混成一位，台账上就分不出这两级证据。
constexpr uint32_t kXAudioDiagRuntimeXwmaPublished = 0x00100000u;
// Exact WHITE ALBUM2 Leaf/AQUAPLUS resource capture reuses the shared
// KernelBase file broker: VOICE.PAK is validated as a LAC archive at install,
// then a playback-time read queues the original Ogg member for worker-side
// publication.  These bits live in the existing diagnostics word; no IPC
// layout or region size changes.
constexpr uint32_t kXAudioDiagLeafLacHooksReady = 0x00200000u;
constexpr uint32_t kXAudioDiagLeafLacHandleTracked = 0x00400000u;
constexpr uint32_t kXAudioDiagLeafLacReadObserved = 0x00800000u;
constexpr uint32_t kXAudioDiagLeafLacVoiceQueued = 0x01000000u;
constexpr uint32_t kXAudioDiagLeafLacTaskRejected = 0x02000000u;
constexpr uint32_t kXAudioDiagLeafLacVoicePublished = 0x04000000u;
// HUNEX GGE 的 HFA/HW 源资源链只复用共享 KernelBase 文件 broker。前四位
// 分别证明档案索引、实际句柄、播放期读取和有界任务队列；最后一位保留拒绝原因。
// HooksReady 不能单独算 resource-audio ready：只有 worker 成功发布逐字节取自
// HW wrapper 后 Ogg payload 的文件时，才另外置 kXAudioDiagGameResourcePublished。
constexpr uint32_t kXAudioDiagHunexHfaHooksReady = 0x08000000u;
constexpr uint32_t kXAudioDiagHunexHfaHandleTracked = 0x10000000u;
constexpr uint32_t kXAudioDiagHunexHfaReadObserved = 0x20000000u;
constexpr uint32_t kXAudioDiagHunexHfaVoiceQueued = 0x40000000u;
constexpr uint32_t kXAudioDiagHunexHfaTaskRejected = 0x80000000u;
// SGRE (M2 wind3d11) identity is two layers: the family (voice_body.bin next
// to the executable) and the build-specific anchors (measured hash row or
// unique signature hit). These three bits report where anchor resolution
// ended so an unmeasured build reads as "engine recognised, anchors missing"
// instead of silently doing nothing.
// 注意这三位落在 **xaudio_diagnostics2**（第二个诊断字），不是 xaudio_diagnostics：
// 后者的 32 位在 v20 合并时已被占满（低 27 位既有 + HUNEX HFA 的高 5 位）。设置侧用
// SetXAudioDiagnostic2，别误用 SetXAudioDiagnostic —— 那会把位或进错误的字，
// 表现为「诊断一直是 0」而不是编译错误。
constexpr uint32_t kXAudioDiag2SgreFamilyMatched = 0x00000001u;
constexpr uint32_t kXAudioDiag2SgreAnchorsResolved = 0x00000002u;   // all three
constexpr uint32_t kXAudioDiag2SgreAnchorsUnresolved = 0x00000004u; // any missing

// Leaf/AQUAPLUS（WHITE ALBUM2）资源音频三段门的**分型**位。
//
// TryHookLeafAquaplusResourceAudio 的三个前置（exact profile 匹配 / 共享文件 hook /
// VOICE.PAK 归档加载）此前任一失败都只是静默 `return false`，诊断上完全同形：真机上
// 只看得到「音频降级成系统 Loopback」，分不出是身份没匹配、hook 没装上，还是归档没读到，
// 而这三者的处置完全不同。这三位只记录事实，不参与任何判定。
//
// kDiagSiglusOvkHooksReady 不能拿来替代：它只在 siglus 家族为真时才置位，Leaf 复用同一套
// 共享文件 hook 却永远不会点亮它，据此推断会得到相反的结论。
constexpr uint32_t kXAudioDiag2LeafProfileUnmatched = 0x00000008u;
constexpr uint32_t kXAudioDiag2LeafFileHooksUnavailable = 0x00000010u;
constexpr uint32_t kXAudioDiag2LeafVoiceArchivesMissing = 0x00000020u;

// Leaf/AQUAPLUS 身份门（IsLeafAquaplusProfileMatched）的**分型**位。
//
// 上面三位挂在 TryHookLeafAquaplusResourceAudio 里，而那个函数只有在 adapter 已经
// claim 本进程之后才会被调用；adapter 的 probe() 就是身份门本身。真机上观察到
// lookup_admission=EngineUnsupported（Leaf 的 lookupAdmission 只可能返回
// SensorInstalled / IdentityAccepted，绝不会返回 EngineUnsupported）意味着根本没有
// adapter claim，也就是身份门没过——此时上面三位必然全灭，无法分型。
//
// 身份门是两层：先按 exe SHA-256 + machine 选中 profile，再做二进制结构校验（唯一
// 掩码模式扫描 + 重定位操作数复核 + section 角色复核）。哈希逐字节相同却仍不匹配时，
// 失败一定在第二层，而那是一条约 25 项的 && 链，不分型就只能逐项猜。
//
// kXAudioDiag2LeafIdentityHashMatched 在哈希 + machine 匹配后立刻置位（结构门之前），
// 其余各位只在结构校验失败时按组记录事实。全部只记录，不参与任何判定；判定链一字未改。
constexpr uint32_t kXAudioDiag2LeafIdentityHashMatched = 0x00000040u;
constexpr uint32_t kXAudioDiag2LeafStructureRejected = 0x00000080u;
constexpr uint32_t kXAudioDiag2LeafImageUnopened = 0x00000100u;
constexpr uint32_t kXAudioDiag2LeafSectionRolesRejected = 0x00000200u;
constexpr uint32_t kXAudioDiag2LeafTraversalAnchorMissed = 0x00000400u;
constexpr uint32_t kXAudioDiag2LeafRasterAnchorMissed = 0x00000800u;
constexpr uint32_t kXAudioDiag2LeafInputAnchorMissed = 0x00001000u;
constexpr uint32_t kXAudioDiag2LeafEmbedAnchorMissed = 0x00002000u;
constexpr uint32_t kXAudioDiag2LeafDeviceAnchorMissed = 0x00004000u;
constexpr uint32_t kXAudioDiag2LeafReturnSitesRejected = 0x00008000u;

// 「exe 摘要量不到」与「摘要量到了但不是这个发行版」必须分开：前者是瞬时条件
// （首次 probe 可能落在注入窗口内，BCrypt / 文件映射在 loader lock 或 hook 安装
// 中途失败），后者是确定结论。旧实现两者共用一条永久 -1 缓存路径，于是一次瞬时
// 失败就让本会话的 Leaf adapter 永久出局，表现为整场音频降级到系统 Loopback。
constexpr uint32_t kXAudioDiag2LeafExecutableUnmeasurable = 0x00010000u;

// KiriKiri 查词传感器**安装路径**的分型位（BUG-2121，Fate/stay night[Realta Nua] KiriKiri2
// 2.31/BCB 真机）。lookup_diag 只在传感器装上之后才开始有位，装不上时整局零位——而安装路径
// 上有 9 个静默 return（主窗解析不到 / 接缝挂不上 / 线程身份 / 导出表查不到 / 表达式查不到 /
// bootstrap 分配失败…），没有这组位就分不出「这个引擎没做」和「装到第 N 步死了」。粘滞位
// 语义（曾经到过哪一步）正合适：安装是单向推进的，读侧按位序就能看出卡在哪。
// 放这个字而不是 reserved_luna / lookup_diag：那两个 32 位都已满（见各自注释）。
constexpr uint32_t kXAudioDiag2KirikiriLookupMainWindowMissing = 0x00020000u;  // 安装已请求但 FindGameMainWindow()==null
constexpr uint32_t kXAudioDiag2KirikiriLookupSeamArmed = 0x00040000u;          // WH_GETMESSAGE 主线程接缝已挂
constexpr uint32_t kXAudioDiag2KirikiriLookupSeamHookFailed = 0x00080000u;     // SetWindowsHookEx 失败
constexpr uint32_t kXAudioDiag2KirikiriLookupSeamFired = 0x00100000u;          // 接缝在主线程上跑过安装
constexpr uint32_t kXAudioDiag2KirikiriLookupExportQueryFailed = 0x00200000u;  // 5 个核心导出名查不到
constexpr uint32_t kXAudioDiag2KirikiriLookupExpressionQueryFailed = 0x00400000u;  // TVPExecuteExpression 查不到
constexpr uint32_t kXAudioDiag2KirikiriLookupBootstrapStarted = 0x00800000u;   // bootstrap 脚本已登记进连续事件
// 「登记进连续事件」与「引擎真的回调进来并把脚本跑完」是两件事：前者只证明
// TVPAddContinuousEventHook 接受了我们的回调对象，后者才证明引擎事件循环在跑我们的 TJS。
// 中间还隔着一次 TVPExecuteScript——在 BCB 上它抛的是 Borland 异常，只有 SEH 拦得住，
// 拦下来之后脚本就是"静默没执行"，与"回调压根没来"同形（BUG-2121 第三段）。
constexpr uint32_t kXAudioDiag2KirikiriLookupBootstrapFired = 0x01000000u;     // 连续事件回调真的进来了
constexpr uint32_t kXAudioDiag2KirikiriLookupBootstrapFaulted = 0x02000000u;   // TVPExecuteScript 抛了（SEH 拦下）
// bootstrap 脚本跑完之后，TJS 侧那个 System.addContinuousHandler 回调每帧都在前置条件
// `typeof global.kag == "Object" && typeof global.kag.addHook == "Object"` 上静默 return，
// 症状与「脚本没跑」完全同形（都是 fushiLookupNotify 不存在、控制台无 [HibikiLookup] 行）。
// 这三位把前置条件拆开量：脚本活着吗 / kag 出来了吗 / 这个 KAG 分支有 addHook 吗。
constexpr uint32_t kXAudioDiag2KirikiriLookupTjsBootstrapFnAlive = 0x04000000u;  // global.fushiLookupBootstrap 仍在
constexpr uint32_t kXAudioDiag2KirikiriLookupKagObjectReady = 0x08000000u;       // global.kag 是对象
constexpr uint32_t kXAudioDiag2KirikiriLookupKagAddHookReady = 0x10000000u;      // global.kag.addHook 存在

// 第三条 exporter 路径（BUG-2145）：exe 无导出表 + 插件早于我们 link 时，从已 link 插件
// 的可写节反查 exporter 单例。三态互斥可判：扫描是否跑过 / 有没有过形状门的候选 /
// 真调用校验后是否采用。
// ⚠️ 本字至此 32 位用尽；下一族诊断位必须另立新字（照 reserved_luna→xaudio_diagnostics2
// 的先例），不要拓宽本字或挤占已有位。
constexpr uint32_t kXAudioDiag2KirikiriExporterScanRan = 0x20000000u;          // 前两条路径都空，扫描已跑
constexpr uint32_t kXAudioDiag2KirikiriExporterScanNoCandidate = 0x40000000u;  // 交集/形状门后无候选
constexpr uint32_t kXAudioDiag2KirikiriExporterScanAdopted = 0x80000000u;      // 候选过真调用校验并被采用

// reserved_luna 的资源音频诊断位。KiriKiriZ 的 TVPCreateStream hook 直接导出当前播放的
// 已解密 Ogg；Siglus 从 OVK 索引导出逐句 Ogg。它们只代表“资源捕获链已安装”，不要求 PCM
// 环已有格式，因此 host 应优先按时间戳配对资源文件，并把系统回环保留为逐句 fallback。
constexpr uint32_t kDiagKirikiriVoiceStreamHookReady = 0x00020000u;
constexpr uint32_t kDiagKirikiriVoiceStreamDumped = 0x00080000u;
constexpr uint32_t kDiagSiglusOvkHooksReady = 0x10000000u;

// reserved_luna 里 KiriKiri 经典 KAG3 的采集自证位。TJS 侧的 fushiLookupClassicSource
// 位 3 = 「至少给一个消息层实例挂上过 classic 采集包装」。它与位 0（classic 分支跑到了）
// 必须分开读：分支跑到但一个层都没挂上，说明 kag.fore.messages 不是标准 KAG3 结构——
// 这两种失败在真机上完全同形，而 lookup_diag 与 xaudiodiag2 两个 32 位字都已用满，
// 所以这一位落在 reserved_luna（KiriKiri 的 exporter 溯源位本来就住这儿）。
constexpr uint32_t kDiagKirikiriClassicLayerPatched = 0x00000040u;

inline constexpr bool HasReadyGameResourceAudio(uint32_t reserved_luna,
                                                uint32_t hook_diagnostics,
                                                uint32_t reserved_hook_diagnostics = 0,
                                                uint32_t xaudio_diagnostics = 0) {
  const uint32_t unity_required = kDiagUnityIl2CppHooksReady |
                                  kDiagUnityResourceExtractorReady;
  const bool unity_ready =
      (hook_diagnostics & unity_required) == unity_required;
  return (reserved_luna & kDiagKirikiriVoiceStreamHookReady) != 0 ||
         (reserved_luna & kDiagSiglusOvkHooksReady) != 0 ||
         (hook_diagnostics & kDiagFfmpegResourceHooksReady) != 0 ||
         (hook_diagnostics & kDiagTyranoAsarHooksReady) != 0 ||
         (hook_diagnostics & kDiagBgiArcHooksReady) != 0 ||
         (hook_diagnostics & kDiagArtemisPfsHooksReady) != 0 ||
         (hook_diagnostics & kDiagCatSystem2PcmHooksReady) != 0 ||
         (hook_diagnostics & kDiagMalieLibpHooksReady) != 0 ||
         (hook_diagnostics & kDiagVisualArtsOvkHooksReady) != 0 ||
         (reserved_hook_diagnostics & kDiagElfAi6ArcHooksReady) != 0 ||
         (xaudio_diagnostics & kXAudioDiagLeafLacHooksReady) != 0 ||
         (xaudio_diagnostics & kXAudioDiagGameResourcePublished) != 0 ||
         unity_ready;
}

// Unity Streaming AudioClip 不能用 AudioClip.GetData 读取。DLL 在 Play/set_clip 时只写一个
// 轻量资源事件（clip 名 + 最近打开的 voice bundle）；injector 宿主进程再解析 AssetBundle 并
// 用 vgmstream 解码，所有磁盘/解码工作都留在游戏进程之外。
constexpr uint32_t kUnityVoiceEventCount = 16;
constexpr uint32_t kUnityClipNameChars = 128;
constexpr uint32_t kUnityBundlePathChars = 520;
// ── v6 loopback 兜底混音捕获 ─────────────────────────────────────────────────
// loopback 环时长（秒）。injector 在**注入前**分配映射，此刻还拿不到真实混音格式，故按名义
// 立体声 16-bit 存储格式（48k*2ch*2B）预留固定字节；实际混音若是 5.1/7.1，同容量下只是历史
// 时长变短（例 6ch → ~20s），仍够 [ts-100ms, ts+5000ms] 抽窗。混音端 32-bit float 在 hook 侧
// 转成 16-bit PCM 再入环，故按 16-bit 名义容量算字节（同时压低 32 位游戏地址空间占用）。
constexpr uint32_t kLoopbackSeconds = 60;
constexpr uint32_t kMaxLoopbackBytes = 16u * 1024u * 1024u;  // ≤16MB（32 位地址空间预算）
// 时间戳↔环位置标记表槽数。loopback 线程每 ~200ms 记一条 {tick, total}；60s → 300 条，512 留余。
constexpr uint32_t kLoopbackMarkerCount = 512;

// 文本事件槽：lane_seq==该道 TextLane::write_count 对应值时该槽有效（v13 起道内校验，不再拿
// 全局序号取模）；event_kind==kTextEventLine 时，文本紧跟本头之后（kTextSlotBytes-头长）；
// 线程发现事件的 byte_len 为 0、只携带线程元数据。
#pragma pack(push, 8)
struct TextSlot {
  volatile uint64_t seq;    // 全局发布序（host 的 pollText 游标就是它；0=空）
  uint64_t timestamp_ms;    // GetTickCount64() 写入时刻（与语音 clip 配对用）
  uint32_t byte_len;        // 文本有效字节数（<= kTextSlotBytes - sizeof(TextSlot)）
  uint32_t is_utf8;         // 1=UTF-8，0=UTF-16LE
  uint64_t thread_id;       // 会话内稳定的 Hook 线程 id（0=不可区分）
  uint64_t thread_address;  // Luna ThreadParam.addr
  uint64_t thread_context;  // Luna ThreadParam.ctx
  uint64_t thread_context2; // Luna ThreadParam.ctx2
  uint32_t process_id;      // Luna ThreadParam.processId / GDI 当前进程
  uint32_t source_kind;     // kTextSource*；决定 UI 标签
  uint32_t hook_name_len;   // hook_name 有效字节数（不含结尾 0）
  uint32_t hook_code_len;   // hook_code 有效 wchar 数（不含结尾 0）
  uint32_t event_kind;      // kTextEvent*；0 保持旧写者默认语义为台词行
  uint32_t event_flags;     // bit 0: discovery embedable; bit 1: exact ctx only
  // hook「面」id（不含 ctx，见 luna_text_selector.h 的 LunaTextFaceIdFrom）。
  //
  // v13 把选定线程的过滤从采集期挪到消费期，这个字段是**挪过去还能等价**的前提：旧的
  // native 过滤按 hook 面放行（同一 hook 面换调用点 ctx 会变、thread_id 随之变，精确匹配
  // 会把整段台词丢掉——BUG-1159）。消费方只有拿到同一个 face id，才能复刻同样的放行判据，
  // 而不是在 Dart 里照抄一遍 FNV 哈希（那又是一个漂移源）。0 = 写者无法提供。
  uint64_t face_id;
  // 道内序号，兼**完成标记**：==该道 write_count 快照即有效，**最后**写。
  //
  // 必须 volatile 且必须用 AtomicStorePreview64 发布（与预览槽 seq、VoiceClip::seq、
  // LoopbackMarker::seq 同一套纪律）：它是跨进程可见性的分界线。普通写有两个真实风险——
  // 编译器可以把它提到 payload 之前（reader 就会读到半写槽），x86 上 64 位普通写还可能被
  // 拆成两次 32 位写而撕裂。Interlocked 系是全栅栏且不可撕裂，一次解决两个。
  volatile uint64_t lane_seq;
  char hook_name[kTextHookNameChars];
  wchar_t hook_code[kTextHookCodeChars];
  // 紧跟文本字节。
};

// v13 文本道表头：每条线程一条道，位于文本区最前面，槽区紧随其后。
//
// 认领纪律与线程预览槽**完全一致**（下标同一套）：writer 先由进程内锁串行化，再按 thread_id
// 线性查找/认领；Luna（injector 进程）与游戏内 native adapter 使用互斥的下标区段，跨进程
// writer 因此不会争抢同一条道——进程内 CRITICAL_SECTION 串不住另一个进程，这是 v12 已经踩过
// 的坑，v13 不重新发明。
struct TextLane {
  volatile uint64_t thread_id;    // 0=空道（回收后允许出现空洞，查找必须扫完整张表）
  volatile uint64_t write_count;  // 道内单调写入数（reader 据此定位有效槽区间）
  // 最近一次写入时刻（GetTickCount64）。道用尽时按它挑最久没动的**非选定**道回收——
  // 见 WriteTextLaneEvent 的道满处置。
  volatile uint64_t last_write_ms;
};

// 语音 clip 记录：一段独立语音片段在音频环形里的位置 + 时刻 + 格式。host 按文本时间戳找最近
// clip，再从音频环形 [ring_offset, ring_offset+byte_len) 取 PCM（若已被环形覆盖则 total_at_write
// 与当前 total_written 差值 > ring_capacity，host 判为过期）。
struct VoiceClip {
  volatile uint64_t seq;      // 写入序号（0=空）
  uint64_t timestamp_ms;      // 该 clip 播放时刻
  uint64_t total_at_write;    // 写该 clip 尾时的 total_written（判是否已被环形覆盖）
  uint32_t ring_offset;       // 在音频环形里的起始偏移
  uint32_t byte_len;          // clip 字节数
  uint32_t sample_rate;
  uint32_t channels;
  uint32_t bits_per_sample;
  uint32_t is_float;
  uint32_t pad;               // 保留位；必须写 0，结构尺寸/协议布局不变
  uint64_t source_ptr;        // 该段所属 source voice / DS buffer 指针：区分语音源 vs BGM 源，
                              // 供 host 把同一源的连续段合成整句语音（而非只取一个 buffer 片段）
};

struct UnityVoiceEvent {
  volatile uint64_t seq;   // 全局序号，最后写；0=槽尚未完成
  uint64_t timestamp_ms;   // AudioSource 播放/绑定该 AudioClip 的 GetTickCount64
  wchar_t clip_name[kUnityClipNameChars];
  wchar_t bundle_path[kUnityBundlePathChars];
};

// loopback 时间戳↔环位置标记：loopback 线程每 ~200ms 写一条，记该时刻的墙钟 tick 与 loopback 环
// 已写字节 total。host/工具按文本时间戳（同为 GetTickCount64）在标记表里插值反查环内字节位置，
// 抽 [ts_start, ts_end] 窗口。单写者（仅 loopback 线程写），seq 作半写完成标记（reader 校验
// seq==loopback_marker_count 快照即有效），与 VoiceClip 同款纪律。
struct LoopbackMarker {
  volatile uint64_t seq;    // 写入序号（0=空；等于 loopback_marker_count 快照即有效），**最后**写
  uint64_t tick_ms;         // GetTickCount64() 记录时刻
  uint64_t total_written;   // 该时刻的 loopback_total_written（单调）
};

// ══ v14 游戏内查词区 ════════════════════════════════════════════════════
// KiriKiri/KAGEX 在**游戏渲染树内部**显示词典卡片。注入侧只做几何传感、
// 位图落地和输入转发；分词、查词、排版、卡片像素全部由 host（Hibiki 既有
// popup.html + WebView2 离屏合成）负责。跨进程边界上因此只有一块位图和一串整数。
//
// 三条通道各自单写单读，无锁：
//   hit   : hook → host，单槽 latest-wins，仅发布 submit；hover 在游戏线程即时高亮
//   input : hook → host，环（落在卡片矩形内的鼠标/滚轮事件，供 host 喂 SendMouseInput）
//   frame : host → hook，双缓冲（避免 host 写下一帧时撕裂 hook 正在拷的这一帧）
//
// **像素格式：BGRA8，直通（非预乘）alpha，自顶向下。** 两端都按直通最省事——host 侧
// WebView2 取帧经 WIC 解码并由 shell mask 重建透明边界；注入侧 KiriKiri 的 ltAlpha
// 是直通（预乘对应的是 ltAddAlpha）。任何一侧擅自改成预乘，症状是卡片半透明边缘发暗，
// 不会报错，只会看起来"有点脏"——所以在这里写死，别靠两边默契。
constexpr uint32_t kLookupLineBytes = 1024;      // 单行台词 UTF-8 上限（整行，不截断）
constexpr uint32_t kLookupInputSlotCount = 64;   // 输入转发环槽数
constexpr uint32_t kLookupFrameCount = 2;        // 位图双缓冲
// 单缓冲位图上限 3MiB ≈ 880×880 BGRA。x86 游戏进程地址空间有限，故设硬上界；超限由
// host 负责钳制卡片尺寸，注入侧只做校验和拒绝，绝不按收到的 width/height 盲拷。
// 单张卡片位图的字节预算（双缓冲，共享内存占 2 倍）。
//
// 超预算时 runner 只能**裁**（DecodeCaptureStreamToStraightBgra 直接改小 width/height
// 按左上角取块），不是缩——也就是说预算定小了，用户看到的是被切掉半张的卡片。
// 原来的 3 MiB 只够 786432 像素，1920x1440 视口下取 0.6 就已经逼近；抬到 8 MiB
// 后可容 2097152 像素（约 1600x1200 / 1920x1092），正常卡片不可能撞到。
//
// 抬这个数**不需要升 kSharedVersion**：区域寻址、IsLookupFrameSane、runner 的预算
// 校验一律读 header->lookup_bitmap_bytes，没有一处硬用本常量。旧 helper 建的段就
// 报 3 MiB，host 照它办，两侧仍自洽。代价只是共享内存多 10 MiB。
constexpr uint32_t kLookupBitmapBytes = 8u * 1024u * 1024u;

// lookup_diag 位。与 reserved_luna / hook_diagnostics 分开：那两个各自已满，且这里的
// 阶段语义（传感器装没装 / 像素走哪条路）与引擎探针、helper 启动都不是一回事。
constexpr uint32_t kLookupDiagSensorInstalled = 0x00000001u;  // TJS 传感器已装
constexpr uint32_t kLookupDiagGeometryObserved = 0x00000002u;  // 真拿到过逐字符几何
constexpr uint32_t kLookupDiagHitSubmitted = 0x00000004u;     // 真上报过命中
constexpr uint32_t kLookupDiagBufferRouteReady = 0x00000008u;  // mainImageBufferForWrite 可用
constexpr uint32_t kLookupDiagFallbackPngRoute = 0x00000010u;  // 降级走 PNG + loadImages
constexpr uint32_t kLookupDiagFramePresented = 0x00000020u;   // 位图真落进游戏 Layer
constexpr uint32_t kLookupDiagExpressionReady = 0x00000040u;  // TVPExecuteExpression 可用
constexpr uint32_t kLookupDiagFrameRejected = 0x00000080u;    // 收到过不合契约的帧（已拒）
// 经典 KAG3 采集面（原生 Layer.drawText）已生效：该游戏没有 KAGEX 的 global.TextRender，
// 逐字几何只能从原生绘字方法取。与 kLookupDiagGeometryObserved 分开——那位只说"拿到过
// 几何"，这位说"几何是从哪条面来的"，真机排障时决定该去看 TextRender 还是 drawText。
constexpr uint32_t kLookupDiagClassicTextSource = 0x00000100u;
// 经典采集面**真的捕到过字形**。与上一位分开是因为真机上这两件事会分离：补丁装上了、
// bootstrap 也跑完了，但一个字都没经过它——那说明游戏的文字根本不走这个原生方法，而不是
// 安装失败。两者症状同形（都没有卡片），合成一位就永远分不出该去修哪边。
constexpr uint32_t kLookupDiagClassicGeometry = 0x00000200u;
// 经典采集面走的是 MessageLayer.processCh（TJS 类）而不是 Layer.drawText（原生类）。
// 两者必须分开自证：真机实测 KiriKiri2 上给原生类成员赋值**拦不住实例调用**，只有 TJS
// 层的类才拦得住。合成一位就会把"装上了但永远不触发"误读成"这条路能用"。
constexpr uint32_t kLookupDiagClassicProcessCh = 0x00000400u;

// 传感器在游戏事件循环里吞下过异常（TJS 侧 fushiLookupFaults > 0）。
//
// 注入进别人的事件循环，异常就绝不允许逃逸——逃出去 KiriKiri 会弹「致命的なエラー」
// 把玩家这一局打断。但"不逃逸"必须与"看得见"成对出现：只 catch 不计数，查词会安静地
// 半死不活（命中报不上来、卡片不出现），而现场没有任何痕迹可查。这一位就是那道痕迹。
constexpr uint32_t kLookupDiagSensorFault = 0x00000800u;
// ── hover 未命中的原因（真机排查用；采集成功但点不中时唯一能分型的依据）──────
//
// 「采到了几何」和「点得中」之间隔着坐标系换算、图层可见性、逐字形命中三道，任何
// 一道断了，用户看到的都是同一句「点了没反应」。没有这几位就只能靠改一版试一版。
constexpr uint32_t kLookupDiagHoverBoxMiss = 0x00001000u;   // 光标不在整行包围盒内
constexpr uint32_t kLookupDiagHoverGlyphMiss = 0x00002000u; // 在包围盒内但无字形命中
constexpr uint32_t kLookupDiagHoverHidden = 0x00004000u;    // 命中但可见性判定否决
// 绘制原点在一次采集周期内被绑定多次 = drawCh 的 ox/oy 是**逐字符**位置，不是整行
// 原点。**这是引擎事实的记录位，不是错误位**：本样本（textrender.dll）实测每字一次，
// 采集侧据此改为「用 min(ox) 与 min(字形 x) 配对解平移量」，而不是把最后一个字的落
// 点当行原点（那正是第一版 HoverBoxMiss 的成因）。留着它是为了换引擎时一眼看出该
// 引擎属于哪一类。
constexpr uint32_t kLookupDiagOriginPerChar = 0x00008000u;
// 文字的绘制目标层不在 primaryLayer 的父链上（独立/离屏层），沿父链累加得到的偏移
// 因此没有意义。
constexpr uint32_t kLookupDiagLayerDetached = 0x00010000u;
// ── 投帧失败分型（真机上"卡片就是不出现"的唯一分辨依据）────────────────────
//
// 之前 FramePresented 在降级路上是**无条件置位**的：只证明"我让 TJS 去加载 PNG 了"，
// 不证明卡片显示了。而那条降级路要求有人把卡片写成 PNG 落盘——实测**没有任何一处
// 写过那个文件**，于是 loadImages 必然失败、被 TJS 的 catch 吞掉，所有诊断却都报成功。
// 诊断位声称的比它知道的多，是最难查的一类缺陷，这几位专门用来消除它。
constexpr uint32_t kLookupDiagCardLayerMissing = 0x00020000u;   // 卡片层建不出来
constexpr uint32_t kLookupDiagWriteBufferNull = 0x00040000u;    // 层在，但拿不到写指针
constexpr uint32_t kLookupDiagFallbackPngMissing = 0x00080000u; // 降级路的 PNG 文件不存在
// 卡片层退回了普通 Layer（自定义子类建不出来）。卡片能显示，但卡片内的鼠标事件
// 转发失效——降级发生了就要看得见，不许悄悄发生。
constexpr uint32_t kLookupDiagCardPlainFallback = 0x00100000u;
// Helper 已完成显式 Luna H-code 的插入。与 kDiagLunaConnected 分开：Connect 回调先置后者、
// 随后才逐条 InsertHook；同一入口还要叠加原生查词 detour 时，必须等到这一步完成才能稳定链式
// 安装，不能拿“管道已连上”冒充“目标地址已改写”。
constexpr uint32_t kLookupDiagLunaKnownHookReady = 0x00200000u;
// 精确 profile 的 sampled-input detour 已装，且 ready property 已发布到当前游戏
// 主窗。SGRE 的实现是 DirectInput GetDeviceState，Siglus 的实现是 GetKeyState；该位只
// 证明 host 可以安全启用对应输入盾，不声称 popup 正显示。保留旧 SGRE 名为 ABI/源码
// 兼容别名。
constexpr uint32_t kLookupDiagSampledInputShieldReady = 0x00400000u;
constexpr uint32_t kLookupDiagSgreDirectInputShieldReady =
    kLookupDiagSampledInputShieldReady;
// Exact anemoi/Siglus 1.1.141.3 lookup gates. Keep identity, installation,
// and live observations separate so a real-process probe identifies the first
// failed boundary without inferring it from a missing popup.
constexpr uint32_t kLookupDiagSiglusProfileMatched = 0x00800000u;
constexpr uint32_t kLookupDiagSiglusGlyphHookReady = 0x01000000u;
constexpr uint32_t kLookupDiagSiglusGetKeyStateHookReady = 0x02000000u;
constexpr uint32_t kLookupDiagSiglusGlyphObserved = 0x04000000u;
constexpr uint32_t kLookupDiagSiglusGetKeyStateObserved = 0x08000000u;
// Exact-profile admission diagnostics. These keep the shared layout/version
// unchanged while making fail-closed identity rejection observable.
constexpr uint32_t kLookupDiagSiglusProfileChecked = 0x10000000u;
constexpr uint32_t kLookupDiagSiglusExecutableRead = 0x20000000u;
constexpr uint32_t kLookupDiagSiglusHashMatched = 0x40000000u;
constexpr uint32_t kLookupDiagSiglusMachineMatched = 0x80000000u;

// v19 几何 provider 的稳定 wire id。kind 决定仲裁优先级；provider_id 标识具体实现，
// 两者不能互相替代。新增 provider 只能追加 id，不能复用旧值改变含义。
constexpr uint32_t kLookupGeometryProviderUnknown = 0u;
constexpr uint32_t kLookupGeometryProviderRuntimeLayout = 1u;
constexpr uint32_t kLookupGeometryProviderEngineExactLayout = 2u;
constexpr uint32_t kLookupGeometryProviderPositionedTextApi = 3u;
constexpr uint32_t kLookupGeometryProviderAttachedCalibrated = 4u;
constexpr uint32_t kLookupGeometryProviderPixelTemplateExperimental = 5u;
constexpr uint32_t kLookupGeometryProviderTypewriterDiffExperimental = 6u;

constexpr uint32_t kLookupGeometryProviderIdUnknown = 0u;
constexpr uint32_t kLookupGeometryProviderIdKirikiri = 1u;
constexpr uint32_t kLookupGeometryProviderIdRenpy = 2u;
constexpr uint32_t kLookupGeometryProviderIdSiglus = 3u;
constexpr uint32_t kLookupGeometryProviderIdLeafAquaplus = 4u;
constexpr uint32_t kLookupGeometryProviderIdSgre = 5u;
constexpr uint32_t kLookupGeometryProviderIdTyranoDom = 6u;
constexpr uint32_t kLookupGeometryProviderIdUnityTmp = 7u;
constexpr uint32_t kLookupGeometryProviderIdUnityUgui = 8u;
constexpr uint32_t kLookupGeometryProviderIdGdiPositioned = 9u;
constexpr uint32_t kLookupGeometryProviderIdDwritePositioned = 10u;
constexpr uint32_t kLookupGeometryProviderIdAttachedCalibrated = 11u;
constexpr uint32_t kLookupGeometryProviderIdPixelTemplateExperimental = 12u;
constexpr uint32_t kLookupGeometryProviderIdTypewriterDiffExperimental = 13u;
// Reserved for the measured HUNEX/GGE exact-layout family.  The current
// runtime trace remains observation-only; assigning a stable wire id does not
// promote it to a production publisher or change engine-support evidence.
constexpr uint32_t kLookupGeometryProviderIdHunexGge = 14u;
// smash/fzmedia KAG text-layer exact layout provider (append-only id).
constexpr uint32_t kLookupGeometryProviderIdSmashFzmedia = 15u;

constexpr uint32_t kLookupGeometryStatusUnavailable = 0u;
constexpr uint32_t kLookupGeometryStatusReady = 1u;
constexpr uint32_t kLookupGeometryStatusActive = 2u;
constexpr uint32_t kLookupGeometryStatusSuspended = 3u;
constexpr uint32_t kLookupGeometryStatusFaulted = 4u;

// v20 host -> injected registry geometry admission.  This is deliberately
// independent from lookup_enabled: attached calibrated lookup still needs the
// injected generic input shield while native geometry publishers are retired.
// Auto keeps observing native offers and uses the host-owned attached offer
// only as the lowest-priority production fallback.  v21 assigns flags bit 0x2
// the NativeInputAllowed semantic gate; that semantic change is versioned even
// though SharedHeader layout remains byte-for-byte identical to v20.
constexpr uint32_t kLookupGeometryAdmissionDisabled = 0u;
constexpr uint32_t kLookupGeometryAdmissionAuto = 1u;
constexpr uint32_t kLookupGeometryAdmissionNativeOnly = 2u;
constexpr uint32_t kLookupGeometryAdmissionAttachedOnly = 3u;
constexpr uint32_t kLookupGeometryAdmissionFlagAttachedReady = 0x00000001u;
// Host-owned semantic input gate.  Provider discovery/readiness intentionally
// ignores this bit: it only authorizes an already-applied exact native owner to
// consume input and publish the resulting lookup hit.
constexpr uint32_t kLookupGeometryAdmissionFlagNativeInputAllowed =
    0x00000002u;
constexpr uint32_t kLookupGeometryAdmissionFlagMask =
    kLookupGeometryAdmissionFlagAttachedReady |
    kLookupGeometryAdmissionFlagNativeInputAllowed;
constexpr uint32_t kLookupGeometryAdmissionWriteInProgress = 0x80000000u;
constexpr uint32_t kLookupGeometryAdmissionSequenceMask = 0x7fffffffu;

// LookupHitSlot 坐标域。生产 provider 必须明确声明；Unknown 会被 registry 拒绝。
constexpr uint32_t kLookupCoordinateSpaceUnknown = 0u;
constexpr uint32_t kLookupCoordinateSpaceClientPhysicalPixels = 1u;
constexpr uint32_t kLookupCoordinateSpacePrimaryLayer = 2u;
constexpr uint32_t kLookupCoordinateSpaceDesignSurface = 3u;
constexpr uint32_t kLookupCoordinateSpaceLayoutLocal = 4u;

// The host card compositor accepts either client physical pixels (the
// RevealOverProcessClient path enforces a 1:1 client/view contract before
// ClientToScreen) or in-process primaryLayer pixels. Design/layout-local wire
// spaces remain observations until a unique transform lineage resolves them.
inline constexpr bool IsLookupCardCoordinateSpaceResolved(
    uint32_t coordinate_space) {
  return coordinate_space == kLookupCoordinateSpaceClientPhysicalPixels ||
         coordinate_space == kLookupCoordinateSpacePrimaryLayer;
}

constexpr uint32_t kLookupWritingModeUnknown = 0u;
constexpr uint32_t kLookupWritingModeHorizontal = 1u;
constexpr uint32_t kLookupWritingModeVertical = 2u;

// v19 统一输入盾 ABI。required/ready/observed/fault 都使用同一 surface mask；粒度保留到
// immediate/buffered 与 RawInput 两个入口，避免“DirectInput ready”掩盖只覆盖一半的情况。
constexpr uint32_t kLookupShieldSurfaceWin32Messages = 0x00000001u;
constexpr uint32_t kLookupShieldSurfaceLowLevelMouse = 0x00000002u;
constexpr uint32_t kLookupShieldSurfaceKeyState = 0x00000004u;
constexpr uint32_t kLookupShieldSurfaceDirectInputImmediate = 0x00000008u;
constexpr uint32_t kLookupShieldSurfaceDirectInputBuffered = 0x00000010u;
constexpr uint32_t kLookupShieldSurfaceRawInputData = 0x00000020u;
constexpr uint32_t kLookupShieldSurfaceRawInputBuffer = 0x00000040u;
constexpr uint32_t kLookupShieldSurfaceEnginePrivate = 0x00000080u;
constexpr uint32_t kLookupShieldSurfaceMask = 0x000000ffu;

constexpr uint32_t kLookupShieldOwnerNone = 0u;
constexpr uint32_t kLookupShieldOwnerNativeGlyph = 1u;
constexpr uint32_t kLookupShieldOwnerAttachedGlyph = 2u;
constexpr uint32_t kLookupShieldOwnerPopup = 3u;
constexpr uint32_t kLookupShieldOwnerDismiss = 4u;

constexpr uint32_t kLookupShieldButtonLeft = 0x00000001u;
constexpr uint32_t kLookupShieldButtonRight = 0x00000002u;
constexpr uint32_t kLookupShieldButtonMiddle = 0x00000004u;
constexpr uint32_t kLookupShieldButtonX1 = 0x00000008u;
constexpr uint32_t kLookupShieldButtonX2 = 0x00000010u;
constexpr uint32_t kLookupShieldButtonMask = 0x0000001fu;

// status_flags 是互斥结论位 + 两个正交运行位。unknown 是零；Verified/Partial/
// KnownUncovered/Faulted 最多只能有一个，helper 会归一化并禁止风险路径冒充 verified。
constexpr uint32_t kLookupShieldStatusVerified = 0x00000001u;
constexpr uint32_t kLookupShieldStatusPartial = 0x00000002u;
constexpr uint32_t kLookupShieldStatusKnownUncovered = 0x00000004u;
constexpr uint32_t kLookupShieldStatusFaulted = 0x00000008u;
constexpr uint32_t kLookupShieldStatusRiskAllowed = 0x00000010u;
constexpr uint32_t kLookupShieldStatusTransactionActive = 0x00000020u;
constexpr uint32_t kLookupShieldStatusConclusionMask = 0x0000000fu;

constexpr uint32_t kLookupShieldRequestWriteInProgress = 0x80000000u;
constexpr uint32_t kLookupShieldRequestSequenceMask = 0x7fffffffu;

// v17：hook DLL 摘要字段的固定长度 = 64 位十六进制 SHA-256 + 结尾 NUL。定长而不是变长，
// 是因为它落在跨进程共享内存里：读侧必须能在不信任写侧的前提下有界读（strnlen 上界就是它）。
// 定义点在 v19 从 SharedHeader 附近前移到这里：v19 的 LookupAdmissionReport 也要用它，
// 而那个结构必须早于 SharedHeader 可见（adapter 契约要用）。
constexpr uint32_t kHookModuleDigestChars = 65;

// ══ v19 游戏内查词准入 ══════════════════════════════════════════════════
// 「本会话到底能不能游戏内查词，不能的话卡在哪一步」——这是 host 唯一需要拿来做 UI
// 决策的东西，而在 v19 之前它**在协议里根本没有位置**。
//
// 为什么不是再加一个 lookup_diag 位（两条独立理由，各自都足够）：
//  1. lookup_diag 32 位在 v18 已经用满（kLookupDiagSiglusMachineMatched = 0x80000000）。
//  2. 更要命的是语义：lookup_diag 是**粘滞累积**的诊断位，只回答"曾经发生过吗"。而准入
//     是**状态机的当前状态**。用位表达就能同时置上 IdentityRejected 和 SensorInstalled，
//     造出一个不存在的状态；读侧于是必须按某个约定的优先级去猜"现在到底算哪个"，而那个
//     约定不在协议里、只活在读者脑子里。今天三家传感器各写各的私有位（Siglus 四个 admission
//     位、Leaf 写进 FushiLeafD3DTraceV1.reserved、KiriKiri 什么都不写），host 一个都读不懂，
//     正是这个缺失的直接后果。单值枚举让不可能状态**无法被表达**，问题从根上消失。
//
// 单调性：不保证。这是"当前状态"不是"历史最高水位"，传感器卸载后退回 IdentityAccepted
// 是合法且必要的。合并多个 adapter 的报告由 registry 单点完成（取最高进展），因此跨进程
// 只有一个写者，无需 CAS。
enum LookupAdmissionState : uint32_t {
  // 尚未判定。**旧 helper 建的段读出来不保证是这个值**，所以版本门必须把旧段整体拒掉，
  // 不能靠"0 就是 Unknown"来兼容——那块内存压根没被初始化过。
  kLookupAdmissionUnknown = 0,
  // 命中的引擎 adapter 没有查词传感器（12 个 adapter 走 EngineAdapter 的默认实现落到这里）。
  // 这是"本引擎没做"，不是"装失败"——两者在 v18 的 kLookupDiagSensorInstalled 上完全同形，
  // 用户和开发者都分不出该等新版本还是该报 bug。
  kLookupAdmissionEngineUnsupported = 1,
  // 引擎有传感器，但当前 exe 不在该传感器的精确白名单里（hash-pinned fail closed）。
  // 此时 lookup_executable_sha256 必须已填，用户据此就能报出自己的版本。
  kLookupAdmissionIdentityRejected = 2,
  // 身份通过，传感器尚未装上（还在等 lookup_enabled / 主窗 / D3D 设备 / 字节签名等门）。
  kLookupAdmissionIdentityAccepted = 3,
  // 传感器已装。不声称"卡片一定出得来"——那要看几何有没有真的采到，那是 lookup_diag 的活。
  kLookupAdmissionSensorInstalled = 4,
};

// adapter → registry 的准入报告。sha256_hex 只在 IdentityRejected 时有意义（其余状态留空），
// 因为只有那一种情况需要用户把自己的 exe 身份报回来。
struct LookupAdmissionReport {
  uint32_t state = kLookupAdmissionUnknown;
  // 小写十六进制 SHA-256 + NUL；首字节为 0 表示"本次没算出/不适用"。
  char executable_sha256[kHookModuleDigestChars] = {};
};

// 把 32 字节摘要写成小写十六进制 + NUL。各 profile 在做 hash 准入时**本来就已经算过**
// 这个摘要，只是过去算完就扔；这里只负责格式化，不重新读盘也不重新哈希——多算一次
// SHA-256 要读几十 MB 的 exe，落在 Poll 线程上就是一次可感的卡顿。
inline void FormatSha256Hex(const uint8_t* digest, size_t digest_bytes,
                            char* out, size_t out_chars) {
  if (out == nullptr || out_chars == 0) return;
  out[0] = '\0';
  if (digest == nullptr || digest_bytes != 32 ||
      out_chars < kHookModuleDigestChars) {
    return;
  }
  static const char kHex[] = "0123456789abcdef";
  for (size_t i = 0; i < digest_bytes; ++i) {
    out[i * 2] = kHex[(digest[i] >> 4) & 0x0F];
    out[i * 2 + 1] = kHex[digest[i] & 0x0F];
  }
  out[digest_bytes * 2] = '\0';
}

// hook → host：用户真正提交查词时命中了哪个字符。hover 由游戏线程即时画高亮，不写这个
// 单槽，避免后到 hover 覆盖尚未被 host 消费的 submit。写侧先把 `seq` 清 0，再写 payload，
// 最后用 Interlocked 发布新 `seq`，与 VoiceClip / LoopbackMarker 同一套纪律。
struct LookupHitSlot {
  volatile uint64_t seq;   // 单调；host 据此判新。0=从未命中
  uint32_t provider_kind;  // kLookupGeometryProvider*；决定 registry 优先级
  uint32_t provider_id;    // kLookupGeometryProviderId*；具体实现的稳定身份
  // 光标落在第几个字符。**单位是 UTF-16 code unit**，不是 UTF-8 字节、不是 code point。
  //
  // 为什么是这个单位而不是随便挑一个：两端天然就都是 UTF-16——TJS 的 tjs_char 是 wchar_t
  // （UTF-16LE），Dart 的 String 下标也是 UTF-16 code unit。选它，两侧各自「就是自己的字符串
  // 下标」，零转换；选 UTF-8 字节或 code point，两端都要转，而转错的症状是**含非 ASCII 或
  // 非 BMP 字符的行整体偏移**——日文行必然含非 ASCII，也就是必错，但错得像"命中判定有点飘"
  // 而不像编码 bug，极难定位。line_utf8 用 UTF-8 只是因为它要跨 C ABI，不影响本字段单位。
  uint32_t char_index;
  uint32_t source_length;  // 命中 cluster 的 UTF-16 code unit 长度（至少 1）
  uint32_t char_count;     // 本行 UTF-16 code unit 数（自洽校验：char_index < char_count）
  uint32_t coordinate_space;  // kLookupCoordinateSpace*
  uint32_t writing_mode;      // kLookupWritingMode*；首期只发布 Horizontal
  uint64_t text_generation;      // 文本快照代际；0 非法
  uint64_t geometry_generation;  // 几何快照代际；0 非法
  int32_t glyph_x;         // 命中字形矩形，primaryLayer 坐标
  int32_t glyph_y;
  int32_t glyph_w;
  int32_t glyph_h;
  int32_t view_w;          // primaryLayer 尺寸；host 据此定位与钳制卡片
  int32_t view_h;
  uint32_t flags;          // bit0: 1=点击提交，0=悬停预览
  uint32_t line_bytes;     // line_utf8 有效字节数（<= kLookupLineBytes）
  // **整行**台词，不截断。prototype 从点击字向后截 48 字，结果是制卡拿不到完整句子；
  // 分词也不该在注入侧做——host 的分词才是全 app 唯一真值。
  uint8_t line_utf8[kLookupLineBytes];
};

constexpr uint32_t kLookupHitFlagSubmit = 0x00000001u;

// host → hook：一帧卡片位图的元数据。
//
// **两个序号是两回事，别再压成一个字段。** 早先只有一个 `seq`（既当发布序、又当"回应
// 哪次 hit"），结果 dismiss 直接死在自己手里：收卡帧复用被撤那张卡的 hit seq，而那个 seq
// 刚 present 过，注入侧的"丢弃不比已应用的新"过滤把它当陈旧帧扔了——加个 0×0 分支也救不
// 回来，因为帧压根进不了候选。这不是漏了个分支，是数据结构错了：
//   * `seq`     = **发布序**。host 每投一帧（present 或 dismiss）都 +1，单调。注入侧用它
//                 判新与去重，也用它算槽下标。
//   * `hit_seq` = 这帧**回应哪次 hit**。注入侧用它判"这张卡是不是已经被更新的命中作废了"。
// 分开之后 dismiss 就是普通一帧，不需要任何特例。
//
// **槽下标规则（两侧唯一约定，别各写各的）**：元数据槽下标与像素块下标**同为**
// `seq % lookup_frame_count`（发布序，不是 hit_seq）。host 不许用自己的轮转计数器放元数据、
// 再用 seq%N 放像素——那样注入侧会全量拒帧，而症状（卡片永远不出现）和「host 压根没投帧」
// 完全同形，真机上根本分不开。注入侧按此下标读，不一致即丢帧并置 kLookupDiagFrameRejected。
//
// `ready` **最后**写：0=host 正在写，1=可读。hook 拷完必须复查 seq/ready 未变，否则丢弃。
struct LookupFrame {
  volatile uint64_t seq;      // 发布序：host 每投一帧 +1，单调。注入侧据此判新/去重/算槽
  uint64_t hit_seq;           // 这帧回应哪次 hit；比最新 hit 旧即作废
  uint32_t flags;             // kLookupFrame* 位
  uint32_t width;             // 像素宽（dismiss 帧为 0）
  uint32_t height;            // 像素高（dismiss 帧为 0）
  // 行字节跨距，**恒为正、恒自顶向下**（>= width*4）。这块内存是我们自己的，没有理由
  // 继承任何一侧的行序怪癖。游戏 Layer 那侧的 mainImageBufferPitch 可能为负（KiriKiri
  // 自底向上），那是注入侧搬运时的事，不许漏进这个跨进程契约。
  uint32_t pitch;
  int32_t anchor_x;           // 卡片左上角，primaryLayer 坐标（host 决定，含避让与钳制）
  int32_t anchor_y;
  uint32_t highlight_start;   // 字幕高亮起始字符下标
  uint32_t highlight_len;     // 高亮字符数（0=不高亮）
  uint32_t byte_len;          // 位图有效字节数（= pitch*height，<= kLookupBitmapBytes）
  volatile uint32_t ready;    // 0=写入中，1=可读
  uint32_t reserved;
  uint32_t reserved2;
};

// LookupFrame::flags 位。
// 收卡是**普通一帧**，靠这个位自述，不靠「width==0 是收卡」这种魔法编码：后者要求每个
// 读侧都记住这条隐规则，而它和「host 投了张废帧」在字节上完全一样。
constexpr uint32_t kLookupFrameDismiss = 0x00000001u;
// 只更新高亮：不带像素，注入侧跳过整张卡片的 memcpy，只把高亮挪到新位置。
//
// 悬停时卡片内容一个像素都没变，只是高亮要换字。而普通 present 每次都要走一整轮
// 「CapturePreview → PNG 编码 → WIC 解码 → 全卡 memcpy」——鼠标划过一行就是几十次，
// 真机上直接表现为"太卡了"。高亮本来就画在游戏自己的图层上，不在卡片位图里，所以
// 这条路不需要任何像素。
constexpr uint32_t kLookupFrameHighlightOnly = 0x00000002u;
// 制卡截图期间临时隐藏卡片与选词高亮。它不是 dismiss：不推进 Esc/submit fence，也不销毁
// 当前 route；截图完成后 host 通过一张普通 full frame 恢复。hook 必须等 TJS hide/update 成功且
// 又经过一次 continuous callback 后，才把本帧 seq 写进 lookup_frame_applied_seq。
constexpr uint32_t kLookupFrameCaptureSuppress = 0x00000004u;
// hook → host：需要喂给离屏 WebView2 的卡内输入，或由注入侧判定的弹框控制事件。
struct LookupInputSlot {
  volatile uint64_t seq;  // 单调；**最后**写
  int32_t x;              // 卡片局部坐标（已减去 anchor）
  int32_t y;
  uint32_t kind;          // kLookupInput*
  int32_t wheel;          // 滚轮增量（kind==kLookupInputWheel 时有效）
  uint32_t keys;          // kLookupInputVirtualKey*；直接对应 WebView2 virtualKeys
  uint32_t reserved;
};

constexpr uint32_t kLookupInputMove = 0;
constexpr uint32_t kLookupInputLeftDown = 1;
constexpr uint32_t kLookupInputLeftUp = 2;
constexpr uint32_t kLookupInputWheel = 3;
constexpr uint32_t kLookupInputLeave = 4;
// Injected bitmap presenters cannot receive a window message for a click that
// lands on the game outside their layered HWND.  They publish this control
// event after consuming that raw DirectInput transaction so Dart can retire the
// same lookup session instead of merely hiding one stale bitmap.
constexpr uint32_t kLookupInputDismissOutside = 5;

// LookupInputSlot::keys 的跨进程真相源。数值与
// COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS 完全一致；它不是 Win32 MK_* 的任意
// “修饰键压缩表”。尤其 1 是左键、4 才是 Shift，WebView2 没有 Alt 位。
constexpr uint32_t kLookupInputVirtualKeyNone = 0x0000u;
constexpr uint32_t kLookupInputVirtualKeyLeftButton = 0x0001u;
constexpr uint32_t kLookupInputVirtualKeyRightButton = 0x0002u;
constexpr uint32_t kLookupInputVirtualKeyShift = 0x0004u;
constexpr uint32_t kLookupInputVirtualKeyControl = 0x0008u;
constexpr uint32_t kLookupInputVirtualKeyMiddleButton = 0x0010u;
constexpr uint32_t kLookupInputVirtualKeyXButton1 = 0x0020u;
constexpr uint32_t kLookupInputVirtualKeyXButton2 = 0x0040u;


// 共享内存头。injector 创建并清零、填各区偏移；hook DLL 注入后填格式、持续更新计数。
// volatile 字段跨进程无锁单写单读。绝不在此放指针（跨进程地址无意义）。
// 内存布局：[SharedHeader][音频环形 ring_capacity][文本区 TextRegionBytes()]
//           [clip 索引 kClipCount*sizeof(VoiceClip)]，各区偏移由 injector 填进 header。
// 文本区自 v13 起是 [TextLane 表][按道分块的槽区]，寻址一律走 TextLaneSlotAt。
// ── v23 adapter 运行期读数 ─────────────────────────────────────────────────
// 每个 adapter 一槽。id 是**槽自带的**，不靠下标对齐：往 generated 清单中间插一行
// 就会让下标制的读数整体错位且不报错（读到的是别人的 probe/installed）。
constexpr size_t kAdapterReportSlots = 32u;      // 当前 21 个 adapter，留一倍余量
constexpr size_t kAdapterReportIdChars = 32u;    // 最长 id "xaudio2_directsound" 19 + NUL

struct AdapterReportSlot {
  char id[kAdapterReportIdChars];  // NUL 结尾；空串 = 该槽未使用
  uint8_t applicable;              // adapter->probe()
  uint8_t installed;               // adapter->installed
  uint16_t slot_reserved;
  uint32_t flags;                  // adapter 自报的 flags（各家含义不同，只作透传）
};
static_assert(sizeof(AdapterReportSlot) == kAdapterReportIdChars + 8u,
              "AdapterReportSlot must stay tightly packed");

struct SharedHeader {
  uint32_t magic;           // = kSharedMagic
  uint32_t version;         // = kSharedVersion
  uint32_t ipc_protocol_version;     // = kStableIpcVersion
  uint32_t luna_bridge_abi_version;  // = kLunaBridgeAbiVersion
  uint32_t luna_vendored_version;    // packed 10.16.1.2
  volatile uint32_t xaudio_diagnostics;  // kXAudioDiag*（沿用原 protocol_reserved 槽）
  // v20 第二个引擎诊断字：上面那个 32 位已满（低 27 位既有 + HUNEX HFA 高 5 位）。
  // 同 reserved_luna→reserved_hook_diagnostics 的先例，另立而不是拓宽。kXAudioDiag2*。
  volatile uint32_t xaudio_diagnostics2;
  uint32_t sample_rate;     // hook 首次拿到语音格式后填
  uint32_t channels;        //
  uint32_t bits_per_sample;  //
  uint32_t is_float;        // 1 = IEEE float，0 = 整型 PCM
  uint32_t ring_capacity;   // 紧随 header 的音频环形字节数（帧对齐，≤kMaxRingBytes）
  uint32_t block_align;     // 每帧字节 = channels * bits/8（hook 填）
  volatile uint32_t write_pos;      // 下一个写入位置（0..ring_capacity）
  volatile uint32_t hooked;         // 1 = hook DLL 已注入并安装钩子（proof-of-life）
  volatile uint32_t calibrating;    // 1 = 校准模式（识别 voice callsite 中）
  volatile uint32_t text_hooked;    // 1 = 文本 hook 已装（v2）
  volatile uint64_t total_written;  // 单调累计写入音频字节（host 判断有多少可读）
  // ── v2 区偏移（injector 填，header 起算的字节偏移）──
  uint32_t text_region_offset;      // 文本环起始
  uint32_t clip_region_offset;      // clip 索引起始
  volatile uint64_t text_write_count;  // 单调：已写文本事件数（host 取 last..count 的新事件）
  volatile uint64_t clip_write_count;  // 单调：已写语音 clip 数
  // 0=尚未选定（v12 起文本环恒空）；非 0=用户在 Hibiki 选择的 TextSlot::thread_id。
  // injector 无条件过滤重复伪影，再仅写该线程/同一 hook face。
  volatile uint64_t selected_text_thread_id;
  // LunaHook（引擎精确）出干净行后 injector 置 1；置 1 后游戏内 GDI 文本 hook 让位不再写文本，
  // 消除「LunaHook 干净行 + GDI 每字重画伪影」双写者污染。音频写入不受此标志影响。GDI 仅在
  // luna_active==0（LunaHook 未覆盖该引擎）时作兜底文本源。
  volatile uint32_t luna_active;
  uint32_t reserved_luna;  // 32 位引擎诊断位（已满，loopback 另立字段）
  // Helper 自身诊断位。不能复用 reserved_luna：其 32 位已被各引擎探针占满，且 Siglus
  // 原始 OGG dump 也使用最高位。v10 单独扩展，避免启动同步与 Siglus 状态互相误判。
  volatile uint32_t hook_diagnostics;
  uint32_t reserved_hook_diagnostics;
  volatile uint64_t unity_voice_write_count;
  UnityVoiceEvent unity_voice_events[kUnityVoiceEventCount];
  // ── v6 loopback 区（injector 填偏移/容量，hook 侧 loopback 线程填格式/计数）──
  // 内存布局尾部追加：[...clip 索引][loopback 环 loopback_ring_capacity][标记表 kLoopbackMarkerCount*LoopbackMarker]
  uint32_t loopback_ring_offset;       // loopback 环起始（header 起算字节偏移）
  uint32_t loopback_ring_capacity;     // loopback 环字节容量（帧对齐）
  uint32_t loopback_marker_offset;     // 标记表起始（header 起算字节偏移）
  uint32_t loopback_marker_slot_count;  // 标记表槽数（= kLoopbackMarkerCount，冗余便于 reader 自洽）
  uint32_t loopback_sample_rate;       // loopback 混音采样率（GetMixFormat 后 hook 填）
  uint32_t loopback_channels;          // 混音声道数
  uint32_t loopback_bits_per_sample;   // 存入环的位深（固定 16，混音 float32 已转换）
  uint32_t loopback_block_align;       // 每帧字节 = channels*bits/8（存储格式；hook 填，作格式就绪信号）
  volatile uint32_t loopback_write_pos;  // 下一写入位置（0..loopback_ring_capacity）
  volatile uint32_t loopback_diag;       // kLoopbackDiag*（跨 worker 代际原子 OR）
  volatile uint64_t loopback_total_written;  // 单调累计写入 loopback 字节（reader 判可读量/覆盖）
  volatile uint64_t loopback_marker_count;   // 单调累计已写标记数
  // ── v12 线程预览区（injector 填偏移/槽数，写入者是 Luna 回调路径）──
  // 内存布局尾部再追加：[...标记表][线程预览区 thread_preview_slot_count*ThreadPreviewSlot]
  uint32_t thread_preview_offset;      // 线程预览区起始（header 起算字节偏移）
  uint32_t thread_preview_slot_count;  // 槽数（= kThreadPreviewCount，冗余便于 reader 自洽）
  // 单调累计预览变更次数（含 partial TextMesh 快照）。host 只用它判断「有没有新预览」；
  // 预览槽本身按
  // thread_id 寻址，不靠这个序号定位（与文本环的 text_write_count 语义不同，勿照搬）。
  volatile uint64_t thread_preview_write_count;
  // ── v13 文本分道（injector 填，冗余便于 reader 自洽；道表位于 text_region_offset 处）──
  // 布局：[TextLane 表 text_lane_count 条][槽区 text_lane_count*text_lane_slot_count*kTextSlotBytes]
  uint32_t text_lane_count;
  uint32_t text_lane_slot_count;
  // 道用尽时的两个计数（host 必须能把「道满」和「hook 压根没出文本」分开）。
  //
  // 为什么非有不可：v13 放开非胜出线程**本身就抬高了道满概率**（以前只有选定线程在写，
  // 现在每条线程都要占一条道）。而道满的症状——某些线程的台词就是不来——与它要根治的
  // 256 槽挤压**完全同形**。没有这两个数，真机上根本分不出「分道没生效」和「道不够用」，
  // 等于把要修的病换个地方藏起来。
  volatile uint64_t text_lane_recycle_count;   // 回收了一条最久未写的非选定道
  volatile uint64_t text_lane_overflow_count;  // 连可回收的道都没有，本行被丢弃
  // ── v14 游戏内查词区（injector 填偏移/容量；追加在布局最尾，前面各区偏移不动）────
  uint32_t lookup_region_offset;      // 查词区起始（header 起算字节偏移；0=本会话无此区）
  uint32_t lookup_bitmap_bytes;       // 单缓冲位图字节容量（= kLookupBitmapBytes，冗余自洽）
  uint32_t lookup_frame_count;        // 位图缓冲数（= kLookupFrameCount，冗余自洽）
  uint32_t lookup_input_slot_count;   // 输入环槽数（= kLookupInputSlotCount，冗余自洽）
  volatile uint64_t lookup_hit_count;    // hook→host 单调：命中事件数
  volatile uint64_t lookup_frame_count_written;  // host→hook 单调：已投位图帧数
  volatile uint64_t lookup_input_count;  // hook→host 单调：已转发的卡片输入事件数
  // host→hook 开关。取代 prototype 的 FUSHI_KIRIKIRI_LOOKUP_* 环境变量——把认证 token
  // 塞进游戏进程环境块是安全缺陷（任何拿得到 PROCESS_QUERY_INFORMATION 的进程都能读），
  // 且环境变量在进程启动后改不了，做不到运行期开关。形态照抄 selected_text_thread_id。
  volatile uint32_t lookup_enabled;
  volatile uint32_t lookup_diag;      // kLookupDiag* 位
  // hook→host：只确认 kLookupFrameCaptureSuppress。值是已经在 TJS hide/update 后又跨过
  // 一次 continuous callback 的最高 LookupFrame::seq。普通 present/dismiss 不得推进它，
  // 否则一张更晚的普通帧会伪装成“截图抑制已经安全生效”。
  volatile uint64_t lookup_frame_applied_seq;
  // ── v16 injected WASAPI loopback policy（纯追加；host/injector→hook→host）─────────
  // producer 先以 request_seq 最高位取得写令牌，再写 requested，最后发布非零稳定 seq；
  // hook 在写令牌存在时 fail closed，且只把 exact 1 当 allow。
  // hook 先写 state，只有完成相应生命周期动作后才最后写 applied_seq。特别地，deny 的
  // applied_seq==request_seq 且 state==stopped 保证 Stop/Release/worker join 均已完成。
  volatile uint32_t native_loopback_requested;
  volatile uint32_t native_loopback_request_seq;
  volatile uint32_t native_loopback_state;
  volatile uint32_t native_loopback_applied_seq;
  // ── v17 驻留 hook DLL 构建身份（纯追加；创建映射的 injector 写，下一次 injector 读）──
  // 64 位小写十六进制 SHA-256 + NUL；全 0 表示「本次注入算不出摘要」，读侧据此走
  // kDigestUnavailable（有界重试），绝不当成 mismatch 去要求用户重启游戏。
  // 只在**新建映射**时写一次，复用既有映射时一个字节都不碰——那条记录属于当初真正
  // 完成注入的那次会话，被本次请求覆盖就等于把要比对的证据自己抹掉了。
  char hook_module_sha256[kHookModuleDigestChars];
  // ── v19 单一几何 provider 状态（hook/host 共读；registry 单写）────────────
  // active_kind/id/status/text_generation 先写，geometry_generation 最后发布。消费者看到
  // generation==0 即尚无权威 provider，绝不能把别处文本与当前几何拼在一起。
  volatile uint32_t lookup_geometry_active_kind;
  volatile uint32_t lookup_geometry_active_id;
  volatile uint32_t lookup_geometry_status;
  uint32_t lookup_geometry_reserved;
  volatile uint64_t lookup_geometry_text_generation;
  volatile uint64_t lookup_geometry_generation;
  // ── v19 统一输入盾控制（host→hook request；状态方→host ack）──────────────
  // request_seq 的最高位是写令牌。发布顺序固定为：取得令牌 → 填 owner/target/transaction/
  // buttons/risk → 最后写稳定 request_seq。active_buttons 非零表示 down/up transaction 尚未
  // 排空，几何 registry 不得在此期间切换 provider。
  volatile uint32_t lookup_shield_request_seq;
  volatile uint32_t lookup_shield_owner_kind;
  volatile uint64_t lookup_shield_target_hwnd;
  volatile uint64_t lookup_shield_transaction_id;
  volatile uint32_t lookup_shield_active_buttons;
  volatile uint32_t lookup_shield_allow_risk;
  // required/ready/observed/fault/status 先写，applied_seq 最后确认。不同输入面必须用各自位，
  // 不得拿“装了某个 detour”推断另一输入面 ready。
  volatile uint32_t lookup_shield_required_mask;
  volatile uint32_t lookup_shield_ready_mask;
  volatile uint32_t lookup_shield_observed_mask;
  volatile uint32_t lookup_shield_fault_mask;
  volatile uint32_t lookup_shield_status_flags;
  uint32_t lookup_shield_reserved;
  volatile uint32_t lookup_shield_applied_seq;
  uint32_t lookup_shield_reserved2;
  // ── v19 geometry admission（host→hook request；registry→host ack）──────
  // mode/flags are payload; request_seq is published last.  applied_seq may
  // advance only after the registry has reached the requested owner policy,
  // including any deferred down/up/tail provider transition.
  volatile uint32_t lookup_geometry_admission_mode;
  volatile uint32_t lookup_geometry_admission_flags;
  volatile uint32_t lookup_geometry_admission_request_seq;
  volatile uint32_t lookup_geometry_admission_applied_seq;
  // ── v19 游戏内查词准入（纯追加；hook→host）──────────────────────────────
  // 写者唯一：AdapterRegistry::Poll 每轮汇总所有 adapter 的 lookupAdmission() 后写这里。
  // 各 adapter 自己不碰这三个字段——多写者会让「Leaf 说身份不符」和「Siglus 说本引擎没做」
  // 互相覆盖，而两条都"对"，只是说的不是同一个 adapter。汇总点唯一，竞争就不存在。
  volatile uint32_t lookup_admission;      // kLookupAdmissionState 单值（**不是位或**）
  // 单调发布序号；0 = 从未上报过。写侧先写 admission/sha256，再发布 seq，读侧据此
  // 判"这份快照写完了"。与 VoiceClip / LookupHitSlot 同一套纪律。
  volatile uint32_t lookup_admission_seq;
  // 当前游戏主 exe 的小写十六进制 SHA-256 + NUL。只有 kLookupAdmissionIdentityRejected
  // 时保证有值：那是唯一需要用户把自己的版本身份报回来的情形（hash-pinned 白名单不中）。
  // 有界读——上界就是 kHookModuleDigestChars，绝不假设写侧给了 NUL。
  char lookup_executable_sha256[kHookModuleDigestChars];
  // ── BUG-2136 引擎层原点（双向；纯追加）────────────────────────────────────
  // 背景：HUNEX/GGE 的正文字形位置是**文本层局部坐标**（1920x1080 逻辑单位），
  // client = (render + origin) * client/(design_w, design_h) 已在两种窗口尺寸 × 三条行
  // 上实测成立。origin 是每作一个常量，但**游戏内存里读不到现成的**——item 前 0x70 字节、
  // render_item 另三个参数、body_submit 调用帧 0x000..0x180、viewport/scale 全局邻域
  // 四处都排除过。所以由**宿主**抓一帧画面自动解出来，再回传给注入侧。
  //
  // hook→host：当前行在层空间的包围盒 + 设计分辨率。宿主据此预测「墨迹应该在哪」，
  // 与实拍的墨迹框做二维平移求解。line_seq 单调，0=尚无。
  volatile uint32_t lookup_layer_line_seq;
  volatile uint32_t lookup_layer_design_w;
  volatile uint32_t lookup_layer_design_h;
  volatile uint32_t lookup_layer_glyph_count;
  volatile int32_t lookup_layer_line_left;
  volatile int32_t lookup_layer_line_top;
  volatile int32_t lookup_layer_line_right;
  volatile int32_t lookup_layer_line_bottom;
  // host→hook：解出来的层原点。origin_seq 最后写；0=宿主尚未给出，注入侧此时**不得**
  // 假装几何可用（fail-closed，照常退回贴合层）。
  volatile int32_t lookup_layer_origin_x;
  volatile int32_t lookup_layer_origin_y;
  volatile uint32_t lookup_layer_origin_seq;
  uint32_t lookup_layer_reserved;
  // ── v23 adapter 运行期读数（纯追加；hook→host）──────────────────────────
  // 写者唯一：AdapterRegistry::Poll 每轮把每个 adapter 的 diagnostics() 抄进来，
  // 与 lookup_admission 同一处、同一套纪律（内容先写，seq 最后发布）。
  // 各 adapter 自己不碰这块——多写者会让"谁在第几槽"取决于调用顺序。
  AdapterReportSlot adapter_reports[kAdapterReportSlots];
  volatile uint32_t adapter_report_count;  // 实际使用的槽数，<= kAdapterReportSlots
  volatile uint32_t adapter_report_seq;    // 单调；0 = 从未上报过（≠"没有 adapter"）
};
#pragma pack(pop)

// ── BUG-2136 层原点：两侧读写器 ─────────────────────────────────────────────
struct LookupLayerLineSnapshot {
  uint32_t seq = 0;
  uint32_t design_w = 0;
  uint32_t design_h = 0;
  uint32_t glyph_count = 0;
  int32_t left = 0, top = 0, right = 0, bottom = 0;
  bool valid = false;
};

struct LookupGeometryAdmissionSnapshot {
  uint32_t seq = 0;
  uint32_t mode = kLookupGeometryAdmissionDisabled;
  uint32_t flags = 0;
  bool valid = false;

  bool attached_ready() const {
    return (flags & kLookupGeometryAdmissionFlagAttachedReady) != 0;
  }

  bool native_input_allowed() const {
    return (flags & kLookupGeometryAdmissionFlagNativeInputAllowed) != 0;
  }
};

struct LookupShieldRequestSnapshot {
  uint32_t seq = 0;
  uint32_t owner_kind = kLookupShieldOwnerNone;
  uint64_t target_hwnd = 0;
  uint64_t transaction_id = 0;
  uint32_t active_buttons = 0;
  bool allow_risk = false;
  bool valid = false;
};

struct LookupShieldStatusPublication {
  uint32_t required_mask = 0;
  uint32_t ready_mask = 0;
  uint32_t observed_mask = 0;
  uint32_t fault_mask = 0;
  uint32_t status_flags = 0;
};

struct NativeLoopbackRequestSnapshot {
  uint32_t requested = kNativeLoopbackDeny;
  uint32_t seq = 0;
  bool valid = false;
};

// All v16 control words are aligned 32-bit values. Interlocked access is used
// instead of relying on volatile for cross-process ordering (and stays atomic
// on both Win32 and x64).
inline uint32_t AtomicLoadShared32(const volatile uint32_t* value) {
  if (value == nullptr) return 0;
  auto* word = reinterpret_cast<volatile LONG*>(
      const_cast<volatile uint32_t*>(value));
  return static_cast<uint32_t>(InterlockedCompareExchange(word, 0, 0));
}

inline void AtomicStoreShared32(volatile uint32_t* value, uint32_t desired) {
  if (value == nullptr) return;
  InterlockedExchange(reinterpret_cast<volatile LONG*>(value),
                      static_cast<LONG>(desired));
}

inline void AtomicOrShared32(volatile uint32_t* value, uint32_t bits) {
  if (value == nullptr) return;
  InterlockedOr(reinterpret_cast<volatile LONG*>(value),
                static_cast<LONG>(bits));
}

// Host-side attached hit publication and the injected provider registry share
// the shield request writer bit as their hand-off fence.  Callers which hold
// that fence may use this bounded, lock-free snapshot to decide whether an
// AttachedGlyph down still owns geometry.  Ready is deliberately usable before
// the first hit; Active must name one complete text+geometry publication.
inline bool LookupGeometryAttachedProviderOwns(const SharedHeader* header) {
  if (header == nullptr) return false;
  for (int attempt = 0; attempt < 4; ++attempt) {
    const uint64_t generation_before =
        AtomicLoadPreview64(&header->lookup_geometry_generation);
    const uint32_t kind =
        AtomicLoadShared32(&header->lookup_geometry_active_kind);
    const uint32_t id =
        AtomicLoadShared32(&header->lookup_geometry_active_id);
    const uint32_t status =
        AtomicLoadShared32(&header->lookup_geometry_status);
    const uint64_t text_generation =
        AtomicLoadPreview64(&header->lookup_geometry_text_generation);
    MemoryBarrier();
    const uint64_t generation_after =
        AtomicLoadPreview64(&header->lookup_geometry_generation);
    if (generation_before != generation_after) continue;
    if (kind != kLookupGeometryProviderAttachedCalibrated ||
        id != kLookupGeometryProviderIdAttachedCalibrated) {
      return false;
    }
    return status == kLookupGeometryStatusReady ||
           (status == kLookupGeometryStatusActive && generation_after != 0 &&
            text_generation != 0);
  }
  return false;
}

inline constexpr bool IsLookupGeometryAdmissionMode(uint32_t mode) {
  return mode == kLookupGeometryAdmissionDisabled ||
         mode == kLookupGeometryAdmissionAuto ||
         mode == kLookupGeometryAdmissionNativeOnly ||
         mode == kLookupGeometryAdmissionAttachedOnly;
}

inline LookupGeometryAdmissionSnapshot ReadLookupGeometryAdmission(
    const SharedHeader* header) {
  LookupGeometryAdmissionSnapshot result;
  if (header == nullptr) return result;
  for (int attempt = 0; attempt < 8; ++attempt) {
    const uint32_t before =
        AtomicLoadShared32(&header->lookup_geometry_admission_request_seq);
    if (before == 0 ||
        (before & kLookupGeometryAdmissionWriteInProgress) != 0) {
      continue;
    }
    const uint32_t mode =
        AtomicLoadShared32(&header->lookup_geometry_admission_mode);
    const uint32_t flags =
        AtomicLoadShared32(&header->lookup_geometry_admission_flags);
    MemoryBarrier();
    const uint32_t after =
        AtomicLoadShared32(&header->lookup_geometry_admission_request_seq);
    if (before == after &&
        (after & kLookupGeometryAdmissionWriteInProgress) == 0 &&
        IsLookupGeometryAdmissionMode(mode) &&
        (flags & ~kLookupGeometryAdmissionFlagMask) == 0) {
      result.seq = after;
      result.mode = mode;
      result.flags = flags;
      result.valid = true;
      return result;
    }
  }
  return LookupGeometryAdmissionSnapshot{};
}

// Host-side publication.  Geometry ownership is a separate control plane
// from lookup_enabled so switching to attached never tears down the injected
// generic shield.  The helper is idempotent across repeated Flutter syncs.
inline uint32_t PublishLookupGeometryAdmission(
    SharedHeader* header, uint32_t mode, bool attached_ready,
    bool native_input_allowed = false) {
  if (header == nullptr || !IsLookupGeometryAdmissionMode(mode)) return 0;
  const uint32_t flags =
      (attached_ready ? kLookupGeometryAdmissionFlagAttachedReady : 0u) |
      (native_input_allowed
           ? kLookupGeometryAdmissionFlagNativeInputAllowed
           : 0u);
  const LookupGeometryAdmissionSnapshot stable =
      ReadLookupGeometryAdmission(header);
  if (stable.valid && stable.mode == mode && stable.flags == flags) {
    return stable.seq;
  }

  auto* seq = reinterpret_cast<volatile LONG*>(
      &header->lookup_geometry_admission_request_seq);
  uint32_t current = 0;
  bool claimed = false;
  const ULONGLONG claim_deadline = GetTickCount64() + 1000;
  do {
    current = AtomicLoadShared32(
        &header->lookup_geometry_admission_request_seq);
    if ((current & kLookupGeometryAdmissionWriteInProgress) != 0) {
      SwitchToThread();
      continue;
    }
    const uint32_t token =
        current | kLookupGeometryAdmissionWriteInProgress;
    const LONG observed = InterlockedCompareExchange(
        seq, static_cast<LONG>(token), static_cast<LONG>(current));
    if (static_cast<uint32_t>(observed) == current) {
      claimed = true;
      break;
    }
  } while (GetTickCount64() < claim_deadline);
  if (!claimed) return 0;

  AtomicStoreShared32(&header->lookup_geometry_admission_mode, mode);
  AtomicStoreShared32(&header->lookup_geometry_admission_flags, flags);
  uint32_t published =
      (current & kLookupGeometryAdmissionSequenceMask) + 1u;
  published &= kLookupGeometryAdmissionSequenceMask;
  if (published == 0) published = 1;
  AtomicStoreShared32(&header->lookup_geometry_admission_request_seq,
                      published);
  return published;
}

// Update only the semantic-input bit while preserving the current geometry
// owner policy and attached-ready offer.  ReaderState serialises host writers;
// this helper still uses the same request seqlock so injected readers never
// accept a half-updated flag set.  A mapping without a stable geometry request
// is fail-closed and must be initialised by PublishLookupGeometryAdmission.

inline LookupShieldRequestSnapshot ReadLookupShieldRequest(
    const SharedHeader* header) {
  LookupShieldRequestSnapshot result;
  if (header == nullptr) return result;
  for (int attempt = 0; attempt < 8; ++attempt) {
    const uint32_t before =
        AtomicLoadShared32(&header->lookup_shield_request_seq);
    if (before == 0 ||
        (before & kLookupShieldRequestWriteInProgress) != 0) {
      continue;
    }
    result.owner_kind =
        AtomicLoadShared32(&header->lookup_shield_owner_kind);
    result.target_hwnd =
        AtomicLoadPreview64(&header->lookup_shield_target_hwnd);
    result.transaction_id =
        AtomicLoadPreview64(&header->lookup_shield_transaction_id);
    result.active_buttons =
        AtomicLoadShared32(&header->lookup_shield_active_buttons) &
        kLookupShieldButtonMask;
    result.allow_risk =
        AtomicLoadShared32(&header->lookup_shield_allow_risk) != 0;
    MemoryBarrier();
    const uint32_t after =
        AtomicLoadShared32(&header->lookup_shield_request_seq);
    if (before == after &&
        (after & kLookupShieldRequestWriteInProgress) == 0) {
      result.seq = after;
      result.valid = true;
      return result;
    }
  }
  return LookupShieldRequestSnapshot{};
}

inline bool LookupShieldRequestMatches(
    const SharedHeader* header,
    const LookupShieldRequestSnapshot& expected) {
  const LookupShieldRequestSnapshot current = ReadLookupShieldRequest(header);
  return expected.valid && current.valid && current.seq == expected.seq &&
         current.owner_kind == expected.owner_kind &&
         current.target_hwnd == expected.target_hwnd &&
         current.transaction_id == expected.transaction_id &&
         current.active_buttons == expected.active_buttons &&
         current.allow_risk == expected.allow_risk;
}

// host 侧统一发布入口。active_buttons==0 是 release 请求；新的 release 仍是一个新代际，
// 只有所有输入面排空 tail 并回写 applied_seq 后才能视为完成。
inline uint32_t PublishLookupShieldRequest(
    SharedHeader* header, uint32_t owner_kind, uint64_t target_hwnd,
    uint64_t transaction_id, uint32_t active_buttons, bool allow_risk) {
  if (header == nullptr) return 0;
  const uint32_t normalized_buttons =
      active_buttons & kLookupShieldButtonMask;
  const uint32_t normalized_risk = allow_risk ? 1u : 0u;
  const LookupShieldRequestSnapshot stable =
      ReadLookupShieldRequest(header);
  if (stable.valid && stable.owner_kind == owner_kind &&
      stable.target_hwnd == target_hwnd &&
      stable.transaction_id == transaction_id &&
      stable.active_buttons == normalized_buttons &&
      stable.allow_risk == allow_risk) {
    return stable.seq;
  }

  auto* seq = reinterpret_cast<volatile LONG*>(
      &header->lookup_shield_request_seq);
  uint32_t current = 0;
  bool claimed = false;
  const ULONGLONG claim_deadline = GetTickCount64() + 1000;
  do {
    current = AtomicLoadShared32(&header->lookup_shield_request_seq);
    if ((current & kLookupShieldRequestWriteInProgress) != 0) {
      SwitchToThread();
      continue;
    }
    const uint32_t token = current | kLookupShieldRequestWriteInProgress;
    const LONG observed = InterlockedCompareExchange(
        seq, static_cast<LONG>(token), static_cast<LONG>(current));
    if (static_cast<uint32_t>(observed) == current) {
      claimed = true;
      break;
    }
  } while (GetTickCount64() < claim_deadline);
  if (!claimed) return 0;

  AtomicStoreShared32(&header->lookup_shield_owner_kind, owner_kind);
  AtomicStorePreview64(&header->lookup_shield_target_hwnd, target_hwnd);
  AtomicStorePreview64(&header->lookup_shield_transaction_id, transaction_id);
  AtomicStoreShared32(&header->lookup_shield_active_buttons,
                      normalized_buttons);
  AtomicStoreShared32(&header->lookup_shield_allow_risk, normalized_risk);
  uint32_t published =
      (current & kLookupShieldRequestSequenceMask) + 1u;
  published &= kLookupShieldRequestSequenceMask;
  if (published == 0) published = 1;
  AtomicStoreShared32(&header->lookup_shield_request_seq, published);
  return published;
}

inline uint32_t NormalizeLookupShieldStatusFlags(
    const LookupShieldRequestSnapshot& request,
    const LookupShieldStatusPublication& publication) {
  uint32_t runtime = publication.status_flags &
                     (kLookupShieldStatusRiskAllowed |
                      kLookupShieldStatusTransactionActive);
  if (request.allow_risk) runtime |= kLookupShieldStatusRiskAllowed;
  if (request.active_buttons != 0) {
    runtime |= kLookupShieldStatusTransactionActive;
  }
  const uint32_t required = publication.required_mask &
                            kLookupShieldSurfaceMask;
  const uint32_t ready = publication.ready_mask & kLookupShieldSurfaceMask;
  const uint32_t fault = publication.fault_mask & kLookupShieldSurfaceMask;
  const uint32_t requested_conclusion =
      publication.status_flags & kLookupShieldStatusConclusionMask;
  if (fault != 0 ||
      (requested_conclusion & kLookupShieldStatusFaulted) != 0) {
    return runtime | kLookupShieldStatusFaulted;
  }
  if ((requested_conclusion & kLookupShieldStatusKnownUncovered) != 0) {
    return runtime | kLookupShieldStatusKnownUncovered;
  }
  // verified is deliberately stricter than "covers required": an unexpected
  // extra ready surface means the producer and consumer disagree about the
  // transaction contract, so it must remain partial until the masks match.
  const bool fully_ready = required != 0 && ready == required;
  if ((requested_conclusion & kLookupShieldStatusVerified) != 0 &&
      fully_ready &&
      (runtime & kLookupShieldStatusRiskAllowed) == 0) {
    return runtime | kLookupShieldStatusVerified;
  }
  if ((requested_conclusion & kLookupShieldStatusPartial) != 0 || ready != 0 ||
      (requested_conclusion & kLookupShieldStatusVerified) != 0) {
    return runtime | kLookupShieldStatusPartial;
  }
  return runtime;  // unknown
}

// 状态 payload 先写，applied_seq 最后写。verified 只有在 required 非空、ready 完全相等、
// fault 为空且请求没有 allow_risk 时才保留；否则 helper 至少降为 partial。
inline bool PublishLookupShieldStatus(
    SharedHeader* header, const LookupShieldRequestSnapshot& request,
    const LookupShieldStatusPublication& publication) {
  if (header == nullptr || !LookupShieldRequestMatches(header, request)) {
    return false;
  }
  const uint32_t required = publication.required_mask &
                            kLookupShieldSurfaceMask;
  const uint32_t ready = publication.ready_mask & kLookupShieldSurfaceMask;
  const uint32_t observed = publication.observed_mask &
                            kLookupShieldSurfaceMask;
  const uint32_t fault = publication.fault_mask & kLookupShieldSurfaceMask;
  const uint32_t status =
      NormalizeLookupShieldStatusFlags(request, publication);
  AtomicStoreShared32(&header->lookup_shield_required_mask, required);
  AtomicStoreShared32(&header->lookup_shield_ready_mask, ready);
  AtomicStoreShared32(&header->lookup_shield_observed_mask, observed);
  AtomicStoreShared32(&header->lookup_shield_fault_mask, fault);
  AtomicStoreShared32(&header->lookup_shield_status_flags, status);
  if (!LookupShieldRequestMatches(header, request)) return false;
  AtomicStoreShared32(&header->lookup_shield_applied_seq, request.seq);
  return LookupShieldRequestMatches(header, request);
}

// v19 查词准入：hook 侧发布。payload 先落，seq 最后发布——读侧看到新 seq 就保证
// admission/sha256 已经写完。写者唯一（registry 汇总点），所以不需要写令牌。
//
// 只在**内容真的变了**时推进 seq：registry 每 16~200ms 就 Poll 一次，稳态下无脑推 seq
// 会让 host 每轮都当成新事件去刷 UI。返回值告诉调用方这轮有没有发生变化。
// hook 侧发布：payload 先写，seq 最后写。内容没变就不推进 seq——宿主每轮都在轮询，
// 无脑推序号会让它把同一行当成新行反复重解原点。
inline bool PublishLookupLayerLine(SharedHeader* header, uint32_t design_w,
                                   uint32_t design_h, uint32_t glyph_count,
                                   int32_t left, int32_t top, int32_t right,
                                   int32_t bottom) {
  if (header == nullptr || design_w == 0u || design_h == 0u ||
      glyph_count == 0u || right <= left || bottom <= top) {
    return false;
  }
  const bool same =
      AtomicLoadShared32(&header->lookup_layer_design_w) == design_w &&
      AtomicLoadShared32(&header->lookup_layer_design_h) == design_h &&
      AtomicLoadShared32(&header->lookup_layer_glyph_count) == glyph_count &&
      static_cast<int32_t>(AtomicLoadShared32(
          reinterpret_cast<volatile uint32_t*>(
              &header->lookup_layer_line_left))) == left &&
      static_cast<int32_t>(AtomicLoadShared32(
          reinterpret_cast<volatile uint32_t*>(
              &header->lookup_layer_line_top))) == top &&
      static_cast<int32_t>(AtomicLoadShared32(
          reinterpret_cast<volatile uint32_t*>(
              &header->lookup_layer_line_right))) == right &&
      static_cast<int32_t>(AtomicLoadShared32(
          reinterpret_cast<volatile uint32_t*>(
              &header->lookup_layer_line_bottom))) == bottom;
  if (same && AtomicLoadShared32(&header->lookup_layer_line_seq) != 0u) {
    return false;
  }
  AtomicStoreShared32(&header->lookup_layer_design_w, design_w);
  AtomicStoreShared32(&header->lookup_layer_design_h, design_h);
  AtomicStoreShared32(&header->lookup_layer_glyph_count, glyph_count);
  AtomicStoreShared32(
      reinterpret_cast<volatile uint32_t*>(&header->lookup_layer_line_left),
      static_cast<uint32_t>(left));
  AtomicStoreShared32(
      reinterpret_cast<volatile uint32_t*>(&header->lookup_layer_line_top),
      static_cast<uint32_t>(top));
  AtomicStoreShared32(
      reinterpret_cast<volatile uint32_t*>(&header->lookup_layer_line_right),
      static_cast<uint32_t>(right));
  AtomicStoreShared32(
      reinterpret_cast<volatile uint32_t*>(&header->lookup_layer_line_bottom),
      static_cast<uint32_t>(bottom));
  AtomicStoreShared32(&header->lookup_layer_line_seq,
                      AtomicLoadShared32(&header->lookup_layer_line_seq) + 1u);
  return true;
}

// host 侧读取。seq==0 表示注入侧还没发布过任何一行，宿主此时无从求解。
inline LookupLayerLineSnapshot ReadLookupLayerLine(const SharedHeader* header) {
  LookupLayerLineSnapshot out;
  if (header == nullptr) return out;
  auto* mutable_header = const_cast<SharedHeader*>(header);
  const uint32_t seq =
      AtomicLoadShared32(&mutable_header->lookup_layer_line_seq);
  if (seq == 0u) return out;
  out.seq = seq;
  out.design_w = AtomicLoadShared32(&mutable_header->lookup_layer_design_w);
  out.design_h = AtomicLoadShared32(&mutable_header->lookup_layer_design_h);
  out.glyph_count =
      AtomicLoadShared32(&mutable_header->lookup_layer_glyph_count);
  out.left = static_cast<int32_t>(AtomicLoadShared32(
      reinterpret_cast<volatile uint32_t*>(
          &mutable_header->lookup_layer_line_left)));
  out.top = static_cast<int32_t>(AtomicLoadShared32(
      reinterpret_cast<volatile uint32_t*>(
          &mutable_header->lookup_layer_line_top)));
  out.right = static_cast<int32_t>(AtomicLoadShared32(
      reinterpret_cast<volatile uint32_t*>(
          &mutable_header->lookup_layer_line_right)));
  out.bottom = static_cast<int32_t>(AtomicLoadShared32(
      reinterpret_cast<volatile uint32_t*>(
          &mutable_header->lookup_layer_line_bottom)));
  // 再读一次 seq：中途被改过就当这份快照没读到（与其它槽同一套纪律）。
  if (AtomicLoadShared32(&mutable_header->lookup_layer_line_seq) != seq) {
    return LookupLayerLineSnapshot{};
  }
  out.valid = out.design_w != 0u && out.design_h != 0u &&
              out.glyph_count != 0u && out.right > out.left &&
              out.bottom > out.top;
  return out;
}

// host 侧发布原点：payload 先写，seq 最后写。
inline bool PublishLookupLayerOrigin(SharedHeader* header, int32_t origin_x,
                                     int32_t origin_y) {
  if (header == nullptr) return false;
  AtomicStoreShared32(
      reinterpret_cast<volatile uint32_t*>(&header->lookup_layer_origin_x),
      static_cast<uint32_t>(origin_x));
  AtomicStoreShared32(
      reinterpret_cast<volatile uint32_t*>(&header->lookup_layer_origin_y),
      static_cast<uint32_t>(origin_y));
  AtomicStoreShared32(
      &header->lookup_layer_origin_seq,
      AtomicLoadShared32(&header->lookup_layer_origin_seq) + 1u);
  return true;
}

// hook 侧读取原点。返回 false = 宿主还没给，注入侧必须 fail-closed。
inline bool ReadLookupLayerOrigin(const SharedHeader* header, int32_t* out_x,
                                  int32_t* out_y) {
  if (header == nullptr || out_x == nullptr || out_y == nullptr) return false;
  auto* mutable_header = const_cast<SharedHeader*>(header);
  const uint32_t seq =
      AtomicLoadShared32(&mutable_header->lookup_layer_origin_seq);
  if (seq == 0u) return false;
  const int32_t x = static_cast<int32_t>(AtomicLoadShared32(
      reinterpret_cast<volatile uint32_t*>(
          &mutable_header->lookup_layer_origin_x)));
  const int32_t y = static_cast<int32_t>(AtomicLoadShared32(
      reinterpret_cast<volatile uint32_t*>(
          &mutable_header->lookup_layer_origin_y)));
  if (AtomicLoadShared32(&mutable_header->lookup_layer_origin_seq) != seq) {
    return false;
  }
  *out_x = x;
  *out_y = y;
  return true;
}

inline bool PublishLookupAdmission(SharedHeader* header,
                                   const LookupAdmissionReport& report) {
  if (header == nullptr) return false;
  const uint32_t previous = AtomicLoadShared32(&header->lookup_admission);
  const bool same_state = previous == report.state;
  const bool same_digest =
      std::strncmp(const_cast<const char*>(header->lookup_executable_sha256),
                   report.executable_sha256, kHookModuleDigestChars) == 0;
  if (same_state && same_digest &&
      AtomicLoadShared32(&header->lookup_admission_seq) != 0) {
    return false;
  }
  AtomicStoreShared32(&header->lookup_admission, report.state);
  std::memcpy(const_cast<char*>(header->lookup_executable_sha256),
              report.executable_sha256, kHookModuleDigestChars);
  // 结尾 NUL 由写侧保证，读侧仍按有界读处理（写侧可能是别的构建）。
  const_cast<char*>(header->lookup_executable_sha256)[kHookModuleDigestChars - 1] = '\0';
  AtomicStoreShared32(&header->lookup_admission_seq,
                      AtomicLoadShared32(&header->lookup_admission_seq) + 1);
  return true;
}

// host 侧读取。seq==0 表示 hook 从未上报过（例如 helper 还没起来），此时**不能**当成
// EngineUnsupported 去把开关灰掉——"还不知道"和"确定不支持"是两件事，混在一起就会在
// 每次启动的头几百毫秒里误报"本引擎不支持"。
inline LookupAdmissionReport ReadLookupAdmission(const SharedHeader* header,
                                                 uint32_t* out_seq = nullptr) {
  LookupAdmissionReport report;
  if (out_seq != nullptr) *out_seq = 0;
  if (header == nullptr) return report;
  const uint32_t seq = AtomicLoadShared32(&header->lookup_admission_seq);
  if (out_seq != nullptr) *out_seq = seq;
  if (seq == 0) return report;
  report.state = AtomicLoadShared32(&header->lookup_admission);
  if (report.state > kLookupAdmissionSensorInstalled) {
    // 写侧给了本构建不认识的值：当作"还不知道"，绝不猜。
    report.state = kLookupAdmissionUnknown;
    return report;
  }
  const char* digest =
      const_cast<const char*>(header->lookup_executable_sha256);
  const size_t length = ::strnlen(digest, kHookModuleDigestChars - 1);
  std::memcpy(report.executable_sha256, digest, length);
  report.executable_sha256[length] = '\0';
  return report;
}

// ── v23 adapter 运行期读数：两侧读写器 ────────────────────────────────────
//
// 为什么要有这条面：`AdapterDiagnostics` 以前只被契约测试读，运行期没有消费方。
// 于是「这局到底哪个 adapter 认领了、装上没有」在真机上是**看不见的**——每加一个
// 引擎就多一个答不出的问题，而 engine-support 的证据门恰恰要求逐门可判。
//
// 写侧只有 AdapterRegistry::Poll 一处。内容先写、seq 最后发布；读侧 seq→读→复核 seq，
// 与 LookupHitSlot / VoiceClip 同一套。
inline uint32_t PublishAdapterReports(SharedHeader* header,
                                      const AdapterReportSlot* slots,
                                      size_t count) {
  if (header == nullptr || slots == nullptr) return 0u;
  const size_t writable =
      count < kAdapterReportSlots ? count : kAdapterReportSlots;
  for (size_t i = 0; i < writable; ++i) {
    AdapterReportSlot& dst = header->adapter_reports[i];
    // 有界拷贝 + 强制 NUL：写侧可能是别的构建，读侧不许假设对面给了结尾。
    std::memcpy(dst.id, slots[i].id, kAdapterReportIdChars);
    dst.id[kAdapterReportIdChars - 1] = '\0';
    dst.applicable = slots[i].applicable;
    dst.installed = slots[i].installed;
    dst.slot_reserved = 0u;
    dst.flags = slots[i].flags;
  }
  // 尾部残留必须清掉：adapter 数变少时（换构建），旧槽会以陈旧读数继续存在。
  for (size_t i = writable; i < kAdapterReportSlots; ++i) {
    header->adapter_reports[i].id[0] = '\0';
    header->adapter_reports[i].applicable = 0u;
    header->adapter_reports[i].installed = 0u;
    header->adapter_reports[i].slot_reserved = 0u;
    header->adapter_reports[i].flags = 0u;
  }
  AtomicStoreShared32(&header->adapter_report_count,
                      static_cast<uint32_t>(writable));
  AtomicStoreShared32(&header->adapter_report_seq,
                      AtomicLoadShared32(&header->adapter_report_seq) + 1u);
  return static_cast<uint32_t>(writable);
}

// 读侧。seq==0 表示 hook 从未上报过（helper 还没起来 / 是旧版本），此时返回 0 槽——
// 那是"还不知道"，**不是**"一个 adapter 都没认领"。两者混在一起会让诊断在启动头
// 几百毫秒里稳定误报。
inline uint32_t ReadAdapterReports(const SharedHeader* header,
                                   AdapterReportSlot* out, size_t capacity,
                                   uint32_t* out_seq = nullptr) {
  if (out_seq != nullptr) *out_seq = 0u;
  if (header == nullptr || out == nullptr || capacity == 0u) return 0u;
  auto* mutable_header = const_cast<SharedHeader*>(header);
  for (int attempt = 0; attempt < 8; ++attempt) {
    const uint32_t seq = AtomicLoadShared32(&mutable_header->adapter_report_seq);
    if (seq == 0u) return 0u;
    uint32_t count = AtomicLoadShared32(&mutable_header->adapter_report_count);
    if (count > kAdapterReportSlots) count = kAdapterReportSlots;
    const size_t take = count < capacity ? count : capacity;
    for (size_t i = 0; i < take; ++i) out[i] = mutable_header->adapter_reports[i];
    if (AtomicLoadShared32(&mutable_header->adapter_report_seq) != seq) continue;
    for (size_t i = 0; i < take; ++i) {
      out[i].id[kAdapterReportIdChars - 1] = '\0';  // 有界：不信写侧给了 NUL
    }
    if (out_seq != nullptr) *out_seq = seq;
    return static_cast<uint32_t>(take);
  }
  return 0u;
}

inline NativeLoopbackRequestSnapshot ReadNativeLoopbackRequest(
    const SharedHeader* header) {
  NativeLoopbackRequestSnapshot result;
  if (header == nullptr) return result;
  // A writer publishes requested before seq. A stable seq/request/seq read is
  // therefore one coherent request; an in-flight update is retried later and
  // never grants capture.
  for (int attempt = 0; attempt < 8; ++attempt) {
    const uint32_t before =
        AtomicLoadShared32(&header->native_loopback_request_seq);
    const uint32_t requested =
        AtomicLoadShared32(&header->native_loopback_requested);
    MemoryBarrier();
    const uint32_t after =
        AtomicLoadShared32(&header->native_loopback_request_seq);
    if (before == after && after != 0 &&
        (after & kNativeLoopbackRequestWriteInProgress) == 0) {
      result.requested = requested;
      result.seq = after;
      result.valid = true;
      return result;
    }
  }
  return result;
}

// 当前发布的 native loopback 请求是否已被 hook 侧确认（applied_seq 追平 request seq）。
//
// 供 hook 侧在重量级引擎探测**之前**有界追平 ack 用（见 dll_main 的追平循环）：
// allow 的 applied/running 只能在 worker 起流后的下一轮 PollPolicy 发布，若把那一轮
// 留到引擎探测之后，早注入 5s 的确认预算基本必然超时（BUG-2131）。
// injector 侧另有带 requested 值校验的版本，那里要区分 deny/allow 的语义边界。
inline bool NativeLoopbackRequestAcknowledged(const SharedHeader* header) {
  if (header == nullptr) return false;
  const NativeLoopbackRequestSnapshot request =
      ReadNativeLoopbackRequest(header);
  if (!request.valid) return false;
  return AtomicLoadShared32(&header->native_loopback_applied_seq) ==
         request.seq;
}

inline bool NativeLoopbackRequestMatches(
    const SharedHeader* header,
    const NativeLoopbackRequestSnapshot& expected) {
  const NativeLoopbackRequestSnapshot current =
      ReadNativeLoopbackRequest(header);
  return expected.valid && current.valid && current.seq == expected.seq &&
         current.requested == expected.requested;
}

inline constexpr bool NativeLoopbackWorkerMayCapture(
    const NativeLoopbackRequestSnapshot& request, uint32_t worker_request_seq) {
  return request.valid && request.requested == kNativeLoopbackAllow &&
         request.seq == worker_request_seq;
}

inline constexpr bool NativeLoopbackWorkerFailureApplies(
    const NativeLoopbackRequestSnapshot& current_request,
    uint32_t completed_request_seq, bool stop_was_requested,
    uint32_t worker_exit_code) {
  return worker_exit_code != 0 && !stop_was_requested &&
         current_request.valid &&
         current_request.requested == kNativeLoopbackAllow &&
         current_request.seq == completed_request_seq;
}

// Cross-process publication primitive. The high request_seq bit is a bounded
// seqlock writer token: readers never consume requested while it is set, and
// concurrent injector/host publishers cannot expose "new requested + old
// generation". Injector calls this before InjectDll, so a fresh zeroed mapping
// publishes exactly seq=1.
inline uint32_t PublishNativeLoopbackRequest(SharedHeader* header,
                                             uint32_t requested) {
  if (header == nullptr) return 0;
  const uint32_t normalized = requested == kNativeLoopbackAllow
                                  ? kNativeLoopbackAllow
                                  : kNativeLoopbackDeny;
  const NativeLoopbackRequestSnapshot stable =
      ReadNativeLoopbackRequest(header);
  if (stable.valid && stable.requested == normalized) return stable.seq;
  auto* seq = reinterpret_cast<volatile LONG*>(
      &header->native_loopback_request_seq);
  uint32_t current = 0;
  bool claimed = false;
  const ULONGLONG claim_deadline = GetTickCount64() + 1000;
  do {
    current = AtomicLoadShared32(&header->native_loopback_request_seq);
    if ((current & kNativeLoopbackRequestWriteInProgress) != 0) {
      SwitchToThread();
      continue;
    }
    const uint32_t claim_token =
        current | kNativeLoopbackRequestWriteInProgress;
    const LONG observed = InterlockedCompareExchange(
        seq, static_cast<LONG>(claim_token), static_cast<LONG>(current));
    if (static_cast<uint32_t>(observed) == current) {
      claimed = true;
      break;
    }
  } while (GetTickCount64() < claim_deadline);
  if (!claimed) return 0;

  const uint32_t previous_requested =
      AtomicLoadShared32(&header->native_loopback_requested);
  if (current != 0 && previous_requested == normalized) {
    AtomicStoreShared32(&header->native_loopback_request_seq, current);
    return current;
  }
  AtomicStoreShared32(&header->native_loopback_requested, normalized);
  uint32_t published =
      (current & kNativeLoopbackRequestSequenceMask) + 1u;
  published &= kNativeLoopbackRequestSequenceMask;
  if (published == 0) published = 1;
  AtomicStoreShared32(&header->native_loopback_request_seq, published);
  return published;
}

inline void PublishNativeLoopbackTransientState(
    SharedHeader* header, const NativeLoopbackRequestSnapshot& request,
    uint32_t state) {
  if (!NativeLoopbackRequestMatches(header, request)) return;
  AtomicStoreShared32(&header->native_loopback_state, state);
}

// State is written first, applied_seq last. HookWorker is the only ack writer;
// capture workers never touch these fields, eliminating stale-generation
// publication. A newer request racing immediately after this publication remains distinguishable:
// applied_seq then differs from request_seq and the controller converges on
// the latest request without treating the old state as its acknowledgement.
inline bool PublishNativeLoopbackApplied(
    SharedHeader* header, const NativeLoopbackRequestSnapshot& request,
    uint32_t state) {
  if (!NativeLoopbackRequestMatches(header, request)) return false;
  AtomicStoreShared32(&header->native_loopback_state, state);
  if (!NativeLoopbackRequestMatches(header, request)) return false;

  AtomicStoreShared32(&header->native_loopback_applied_seq, request.seq);
  return NativeLoopbackRequestMatches(header, request);
}

enum class NativeLoopbackWorkerPhase : uint32_t {
  kAbsent = 0,
  kStarting = 1,
  kRunning = 2,
  kStopping = 3,
};

enum class NativeLoopbackPolicyAction : uint32_t {
  kNone = 0,
  kStartWorker,
  kRequestStop,
  kPublishStarting,
  kPublishStopping,
  kAcknowledgeStopped,
  kAcknowledgeRunning,
  kAcknowledgeFailed,
};

// Pure lifecycle reducer shared by production and the x86/x64 offline test.
// It is intentionally fail-closed: only exact allow can emit kStartWorker.
inline constexpr NativeLoopbackPolicyAction DecideNativeLoopbackPolicyAction(
    const NativeLoopbackRequestSnapshot& request,
    NativeLoopbackWorkerPhase worker_phase,
    bool failed_for_this_request) {
  if (!request.valid) return NativeLoopbackPolicyAction::kNone;
  const bool allow = request.requested == kNativeLoopbackAllow;
  if (!allow) {
    if (worker_phase == NativeLoopbackWorkerPhase::kAbsent) {
      return NativeLoopbackPolicyAction::kAcknowledgeStopped;
    }
    if (worker_phase == NativeLoopbackWorkerPhase::kStopping) {
      return NativeLoopbackPolicyAction::kPublishStopping;
    }
    return NativeLoopbackPolicyAction::kRequestStop;
  }
  if (failed_for_this_request) {
    return NativeLoopbackPolicyAction::kAcknowledgeFailed;
  }
  switch (worker_phase) {
    case NativeLoopbackWorkerPhase::kAbsent:
      return NativeLoopbackPolicyAction::kStartWorker;
    case NativeLoopbackWorkerPhase::kStarting:
      return NativeLoopbackPolicyAction::kPublishStarting;
    case NativeLoopbackWorkerPhase::kRunning:
      return NativeLoopbackPolicyAction::kAcknowledgeRunning;
    case NativeLoopbackWorkerPhase::kStopping:
      return NativeLoopbackPolicyAction::kPublishStopping;
  }
  return NativeLoopbackPolicyAction::kNone;
}

inline uint64_t SelectedTextThreadId(const SharedHeader* header) {
  if (header == nullptr) return 0;
  return AtomicLoadPreview64(&header->selected_text_thread_id);
}

inline bool IsExactTextThreadSelected(const SharedHeader* header,
                                      uint64_t thread_id) {
  return thread_id != 0 && SelectedTextThreadId(header) == thread_id;
}

// ── v13 文本分道寻址（写侧/读侧唯一实现，谁都不许自己再算一遍偏移）────────────────
//
// 整区尺寸：道表 + 槽区。injector 按此分配并填 text_region_offset / text_lane_*。
inline constexpr uint64_t TextRegionBytes(uint32_t lane_count,
                                          uint32_t lane_slot_count) {
  return static_cast<uint64_t>(lane_count) * sizeof(TextLane) +
         static_cast<uint64_t>(lane_count) * lane_slot_count * kTextSlotBytes;
}

inline TextLane* TextLanesOf(SharedHeader* header) {
  if (header == nullptr || header->text_region_offset == 0) return nullptr;
  return reinterpret_cast<TextLane*>(reinterpret_cast<uint8_t*>(header) +
                                     header->text_region_offset);
}

inline const TextLane* TextLanesOf(const SharedHeader* header) {
  if (header == nullptr || header->text_region_offset == 0) return nullptr;
  return reinterpret_cast<const TextLane*>(
      reinterpret_cast<const uint8_t*>(header) + header->text_region_offset);
}

// 槽区起点 = 道表之后。
inline uint64_t TextSlotAreaOffset(const SharedHeader* header) {
  return static_cast<uint64_t>(header->text_region_offset) +
         static_cast<uint64_t>(header->text_lane_count) * sizeof(TextLane);
}

// 第 [lane] 条道、道内序号 [lane_seq]（从 1 起）对应的槽。lane_seq 在道内取模覆盖。
inline uint8_t* TextLaneSlotAt(SharedHeader* header, uint32_t lane,
                               uint64_t lane_seq) {
  if (header == nullptr || lane >= header->text_lane_count ||
      header->text_lane_slot_count == 0 || lane_seq == 0) {
    return nullptr;
  }
  const uint64_t index_in_lane = (lane_seq - 1) % header->text_lane_slot_count;
  const uint64_t offset =
      TextSlotAreaOffset(header) +
      (static_cast<uint64_t>(lane) * header->text_lane_slot_count +
       index_in_lane) *
          kTextSlotBytes;
  return reinterpret_cast<uint8_t*>(header) + static_cast<size_t>(offset);
}

inline const uint8_t* TextLaneSlotAt(const SharedHeader* header, uint32_t lane,
                                     uint64_t lane_seq) {
  return TextLaneSlotAt(const_cast<SharedHeader*>(header), lane, lane_seq);
}

// 在 [begin, end) 区段里按 thread_id 查找/认领一条道。调用方持 writer 锁。
// 回收会产生空洞，因此必须扫完整个区段以优先找回已有 id（与 FindThreadPreviewSlot 同款纪律）。
// 区段用于隔离跨进程 writer：Luna 用低段、游戏内 native adapter 用高段。
inline TextLane* FindTextLane(TextLane* lanes, uint32_t begin, uint32_t end,
                              uint64_t thread_id, uint32_t* lane_index_out) {
  if (lanes == nullptr || thread_id == 0) return nullptr;
  TextLane* first_empty = nullptr;
  uint32_t first_empty_index = 0;
  for (uint32_t i = begin; i < end; ++i) {
    if (lanes[i].thread_id == thread_id) {
      if (lane_index_out != nullptr) *lane_index_out = i;
      return &lanes[i];
    }
    if (lanes[i].thread_id == 0 && first_empty == nullptr) {
      first_empty = &lanes[i];
      first_empty_index = i;
    }
  }
  if (first_empty != nullptr && lane_index_out != nullptr) {
    *lane_index_out = first_empty_index;
  }
  return first_empty;
}

// 按**全局发布序**枚举当前仍留在各道里的文本槽（只收 seq > [after_seq] 的）。
//
// 分道之后「读最近 N 条」不再是对一个全局序号取模，而是遍历各道再归并。读侧不止一个
// （host 的 PollText、诊断探针 ring_probe），归并写两遍就会两边行为漂开——所以实现只放
// 这里一份。插入排序，条数上界是总槽数（几百），无分配。
//
// 返回写入 [out] 的条数。[capacity] 不足时保留**序号最大**的那批（最近的行）。
inline uint32_t CollectTextSlotsBySeq(const SharedHeader* header,
                                      const TextSlot** out, uint32_t capacity,
                                      uint64_t after_seq) {
  if (header == nullptr || out == nullptr || capacity == 0) return 0;
  const TextLane* lanes = TextLanesOf(header);
  if (lanes == nullptr) return 0;
  const uint32_t lane_slots = header->text_lane_slot_count;
  if (lane_slots == 0) return 0;
  uint32_t count = 0;
  for (uint32_t lane = 0; lane < header->text_lane_count; ++lane) {
    if (lanes[lane].thread_id == 0) continue;
    const uint64_t written = lanes[lane].write_count;
    if (written == 0) continue;
    const uint64_t first =
        written > lane_slots ? written - lane_slots + 1 : 1;
    for (uint64_t lane_seq = first; lane_seq <= written; ++lane_seq) {
      const auto* slot =
          reinterpret_cast<const TextSlot*>(TextLaneSlotAt(header, lane,
                                                           lane_seq));
      // 道内校验：lane_seq 对不上 = 已被本道后来的行覆盖，或还没发布完。
      // 原子读：写侧用 Interlocked 发布，读侧照样不能裸读（x86 上 64 位裸读会撕裂）。
      if (slot == nullptr ||
          AtomicLoadPreview64(&slot->lane_seq) != lane_seq) {
        continue;
      }
      const uint64_t seq = slot->seq;
      if (seq <= after_seq) continue;
      if (count < capacity) {
        out[count++] = slot;
        // 从尾部往前冒泡到位（out 始终按 seq 升序，out[0] 恒为最旧）。
        for (uint32_t i = count - 1; i > 0; --i) {
          if (out[i - 1]->seq <= out[i]->seq) break;
          const TextSlot* tmp = out[i - 1];
          out[i - 1] = out[i];
          out[i] = tmp;
        }
      } else if (out[0]->seq < seq) {
        out[0] = slot;  // 满了就顶掉当前最旧的那条，再从头冒泡回位
        for (uint32_t i = 0; i + 1 < capacity; ++i) {
          if (out[i]->seq <= out[i + 1]->seq) break;
          const TextSlot* tmp = out[i];
          out[i] = out[i + 1];
          out[i + 1] = tmp;
        }
      }
    }
  }
  return count;
}

// 一次文本事件写入的全部输入。三个写侧（injector 的 Luna 回调、游戏内 GDI/TextRender、
// 游戏内 Unity）字段集合不同，但**寻址与发布纪律必须只有一份实现**，否则分道的不变量
// （只能覆盖自己那条道）会随第四个写侧被悄悄破坏。
struct TextLaneWrite {
  uint64_t thread_id = 0;
  uint64_t face_id = 0;
  uint64_t thread_address = 0;
  uint64_t thread_context = 0;
  uint64_t thread_context2 = 0;
  uint32_t process_id = 0;
  uint32_t source_kind = kTextSourceUnknown;
  uint32_t event_kind = kTextEventLine;
  uint32_t event_flags = 0;
  uint32_t is_utf8 = 0;
  const void* text = nullptr;  // 文本字节（按 is_utf8 解释）；线程发现事件可为空
  uint32_t byte_len = 0;
  const char* hook_name = nullptr;
  const wchar_t* hook_code = nullptr;
};

// 把一条文本事件写进 [thread_id] 自己那条道。返回全局发布序（0 = 没写成：道满/参数非法）。
//
// 调用方持**自己进程内**的 writer 锁（认领与道内占号要互斥）；跨进程隔离靠 [lane_begin,
// lane_end) 区段划分，不靠锁。写序：认领道 → 原子占全局序 → 原子占道内序 → 填字段与文本 →
// **最后**写 lane_seq 作完成标记（reader 校验 lane_seq 才取该槽；x86/x64 store 有序，
// 前面的数据写对 reader 先于 lane_seq 可见）。
inline uint64_t WriteTextLaneEvent(SharedHeader* header, uint32_t lane_begin,
                                   uint32_t lane_end,
                                   const TextLaneWrite& write) {
  if (header == nullptr || write.thread_id == 0) return 0;
  TextLane* lanes = TextLanesOf(header);
  if (lanes == nullptr || header->text_lane_count == 0) return 0;
  const uint32_t end = (lane_end < header->text_lane_count)
                           ? lane_end
                           : header->text_lane_count;
  if (lane_begin >= end) return 0;
  uint32_t lane_index = 0;
  TextLane* lane = FindTextLane(lanes, lane_begin, end, write.thread_id,
                                &lane_index);
  if (lane == nullptr) {
    // 道用尽。**绝不静默丢弃**：那样的症状（某些线程的台词就是不来）与 v13 要根治的
    // 256 槽挤压完全同形，真机上分不出是分道没生效还是道不够用。
    //
    // 处置分两级，两级都留计数：
    //  ① 回收最久没写过的**非选定**道 —— 选定线程那条道是配对路径的输入，任何情况下
    //     都不能被顶掉；被回收的线程只是暂时失去历史，它下一行会重新认领一条道，仍然
    //     在预览区里看得见、仍然可选（预览区另有自己的槽，不受此处影响）。
    //  ② 连一条可回收的都没有（全被选定线程占着，理论上只有 1 条）才丢弃本行。
    // write_count 跨回收保持单调：重置它会让新占用者的 lane_seq 与上一任的残留槽撞号，
    // reader 会把旧行当成新行的有效槽。残留槽本身无害——每个槽自带 thread_id，消费方
    // 按线程过滤，不会张冠李戴。
    const uint64_t selected = SelectedTextThreadId(header);
    TextLane* victim = nullptr;
    uint32_t victim_index = 0;
    for (uint32_t i = lane_begin; i < end; ++i) {
      if (lanes[i].thread_id == selected) continue;
      if (victim == nullptr || lanes[i].last_write_ms < victim->last_write_ms) {
        victim = &lanes[i];
        victim_index = i;
      }
    }
    if (victim == nullptr) {
      InterlockedIncrement64(reinterpret_cast<volatile LONGLONG*>(
          &header->text_lane_overflow_count));
      return 0;
    }
    InterlockedIncrement64(reinterpret_cast<volatile LONGLONG*>(
        &header->text_lane_recycle_count));
    lane = victim;
    lane_index = victim_index;
  }
  lane->thread_id = write.thread_id;
  const uint64_t global_seq = static_cast<uint64_t>(InterlockedIncrement64(
      reinterpret_cast<volatile LONGLONG*>(&header->text_write_count)));
  const uint64_t lane_seq = static_cast<uint64_t>(InterlockedIncrement64(
      reinterpret_cast<volatile LONGLONG*>(&lane->write_count)));
  uint8_t* slot = TextLaneSlotAt(header, lane_index, lane_seq);
  if (slot == nullptr) return 0;
  auto* ts = reinterpret_cast<TextSlot*>(slot);
  memset(ts, 0, sizeof(TextSlot));
  uint32_t max_bytes = kTextSlotBytes - static_cast<uint32_t>(sizeof(TextSlot));
  max_bytes -= (max_bytes % static_cast<uint32_t>(sizeof(wchar_t)));
  uint32_t byte_len = write.text == nullptr ? 0 : write.byte_len;
  if (byte_len > max_bytes) byte_len = max_bytes;
  if (byte_len != 0) memcpy(slot + sizeof(TextSlot), write.text, byte_len);
  ts->seq = global_seq;
  ts->timestamp_ms = GetTickCount64();
  ts->byte_len = byte_len;
  ts->is_utf8 = write.is_utf8;
  ts->thread_id = write.thread_id;
  ts->face_id = write.face_id;
  ts->thread_address = write.thread_address;
  ts->thread_context = write.thread_context;
  ts->thread_context2 = write.thread_context2;
  ts->process_id = write.process_id;
  ts->source_kind = write.source_kind;
  ts->event_kind = write.event_kind;
  ts->event_flags = write.event_flags;
  if (write.hook_name != nullptr) {
    size_t n = 0;
    while (n < kTextHookNameChars - 1 && write.hook_name[n] != '\0') ++n;
    memcpy(ts->hook_name, write.hook_name, n);
    ts->hook_name[n] = '\0';
    ts->hook_name_len = static_cast<uint32_t>(n);
  }
  if (write.hook_code != nullptr) {
    size_t n = 0;
    while (n < kTextHookCodeChars - 1 && write.hook_code[n] != L'\0') ++n;
    memcpy(ts->hook_code, write.hook_code, n * sizeof(wchar_t));
    ts->hook_code[n] = L'\0';
    ts->hook_code_len = static_cast<uint32_t>(n);
  }
  lane->last_write_ms = ts->timestamp_ms;
  // 完成标记，**最后**写：Interlocked 是全栅栏（前面的 payload 写对 reader 必先可见）
  // 且 64 位不可撕裂（x86 上普通写会被拆成两次 32 位写）。与预览槽 seq 同一套纪律。
  AtomicStorePreview64(&ts->lane_seq, lane_seq);
  if (header->text_hooked == 0) header->text_hooked = 1;
  return global_seq;
}

// ── v14 查词区寻址（写侧/读侧唯一实现，谁都不许自己再算一遍偏移）────────────────
//
// 整区布局：[LookupHitSlot][LookupInputSlot × N][LookupFrame × F][位图 × F]
inline constexpr uint64_t LookupRegionBytes(uint32_t input_slot_count,
                                            uint32_t frame_count,
                                            uint32_t bitmap_bytes) {
  return sizeof(LookupHitSlot) +
         static_cast<uint64_t>(input_slot_count) * sizeof(LookupInputSlot) +
         static_cast<uint64_t>(frame_count) * sizeof(LookupFrame) +
         static_cast<uint64_t>(frame_count) * bitmap_bytes;
}

inline bool HasLookupRegion(const SharedHeader* header) {
  return header != nullptr && header->lookup_region_offset != 0 &&
         header->lookup_frame_count != 0 && header->lookup_bitmap_bytes != 0 &&
         header->lookup_input_slot_count != 0;
}

inline LookupHitSlot* LookupHitOf(SharedHeader* header) {
  if (!HasLookupRegion(header)) return nullptr;
  return reinterpret_cast<LookupHitSlot*>(reinterpret_cast<uint8_t*>(header) +
                                          header->lookup_region_offset);
}

inline const LookupHitSlot* LookupHitOf(const SharedHeader* header) {
  if (!HasLookupRegion(header)) return nullptr;
  return reinterpret_cast<const LookupHitSlot*>(
      reinterpret_cast<const uint8_t*>(header) + header->lookup_region_offset);
}

inline LookupInputSlot* LookupInputsOf(SharedHeader* header) {
  if (!HasLookupRegion(header)) return nullptr;
  return reinterpret_cast<LookupInputSlot*>(
      reinterpret_cast<uint8_t*>(header) + header->lookup_region_offset +
      sizeof(LookupHitSlot));
}

inline const LookupInputSlot* LookupInputsOf(const SharedHeader* header) {
  if (!HasLookupRegion(header)) return nullptr;
  return reinterpret_cast<const LookupInputSlot*>(
      reinterpret_cast<const uint8_t*>(header) + header->lookup_region_offset +
      sizeof(LookupHitSlot));
}

// 区内偏移一律用 size_t 而不是 uint64_t：这些值按构造都装得下 uint32_t（header 里的偏移
// 字段本身就是 uint32_t），而 x86 构建下拿 uint64_t 去做指针算术会被截断并在 /W4 /WX 的
// runner 上直接变成编译错误。整区**总字节数**仍用 uint64_t（LookupRegionBytes），因为它要
// 参与 injector 的 total_size 求和，那里确实可能超 4GB 语义上限。
inline size_t LookupFramesByteOffset(const SharedHeader* header) {
  return static_cast<size_t>(header->lookup_region_offset) +
         sizeof(LookupHitSlot) +
         static_cast<size_t>(header->lookup_input_slot_count) *
             sizeof(LookupInputSlot);
}

inline size_t LookupBitmapsByteOffset(const SharedHeader* header) {
  return LookupFramesByteOffset(header) +
         static_cast<size_t>(header->lookup_frame_count) * sizeof(LookupFrame);
}

inline LookupFrame* LookupFrameAt(SharedHeader* header, uint32_t index) {
  if (!HasLookupRegion(header) || index >= header->lookup_frame_count) {
    return nullptr;
  }
  return reinterpret_cast<LookupFrame*>(reinterpret_cast<uint8_t*>(header) +
                                        LookupFramesByteOffset(header)) +
         index;
}

inline const LookupFrame* LookupFrameAt(const SharedHeader* header,
                                        uint32_t index) {
  if (!HasLookupRegion(header) || index >= header->lookup_frame_count) {
    return nullptr;
  }
  return reinterpret_cast<const LookupFrame*>(
             reinterpret_cast<const uint8_t*>(header) +
             LookupFramesByteOffset(header)) +
         index;
}

inline uint8_t* LookupBitmapAt(SharedHeader* header, uint32_t index) {
  if (!HasLookupRegion(header) || index >= header->lookup_frame_count) {
    return nullptr;
  }
  return reinterpret_cast<uint8_t*>(header) + LookupBitmapsByteOffset(header) +
         static_cast<size_t>(index) * header->lookup_bitmap_bytes;
}

inline const uint8_t* LookupBitmapAt(const SharedHeader* header,
                                     uint32_t index) {
  if (!HasLookupRegion(header) || index >= header->lookup_frame_count) {
    return nullptr;
  }
  return reinterpret_cast<const uint8_t*>(header) +
         LookupBitmapsByteOffset(header) +
         static_cast<size_t>(index) * header->lookup_bitmap_bytes;
}

// 「这帧该不该应用」的**唯一判据**。注入侧与 replay 测试共用同一份——判据一旦各写各的，
// replay 绿了也只证明参照实现自洽，证明不了生产代码对。收卡曾经整条不通就是死在这个判据上
// （详见 LookupFrame 注释），那种错必须能被离线回归抓住，而不是等真机。
//
// ready 位不在这里判：它是「host 写完没有」的内存可见性问题，归调用点，与「这帧是否过期」
// 是两件事。seq 由调用点原子读出后传进来，同理。
inline bool ShouldApplyLookupFrame(uint64_t frame_seq, uint64_t frame_hit_seq,
                                   uint32_t frame_flags,
                                   uint64_t presented_seq,
                                   uint64_t current_any_hit_seq,
                                   uint64_t current_submit_hit_seq) {
  // 发布序不比已处理的新 → 这帧我处理过了。
  if (frame_seq <= presented_seq) return false;
  // hover 只控制游戏线程即时绘制的字形高亮；卡片内容、收卡与 dismiss 都属于最近一次
  // submit。两种身份混用会让查词期间经过的 hover 把正确结果判成陈旧帧。
  const uint64_t fence = frame_flags == kLookupFrameHighlightOnly
                             ? current_any_hit_seq
                             : current_submit_hit_seq;
  // 只接受精确身份。大于 fence 的 frame 同样没有合法来源，不能把“host 抢跑”当成功。
  return frame_hit_seq == fence;
}

// 帧自洽校验。**注入侧必须先过这一关再拷贝**：跨进程来的 width/height/pitch 全是不可信
// 输入，按它们盲拷就是把共享内存越界写进游戏进程。host 侧同样用它自检，避免投出废帧。
inline bool IsLookupFrameSane(const SharedHeader* header,
                              const LookupFrame* frame) {
  if (header == nullptr || frame == nullptr) return false;
  if (frame->width == 0 || frame->height == 0) return false;
  if (frame->width > 0x4000u || frame->height > 0x4000u) return false;
  const uint64_t min_pitch = static_cast<uint64_t>(frame->width) * 4u;
  if (frame->pitch < min_pitch) return false;
  const uint64_t needed =
      static_cast<uint64_t>(frame->pitch) * frame->height;
  if (needed != frame->byte_len) return false;
  return needed <= header->lookup_bitmap_bytes;
}

static_assert(sizeof(SharedHeader) % 8 == 0, "SharedHeader must stay 8-aligned");
static_assert(sizeof(LookupHitSlot) % 8 == 0, "LookupHitSlot must stay 8-aligned");
static_assert(sizeof(LookupFrame) % 8 == 0, "LookupFrame must stay 8-aligned");
static_assert(sizeof(LookupInputSlot) % 8 == 0,
              "LookupInputSlot must stay 8-aligned");
// 双缓冲是防撕裂的**结构前提**：单缓冲时 host 写下一帧与 hook 拷当前帧必然重叠。
static_assert(kLookupFrameCount >= 2, "lookup frames must be double-buffered");
static_assert(sizeof(TextSlot) % 8 == 0, "TextSlot must stay 8-aligned");
static_assert(sizeof(TextLane) % 8 == 0, "TextLane must stay 8-aligned");
// 道数与预览槽数必须同值：两者共用同一套下标与同一套跨进程互斥分区，分开就会有一侧
// 越界或两个进程认领到同一条道。
static_assert(kTextLaneCount == kThreadPreviewCount,
              "text lanes and thread previews must share one index space");
static_assert(sizeof(TextSlot) < kTextSlotBytes,
              "TextSlot header must leave room for payload bytes");
static_assert(sizeof(VoiceClip) % 8 == 0, "VoiceClip must stay 8-aligned");
static_assert(sizeof(UnityVoiceEvent) % 8 == 0,
              "UnityVoiceEvent must stay 8-aligned");
static_assert(sizeof(LoopbackMarker) % 8 == 0, "LoopbackMarker must stay 8-aligned");

// 命名对象（同会话跨进程）。以目标 PID 区分，支持同时对多个游戏进程各挂一份。
// injector 创建、hook DLL 打开：共享内存 + 「就绪」事件（DLL 装好后 SetEvent，injector 据此
// 确认注入成功并读回格式）。
//
// Fushi 改名后的 host 使用 FushiVoiceHook；旧 Hibiki host 仍只会打开 HibikiVoiceHook。
// helper/DLL 可能被部署到旧安装中做兼容修复，因此两侧都按实际组件文件名选同一命名空间，
// 而不是让新版默认名静默破坏旧 host。严格只认完整 basename，避免任意路径子串误判。
inline bool ComponentUsesLegacyHibikiIpc(const std::wstring& component_path) {
  const size_t slash = component_path.find_last_of(L"\\/");
  const wchar_t* basename = slash == std::wstring::npos
                                ? component_path.c_str()
                                : component_path.c_str() + slash + 1;
  return _wcsicmp(basename, L"hibiki_voice_injector.exe") == 0 ||
         _wcsicmp(basename, L"hibiki_voice_hook.dll") == 0;
}

inline std::wstring SharedMemoryName(DWORD target_pid,
                                     bool legacy_hibiki = false) {
  return std::wstring(legacy_hibiki ? L"Local\\HibikiVoiceHook_"
                                    : L"Local\\FushiVoiceHook_") +
         std::to_wstring(target_pid);
}
inline std::wstring ReadyEventName(DWORD target_pid,
                                   bool legacy_hibiki = false) {
  return std::wstring(legacy_hibiki ? L"Local\\HibikiVoiceHookReady_"
                                    : L"Local\\FushiVoiceHookReady_") +
         std::to_wstring(target_pid);
}

}  // namespace fushi_voice_hook

#endif  // FUSHI_VOICE_HOOK_IPC_H_
