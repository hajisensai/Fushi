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

ImeAssociationUpdate ImeAssociationGuard::SetEnabled(HWND hwnd, bool enable) {
  if (associate_ == nullptr) {
    return ImeAssociationUpdate::kFailed;
  }
  if (initialised_ && hwnd_ == hwnd && enabled_ == enable) {
    return ImeAssociationUpdate::kUnchanged;
  }
  if (!associate_(hwnd, enable, context_)) {
    return ImeAssociationUpdate::kFailed;
  }
  hwnd_ = hwnd;
  enabled_ = enable;
  initialised_ = true;
  return ImeAssociationUpdate::kApplied;
}
