// 反馈 4c0IeCpSjb：游戏内查词卡在屏时键盘不进游戏，Ctrl+C 仍能复制卡里的选区。
// 纯状态机测试（lookup_keyboard_shield.h），与 WH_KEYBOARD_LL 回调共用同一份判据。
#undef NDEBUG

#include <cassert>
#include <cstdint>

#include "../lookup_keyboard_shield.h"

namespace {

using fushi::lookup_keyboard_shield::Action;
using fushi::lookup_keyboard_shield::KeyboardShieldLatch;
namespace k = fushi::lookup_keyboard_shield;

constexpr uint32_t kVkReturn = 0x0D;
constexpr uint32_t kVkSpace = 0x20;

Action Down(KeyboardShieldLatch& latch, uint32_t vk, bool shield,
            bool down_in_system = false, bool ctrl_in_system = false,
            bool system_combo = false) {
  return latch.OnKey(vk, false, shield, down_in_system, ctrl_in_system,
                     system_combo);
}

// Alt / Win 按住时的新按下（钩子按 LLKHF_ALTDOWN / Win 键态传 system_combo=true）。
Action ComboDown(KeyboardShieldLatch& latch, uint32_t vk, bool shield) {
  return Down(latch, vk, shield, false, false, true);
}

Action Up(KeyboardShieldLatch& latch, uint32_t vk, bool shield) {
  return latch.OnKey(vk, true, shield, true, false, false);
}

}  // namespace

int main() {
  // 卡在屏：Ctrl 被吞（游戏看不到 Ctrl 就不会快进），C 被吞并请求复制，
  // 自动重复不重复复制，配对 up 全部吞掉。
  {
    KeyboardShieldLatch latch;
    assert(Down(latch, k::kVkLControl, true) == Action::kSwallow);
    assert(latch.ControlSwallowed());
    // Ctrl 的自动重复：系统键态里它不是按下（被吞了），仍按已吞键继续吞。
    assert(Down(latch, k::kVkLControl, true) == Action::kSwallow);
    assert(Down(latch, k::kVkC, true) == Action::kSwallowAndCopy);
    assert(Down(latch, k::kVkC, true) == Action::kSwallow);
    assert(Up(latch, k::kVkC, true) == Action::kSwallow);
    assert(Up(latch, k::kVkLControl, true) == Action::kSwallow);
    assert(!latch.AnySwallowed());
  }

  // 卡片出现前就按住的 Ctrl（系统里已按下）：它的重复与 up 放行，绝不制造卡键；
  // 期间按 C 仍被吞并复制。
  {
    KeyboardShieldLatch latch;
    assert(Down(latch, k::kVkRControl, true, true) == Action::kPass);
    assert(Down(latch, k::kVkC, true, false, true) == Action::kSwallowAndCopy);
    assert(Up(latch, k::kVkC, true) == Action::kSwallow);
    assert(Up(latch, k::kVkRControl, true) == Action::kPass);
  }

  // 卡片中途关闭：按下时被吞的键，关闭后的重复与 up 照样吞（游戏从头到尾看不到）。
  {
    KeyboardShieldLatch latch;
    assert(Down(latch, kVkReturn, true) == Action::kSwallow);
    assert(Down(latch, kVkReturn, false) == Action::kSwallow);
    assert(Up(latch, kVkReturn, false) == Action::kSwallow);
    // 之后的新按下与卡片无关，放行。
    assert(Down(latch, kVkReturn, false) == Action::kPass);
    assert(Up(latch, kVkReturn, false) == Action::kPass);
  }

  // 卡片不在屏：什么都不吞，Ctrl+C 也不由宿主复制。
  {
    KeyboardShieldLatch latch;
    assert(Down(latch, k::kVkLControl, false) == Action::kPass);
    assert(Down(latch, k::kVkC, false, false, true) == Action::kPass);
    assert(Up(latch, k::kVkC, false) == Action::kPass);
    assert(Up(latch, k::kVkLControl, false) == Action::kPass);
  }

  // 卡在屏时放行前先按下的键（卡片出现后自动重复）照常放行。
  {
    KeyboardShieldLatch latch;
    assert(Down(latch, kVkSpace, false) == Action::kPass);
    assert(Down(latch, kVkSpace, true, true) == Action::kPass);
    assert(Up(latch, kVkSpace, true) == Action::kPass);
  }

  // Alt / Win / Shift 永远放行：Alt+Tab、Win 键属于系统，Shift 是悬停查词修饰键。
  {
    KeyboardShieldLatch latch;
    assert(Down(latch, k::kVkLMenu, true) == Action::kPass);
    assert(Down(latch, k::kVkLWin, true) == Action::kPass);
    assert(Down(latch, k::kVkLShift, true) == Action::kPass);
    assert(Down(latch, k::kVkShift, true) == Action::kPass);
    assert(!latch.AnySwallowed());
  }

  // Alt / Win 按住时的新按下属于系统：Alt+F4、Alt+Tab、Win+D 整组放行，不记位。
  {
    KeyboardShieldLatch latch;
    constexpr uint32_t kVkTab = 0x09;
    constexpr uint32_t kVkF4 = 0x73;
    constexpr uint32_t kVkD = 0x44;
    // Alt+F4
    assert(Down(latch, k::kVkLMenu, true) == Action::kPass);
    assert(ComboDown(latch, kVkF4, true) == Action::kPass);
    assert(Up(latch, kVkF4, true) == Action::kPass);
    assert(Up(latch, k::kVkLMenu, true) == Action::kPass);
    // Alt+Tab（含按住 Alt 连按 Tab）
    assert(Down(latch, k::kVkRMenu, true) == Action::kPass);
    assert(ComboDown(latch, kVkTab, true) == Action::kPass);
    assert(Up(latch, kVkTab, true) == Action::kPass);
    assert(ComboDown(latch, kVkTab, true) == Action::kPass);
    assert(Up(latch, kVkTab, true) == Action::kPass);
    assert(Up(latch, k::kVkRMenu, true) == Action::kPass);
    // Win+D
    assert(Down(latch, k::kVkLWin, true) == Action::kPass);
    assert(ComboDown(latch, kVkD, true) == Action::kPass);
    assert(Up(latch, kVkD, true) == Action::kPass);
    assert(Up(latch, k::kVkLWin, true) == Action::kPass);
    assert(!latch.AnySwallowed());
    // 同一批键不带 Alt / Win 时仍按普通键吞（护盾本身没被放宽）。
    assert(Down(latch, kVkF4, true) == Action::kSwallow);
    assert(Down(latch, kVkTab, true) == Action::kSwallow);
    assert(Down(latch, kVkD, true) == Action::kSwallow);
    assert(Up(latch, kVkF4, true) == Action::kSwallow);
    assert(Up(latch, kVkTab, true) == Action::kSwallow);
    assert(Up(latch, kVkD, true) == Action::kSwallow);
    assert(!latch.AnySwallowed());
  }

  // 已被吞住的键在 Alt 后按下时的自动重复仍吞（down/up 对游戏保持成对不可见）。
  {
    KeyboardShieldLatch latch;
    assert(Down(latch, kVkReturn, true) == Action::kSwallow);
    assert(ComboDown(latch, kVkReturn, true) == Action::kSwallow);
    assert(Up(latch, kVkReturn, true) == Action::kSwallow);
    assert(!latch.AnySwallowed());
  }

  // 音量 / 媒体 / 浏览器 / 启动键（VK 0xA6–0xB7）永远放行；边界外的 0xB8 仍被吞。
  {
    KeyboardShieldLatch latch;
    constexpr uint32_t kVkVolumeMute = 0xAD;
    constexpr uint32_t kVkVolumeDown = 0xAE;
    constexpr uint32_t kVkVolumeUp = 0xAF;
    constexpr uint32_t kVkMediaPlayPause = 0xB3;
    assert(Down(latch, kVkVolumeMute, true) == Action::kPass);
    assert(Down(latch, kVkVolumeDown, true) == Action::kPass);
    assert(Down(latch, kVkVolumeUp, true) == Action::kPass);
    assert(Down(latch, kVkMediaPlayPause, true) == Action::kPass);
    for (uint32_t vk = 0xA6; vk <= 0xB7; ++vk) {
      assert(Down(latch, vk, true) == Action::kPass);
      assert(Up(latch, vk, true) == Action::kPass);
    }
    assert(!latch.AnySwallowed());
    assert(Down(latch, 0xB8, true) == Action::kSwallow);
    assert(Up(latch, 0xB8, true) == Action::kSwallow);
  }

  // 普通键在卡在屏时照旧被挡（回归：系统组合键放行不得放宽普通键）。
  {
    KeyboardShieldLatch latch;
    assert(Down(latch, kVkSpace, true) == Action::kSwallow);
    assert(Down(latch, kVkReturn, true) == Action::kSwallow);
    assert(Up(latch, kVkSpace, true) == Action::kSwallow);
    assert(Up(latch, kVkReturn, true) == Action::kSwallow);
    assert(!latch.AnySwallowed());
  }

  // 被吞的组合其实是全局热键：交还 Ctrl 与该键，之后的 up 放行（不再算被吞）。
  {
    KeyboardShieldLatch latch;
    constexpr uint32_t kVkX = 0x58;
    assert(Down(latch, k::kVkLControl, true) == Action::kSwallow);
    assert(Down(latch, kVkX, true) == Action::kSwallow);
    uint32_t controls[3] = {};
    assert(latch.ReleaseForHotkey(kVkX, controls) == 1);
    assert(controls[0] == k::kVkLControl);
    assert(!latch.AnySwallowed());
    assert(Up(latch, kVkX, true) == Action::kPass);
    assert(Up(latch, k::kVkLControl, true) == Action::kPass);
    // 没有被吞的 Ctrl 时只交还键本身。
    assert(Down(latch, kVkX, true) == Action::kSwallow);
    assert(latch.ReleaseForHotkey(kVkX, controls) == 0);
    assert(!latch.AnySwallowed());
  }

  // 没有 Ctrl 的 C 只吞不复制；越界 vk 放行；Reset 清空。
  {
    KeyboardShieldLatch latch;
    assert(Down(latch, k::kVkC, true) == Action::kSwallow);
    assert(latch.OnKey(300, false, true, false, false, false) == Action::kPass);
    latch.Reset();
    assert(!latch.AnySwallowed());
    assert(Up(latch, k::kVkC, true) == Action::kPass);
  }
  return 0;
}
