#ifndef RUNNER_IME_ASSOCIATION_GUARD_H_
#define RUNNER_IME_ASSOCIATION_GUARD_H_

#include <windows.h>

// BUG-1450: Flutter's Windows HWND keeps a live IME context for the whole
// lifetime of the window -- the engine never dissociates it when no text field
// holds focus. While a CJK IME is in a swallowing mode (Microsoft Pinyin in
// Chinese mode, MS-IME in kana mode) every keystroke is consumed by the IME and
// arrives as WM_KEYDOWN/wParam=VK_PROCESSKEY. The engine then reports it as a
// KeyEvent with physical/logical key 0 (see BUG-1427), so the whole shortcut
// table silently dies -- not just Space (BUG-1239 only patched that one key).
//
// The fix is to remove the special case instead of forwarding keys one by one:
// dissociate the IME context while nothing editable has focus, and associate it
// back the moment a text field takes focus. Dart owns focus knowledge and drives
// this through the app.hibiki/windows_ime_guard channel.
//
// Win32 contract (same one Chromium's InputMethodWinImm32 uses):
//   disable -> ImmAssociateContextEx(hwnd, nullptr, 0)
//   enable  -> ImmAssociateContextEx(hwnd, nullptr, IACE_DEFAULT)

// Performs the real Win32 association change. Returns false when the platform
// call fails; separated from the state machine so tests can drive the latter
// without a live HWND.
bool ApplyImeAssociation(HWND hwnd, bool enable);

using ImeAssociateFn = bool (*)(HWND hwnd, bool enable, void* context);

enum class ImeAssociationUpdate {
  kUnchanged,
  kApplied,
  kFailed,
};

// Tracks the association state so repeated identical requests (focus churn
// emits many notifications per frame) do not hammer Win32.
class ImeAssociationGuard {
 public:
  ImeAssociationGuard() = default;
  explicit ImeAssociationGuard(ImeAssociateFn fn, void* context = nullptr)
      : associate_(fn), context_(context) {}

  // Requests the IME association state. The HWND is part of the cached identity:
  // a recreated Flutter view must receive the current state even when `enable`
  // did not change. The first request is always applied too (after a Dart hot
  // restart the native window may already be dissociated).
  ImeAssociationUpdate SetEnabled(HWND hwnd, bool enable);

  bool enabled() const { return enabled_; }
  bool initialised() const { return initialised_; }

 private:
  ImeAssociateFn associate_ = nullptr;
  void* context_ = nullptr;
  // Flutter creates the window with the IME associated, so that is the state we
  // start from; `initialised_` forces the first request through regardless.
  bool enabled_ = true;
  bool initialised_ = false;
  HWND hwnd_ = nullptr;
};

#endif  // RUNNER_IME_ASSOCIATION_GUARD_H_
