// HUNEX GGE resource-audio adapter.  The engine-generic HFA/HW parser lives
// in hook/hunex_hfa.h; this file only admits a measured title/archive role and
// connects playback-time reads to the common source-Ogg publication outlet.
#include "hunex_gge_profile.h"

bool IsHunexGgeProfileMatched();

#if defined(_M_X64)

using HunexGgeDrawTextFn = void (*)(
    void*, void*, void*, void*, uintptr_t, void*, uint32_t, void*, int32_t,
    int32_t, int32_t, double, uint32_t);
using HunexGgeGlyphFn = void (*)(void*, void*, uint32_t, void*, uint32_t,
                                 uint32_t);
using HunexGgeGetAsyncKeyStateFn = SHORT(WINAPI*)(int);

struct HunexGgeRuntimeAnchors {
  uintptr_t module = 0;
  uintptr_t draw = 0;
  uintptr_t glyph = 0;
  uintptr_t key_poller = 0;
  uintptr_t input_pump = 0;
  uintptr_t direct_first_glyph_return = 0;
  uintptr_t direct_second_glyph_return = 0;
  uintptr_t generic_key_return = 0;
  uintptr_t left_button_return = 0;
  uintptr_t async_key_state = 0;
};

struct HunexGgeDrawContext {
  bool active = false;
  uint64_t draw_sequence = 0;
  uint64_t text_hash = 0;
  uint32_t text_units = 0;
  uint32_t visible_units = 0;
  fushi_voice_hook::hunex_lookup::GlyphTraceCursor glyph_trace_cursor;
  uint32_t arg7 = 0;
  int32_t x = 0;
  int32_t y = 0;
  int32_t width = 0;
};

HunexGgeRuntimeAnchors g_hunex_gge_anchors;
HunexGgeDrawTextFn g_orig_hunex_gge_draw_text = nullptr;
HunexGgeGlyphFn g_orig_hunex_gge_glyph = nullptr;
HunexGgeGetAsyncKeyStateFn g_orig_hunex_gge_get_async_key_state = nullptr;
volatile LONG g_hunex_gge_trace_scan_state = 0;
volatile LONG g_hunex_gge_trace_hooks_ready = 0;
volatile LONG g_hunex_gge_trace_writer = 0;
volatile LONG g_hunex_gge_input_trace_state[2][256] = {};
thread_local HunexGgeDrawContext g_hunex_gge_draw_context;

uint32_t HunexGgeRva(uintptr_t address) {
  const uintptr_t module = g_hunex_gge_anchors.module;
  if (address < module || address - module > UINT32_MAX) return 0u;
  return static_cast<uint32_t>(address - module);
}

void PublishHunexGgeTrace(fushi_voice_hook::HunexGgeTraceEvent event) {
  auto* trace = &FushiHunexGgeTraceV1;
  // The exported v1 event keeps sequence at the front for a fixed cross-arch
  // layout.  Serialize writers without waiting, then advance next_sequence
  // only after the complete slot is visible; a contending renderer/input
  // callback drops diagnostics instead of blocking the game thread.
  if (InterlockedCompareExchange(&g_hunex_gge_trace_writer, 1, 0) != 0) {
    InterlockedIncrement64(
        reinterpret_cast<volatile LONG64*>(&trace->dropped_busy));
    return;
  }
  const uint64_t sequence = static_cast<uint64_t>(
                                InterlockedCompareExchange64(
                                    reinterpret_cast<volatile LONG64*>(
                                        &trace->next_sequence),
                                    0, 0)) +
                            1u;
  auto* slot = &trace->slots[(sequence - 1u) % trace->capacity];
  if (InterlockedCompareExchange(
          reinterpret_cast<volatile LONG*>(&slot->writing), 1, 0) != 0) {
    InterlockedIncrement64(
        reinterpret_cast<volatile LONG64*>(&trace->dropped_busy));
    InterlockedExchange(&g_hunex_gge_trace_writer, 0);
    return;
  }
  event.sequence = sequence;
  event.timestamp_ms = GetTickCount64();
  event.thread_id = GetCurrentThreadId();
  slot->event = event;
  MemoryBarrier();
  InterlockedExchange(reinterpret_cast<volatile LONG*>(&slot->writing), 0);
  InterlockedExchange64(
      reinterpret_cast<volatile LONG64*>(&trace->next_sequence),
      static_cast<LONG64>(sequence));
  InterlockedExchange(&g_hunex_gge_trace_writer, 0);
}

bool DescribeHunexGgeDrawText(const void* text_object, uint64_t* hash,
                              uint32_t* text_units,
                              uint32_t* visible_units) {
  if (text_object == nullptr || hash == nullptr || text_units == nullptr ||
      visible_units == nullptr) {
    return false;
  }
  bool valid = false;
  __try {
    const auto* object = static_cast<const uint8_t*>(text_object);
    const uint64_t units =
        *reinterpret_cast<const uint64_t*>(object + 0x38u);
    const uint64_t capacity =
        *reinterpret_cast<const uint64_t*>(object + 0x40u);
    const uint32_t visible =
        *reinterpret_cast<const uint32_t*>(object + 0x60u);
    if (units > 0u && units <= 4096u && capacity >= units &&
        capacity <= (1u << 20u) && visible <= 4096u) {
      const wchar_t* text = reinterpret_cast<const wchar_t*>(object + 0x28u);
      if (capacity >= 8u) {
        text = *reinterpret_cast<const wchar_t* const*>(object + 0x28u);
      }
      if (text != nullptr && text[units] == L'\0') {
        uint64_t value = 1469598103934665603ull;
        for (uint64_t index = 0u; index < units; ++index) {
          const uint16_t unit = static_cast<uint16_t>(text[index]);
          value ^= static_cast<uint8_t>(unit & 0xffu);
          value *= 1099511628211ull;
          value ^= static_cast<uint8_t>(unit >> 8u);
          value *= 1099511628211ull;
        }
        *hash = value;
        *text_units = static_cast<uint32_t>(units);
        *visible_units = visible;
        valid = true;
      }
    }
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    valid = false;
  }
  return valid;
}

void Detour_HunexGgeDrawText(
    void* arg1, void* arg2, void* arg3, void* text_object, uintptr_t arg5,
    void* arg6, uint32_t arg7, void* arg8, int32_t x, int32_t y,
    int32_t width, double arg12, uint32_t arg13) {
  const uintptr_t return_address =
      reinterpret_cast<uintptr_t>(_ReturnAddress());
  HunexGgeDrawContext previous = g_hunex_gge_draw_context;
  HunexGgeDrawContext current;
  current.active = DescribeHunexGgeDrawText(
      text_object, &current.text_hash, &current.text_units,
      &current.visible_units);
  current.draw_sequence = static_cast<uint64_t>(InterlockedIncrement64(
      reinterpret_cast<volatile LONG64*>(&FushiHunexGgeTraceV1.draw_calls)));
  current.arg7 = arg7;
  current.x = x;
  current.y = y;
  current.width = width;
  g_hunex_gge_draw_context = current;
  if (current.active) {
    fushi_voice_hook::HunexGgeTraceEvent event;
    event.kind = static_cast<uint32_t>(
        fushi_voice_hook::HunexGgeTraceKind::kDraw);
    event.draw_sequence = current.draw_sequence;
    event.text_hash = current.text_hash;
    std::memcpy(&event.draw_arg12_bits, &arg12,
                sizeof(event.draw_arg12_bits));
    event.caller_rva = HunexGgeRva(return_address);
    event.text_units = current.text_units;
    event.visible_units = current.visible_units;
    event.arg7 = arg7;
    event.draw_arg13 = arg13;
    event.draw_x = x;
    event.draw_y = y;
    event.draw_width = width;
    PublishHunexGgeTrace(event);
  }
  g_orig_hunex_gge_draw_text(arg1, arg2, arg3, text_object, arg5, arg6, arg7,
                             arg8, x, y, width, arg12, arg13);
  g_hunex_gge_draw_context = previous;
}

void Detour_HunexGgeGlyph(void* descriptor, void* output, uint32_t scalar,
                          void* raster, uint32_t arg5, uint32_t arg6) {
  const uintptr_t return_address =
      reinterpret_cast<uintptr_t>(_ReturnAddress());
  g_orig_hunex_gge_glyph(descriptor, output, scalar, raster, arg5, arg6);
  auto& context = g_hunex_gge_draw_context;
  fushi_voice_hook::HunexGgeTraceKind kind;
  if (!context.active) return;
  if (return_address == g_hunex_gge_anchors.direct_first_glyph_return) {
    kind = fushi_voice_hook::HunexGgeTraceKind::kGlyphDirectFirst;
  } else if (return_address ==
             g_hunex_gge_anchors.direct_second_glyph_return) {
    kind = fushi_voice_hook::HunexGgeTraceKind::kGlyphDirectSecond;
  } else {
    return;
  }
  InterlockedIncrement64(reinterpret_cast<volatile LONG64*>(
      &FushiHunexGgeTraceV1.glyph_calls));
  const uint32_t scalar_width = scalar > 0xffffu ? 2u : 1u;
  const auto position =
      fushi_voice_hook::hunex_lookup::ObserveGlyphTraceCall(
          &context.glyph_trace_cursor,
          kind == fushi_voice_hook::HunexGgeTraceKind::kGlyphDirectFirst,
          scalar_width);
  if (!position.valid) return;
  fushi_voice_hook::HunexGgeTraceEvent event;
  event.kind = static_cast<uint32_t>(kind);
  event.draw_sequence = context.draw_sequence;
  event.text_hash = context.text_hash;
  event.caller_rva = HunexGgeRva(return_address);
  event.text_units = context.text_units;
  event.visible_units = context.visible_units;
  event.glyph_ordinal = position.glyph_ordinal;
  event.utf16_char_index = position.utf16_char_index;
  event.scalar_width = scalar_width;
  event.arg7 = context.arg7;
  event.draw_x = context.x;
  event.draw_y = context.y;
  event.draw_width = context.width;
  __try {
    if (descriptor != nullptr) {
      std::memcpy(event.descriptor_words, descriptor,
                  sizeof(event.descriptor_words));
    }
    if (output != nullptr) {
      std::memcpy(event.output_words, output, sizeof(event.output_words));
    }
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    event.result = -1;
  }
  PublishHunexGgeTrace(event);
}

SHORT WINAPI Detour_HunexGgeGetAsyncKeyState(int virtual_key) {
  const SHORT raw = g_orig_hunex_gge_get_async_key_state(virtual_key);
  const uintptr_t return_address =
      reinterpret_cast<uintptr_t>(_ReturnAddress());
  fushi_voice_hook::HunexGgeTraceKind kind;
  if (return_address == g_hunex_gge_anchors.generic_key_return) {
    kind = fushi_voice_hook::HunexGgeTraceKind::kInputGeneric;
  } else if (return_address == g_hunex_gge_anchors.left_button_return) {
    kind = fushi_voice_hook::HunexGgeTraceKind::kInputLeftButton;
  } else {
    return raw;
  }
  InterlockedIncrement64(reinterpret_cast<volatile LONG64*>(
      &FushiHunexGgeTraceV1.input_calls));
  if (virtual_key == VK_LBUTTON || virtual_key == VK_SHIFT ||
      kind == fushi_voice_hook::HunexGgeTraceKind::kInputLeftButton) {
    if (virtual_key < 0 || virtual_key >= 256) return raw;
    const size_t kind_index =
        kind == fushi_voice_hook::HunexGgeTraceKind::kInputGeneric ? 0u : 1u;
    const LONG encoded = static_cast<LONG>(
        fushi_voice_hook::hunex_lookup::EncodeInputTraceState(raw));
    const LONG previous = InterlockedExchange(
        &g_hunex_gge_input_trace_state[kind_index][virtual_key], encoded);
    if (!fushi_voice_hook::hunex_lookup::IsInputTraceStateChange(
            static_cast<uint32_t>(previous), raw)) {
      return raw;
    }
    fushi_voice_hook::HunexGgeTraceEvent event;
    event.kind = static_cast<uint32_t>(kind);
    event.caller_rva = HunexGgeRva(return_address);
    event.arg7 = static_cast<uint32_t>(virtual_key);
    event.result = static_cast<int32_t>(raw);
    PublishHunexGgeTrace(event);
  }
  return raw;
}

bool GetHunexGgeFunctionSpan(const uint8_t* expected_entry,
                             uintptr_t expected_module, size_t maximum_bytes,
                             const uint8_t** span, size_t* span_bytes) {
  if (expected_entry == nullptr || expected_module == 0u || span == nullptr ||
      span_bytes == nullptr || maximum_bytes == 0u) {
    return false;
  }
  DWORD64 image_base = 0u;
  const PRUNTIME_FUNCTION runtime = RtlLookupFunctionEntry(
      reinterpret_cast<DWORD64>(expected_entry), &image_base, nullptr);
  if (runtime == nullptr || image_base != expected_module ||
      image_base + runtime->BeginAddress !=
          reinterpret_cast<uintptr_t>(expected_entry) ||
      runtime->EndAddress <= runtime->BeginAddress) {
    return false;
  }
  const size_t function_bytes =
      static_cast<size_t>(runtime->EndAddress - runtime->BeginAddress);
  *span = expected_entry;
  *span_bytes = (std::min)(function_bytes, maximum_bytes);
  return *span_bytes > 0u;
}

bool ScanHunexGgeRuntimeAnchors() {
  // install() is reachable both from the worker poll and module-load
  // notifications.  Give exactly one caller ownership of the scan; a caller
  // observing state 2 simply retries on the next poll instead of racing the
  // anchor/trace publication below.
  const LONG cached =
      InterlockedCompareExchange(&g_hunex_gge_trace_scan_state, 2, 0);
  if (cached != 0) return cached == 1;
  auto* trace = &FushiHunexGgeTraceV1;
  trace->scanner_status |=
      fushi_voice_hook::kHunexGgeTraceScannerProfileMatched;
  HMODULE module = GetModuleHandleW(nullptr);
  if (module == nullptr) {
    InterlockedExchange(&g_hunex_gge_trace_scan_state, -1);
    return false;
  }

  const uint8_t* draw = nullptr;
  const uint8_t* glyph = nullptr;
  const uint8_t* key_poller = nullptr;
  const uint8_t* input_pump = nullptr;
  uint32_t draw_count = 0u;
  uint32_t glyph_count = 0u;
  uint32_t key_poller_count = 0u;
  uint32_t input_pump_count = 0u;
  uint16_t machine = 0u;
  bool pe_valid = false;
  __try {
    const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(module);
    if (dos->e_magic == IMAGE_DOS_SIGNATURE) {
      const auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS*>(
          reinterpret_cast<const uint8_t*>(module) + dos->e_lfanew);
      if (nt->Signature == IMAGE_NT_SIGNATURE &&
          nt->OptionalHeader.Magic == IMAGE_NT_OPTIONAL_HDR64_MAGIC &&
          nt->FileHeader.Machine == IMAGE_FILE_MACHINE_AMD64) {
        pe_valid = true;
        machine = nt->FileHeader.Machine;
        const IMAGE_SECTION_HEADER* sections = IMAGE_FIRST_SECTION(nt);
        for (uint16_t index = 0u; index < nt->FileHeader.NumberOfSections;
             ++index) {
          if ((sections[index].Characteristics & IMAGE_SCN_MEM_EXECUTE) == 0u ||
              sections[index].Misc.VirtualSize == 0u) {
            continue;
          }
          const auto* section = reinterpret_cast<const uint8_t*>(module) +
                                sections[index].VirtualAddress;
          const size_t bytes = sections[index].Misc.VirtualSize;
          const auto draw_match =
              fushi_voice_hook::hunex_lookup::FindUniqueMaskedPattern(
                  section, bytes,
                  fushi_voice_hook::hunex_lookup::kDrawEntryPattern);
          const auto glyph_match =
              fushi_voice_hook::hunex_lookup::FindUniqueMaskedPattern(
                  section, bytes,
                  fushi_voice_hook::hunex_lookup::kGlyphEntryPattern);
          const auto poller_match =
              fushi_voice_hook::hunex_lookup::FindUniqueMaskedPattern(
                  section, bytes,
                  fushi_voice_hook::hunex_lookup::kKeyPollerEntryPattern);
          const auto pump_match =
              fushi_voice_hook::hunex_lookup::FindUniqueMaskedPattern(
                  section, bytes,
                  fushi_voice_hook::hunex_lookup::kInputPumpEntryPattern);
          if (draw_match.count == 1u && draw_count == 0u)
            draw = section + draw_match.offset;
          if (glyph_match.count == 1u && glyph_count == 0u)
            glyph = section + glyph_match.offset;
          if (poller_match.count == 1u && key_poller_count == 0u)
            key_poller = section + poller_match.offset;
          if (pump_match.count == 1u && input_pump_count == 0u)
            input_pump = section + pump_match.offset;
          draw_count += draw_match.count;
          glyph_count += glyph_match.count;
          key_poller_count += poller_match.count;
          input_pump_count += pump_match.count;
        }
      }
    }
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    pe_valid = false;
  }
  trace->module_machine = machine;
  trace->draw_match_count = draw_count;
  trace->glyph_match_count = glyph_count;
  trace->key_poller_match_count = key_poller_count;
  trace->input_pump_match_count = input_pump_count;
  if (!pe_valid || draw_count != 1u || glyph_count != 1u ||
      key_poller_count != 1u || input_pump_count != 1u || draw == nullptr ||
      glyph == nullptr || key_poller == nullptr || input_pump == nullptr) {
    InterlockedExchange(&g_hunex_gge_trace_scan_state, -1);
    return false;
  }
  trace->scanner_status |=
      fushi_voice_hook::kHunexGgeTraceScannerPe64 |
      fushi_voice_hook::kHunexGgeTraceScannerDrawUnique |
      fushi_voice_hook::kHunexGgeTraceScannerGlyphUnique |
      fushi_voice_hook::kHunexGgeTraceScannerInputUnique;

  const uint8_t* draw_span = nullptr;
  const uint8_t* poller_span = nullptr;
  const uint8_t* pump_span = nullptr;
  size_t draw_bytes = 0u;
  size_t poller_bytes = 0u;
  size_t pump_bytes = 0u;
  const uintptr_t module_address = reinterpret_cast<uintptr_t>(module);
  if (!GetHunexGgeFunctionSpan(
          draw, module_address,
          fushi_voice_hook::hunex_lookup::kDrawScanBytes, &draw_span,
          &draw_bytes) ||
      !GetHunexGgeFunctionSpan(
          key_poller, module_address,
          fushi_voice_hook::hunex_lookup::kKeyPollerScanBytes, &poller_span,
          &poller_bytes) ||
      !GetHunexGgeFunctionSpan(
          input_pump, module_address,
          fushi_voice_hook::hunex_lookup::kInputPumpScanBytes, &pump_span,
          &pump_bytes)) {
    InterlockedExchange(&g_hunex_gge_trace_scan_state, -1);
    return false;
  }

  const auto first_glyph =
      fushi_voice_hook::hunex_lookup::FindUniqueMaskedPattern(
          draw_span, draw_bytes,
          fushi_voice_hook::hunex_lookup::kDrawFirstGlyphCallPattern);
  const auto second_glyph =
      fushi_voice_hook::hunex_lookup::FindUniqueMaskedPattern(
          draw_span, draw_bytes,
          fushi_voice_hook::hunex_lookup::kDrawSecondGlyphCallPattern);
  uintptr_t first_glyph_target = 0u;
  uintptr_t first_glyph_return = 0u;
  uintptr_t second_glyph_target = 0u;
  uintptr_t second_glyph_return = 0u;
  uintptr_t raw_first_return = 0u;
  uintptr_t raw_second_return = 0u;
  const uint32_t raw_glyph_calls =
      fushi_voice_hook::hunex_lookup::FindRel32CallReturnsToTarget(
          draw_span, draw_bytes, reinterpret_cast<uintptr_t>(glyph),
          &raw_first_return, &raw_second_return);
  const bool draw_graph_valid =
      first_glyph.count == 1u && second_glyph.count == 1u &&
      fushi_voice_hook::hunex_lookup::DecodeRel32CallTarget(
          draw_span + first_glyph.offset +
              fushi_voice_hook::hunex_lookup::kDrawFirstGlyphCallOffset,
          &first_glyph_target, &first_glyph_return) &&
      fushi_voice_hook::hunex_lookup::DecodeRel32CallTarget(
          draw_span + second_glyph.offset +
              fushi_voice_hook::hunex_lookup::kDrawSecondGlyphCallOffset,
          &second_glyph_target, &second_glyph_return) &&
      first_glyph_target == reinterpret_cast<uintptr_t>(glyph) &&
      second_glyph_target == reinterpret_cast<uintptr_t>(glyph) &&
      raw_glyph_calls == 2u && raw_first_return == first_glyph_return &&
      raw_second_return == second_glyph_return;

  const auto generic =
      fushi_voice_hook::hunex_lookup::FindUniqueMaskedPattern(
          poller_span, poller_bytes,
          fushi_voice_hook::hunex_lookup::kGenericKeyPollPattern);
  const auto pump_to_poller =
      fushi_voice_hook::hunex_lookup::FindUniqueMaskedPattern(
          pump_span, pump_bytes,
          fushi_voice_hook::hunex_lookup::kPumpCallsPollerPattern);
  const auto cursor_pair =
      fushi_voice_hook::hunex_lookup::FindUniqueMaskedPattern(
          pump_span, pump_bytes,
          fushi_voice_hook::hunex_lookup::kCursorPairPattern);
  const auto left_button =
      fushi_voice_hook::hunex_lookup::FindUniqueMaskedPattern(
          pump_span, pump_bytes,
          fushi_voice_hook::hunex_lookup::kLeftButtonPollPattern);
  uintptr_t pump_target = 0u;
  uintptr_t pump_return = 0u;
  uintptr_t ignored_return = 0u;
  const uint32_t raw_poller_calls =
      fushi_voice_hook::hunex_lookup::FindRel32CallReturnsToTarget(
          pump_span, pump_bytes, reinterpret_cast<uintptr_t>(key_poller),
          &pump_return, &ignored_return);
  uintptr_t generic_slot = 0u;
  uintptr_t left_button_slot = 0u;
  uintptr_t cursor_position_slot = 0u;
  uintptr_t screen_to_client_slot = 0u;
  uintptr_t generic_return = 0u;
  uintptr_t left_button_return = 0u;
  const bool input_shapes_valid =
      generic.count == 1u && pump_to_poller.count == 1u &&
      cursor_pair.count == 1u && left_button.count == 1u &&
      fushi_voice_hook::hunex_lookup::DecodeRel32CallTarget(
          pump_span + pump_to_poller.offset +
              fushi_voice_hook::hunex_lookup::kPumpCallsPollerCallOffset,
          &pump_target, nullptr) &&
      pump_target == reinterpret_cast<uintptr_t>(key_poller) &&
      raw_poller_calls == 1u && pump_return != 0u &&
      fushi_voice_hook::hunex_lookup::DecodeRipIndirectCallSlot(
          poller_span + generic.offset +
              fushi_voice_hook::hunex_lookup::kGenericKeyPollCallOffset,
          &generic_slot, &generic_return) &&
      fushi_voice_hook::hunex_lookup::DecodeRipIndirectCallSlot(
          pump_span + left_button.offset +
              fushi_voice_hook::hunex_lookup::kLeftButtonPollCallOffset,
          &left_button_slot, &left_button_return) &&
      fushi_voice_hook::hunex_lookup::DecodeRipIndirectCallSlot(
          pump_span + cursor_pair.offset +
              fushi_voice_hook::hunex_lookup::kCursorGetPositionCallOffset,
          &cursor_position_slot, nullptr) &&
      fushi_voice_hook::hunex_lookup::DecodeRipIndirectCallSlot(
          pump_span + cursor_pair.offset +
              fushi_voice_hook::hunex_lookup::kCursorScreenToClientCallOffset,
          &screen_to_client_slot, nullptr) &&
      generic_slot == left_button_slot;

  uintptr_t imported_async_key_state = 0u;
  uintptr_t imported_cursor_position = 0u;
  uintptr_t imported_screen_to_client = 0u;
  __try {
    if (input_shapes_valid) {
      imported_async_key_state = reinterpret_cast<uintptr_t>(
          *reinterpret_cast<void**>(generic_slot));
      imported_cursor_position = reinterpret_cast<uintptr_t>(
          *reinterpret_cast<void**>(cursor_position_slot));
      imported_screen_to_client = reinterpret_cast<uintptr_t>(
          *reinterpret_cast<void**>(screen_to_client_slot));
    }
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    imported_async_key_state = 0u;
    imported_cursor_position = 0u;
    imported_screen_to_client = 0u;
  }
  HMODULE user32 = GetModuleHandleW(L"user32.dll");
  const uintptr_t exported_async_key_state = reinterpret_cast<uintptr_t>(
      user32 == nullptr ? nullptr
                        : GetProcAddress(user32, "GetAsyncKeyState"));
  const uintptr_t exported_cursor_position = reinterpret_cast<uintptr_t>(
      user32 == nullptr ? nullptr : GetProcAddress(user32, "GetCursorPos"));
  const uintptr_t exported_screen_to_client = reinterpret_cast<uintptr_t>(
      user32 == nullptr ? nullptr
                        : GetProcAddress(user32, "ScreenToClient"));
  if (!draw_graph_valid || !input_shapes_valid ||
      imported_async_key_state == 0u ||
      imported_async_key_state != exported_async_key_state ||
      imported_cursor_position != exported_cursor_position ||
      imported_screen_to_client != exported_screen_to_client) {
    InterlockedExchange(&g_hunex_gge_trace_scan_state, -1);
    return false;
  }

  trace->scanner_status |=
      fushi_voice_hook::kHunexGgeTraceScannerDrawCallsValid |
      fushi_voice_hook::kHunexGgeTraceScannerInputCallsValid;
  g_hunex_gge_anchors.module = module_address;
  g_hunex_gge_anchors.draw = reinterpret_cast<uintptr_t>(draw);
  g_hunex_gge_anchors.glyph = reinterpret_cast<uintptr_t>(glyph);
  g_hunex_gge_anchors.key_poller = reinterpret_cast<uintptr_t>(key_poller);
  g_hunex_gge_anchors.input_pump = reinterpret_cast<uintptr_t>(input_pump);
  g_hunex_gge_anchors.direct_first_glyph_return = first_glyph_return;
  g_hunex_gge_anchors.direct_second_glyph_return = second_glyph_return;
  g_hunex_gge_anchors.generic_key_return = generic_return;
  g_hunex_gge_anchors.left_button_return = left_button_return;
  g_hunex_gge_anchors.async_key_state = imported_async_key_state;
  trace->draw_rva = HunexGgeRva(g_hunex_gge_anchors.draw);
  trace->glyph_rva = HunexGgeRva(g_hunex_gge_anchors.glyph);
  trace->key_poller_rva = HunexGgeRva(g_hunex_gge_anchors.key_poller);
  trace->input_pump_rva = HunexGgeRva(g_hunex_gge_anchors.input_pump);
  trace->generic_return_rva = HunexGgeRva(generic_return);
  trace->left_button_return_rva = HunexGgeRva(left_button_return);
  trace->direct_first_glyph_return_rva = HunexGgeRva(first_glyph_return);
  trace->direct_second_glyph_return_rva = HunexGgeRva(second_glyph_return);
  InterlockedExchange(&g_hunex_gge_trace_scan_state, 1);
  return true;
}

bool TryHookHunexGgeRuntimeTrace() {
  if (!IsHunexGgeProfileMatched() || !ScanHunexGgeRuntimeAnchors()) {
    return false;
  }
  if (InterlockedCompareExchange(&g_hunex_gge_trace_hooks_ready, 0, 0) != 0) {
    return true;
  }
  // The draw detour activates the high-frequency TLS traversal.  Install it
  // last so a collision/failure on the shared USER32 input target cannot leave
  // an active draw hook with an incomplete dependency chain.
  const bool input_ready = HookFn(
      reinterpret_cast<void*>(g_hunex_gge_anchors.async_key_state),
      reinterpret_cast<void*>(&Detour_HunexGgeGetAsyncKeyState),
      reinterpret_cast<void**>(&g_orig_hunex_gge_get_async_key_state));
  const bool glyph_ready = input_ready && HookFn(
      reinterpret_cast<void*>(g_hunex_gge_anchors.glyph),
      reinterpret_cast<void*>(&Detour_HunexGgeGlyph),
      reinterpret_cast<void**>(&g_orig_hunex_gge_glyph));
  const bool draw_ready = glyph_ready && HookFn(
      reinterpret_cast<void*>(g_hunex_gge_anchors.draw),
      reinterpret_cast<void*>(&Detour_HunexGgeDrawText),
      reinterpret_cast<void**>(&g_orig_hunex_gge_draw_text));
  if (!draw_ready || g_orig_hunex_gge_draw_text == nullptr ||
      g_orig_hunex_gge_glyph == nullptr ||
      g_orig_hunex_gge_get_async_key_state == nullptr) {
    return false;
  }
  FushiHunexGgeTraceV1.scanner_status |=
      fushi_voice_hook::kHunexGgeTraceScannerHooksReady;
  InterlockedExchange(&g_hunex_gge_trace_hooks_ready, 1);
  return true;
}

#else

bool TryHookHunexGgeRuntimeTrace() { return false; }

#endif  // _M_X64

constexpr size_t kHunexVoicePathChars = 32768u;
constexpr int kHunexVoiceHandleSlots = 16;
constexpr int kHunexVoiceTaskSlots = 32;

struct HunexVoiceFileIdentity {
  DWORD volume_serial = 0;
  DWORD file_index_high = 0;
  DWORD file_index_low = 0;
  uint64_t file_bytes = 0;
  uint64_t last_write = 0;
};

struct HunexVoiceRange {
  uint64_t offset = 0;
  uint32_t size = 0;
  uint32_t id = 0;
};

struct HunexVoiceArchive {
  wchar_t path[kHunexVoicePathChars] = {};
  HunexVoiceFileIdentity identity;
  HunexVoiceRange* ranges = nullptr;
  uint32_t range_count = 0;
};

struct HunexVoiceHandle {
  HANDLE handle = INVALID_HANDLE_VALUE;
  uint32_t archive_index = 0;
};

// The shared file callback may only copy these fixed scalars. HFA index/range access,
// source-file reopening, complete HW/Ogg validation and disk publication all
// remain on HookWorker in ProcessHunexVoiceTask.
struct HunexVoiceTask {
  volatile LONG state = 0;  // 0=free, 1=producing, 2=pending, 3=consuming
  uint64_t tick_ms = 0;
  uint64_t offset = 0;
  uint32_t read_bytes = 0;
  uint32_t archive_index = 0;
  uint32_t generation = 0;
  uint8_t prefix[4] = {};
};

struct HunexVoiceArchiveStamp {
  bool present = false;
  uint64_t bytes = 0;
  uint64_t written = 0;

  bool operator==(const HunexVoiceArchiveStamp& other) const {
    return present == other.present && bytes == other.bytes &&
           written == other.written;
  }
};

HunexVoiceArchive g_hunex_voice_archive;
HunexVoiceHandle g_hunex_voice_handles[kHunexVoiceHandleSlots];
HunexVoiceTask g_hunex_voice_tasks[kHunexVoiceTaskSlots];
volatile LONG g_hunex_voice_archive_count = 0;
volatile LONG g_hunex_voice_enabled = 0;
volatile LONG g_hunex_voice_generation = 1;
HunexVoiceArchiveStamp g_hunex_voice_load_stamp;
bool g_hunex_voice_load_attempted = false;
uint32_t g_hunex_voice_last_range = UINT32_MAX;
uint64_t g_hunex_voice_last_tick = 0;

bool ReadHunexVoiceFileIdentity(HANDLE file, HunexVoiceFileIdentity* out) {
  if (file == INVALID_HANDLE_VALUE || out == nullptr) return false;
  BY_HANDLE_FILE_INFORMATION info = {};
  if (!GetFileInformationByHandle(file, &info)) return false;
  out->volume_serial = info.dwVolumeSerialNumber;
  out->file_index_high = info.nFileIndexHigh;
  out->file_index_low = info.nFileIndexLow;
  out->file_bytes = (static_cast<uint64_t>(info.nFileSizeHigh) << 32u) |
                    static_cast<uint64_t>(info.nFileSizeLow);
  out->last_write =
      (static_cast<uint64_t>(info.ftLastWriteTime.dwHighDateTime) << 32u) |
      static_cast<uint64_t>(info.ftLastWriteTime.dwLowDateTime);
  return out->file_bytes != 0u;
}

bool SameHunexVoiceFileIdentity(const HunexVoiceFileIdentity& left,
                                const HunexVoiceFileIdentity& right) {
  return left.volume_serial == right.volume_serial &&
         left.file_index_high == right.file_index_high &&
         left.file_index_low == right.file_index_low &&
         left.file_bytes == right.file_bytes &&
         left.last_write == right.last_write;
}

bool IsHunexHwName(const char* name) {
  if (name == nullptr) return false;
  const size_t chars = strlen(name);
  return chars >= 3u && name[chars - 3u] == '.' &&
         (name[chars - 2u] == 'h' || name[chars - 2u] == 'H') &&
         (name[chars - 1u] == 'w' || name[chars - 1u] == 'W');
}

bool IsHunexGgeProfileMatched() {
  wchar_t executable[kHunexVoicePathChars] = {};
  const DWORD chars = GetModuleFileNameW(
      nullptr, executable, static_cast<DWORD>(std::size(executable)));
  return chars > 0u && chars < std::size(executable) &&
         fushi_voice_hook::MatchesHunexGgeTitleProfile(executable);
}

bool BuildHunexVoiceArchivePath(wchar_t* out, size_t out_chars) {
  if (out == nullptr || out_chars == 0u) return false;
  const DWORD chars = GetModuleFileNameW(
      nullptr, out, static_cast<DWORD>(out_chars));
  if (chars == 0u || chars >= out_chars) return false;
  wchar_t* slash = wcsrchr(out, L'\\');
  if (slash == nullptr) return false;
  slash[1] = 0;
  return wcscat_s(out, out_chars,
                  fushi_voice_hook::kHunexGgeMahoyoVoiceArchiveName) == 0;
}

void StampHunexVoiceArchivePath(const wchar_t* path,
                                HunexVoiceArchiveStamp* out) {
  if (out == nullptr) return;
  *out = {};
  WIN32_FILE_ATTRIBUTE_DATA data = {};
  if (path == nullptr ||
      !GetFileAttributesExW(path, GetFileExInfoStandard, &data) ||
      (data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0u) {
    return;
  }
  out->present = true;
  out->bytes = (static_cast<uint64_t>(data.nFileSizeHigh) << 32u) |
               static_cast<uint64_t>(data.nFileSizeLow);
  out->written =
      (static_cast<uint64_t>(data.ftLastWriteTime.dwHighDateTime) << 32u) |
      static_cast<uint64_t>(data.ftLastWriteTime.dwLowDateTime);
}

bool ReadHunexVoiceMember(HANDLE file, const HunexVoiceRange& range,
                          uint8_t** member) {
  if (file == INVALID_HANDLE_VALUE || member == nullptr || range.size == 0u ||
      range.size > fushi_voice_hook::hunex::kMaxHunexHwBytes) {
    return false;
  }
  *member = static_cast<uint8_t*>(malloc(range.size));
  if (*member == nullptr) return false;
  LARGE_INTEGER at = {};
  at.QuadPart = range.offset;
  if (!SetFilePointerEx(file, at, nullptr, FILE_BEGIN) ||
      !ReadExact(file, *member, range.size)) {
    free(*member);
    *member = nullptr;
    return false;
  }
  return true;
}

bool LoadHunexVoiceArchive(const wchar_t* path, HunexVoiceArchive* out) {
  if (path == nullptr || out == nullptr ||
      !fushi_voice_hook::IsHunexGgeVoiceArchivePath(path) ||
      g_orig_CreateFileW == nullptr || g_orig_ReadFile == nullptr ||
      g_orig_CloseHandle == nullptr) {
    return false;
  }
  HANDLE file = g_orig_CreateFileW(
      path, GENERIC_READ,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;

  HunexVoiceFileIdentity identity;
  uint8_t header[fushi_voice_hook::hunex::kHunexHfaHeaderBytes] = {};
  uint8_t* index = nullptr;
  HunexVoiceRange* ranges = nullptr;
  uint32_t range_count = 0u;
  fushi_voice_hook::hunex::HunexHfaArchiveInfo info;
  bool valid = ReadHunexVoiceFileIdentity(file, &identity) &&
               ReadExact(file, header, sizeof(header)) &&
               memcmp(header, fushi_voice_hook::hunex::kHunexHfaMagic,
                      sizeof(fushi_voice_hook::hunex::kHunexHfaMagic) - 1u) ==
                   0;
  uint64_t index_bytes = 0u;
  if (valid) {
    const uint32_t count =
        fushi_voice_hook::hunex::ReadHunexLe32(header + 12u);
    index_bytes =
        fushi_voice_hook::hunex::kHunexHfaHeaderBytes +
        static_cast<uint64_t>(count) *
            fushi_voice_hook::hunex::kHunexHfaRecordBytes;
    valid = count > 0u &&
            count <= fushi_voice_hook::hunex::kMaxHunexHfaEntries &&
            index_bytes <= identity.file_bytes && index_bytes <= UINT32_MAX;
  }
  if (valid) {
    index = static_cast<uint8_t*>(malloc(static_cast<size_t>(index_bytes)));
    valid = index != nullptr;
    if (valid) {
      memcpy(index, header, sizeof(header));
      valid = ReadExact(file, index + sizeof(header),
                        static_cast<uint32_t>(index_bytes - sizeof(header))) &&
              fushi_voice_hook::hunex::ParseHunexHfaIndex(
                  index, static_cast<size_t>(index_bytes), identity.file_bytes,
                  &info);
    }
  }
  if (valid) {
    ranges = static_cast<HunexVoiceRange*>(
        malloc(static_cast<size_t>(info.count) * sizeof(HunexVoiceRange)));
    valid = ranges != nullptr;
    for (uint32_t id = 0u; valid && id < info.count; ++id) {
      fushi_voice_hook::hunex::HunexHfaEntry entry;
      valid = fushi_voice_hook::hunex::ReadHunexHfaEntryAtIndex(
          index, static_cast<size_t>(index_bytes), identity.file_bytes, id,
          &entry);
      if (!valid) break;
      if (!IsHunexHwName(entry.name)) continue;
      ranges[range_count++] = {entry.absolute_offset, entry.size, entry.id};
    }
    valid = valid && range_count > 0u;
  }
  if (valid) {
    std::sort(ranges, ranges + range_count,
              [](const HunexVoiceRange& left, const HunexVoiceRange& right) {
                return left.offset < right.offset;
              });
    uint8_t* member = nullptr;
    fushi_voice_hook::hunex::HunexHwOggInfo hw;
    valid = ReadHunexVoiceMember(file, ranges[0], &member) &&
            fushi_voice_hook::hunex::ParseHunexHwOgg(
                member, ranges[0].size, &hw);
    free(member);
  }
  if (valid) {
    wcsncpy_s(out->path, path, _TRUNCATE);
    out->identity = identity;
    out->ranges = ranges;
    out->range_count = range_count;
    ranges = nullptr;
  }
  free(ranges);
  free(index);
  g_orig_CloseHandle(file);
  return valid;
}

bool LoadHunexVoiceArchives() {
  if (InterlockedCompareExchange(&g_hunex_voice_archive_count, 0, 0) > 0) {
    return true;
  }
  if (!IsHunexGgeProfileMatched()) return false;
  wchar_t path[kHunexVoicePathChars] = {};
  if (!BuildHunexVoiceArchivePath(path, std::size(path))) return false;
  HunexVoiceArchiveStamp stamp;
  StampHunexVoiceArchivePath(path, &stamp);
  if (g_hunex_voice_load_attempted && stamp == g_hunex_voice_load_stamp) {
    return false;
  }
  g_hunex_voice_load_attempted = true;
  g_hunex_voice_load_stamp = stamp;
  if (!stamp.present || !LoadHunexVoiceArchive(path, &g_hunex_voice_archive)) {
    return false;
  }
  MemoryBarrier();
  InterlockedExchange(&g_hunex_voice_archive_count, 1);
  return true;
}

int FindHunexVoiceArchive(const HunexVoiceFileIdentity& identity) {
  if (InterlockedCompareExchange(&g_hunex_voice_archive_count, 0, 0) != 1) {
    return -1;
  }
  return SameHunexVoiceFileIdentity(g_hunex_voice_archive.identity, identity)
             ? 0
             : -1;
}

void RememberHunexVoiceHfa(HANDLE handle, const wchar_t* path) {
  if (InterlockedCompareExchange(&g_hunex_voice_enabled, 0, 0) == 0 ||
      handle == INVALID_HANDLE_VALUE ||
      !fushi_voice_hook::IsHunexGgeVoiceArchivePath(path) || !g_cs_ready) {
    return;
  }
  HunexVoiceFileIdentity identity;
  if (!ReadHunexVoiceFileIdentity(handle, &identity)) return;
  const int archive_index = FindHunexVoiceArchive(identity);
  if (archive_index < 0) return;

  EnterCriticalSection(&g_cs);
  for (int index = 0; index < kHunexVoiceHandleSlots; ++index) {
    if (g_hunex_voice_handles[index].handle == INVALID_HANDLE_VALUE ||
        g_hunex_voice_handles[index].handle == handle) {
      g_hunex_voice_handles[index].handle = handle;
      g_hunex_voice_handles[index].archive_index =
          static_cast<uint32_t>(archive_index);
      SetXAudioDiagnostic(
          fushi_voice_hook::kXAudioDiagHunexHfaHandleTracked);
      break;
    }
  }
  LeaveCriticalSection(&g_cs);
}

bool CopyHunexVoiceArchiveIndex(HANDLE handle, uint32_t* archive_index) {
  if (handle == INVALID_HANDLE_VALUE || archive_index == nullptr ||
      !g_cs_ready) {
    return false;
  }
  bool found = false;
  EnterCriticalSection(&g_cs);
  for (int index = 0; index < kHunexVoiceHandleSlots; ++index) {
    if (g_hunex_voice_handles[index].handle == handle) {
      *archive_index = g_hunex_voice_handles[index].archive_index;
      found = true;
      break;
    }
  }
  LeaveCriticalSection(&g_cs);
  return found;
}

void ForgetHunexVoiceHfa(HANDLE handle) {
  if (handle == INVALID_HANDLE_VALUE || !g_cs_ready) return;
  EnterCriticalSection(&g_cs);
  for (int index = 0; index < kHunexVoiceHandleSlots; ++index) {
    if (g_hunex_voice_handles[index].handle == handle) {
      g_hunex_voice_handles[index] = {};
      g_hunex_voice_handles[index].handle = INVALID_HANDLE_VALUE;
      break;
    }
  }
  LeaveCriticalSection(&g_cs);
}

bool QueueHunexVoice(uint32_t archive_index, uint64_t offset,
                     uint32_t read_bytes, const uint8_t prefix[4],
                     uint64_t tick_ms) {
  if (prefix == nullptr) return false;
  const uint32_t generation = static_cast<uint32_t>(
      InterlockedCompareExchange(&g_hunex_voice_generation, 0, 0));
  for (int index = 0; index < kHunexVoiceTaskSlots; ++index) {
    const LONG state =
        InterlockedCompareExchange(&g_hunex_voice_tasks[index].state, 0, 0);
    if (state >= 2 && g_hunex_voice_tasks[index].generation == generation &&
        g_hunex_voice_tasks[index].archive_index == archive_index &&
        g_hunex_voice_tasks[index].offset == offset) {
      return true;
    }
  }
  for (int index = 0; index < kHunexVoiceTaskSlots; ++index) {
    if (InterlockedCompareExchange(&g_hunex_voice_tasks[index].state, 1, 0) !=
        0) {
      continue;
    }
    HunexVoiceTask* task = &g_hunex_voice_tasks[index];
    task->tick_ms = tick_ms;
    task->offset = offset;
    task->read_bytes = read_bytes;
    task->archive_index = archive_index;
    task->generation = generation;
    memcpy(task->prefix, prefix, sizeof(task->prefix));
    MemoryBarrier();
    InterlockedExchange(&task->state, 2);
    return true;
  }
  return false;
}

void ObserveHunexVoiceHfaRead(HANDLE file, const void* buffer, DWORD done,
                              LPOVERLAPPED overlapped) {
  if (InterlockedCompareExchange(&g_hunex_voice_enabled, 0, 0) == 0 ||
      buffer == nullptr || done < 4u || overlapped != nullptr) {
    return;
  }
  uint8_t prefix[4] = {};
  __try {
    memcpy(prefix, buffer, sizeof(prefix));
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return;
  }
  if (fushi_voice_hook::hunex::ReadHunexLe32(prefix) !=
          fushi_voice_hook::hunex::kHunexHwHeaderBytes &&
      memcmp(prefix, "OggS", 4u) != 0) {
    return;
  }

  uint32_t archive_index = 0u;
  if (!CopyHunexVoiceArchiveIndex(file, &archive_index)) {
    wchar_t path[kHunexVoicePathChars] = {};
    const DWORD chars = GetFinalPathNameByHandleW(
        file, path, static_cast<DWORD>(std::size(path)), FILE_NAME_NORMALIZED);
    if (chars == 0u || chars >= std::size(path) ||
        !fushi_voice_hook::IsHunexGgeVoiceArchivePath(path)) {
      return;
    }
    RememberHunexVoiceHfa(file, path);
    if (!CopyHunexVoiceArchiveIndex(file, &archive_index)) return;
  }
  SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagHunexHfaReadObserved);

  LARGE_INTEGER zero = {};
  LARGE_INTEGER current = {};
  if (!SetFilePointerEx(file, zero, &current, FILE_CURRENT) ||
      current.QuadPart < done) {
    SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagHunexHfaTaskRejected);
    return;
  }
  const uint64_t start = static_cast<uint64_t>(current.QuadPart) - done;
  const bool queued = QueueHunexVoice(archive_index, start, done, prefix,
                                      GetTickCount64());
  SetXAudioDiagnostic(queued
                          ? fushi_voice_hook::kXAudioDiagHunexHfaVoiceQueued
                          : fushi_voice_hook::kXAudioDiagHunexHfaTaskRejected);
}

bool FindHunexVoiceRange(const HunexVoiceArchive& archive,
                         const HunexVoiceTask& task, uint32_t* range_index,
                         bool* payload_start) {
  if (archive.ranges == nullptr || range_index == nullptr ||
      payload_start == nullptr || task.read_bytes < 4u) {
    return false;
  }
  uint64_t member_offset = task.offset;
  bool payload = false;
  if (memcmp(task.prefix, "OggS", 4u) == 0) {
    if (task.offset < fushi_voice_hook::hunex::kHunexHwHeaderBytes) {
      return false;
    }
    member_offset -= fushi_voice_hook::hunex::kHunexHwHeaderBytes;
    payload = true;
  } else if (fushi_voice_hook::hunex::ReadHunexLe32(task.prefix) !=
             fushi_voice_hook::hunex::kHunexHwHeaderBytes) {
    return false;
  }

  uint32_t first = 0u;
  uint32_t last = archive.range_count;
  while (first < last) {
    const uint32_t middle = first + (last - first) / 2u;
    if (member_offset < archive.ranges[middle].offset) {
      last = middle;
    } else if (member_offset > archive.ranges[middle].offset) {
      first = middle + 1u;
    } else {
      if (archive.ranges[middle].size <=
          fushi_voice_hook::hunex::kHunexHwHeaderBytes) {
        return false;
      }
      const uint32_t available =
          payload
              ? archive.ranges[middle].size -
                    fushi_voice_hook::hunex::kHunexHwHeaderBytes
              : archive.ranges[middle].size;
      if (task.read_bytes > available) {
        return false;
      }
      *range_index = middle;
      *payload_start = payload;
      return true;
    }
  }
  return false;
}

void ProcessHunexVoiceTask(HunexVoiceTask* task) {
  const uint32_t generation = static_cast<uint32_t>(
      InterlockedCompareExchange(&g_hunex_voice_generation, 0, 0));
  if (task == nullptr || task->generation != generation ||
      task->archive_index != 0u ||
      InterlockedCompareExchange(&g_hunex_voice_archive_count, 0, 0) != 1) {
    SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagHunexHfaTaskRejected);
    return;
  }
  const HunexVoiceArchive& archive = g_hunex_voice_archive;
  uint32_t range_index = 0u;
  bool payload_start = false;
  if (!FindHunexVoiceRange(archive, *task, &range_index, &payload_start) ||
      range_index >= archive.range_count) {
    SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagHunexHfaTaskRejected);
    return;
  }
  (void)payload_start;
  if (range_index == g_hunex_voice_last_range &&
      task->tick_ms >= g_hunex_voice_last_tick &&
      task->tick_ms - g_hunex_voice_last_tick <= 2000u) {
    return;
  }

  HANDLE file = g_orig_CreateFileW(
      archive.path, GENERIC_READ,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagHunexHfaTaskRejected);
    return;
  }
  const HunexVoiceRange range = archive.ranges[range_index];
  HunexVoiceFileIdentity identity;
  uint8_t* member = nullptr;
  fushi_voice_hook::hunex::HunexHwOggInfo hw;
  bool valid = ReadHunexVoiceFileIdentity(file, &identity) &&
               SameHunexVoiceFileIdentity(identity, archive.identity) &&
               ReadHunexVoiceMember(file, range, &member) &&
               fushi_voice_hook::hunex::ParseHunexHwOgg(member, range.size,
                                                        &hw);
  if (valid) {
    wchar_t storage_name[64] = {};
    swprintf_s(storage_name, L"hunex-%u.ogg", range.id);
    valid = WriteVoiceOggAt(member + hw.payload_offset, hw.payload_bytes,
                            storage_name, task->tick_ms);
  }
  if (valid) {
    g_hunex_voice_last_range = range_index;
    g_hunex_voice_last_tick = task->tick_ms;
    SetXAudioDiagnostic(
        fushi_voice_hook::kXAudioDiagGameResourcePublished);
  } else {
    SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagHunexHfaTaskRejected);
  }
  free(member);
  g_orig_CloseHandle(file);
}

void ProcessHunexVoiceTasks() {
  for (int index = 0; index < kHunexVoiceTaskSlots; ++index) {
    if (InterlockedCompareExchange(&g_hunex_voice_tasks[index].state, 3, 2) ==
        2) {
      ProcessHunexVoiceTask(&g_hunex_voice_tasks[index]);
      InterlockedExchange(&g_hunex_voice_tasks[index].state, 0);
    }
  }
}

bool TryHookHunexGgeResourceAudio() {
  if (!IsHunexGgeProfileMatched()) return false;
  if (InterlockedCompareExchange(&g_hunex_voice_enabled, 0, 0) != 0) {
    return true;
  }
  if (!TryHookSiglusOvk() || !LoadHunexVoiceArchives()) return false;
  InterlockedExchange(&g_hunex_voice_enabled, 1);
  SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagHunexHfaHooksReady);
  return true;
}

void StopHunexGgeResourceAudio() {
  InterlockedExchange(&g_hunex_voice_enabled, 0);
  InterlockedIncrement(&g_hunex_voice_generation);
  if (g_cs_ready) {
    EnterCriticalSection(&g_cs);
    for (int index = 0; index < kHunexVoiceHandleSlots; ++index) {
      g_hunex_voice_handles[index] = {};
      g_hunex_voice_handles[index].handle = INVALID_HANDLE_VALUE;
    }
    LeaveCriticalSection(&g_cs);
  }
  InterlockedExchange(&g_hunex_voice_archive_count, 0);
  HunexVoiceRange* ranges = g_hunex_voice_archive.ranges;
  g_hunex_voice_archive = {};
  free(ranges);
  for (int index = 0; index < kHunexVoiceTaskSlots; ++index) {
    InterlockedExchange(&g_hunex_voice_tasks[index].state, 0);
  }
  g_hunex_voice_load_attempted = false;
  g_hunex_voice_load_stamp = {};
  g_hunex_voice_last_range = UINT32_MAX;
  g_hunex_voice_last_tick = 0u;
}

class HunexGgeAdapter final : public fushi_voice_hook::EngineAdapter {
 public:
  const char* id() const override { return "hunex_gge"; }
  bool probe() const override { return IsHunexGgeProfileMatched(); }
  bool install() override {
    TryHookHunexGgeRuntimeTrace();
    installed_ = TryHookHunexGgeResourceAudio() || installed_;
    return installed_;
  }
  void ProcessPendingEvents() {
    install();
    ProcessHunexVoiceTasks();
  }
  fushi_voice_hook::AdapterCapability capabilities() const override {
    return fushi_voice_hook::AdapterCapability::kResourceAudio;
  }
  void onModuleLoaded(const wchar_t*) override { install(); }
  void shutdown() override {
    StopHunexGgeResourceAudio();
    installed_ = false;
  }
  fushi_voice_hook::AdapterDiagnostics diagnostics() const override {
    return {id(), probe(), installed_,
            g_header == nullptr ? 0u : g_header->xaudio_diagnostics};
  }

 private:
  bool installed_ = false;
};
