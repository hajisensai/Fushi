#include "ime_association_guard.h"

#include <imm.h>

bool ApplyImeAssociation(HWND hwnd, bool enable) {
  if (hwnd == nullptr) {
    return false;
  }
  // Passing a null HIMC with IACE_DEFAULT restores the thread's default input
  // context; with flags 0 it detaches the window from any input context, which
  // is what stops the IME from consuming keystrokes for this window.
  return ImmAssociateContextEx(hwnd, nullptr,
                               enable ? IACE_DEFAULT : 0) != FALSE;
}

bool ImeAssociationGuard::SetEnabled(HWND hwnd, bool enable) {
  if (associate_ == nullptr) {
    return false;
  }
  if (initialised_ && enabled_ == enable) {
    return false;
  }
  if (!associate_(hwnd, enable, context_)) {
    return false;
  }
  enabled_ = enable;
  initialised_ = true;
  return true;
}
