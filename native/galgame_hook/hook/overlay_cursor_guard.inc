// BUG-2864 — 游戏光标不得盖过 Fushi 浮层的光标。判据与根因说明见 overlay_cursor_guard.h。
//
// 本文件被 include 进 dll_main.cpp 的匿名命名空间，放在 generic_input_shield.inc 之后：
// 复用它的 IsHookTargetTrackedByThisDll，与精确适配器的所有权规则一致——某个适配器若已
// 自己钩了 SetCursor，这里不抢它的 trampoline。这里一行 #include 都不能有（理由同
// lookup_overlay_window.inc 文件头）；overlay_cursor_guard.h 由 dll_main.cpp 在文件作用域引入。

using OverlayCursorGuardSetCursorFn = HCURSOR(WINAPI *)(HCURSOR);

OverlayCursorGuardSetCursorFn g_overlay_cursor_guard_set_cursor_original = nullptr;
bool g_overlay_cursor_guard_installed = false;

// 扣下时**不改**本线程的光标：返回值按 SetCursor 语义给出当前光标。引擎若按
// `GetCursor() != 目标` 才调 SetCursor，光标移回游戏画面后的下一帧就会再调一次并被放行，
// 不需要任何补发。
HCURSOR WINAPI OverlayCursorGuardSetCursorDetour(HCURSOR cursor) {
  const OverlayCursorGuardSetCursorFn original =
      g_overlay_cursor_guard_set_cursor_original;
  if (original == nullptr) return GetCursor();
  if (fushi_voice_hook::ShouldWithholdGameCursorNow()) {
    return GetCursor();
  }
  return original(cursor);
}

// 只在 MH_Initialize 成功后的工作线程上调用（HookFn 依赖 g_cs）；装成功一次即止。
void TryInstallOverlayCursorGuard() {
  if (g_overlay_cursor_guard_installed) return;
  HMODULE user32 = GetModuleHandleW(L"user32.dll");
  if (user32 == nullptr) return;
  void *target = reinterpret_cast<void *>(GetProcAddress(user32, "SetCursor"));
  if (target == nullptr) return;
  if (IsHookTargetTrackedByThisDll(target)) {
    // 别的 adapter 已占用该导出：不链未知 trampoline，也不再重试。
    g_overlay_cursor_guard_installed = true;
    return;
  }
  if (HookFn(target, reinterpret_cast<void *>(&OverlayCursorGuardSetCursorDetour),
             reinterpret_cast<void **>(
                 &g_overlay_cursor_guard_set_cursor_original)) &&
      g_overlay_cursor_guard_set_cursor_original != nullptr) {
    g_overlay_cursor_guard_installed = true;
  }
}
