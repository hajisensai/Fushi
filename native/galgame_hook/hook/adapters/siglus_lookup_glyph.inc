// Included in the injected adapter and the x86 ABI regression executable.
// The resolver/installer owns admission; neither callback guesses an ABI.

void CaptureSiglusLookupGlyph(void* self, uint8_t result,
                              uintptr_t return_address,
                              fushi_voice_hook::SiglusGlyphLayoutAbi abi) {
  if (result == 0 || self == nullptr ||
      !g_siglus_lookup_capture_enabled.load(std::memory_order_acquire)) return;
  const uintptr_t module = reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr));
  const auto* profile = ActiveSiglusLookupProfile();
  if (profile == nullptr || profile->glyph_abi != abi ||
      return_address < module ||
      return_address - module != profile->dialogue_glyph_return_rva) return;
  const size_t size = fushi_voice_hook::SiglusGlyphRecordBytes(abi);
  if (size == 0 || size > 0x48u) return;
  __try {
    uint8_t bytes[0x48] = {};
    memcpy(bytes, self, size);
    fushi_voice_hook::SiglusGlyphRecord glyph;
    if (fushi_voice_hook::DecodeSiglusGlyphRecord(
            abi, bytes, size, profile->viewport_width,
            profile->viewport_height, &glyph)) {
      PublishSiglusLookupGlyphEvent(glyph.code_unit, glyph.x, glyph.y,
                                    glyph.extent);
    }
  } __except (EXCEPTION_EXECUTE_HANDLER) {
  }
}

uint8_t __fastcall Detour_SiglusGlyphLayout(void* self, void*, uintptr_t arg1,
    uintptr_t arg2, uintptr_t arg3, uintptr_t arg4, uintptr_t arg5,
    uintptr_t arg6, uintptr_t arg7, uintptr_t arg8, uintptr_t arg9,
    uintptr_t arg10) {
  const uintptr_t caller = reinterpret_cast<uintptr_t>(_ReturnAddress());
  const auto original = g_orig_SiglusGlyphLayout;
  if (original == nullptr) return 0;
  const uint8_t result = original(self, arg1, arg2, arg3, arg4, arg5,
                                  arg6, arg7, arg8, arg9, arg10);
  CaptureSiglusLookupGlyph(self, result, caller,
      fushi_voice_hook::SiglusGlyphLayoutAbi::kEcxTenArguments);
  return result;
}

// Legacy glyph layout has sixteen DWORD stack slots including self, and
// returns AL with callee cleanup (ret 0x40). Do not pass self through ECX.
uint8_t __stdcall Detour_SiglusLegacyGlyphLayout(void* self, uintptr_t arg1,
    uintptr_t arg2, uintptr_t arg3, uintptr_t arg4, uintptr_t arg5,
    uintptr_t arg6, uintptr_t arg7, uintptr_t arg8, uintptr_t arg9,
    uintptr_t arg10, uintptr_t arg11, uintptr_t arg12, uintptr_t arg13,
    uintptr_t arg14, uintptr_t arg15) {
  const uintptr_t caller = reinterpret_cast<uintptr_t>(_ReturnAddress());
  const auto original = g_orig_SiglusLegacyGlyphLayout;
  if (original == nullptr) return 0;
  const uint8_t result = original(self, arg1, arg2, arg3, arg4, arg5,
      arg6, arg7, arg8, arg9, arg10, arg11, arg12, arg13, arg14, arg15);
  CaptureSiglusLookupGlyph(self, result, caller,
      fushi_voice_hook::SiglusGlyphLayoutAbi::kStackSixteenArguments);
  return result;
}
