// Only ABI transport lives here. Shared ownership policy runs once after the
// original sampled API, or before forwarding an unconsumed engine message.
SHORT WINAPI Detour_SiglusGetKeyState(int virtual_key) {
  const uintptr_t caller = reinterpret_cast<uintptr_t>(_ReturnAddress());
  const auto original = g_orig_SiglusGetKeyState;
  if (original == nullptr) return 0;
  const SHORT raw = original(virtual_key);
  return virtual_key == VK_LBUTTON
      ? FilterSiglusLookupLeftButtonSample(raw, caller, false) : raw;
}

BOOL WINAPI Detour_SiglusGetKeyboardState(PBYTE keys) {
  const uintptr_t caller = reinterpret_cast<uintptr_t>(_ReturnAddress());
  const auto original = g_orig_SiglusGetKeyboardState;
  if (original == nullptr) return FALSE;
  const BOOL result = original(keys);
  if (result == FALSE || keys == nullptr) return result;
  // Preserve the BOOL, all unrelated keys and every low/toggle bit. Only the
  // physical LB high bit participates in the existing sampled transaction.
  __try {
    const BYTE raw = keys[VK_LBUTTON];
    const SHORT filtered = FilterSiglusLookupLeftButtonSample(
        static_cast<SHORT>(static_cast<uint16_t>(raw) << 8), caller, true);
    keys[VK_LBUTTON] = static_cast<BYTE>(static_cast<uint16_t>(filtered) >> 8);
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    // The OS result is authoritative; a raced caller buffer is not an input.
  }
  return result;
}

void __stdcall Detour_SiglusInputMessage(UINT message, WPARAM wparam,
                                        LPARAM lparam) {
  const auto original = g_orig_SiglusInputMessage;
  if (original != nullptr && !ConsumeSiglusLookupInputMessage(
          message, lparam, reinterpret_cast<uintptr_t>(_ReturnAddress())))
    original(message, wparam, lparam);
}

void __fastcall Detour_SiglusLegacyInputMessage(LPARAM lparam, WPARAM wparam,
                                               UINT message) {
  const auto original = g_orig_SiglusLegacyInputMessage;
  if (original != nullptr && !ConsumeSiglusLookupInputMessage(
          message, lparam, reinterpret_cast<uintptr_t>(_ReturnAddress())))
    original(lparam, wparam, message);
}
