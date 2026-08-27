// Exact anemoi / SiglusEngine 1.1.141.3 in-game lookup sensor.
//
// This file is included after text_render_adapter.inc inside dll_main.cpp's
// anonymous namespace. Keep it header-free. The pure data transforms live in
// siglus_lookup.h, included at file scope by dll_main.cpp.

#if defined(_M_IX86)

static_assert(sizeof(wchar_t) == sizeof(char16_t),
              "Siglus lookup requires Windows UTF-16 wchar_t");

constexpr size_t kSiglusLookupGlyphEventSlots = 512;
constexpr size_t kSiglusLookupTextSlots = 4;
constexpr size_t kSiglusLookupClickEventSlots = 4;
constexpr size_t kSiglusLookupMaxTextUnits = 512;
constexpr ULONGLONG kSiglusLookupClickTargetMaxAgeMs = 64;
constexpr ULONGLONG kSiglusLookupDuplicateHitWindowMs = 250;

struct SiglusLookupGlyphEvent {
  volatile LONG64 seq = 0;
  uint16_t code_unit = 0;
  uint16_t reserved = 0;
  int32_t design_x = 0;
  int32_t design_y = 0;
  int32_t extent = 0;
};

struct SiglusLookupTextSnapshot {
  volatile LONG64 seq = 0;
  uint32_t text_units = 0;
  wchar_t text[kSiglusLookupMaxTextUnits] = {};
};

struct SiglusLookupPayload {
  uint64_t geometry_generation = 0;
  uint32_t text_units = 0;
  uint32_t char_index = 0;
  fushi_voice_hook::SiglusLookupRect rect;
  int32_t client_width = 0;
  int32_t client_height = 0;
  wchar_t text[kSiglusLookupMaxTextUnits] = {};
};

struct SiglusLookupClickTarget {
  volatile LONG64 seq = 0;
  uint32_t valid = 0;
  ULONGLONG published_tick = 0;
  uintptr_t game_window = 0;
  int32_t client_screen_x = 0;
  int32_t client_screen_y = 0;
  int32_t client_width = 0;
  int32_t client_height = 0;
  uint64_t geometry_generation = 0;
  uint32_t text_units = 0;
  wchar_t text[kSiglusLookupMaxTextUnits] = {};
  fushi_voice_hook::SiglusLookupGeometry geometry;
};

struct SiglusLookupClickEvent {
  volatile LONG64 seq = 0;
  SiglusLookupPayload payload;
};

using SiglusGlyphLayoutFn = uint8_t(__thiscall *)(void *, uintptr_t, uintptr_t,
                                                  uintptr_t, uintptr_t,
                                                  uintptr_t, uintptr_t,
                                                  uintptr_t, uintptr_t,
                                                  uintptr_t, uintptr_t);
using SiglusInputMessageFn = void(__stdcall *)(UINT, WPARAM, LPARAM);

SiglusGlyphLayoutFn g_orig_SiglusGlyphLayout = nullptr;
decltype(&GetKeyState) g_orig_SiglusGetKeyState = nullptr;
SiglusInputMessageFn g_orig_SiglusInputMessage = nullptr;
std::atomic<bool> g_siglus_lookup_capture_enabled{false};
std::atomic<bool> g_siglus_lookup_click_runtime_enabled{false};
std::atomic<uint32_t> g_siglus_lookup_click_epoch{1};
volatile LONG g_siglus_lookup_profile_state = 0; // 0 unknown, 1 match, -1 miss

SiglusLookupGlyphEvent
    g_siglus_lookup_glyph_events[kSiglusLookupGlyphEventSlots] = {};
volatile LONG64 g_siglus_lookup_glyph_event_count = 0;
uint64_t g_siglus_lookup_glyph_processed_seq = 0;
fushi_voice_hook::SiglusLookupGlyphCaptureBuffer g_siglus_lookup_glyph_captures;

SiglusLookupTextSnapshot
    g_siglus_lookup_text_snapshots[kSiglusLookupTextSlots] = {};
volatile LONG64 g_siglus_lookup_text_count = 0;
uint64_t g_siglus_lookup_text_processed_seq = 0;

wchar_t g_siglus_lookup_active_line[kSiglusLookupMaxTextUnits] = {};
uint32_t g_siglus_lookup_active_line_units = 0;
fushi_voice_hook::SiglusLookupGeometry g_siglus_lookup_active_geometry;
bool g_siglus_lookup_active_valid = false;
uint64_t g_siglus_lookup_geometry_generation = 0;
bool g_siglus_lookup_last_shift_down = false;

SiglusLookupClickTarget g_siglus_lookup_click_target = {};
volatile LONG64 g_siglus_lookup_click_target_count = 0;
SiglusLookupClickEvent
    g_siglus_lookup_click_events[kSiglusLookupClickEventSlots] = {};
volatile LONG64 g_siglus_lookup_click_event_count = 0;
uint64_t g_siglus_lookup_click_processed_seq = 0;

// The exact GetKeyState callsite is single-threaded. These are mutated only by
// that admitted engine poller; the worker communicates through seqlock slots.
fushi_voice_hook::SiglusLookupClickSampleState
    g_siglus_lookup_click_sample_state;
// The admitted poller below decides ownership, but this Siglus build has
// several other GetKeyState(VK_LBUTTON) consumers in the hydrated main image.
// Once the exact poller owns a physical press, every consumer must see the same
// filtered state until that poller observes the matching up.  SGRE gets this
// property by detouring the DirectInput device implementation itself; Siglus
// needs an explicit cross-caller latch because its input boundary is user32.
std::atomic<bool> g_siglus_lookup_left_button_filter_latched{false};
std::atomic<bool> g_siglus_lookup_message_left_button_latched{false};
uint32_t g_siglus_lookup_click_observed_epoch = 0;
SiglusLookupPayload g_siglus_lookup_pending_click;
bool g_siglus_lookup_pending_click_valid = false;
SiglusLookupClickTarget g_siglus_lookup_click_read_target;

uint64_t g_siglus_lookup_last_hit_identity = 0;
ULONGLONG g_siglus_lookup_last_hit_tick = 0;

// The direct WebView lives in Fushi, while this exact engine samples
// GetKeyState in-process.  Publish the same fail-closed liveness transaction
// used by SGRE, under a Siglus-specific property namespace.  The worker owns
// property-window migration; the admitted engine poller only reads the atomic
// game HWND and the current popup property.
std::atomic<HWND> g_siglus_sampled_input_game_window{nullptr};
HWND g_siglus_sampled_input_property_window = nullptr;
ULONGLONG g_siglus_sampled_input_last_health_tick = 0;
constexpr ULONGLONG kSiglusSampledInputHealthIntervalMs = 1000;

void SetSiglusLookupDiag(uint32_t bits) {
  if (g_header == nullptr)
    return;
  InterlockedOr(reinterpret_cast<volatile LONG *>(&g_header->lookup_diag),
                static_cast<LONG>(bits));
}

HWND GetValidPublishedSiglusSampledInputShieldPopup(HWND game) {
  if (game == nullptr)
    return nullptr;
  const HWND popup = reinterpret_cast<HWND>(GetPropW(
      game, fushi_voice_hook::kSiglusSampledInputShieldWindowProperty));
  if (popup == nullptr || !IsWindow(game) || !IsWindow(popup) ||
      GetWindow(popup, GW_OWNER) != game) {
    return nullptr;
  }
  wchar_t class_name[64] = {};
  if (GetClassNameW(
          popup, class_name,
          static_cast<int>(sizeof(class_name) / sizeof(class_name[0]))) <= 0 ||
      lstrcmpW(class_name, L"FushiGlobalLookupWindow") != 0) {
    return nullptr;
  }
  return popup;
}

bool IsSiglusSampledInputShieldReadyPublished(HWND game) {
  return game != nullptr &&
         reinterpret_cast<uintptr_t>(GetPropW(
             game, fushi_voice_hook::kSiglusSampledInputShieldReadyProperty)) ==
             fushi_voice_hook::kSiglusSampledInputShieldReadyValue;
}

void RevokeSiglusSampledInputShieldReady(HWND game) {
  if (game != nullptr && IsWindow(game)) {
    RemovePropW(game,
                fushi_voice_hook::kSiglusSampledInputShieldWindowProperty);
    RemovePropW(game, fushi_voice_hook::kSiglusSampledInputShieldReadyProperty);
  }
  g_siglus_sampled_input_game_window.store(nullptr, std::memory_order_release);
  g_siglus_sampled_input_last_health_tick = 0;
  if (g_header != nullptr) {
    InterlockedAnd(reinterpret_cast<volatile LONG *>(&g_header->lookup_diag),
                   static_cast<LONG>(
                       ~fushi_voice_hook::kLookupDiagSampledInputShieldReady));
  }
}

bool RefreshSiglusSampledInputPropertyWindow() {
  const HWND previous = g_siglus_sampled_input_property_window;
  const HWND current = FindGameMainWindow();
  if (current == nullptr) {
    if (previous != nullptr && IsWindow(previous))
      return true;
    RevokeSiglusSampledInputShieldReady(previous);
    g_siglus_sampled_input_property_window = nullptr;
    return false;
  }
  if (current == previous)
    return true;
  if (GetValidPublishedSiglusSampledInputShieldPopup(previous) != nullptr) {
    // The popup owner is immutable for its lifetime.  Defer a main-window
    // migration until Fushi removes Window after the matching physical up.
    return true;
  }
  RevokeSiglusSampledInputShieldReady(previous);
  if (previous != nullptr && IsWindow(previous)) {
    RemovePropW(previous,
                fushi_voice_hook::kSiglusSampledInputShieldRequiredProperty);
  }
  g_siglus_sampled_input_property_window = current;
  return true;
}

bool PublishSiglusSampledInputShieldRequired() {
  const HWND game = g_siglus_sampled_input_property_window;
  if (game == nullptr || !IsWindow(game))
    return false;
  if (reinterpret_cast<uintptr_t>(GetPropW(
          game, fushi_voice_hook::kSiglusSampledInputShieldRequiredProperty)) ==
      fushi_voice_hook::kSiglusSampledInputShieldRequiredValue) {
    return true;
  }
  return SetPropW(
             game, fushi_voice_hook::kSiglusSampledInputShieldRequiredProperty,
             reinterpret_cast<HANDLE>(
                 fushi_voice_hook::kSiglusSampledInputShieldRequiredValue)) !=
         FALSE;
}

bool PublishSiglusSampledInputShieldReady() {
  const HWND game = g_siglus_sampled_input_property_window;
  if (game == nullptr || !IsWindow(game))
    return false;
  // The injected cache is visible to the GetKeyState detour before Ready is
  // committed cross-process, closing the first-frame race with Fushi Reveal.
  g_siglus_sampled_input_game_window.store(game, std::memory_order_release);
  if (reinterpret_cast<uintptr_t>(GetPropW(
          game, fushi_voice_hook::kSiglusSampledInputShieldReadyProperty)) !=
          fushi_voice_hook::kSiglusSampledInputShieldReadyValue &&
      !SetPropW(game, fushi_voice_hook::kSiglusSampledInputShieldReadyProperty,
                reinterpret_cast<HANDLE>(
                    fushi_voice_hook::kSiglusSampledInputShieldReadyValue))) {
    g_siglus_sampled_input_game_window.store(nullptr,
                                             std::memory_order_release);
    g_siglus_sampled_input_last_health_tick = 0;
    return false;
  }
  g_siglus_sampled_input_last_health_tick = GetTickCount64();
  SetSiglusLookupDiag(fushi_voice_hook::kLookupDiagSampledInputShieldReady);
  return true;
}

bool Sha256FileForSiglusLookup(const wchar_t *path,
                               std::array<uint8_t, 32> *digest) {
  if (path == nullptr || digest == nullptr)
    return false;
  // Profile admission must not flow through our already-installed resource
  // audio observers. Besides being unnecessary, those detours fan the bytes
  // out to every archive recognizer before returning. Use the MinHook
  // trampolines when available so executable identity is computed from the
  // underlying file stream alone.
  const auto create_file =
      g_orig_CreateFileW != nullptr ? g_orig_CreateFileW : &CreateFileW;
  HANDLE file =
      create_file(path, GENERIC_READ,
                  FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                  nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE)
    return false;
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  BCRYPT_HASH_HANDLE hash = nullptr;
  DWORD object_bytes = 0;
  DWORD hash_bytes = 0;
  DWORD result_bytes = 0;
  bool ok = BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM,
                                        nullptr, 0) == 0;
  if (ok) {
    ok = BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH,
                           reinterpret_cast<PUCHAR>(&object_bytes),
                           sizeof(object_bytes), &result_bytes, 0) == 0;
  }
  if (ok) {
    ok = BCryptGetProperty(algorithm, BCRYPT_HASH_LENGTH,
                           reinterpret_cast<PUCHAR>(&hash_bytes),
                           sizeof(hash_bytes), &result_bytes, 0) == 0 &&
         hash_bytes == digest->size();
  }
  std::vector<uint8_t> hash_object(object_bytes);
  if (ok) {
    ok = BCryptCreateHash(algorithm, &hash, hash_object.data(), object_bytes,
                          nullptr, 0, 0) == 0;
  }
  LARGE_INTEGER file_size = {};
  HANDLE mapping = nullptr;
  void *view = nullptr;
  if (ok) {
    ok = GetFileSizeEx(file, &file_size) && file_size.QuadPart > 0 &&
         file_size.QuadPart <= static_cast<LONGLONG>(0xFFFFFFFFull);
  }
  if (ok) {
    const auto create_mapping = g_orig_CreateFileMappingW != nullptr
                                    ? g_orig_CreateFileMappingW
                                    : &CreateFileMappingW;
    mapping = create_mapping(file, nullptr, PAGE_READONLY, 0, 0, nullptr);
    ok = mapping != nullptr;
  }
  if (ok) {
    const auto map_view =
        g_orig_MapViewOfFile != nullptr ? g_orig_MapViewOfFile : &MapViewOfFile;
    view = map_view(mapping, FILE_MAP_READ, 0, 0, 0);
    ok = view != nullptr;
  }
  if (ok) {
    ok = BCryptHashData(hash, static_cast<PUCHAR>(view),
                        static_cast<ULONG>(file_size.QuadPart), 0) == 0;
  }
  if (ok) {
    ok = BCryptFinishHash(hash, digest->data(),
                          static_cast<ULONG>(digest->size()), 0) == 0;
  }
  if (view != nullptr)
    UnmapViewOfFile(view);
  if (mapping != nullptr)
    CloseHandle(mapping);
  if (hash != nullptr)
    BCryptDestroyHash(hash);
  if (algorithm != nullptr)
    BCryptCloseAlgorithmProvider(algorithm, 0);
  CloseHandle(file);
  return ok;
}

bool IsSiglusLookupProfileMatched() {
  const LONG cached =
      InterlockedCompareExchange(&g_siglus_lookup_profile_state, 0, 0);
  if (cached != 0)
    return cached > 0;
  wchar_t executable[32768] = {};
  const DWORD chars = GetModuleFileNameW(
      nullptr, executable,
      static_cast<DWORD>(sizeof(executable) / sizeof(executable[0])));
  HMODULE module = GetModuleHandleW(nullptr);
  std::array<uint8_t, 32> digest = {};
  uint16_t machine = 0;
  if (module != nullptr) {
    const auto *dos = reinterpret_cast<const IMAGE_DOS_HEADER *>(module);
    if (dos->e_magic == IMAGE_DOS_SIGNATURE) {
      const auto *nt = reinterpret_cast<const IMAGE_NT_HEADERS *>(
          reinterpret_cast<const uint8_t *>(module) + dos->e_lfanew);
      if (nt->Signature == IMAGE_NT_SIGNATURE) {
        machine = nt->FileHeader.Machine;
      }
    }
  }
  const bool executable_read =
      chars != 0 && chars < sizeof(executable) / sizeof(executable[0]) &&
      Sha256FileForSiglusLookup(executable, &digest);
  const auto &profile = fushi_voice_hook::kAnemoiSiglusLookupProfile;
  const bool hash_matched =
      executable_read && fushi_voice_hook::MatchesSiglusLookupDigest(
                             profile, digest.data(), digest.size());
  const bool machine_matched = machine == profile.pe_machine;
  uint32_t admission_diag = fushi_voice_hook::kLookupDiagSiglusProfileChecked;
  if (executable_read) {
    admission_diag |= fushi_voice_hook::kLookupDiagSiglusExecutableRead;
  }
  if (hash_matched) {
    admission_diag |= fushi_voice_hook::kLookupDiagSiglusHashMatched;
  }
  if (machine_matched) {
    admission_diag |= fushi_voice_hook::kLookupDiagSiglusMachineMatched;
  }
  SetSiglusLookupDiag(admission_diag);
  const bool matched = hash_matched && machine_matched &&
                       fushi_voice_hook::MatchesSiglusLookupProfile(
                           profile, digest.data(), digest.size(), machine);
  InterlockedExchange(&g_siglus_lookup_profile_state, matched ? 1 : -1);
  if (matched) {
    SetSiglusLookupDiag(fushi_voice_hook::kLookupDiagSiglusProfileMatched);
  }
  return matched;
}

bool MatchesSiglusGlyphLayoutEntry(const uint8_t *target) {
  // Exact-hash sanity guard for the live unpacked entry. Relocation operands
  // at [6,10) and [27,31) are deliberately ignored.
  static constexpr uint8_t kSignature[] = {
      0x55, 0x8B, 0xEC, 0x6A, 0xFF, 0x68, 0x00, 0x00, 0x00, 0x00, 0x64,
      0xA1, 0x00, 0x00, 0x00, 0x00, 0x50, 0x81, 0xEC, 0xDC, 0x00, 0x00,
      0x00, 0x53, 0x56, 0x57, 0xA1, 0x00, 0x00, 0x00, 0x00, 0x33, 0xC5,
      0x50, 0x8D, 0x45, 0xF4, 0x64, 0xA3, 0x00, 0x00, 0x00, 0x00, 0x8B,
      0xF1, 0x80, 0x7E, 0x20, 0x00, 0x75, 0x16,
  };
  if (!IsReadableSpan(target, sizeof(kSignature)))
    return false;
  for (size_t index = 0; index < sizeof(kSignature); ++index) {
    if ((index >= 6 && index < 10) || (index >= 27 && index < 31)) {
      continue;
    }
    if (target[index] != kSignature[index])
      return false;
  }
  return true;
}

bool MatchesSiglusInputMessageEntry(const uint8_t *target) {
  // Exact-hash sanity guard for RVA 0x2C1AC0 in the hydrated image. The
  // absolute global loaded by `mov esi, [imm32]` is relocation-dependent.
  static constexpr uint8_t kSignature[] = {
      0x55, 0x8B, 0xEC, 0x83, 0xE4, 0xF8, 0x51, 0x8B, 0x45, 0x08, 0x56, 0x8B,
      0x35, 0x00, 0x00, 0x00, 0x00, 0x3D, 0x01, 0x02, 0x00, 0x00, 0x77, 0x5C,
      0x74, 0x45, 0x05, 0x00, 0xFF, 0xFF, 0xFF, 0x83, 0xF8, 0x05,
  };
  if (!IsReadableSpan(target, sizeof(kSignature)))
    return false;
  for (size_t index = 0; index < sizeof(kSignature); ++index) {
    if (index >= 13 && index < 17)
      continue;
    if (target[index] != kSignature[index])
      return false;
  }
  return true;
}

void PublishSiglusLookupGlyphEvent(uint16_t code_unit, int32_t design_x,
                                   int32_t design_y, int32_t extent) {
  if (code_unit == 0 || extent <= 0)
    return;
  const uint64_t next = static_cast<uint64_t>(
      InterlockedIncrement64(&g_siglus_lookup_glyph_event_count));
  SiglusLookupGlyphEvent *event =
      &g_siglus_lookup_glyph_events[next % kSiglusLookupGlyphEventSlots];
  InterlockedExchange64(&event->seq, 0);
  event->code_unit = code_unit;
  event->reserved = 0;
  event->design_x = design_x;
  event->design_y = design_y;
  event->extent = extent;
  InterlockedExchange64(&event->seq, static_cast<LONG64>(next));
  SetSiglusLookupDiag(fushi_voice_hook::kLookupDiagSiglusGlyphObserved);
}

uint8_t __fastcall Detour_SiglusGlyphLayout(void *self, void *, uintptr_t arg1,
                                            uintptr_t arg2, uintptr_t arg3,
                                            uintptr_t arg4, uintptr_t arg5,
                                            uintptr_t arg6, uintptr_t arg7,
                                            uintptr_t arg8, uintptr_t arg9,
                                            uintptr_t arg10) {
  const uintptr_t return_address =
      reinterpret_cast<uintptr_t>(_ReturnAddress());
  const SiglusGlyphLayoutFn original = g_orig_SiglusGlyphLayout;
  if (original == nullptr)
    return 0;
  const uint8_t result = original(self, arg1, arg2, arg3, arg4, arg5, arg6,
                                  arg7, arg8, arg9, arg10);
  if (result == 0 || self == nullptr ||
      !g_siglus_lookup_capture_enabled.load(std::memory_order_acquire)) {
    return result;
  }
  const uintptr_t module =
      reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr));
  if (return_address < module ||
      return_address - module != fushi_voice_hook::kAnemoiSiglusLookupProfile
                                     .dialogue_glyph_return_rva) {
    return result;
  }
  __try {
    const auto *bytes = static_cast<const uint8_t *>(self);
    const uint32_t character =
        *reinterpret_cast<const uint32_t *>(bytes + 0x04);
    const int32_t extent = *reinterpret_cast<const int32_t *>(bytes + 0x08);
    const float design_x = *reinterpret_cast<const float *>(bytes + 0x40);
    const float design_y = *reinterpret_cast<const float *>(bytes + 0x44);
    if (character != 0 && character <= 0xFFFFu && extent > 0 && extent <= 256 &&
        std::isfinite(design_x) && std::isfinite(design_y)) {
      const int32_t x = static_cast<int32_t>(std::lround(design_x));
      const int32_t y = static_cast<int32_t>(std::lround(design_y));
      const auto &profile = fushi_voice_hook::kAnemoiSiglusLookupProfile;
      if (x >= 0 && x < profile.viewport_width && y >= 0 &&
          y < profile.viewport_height) {
        PublishSiglusLookupGlyphEvent(static_cast<uint16_t>(character), x, y,
                                      extent);
      }
    }
  } __except (EXCEPTION_EXECUTE_HANDLER) {
  }
  return result;
}

void ObserveSiglusLookupExactText(const wchar_t *text, uint32_t text_units,
                                  uint64_t callsite_rva,
                                  uintptr_t function_rva) {
  const auto &profile = fushi_voice_hook::kAnemoiSiglusLookupProfile;
  if (!g_siglus_lookup_capture_enabled.load(std::memory_order_acquire) ||
      text == nullptr || text_units == 0 ||
      text_units > kSiglusLookupMaxTextUnits ||
      callsite_rva != profile.exact_text_return_rva ||
      function_rva != profile.exact_text_rva) {
    return;
  }
  const uint64_t next = static_cast<uint64_t>(
      InterlockedIncrement64(&g_siglus_lookup_text_count));
  SiglusLookupTextSnapshot *snapshot =
      &g_siglus_lookup_text_snapshots[next % kSiglusLookupTextSlots];
  InterlockedExchange64(&snapshot->seq, 0);
  snapshot->text_units = text_units;
  memcpy(snapshot->text, text,
         static_cast<size_t>(text_units) * sizeof(wchar_t));
  InterlockedExchange64(&snapshot->seq, static_cast<LONG64>(next));
}

bool ReadSiglusLookupGlyphEvent(uint64_t seq, SiglusLookupGlyphEvent *copy) {
  if (seq == 0 || copy == nullptr)
    return false;
  SiglusLookupGlyphEvent *source =
      &g_siglus_lookup_glyph_events[seq % kSiglusLookupGlyphEventSlots];
  const uint64_t before =
      static_cast<uint64_t>(InterlockedCompareExchange64(&source->seq, 0, 0));
  if (before != seq)
    return false;
  memcpy(copy, source, sizeof(*copy));
  const uint64_t after =
      static_cast<uint64_t>(InterlockedCompareExchange64(&source->seq, 0, 0));
  return after == before && after != 0;
}

bool ReadLatestSiglusLookupText(SiglusLookupTextSnapshot *copy, uint64_t *seq) {
  if (copy == nullptr || seq == nullptr)
    return false;
  const uint64_t latest = static_cast<uint64_t>(
      InterlockedCompareExchange64(&g_siglus_lookup_text_count, 0, 0));
  if (latest == 0 || latest == g_siglus_lookup_text_processed_seq) {
    return false;
  }
  SiglusLookupTextSnapshot *source =
      &g_siglus_lookup_text_snapshots[latest % kSiglusLookupTextSlots];
  const uint64_t before =
      static_cast<uint64_t>(InterlockedCompareExchange64(&source->seq, 0, 0));
  if (before != latest)
    return false;
  memcpy(copy, source, sizeof(*copy));
  const uint64_t after =
      static_cast<uint64_t>(InterlockedCompareExchange64(&source->seq, 0, 0));
  if (after != before || after == 0 ||
      copy->text_units > kSiglusLookupMaxTextUnits) {
    return false;
  }
  *seq = latest;
  return true;
}

void InvalidateSiglusLookupClickTarget() {
  const uint64_t next = static_cast<uint64_t>(
      InterlockedIncrement64(&g_siglus_lookup_click_target_count));
  InterlockedExchange64(&g_siglus_lookup_click_target.seq, 0);
  g_siglus_lookup_click_target.valid = 0;
  g_siglus_lookup_click_target.published_tick = GetTickCount64();
  g_siglus_lookup_click_target.game_window = 0;
  g_siglus_lookup_click_target.text_units = 0;
  g_siglus_lookup_click_target.geometry = {};
  InterlockedExchange64(&g_siglus_lookup_click_target.seq,
                        static_cast<LONG64>(next));
}

void PublishSiglusLookupClickTarget(HWND game, const POINT &client_origin,
                                    int32_t client_width,
                                    int32_t client_height) {
  if (!g_siglus_lookup_active_valid || game == nullptr || client_width <= 0 ||
      client_height <= 0 || g_siglus_lookup_active_line_units == 0) {
    InvalidateSiglusLookupClickTarget();
    return;
  }
  const uint64_t next = static_cast<uint64_t>(
      InterlockedIncrement64(&g_siglus_lookup_click_target_count));
  InterlockedExchange64(&g_siglus_lookup_click_target.seq, 0);
  g_siglus_lookup_click_target.valid = 1;
  g_siglus_lookup_click_target.published_tick = GetTickCount64();
  g_siglus_lookup_click_target.game_window = reinterpret_cast<uintptr_t>(game);
  g_siglus_lookup_click_target.client_screen_x = client_origin.x;
  g_siglus_lookup_click_target.client_screen_y = client_origin.y;
  g_siglus_lookup_click_target.client_width = client_width;
  g_siglus_lookup_click_target.client_height = client_height;
  g_siglus_lookup_click_target.geometry_generation =
      g_siglus_lookup_geometry_generation;
  g_siglus_lookup_click_target.text_units = g_siglus_lookup_active_line_units;
  memcpy(g_siglus_lookup_click_target.text, g_siglus_lookup_active_line,
         static_cast<size_t>(g_siglus_lookup_active_line_units) *
             sizeof(wchar_t));
  g_siglus_lookup_click_target.geometry = g_siglus_lookup_active_geometry;
  InterlockedExchange64(&g_siglus_lookup_click_target.seq,
                        static_cast<LONG64>(next));
}

bool ReadSiglusLookupClickTarget(SiglusLookupClickTarget *copy) {
  if (copy == nullptr)
    return false;
  const uint64_t before = static_cast<uint64_t>(
      InterlockedCompareExchange64(&g_siglus_lookup_click_target.seq, 0, 0));
  if (before == 0)
    return false;
  memcpy(copy, &g_siglus_lookup_click_target, sizeof(*copy));
  const uint64_t after = static_cast<uint64_t>(
      InterlockedCompareExchange64(&g_siglus_lookup_click_target.seq, 0, 0));
  const ULONGLONG now = GetTickCount64();
  return after == before && after != 0 && copy->valid == 1 &&
         copy->text_units != 0 &&
         copy->text_units <= kSiglusLookupMaxTextUnits &&
         copy->geometry.glyph_count != 0 &&
         copy->geometry.glyph_count <=
             fushi_voice_hook::kSiglusLookupMaxGlyphs &&
         copy->published_tick != 0 && now >= copy->published_tick &&
         now - copy->published_tick <= kSiglusLookupClickTargetMaxAgeMs;
}

bool BuildSiglusLookupPayloadAtPress(const SiglusLookupClickTarget &target,
                                     HWND game, const POINT &screen_point,
                                     SiglusLookupPayload *payload,
                                     uint16_t *glyph_index) {
  if (payload == nullptr || glyph_index == nullptr || target.valid != 1 ||
      game == nullptr || reinterpret_cast<HWND>(target.game_window) != game ||
      !IsWindow(game) || GetForegroundWindow() != game) {
    return false;
  }
  const HWND point_window = WindowFromPoint(screen_point);
  if (point_window == nullptr ||
      (point_window != game && !IsChild(game, point_window))) {
    return false;
  }
  RECT client = {};
  POINT origin = {0, 0};
  if (!GetClientRect(game, &client) || !ClientToScreen(game, &origin)) {
    return false;
  }
  const int32_t client_width = client.right - client.left;
  const int32_t client_height = client.bottom - client.top;
  if (client_width != target.client_width ||
      client_height != target.client_height ||
      origin.x != target.client_screen_x ||
      origin.y != target.client_screen_y) {
    return false;
  }
  const int32_t cursor_x = screen_point.x - origin.x;
  const int32_t cursor_y = screen_point.y - origin.y;
  for (size_t index = 0; index < target.geometry.glyph_count; ++index) {
    fushi_voice_hook::SiglusLookupRect client_rect;
    if (!fushi_voice_hook::ScaleSiglusLookupRectToClient(
            fushi_voice_hook::kAnemoiSiglusLookupProfile,
            target.geometry.glyphs[index].rect, client_width, client_height,
            &client_rect)) {
      continue;
    }
    if (cursor_x < client_rect.x || cursor_y < client_rect.y ||
        cursor_x >= client_rect.x + client_rect.width ||
        cursor_y >= client_rect.y + client_rect.height) {
      continue;
    }
    *payload = {};
    payload->geometry_generation = target.geometry_generation;
    payload->text_units = target.text_units;
    payload->char_index = target.geometry.glyphs[index].char_index;
    payload->rect = client_rect;
    payload->client_width = client_width;
    payload->client_height = client_height;
    memcpy(payload->text, target.text,
           static_cast<size_t>(target.text_units) * sizeof(wchar_t));
    *glyph_index = static_cast<uint16_t>(index);
    return payload->char_index < payload->text_units;
  }
  return false;
}

void QueueSiglusLookupClickSubmit(const SiglusLookupPayload &payload) {
  if (payload.text_units == 0 ||
      payload.text_units > kSiglusLookupMaxTextUnits ||
      payload.char_index >= payload.text_units) {
    return;
  }
  const uint64_t next = static_cast<uint64_t>(
      InterlockedIncrement64(&g_siglus_lookup_click_event_count));
  SiglusLookupClickEvent *event =
      &g_siglus_lookup_click_events[next % kSiglusLookupClickEventSlots];
  InterlockedExchange64(&event->seq, 0);
  event->payload = payload;
  InterlockedExchange64(&event->seq, static_cast<LONG64>(next));
}

bool ReadLatestSiglusLookupClickSubmit(SiglusLookupClickEvent *copy,
                                       uint64_t *seq) {
  if (copy == nullptr || seq == nullptr)
    return false;
  const uint64_t latest = static_cast<uint64_t>(
      InterlockedCompareExchange64(&g_siglus_lookup_click_event_count, 0, 0));
  if (latest == 0 || latest == g_siglus_lookup_click_processed_seq) {
    return false;
  }
  SiglusLookupClickEvent *source =
      &g_siglus_lookup_click_events[latest % kSiglusLookupClickEventSlots];
  const uint64_t before =
      static_cast<uint64_t>(InterlockedCompareExchange64(&source->seq, 0, 0));
  if (before != latest)
    return false;
  memcpy(copy, source, sizeof(*copy));
  const uint64_t after =
      static_cast<uint64_t>(InterlockedCompareExchange64(&source->seq, 0, 0));
  if (after != before || after == 0)
    return false;
  *seq = latest;
  return true;
}

SHORT WINAPI Detour_SiglusGetKeyState(int virtual_key) {
  const uintptr_t return_address =
      reinterpret_cast<uintptr_t>(_ReturnAddress());
  const auto original = g_orig_SiglusGetKeyState;
  if (original == nullptr)
    return 0;
  const SHORT raw = original(virtual_key);
  const uintptr_t module =
      reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr));
  if (virtual_key != VK_LBUTTON || !g_capture_enabled) {
    return raw;
  }
  const bool runtime_enabled =
      g_siglus_lookup_click_runtime_enabled.load(std::memory_order_acquire);
  const HWND published_game =
      g_siglus_sampled_input_game_window.load(std::memory_order_acquire);
  const HWND direct_popup =
      GetValidPublishedSiglusSampledInputShieldPopup(published_game);
  const bool direct_shield =
      direct_popup != nullptr &&
      IsSiglusSampledInputShieldReadyPublished(published_game);
  const bool bitmap_popup_visible = IsLookupOverlayInputShieldVisible();
  const bool popup_shield = direct_shield || bitmap_popup_visible;
  const bool lookup_press_latched =
      g_siglus_lookup_left_button_filter_latched.load(
          std::memory_order_acquire);
  const bool admitted_lookup_poller =
      return_address >= module &&
      return_address - module ==
          fushi_voice_hook::kAnemoiSiglusLookupProfile.get_key_state_return_rva;
  if (!admitted_lookup_poller) {
    // The WebView HWND consumes queued mouse messages in its real region and
    // the host HHOOK consumes game-client clicks outside it.  Siglus also polls
    // physical state at several other callsites, so those callers must be
    // filtered before the exact lookup-poller gate.  Otherwise a click can be
    // handled by WebView and still advance the game in the same frame.
    return fushi_voice_hook::FilterSiglusLookupGetKeyState(
        raw, popup_shield || lookup_press_latched);
  }
  SetSiglusLookupDiag(fushi_voice_hook::kLookupDiagSiglusGetKeyStateObserved);
  const uint32_t epoch =
      g_siglus_lookup_click_epoch.load(std::memory_order_acquire);
  if (epoch != g_siglus_lookup_click_observed_epoch) {
    g_siglus_lookup_click_observed_epoch = epoch;
    g_siglus_lookup_click_sample_state = {};
    g_siglus_lookup_pending_click = {};
    g_siglus_lookup_pending_click_valid = false;
    g_siglus_lookup_left_button_filter_latched.store(false,
                                                     std::memory_order_release);
  }
  if (!runtime_enabled && !popup_shield && !lookup_press_latched &&
      g_siglus_lookup_click_sample_state.owner ==
          fushi_voice_hook::SiglusLookupClickOwner::kIdle) {
    return raw;
  }
  const bool button_down = (static_cast<uint16_t>(raw) & 0x8000u) != 0;
  const bool fresh_down = button_down &&
                          g_siglus_lookup_click_sample_state.synchronized &&
                          g_siglus_lookup_click_sample_state.owner ==
                              fushi_voice_hook::SiglusLookupClickOwner::kIdle;
  HWND game = published_game;
  if (game == nullptr || !IsWindow(game))
    game = FindGameMainWindow();
  POINT pointer = {};
  const bool pointer_valid = !fresh_down || GetCursorPos(&pointer) != FALSE;
  SiglusLookupPayload pressed_payload;
  uint16_t hit_index = fushi_voice_hook::kSiglusLookupNoGlyph;
  bool hit = false;
  if (fresh_down && runtime_enabled && !popup_shield && pointer_valid &&
      ReadSiglusLookupClickTarget(&g_siglus_lookup_click_read_target)) {
    hit =
        BuildSiglusLookupPayloadAtPress(g_siglus_lookup_click_read_target, game,
                                        pointer, &pressed_payload, &hit_index);
  }
  const auto decision = fushi_voice_hook::AdvanceSiglusLookupClickSample(
      button_down, popup_shield,
      hit ? hit_index : fushi_voice_hook::kSiglusLookupNoGlyph,
      &g_siglus_lookup_click_sample_state);
  if (decision.begin && decision.popup_transaction && pointer_valid &&
      !direct_shield && bitmap_popup_visible && game != nullptr &&
      GetForegroundWindow() == game) {
    const HWND point_window = WindowFromPoint(pointer);
    if (point_window != nullptr &&
        (point_window == game || IsChild(game, point_window))) {
      RequestLookupOverlayOutsideDismiss();
    }
  }
  if (decision.begin && hit && !decision.popup_transaction) {
    g_siglus_lookup_pending_click = pressed_payload;
    g_siglus_lookup_pending_click_valid = true;
  }
  if (decision.submit) {
    if (g_siglus_lookup_pending_click_valid && runtime_enabled) {
      QueueSiglusLookupClickSubmit(g_siglus_lookup_pending_click);
    }
    g_siglus_lookup_pending_click_valid = false;
  } else if (!button_down && !decision.consume) {
    g_siglus_lookup_pending_click_valid = false;
  }
  if (decision.consume) {
    g_siglus_lookup_left_button_filter_latched.store(true,
                                                     std::memory_order_release);
  }
  const SHORT filtered = fushi_voice_hook::FilterSiglusLookupGetKeyState(
      raw, decision.consume || popup_shield || lookup_press_latched);
  if (!button_down) {
    // Keep the latch through the exact poller's up sample itself, then release
    // it for the next physical transaction. Other GetKeyState callers are not
    // allowed to clear it because GetKeyState state is thread-queue-relative.
    g_siglus_lookup_left_button_filter_latched.store(false,
                                                     std::memory_order_release);
  }
  return filtered;
}

void __stdcall Detour_SiglusInputMessage(UINT message, WPARAM wparam,
                                         LPARAM lparam) {
  const SiglusInputMessageFn original = g_orig_SiglusInputMessage;
  if (original == nullptr)
    return;
  const uintptr_t module =
      reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr));
  const uintptr_t return_address =
      reinterpret_cast<uintptr_t>(_ReturnAddress());
  const auto &profile = fushi_voice_hook::kAnemoiSiglusLookupProfile;
  if (return_address < module ||
      return_address - module != profile.main_input_message_return_rva) {
    original(message, wparam, lparam);
    return;
  }

  const bool is_down =
      message == fushi_voice_hook::kSiglusLookupWmLeftButtonDown ||
      message == fushi_voice_hook::kSiglusLookupWmLeftButtonDoubleClick;
  const bool is_up = message == fushi_voice_hook::kSiglusLookupWmLeftButtonUp;
  if (!is_down && !is_up) {
    original(message, wparam, lparam);
    return;
  }

  HWND game =
      g_siglus_sampled_input_game_window.load(std::memory_order_acquire);
  if (game == nullptr || !IsWindow(game))
    game = FindGameMainWindow();
  const HWND direct_popup =
      GetValidPublishedSiglusSampledInputShieldPopup(game);
  const bool direct_shield =
      direct_popup != nullptr && IsSiglusSampledInputShieldReadyPublished(game);
  const bool popup_shield =
      direct_shield || IsLookupOverlayInputShieldVisible();

  bool glyph_hit = false;
  if (is_down && !popup_shield &&
      g_siglus_lookup_click_runtime_enabled.load(std::memory_order_acquire) &&
      game != nullptr) {
    POINT screen_point = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
    SiglusLookupClickTarget target;
    SiglusLookupPayload payload;
    uint16_t glyph_index = fushi_voice_hook::kSiglusLookupNoGlyph;
    if (ClientToScreen(game, &screen_point) &&
        ReadSiglusLookupClickTarget(&target)) {
      glyph_hit = BuildSiglusLookupPayloadAtPress(target, game, screen_point,
                                                  &payload, &glyph_index);
    }
  }

  const bool latched = g_siglus_lookup_message_left_button_latched.load(
      std::memory_order_acquire);
  const auto decision = fushi_voice_hook::DecideSiglusLookupMouseMessage(
      static_cast<uint32_t>(message), popup_shield, glyph_hit, latched);
  g_siglus_lookup_message_left_button_latched.store(decision.next_latched,
                                                    std::memory_order_release);
  if (decision.consume) {
    // The exact GetKeyState poller still observes physical state and owns the
    // one lookup submission. This latch only makes every other state consumer
    // agree while the engine's independent WM edge writer is bypassed.
    g_siglus_lookup_left_button_filter_latched.store(true,
                                                     std::memory_order_release);
    return;
  }
  original(message, wparam, lparam);
}

bool InstallSiglusLookupSensor() {
  if (!IsSiglusLookupProfileMatched())
    return false;
  HMODULE module = GetModuleHandleW(nullptr);
  if (module == nullptr)
    return false;
  const ULONGLONG now = GetTickCount64();
  const HWND cached_game =
      g_siglus_sampled_input_game_window.load(std::memory_order_acquire);
  if (g_orig_SiglusGlyphLayout != nullptr &&
      g_orig_SiglusGetKeyState != nullptr &&
      g_orig_SiglusInputMessage != nullptr && cached_game != nullptr &&
      cached_game == g_siglus_sampled_input_property_window &&
      IsWindow(cached_game) && g_siglus_sampled_input_last_health_tick != 0 &&
      now - g_siglus_sampled_input_last_health_tick <
          kSiglusSampledInputHealthIntervalMs) {
    return true;
  }
  if (!RefreshSiglusSampledInputPropertyWindow() ||
      !PublishSiglusSampledInputShieldRequired()) {
    RevokeSiglusSampledInputShieldReady(g_siglus_sampled_input_property_window);
    return false;
  }
  if (g_orig_SiglusGlyphLayout == nullptr) {
    auto *target =
        reinterpret_cast<uint8_t *>(module) +
        fushi_voice_hook::kAnemoiSiglusLookupProfile.glyph_layout_rva;
    if (!MatchesSiglusGlyphLayoutEntry(target) ||
        !HookFn(target, reinterpret_cast<void *>(&Detour_SiglusGlyphLayout),
                reinterpret_cast<void **>(&g_orig_SiglusGlyphLayout)) ||
        g_orig_SiglusGlyphLayout == nullptr) {
      RevokeSiglusSampledInputShieldReady(
          g_siglus_sampled_input_property_window);
      return false;
    }
    SetSiglusLookupDiag(fushi_voice_hook::kLookupDiagSiglusGlyphHookReady);
  }
  if (g_orig_SiglusGetKeyState == nullptr) {
    HMODULE user32 = GetModuleHandleW(L"user32.dll");
    if (user32 == nullptr)
      user32 = LoadLibraryW(L"user32.dll");
    void *target =
        user32 == nullptr
            ? nullptr
            : reinterpret_cast<void *>(GetProcAddress(user32, "GetKeyState"));
    if (target == nullptr ||
        !HookFn(target, reinterpret_cast<void *>(&Detour_SiglusGetKeyState),
                reinterpret_cast<void **>(&g_orig_SiglusGetKeyState)) ||
        g_orig_SiglusGetKeyState == nullptr) {
      RevokeSiglusSampledInputShieldReady(
          g_siglus_sampled_input_property_window);
      return false;
    }
  }
  if (g_orig_SiglusInputMessage == nullptr) {
    auto *target =
        reinterpret_cast<uint8_t *>(module) +
        fushi_voice_hook::kAnemoiSiglusLookupProfile.input_message_rva;
    if (!MatchesSiglusInputMessageEntry(target) ||
        !HookFn(target, reinterpret_cast<void *>(&Detour_SiglusInputMessage),
                reinterpret_cast<void **>(&g_orig_SiglusInputMessage)) ||
        g_orig_SiglusInputMessage == nullptr) {
      RevokeSiglusSampledInputShieldReady(
          g_siglus_sampled_input_property_window);
      return false;
    }
  }
  SetSiglusLookupDiag(fushi_voice_hook::kLookupDiagSensorInstalled |
                      fushi_voice_hook::kLookupDiagSiglusGlyphHookReady |
                      fushi_voice_hook::kLookupDiagSiglusGetKeyStateHookReady);
  if (!PublishSiglusSampledInputShieldReady()) {
    RevokeSiglusSampledInputShieldReady(g_siglus_sampled_input_property_window);
    return false;
  }
  return true;
}

void SetSiglusLookupRuntimeEnabled(bool enabled) {
  const bool previous = g_siglus_lookup_click_runtime_enabled.exchange(
      enabled, std::memory_order_acq_rel);
  g_siglus_lookup_capture_enabled.store(enabled, std::memory_order_release);
  if (enabled && !previous) {
    g_siglus_lookup_click_epoch.fetch_add(1, std::memory_order_acq_rel);
  }
}

void ConsumeSiglusLookupCaptures() {
  bool changed = false;
  SiglusLookupTextSnapshot text_snapshot;
  uint64_t text_seq = 0;
  if (ReadLatestSiglusLookupText(&text_snapshot, &text_seq)) {
    g_siglus_lookup_text_processed_seq = text_seq;
    const bool same =
        text_snapshot.text_units == g_siglus_lookup_active_line_units &&
        text_snapshot.text_units != 0 &&
        memcmp(text_snapshot.text, g_siglus_lookup_active_line,
               static_cast<size_t>(text_snapshot.text_units) *
                   sizeof(wchar_t)) == 0;
    if (!same) {
      g_siglus_lookup_active_line_units = text_snapshot.text_units;
      memcpy(g_siglus_lookup_active_line, text_snapshot.text,
             static_cast<size_t>(text_snapshot.text_units) * sizeof(wchar_t));
      g_siglus_lookup_active_valid = false;
      changed = true;
    }
  }

  const uint64_t latest = static_cast<uint64_t>(
      InterlockedCompareExchange64(&g_siglus_lookup_glyph_event_count, 0, 0));
  if (latest != g_siglus_lookup_glyph_processed_seq) {
    uint64_t first = g_siglus_lookup_glyph_processed_seq + 1;
    if (latest >= kSiglusLookupGlyphEventSlots &&
        first <= latest - kSiglusLookupGlyphEventSlots) {
      first = latest - kSiglusLookupGlyphEventSlots + 1;
      fushi_voice_hook::ClearSiglusLookupGlyphCapture(
          &g_siglus_lookup_glyph_captures);
    }
    uint64_t processed_through = first - 1u;
    for (uint64_t seq = first; seq <= latest; ++seq) {
      SiglusLookupGlyphEvent event;
      // The producer reserves its sequence before publishing the slot. Stop
      // at the first not-yet-published event so the next tick retries it;
      // advancing straight to `latest` would permanently drop a tail glyph.
      if (!ReadSiglusLookupGlyphEvent(seq, &event))
        break;
      fushi_voice_hook::AppendSiglusLookupGlyphCapture(
          static_cast<char16_t>(event.code_unit), event.design_x,
          event.design_y, event.extent, &g_siglus_lookup_glyph_captures);
      processed_through = seq;
      changed = true;
    }
    g_siglus_lookup_glyph_processed_seq = processed_through;
  }

  if (!changed || g_siglus_lookup_active_line_units == 0)
    return;
  fushi_voice_hook::SiglusLookupGeometry geometry;
  if (fushi_voice_hook::BuildSiglusLookupGeometry(
          fushi_voice_hook::kAnemoiSiglusLookupProfile,
          g_siglus_lookup_glyph_captures,
          reinterpret_cast<const char16_t *>(g_siglus_lookup_active_line),
          g_siglus_lookup_active_line_units, &geometry)) {
    g_siglus_lookup_active_geometry = geometry;
    g_siglus_lookup_active_valid = true;
    ++g_siglus_lookup_geometry_generation;
    SetSiglusLookupDiag(fushi_voice_hook::kLookupDiagGeometryObserved);
  }
}

void PublishSiglusLookupHit(const SiglusLookupPayload &payload) {
  if (g_header == nullptr || payload.text_units == 0 ||
      payload.text_units > kSiglusLookupMaxTextUnits ||
      payload.char_index >= payload.text_units) {
    return;
  }
  fushi_voice_hook::LookupHitSlot *slot =
      fushi_voice_hook::LookupHitOf(g_header);
  if (slot == nullptr)
    return;
  char utf8[fushi_voice_hook::kLookupLineBytes] = {};
  const int bytes = WideCharToMultiByte(
      CP_UTF8, 0, payload.text, static_cast<int>(payload.text_units), utf8,
      static_cast<int>(sizeof(utf8)), nullptr, nullptr);
  if (bytes <= 0)
    return;
  const uint64_t next =
      static_cast<uint64_t>(InterlockedCompareExchange64(
          reinterpret_cast<volatile LONG64 *>(&g_header->lookup_hit_count), 0,
          0)) +
      1u;
  InterlockedExchange64(reinterpret_cast<volatile LONG64 *>(&slot->seq), 0);
  slot->char_index = payload.char_index;
  slot->char_count = payload.text_units;
  slot->glyph_x = payload.rect.x;
  slot->glyph_y = payload.rect.y;
  slot->glyph_w = payload.rect.width;
  slot->glyph_h = payload.rect.height;
  slot->view_w = payload.client_width;
  slot->view_h = payload.client_height;
  slot->flags = fushi_voice_hook::kLookupHitFlagSubmit;
  slot->line_bytes = static_cast<uint32_t>(bytes);
  memcpy(slot->line_utf8, utf8, static_cast<size_t>(bytes));
  InterlockedExchange64(reinterpret_cast<volatile LONG64 *>(&slot->seq),
                        static_cast<LONG64>(next));
  InterlockedExchange64(
      reinterpret_cast<volatile LONG64 *>(&g_header->lookup_hit_count),
      static_cast<LONG64>(next));
  SetSiglusLookupDiag(fushi_voice_hook::kLookupDiagHitSubmitted);
}

bool PublishSiglusLookupPayload(const SiglusLookupPayload &payload) {
  const ULONGLONG now = GetTickCount64();
  uint64_t identity = 1469598103934665603ull;
  const auto hash_value = [&identity](uint64_t value) {
    identity ^= value;
    identity *= 1099511628211ull;
  };
  hash_value(payload.text_units);
  for (uint32_t index = 0; index < payload.text_units; ++index) {
    hash_value(static_cast<uint32_t>(payload.text[index]));
  }
  hash_value(payload.char_index);
  hash_value(static_cast<uint32_t>(payload.rect.x));
  hash_value(static_cast<uint32_t>(payload.rect.y));
  if (identity == g_siglus_lookup_last_hit_identity &&
      now >= g_siglus_lookup_last_hit_tick &&
      now - g_siglus_lookup_last_hit_tick <=
          kSiglusLookupDuplicateHitWindowMs) {
    return false;
  }
  PublishSiglusLookupHit(payload);
  g_siglus_lookup_last_hit_identity = identity;
  g_siglus_lookup_last_hit_tick = now;
  return true;
}

void ProcessSiglusLookupTick() {
  if (g_stop || g_header == nullptr ||
      !fushi_voice_hook::HasLookupRegion(g_header) ||
      g_header->lookup_enabled == 0) {
    SetSiglusLookupRuntimeEnabled(false);
    g_siglus_lookup_last_shift_down = false;
    g_siglus_lookup_active_valid = false;
    InvalidateSiglusLookupClickTarget();
    return;
  }
  if (!InstallSiglusLookupSensor()) {
    SetSiglusLookupRuntimeEnabled(false);
    InvalidateSiglusLookupClickTarget();
    return;
  }
  SetSiglusLookupRuntimeEnabled(true);
  ConsumeSiglusLookupCaptures();

  SiglusLookupClickEvent click_event;
  uint64_t click_seq = 0;
  bool click_submitted = false;
  if (ReadLatestSiglusLookupClickSubmit(&click_event, &click_seq)) {
    g_siglus_lookup_click_processed_seq = click_seq;
    click_submitted = PublishSiglusLookupPayload(click_event.payload);
  }

  const uint16_t shift_state =
      static_cast<uint16_t>(GetAsyncKeyState(VK_SHIFT));
  const bool shift_submit = fushi_voice_hook::ConsumeSiglusLookupShiftSample(
      shift_state, &g_siglus_lookup_last_shift_down);
  if (!g_siglus_lookup_active_valid) {
    InvalidateSiglusLookupClickTarget();
    return;
  }
  HWND game = FindGameMainWindow();
  RECT client = {};
  POINT origin = {0, 0};
  POINT cursor = {};
  if (game == nullptr || !GetClientRect(game, &client) ||
      !ClientToScreen(game, &origin) || !GetCursorPos(&cursor)) {
    InvalidateSiglusLookupClickTarget();
    return;
  }
  const int32_t client_width = client.right - client.left;
  const int32_t client_height = client.bottom - client.top;
  const bool bitmap_popup_visible = IsLookupOverlayInputShieldVisible();
  const HWND direct_popup =
      GetValidPublishedSiglusSampledInputShieldPopup(game);
  const bool direct_popup_visible =
      direct_popup != nullptr && IsSiglusSampledInputShieldReadyPublished(game);
  const bool popup_visible = bitmap_popup_visible || direct_popup_visible;
  if (!popup_visible) {
    PublishSiglusLookupClickTarget(game, origin, client_width, client_height);
  } else {
    InvalidateSiglusLookupClickTarget();
  }

  const HWND point_window = WindowFromPoint(cursor);
  const bool game_point = GetForegroundWindow() == game &&
                          point_window != nullptr &&
                          (point_window == game || IsChild(game, point_window));
  if (!shift_submit || click_submitted || popup_visible || !game_point) {
    return;
  }
  SiglusLookupClickTarget target;
  if (!ReadSiglusLookupClickTarget(&target))
    return;
  SiglusLookupPayload payload;
  uint16_t glyph_index = fushi_voice_hook::kSiglusLookupNoGlyph;
  if (BuildSiglusLookupPayloadAtPress(target, game, cursor, &payload,
                                      &glyph_index)) {
    PublishSiglusLookupPayload(payload);
  }
}

void ShutdownSiglusLookup() {
  SetSiglusLookupRuntimeEnabled(false);
  g_siglus_lookup_message_left_button_latched.store(false,
                                                    std::memory_order_release);
  g_siglus_lookup_active_valid = false;
  InvalidateSiglusLookupClickTarget();
  // Keep Required on this exact Siglus process.  A later/older host must fail
  // closed until a live GetKeyState detour republishes Ready; dropping Required
  // would silently re-enable the HHOOK-only path disproved on the real game.
  RevokeSiglusSampledInputShieldReady(g_siglus_sampled_input_property_window);
}

#else

bool IsSiglusLookupProfileMatched() { return false; }
void ProcessSiglusLookupTick() {}
void ShutdownSiglusLookup() {}

#endif // _M_IX86
