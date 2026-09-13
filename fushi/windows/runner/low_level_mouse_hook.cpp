#include "low_level_mouse_hook.h"

#include "attached_glyph_transaction_latch.h"
#include "voice_hook_reader.h"

#include "../../../native/galgame_hook/include/voice_hook_ipc.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

namespace fushi {

namespace {

// 钩子线程私有的控制消息（PostThreadMessage）。
constexpr UINT kThreadArm = WM_APP + 0x60;
constexpr UINT kThreadDisarm = WM_APP + 0x61;
constexpr UINT kThreadBarrier = WM_APP + 0x62;
constexpr UINT kThreadReconcileAttached = WM_APP + 0x63;
constexpr UINT kAttachedReleasePollMs = 10;
// Once a real/safely reconciled physical up exists, an injected reducer that
// never acknowledges down or neutral must not turn the process-wide LL hook
// into a permanent left-click sink. This deadline never runs while held.
constexpr ULONGLONG kAttachedShieldAcknowledgeTimeoutMs = 3000;

// BUG-1077 — Disarm 的宽限期（毫秒）。嵌套查词的 reset(Hide) → RevealStack 间隔
// 只有百毫秒级，立卸立装等于每次嵌套做两次全局钩子表变更（桌面级钩子链更新要与
// Raw Input 线程串行，本身就是一次全系统输入短暂停顿）。宽限期内 g_target 已清空、
// 回调纯放行，语义与已卸载等价；超过宽限期仍无新 Arm 才真正 UnhookWindowsHookEx，
// 维持「不查词不留全局钩子」的承诺。
constexpr UINT kDisarmGraceMs = 3000;
constexpr DWORD kArmAckTimeoutMs = 2000;

// BUG-1286 — 钩子存活性核对间隔（毫秒）。
//
// WH_MOUSE_LL 不是「装上就永远有效」的资源：回调若超过 HKCU\Control Panel\Desktop
// 的 LowLevelHooksTimeout（默认 300ms）没返回，**系统会直接把这个钩子从链上摘掉**，
// 既不通知也不让 HHOOK 失效。旧实现只在 Arm 时装一次，之后 `hook != nullptr` 永远为
// 真，于是被摘掉之后再也不会重装——查词卡从此收不到任何点击，而台词照常更新（那条路
// 走 IPC→ExecuteScript，与钩子无关），表现成「浮窗看得见、点不动，只能重启」。玩 gal
// 时进程内同时有词典 FFI、WebView2 COM、语音捕获与转码在抢核，超时是现实会发生的。
constexpr UINT kLivenessIntervalMs = 1000;
// A synchronous direct reveal may reuse the hook during the 3s disarm grace.
// A recent callback proves that handle is still in the chain. If callbacks have
// been silent for two liveness periods, refresh the handle before acknowledging
// the reveal instead of trusting the non-null HHOOK value (Windows can silently
// remove a timed-out low-level hook without invalidating that value).
constexpr ULONGLONG kSynchronousArmFreshnessMs =
    static_cast<ULONGLONG>(kLivenessIntervalMs) * 2;

// 钩子线程与调用线程共享的唯一可变状态：目标窗口。回调只读它，故用 atomic 而不是锁——
// 钩子回调必须尽快返回，任何可能阻塞（锁竞争、堆分配）的东西都不该出现在这条路径上。
std::atomic<HWND> g_target{nullptr};
// Non-null only when an attached surface deliberately fell back to the
// HHOOK+v19 risk path because an exact sampled-input contract was declared but
// could not be published.  Keep this separate from g_target so callers never
// mistake hook installation for verified sampled-input coverage.
std::atomic<HWND> g_attached_risky_target{nullptr};

// BUG-1882 — direct galCard 的消费范围绑定在专用目标 HWND 上，而不是再放一个
// 独立 relaxed atomic。修改属性前 ArmAndWait 会先清 g_target，再等钩子线程 ack
//（它也是 callback barrier）；因此已取旧 target 的回调必已退出，之后的新回调只会
// 看到 null，直到属性和 target 按此顺序发布。
constexpr wchar_t kConsumeOutsideOwnerProperty[] =
    L"Fushi.LowLevelMouseHook.ConsumeOutsideOwner";
// sampled-input publication 与“是否吞游戏客户区空白”是两件事。direct galCard 两者都要，
// attached glyph surface 只要前者；复用一个 property 会把整块游戏客户区误吞。
constexpr wchar_t kSampledShieldOwnerProperty[] =
    L"Fushi.LowLevelMouseHook.SampledShieldOwner";
constexpr wchar_t kSampledShieldTargetOnlyProperty[] =
    L"Fushi.LowLevelMouseHook.SampledShieldTargetOnly";
constexpr uintptr_t kSampledShieldTargetOnlyValue = 1u;

constexpr uint32_t kSwallowedLeftButton = 1u << 0;
constexpr uint32_t kSwallowedRightButton = 1u << 1;
constexpr uint32_t kSwallowedMiddleButton = 1u << 2;
constexpr uint32_t kSwallowedX1Button = 1u << 3;
constexpr uint32_t kSwallowedX2Button = 1u << 4;

// 吞掉 down 后，窗口线程会异步 Hide -> Disarm，而 up 往往在那之后才到。
// 所以这份事务状态不能随 g_target 立即清空；回调必须先收掉配对 up，再看
// target 是否还在。只有宽限期后真正卸钩才清理残留位。
std::atomic<uint32_t> g_swallowed_buttons{0};

struct AttachedGlyphHitSnapshot {
  HWND surface = nullptr;
  HWND game_owner = nullptr;
  uint32_t token = 0;
  bool allow_risk = false;
  std::vector<RECT> screen_rects;
};

// C++17 supplies atomic operations for shared_ptr as free functions.  Updates
// allocate/copy on the surface thread; WH_MOUSE_LL performs only an atomic
// snapshot load and linear reads over immutable RECTs.
std::shared_ptr<const AttachedGlyphHitSnapshot> g_attached_hit_snapshot;
std::atomic<uint32_t> g_attached_hit_token{0};
std::atomic<uint32_t> g_attached_transaction_counter{0};
SRWLOCK g_attached_transaction_lock = SRWLOCK_INIT;

struct AttachedGlyphActiveTransaction {
  AttachedGlyphTransactionLatch latch;
  size_t rect_index = 0;
  POINT down_point{};
  ULONGLONG physical_up_tick = 0;
  std::shared_ptr<const AttachedGlyphHitSnapshot> snapshot;
};

AttachedGlyphActiveTransaction g_attached_active_transaction;
// Callback-side ownership probes must not wait behind the release worker or
// surface teardown. The SRW-protected object remains authoritative; this id is
// only a conservative, lock-free indication that an up/down tail is live.
std::atomic<uint64_t> g_attached_active_transaction_id{0};
// A callback-side PostMessage failure may race the acknowledgement worker's
// SRW ownership.  Defer only the lookup-submission cancellation; this must
// never reuse the pending-up slot because no physical up was observed.
std::atomic<uint64_t> g_attached_pending_cancel_transaction_id{0};
std::atomic<uint64_t> g_attached_pending_up_transaction_id{0};
std::atomic<WPARAM> g_attached_pending_up_point{0};
std::atomic<bool> g_attached_pending_up_real{false};

// SGRE helper ready 时，game HWND 的 Window property 指向当前 direct popup。
// 与 g_swallowed_buttons 分开：卡片内部点击要继续交给 WebView2，但 DirectInput
// 同样必须看不见它；若这次点击恰好关闭卡片，也要把 publication 留到真实 up。
std::atomic<HWND> g_direct_input_shield_game{nullptr};
std::atomic<HWND> g_direct_input_shield_popup{nullptr};
std::atomic<uint32_t> g_direct_input_shield_buttons{0};

// A direct galCard may sit above an engine that samples physical mouse state
// outside the Win32 message queue.  SGRE, exact-profile Siglus, admitted
// Leaf/AQUAPLUS, and admitted HUNEX/GGE use different injected ABIs, but the host publication
// transaction is identical. Keep the property names as data so the low-level
// hook can retain one down/up lifetime implementation without pretending the
// engine-side detours are interchangeable.
struct SampledInputShieldContract {
  const wchar_t* required_property;
  uintptr_t required_value;
  const wchar_t* ready_property;
  uintptr_t ready_value;
  const wchar_t* window_property;
  const wchar_t* tail_request_property;
  const wchar_t* tail_ack_property;
};

constexpr SampledInputShieldContract kSgreSampledInputShieldContract = {
    fushi_voice_hook::kSgreDirectInputShieldRequiredProperty,
    fushi_voice_hook::kSgreDirectInputShieldRequiredValue,
    fushi_voice_hook::kSgreDirectInputShieldReadyProperty,
    fushi_voice_hook::kSgreDirectInputShieldReadyValue,
    fushi_voice_hook::kSgreDirectInputShieldWindowProperty,
    nullptr,
    nullptr,
};

constexpr SampledInputShieldContract kSiglusSampledInputShieldContract = {
    fushi_voice_hook::kSiglusSampledInputShieldRequiredProperty,
    fushi_voice_hook::kSiglusSampledInputShieldRequiredValue,
    fushi_voice_hook::kSiglusSampledInputShieldReadyProperty,
    fushi_voice_hook::kSiglusSampledInputShieldReadyValue,
    fushi_voice_hook::kSiglusSampledInputShieldWindowProperty,
    nullptr,
    nullptr,
};

constexpr SampledInputShieldContract kLeafAquaplusSampledInputShieldContract = {
    fushi_voice_hook::kLeafAquaplusSampledInputShieldRequiredProperty,
    fushi_voice_hook::kLeafAquaplusSampledInputShieldRequiredValue,
    fushi_voice_hook::kLeafAquaplusSampledInputShieldReadyProperty,
    fushi_voice_hook::kLeafAquaplusSampledInputShieldReadyValue,
    fushi_voice_hook::kLeafAquaplusSampledInputShieldWindowProperty,
    fushi_voice_hook::kLeafAquaplusSampledInputShieldTailRequestProperty,
    fushi_voice_hook::kLeafAquaplusSampledInputShieldTailAckProperty,
};

constexpr SampledInputShieldContract kHunexGgeSampledInputShieldContract = {
    fushi_voice_hook::kHunexGgeSampledInputShieldRequiredProperty,
    fushi_voice_hook::kHunexGgeSampledInputShieldRequiredValue,
    fushi_voice_hook::kHunexGgeSampledInputShieldReadyProperty,
    fushi_voice_hook::kHunexGgeSampledInputShieldReadyValue,
    fushi_voice_hook::kHunexGgeSampledInputShieldWindowProperty,
    fushi_voice_hook::kHunexGgeSampledInputShieldTailRequestProperty,
    fushi_voice_hook::kHunexGgeSampledInputShieldTailAckProperty,
};

// smash/fzmedia swallows the click in a window-procedure subclass; there is
// no sampled low bit to drain, so the contract has no tail handshake.
constexpr SampledInputShieldContract kSmashFzmediaSampledInputShieldContract = {
    fushi_voice_hook::kSmashFzmediaSampledInputShieldRequiredProperty,
    fushi_voice_hook::kSmashFzmediaSampledInputShieldRequiredValue,
    fushi_voice_hook::kSmashFzmediaSampledInputShieldReadyProperty,
    fushi_voice_hook::kSmashFzmediaSampledInputShieldReadyValue,
    fushi_voice_hook::kSmashFzmediaSampledInputShieldWindowProperty,
    nullptr,
    nullptr,
};

std::atomic<const SampledInputShieldContract*>
    g_direct_input_shield_contract{nullptr};
std::atomic<uint32_t> g_direct_input_shield_tail_generation{0};
std::atomic<uint32_t> g_direct_input_shield_tail_token{0};

static_assert(kLowLevelMouseShieldReleaseMessage ==
                  fushi_voice_hook::kSampledInputShieldReleaseWindowMessage,
              "host/helper sampled-input release message drifted");

// BUG-1286 — 回调最近一次被调用的时刻。存活性判据的一半（另一半是光标是否移动过）。
// 只在回调里写、只在钩子线程的定时器里读，relaxed 足够：判据比较的是「有没有变化」，
// 不依赖它与其他内存的顺序关系。
std::atomic<ULONGLONG> g_callback_tick{0};

std::mutex g_thread_mutex;
// 只串行 Arm/Disarm 的发布与 direct cold-arm ack；钩子回调绝不碰这把锁。
std::mutex g_binding_mutex;
std::mutex g_attached_release_worker_mutex;
std::condition_variable g_attached_release_worker_cv;
std::once_flag g_attached_release_worker_once;
std::atomic<bool> g_attached_release_work_requested{false};
std::atomic<DWORD> g_thread_id{0};
// 线程 id 发布完成的信号（进程生命周期常驻，不关闭）。
HANDLE g_thread_ready = nullptr;
// direct galCard 上屏前的安装确认。generation 防止一个陈旧 kThreadArm 的 SetEvent
// 被误认成当前请求；事件只负责唤醒，generation 才是完成真值。
std::atomic<uint32_t> g_arm_requested_generation{0};
std::atomic<uint32_t> g_arm_applied_generation{0};
std::atomic<bool> g_hook_active{false};
HANDLE g_arm_applied_event = nullptr;

uint32_t ButtonBitForMessage(WPARAM message, DWORD mouse_data) {
  switch (message) {
    case WM_LBUTTONDOWN:
    case WM_LBUTTONUP:
    case WM_NCLBUTTONDOWN:
    case WM_NCLBUTTONUP:
      return kSwallowedLeftButton;
    case WM_RBUTTONDOWN:
    case WM_RBUTTONUP:
    case WM_NCRBUTTONDOWN:
    case WM_NCRBUTTONUP:
      return kSwallowedRightButton;
    case WM_MBUTTONDOWN:
    case WM_MBUTTONUP:
    case WM_NCMBUTTONDOWN:
    case WM_NCMBUTTONUP:
      return kSwallowedMiddleButton;
    case WM_XBUTTONDOWN:
    case WM_XBUTTONUP:
    case WM_NCXBUTTONDOWN:
    case WM_NCXBUTTONUP:
      if (HIWORD(mouse_data) == XBUTTON1) return kSwallowedX1Button;
      if (HIWORD(mouse_data) == XBUTTON2) return kSwallowedX2Button;
      return 0;
    default:
      return 0;
  }
}

bool IsButtonDownMessage(WPARAM message) {
  return message == WM_LBUTTONDOWN || message == WM_RBUTTONDOWN ||
         message == WM_MBUTTONDOWN || message == WM_XBUTTONDOWN ||
         message == WM_NCLBUTTONDOWN || message == WM_NCRBUTTONDOWN ||
         message == WM_NCMBUTTONDOWN || message == WM_NCXBUTTONDOWN;
}

bool IsButtonUpMessage(WPARAM message) {
  return message == WM_LBUTTONUP || message == WM_RBUTTONUP ||
         message == WM_MBUTTONUP || message == WM_XBUTTONUP ||
         message == WM_NCLBUTTONUP || message == WM_NCRBUTTONUP ||
         message == WM_NCMBUTTONUP || message == WM_NCXBUTTONUP;
}

uint32_t ReconcileSwallowedButtonsWithPhysicalState() {
  const uint32_t swallowed =
      g_swallowed_buttons.load(std::memory_order_relaxed);
  uint32_t still_held = 0;
  if ((swallowed & kSwallowedLeftButton) != 0 &&
      (GetAsyncKeyState(VK_LBUTTON) & 0x8000) != 0) {
    still_held |= kSwallowedLeftButton;
  }
  if ((swallowed & kSwallowedRightButton) != 0 &&
      (GetAsyncKeyState(VK_RBUTTON) & 0x8000) != 0) {
    still_held |= kSwallowedRightButton;
  }
  if ((swallowed & kSwallowedMiddleButton) != 0 &&
      (GetAsyncKeyState(VK_MBUTTON) & 0x8000) != 0) {
    still_held |= kSwallowedMiddleButton;
  }
  if ((swallowed & kSwallowedX1Button) != 0 &&
      (GetAsyncKeyState(VK_XBUTTON1) & 0x8000) != 0) {
    still_held |= kSwallowedX1Button;
  }
  if ((swallowed & kSwallowedX2Button) != 0 &&
      (GetAsyncKeyState(VK_XBUTTON2) & 0x8000) != 0) {
    still_held |= kSwallowedX2Button;
  }
  // A device switch can lose the up callback. Drop only bits whose physical
  // button is already up; a real long hold must keep its paired-up transaction.
  g_swallowed_buttons.fetch_and(still_held, std::memory_order_relaxed);
  return still_held;
}

uint32_t PhysicalButtonsStillHeld(uint32_t buttons) {
  uint32_t still_held = 0;
  if ((buttons & kSwallowedLeftButton) != 0 &&
      (GetAsyncKeyState(VK_LBUTTON) & 0x8000) != 0) {
    still_held |= kSwallowedLeftButton;
  }
  if ((buttons & kSwallowedRightButton) != 0 &&
      (GetAsyncKeyState(VK_RBUTTON) & 0x8000) != 0) {
    still_held |= kSwallowedRightButton;
  }
  if ((buttons & kSwallowedMiddleButton) != 0 &&
      (GetAsyncKeyState(VK_MBUTTON) & 0x8000) != 0) {
    still_held |= kSwallowedMiddleButton;
  }
  if ((buttons & kSwallowedX1Button) != 0 &&
      (GetAsyncKeyState(VK_XBUTTON1) & 0x8000) != 0) {
    still_held |= kSwallowedX1Button;
  }
  if ((buttons & kSwallowedX2Button) != 0 &&
      (GetAsyncKeyState(VK_XBUTTON2) & 0x8000) != 0) {
    still_held |= kSwallowedX2Button;
  }
  return still_held;
}

void RequestDirectInputShieldFinalize() {
  const HWND popup =
      g_direct_input_shield_popup.load(std::memory_order_acquire);
  // A matching up from an older click must not revoke a newly revealed card
  // that reuses the same HWND.  Conversely, an unrelated desktop/global lookup
  // target must not keep the hidden gal publication alive forever.
  if (popup != nullptr && IsWindow(popup) &&
      g_target.load(std::memory_order_acquire) != popup) {
    PostMessage(popup, kLowLevelMouseShieldReleaseMessage, 0, 0);
  }
}

uint32_t ReconcileDirectInputShieldButtonsWithPhysicalState() {
  const uint32_t shield_buttons =
      g_direct_input_shield_buttons.load(std::memory_order_relaxed);
  const uint32_t still_held = PhysicalButtonsStillHeld(shield_buttons);
  g_direct_input_shield_buttons.fetch_and(still_held,
                                           std::memory_order_relaxed);
  if (still_held == 0 && shield_buttons != 0) {
    RequestDirectInputShieldFinalize();
  }
  return still_held;
}

bool IsSampledInputShieldContractDeclared(
    HWND game, const SampledInputShieldContract& contract) {
  return game != nullptr &&
         reinterpret_cast<uintptr_t>(
             GetPropW(game, contract.required_property)) ==
             contract.required_value;
}

bool IsSampledInputShieldContractReady(
    HWND game, const SampledInputShieldContract& contract) {
  return IsSampledInputShieldContractDeclared(game, contract) &&
         reinterpret_cast<uintptr_t>(GetPropW(game, contract.ready_property)) ==
             contract.ready_value;
}

// Retain the named SGRE predicate as a narrow compatibility seam for the
// source guards and for diagnostics that specifically discuss DirectInput.
// New host code selects the declared engine contract below.
bool IsSgreDirectInputShieldContractReady(HWND game) {
  return IsSampledInputShieldContractReady(
      game, kSgreSampledInputShieldContract);
}

bool IsSelectedSampledInputShieldContractReady(
    HWND game, const SampledInputShieldContract* contract) {
  if (contract == &kSgreSampledInputShieldContract) {
    return IsSgreDirectInputShieldContractReady(game);
  }
  return contract != nullptr &&
         IsSampledInputShieldContractReady(game, *contract);
}

const SampledInputShieldContract* SelectSampledInputShieldContract(
    HWND game, bool* any_declared) {
  const bool sgre = IsSampledInputShieldContractDeclared(
      game, kSgreSampledInputShieldContract);
  const bool siglus = IsSampledInputShieldContractDeclared(
      game, kSiglusSampledInputShieldContract);
  const bool leaf_aquaplus = IsSampledInputShieldContractDeclared(
      game, kLeafAquaplusSampledInputShieldContract);
  const bool hunex_gge = IsSampledInputShieldContractDeclared(
      game, kHunexGgeSampledInputShieldContract);
  const bool smash_fzmedia = IsSampledInputShieldContractDeclared(
      game, kSmashFzmediaSampledInputShieldContract);
  const uint32_t declared_count = static_cast<uint32_t>(sgre) +
                                  static_cast<uint32_t>(siglus) +
                                  static_cast<uint32_t>(leaf_aquaplus) +
                                  static_cast<uint32_t>(hunex_gge) +
                                  static_cast<uint32_t>(smash_fzmedia);
  if (any_declared != nullptr) *any_declared = declared_count != 0;
  // Multiple simultaneous declarations mean the target identity is
  // internally inconsistent. Never choose one arbitrarily: every injected ABI
  // suppresses physical input and a false choice can leave the game locked.
  if (declared_count != 1) return nullptr;
  if (sgre) return &kSgreSampledInputShieldContract;
  if (siglus) return &kSiglusSampledInputShieldContract;
  if (leaf_aquaplus) return &kLeafAquaplusSampledInputShieldContract;
  return hunex_gge ? &kHunexGgeSampledInputShieldContract
                   : &kSmashFzmediaSampledInputShieldContract;
}

bool HasSampledInputTailHandshake(
    const SampledInputShieldContract* contract) {
  return contract != nullptr && contract->tail_request_property != nullptr &&
         contract->tail_ack_property != nullptr;
}

// Call only after the hook thread has crossed a callback barrier.  A helper
// health failure or a destroyed game HWND can revoke the cross-process
// contract while the host still owns a Leaf tail token.  Such a token can no
// longer receive a real (raw-state-drained) acknowledgement; retaining it
// would make every later lookup popup fail closed forever.
void AbortInvalidDirectInputShieldAfterBarrier() {
  const HWND popup =
      g_direct_input_shield_popup.load(std::memory_order_acquire);
  if (popup == nullptr) return;
  const HWND game =
      g_direct_input_shield_game.load(std::memory_order_acquire);
  const SampledInputShieldContract* contract =
      g_direct_input_shield_contract.load(std::memory_order_acquire);
  const bool publication_valid =
      game != nullptr && IsWindow(game) && IsWindow(popup) &&
      contract != nullptr &&
      IsSelectedSampledInputShieldContractReady(game, contract) &&
      reinterpret_cast<HWND>(GetPropW(game, contract->window_property)) ==
          popup;
  if (publication_valid) return;

  const uint32_t token =
      g_direct_input_shield_tail_token.load(std::memory_order_acquire);
  if (game != nullptr && IsWindow(game) && contract != nullptr) {
    if (reinterpret_cast<HWND>(
            GetPropW(game, contract->window_property)) == popup) {
      RemovePropW(game, contract->window_property);
    }
    if (HasSampledInputTailHandshake(contract) && token != 0) {
      if (static_cast<uint32_t>(reinterpret_cast<uintptr_t>(GetPropW(
              game, contract->tail_request_property))) == token) {
        RemovePropW(game, contract->tail_request_property);
      }
      if (static_cast<uint32_t>(reinterpret_cast<uintptr_t>(GetPropW(
              game, contract->tail_ack_property))) == token) {
        RemovePropW(game, contract->tail_ack_property);
      }
    }
  }
  g_direct_input_shield_buttons.store(0, std::memory_order_release);
  g_direct_input_shield_tail_token.store(0, std::memory_order_release);
  g_direct_input_shield_popup.store(nullptr, std::memory_order_release);
  g_direct_input_shield_game.store(nullptr, std::memory_order_release);
  g_direct_input_shield_contract.store(nullptr, std::memory_order_release);
}

bool PublishSampledInputTailRequest(
    HWND game, const SampledInputShieldContract* contract,
    uint32_t button_bit) {
  if (!HasSampledInputTailHandshake(contract)) return true;
  const uint32_t requested =
      button_bit & fushi_voice_hook::kLeafAquaplusSampledInputButtonMask;
  if (requested == 0) return true;
  const uint32_t previous =
      g_direct_input_shield_tail_token.load(std::memory_order_acquire);
  const uint32_t buttons =
      requested | fushi_voice_hook::LeafAquaplusSampledInputTailButtons(
                      previous);
  const uint32_t generation =
      g_direct_input_shield_tail_generation.fetch_add(
          1, std::memory_order_acq_rel) +
      1u;
  const uint32_t token =
      fushi_voice_hook::MakeLeafAquaplusSampledInputTailToken(generation,
                                                              buttons);
  if (game == nullptr || !IsWindow(game) || token == 0 ||
      !SetPropW(game, contract->tail_request_property,
                reinterpret_cast<HANDLE>(static_cast<uintptr_t>(token)))) {
    return false;
  }
  // Publish host ownership only after the cross-process request is visible.
  // A stale helper ack cannot match this new generation.
  g_direct_input_shield_tail_token.store(token, std::memory_order_release);
  return true;
}

void RefreshSampledInputTailAck(
    HWND game, const SampledInputShieldContract* contract) {
  if (!HasSampledInputTailHandshake(contract) || game == nullptr ||
      !IsWindow(game)) {
    return;
  }
  uint32_t token =
      g_direct_input_shield_tail_token.load(std::memory_order_acquire);
  if (token == 0) return;
  const uint32_t ack = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(
      GetPropW(game, contract->tail_ack_property)));
  if (ack != token) return;
  // Do not remove the properties here: a new hook callback can publish a newer
  // request concurrently. The generation CAS is race-free; stale property
  // values are harmless and are removed only behind the callback barrier when
  // the Window publication itself is revoked.
  g_direct_input_shield_tail_token.compare_exchange_strong(
      token, 0, std::memory_order_acq_rel, std::memory_order_acquire);
}

enum class SampledShieldPublishResult {
  kNotRequired,
  kPublished,
  kUnavailable,
  kBusy,
};

SampledShieldPublishResult PublishDirectInputShieldIfReady(HWND popup,
                                                           HWND game) {
  bool any_declared = false;
  const SampledInputShieldContract* contract =
      SelectSampledInputShieldContract(game, &any_declared);
  if (contract == nullptr && !any_declared) {
    // Other engines retain the existing WH_MOUSE_LL-only path.
    return SampledShieldPublishResult::kNotRequired;
  }
  if (!IsSelectedSampledInputShieldContractReady(game, contract)) {
    // An exact sampled-input engine declared protection mandatory, but its
    // detour is absent/not ready (or two contracts conflict).  Fail closed
    // instead of silently falling back to the HHOOK-only route already
    // disproved on both SGRE and Siglus.
    return SampledShieldPublishResult::kUnavailable;
  }
  const uint32_t pending =
      g_direct_input_shield_buttons.load(std::memory_order_acquire);
  const HWND previous_game =
      g_direct_input_shield_game.load(std::memory_order_acquire);
  const HWND previous_popup =
      g_direct_input_shield_popup.load(std::memory_order_acquire);
  const uint32_t pending_tail =
      g_direct_input_shield_tail_token.load(std::memory_order_acquire);
  if ((pending != 0 || pending_tail != 0) &&
      (previous_game != game || previous_popup != popup)) {
    return SampledShieldPublishResult::kBusy;
  }
  if (HasSampledInputTailHandshake(contract) && pending_tail == 0) {
    RemovePropW(game, contract->tail_request_property);
    RemovePropW(game, contract->tail_ack_property);
  }
  // Cross-process SetProp can be denied by UIPI (normal Fushi -> elevated
  // game). Fail closed before the popup is shown; HHOOK alone is known not to
  // suppress an immediate physical-state poller.
  if (!SetPropW(game, contract->window_property,
                reinterpret_cast<HANDLE>(popup))) {
    return SampledShieldPublishResult::kUnavailable;
  }
  // Close the Ready -> Window TOCTOU with the helper's health worker: it may
  // revoke the contract between our first Ready read and SetProp.  Re-read both
  // commit properties and our exact Window value before exposing the popup.
  // The injected side, in turn, defers routine main-window migration while this
  // live publication exists.
  if (!IsSelectedSampledInputShieldContractReady(game, contract) ||
      reinterpret_cast<HWND>(GetPropW(game, contract->window_property)) !=
          popup) {
    if (reinterpret_cast<HWND>(
            GetPropW(game, contract->window_property)) == popup) {
      RemovePropW(game, contract->window_property);
    }
    return SampledShieldPublishResult::kUnavailable;
  }
  g_direct_input_shield_contract.store(contract, std::memory_order_release);
  g_direct_input_shield_game.store(game, std::memory_order_release);
  g_direct_input_shield_popup.store(popup, std::memory_order_release);
  return SampledShieldPublishResult::kPublished;
}

void RevokeDirectInputShieldIfIdle(HWND expected_popup) {
  const HWND popup =
      g_direct_input_shield_popup.load(std::memory_order_acquire);
  const HWND game =
      g_direct_input_shield_game.load(std::memory_order_acquire);
  if (popup == nullptr || game == nullptr || popup != expected_popup) return;
  const SampledInputShieldContract* contract =
      g_direct_input_shield_contract.load(std::memory_order_acquire);
  RefreshSampledInputTailAck(game, contract);
  if (g_target.load(std::memory_order_acquire) == popup ||
      g_direct_input_shield_buttons.load(std::memory_order_acquire) != 0 ||
      g_direct_input_shield_tail_token.load(std::memory_order_acquire) != 0) {
    return;
  }
  if (IsWindow(game) &&
      contract != nullptr &&
      reinterpret_cast<HWND>(GetPropW(game, contract->window_property)) ==
          popup) {
    RemovePropW(game, contract->window_property);
    if (HasSampledInputTailHandshake(contract)) {
      RemovePropW(game, contract->tail_request_property);
      RemovePropW(game, contract->tail_ack_property);
    }
  }
  g_direct_input_shield_tail_token.store(0, std::memory_order_release);
  g_direct_input_shield_popup.store(nullptr, std::memory_order_release);
  g_direct_input_shield_game.store(nullptr, std::memory_order_release);
  g_direct_input_shield_contract.store(nullptr, std::memory_order_release);
}

bool PointInWindowClient(HWND window, POINT point) {
  if (window == nullptr || !IsWindow(window) || IsIconic(window)) return false;
  RECT client{};
  POINT top_left{};
  POINT bottom_right{};
  if (!GetClientRect(window, &client)) return false;
  top_left.x = client.left;
  top_left.y = client.top;
  bottom_right.x = client.right;
  bottom_right.y = client.bottom;
  if (!ClientToScreen(window, &top_left) ||
      !ClientToScreen(window, &bottom_right)) {
    return false;
  }
  const RECT screen_client{top_left.x, top_left.y, bottom_right.x,
                           bottom_right.y};
  return PtInRect(&screen_client, point) != FALSE;
}

bool ShouldConsumeGameClientClick(HWND target, HWND game, HWND hit,
                                  POINT point) {
  if (game == nullptr || !IsWindow(game) || !PointInWindowClient(game, point)) {
    return false;
  }

  // WindowFromPoint 认 SetWindowRgn/子窗：查词栈的 bbox 中间可能有透明缝隙，
  // 只用 GetWindowRect 会把缝隙错当成卡内。真正命中 popup 时必须放行，交给
  // WebView2 处理按钮/嵌套查词。
  if (hit == target || (hit != nullptr && IsChild(target, hit))) return false;
  if (hit == nullptr) return false;

  // 只吞绑定的这一个游戏 HWND（或它的渲染子窗）。不能只比 PID：同进程的
  // 启动器/设置窗可能刚好盖在游戏坐标上，用户点它时必须正常收到点击。
  const bool hit_game = hit == game || IsChild(game, hit);
  if (!hit_game) return false;

  // 查词窗是 NOACTIVATE，正常情况下前台仍是 game。再锁一次前台可避免游戏
  // 已经失焦、别的窗口正接管输入时吞掉一次用于切回游戏的点击。
  return GetForegroundWindow() == game;
}

std::shared_ptr<const AttachedGlyphHitSnapshot>
AttachedGlyphSnapshotForTarget(HWND target) {
  const auto snapshot = std::atomic_load_explicit(
      &g_attached_hit_snapshot, std::memory_order_acquire);
  if (snapshot == nullptr || snapshot->surface != target ||
      snapshot->game_owner == nullptr || snapshot->screen_rects.empty()) {
    return nullptr;
  }
  return snapshot;
}

size_t AttachedGlyphRectAt(
    const std::shared_ptr<const AttachedGlyphHitSnapshot>& snapshot,
    POINT screen_point) {
  if (snapshot == nullptr) return SIZE_MAX;
  for (size_t index = 0; index < snapshot->screen_rects.size(); ++index) {
    if (PtInRect(&snapshot->screen_rects[index], screen_point)) return index;
  }
  return SIZE_MAX;
}

bool BareLeftClickModifiersClear() {
  constexpr int keys[] = {VK_SHIFT, VK_CONTROL, VK_MENU, VK_LWIN, VK_RWIN,
                          VK_RBUTTON, VK_MBUTTON, VK_XBUTTON1, VK_XBUTTON2};
  for (int key : keys) {
    if ((GetAsyncKeyState(key) & 0x8000) != 0) return false;
  }
  return true;
}

uint64_t NextAttachedGlyphTransactionId(uint32_t snapshot_token) {
  uint32_t sequence =
      g_attached_transaction_counter.fetch_add(1, std::memory_order_acq_rel) +
      1u;
  if (sequence == 0) {
    sequence =
        g_attached_transaction_counter.fetch_add(1,
                                                  std::memory_order_acq_rel) +
        1u;
  }
  return (static_cast<uint64_t>(snapshot_token) << 32u) | sequence;
}

void RequestAttachedGlyphReleasePoll();

void RequestAttachedGlyphPhysicalReconciliation() {
  const DWORD thread_id = g_thread_id.load(std::memory_order_acquire);
  if (thread_id != 0) {
    // HookProc runs on this installing thread, so this is only a queue append.
    // The thread timer performs the physical-state read after the normal 3s
    // grace; the callback itself never guesses that a held button was released.
    PostThreadMessage(thread_id, kThreadReconcileAttached, 0, 0);
  }
}

bool BeginAttachedGlyphTransaction(
    HWND target,
    const std::shared_ptr<const AttachedGlyphHitSnapshot>& snapshot,
    size_t rect_index, POINT screen_point, uint64_t* transaction_id) {
  if (transaction_id != nullptr) *transaction_id = 0;
  if (snapshot == nullptr || snapshot->surface != target ||
      rect_index >= snapshot->screen_rects.size()) {
    return false;
  }
  // WH_MOUSE_LL is a synchronous system hook. Contention with teardown or the
  // acknowledgement worker must fail open before publishing any shield state,
  // never park the system input thread on an SRW lock.
  if (!TryAcquireSRWLockExclusive(&g_attached_transaction_lock)) return false;
  if (g_attached_active_transaction.latch.active()) {
    ReleaseSRWLockExclusive(&g_attached_transaction_lock);
    return false;
  }
  const auto current = std::atomic_load_explicit(
      &g_attached_hit_snapshot, std::memory_order_acquire);
  if (current.get() != snapshot.get()) {
    ReleaseSRWLockExclusive(&g_attached_transaction_lock);
    return false;
  }
  const uint64_t id = NextAttachedGlyphTransactionId(snapshot->token);
  const uint32_t request_seq =
      VoiceHookReader::Instance().TryPublishLookupShieldTransaction(
          fushi_voice_hook::kLookupShieldOwnerAttachedGlyph,
          snapshot->game_owner, id,
          fushi_voice_hook::kLookupShieldButtonLeft, snapshot->allow_risk);
  const auto after_publish = std::atomic_load_explicit(
      &g_attached_hit_snapshot, std::memory_order_acquire);
  if (request_seq == 0 || after_publish.get() != snapshot.get()) {
    if (request_seq != 0) {
      // The published down already belongs to this physical transaction even
      // though its immutable geometry was concurrently revoked.  Cancel only
      // the lookup submission: treating revocation as a physical up would make
      // GetAsyncKeyState/DirectInput/Raw Input expose the held button and its
      // eventual up tail to the game.
      g_attached_active_transaction.latch.Begin(id, request_seq);
      g_attached_active_transaction.latch.Cancel();
      g_attached_active_transaction.snapshot = snapshot;
      g_attached_active_transaction_id.store(id, std::memory_order_release);
      ReleaseSRWLockExclusive(&g_attached_transaction_lock);
      RequestAttachedGlyphReleasePoll();
      RequestAttachedGlyphPhysicalReconciliation();
      // A down request is already visible to the injected reducer. Swallow the
      // corresponding Win32 down even though the geometry was concurrently
      // revoked; failing open after publication would split one click across
      // two owners.
      if (transaction_id != nullptr) *transaction_id = id;
      return true;
    }
    ReleaseSRWLockExclusive(&g_attached_transaction_lock);
    return false;
  }
  if (!g_attached_active_transaction.latch.Begin(id, request_seq)) {
    // This is unreachable under the exclusive latch lock, but failing open is
    // safer than blocking the system hook on a compensating publish.
    ReleaseSRWLockExclusive(&g_attached_transaction_lock);
    return false;
  }
  g_attached_active_transaction.rect_index = rect_index;
  g_attached_active_transaction.down_point = screen_point;
  g_attached_active_transaction.snapshot = snapshot;
  g_attached_active_transaction_id.store(id, std::memory_order_release);
  ReleaseSRWLockExclusive(&g_attached_transaction_lock);
  RequestAttachedGlyphPhysicalReconciliation();

  if (!PostMessageW(target, kLowLevelMouseAttachedGlyphDownMessage,
                    static_cast<WPARAM>(id),
                    static_cast<LPARAM>(PackMouseHookPoint(
                        screen_point.x, screen_point.y)))) {
    if (TryAcquireSRWLockExclusive(&g_attached_transaction_lock)) {
      if (g_attached_active_transaction.latch.transaction_id() == id) {
        g_attached_active_transaction.latch.Cancel();
      }
      ReleaseSRWLockExclusive(&g_attached_transaction_lock);
    } else {
      // Lock contention cannot turn a failed UI notification into a synthetic
      // button-up.  The worker applies this cancellation marker while the live
      // physical transaction and its sampled-input latch remain owned.
      g_attached_pending_cancel_transaction_id.store(id,
                                                      std::memory_order_release);
    }
    RequestAttachedGlyphReleasePoll();
    if (transaction_id != nullptr) *transaction_id = id;
    return true;
  }
  if (transaction_id != nullptr) *transaction_id = id;
  return true;
}

bool AdvanceAttachedGlyphReleaseIfAcknowledged();

bool ApplyPendingAttachedGlyphCancellation() {
  const uint64_t transaction_id =
      g_attached_pending_cancel_transaction_id.exchange(
          0, std::memory_order_acq_rel);
  if (transaction_id == 0) return false;

  AcquireSRWLockExclusive(&g_attached_transaction_lock);
  const bool matches =
      g_attached_active_transaction.latch.transaction_id() == transaction_id;
  if (matches) g_attached_active_transaction.latch.Cancel();
  ReleaseSRWLockExclusive(&g_attached_transaction_lock);
  return matches;
}

bool ApplyPendingAttachedGlyphPhysicalUp() {
  const uint64_t transaction_id =
      g_attached_pending_up_transaction_id.exchange(
          0, std::memory_order_acq_rel);
  if (transaction_id == 0) return false;
  const POINT screen_point = UnpackMouseHookPoint(
      g_attached_pending_up_point.load(std::memory_order_relaxed));
  const bool real_up =
      g_attached_pending_up_real.load(std::memory_order_relaxed);

  AcquireSRWLockExclusive(&g_attached_transaction_lock);
  if (g_attached_active_transaction.latch.transaction_id() != transaction_id ||
      g_attached_active_transaction.snapshot == nullptr) {
    ReleaseSRWLockExclusive(&g_attached_transaction_lock);
    return false;
  }
  const bool first_up =
      g_attached_active_transaction.latch.MarkPhysicalUp();
  if (first_up) {
    g_attached_active_transaction.physical_up_tick = GetTickCount64();
  }
  const bool cancel_submission =
      !real_up || g_attached_active_transaction.latch.cancelled();
  const HWND surface = g_attached_active_transaction.snapshot->surface;
  ReleaseSRWLockExclusive(&g_attached_transaction_lock);
  if (first_up) {
    PostMessageW(surface,
                 cancel_submission ? kLowLevelMouseAttachedGlyphCancelMessage
                                   : kLowLevelMouseAttachedGlyphUpMessage,
                 static_cast<WPARAM>(transaction_id),
                 static_cast<LPARAM>(PackMouseHookPoint(
                     screen_point.x, screen_point.y)));
  }
  return true;
}

void EnsureAttachedGlyphReleaseWorker() {
  std::call_once(g_attached_release_worker_once, []() {
    std::thread([]() {
      std::unique_lock<std::mutex> lock(g_attached_release_worker_mutex);
      for (;;) {
        g_attached_release_worker_cv.wait(lock, []() {
          return g_attached_release_work_requested.load(
              std::memory_order_acquire);
        });
        g_attached_release_work_requested.store(false,
                                                std::memory_order_release);
        lock.unlock();
        ApplyPendingAttachedGlyphCancellation();
        ApplyPendingAttachedGlyphPhysicalUp();
        while (AdvanceAttachedGlyphReleaseIfAcknowledged()) {
          std::this_thread::sleep_for(
              std::chrono::milliseconds(kAttachedReleasePollMs));
        }
        lock.lock();
      }
    }).detach();
  });
}

void RequestAttachedGlyphReleasePoll() {
  // The worker is created on the surface/platform thread before the immutable
  // snapshot is published. Callback-side wake-up is therefore a lock-free
  // atomic store plus notify; it never enters call_once or the worker mutex.
  g_attached_release_work_requested.store(true, std::memory_order_release);
  g_attached_release_worker_cv.notify_one();
}

bool ObserveAttachedGlyphPhysicalUp(POINT screen_point, bool real_up) {
  AcquireSRWLockExclusive(&g_attached_transaction_lock);
  if (!g_attached_active_transaction.latch.active() ||
      g_attached_active_transaction.snapshot == nullptr) {
    ReleaseSRWLockExclusive(&g_attached_transaction_lock);
    return false;
  }
  const bool first_up =
      g_attached_active_transaction.latch.MarkPhysicalUp();
  if (first_up) {
    g_attached_active_transaction.physical_up_tick = GetTickCount64();
  }
  const uint64_t transaction_id =
      g_attached_active_transaction.latch.transaction_id();
  const bool cancel_submission =
      !real_up || g_attached_active_transaction.latch.cancelled();
  const HWND surface = g_attached_active_transaction.snapshot->surface;
  ReleaseSRWLockExclusive(&g_attached_transaction_lock);
  if (first_up) {
    PostMessageW(surface,
                 cancel_submission ? kLowLevelMouseAttachedGlyphCancelMessage
                                   : kLowLevelMouseAttachedGlyphUpMessage,
                 static_cast<WPARAM>(transaction_id),
                 static_cast<LPARAM>(
                     PackMouseHookPoint(screen_point.x, screen_point.y)));
  }
  RequestAttachedGlyphReleasePoll();
  return true;
}

bool TryObserveAttachedGlyphPhysicalUp(POINT screen_point, bool real_up) {
  const uint64_t transaction_id =
      g_attached_active_transaction_id.load(std::memory_order_acquire);
  if (transaction_id == 0) return false;
  if (!TryAcquireSRWLockExclusive(&g_attached_transaction_lock)) {
    g_attached_pending_up_point.store(
        PackMouseHookPoint(screen_point.x, screen_point.y),
        std::memory_order_relaxed);
    g_attached_pending_up_real.store(real_up, std::memory_order_relaxed);
    g_attached_pending_up_transaction_id.store(transaction_id,
                                                std::memory_order_release);
    RequestAttachedGlyphReleasePoll();
    return true;
  }
  if (g_attached_active_transaction.latch.transaction_id() != transaction_id ||
      g_attached_active_transaction.snapshot == nullptr) {
    ReleaseSRWLockExclusive(&g_attached_transaction_lock);
    return false;
  }
  const bool first_up =
      g_attached_active_transaction.latch.MarkPhysicalUp();
  if (first_up) {
    g_attached_active_transaction.physical_up_tick = GetTickCount64();
  }
  const bool cancel_submission =
      !real_up || g_attached_active_transaction.latch.cancelled();
  const HWND surface = g_attached_active_transaction.snapshot->surface;
  ReleaseSRWLockExclusive(&g_attached_transaction_lock);
  if (first_up) {
    PostMessageW(surface,
                 cancel_submission ? kLowLevelMouseAttachedGlyphCancelMessage
                                   : kLowLevelMouseAttachedGlyphUpMessage,
                 static_cast<WPARAM>(transaction_id),
                 static_cast<LPARAM>(PackMouseHookPoint(
                     screen_point.x, screen_point.y)));
  }
  RequestAttachedGlyphReleasePoll();
  return true;
}

bool EndAttachedGlyphTransaction(POINT screen_point) {
  return TryObserveAttachedGlyphPhysicalUp(screen_point, true);
}

bool HasActiveAttachedGlyphTransactionFast() {
  return g_attached_active_transaction_id.load(std::memory_order_acquire) != 0;
}

bool HasActiveAttachedGlyphTransaction() {
  AcquireSRWLockShared(&g_attached_transaction_lock);
  const bool active = g_attached_active_transaction.latch.active();
  ReleaseSRWLockShared(&g_attached_transaction_lock);
  return active;
}

bool FailOpenRetireAttachedGlyphTransaction(uint64_t transaction_id) {
  if (transaction_id == 0)
    return false;
  std::shared_ptr<const AttachedGlyphHitSnapshot> retired_snapshot;
  AcquireSRWLockExclusive(&g_attached_transaction_lock);
  if (g_attached_active_transaction.latch.transaction_id() != transaction_id ||
      g_attached_active_transaction.snapshot == nullptr ||
      g_attached_active_transaction.latch.FailOpenRetireAfterPhysicalUp() == 0) {
    ReleaseSRWLockExclusive(&g_attached_transaction_lock);
    return false;
  }
  retired_snapshot = g_attached_active_transaction.snapshot;

  // Revoke the admitting snapshot before publishing the lock-free inactive id.
  // Otherwise HookProc could observe id==0, begin another transaction from the
  // old snapshot, and overwrite the best-effort neutral in this tiny gap.
  auto current = std::atomic_load_explicit(
      &g_attached_hit_snapshot, std::memory_order_acquire);
  while (current.get() == retired_snapshot.get()) {
    std::shared_ptr<const AttachedGlyphHitSnapshot> empty;
    if (std::atomic_compare_exchange_weak_explicit(
            &g_attached_hit_snapshot, &current, empty,
            std::memory_order_acq_rel, std::memory_order_acquire)) {
      break;
    }
  }
  HWND expected_target = retired_snapshot->surface;
  g_target.compare_exchange_strong(expected_target, nullptr,
                                   std::memory_order_acq_rel,
                                   std::memory_order_acquire);
  g_attached_active_transaction = {};
  g_attached_active_transaction_id.store(0, std::memory_order_release);
  ReleaseSRWLockExclusive(&g_attached_transaction_lock);

  // The platform-thread mirror must not submit a lookup whose sampled-input
  // transaction could not be acknowledged. PostMessage remains non-blocking;
  // a destroyed surface simply means there is no mirror left to cancel/hide.
  PostMessageW(retired_snapshot->surface,
               kLowLevelMouseAttachedGlyphAbortMessage,
               static_cast<WPARAM>(transaction_id), 0);
  return true;
}

// Device replacement or a removed hook can lose the physical up.  The normal
// path must wait for WM_LBUTTONUP; only the existing three-second reconciliation
// timer may synthesize release once physical state proves the button is up.
bool ReconcileAttachedGlyphTransactionWithPhysicalState() {
  if (!HasActiveAttachedGlyphTransaction()) return false;
  AcquireSRWLockShared(&g_attached_transaction_lock);
  const bool physical_up =
      g_attached_active_transaction.latch.physical_up();
  ReleaseSRWLockShared(&g_attached_transaction_lock);
  if (!physical_up) {
    if ((GetAsyncKeyState(VK_LBUTTON) & 0x8000) != 0) return true;
    POINT point{};
    GetCursorPos(&point);
    ObserveAttachedGlyphPhysicalUp(point, false);
  }
  return HasActiveAttachedGlyphTransaction();
}

// Advance the single-slot v19 request in two acknowledged phases. A fast
// physical up must not overwrite the down request before the injected reducer
// has observed it; likewise, ownership is retained until the neutral release
// itself is acknowledged so provider handoff cannot cut through the tail.
bool AdvanceAttachedGlyphReleaseIfAcknowledged() {
  AcquireSRWLockShared(&g_attached_transaction_lock);
  if (!g_attached_active_transaction.latch.active() ||
      !g_attached_active_transaction.latch.physical_up() ||
      g_attached_active_transaction.snapshot == nullptr) {
    ReleaseSRWLockShared(&g_attached_transaction_lock);
    return false;
  }
  const uint64_t transaction_id =
      g_attached_active_transaction.latch.transaction_id();
  const uint32_t down_request_seq =
      g_attached_active_transaction.latch.down_request_seq();
  uint32_t release_request_seq =
      g_attached_active_transaction.latch.release_request_seq();
  const ULONGLONG physical_up_tick =
      g_attached_active_transaction.physical_up_tick;
  const auto snapshot = g_attached_active_transaction.snapshot;
  ReleaseSRWLockShared(&g_attached_transaction_lock);

  VoiceHookLookupShieldStatus status =
      VoiceHookReader::Instance().LookupShieldStatus();
  const uint64_t raw_target =
      static_cast<uint64_t>(reinterpret_cast<uintptr_t>(snapshot->game_owner));
  auto status_belongs_to_transaction = [&]() {
    return status.ok() &&
           status.owner_kind ==
               fushi_voice_hook::kLookupShieldOwnerAttachedGlyph &&
           status.target_hwnd == raw_target &&
           status.transaction_id == transaction_id;
  };
  auto fail_open_after_best_effort_neutral = [&]() {
    // Only an exact, coherently read request is safe to overwrite. If the IPC
    // mapping is gone/invalid, or another owner has already replaced it, there
    // is nothing this host can safely write; retire the already-physical-up LL
    // latch so the process cannot become a global left-click sink.
    if (status_belongs_to_transaction() && status.active_buttons != 0) {
      (void)VoiceHookReader::Instance().PublishLookupShieldTransaction(
          fushi_voice_hook::kLookupShieldOwnerAttachedGlyph,
          snapshot->game_owner, transaction_id, 0, snapshot->allow_risk);
    }
    return !FailOpenRetireAttachedGlyphTransaction(transaction_id);
  };
  if (!status.ok()) {
    return fail_open_after_best_effort_neutral();
  }
  const uint32_t expected_request_seq =
      release_request_seq == 0 ? down_request_seq : release_request_seq;
  if (!status_belongs_to_transaction() ||
      status.request_seq != expected_request_seq) {
    return fail_open_after_best_effort_neutral();
  }
  const bool shield_faulted =
      status.fault_mask != 0 ||
      (status.status_flags &
       fushi_voice_hook::kLookupShieldStatusFaulted) != 0;
  const bool acknowledgement_timed_out =
      AttachedGlyphAcknowledgeTimedOut(
          physical_up_tick, GetTickCount64(),
          kAttachedShieldAcknowledgeTimeoutMs);
  if (shield_faulted || acknowledgement_timed_out) {
    return fail_open_after_best_effort_neutral();
  }
  if (release_request_seq == 0 && status.ok() &&
      status.request_seq == down_request_seq &&
      status.applied_seq == down_request_seq) {
    const uint32_t release_seq =
        VoiceHookReader::Instance().PublishLookupShieldTransaction(
            fushi_voice_hook::kLookupShieldOwnerAttachedGlyph,
            snapshot->game_owner, transaction_id, 0, snapshot->allow_risk);
    AcquireSRWLockExclusive(&g_attached_transaction_lock);
    if (g_attached_active_transaction.latch.transaction_id() ==
            transaction_id &&
        g_attached_active_transaction.latch.release_request_seq() == 0) {
      g_attached_active_transaction.latch.RecordReleaseRequest(release_seq);
      release_request_seq = release_seq;
    }
    ReleaseSRWLockExclusive(&g_attached_transaction_lock);
    if (release_seq == 0) {
      return fail_open_after_best_effort_neutral();
    }
  }

  if (release_request_seq != 0) {
    status = VoiceHookReader::Instance().LookupShieldStatus();
    if (!status.ok() || !status_belongs_to_transaction() ||
        status.request_seq != release_request_seq) {
      return fail_open_after_best_effort_neutral();
    }
    if (status.fault_mask != 0 ||
        (status.status_flags &
         fushi_voice_hook::kLookupShieldStatusFaulted) != 0 ||
        AttachedGlyphAcknowledgeTimedOut(
            physical_up_tick, GetTickCount64(),
            kAttachedShieldAcknowledgeTimeoutMs)) {
      return fail_open_after_best_effort_neutral();
    }
    AcquireSRWLockExclusive(&g_attached_transaction_lock);
    if (g_attached_active_transaction.latch.transaction_id() ==
            transaction_id &&
        status.ok() && g_attached_active_transaction.latch.CanRetire(
                           status.request_seq, status.applied_seq,
                           status.active_buttons)) {
      g_attached_active_transaction.latch.Retire();
      g_attached_active_transaction = {};
      g_attached_active_transaction_id.store(0, std::memory_order_release);
      ReleaseSRWLockExclusive(&g_attached_transaction_lock);
      return false;
    }
    ReleaseSRWLockExclusive(&g_attached_transaction_lock);
  }
  return true;
}

LRESULT CALLBACK HookProc(int code, WPARAM wparam, LPARAM lparam) {
  // BUG-1286 — 存活证据必须记在最前面：**移动事件**才是每秒都有的那类，用它证明
  // 钩子还在链上；记在过滤分支之后就只剩点击/滚轮能刷新，判据立刻失效。
  // GetTickCount64 是读共享页的纯计算，没有系统调用开销。
  g_callback_tick.store(GetTickCount64(), std::memory_order_relaxed);
  // 只关心「按键」和「滚轮」：移动直接放行（这条分支每秒会跑上千次，在任何系统
  // 调用之前必须先被纯比较挡掉）。BUG-1882 需要看 up，但 up 仍只是
  // 按键频率，不会把系统调用放进高频 move 路径。
  const bool is_button_down = IsButtonDownMessage(wparam);
  const bool is_button_up = IsButtonUpMessage(wparam);
  const bool is_wheel =
      (wparam == WM_MOUSEWHEEL || wparam == WM_MOUSEHWHEEL);
  if (code < 0 || (!is_button_down && !is_button_up && !is_wheel)) {
    return CallNextHookEx(nullptr, code, wparam, lparam);
  }
  const MSLLHOOKSTRUCT* info = reinterpret_cast<const MSLLHOOKSTRUCT*>(lparam);
  const uint32_t button_bit =
      (is_button_down || is_button_up)
          ? ButtonBitForMessage(wparam, info->mouseData)
          : 0;

  // 这道闸故意在 g_target 之前。外部 down 被吞后，PostMessage 会让窗口线程
  // 立刻 Hide/Disarm；配对 up 到来时 target 通常已空，若先看 target 就会漏半个
  // 点击给那些在 button-up 推进的游戏。
  if (is_button_up) {
    const uint32_t bit = button_bit;
    if (wparam == WM_LBUTTONUP) {
      EndAttachedGlyphTransaction(info->pt);
    }
    if (bit != 0) {
      const uint32_t previous = g_direct_input_shield_buttons.fetch_and(
          ~bit, std::memory_order_relaxed);
      if ((previous & bit) != 0 && (previous & ~bit) == 0) {
        RequestDirectInputShieldFinalize();
      }
    }
    if (bit != 0 &&
        (g_swallowed_buttons.fetch_and(~bit, std::memory_order_relaxed) & bit) !=
            0) {
      return 1;
    }
    return CallNextHookEx(nullptr, code, wparam, lparam);
  }
  if (is_button_down) {
    const uint32_t bit = button_bit;
    if (wparam == WM_LBUTTONDOWN &&
        HasActiveAttachedGlyphTransactionFast()) {
      // The previous physical up was lost or its neutral release is still
      // waiting for injected acknowledgement. A repeated/injected down does
      // not prove that the button was ever released, so it must never open the
      // neutral tail. Swallow it and leave the original latch untouched; only
      // a real up or the delayed three-second physical reconciliation may mark
      // the transaction complete.
      g_swallowed_buttons.fetch_or(kSwallowedLeftButton,
                                    std::memory_order_relaxed);
      return 1;
    }
    if (bit != 0) {
      // A fresh down proves any older transaction for this same physical
      // button has already ended, even if its low-level up was lost (device
      // switch / hook replacement). Drop that stale bit before deciding the
      // new transaction; otherwise an inside-popup click can leave the bit set
      // and have its unrelated up swallowed seconds later.
      g_swallowed_buttons.fetch_and(~bit, std::memory_order_relaxed);
      // 同一物理键的新 down 同样证明上一次 DirectInput 屏蔽事务已经结束。两套位
      // 集合必须同构：只给 g_swallowed_buttons 补这一步，丢失的 up 就只会把
      // shield 位卡住，于是下一个浮窗的 PublishDirectInputShieldIfReady 因
      // pending!=0 且 popup 变了而 fail-closed，游戏内查词在 3s 物理状态对账之前
      // 一直装不上。清位与随后的条件 fetch_or 不冲突：新 down 若仍满足屏蔽契约，
      // 下面几行会把位重新置上。
      const uint32_t stale_shield = g_direct_input_shield_buttons.fetch_and(
          ~bit, std::memory_order_relaxed);
      if ((stale_shield & bit) != 0 && (stale_shield & ~bit) == 0) {
        RequestDirectInputShieldFinalize();
      }
    }
  }
  const HWND target = g_target.load(std::memory_order_acquire);
  if (target == nullptr) {
    return CallNextHookEx(nullptr, code, wparam, lparam);
  }
  // Attached runtime owns a fully prevalidated immutable screen-space
  // snapshot. Handle it before any HWND/property/WindowFromPoint calls: the
  // system is synchronously waiting for this callback, so a hit needs only the
  // bounded modifier reads, rectangle scan and single-CAS v19 TryPublish path.
  const auto attached_snapshot = AttachedGlyphSnapshotForTarget(target);
  if (attached_snapshot != nullptr) {
    if (wparam == WM_LBUTTONDOWN && BareLeftClickModifiersClear()) {
      const size_t attached_rect =
          AttachedGlyphRectAt(attached_snapshot, info->pt);
      if (attached_rect != SIZE_MAX) {
        uint64_t transaction_id = 0;
        if (BeginAttachedGlyphTransaction(target, attached_snapshot,
                                          attached_rect, info->pt,
                                          &transaction_id)) {
          g_swallowed_buttons.fetch_or(kSwallowedLeftButton,
                                        std::memory_order_relaxed);
          return 1;
        }
      }
    }
    return CallNextHookEx(nullptr, code, wparam, lparam);
  }
  if (!IsWindow(target)) {
    return CallNextHookEx(nullptr, code, wparam, lparam);
  }
  if (is_button_down) {
    // SetWindowRgn 把级联卡片裁成若干圆角 shell；它们的包围矩形包含圆角和卡间
    // 透明 hole。WindowFromPoint 遵守真实 window region，因此这里传给窗口线程的
    // inside 必须与吞点击判定使用同一份几何真相，不能退回 GetWindowRect。
    const HWND point_window = WindowFromPoint(info->pt);
    const bool inside = point_window == target ||
                        (point_window != nullptr &&
                         IsChild(target, point_window));
    const HWND consume_owner = reinterpret_cast<HWND>(
        GetPropW(target, kConsumeOutsideOwnerProperty));
    const HWND sampled_owner = reinterpret_cast<HWND>(
        GetPropW(target, kSampledShieldOwnerProperty));
    const uint32_t bit = button_bit;
    const HWND shield_game =
        g_direct_input_shield_game.load(std::memory_order_acquire);
    const HWND shield_popup =
        g_direct_input_shield_popup.load(std::memory_order_acquire);
    const SampledInputShieldContract* shield_contract =
        g_direct_input_shield_contract.load(std::memory_order_acquire);
    if (bit != 0 && shield_game == sampled_owner && shield_popup == target &&
        shield_contract != nullptr &&
        reinterpret_cast<HWND>(
            GetPropW(shield_game, shield_contract->window_property)) == target) {
      // Track both outside and popup-internal downs. WebView2 still receives an
      // internal click, while the injected DirectInput detour hides it from the
      // game and retains the publication if that click closes the popup.
      // Leaf's GetAsyncKeyState low bit can survive a complete fast click that
      // happens between two engine polls. Publish a generation-tagged tail
      // request before the popup thread can hide; the injected detour acks only
      // after it has consumed the active sample and then observed raw zero.
      const bool tail_published =
          PublishSampledInputTailRequest(shield_game, shield_contract, bit);
      g_direct_input_shield_buttons.fetch_or(bit,
                                              std::memory_order_relaxed);
      if (!tail_published) {
        // Never dispatch this down to either WebView or the dismiss path.  A
        // Leaf quick click can otherwise close the popup between two engine
        // polls without a retained low-bit drain request, then advance the
        // game.  Keep the popup/Window publication intact and swallow the
        // matching up; a later transaction may retry the tail publication.
        g_swallowed_buttons.fetch_or(bit, std::memory_order_relaxed);
        return 1;
      }
    }
    const bool consume_click =
        bit != 0 &&
        ShouldConsumeGameClientClick(target, consume_owner, point_window,
                                     info->pt);
    if (consume_click) {
      // Freeze the paired-up transaction BEFORE notifying the window thread.
      // That thread may process PostMessage immediately and Hide/Disarm, clearing
      // g_target before the physical up arrives.
      g_swallowed_buttons.fetch_or(bit, std::memory_order_relaxed);
    }
    PostMessage(target, kLowLevelMouseClickMessage,
                PackMouseHookPoint(info->pt.x, info->pt.y), inside ? 1 : 0);
    if (consume_click) {
      // 返回非 0 = 这次 down 不进入游戏的输入队列。窗口线程已经收到
      // 异步 dismiss 消息；这里绝不同步等它，否则又把 Flutter/WebView2 忙闲
      // 拽回全系统输入路径（BUG-1048）。
      return 1;
    }
    return CallNextHookEx(nullptr, code, wparam, lparam);
  }
  // BUG-1166 — 滚轮落在查词卡上：吞掉，改投给窗口线程。
  //
  // 命中判定**不能**用 GetWindowRect：级联查词的窗口是整叠卡片的包围盒，
  // TODO-1345 的「保留地板」窗更是横跨大半个工作区，真正可见的只有 ApplyRoundedRegion
  // 用 SetWindowRgn 裁出来的那几块卡片（BUG-749）。按 rect 判，等于卡片一开就把
  // 半个屏幕的滚轮全吞了——用户在游戏画面上滚也会被吃掉。
  // WindowFromPoint 认窗口区域，答的正是「光标此刻真的压在卡片上吗」；卡片之间的
  // 透明缝隙判为「不在」，滚轮照常归游戏，这也正是用户在那儿看到的东西。
  const HWND hit = WindowFromPoint(info->pt);
  if (hit == nullptr || (hit != target && !IsChild(target, hit))) {
    return CallNextHookEx(nullptr, code, wparam, lparam);
  }
  MouseHookWheel wheel;
  wheel.delta = static_cast<short>(HIWORD(info->mouseData));
  wheel.horizontal = (wparam == WM_MOUSEHWHEEL);
  // 修饰键必须现取：MSLLHOOKSTRUCT 不带键状态，而钩子线程的 GetKeyState 是它自己
  // 那份从不更新的输入状态。GetAsyncKeyState 读的是物理按键，跨线程有效；只在滚轮
  // 事件上跑（每秒几十次量级），不会拖慢移动事件那条纯比较的快路。
  //
  // 这里取到的是**唯一可信的修饰键真值**：过了 PostMessage 那道边界就再也拿不回来
  // （Chromium 读 GetKeyState，而合成消息不更新键状态表）。ctrl/alt 因此单独成字段
  // 随载荷带走，供窗口线程分流；MK_* 位只是给裸滚轮那条原生快路捎带的。
  const bool ctrl_down = (GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0;
  const bool shift_down = (GetAsyncKeyState(VK_SHIFT) & 0x8000) != 0;
  const bool alt_down = (GetAsyncKeyState(VK_MENU) & 0x8000) != 0;
  if (ctrl_down) wheel.keys |= MK_CONTROL;
  if (shift_down) wheel.keys |= MK_SHIFT;
  wheel.ctrl = ctrl_down;
  wheel.alt = alt_down;
  PostMessage(target, kLowLevelMouseWheelMessage,
              PackMouseHookPoint(info->pt.x, info->pt.y),
              PackMouseHookWheel(wheel));
  // 返回非 0 = 事件到此为止：不进入任何线程的输入队列，前台的 galgame 也就收不到
  // WM_MOUSEWHEEL。这是整个修复的落点，改成 CallNextHookEx 就等于没修。
  return 1;
}

void HookThreadMain() {
  // BUG-1077 — WH_MOUSE_LL 是同步钩子：系统等这条线程被调度并返回才把输入分发给
  // 前台程序。嵌套查词的瞬间，进程内同时有同步 FFI 词典查询、整栈 JSON 序列化、
  // WebView2 COM 与窗口区域重建在抢核；NORMAL 优先级的钩子线程被抢占几十毫秒，
  // 全系统鼠标就跟着卡一下。TIME_CRITICAL 是 LL 钩子承载线程的标准做法——回调
  // 每个事件只做两次整数比较，高优先级不会饿着任何人。
  SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_TIME_CRITICAL);
  // 线程必须有消息队列钩子事件才会被投递过来；PeekMessage 强制系统建队列，之后
  // Arm/Disarm 的 PostThreadMessage 才不会丢。
  MSG msg{};
  PeekMessage(&msg, nullptr, WM_USER, WM_USER, PM_NOREMOVE);
  g_thread_id.store(GetCurrentThreadId(), std::memory_order_release);
  SetEvent(g_thread_ready);

  HHOOK hook = nullptr;
  // 宽限期卸载定时器（线程定时器，WM_TIMER 走本线程消息队列）。0 = 未挂起。
  UINT_PTR disarm_timer = 0;
  // BUG-1286 — 存活性核对定时器：常驻，不随 Arm/Disarm 起停。armed 状态的真值是
  // g_target，Arm/Disarm 消息只是「立刻生效」的快路径；让这只定时器周期性地把实际
  // 钩子状态收敛到 g_target，SetWindowsHookEx 失败、PostThreadMessage 丢失、系统
  // 摘钩这三类静默失败就都只是「下一拍自动补上」，不再各需一套特例分支。
  UINT_PTR liveness_timer = SetTimer(nullptr, 0, kLivenessIntervalMs, nullptr);
  POINT last_cursor{};
  GetCursorPos(&last_cursor);
  ULONGLONG last_seen_tick = g_callback_tick.load(std::memory_order_relaxed);
  while (GetMessage(&msg, nullptr, 0, 0) > 0) {
    if (msg.message == kThreadArm) {
      const uint32_t ack_generation = static_cast<uint32_t>(msg.wParam);
      // A re-arm normally cancels deferred unload. The exception is a swallowed
      // down still waiting for up: that timer also reconciles a device-switch
      // lost-up against physical button state, so cancelling it would leave a
      // stale bit that later eats an unrelated up in the new popup.
      // Do NOT reconcile against GetAsyncKeyState here. The physical button may
      // already read as up while its WH_MOUSE_LL up callback is still queued on
      // this same thread; clearing now would let that queued up reach the game.
      // Keep/schedule the timer and reconcile only after the 3s grace.
      const bool has_pending_button =
          g_swallowed_buttons.load(std::memory_order_relaxed) != 0 ||
          g_direct_input_shield_buttons.load(std::memory_order_relaxed) != 0 ||
          HasActiveAttachedGlyphTransaction();
      if (disarm_timer != 0 && !has_pending_button) {
        KillTimer(nullptr, disarm_timer);
        disarm_timer = 0;
      } else if (disarm_timer == 0 && has_pending_button) {
        disarm_timer = SetTimer(nullptr, 0, kDisarmGraceMs, nullptr);
      }
      if (ack_generation != 0 && hook != nullptr && !has_pending_button) {
        const ULONGLONG callback_tick =
            g_callback_tick.load(std::memory_order_relaxed);
        const ULONGLONG now = GetTickCount64();
        if (callback_tick == 0 ||
            now - callback_tick > kSynchronousArmFreshnessMs) {
          UnhookWindowsHookEx(hook);
          hook = nullptr;
          g_hook_active.store(false, std::memory_order_release);
        }
      }
      if (hook == nullptr) {
        hook = SetWindowsHookEx(WH_MOUSE_LL, &HookProc,
                                GetModuleHandle(nullptr), 0);
      }
      g_hook_active.store(hook != nullptr, std::memory_order_release);
      if (ack_generation != 0 && g_arm_applied_event != nullptr) {
        g_arm_applied_generation.store(ack_generation,
                                       std::memory_order_release);
        SetEvent(g_arm_applied_event);
      }
    } else if (msg.message == WM_TIMER && liveness_timer != 0 &&
               msg.wParam == liveness_timer) {
      POINT cursor{};
      const BOOL got_cursor = GetCursorPos(&cursor);
      const ULONGLONG seen_tick =
          g_callback_tick.load(std::memory_order_relaxed);
      if (g_target.load(std::memory_order_relaxed) != nullptr) {
        if (hook == nullptr) {
          // armed 但没有钩子：Arm 那次 SetWindowsHookEx 失败，或 kThreadArm 根本没
          // 送达（PostThreadMessage 会失败，旧实现没检查返回值）。补装。
          hook = SetWindowsHookEx(WH_MOUSE_LL, &HookProc,
                                  GetModuleHandle(nullptr), 0);
          g_hook_active.store(hook != nullptr, std::memory_order_release);
        } else if (got_cursor &&
                   (cursor.x != last_cursor.x || cursor.y != last_cursor.y) &&
                   seen_tick == last_seen_tick) {
          // 判据零误报：光标位置变了，说明这一秒里系统一定投递过 WM_MOUSEMOVE；
          // 而我们的回调一次都没跑，那它只可能已经不在钩子链上了（被系统摘掉，或被
          // 链上更靠前的钩子吞掉——后者重装排到链首同样是正解）。
          // 反向不成立的那半（光标没动 → 本就无事件）已被 cursor 比较排除，因此
          // 「用户只是没动鼠标」永远不会触发重装。
          UnhookWindowsHookEx(hook);
          hook = SetWindowsHookEx(WH_MOUSE_LL, &HookProc,
                                  GetModuleHandle(nullptr), 0);
          g_hook_active.store(hook != nullptr, std::memory_order_release);
        }
      }
      if (got_cursor) {
        last_cursor = cursor;
      }
      last_seen_tick = seen_tick;
    } else if (msg.message == kThreadDisarm) {
      // g_target 已由 Disarm 侧清空（回调此刻起纯放行）；这里只安排宽限期后的
      // 真正卸载。已有挂起定时器就沿用原先的到期时间。
      if (hook != nullptr && disarm_timer == 0) {
        disarm_timer = SetTimer(nullptr, 0, kDisarmGraceMs, nullptr);
      }
    } else if (msg.message == kThreadReconcileAttached) {
      // A live attached down needs the same delayed physical-state fallback
      // even while its surface remains armed.  Scheduling this timer does not
      // clear g_target or disarm the hook; it only reuses the established 3s
      // reconciliation path if the low-level up is lost.
      if (hook != nullptr && disarm_timer == 0) {
        disarm_timer = SetTimer(nullptr, 0, kDisarmGraceMs, nullptr);
      }
    } else if (msg.message == kThreadBarrier) {
      // PostThreadMessage is serialized with HookProc on this installing
      // thread.  Reaching this message proves every callback that could have
      // snapshotted the previous direct HWND has returned.
      const uint32_t generation = static_cast<uint32_t>(msg.wParam);
      if (generation != 0 && g_arm_applied_event != nullptr) {
        g_arm_applied_generation.store(generation,
                                       std::memory_order_release);
        SetEvent(g_arm_applied_event);
      }
      const HWND finalize_target = reinterpret_cast<HWND>(msg.lParam);
      if (finalize_target != nullptr && IsWindow(finalize_target)) {
        // Also queue the UI-thread finalizer after the barrier.  Normally the
        // waiting Disarm path has already revoked synchronously; if that wait
        // timed out, this delayed message prevents a hidden live HWND from
        // retaining the game property indefinitely.
        PostMessage(finalize_target, kLowLevelMouseShieldReleaseMessage, 0, 0);
      }
    } else if (msg.message == WM_TIMER && disarm_timer != 0 &&
               msg.wParam == disarm_timer) {
      KillTimer(nullptr, disarm_timer);
      disarm_timer = 0;
      // 被吞的 down 可能被用户长按超过宽限期。此时绝不能卸钩：窗口早已
      // Hide/Disarm，但游戏仍可能在稍后的 button-up 推进台词。保留钩子并
      // 重新排一次检查；up 会在 HookProc 的 g_target 闸门之前清掉对应位。
      const uint32_t still_held =
          ReconcileSwallowedButtonsWithPhysicalState();
      const uint32_t shield_still_held =
          ReconcileDirectInputShieldButtonsWithPhysicalState();
      const bool attached_still_held =
          ReconcileAttachedGlyphTransactionWithPhysicalState();
      if (still_held != 0 || shield_still_held != 0 ||
          attached_still_held) {
        disarm_timer = SetTimer(nullptr, 0, kDisarmGraceMs, nullptr);
        continue;
      }
      // 宽限期内没有新的 Arm（有的话定时器早被杀掉）——真正闲置，卸钩子。
      // 再核一次 g_target 防御 Arm 消息尚在队列里的窗口期。
      if (hook != nullptr &&
          g_target.load(std::memory_order_relaxed) == nullptr) {
        UnhookWindowsHookEx(hook);
        hook = nullptr;
        g_hook_active.store(false, std::memory_order_release);
        // 所有配对 up 都已收齐后才会走到这里。清零是防御式收尾，避免未来
        // 新增按钮位时遗漏某条释放路径。
        g_swallowed_buttons.store(0, std::memory_order_relaxed);
      }
    }
  }
  if (liveness_timer != 0) {
    KillTimer(nullptr, liveness_timer);
  }
  if (hook != nullptr) {
    UnhookWindowsHookEx(hook);
  }
  g_hook_active.store(false, std::memory_order_release);
}

// 返回钩子线程 id（必要时懒创建并等它把 id 发布出来）。0 表示创建失败。
DWORD EnsureHookThread() {
  const DWORD existing = g_thread_id.load(std::memory_order_acquire);
  if (existing != 0) return existing;
  std::lock_guard<std::mutex> guard(g_thread_mutex);
  const DWORD after_lock = g_thread_id.load(std::memory_order_acquire);
  if (after_lock != 0) return after_lock;
  // BUG-1077 — 等待 id 发布用事件而不是逐毫秒睡眠自旋：这里跑在 platform 线程上，
  // 毫秒级睡眠在默认定时器精度下单次可睡 ~15ms，首次查词会白白卡 UI。事件在线程
  // 建好消息队列、发布 id 之后立即置位，实测微秒级；2s 上限只防线程创建失败。
  if (g_thread_ready == nullptr) {
    g_thread_ready = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (g_thread_ready == nullptr) return 0;
  }
  if (g_arm_applied_event == nullptr) {
    g_arm_applied_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (g_arm_applied_event == nullptr) return 0;
  }
  std::thread(&HookThreadMain).detach();
  if (WaitForSingleObject(g_thread_ready, 2000) != WAIT_OBJECT_0) {
    return 0;
  }
  return g_thread_id.load(std::memory_order_acquire);
}

// 屏障有三种结局，绝不能折成一个 bool。撤销跨进程属性的判据问的是「现在能不能
// 由我来收尾」，而这取决于「钩子线程队列里到底有没有那条会自己收尾的消息」：
//   kCrossed       —— 屏障已跨过，能截到旧 HWND 的回调全部已返回，此处同步撤销。
//   kQueuedPending —— 消息已投递、只是同步等待超时。它最终会被处理，并在处理时
//                     PostMessage 一条延迟收尾；此处**不能**抢着撤销，否则与仍在
//                     飞的回调竞争。
//   kNotQueued     —— 消息根本没投出去（没有钩子线程 / PostThreadMessage 失败）。
//                     不会有任何延迟收尾。旧实现把它和超时一样返回 false，于是
//                     游戏窗口上的 kSgreDirectInputShieldWindowProperty 永久留着，
//                     游戏的 DirectInput 立即状态被一直压制——这是死态，不是竞态。
enum class HookThreadBarrierResult {
  kCrossed,
  kQueuedPending,
  kNotQueued,
};

HookThreadBarrierResult WaitForHookThreadBarrier(DWORD thread_id,
                                                 HWND finalize_target) {
  if (thread_id == 0 || g_arm_applied_event == nullptr) {
    return HookThreadBarrierResult::kNotQueued;
  }
  ResetEvent(g_arm_applied_event);
  const uint32_t generation =
      g_arm_requested_generation.fetch_add(1, std::memory_order_acq_rel) + 1;
  if (!PostThreadMessage(thread_id, kThreadBarrier, generation,
                         reinterpret_cast<LPARAM>(finalize_target))) {
    return HookThreadBarrierResult::kNotQueued;
  }
  const ULONGLONG deadline = GetTickCount64() + kArmAckTimeoutMs;
  while (g_arm_applied_generation.load(std::memory_order_acquire) !=
         generation) {
    ResetEvent(g_arm_applied_event);
    if (g_arm_applied_generation.load(std::memory_order_acquire) == generation) {
      break;
    }
    const ULONGLONG now = GetTickCount64();
    if (now >= deadline) return HookThreadBarrierResult::kQueuedPending;
    if (WaitForSingleObject(g_arm_applied_event,
                            static_cast<DWORD>(deadline - now)) !=
        WAIT_OBJECT_0) {
      return HookThreadBarrierResult::kQueuedPending;
    }
  }
  return HookThreadBarrierResult::kCrossed;
}

}  // namespace

WPARAM PackMouseHookPoint(int x, int y) {
  return (static_cast<WPARAM>(static_cast<uint32_t>(x)) << 32) |
         static_cast<WPARAM>(static_cast<uint32_t>(y));
}

POINT UnpackMouseHookPoint(WPARAM wparam) {
  POINT pt{};
  pt.x = static_cast<LONG>(static_cast<int32_t>(
      static_cast<uint32_t>((wparam >> 32) & 0xFFFFFFFFull)));
  pt.y = static_cast<LONG>(
      static_cast<int32_t>(static_cast<uint32_t>(wparam & 0xFFFFFFFFull)));
  return pt;
}

// 滚轮载荷位布局（LPARAM 在 x64 下 64 位）：
//   [15:0]  MK_* 修饰键位（仅供原生快路）
//   [31:16] 有符号 delta
//   [32]    水平滚轮标志
//   [33]    物理 Ctrl（分流判据）
//   [34]    物理 Alt（分流判据；WM_MOUSEWHEEL 没有 MK_ALT，只能走这里）
LPARAM PackMouseHookWheel(const MouseHookWheel& wheel) {
  return static_cast<LPARAM>(
      (static_cast<uint64_t>(wheel.alt ? 1u : 0u) << 34) |
      (static_cast<uint64_t>(wheel.ctrl ? 1u : 0u) << 33) |
      (static_cast<uint64_t>(wheel.horizontal ? 1u : 0u) << 32) |
      (static_cast<uint64_t>(static_cast<uint16_t>(
           static_cast<int16_t>(wheel.delta)))
       << 16) |
      static_cast<uint64_t>(wheel.keys & 0xFFFFu));
}

MouseHookWheel UnpackMouseHookWheel(LPARAM lparam) {
  const auto raw = static_cast<uint64_t>(lparam);
  MouseHookWheel wheel;
  wheel.keys = static_cast<UINT>(raw & 0xFFFFull);
  wheel.delta =
      static_cast<int>(static_cast<int16_t>((raw >> 16) & 0xFFFFull));
  wheel.horizontal = ((raw >> 32) & 0x1ull) != 0;
  wheel.ctrl = ((raw >> 33) & 0x1ull) != 0;
  wheel.alt = ((raw >> 34) & 0x1ull) != 0;
  return wheel;
}

void ArmLowLevelMouseHook(HWND target) {
  if (target == nullptr) {
    return;
  }
  const DWORD thread_id = EnsureHookThread();
  if (thread_id == 0) return;
  std::lock_guard<std::mutex> guard(g_binding_mutex);
  // The desktop/global popup HWND may have carried a consume-owner property
  // for one attached-surface lookup (GlobalLookupWindow::
  // SetOutsideClickConsumeOwner); DisarmLowLevelMouseHook removed it behind
  // the target clear, so this async Arm never inherits it. Do not mutate
  // properties here: async Arm has no callback barrier.
  g_attached_risky_target.store(nullptr, std::memory_order_release);
  g_target.store(target, std::memory_order_release);
  PostThreadMessage(thread_id, kThreadArm, 0, 0);
}

uint32_t UpdateLowLevelAttachedGlyphHitRegions(
    HWND surface, HWND game_owner, const RECT* screen_rects,
    size_t screen_rect_count, bool allow_risk) {
  constexpr size_t kMaximumAttachedGlyphRects = 4096;
  if (surface == nullptr || game_owner == nullptr || screen_rects == nullptr ||
      screen_rect_count == 0 ||
      screen_rect_count > kMaximumAttachedGlyphRects) {
    return 0;
  }
  // Start the acknowledgement worker before the snapshot becomes reachable
  // from WH_MOUSE_LL. Its callback wake-up path can then remain lock-free.
  EnsureAttachedGlyphReleaseWorker();
  auto snapshot = std::make_shared<AttachedGlyphHitSnapshot>();
  snapshot->surface = surface;
  snapshot->game_owner = game_owner;
  snapshot->allow_risk = allow_risk;
  snapshot->screen_rects.reserve(screen_rect_count);
  for (size_t index = 0; index < screen_rect_count; ++index) {
    const RECT rect = screen_rects[index];
    if (rect.right <= rect.left || rect.bottom <= rect.top) return 0;
    snapshot->screen_rects.push_back(rect);
  }
  uint32_t token =
      g_attached_hit_token.fetch_add(1, std::memory_order_acq_rel) + 1u;
  if (token == 0) {
    token =
        g_attached_hit_token.fetch_add(1, std::memory_order_acq_rel) + 1u;
  }
  snapshot->token = token;
  std::shared_ptr<const AttachedGlyphHitSnapshot> immutable = snapshot;
  std::atomic_store_explicit(&g_attached_hit_snapshot, std::move(immutable),
                             std::memory_order_release);
  return token;
}

void ClearLowLevelAttachedGlyphHitRegions(HWND surface) {
  if (surface == nullptr) return;
  auto snapshot = std::atomic_load_explicit(
      &g_attached_hit_snapshot, std::memory_order_acquire);
  while (snapshot != nullptr && snapshot->surface == surface) {
    std::shared_ptr<const AttachedGlyphHitSnapshot> empty;
    if (std::atomic_compare_exchange_weak_explicit(
            &g_attached_hit_snapshot, &snapshot, empty,
            std::memory_order_acq_rel, std::memory_order_acquire)) {
      break;
    }
  }
  AcquireSRWLockExclusive(&g_attached_transaction_lock);
  if (g_attached_active_transaction.latch.active() &&
      g_attached_active_transaction.snapshot != nullptr &&
      g_attached_active_transaction.snapshot->surface == surface) {
    // Geometry/epoch cancellation is not a physical button-up.  Retain the
    // exact transaction (and its snapshot metadata) until HookProc observes the
    // paired WM_LBUTTONUP; only then may v19 release the sampled-input tail.
    g_attached_active_transaction.latch.Cancel();
  }
  ReleaseSRWLockExclusive(&g_attached_transaction_lock);
}

namespace {

bool AttachedBindingHealthy(HWND target, HWND game_owner,
                            bool allow_sampled_risk) {
  if (g_target.load(std::memory_order_acquire) != target ||
      !g_hook_active.load(std::memory_order_acquire)) {
    return false;
  }
  bool any_declared = false;
  const SampledInputShieldContract* selected =
      SelectSampledInputShieldContract(game_owner, &any_declared);
  if (g_attached_risky_target.load(std::memory_order_acquire) == target) {
    // Stay risky while exact coverage remains unavailable. If it recovers (or
    // is no longer required), force one clean re-arm so state can upgrade.
    return allow_sampled_risk && any_declared &&
           !IsSelectedSampledInputShieldContractReady(game_owner, selected);
  }
  if (!any_declared) return true;
  return selected != nullptr &&
         IsSelectedSampledInputShieldContractReady(game_owner, selected) &&
         g_direct_input_shield_game.load(std::memory_order_acquire) ==
             game_owner &&
         g_direct_input_shield_popup.load(std::memory_order_acquire) == target &&
         g_direct_input_shield_contract.load(std::memory_order_acquire) ==
             selected &&
         reinterpret_cast<HWND>(
             GetPropW(game_owner, selected->window_property)) == target;
}

bool AttachedArmHasConflictingTransaction() {
  if (g_swallowed_buttons.load(std::memory_order_acquire) != 0 ||
      g_direct_input_shield_buttons.load(std::memory_order_acquire) != 0 ||
      g_direct_input_shield_tail_token.load(std::memory_order_acquire) != 0 ||
      HasActiveAttachedGlyphTransaction()) {
    return true;
  }
  const VoiceHookLookupShieldStatus status =
      VoiceHookReader::Instance().LookupShieldStatus();
  return !status.ok() || status.active_buttons != 0 ||
         (status.request_seq != 0 && status.request_seq != status.applied_seq);
}

// BUG-2140：attached 表面抢不到低层鼠标单例时，对外只有一条
// `low_level_mouse_singleton_busy_or_unavailable`，而这一路上有五个互不相干的
// 闸门（命中快照缺失 / owner 不符 / 注入侧 shield 目标没准备好 / 单例被别的
// HWND 占着 / 有未结清的事务）。真机上「第一次查词成功、之后每次点击都穿透」
// 就卡在其中一条，靠一条泛化消息完全分不出是哪条。逐条记原因，只加量具。
std::atomic<const char *> g_attached_arm_failure{nullptr};

namespace {
bool AttachedArmFail(const char *reason) {
  g_attached_arm_failure.store(reason, std::memory_order_release);
  return false;
}
}  // namespace

bool ArmLowLevelMouseHookWithSampledShield(HWND target, HWND game_owner,
                                           bool target_only,
                                           bool allow_sampled_risk,
                                           bool idle_only) {
  if (target == nullptr || game_owner == nullptr) return false;
  if (idle_only &&
      !VoiceHookReader::Instance().PrepareLookupShieldTarget(game_owner)) {
    return AttachedArmFail("injected_shield_target_not_prepared");
  }
  const DWORD thread_id = EnsureHookThread();
  if (thread_id == 0 || g_arm_applied_event == nullptr) {
    return idle_only ? AttachedArmFail("hook_thread_unavailable") : false;
  }

  std::lock_guard<std::mutex> guard(g_binding_mutex);
  const HWND current = g_target.load(std::memory_order_acquire);
  if (idle_only && current != nullptr && current != target) {
    // Attached is the lower-priority transparent surface. Never clear or
    // mutate the desktop/global popup's singleton binding.
    return AttachedArmFail("singleton_owned_by_other_hwnd");
  }
  if (idle_only && current == target &&
      AttachedBindingHealthy(target, game_owner, allow_sampled_risk)) {
    return true;
  }
  if (idle_only && AttachedArmHasConflictingTransaction()) {
    return AttachedArmFail("conflicting_transaction_pending");
  }
  // Keep the already-created off-screen renderer non-consuming while the hook
  // thread installs/acknowledges HHOOK. Only after that succeeds do we publish
  // the direct target; Reveal moves it on-screen immediately after this returns.
  g_target.store(nullptr, std::memory_order_release);
  g_attached_risky_target.store(nullptr, std::memory_order_release);

  ResetEvent(g_arm_applied_event);
  const uint32_t generation =
      g_arm_requested_generation.fetch_add(1, std::memory_order_acq_rel) + 1;
  if (!PostThreadMessage(thread_id, kThreadArm, generation, 0)) return false;

  const ULONGLONG deadline = GetTickCount64() + kArmAckTimeoutMs;
  while (g_arm_applied_generation.load(std::memory_order_acquire) !=
         generation) {
    ResetEvent(g_arm_applied_event);
    if (g_arm_applied_generation.load(std::memory_order_acquire) == generation) {
      break;
    }
    const ULONGLONG now = GetTickCount64();
    if (now >= deadline) return false;
    const DWORD remaining = static_cast<DWORD>(deadline - now);
    if (WaitForSingleObject(g_arm_applied_event, remaining) != WAIT_OBJECT_0) {
      return false;
    }
  }
  if (!g_hook_active.load(std::memory_order_acquire)) return false;
  // The ack is also a hook-thread barrier: every callback that could have read
  // the old target has completed, while newer callbacks see target == nullptr.
  // It is now safe to replace this dedicated HWND's game binding.
  AbortInvalidDirectInputShieldAfterBarrier();
  RemovePropW(target, kConsumeOutsideOwnerProperty);
  RemovePropW(target, kSampledShieldOwnerProperty);
  RemovePropW(target, kSampledShieldTargetOnlyProperty);
  if (!target_only &&
      !SetPropW(target, kConsumeOutsideOwnerProperty,
                reinterpret_cast<HANDLE>(game_owner))) {
    return false;
  }
  if (!SetPropW(target, kSampledShieldOwnerProperty,
                reinterpret_cast<HANDLE>(game_owner))) {
    RemovePropW(target, kConsumeOutsideOwnerProperty);
    return false;
  }
  if (target_only &&
      !SetPropW(target, kSampledShieldTargetOnlyProperty,
                reinterpret_cast<HANDLE>(kSampledShieldTargetOnlyValue))) {
    RemovePropW(target, kSampledShieldOwnerProperty);
    return false;
  }
  const SampledShieldPublishResult sampled =
      PublishDirectInputShieldIfReady(target, game_owner);
  bool risk_fallback = false;
  if (sampled == SampledShieldPublishResult::kUnavailable && target_only &&
      allow_sampled_risk && !AttachedArmHasConflictingTransaction()) {
    // Exact sampled-input coverage is unavailable, but the user explicitly
    // accepted the HHOOK+v19 partial route and no other owner/transaction is
    // live. This must remain visibly risky, never verified.
    risk_fallback = true;
  } else if (sampled == SampledShieldPublishResult::kUnavailable ||
             sampled == SampledShieldPublishResult::kBusy) {
    RemovePropW(target, kSampledShieldTargetOnlyProperty);
    RemovePropW(target, kSampledShieldOwnerProperty);
    RemovePropW(target, kConsumeOutsideOwnerProperty);
    return false;
  }
  g_attached_risky_target.store(risk_fallback ? target : nullptr,
                                std::memory_order_release);
  g_target.store(target, std::memory_order_release);
  return true;
}

}  // namespace

bool ArmLowLevelMouseHookAndWait(HWND target, HWND consume_outside_owner) {
  return ArmLowLevelMouseHookWithSampledShield(
      target, consume_outside_owner, false, false, false);
}

// BUG-2140：判断 |candidate| 是否就是**本进程**为 |game_owner| 打开的那张查词卡。
// 依据是 SetOutsideClickConsumeOwner 落在卡片 HWND 上的 owner 属性——已有的身份
// 链，不是「同 PID」这种弱判据。
bool IsLookupCardConsumingForOwner(HWND candidate, HWND game_owner) {
  if (candidate == nullptr || game_owner == nullptr) return false;
  DWORD pid = 0;
  GetWindowThreadProcessId(candidate, &pid);
  if (pid != GetCurrentProcessId()) return false;
  return reinterpret_cast<HWND>(
             GetPropW(candidate, kConsumeOutsideOwnerProperty)) == game_owner;
}

const char *LastAttachedGlyphArmFailure() {
  return g_attached_arm_failure.load(std::memory_order_acquire);
}

bool ArmLowLevelMouseHookForAttachedGlyph(HWND target, HWND game_owner) {
  const auto snapshot = AttachedGlyphSnapshotForTarget(target);
  if (snapshot == nullptr) return AttachedArmFail("hit_snapshot_missing");
  if (snapshot->game_owner != game_owner) {
    return AttachedArmFail("hit_snapshot_owner_mismatch");
  }
  const bool armed = ArmLowLevelMouseHookWithSampledShield(
      target, game_owner, true, snapshot->allow_risk, true);
  if (armed) {
    g_attached_arm_failure.store(nullptr, std::memory_order_release);
  }
  return armed;
}

bool LowLevelAttachedGlyphUsesRiskFallback(HWND target) {
  return target != nullptr &&
         g_target.load(std::memory_order_acquire) == target &&
         g_attached_risky_target.load(std::memory_order_acquire) == target;
}

void FinalizeLowLevelMouseDirectInputShield(HWND target) {
  if (target == nullptr) return;
  std::lock_guard<std::mutex> guard(g_binding_mutex);
  RevokeDirectInputShieldIfIdle(target);
}

void DisarmLowLevelMouseHook(HWND expected_target) {
  if (expected_target == nullptr) return;
  ClearLowLevelAttachedGlyphHitRegions(expected_target);
  std::lock_guard<std::mutex> guard(g_binding_mutex);
  const HWND current = g_target.load(std::memory_order_acquire);
  const bool owns_binding = current == expected_target;
  const bool clean_uncommitted_arm = current == nullptr;
  if (owns_binding) {
    g_target.store(nullptr, std::memory_order_release);
  }
  // The consume-owner property lives on |expected_target| itself and is read
  // by HookProc only while that HWND is the published target. Removing it
  // after the target clear is safe: a callback that already snapshotted the
  // target either sees the owner (the popup was still on-screen for that
  // click) or nullptr (pass-through); the paired-up swallow is carried by
  // g_swallowed_buttons, never by this property. Removing it here is what
  // keeps the same desktop popup HWND from consuming game clicks on a later
  // lookup that never set an owner (attached-surface lookups set it per reveal,
  // the plain async Arm never touches properties).
  RemovePropW(expected_target, kConsumeOutsideOwnerProperty);
  HWND risky_target = expected_target;
  g_attached_risky_target.compare_exchange_strong(
      risky_target, nullptr, std::memory_order_acq_rel,
      std::memory_order_acquire);
  const DWORD thread_id = g_thread_id.load(std::memory_order_acquire);
  const bool owns_direct_publication =
      g_direct_input_shield_popup.load(std::memory_order_acquire) ==
      expected_target;
  // A callback can snapshot target immediately before the exchange above and
  // set the held-button bit after the UI thread reaches this function.  Do not
  // remove the cross-process property until the installing thread has crossed
  // a callback barrier.  If the synchronous wait times out, the queued barrier
  // itself posts a delayed popup-thread finalizer once it is eventually crossed.
  const HookThreadBarrierResult barrier =
      owns_direct_publication
          ? WaitForHookThreadBarrier(thread_id, expected_target)
          : HookThreadBarrierResult::kCrossed;
  // kNotQueued 时也必须撤销：没有任何东西被排队，等不到那条延迟收尾。此处并不是
  // 无保护地撤——RevokeDirectInputShieldIfIdle 自带 g_target / 按住键的闲置门控，
  // 那正是屏障之外的第二道防线。而 kQueuedPending 才是唯一「交给别人收尾」的分支。
  if (barrier != HookThreadBarrierResult::kQueuedPending) {
    if (barrier == HookThreadBarrierResult::kCrossed) {
      AbortInvalidDirectInputShieldAfterBarrier();
    }
    RevokeDirectInputShieldIfIdle(expected_target);
  }
  if ((owns_binding || clean_uncommitted_arm) && thread_id != 0) {
    PostThreadMessage(thread_id, kThreadDisarm, 0, 0);
  }
}

}  // namespace fushi
