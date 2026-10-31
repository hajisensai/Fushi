// Included in the injected adapter and the x86 ABI regression executable.
// The resolver/installer owns admission; no callback guesses an ABI.

void CaptureSiglusLookupGlyph(void* self, uint8_t result,
                              uintptr_t return_address,
                              fushi_voice_hook::SiglusGlyphLayoutAbi abi) {
  if (self == nullptr ||
      !g_siglus_lookup_capture_enabled.load(std::memory_order_acquire)) return;
  const uintptr_t module = reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr));
  const auto* profile = ActiveSiglusLookupProfile();
  if (profile == nullptr || profile->glyph_abi != abi ||
      return_address < module) return;
  const uintptr_t caller = return_address - module;
  // Only the proved choice caller joins the dialogue caller; name plates and
  // every other text object stay out of the lookup line.
  const bool selection = profile->selection_glyph_return_rva != 0 &&
      caller == profile->selection_glyph_return_rva &&
      abi == fushi_voice_hook::SiglusGlyphLayoutAbi::kEcxTenArguments;
  if (!selection && caller != profile->dialogue_glyph_return_rva) return;
  const bool eightarg = abi == fushi_voice_hook::SiglusGlyphLayoutAbi::kEcxEightArguments;
  uint32_t ordinal = 0, count = 0;
  fushi_voice_hook::siglus_eightarg_owner::Vector vector;
  if (eightarg) {
    if (!ReadSiglusEightArgGlyphOrdinal(self, &ordinal, &count, &vector)) return;
  } else if (abi != fushi_voice_hook::SiglusGlyphLayoutAbi::kEcxTenArguments &&
             !IsSiglusLookupGlyphOwned(self)) return;
  if (result == 0) {
    // The admitted eight-argument wrapper stops at the first failed ordinal.
    // A partial pass cannot keep an older complete frame eligible for input.
    if (eightarg) PublishSiglusLookupGlyphInvalidation();
    return;
  }
  const size_t size = fushi_voice_hook::SiglusGlyphRecordBytes(abi);
  if (size == 0 || size > 0x70u) return;
  __try {
    uint8_t bytes[0x70] = {};
    memcpy(bytes, self, size);
    fushi_voice_hook::SiglusGlyphRecord glyph;
    if (fushi_voice_hook::DecodeSiglusGlyphRecord(
            abi, bytes, size, profile->viewport_width,
            profile->viewport_height, &glyph)) {
      if (eightarg) CaptureSiglusEightArgGlyphRecord(glyph, ordinal, count, vector);
      else PublishSiglusLookupGlyphEvent(glyph.code_unit, glyph.x, glyph.y,
                                         glyph.extent,
                                         selection ? kSiglusLookupGlyphEventSelection
                                                   : kSiglusLookupGlyphEventBody);
    } else if (abi == fushi_voice_hook::SiglusGlyphLayoutAbi::kEcxEightArguments) {
      PublishSiglusLookupGlyphInvalidation();
    }
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    if (abi == fushi_voice_hook::SiglusGlyphLayoutAbi::kEcxEightArguments)
      PublishSiglusLookupGlyphInvalidation();
  }
}

// The nine-argument record holds only a line-local offset, so its position is
// decoded with the walker's origin. Only the admitted dialogue walker joins
// the lookup line, and only for a glyph of the current owner walk.
void CaptureSiglusNineArgLookupGlyph(void* self, uint8_t result,
                                     uintptr_t return_address,
                                     int32_t origin_x, int32_t origin_y) {
  if (self == nullptr || result == 0 ||
      !g_siglus_lookup_capture_enabled.load(std::memory_order_acquire)) return;
  const uintptr_t module = reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr));
  const auto* profile = ActiveSiglusLookupProfile();
  if (profile == nullptr ||
      profile->glyph_abi != fushi_voice_hook::SiglusGlyphLayoutAbi::kStackNineArguments ||
      return_address < module ||
      return_address - module != profile->dialogue_glyph_return_rva ||
      !IsSiglusLookupGlyphOwned(self)) return;
  constexpr size_t size = fushi_voice_hook::SiglusGlyphRecordBytes(
      fushi_voice_hook::SiglusGlyphLayoutAbi::kStackNineArguments);
  __try {
    uint8_t bytes[size] = {};
    memcpy(bytes, self, size);
    fushi_voice_hook::SiglusGlyphRecord glyph;
    if (fushi_voice_hook::DecodeSiglusNineArgGlyphRecord(
            bytes, size, origin_x, origin_y, profile->viewport_width,
            profile->viewport_height, &glyph))
      PublishSiglusLookupGlyphEvent(glyph.code_unit, glyph.x, glyph.y,
                                    glyph.extent, kSiglusLookupGlyphEventBody);
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

// The intermediate family keeps ECX=self but cleans up only eight DWORDs.
// Its coordinate writer shares the final fields, not the ten-argument ABI.
uint8_t __fastcall Detour_SiglusEightArgGlyphLayout(void* self, void*,
    uintptr_t arg1, uintptr_t arg2, uintptr_t arg3, uintptr_t arg4,
    uintptr_t arg5, uintptr_t arg6, uintptr_t arg7, uintptr_t arg8) {
  const uintptr_t caller = reinterpret_cast<uintptr_t>(_ReturnAddress());
  const auto original = g_orig_SiglusEightArgGlyphLayout;
  if (original == nullptr) return 0;
  const uint8_t result = original(self, arg1, arg2, arg3, arg4,
                                  arg5, arg6, arg7, arg8);
  CaptureSiglusLookupGlyph(self, result, caller,
      fushi_voice_hook::SiglusGlyphLayoutAbi::kEcxEightArguments);
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

// Nine stack DWORDs including self, callee cleanup (RET 0x24), AL result.
// Arguments 8 and 9 (a7/a8 here) are the walker's origin for this glyph.
uint8_t __stdcall Detour_SiglusNineArgGlyphLayout(void* self, uintptr_t arg1,
    uintptr_t arg2, uintptr_t arg3, uintptr_t arg4, uintptr_t arg5,
    uintptr_t arg6, uintptr_t arg7, uintptr_t arg8) {
  const uintptr_t caller = reinterpret_cast<uintptr_t>(_ReturnAddress());
  const auto original = g_orig_SiglusNineArgGlyphLayout;
  if (original == nullptr) return 0;
  const uint8_t result = original(self, arg1, arg2, arg3, arg4, arg5, arg6,
                                  arg7, arg8);
  CaptureSiglusNineArgLookupGlyph(self, result, caller,
                                  static_cast<int32_t>(arg7),
                                  static_cast<int32_t>(arg8));
  return result;
}
