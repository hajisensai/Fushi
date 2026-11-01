#ifndef RUNNER_LOOKUP_KEYBOARD_SHIELD_H_
#define RUNNER_LOOKUP_KEYBOARD_SHIELD_H_

// 反馈 4c0IeCpSjb — 游戏内查词卡在屏时，键盘不进游戏。
//
// 查词卡是 WS_EX_NOACTIVATE（design §5 保证 3：查词不动前台程序的键盘焦点），所以卡在
// 屏时键盘焦点仍在游戏上：按 Ctrl+C 想复制卡里的字，Ctrl 的 down 照样进游戏——消息型
// 引擎收到 WM_KEYDOWN(VK_CONTROL)，采样型引擎（GetAsyncKeyState / DirectInput /
// RawInput）读到 Ctrl 按下，多数 galgame 把 Ctrl 当「快进 / 跳过」。
//
// 修法在宿主的 WH_KEYBOARD_LL：被吞的键盘事件既不进任何线程的输入队列，也不更新系统的
// 异步键态，所以对游戏的**所有**读法（消息、GetAsyncKeyState/GetKeyState、RawInput、
// DirectInput）同时生效，不依赖逐引擎的注入侧过滤。复制改由宿主自己落地：吞掉的
// Ctrl+C 投一条消息给查词卡，卡片走与 RegisterHotKey 同一个原生复制出口
// （热键在 LL 钩子之后处理，吞了之后热键收不到）。
//
// 本文件是纯状态机（无 Win32 依赖），钩子回调与单测共用同一份判据。
//
// 规则：
//   * 只有「新按下」才会被吞：按下时系统已认为它处于按下态（卡片出现前就按住、或是
//     放行过的键在自动重复）一律放行，配对的 up 也放行——绝不让游戏看到一个没有 up
//     的 down（卡键）。
//   * 被吞的 down 记位，配对 up（以及其间的自动重复）同样吞掉；卡片中途关闭也照吞，
//     游戏从头到尾看不到这一次按键。
//   * 系统级修饰键 Alt / Win 永远放行（Alt+Tab、Win 键、Alt+F4 属于系统，不属于游戏）；
//     Shift 也放行：它是查词的悬停修饰键，吞掉会让卡内悬停查词失效。
//   * Ctrl+C（Ctrl 来自本状态机吞掉的 Ctrl，或系统里已经按住的 Ctrl）在吞掉 C 的同时
//     请求复制；自动重复不重复复制（对齐 RegisterHotKey 的 MOD_NOREPEAT）。

#include <atomic>
#include <cstdint>

namespace fushi {
namespace lookup_keyboard_shield {

constexpr uint32_t kVkShift = 0x10;
constexpr uint32_t kVkControl = 0x11;
constexpr uint32_t kVkMenu = 0x12;
constexpr uint32_t kVkC = 0x43;
constexpr uint32_t kVkLWin = 0x5B;
constexpr uint32_t kVkRWin = 0x5C;
constexpr uint32_t kVkLShift = 0xA0;
constexpr uint32_t kVkRShift = 0xA1;
constexpr uint32_t kVkLControl = 0xA2;
constexpr uint32_t kVkRControl = 0xA3;
constexpr uint32_t kVkLMenu = 0xA4;
constexpr uint32_t kVkRMenu = 0xA5;

enum class Action {
  kPass,
  kSwallow,
  kSwallowAndCopy,
};

inline bool IsAlwaysPassedKey(uint32_t vk) {
  switch (vk) {
    case kVkShift:
    case kVkLShift:
    case kVkRShift:
    case kVkMenu:
    case kVkLMenu:
    case kVkRMenu:
    case kVkLWin:
    case kVkRWin:
      return true;
    default:
      return false;
  }
}

class KeyboardShieldLatch {
 public:
  // |shield_active|: 绑定游戏的查词卡在屏且游戏是前台。
  // |down_in_system|: 回调此刻系统异步键态里该键已是按下（LL 回调先于系统更新键态，
  //   所以一次真正的新按下这里是 false；自动重复 / 卡片出现前就按住的键是 true）。
  // |ctrl_down_in_system|: 同口径的 Ctrl 键态（被本状态机吞掉的 Ctrl 系统看不到，
  //   单独从 Swallowed 位读）。
  Action OnKey(uint32_t vk, bool up, bool shield_active, bool down_in_system,
               bool ctrl_down_in_system) {
    if (vk >= 256u) return Action::kPass;
    if (up) {
      return Clear(vk) ? Action::kSwallow : Action::kPass;
    }
    if (IsSwallowed(vk)) {
      // 被吞的键的自动重复：继续吞，保持 down/up 成对地对游戏不可见。
      return Action::kSwallow;
    }
    if (!shield_active || down_in_system || IsAlwaysPassedKey(vk)) {
      return Action::kPass;
    }
    Set(vk);
    const bool ctrl = ctrl_down_in_system || IsSwallowed(kVkControl) ||
                      IsSwallowed(kVkLControl) || IsSwallowed(kVkRControl);
    if (vk == kVkC && ctrl) return Action::kSwallowAndCopy;
    return Action::kSwallow;
  }

  bool IsSwallowed(uint32_t vk) const {
    if (vk >= 256u) return false;
    return (bits_[vk / 64u].load(std::memory_order_relaxed) &
            (uint64_t{1} << (vk % 64u))) != 0;
  }

  // Ctrl 是否处于「被吞住的按下」态（Ctrl+滚轮缩放等宿主侧修饰键判据要并上它）。
  bool ControlSwallowed() const {
    return IsSwallowed(kVkControl) || IsSwallowed(kVkLControl) ||
           IsSwallowed(kVkRControl);
  }

  bool AnySwallowed() const {
    for (const auto& word : bits_) {
      if (word.load(std::memory_order_relaxed) != 0) return true;
    }
    return false;
  }

  // 钩子卸载时调用：之后的 up 不会再经过本状态机。
  void Reset() {
    for (auto& word : bits_) word.store(0, std::memory_order_relaxed);
  }

 private:
  void Set(uint32_t vk) {
    bits_[vk / 64u].fetch_or(uint64_t{1} << (vk % 64u),
                             std::memory_order_relaxed);
  }
  bool Clear(uint32_t vk) {
    const uint64_t mask = uint64_t{1} << (vk % 64u);
    return (bits_[vk / 64u].fetch_and(~mask, std::memory_order_relaxed) &
            mask) != 0;
  }

  std::atomic<uint64_t> bits_[4] = {};
};

}  // namespace lookup_keyboard_shield
}  // namespace fushi

#endif  // RUNNER_LOOKUP_KEYBOARD_SHIELD_H_
