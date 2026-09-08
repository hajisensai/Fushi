// Structurally admitted SiglusEngine in-game lookup sensor.
//
// This file is included after text_render_adapter.inc inside dll_main.cpp's
// anonymous namespace. Keep it header-free. The pure data transforms live in
// siglus_lookup.h, included at file scope by dll_main.cpp.

#if defined(_M_IX86)

static_assert(sizeof(wchar_t) == sizeof(char16_t),
              "Siglus lookup requires Windows UTF-16 wchar_t");

#include "siglus_lookup_worker_types.inc"

using fushi_voice_hook::SiglusGlyphLayoutFn;
using fushi_voice_hook::SiglusLegacyGlyphLayoutFn;
using SiglusInputMessageFn = void(__stdcall *)(UINT, WPARAM, LPARAM);
using SiglusLegacyInputMessageFn = void(__fastcall *)(LPARAM, WPARAM, UINT);

SiglusGlyphLayoutFn g_orig_SiglusGlyphLayout = nullptr;
SiglusLegacyGlyphLayoutFn g_orig_SiglusLegacyGlyphLayout = nullptr;
decltype(&GetKeyState) g_orig_SiglusGetKeyState = nullptr;
decltype(&GetKeyboardState) g_orig_SiglusGetKeyboardState = nullptr;
SiglusInputMessageFn g_orig_SiglusInputMessage = nullptr;
SiglusLegacyInputMessageFn g_orig_SiglusLegacyInputMessage = nullptr;
std::atomic<bool> g_siglus_lookup_capture_enabled{false};
std::atomic<bool> g_siglus_lookup_click_runtime_enabled{false};
std::atomic<uint32_t> g_siglus_lookup_click_epoch{1};
std::atomic<const fushi_voice_hook::SiglusLookupProfile *>
    g_siglus_lookup_profile{nullptr};
volatile LONG g_siglus_lookup_profile_state = 0; // 0 unknown, 1 match, -1 miss
// 2 is a scan in progress; only the owner can publish the immutable profile.
fushi_voice_hook::SiglusLookupProfile g_siglus_family_profile;
ULONGLONG g_siglus_family_first_scan = 0;
ULONGLONG g_siglus_family_last_scan = 0;
bool g_siglus_digest_attempted = false;
const fushi_voice_hook::SiglusLookupProfile* g_siglus_measured_profile = nullptr;
volatile LONG g_siglus_exact_binary_structure_state =
    0; // 0 unknown, 1 hydrated structure match, -1 reject
// v19 准入上报用。不复用 lookup_diag 的 kLookupDiagSensorInstalled：那位是**粘滞**的，
// 只说"曾经装上过"，卸载后不会落回；准入要报的是当前状态。
std::atomic<bool> g_siglus_lookup_sensor_installed{false};
// 当前主 exe 的十六进制摘要，由 IsSiglusLookupProfileMatched() 在做 hash 比对时顺手填。
// 空串 = 没读到 exe。
char g_siglus_lookup_executable_sha256[fushi_voice_hook::kHookModuleDigestChars] = {};

SiglusLookupGlyphEvent
    g_siglus_lookup_glyph_events[kSiglusLookupGlyphEventSlots] = {};
volatile LONG64 g_siglus_lookup_glyph_event_count = 0;
uint64_t g_siglus_lookup_glyph_processed_seq = 0;
fushi_voice_hook::SiglusLookupGlyphCaptureBuffer g_siglus_lookup_glyph_captures;

SiglusLookupTextSnapshot
    g_siglus_lookup_text_snapshots[kSiglusLookupTextSlots] = {};
volatile LONG64 g_siglus_lookup_text_count = 0;
uint64_t g_siglus_lookup_text_processed_seq = 0;
uint64_t g_siglus_lookup_luna_text_processed_seq = 0;

wchar_t g_siglus_lookup_active_line[kSiglusLookupMaxTextUnits] = {};
uint32_t g_siglus_lookup_active_line_units = 0;
fushi_voice_hook::SiglusLookupTextIdentity g_siglus_lookup_text_identity;
fushi_voice_hook::SiglusLookupLayoutState g_siglus_lookup_layout;
HWND g_siglus_lookup_layout_window = nullptr;
fushi_voice_hook::SiglusLookupEngineView g_siglus_lookup_engine_view;
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

const fushi_voice_hook::SiglusLookupProfile *ActiveSiglusLookupProfile() {
  return g_siglus_lookup_profile.load(std::memory_order_acquire);
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

// 见 leaf_aquaplus_adapter.inc 里同名函数的说明：不可逆的抢占决策必须问三态，
// 不能拿「压成 bool 的 false」当「确定不是这个引擎」。
bool IsSiglusLookupIdentityUndecided() {
  const LONG state = InterlockedCompareExchange(&g_siglus_lookup_profile_state, 0, 0);
  return fushi_voice_hook::IsSiglusLookupResolutionPending(state);
}

#include "siglus_lookup_legacy.inc"

bool ShouldReserveSiglusKeyboardState() {
  const auto* profile = ActiveSiglusLookupProfile();
  return IsSiglusLookupIdentityUndecided() ||
      (profile != nullptr && IsLegacySiglusLookup(*profile));
}

bool ReadSiglusDesignSize(HMODULE module, uintptr_t config_rva,
                          int32_t* width, int32_t* height, bool legacy = false) {
  if (module == nullptr || config_rva == 0 || width == nullptr || height == nullptr)
    return false;
  __try {
    const auto slot = reinterpret_cast<uintptr_t>(module) + config_rva;
    if (!fushi_voice_hook::exact_lookup::IsReadableSpan(
            reinterpret_cast<const void*>(slot), sizeof(uint32_t))) return false;
    const uintptr_t config = *reinterpret_cast<const uint32_t*>(slot);
    if (config == 0 || (config & 3u) != 0 ||
        !fushi_voice_hook::exact_lookup::IsReadableSpan(
            reinterpret_cast<const void*>(config), legacy ? 0x98 : 0x84)) return false;
    *width = *reinterpret_cast<const int32_t*>(config + (legacy ? 0x90 : 0x7c));
    *height = *reinterpret_cast<const int32_t*>(config + (legacy ? 0x94 : 0x80));
    return fushi_voice_hook::siglus_viewport::ValidDesignSize(*width, *height);
  } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

bool ResolveSiglusLiveFamily(HMODULE module,
                             fushi_voice_hook::SiglusLookupProfile* profile) {
  __try {
    fushi_voice_hook::exact_lookup::LoadedPeImage image;
    if (!fushi_voice_hook::OpenSiglusLoadedImage(module, &image))
      return false;
    const HMODULE user32 = GetModuleHandleW(L"user32.dll");
    const auto key_state = user32 == nullptr ? nullptr :
        GetProcAddress(user32, "GetKeyState");
    const uintptr_t key_iat =
        fushi_voice_hook::siglus_viewport::FindGetKeyStateImport(
            image, reinterpret_cast<uintptr_t>(key_state));
    fushi_voice_hook::SiglusLookupProfile luna_profile, native_profile;
    const bool luna_matched = key_iat != 0 &&
        fushi_voice_hook::ResolveSiglusFamilyProfile(image, key_iat, &luna_profile);
    const bool native_matched = key_state != nullptr &&
        fushi_voice_hook::ResolveSiglusNativeFamilyProfile(
            image, reinterpret_cast<uintptr_t>(key_state), &native_profile);
    const auto verified_import = [&](const char* name) -> uintptr_t {
      return user32 == nullptr ? 0 :
          fushi_voice_hook::siglus_viewport::FindVerifiedUser32Import(
              image, name, reinterpret_cast<uintptr_t>(GetProcAddress(user32, name)));
    };
    const siglus_legacy_input::Imports legacy_imports = {
        verified_import("GetKeyboardState"), verified_import("GetCursorPos"),
        verified_import("GetActiveWindow"), verified_import("ScreenToClient")};
    fushi_voice_hook::LegacyGlyphSites glyph_sites;
    siglus_legacy_input::Sites input_sites;
    siglus_legacy_owner::Sites owner_sites;
    const bool legacy_matched =
        fushi_voice_hook::ResolveSiglusLegacyGlyphSites(image, &glyph_sites) &&
        siglus_legacy_input::Resolve(image, legacy_imports, &input_sites) &&
        siglus_legacy_owner::Resolve(image, glyph_sites, input_sites, &owner_sites);
    // Complete families are mutually exclusive; no digest or scan order
    // may choose between ambiguous contracts.
    if (!fushi_voice_hook::HasUniqueSiglusLookupFamily(
            luna_matched, native_matched, legacy_matched)) return false;
    if (legacy_matched) {
      siglus_legacy_live::Snapshot snapshot;
      if (!siglus_legacy_live::ReadSnapshot(reinterpret_cast<uintptr_t>(module),
              input_sites, ReadSiglusLegacyMemory, nullptr, &snapshot)) return false;
      *profile = {};
      profile->pe_machine = IMAGE_FILE_MACHINE_I386;
      profile->pointer_bits = 32;
      profile->text_feed = fushi_voice_hook::SiglusLookupTextFeed::kLunaScenarioLane;
      profile->glyph_abi = fushi_voice_hook::SiglusGlyphLayoutAbi::kStackSixteenArguments;
      profile->glyph_layout_rva = glyph_sites.glyph_entry_rva;
      profile->dialogue_glyph_return_rva = glyph_sites.dialogue_glyph_return_rva;
      profile->exact_text_rva = glyph_sites.text_entry_rva;
      profile->exact_text_return_rva = glyph_sites.text_bridge_return_rva;
      profile->input_message_rva = input_sites.message;
      profile->main_input_message_return_rva = input_sites.main_message_return;
      profile->get_keyboard_state_return_rva = input_sites.keyboard_state_return;
      profile->viewport_config_rva = input_sites.config_slot;
      profile->viewport_width = snapshot.design_width;
      profile->viewport_height = snapshot.design_height;
      g_siglus_legacy_input_sites = input_sites;
      g_siglus_legacy_glyph_sites = glyph_sites;
      g_siglus_legacy_owner_sites = owner_sites;
      return true;
    }
    *profile = luna_matched ? luna_profile : native_profile;
    const uintptr_t config = luna_matched
        ? fushi_voice_hook::siglus_viewport::ResolveConfigSlot(image)
        : fushi_voice_hook::siglus_native_viewport::ResolveNativeConfigSlot(image);
    if (config == 0) return false;
    profile->viewport_config_rva = config;
    return ReadSiglusDesignSize(module, config, &profile->viewport_width,
                                &profile->viewport_height);
  } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

bool SameSiglusMeasuredAnchors(const fushi_voice_hook::SiglusLookupProfile& lhs,
                                const fushi_voice_hook::SiglusLookupProfile& rhs) {
  return lhs.text_feed == rhs.text_feed && lhs.glyph_abi == rhs.glyph_abi &&
      lhs.glyph_layout_rva == rhs.glyph_layout_rva &&
      lhs.dialogue_glyph_return_rva == rhs.dialogue_glyph_return_rva &&
      lhs.exact_text_rva == rhs.exact_text_rva &&
      lhs.exact_text_return_rva == rhs.exact_text_return_rva &&
      lhs.get_key_state_return_rva == rhs.get_key_state_return_rva &&
      lhs.get_keyboard_state_return_rva == rhs.get_keyboard_state_return_rva &&
      lhs.input_message_rva == rhs.input_message_rva &&
      lhs.main_input_message_return_rva == rhs.main_input_message_return_rva;
}

bool IsSiglusLookupProfileMatched() {
  const LONG cached =
      InterlockedCompareExchange(&g_siglus_lookup_profile_state, 0, 0);
  if (cached != 0) return cached == 1;
  if (InterlockedCompareExchange(&g_siglus_lookup_profile_state, 2, 0) != 0)
    return false;
  const ULONGLONG now = GetTickCount64();
  if (g_siglus_family_first_scan == 0) g_siglus_family_first_scan = now;
  // Protected launches expose the real code only after startup. Scans are
  // bounded and rate-limited; no hook is installed until the full proof exists.
  if (g_siglus_family_last_scan != 0 && now-g_siglus_family_last_scan < 500) {
    InterlockedExchange(&g_siglus_lookup_profile_state, 0);
    return false;
  }
  g_siglus_family_last_scan = now;
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
  const bool executable_read = !g_siglus_digest_attempted &&
      chars != 0 && chars < sizeof(executable) / sizeof(executable[0]) &&
      Sha256FileForSiglusLookup(executable, &digest);
  bool hash_matched = false;
  bool machine_matched = false;
  for (const auto *candidate : fushi_voice_hook::kSiglusLookupProfiles) {
    if (candidate == nullptr)
      continue;
    machine_matched = machine_matched || machine == candidate->pe_machine;
    hash_matched =
        hash_matched ||
        (executable_read && fushi_voice_hook::MatchesSiglusLookupDigest(
                                *candidate, digest.data(), digest.size()));
  }
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
  // 摘要已经在上面算出来了，顺手留一份十六进制给 host——身份不符时用户要靠它报版本。
  // 只在真读到 exe 时写；读不到就留空串，让 host 说"算不出"而不是显示一串零。
  if (executable_read) {
    fushi_voice_hook::FormatSha256Hex(digest.data(), digest.size(),
                                      g_siglus_lookup_executable_sha256,
                                      sizeof(g_siglus_lookup_executable_sha256));
    // 同一串摘要再交共享槽一份。私有缓冲不能删：本家 probe() 是 IsSiglusEngine()
    // （引擎探测），hash 不符时**仍然被问话**，那条 IdentityRejected 是活路径，要带上
    // 自己的摘要。共享槽服务的是另一档——谁都没认领时的收敛（见 host_executable_digest.h）。
    fushi_voice_hook::PublishHostExecutableSha256(digest.data(), digest.size());
  }
  if (executable_read) {
    g_siglus_digest_attempted = true;
    g_siglus_measured_profile = fushi_voice_hook::FindSiglusLookupProfile(
        digest.data(), digest.size(), machine);
  }
  const fushi_voice_hook::SiglusLookupProfile* profile = nullptr;
  // Digests corroborate previously measured sites; neither ABI is admitted
  // by its title/hash. Every active profile comes from the live structural proof.
  if (machine == IMAGE_FILE_MACHINE_I386 && IsSiglusEngine() &&
             ResolveSiglusLiveFamily(module, &g_siglus_family_profile) &&
             (g_siglus_measured_profile == nullptr ||
              SameSiglusMeasuredAnchors(g_siglus_family_profile,
                                        *g_siglus_measured_profile))) {
    profile = &g_siglus_family_profile;
    InterlockedExchange(&g_siglus_exact_binary_structure_state, 1);
  }
  const bool matched = profile != nullptr;
  g_siglus_lookup_profile.store(profile, std::memory_order_release);
  const bool finished = machine != IMAGE_FILE_MACHINE_I386 ||
      !IsSiglusEngine() ||
      now-g_siglus_family_first_scan >= 120000;
  InterlockedExchange(&g_siglus_lookup_profile_state,
                       matched ? 1 : (finished ? -1 : 0));
  if (matched) {
    SetSiglusLookupDiag(fushi_voice_hook::kLookupDiagSiglusProfileMatched);
  }
  return matched;
}

bool IsSiglusExactBinaryStructureMatched(
    const fushi_voice_hook::SiglusLookupProfile *profile, HMODULE module) {
  if (profile == nullptr || module == nullptr)
    return false;
  const LONG cached = InterlockedCompareExchange(
      &g_siglus_exact_binary_structure_state, 0, 0);
  if (cached != 0)
    return cached > 0;

  fushi_voice_hook::exact_lookup::LoadedPeImage image;
  const auto *input_pattern =
      fushi_voice_hook::siglus_exact::InputMessagePatternForProfile(*profile);
  const bool opened =
      input_pattern != nullptr &&
      fushi_voice_hook::exact_lookup::OpenLoadedPeImage(module, &image) &&
      image.machine == IMAGE_FILE_MACHINE_I386 && image.pointer_bits == 32u;
  fushi_voice_hook::exact_lookup::UniquePatternMatch glyph;
  fushi_voice_hook::exact_lookup::UniquePatternMatch input;
  if (opened) {
    glyph = fushi_voice_hook::exact_lookup::
        FindUniquePatternInExecutableSections(
            image,
            fushi_voice_hook::siglus_exact::kGlyphLayoutEntryPattern);
    input = fushi_voice_hook::exact_lookup::
        FindUniquePatternInExecutableSections(image, *input_pattern);
  }
  const uintptr_t base = reinterpret_cast<uintptr_t>(module);
  const auto executable_rva = [&image](uintptr_t rva, size_t bytes = 1u) {
    return fushi_voice_hook::exact_lookup::SectionHasRole(
        fushi_voice_hook::exact_lookup::FindSectionForRva(image, rva, bytes),
        IMAGE_SCN_MEM_EXECUTE);
  };
  const bool exact_text_call_valid =
      profile->exact_text_return_rva == 0u ||
      (executable_rva(profile->exact_text_return_rva) &&
       fushi_voice_hook::exact_lookup::MatchesRel32CallEndingAt(
           image, profile->exact_text_return_rva, profile->exact_text_rva));
  const bool matched =
      opened && executable_rva(profile->glyph_layout_rva) &&
      executable_rva(profile->dialogue_glyph_return_rva) &&
      executable_rva(profile->exact_text_rva) &&
      executable_rva(profile->get_key_state_return_rva) &&
      executable_rva(profile->input_message_rva) &&
      executable_rva(profile->main_input_message_return_rva) &&
      glyph.count == 1u &&
      reinterpret_cast<uintptr_t>(glyph.address) ==
          base + profile->glyph_layout_rva &&
      fushi_voice_hook::siglus_exact::IsMeasuredGlyphStackSize(
          glyph.address) &&
      input.count == 1u &&
      reinterpret_cast<uintptr_t>(input.address) ==
          base + profile->input_message_rva &&
      fushi_voice_hook::exact_lookup::MatchesRel32CallEndingAt(
          image, profile->dialogue_glyph_return_rva,
          profile->glyph_layout_rva) &&
      exact_text_call_valid &&
      fushi_voice_hook::exact_lookup::MatchesExecutableCallEndingAt(
          image, profile->get_key_state_return_rva) &&
      fushi_voice_hook::exact_lookup::MatchesRel32CallEndingAt(
          image, profile->main_input_message_return_rva,
          profile->input_message_rva);
  InterlockedExchange(&g_siglus_exact_binary_structure_state,
                      matched ? 1 : -1);
  return matched;
}

bool MatchesSiglusGlyphLayoutEntry(const uint8_t *target) {
  const auto* profile = ActiveSiglusLookupProfile();
  if (profile != nullptr && IsLegacySiglusLookup(*profile)) {
    const auto pattern = fushi_voice_hook::siglus_legacy_glyph::kGlyphEntry.pattern();
    return fushi_voice_hook::exact_lookup::IsReadableSpan(target, pattern.size) &&
        fushi_voice_hook::exact_lookup::MatchesMaskedPattern(target, pattern);
  }
  return fushi_voice_hook::exact_lookup::IsReadableSpan(
             target,
             fushi_voice_hook::siglus_exact::kGlyphLayoutEntryPattern.size) &&
         fushi_voice_hook::exact_lookup::MatchesMaskedPattern(
             target,
             fushi_voice_hook::siglus_exact::kGlyphLayoutEntryPattern) &&
         fushi_voice_hook::siglus_exact::IsMeasuredGlyphStackSize(target);
}

bool MatchesSiglusInputMessageEntry(const uint8_t *target) {
  const auto *profile = ActiveSiglusLookupProfile();
  if (profile != nullptr && IsLegacySiglusLookup(*profile)) {
    const auto pattern = siglus_legacy_input::kMessage.pattern();
    return fushi_voice_hook::exact_lookup::IsReadableSpan(target, pattern.size) &&
        fushi_voice_hook::exact_lookup::MatchesMaskedPattern(target, pattern);
  }
  const auto *pattern =
      profile == nullptr
          ? nullptr
          : fushi_voice_hook::siglus_exact::InputMessagePatternForProfile(
                *profile);
  return pattern != nullptr &&
         fushi_voice_hook::exact_lookup::IsReadableSpan(target,
                                                        pattern->size) &&
         fushi_voice_hook::exact_lookup::MatchesMaskedPattern(target,
                                                              *pattern);
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

#include "siglus_lookup_glyph.inc"

#include "siglus_lookup_text_snapshot.inc"

void ObserveSiglusLookupExactText(const wchar_t *text, uint32_t text_units,
                                  uint64_t callsite_rva,
                                  uintptr_t function_rva,
                                  uint64_t text_event_id, uint64_t thread_id) {
  const auto *profile = ActiveSiglusLookupProfile();
  if (!g_siglus_lookup_capture_enabled.load(std::memory_order_acquire) ||
      profile == nullptr ||
      profile->text_feed !=
          fushi_voice_hook::SiglusLookupTextFeed::kNativeEcxTextUnion ||
      callsite_rva != profile->exact_text_return_rva ||
      function_rva != profile->exact_text_rva) {
    return;
  }
  PublishSiglusLookupTextSnapshot(text, text_units, {text_event_id, thread_id});
}

void ConsumeSiglusLookupLunaScenarioText() {
  // The profile describes the scenario ABI. Its immutable admission is shared
  // by Luna fallback and the native message observer; only its actual owner
  // may publish text snapshots for the current occurrence.
  if (IsSiglusMessageTextInstalled() || IsSiglusMessageTextOwnershipBlocked())
    return;
  const auto *profile = ActiveSiglusLookupProfile();
  if (!g_siglus_lookup_capture_enabled.load(std::memory_order_acquire) ||
      profile == nullptr ||
      profile->text_feed !=
          fushi_voice_hook::SiglusLookupTextFeed::kLunaScenarioLane ||
      g_header == nullptr) {
    return;
  }
  const uintptr_t module =
      reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr));
  if (module == 0)
    return;

  const fushi_voice_hook::TextSlot
      *slots[fushi_voice_hook::kTextSlotCount] = {};
  const uint32_t found = fushi_voice_hook::CollectTextSlotsBySeq(
      g_header, slots, fushi_voice_hook::kTextSlotCount,
      g_siglus_lookup_luna_text_processed_seq);
  uint64_t processed_through = g_siglus_lookup_luna_text_processed_seq;
  SiglusLookupTextSnapshot newest = {};
  uint64_t newest_seq = 0;
  for (uint32_t index = 0; index < found; ++index) {
    const auto *slot = slots[index];
    if (slot == nullptr)
      continue;
    const uint64_t lane_before =
        fushi_voice_hook::AtomicLoadPreview64(&slot->lane_seq);
    const uint64_t global_seq =
        fushi_voice_hook::AtomicLoadPreview64(&slot->seq);
    if (lane_before == 0 || global_seq == 0)
      continue;

    const uint32_t byte_len = slot->byte_len;
    const bool target =
        slot->source_kind == fushi_voice_hook::kTextSourceLuna &&
        slot->event_kind == fushi_voice_hook::kTextEventLine &&
        slot->is_utf8 == 0 &&
        slot->thread_address == module + profile->exact_text_rva &&
        byte_len != 0 &&
        byte_len <= fushi_voice_hook::kTextSlotBytes -
                        static_cast<uint32_t>(
                            sizeof(fushi_voice_hook::TextSlot)) &&
        (byte_len % sizeof(wchar_t)) == 0 &&
        byte_len / sizeof(wchar_t) <= kSiglusLookupMaxTextUnits;
    SiglusLookupTextSnapshot candidate = {};
    if (target) {
      candidate.identity = {global_seq, slot->thread_id};
      candidate.text_units = byte_len / sizeof(wchar_t);
      const auto *payload = reinterpret_cast<const uint8_t *>(slot) +
                            sizeof(fushi_voice_hook::TextSlot);
      memcpy(candidate.text, payload, byte_len);
    }
    const uint64_t lane_after =
        fushi_voice_hook::AtomicLoadPreview64(&slot->lane_seq);
    if (lane_after != lane_before || lane_after == 0)
      continue;
    processed_through = (std::max)(processed_through, global_seq);
    if (target && global_seq > newest_seq) {
      newest = candidate;
      newest_seq = global_seq;
    }
  }
  g_siglus_lookup_luna_text_processed_seq = processed_through;
  if (newest_seq != 0)
    PublishSiglusLookupTextSnapshot(newest.text, newest.text_units, newest.identity);
}



void InvalidateSiglusLookupClickTarget() {
  const uint64_t next = static_cast<uint64_t>(
      InterlockedIncrement64(&g_siglus_lookup_click_target_count));
  InterlockedExchange64(&g_siglus_lookup_click_target.seq, 0);
  g_siglus_lookup_click_target.valid = 0;
  g_siglus_lookup_click_target.engine_view = {};
  g_siglus_lookup_click_target.published_tick = GetTickCount64();
  g_siglus_lookup_click_target.game_window = 0;
  g_siglus_lookup_click_target.client_screen_x = 0;
  g_siglus_lookup_click_target.client_screen_y = 0;
  g_siglus_lookup_click_target.client_width = 0;
  g_siglus_lookup_click_target.client_height = 0;
  g_siglus_lookup_click_target.geometry_generation = 0;
  g_siglus_lookup_click_target.text_identity = {};
  g_siglus_lookup_click_target.snapshot_epoch = 0;
  g_siglus_lookup_click_target.text_units = 0;
  g_siglus_lookup_click_target.geometry = {};
  InterlockedExchange64(&g_siglus_lookup_click_target.seq,
                        static_cast<LONG64>(next));
}

void PublishSiglusLookupClickTarget(HWND game, const POINT &client_origin,
                                    int32_t client_width,
                                    int32_t client_height) {
  fushi_voice_hook::SiglusLookupEngineView engine_view;
  if (!g_siglus_lookup_layout.current_valid ||
      !ReadSiglusLookupEngineView(game, &engine_view) ||
      !fushi_voice_hook::SameSiglusLookupEngineView(engine_view, g_siglus_lookup_engine_view) ||
      g_siglus_lookup_text_identity.event_id == 0 ||
      g_siglus_lookup_text_identity.thread_id == 0 ||
      g_siglus_lookup_layout.generation == 0 || game == nullptr ||
      client_width <= 0 || client_height <= 0 ||
      g_siglus_lookup_active_line_units == 0) {
    InvalidateSiglusLookupClickTarget();
    return;
  }
  const uint64_t next = static_cast<uint64_t>(
      InterlockedIncrement64(&g_siglus_lookup_click_target_count));
  InterlockedExchange64(&g_siglus_lookup_click_target.seq, 0);
  g_siglus_lookup_click_target.valid = 1;
  g_siglus_lookup_click_target.engine_view = engine_view;
  g_siglus_lookup_click_target.text_identity = g_siglus_lookup_text_identity;
  g_siglus_lookup_click_target.published_tick = GetTickCount64();
  g_siglus_lookup_click_target.game_window = reinterpret_cast<uintptr_t>(game);
  g_siglus_lookup_click_target.client_screen_x = client_origin.x;
  g_siglus_lookup_click_target.client_screen_y = client_origin.y;
  g_siglus_lookup_click_target.client_width = client_width;
  g_siglus_lookup_click_target.client_height = client_height;
  g_siglus_lookup_click_target.geometry_generation =
      g_siglus_lookup_layout.generation;
  g_siglus_lookup_click_target.snapshot_epoch = g_siglus_lookup_layout.snapshot_epoch;
  g_siglus_lookup_click_target.text_units = g_siglus_lookup_active_line_units;
  memcpy(g_siglus_lookup_click_target.text, g_siglus_lookup_active_line,
         static_cast<size_t>(g_siglus_lookup_active_line_units) *
             sizeof(wchar_t));
  g_siglus_lookup_click_target.geometry = g_siglus_lookup_layout.geometry;
  InterlockedExchange64(&g_siglus_lookup_click_target.seq,
                        static_cast<LONG64>(next));
}

#include "siglus_lookup_input_diagnostics.inc"
#include "siglus_lookup_click_target.inc"
#include "siglus_lookup_worker.inc"
#include "siglus_lookup_click_policy.inc"

#include "siglus_lookup_input.inc"

bool InstallSiglusLookupSensor() {
  if (!IsSiglusLookupProfileMatched())
    return false;
  const auto *profile = ActiveSiglusLookupProfile();
  if (profile == nullptr)
    return false;
  HMODULE module = GetModuleHandleW(nullptr);
  const bool legacy = IsLegacySiglusLookup(*profile);
  if (profile->viewport_config_rva != 0) {
    int32_t width = 0, height = 0;
    if (!ReadSiglusDesignSize(module, profile->viewport_config_rva, &width, &height, legacy) ||
        width != profile->viewport_width || height != profile->viewport_height) {
      g_siglus_lookup_sensor_installed.store(false, std::memory_order_release);
      RevokeSiglusSampledInputShieldReady(g_siglus_sampled_input_property_window);
      return false;
    }
  }
  if (module == nullptr ||
      !IsSiglusExactBinaryStructureMatched(profile, module))
    return false;
  const ULONGLONG now = GetTickCount64();
  const HWND cached_game =
      g_siglus_sampled_input_game_window.load(std::memory_order_acquire);
  const bool glyph_installed = legacy ? g_orig_SiglusLegacyGlyphLayout != nullptr
                                      : g_orig_SiglusGlyphLayout != nullptr;
  const bool message_installed = legacy ? g_orig_SiglusLegacyInputMessage != nullptr
                                        : g_orig_SiglusInputMessage != nullptr;
  if (glyph_installed &&
      g_orig_SiglusGetKeyState != nullptr &&
      (!legacy || g_orig_SiglusGetKeyboardState != nullptr) &&
      message_installed && cached_game != nullptr &&
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
  if (!glyph_installed) {
    auto *target = reinterpret_cast<uint8_t *>(module) +
                   profile->glyph_layout_rva;
    void* callback = legacy ? reinterpret_cast<void*>(&Detour_SiglusLegacyGlyphLayout)
                            : reinterpret_cast<void*>(&Detour_SiglusGlyphLayout);
    void** original = legacy ? reinterpret_cast<void**>(&g_orig_SiglusLegacyGlyphLayout)
                              : reinterpret_cast<void**>(&g_orig_SiglusGlyphLayout);
    if (!MatchesSiglusGlyphLayoutEntry(target) ||
        !HookFn(target, callback, original) || *original == nullptr) {
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
  if (legacy && g_orig_SiglusGetKeyboardState == nullptr) {
    const HMODULE user32 = GetModuleHandleW(L"user32.dll");
    void* target = user32 == nullptr ? nullptr :
        reinterpret_cast<void*>(GetProcAddress(user32, "GetKeyboardState"));
    if (target == nullptr ||
        !HookFn(target, reinterpret_cast<void*>(&Detour_SiglusGetKeyboardState),
                reinterpret_cast<void**>(&g_orig_SiglusGetKeyboardState)) ||
        g_orig_SiglusGetKeyboardState == nullptr) {
      RevokeSiglusSampledInputShieldReady(g_siglus_sampled_input_property_window);
      return false;
    }
  }
  if (!message_installed) {
    auto *target = reinterpret_cast<uint8_t *>(module) +
                   profile->input_message_rva;
    void* callback = legacy ? reinterpret_cast<void*>(&Detour_SiglusLegacyInputMessage)
                            : reinterpret_cast<void*>(&Detour_SiglusInputMessage);
    void** original = legacy ? reinterpret_cast<void**>(&g_orig_SiglusLegacyInputMessage)
                              : reinterpret_cast<void**>(&g_orig_SiglusInputMessage);
    if (!MatchesSiglusInputMessageEntry(target) ||
        !HookFn(target, callback, original) || *original == nullptr) {
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
  g_siglus_lookup_sensor_installed.store(true, std::memory_order_release);
  return true;
}

// v19 admission queries share the serialized family resolver. Only the first
// successful proof is published; pending initialization remains undecided.
fushi_voice_hook::LookupAdmissionReport SiglusLookupAdmission() {
  fushi_voice_hook::LookupAdmissionReport report;
  if (!IsSiglusLookupProfileMatched()) {
    report.state = IsSiglusLookupIdentityUndecided()
        ? fushi_voice_hook::kLookupAdmissionUnknown
        : fushi_voice_hook::kLookupAdmissionIdentityRejected;
    std::memcpy(report.executable_sha256, g_siglus_lookup_executable_sha256,
                sizeof(report.executable_sha256));
    return report;
  }
  report.state =
      g_siglus_lookup_sensor_installed.load(std::memory_order_acquire)
          ? fushi_voice_hook::kLookupAdmissionSensorInstalled
          : fushi_voice_hook::kLookupAdmissionIdentityAccepted;
  return report;
}

void SetSiglusLookupRuntimeEnabled(bool enabled) {
  const bool previous = g_siglus_lookup_click_runtime_enabled.exchange(
      enabled, std::memory_order_acq_rel);
  g_siglus_lookup_capture_enabled.store(enabled, std::memory_order_release);
  if (enabled && !previous) {
    g_siglus_lookup_click_epoch.fetch_add(1, std::memory_order_acq_rel);
  }
}


void ProcessSiglusLookupTick() {
  if (g_stop || g_header == nullptr ||
      !fushi_voice_hook::HasLookupRegion(g_header) ||
      g_header->lookup_enabled == 0) {
    if (g_header != nullptr) {
      fushi_voice_hook::g_geometry_provider_registry.Retire(
          g_header,
          fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
          fushi_voice_hook::kLookupGeometryProviderIdSiglus);
    }
    SetSiglusLookupRuntimeEnabled(false);
    g_siglus_lookup_last_shift_down = false;
    ResetSiglusLookupRuntimeLayout();
    return;
  }
  if (!InstallSiglusLookupSensor()) {
    fushi_voice_hook::g_geometry_provider_registry.Retire(
        g_header,
        fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
        fushi_voice_hook::kLookupGeometryProviderIdSiglus);
    SetSiglusLookupRuntimeEnabled(false);
    ResetSiglusLookupRuntimeLayout();
    return;
  }
  SetSiglusLookupRuntimeEnabled(true);
  // Window health is required even while a split redraw has no current click
  // geometry. A missing/empty client cannot inherit a prior lifetime.
  HWND game = FindGameMainWindow();
  RECT client = {};
  POINT origin = {0, 0};
  if (game == nullptr || !IsWindow(game) || !GetClientRect(game, &client) ||
      client.right <= client.left || client.bottom <= client.top ||
      !ClientToScreen(game, &origin)) {
    fushi_voice_hook::g_geometry_provider_registry.Retire(
        g_header, fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
        fushi_voice_hook::kLookupGeometryProviderIdSiglus);
    ResetSiglusLookupRuntimeLayout();
    return;
  }
  if (g_siglus_lookup_layout_window != nullptr &&
      g_siglus_lookup_layout_window != game) {
    fushi_voice_hook::g_geometry_provider_registry.Retire(
        g_header, fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
        fushi_voice_hook::kLookupGeometryProviderIdSiglus);
    ResetSiglusLookupRuntimeLayout();
  }
  g_siglus_lookup_layout_window = game;
  fushi_voice_hook::SiglusLookupEngineView engine_view;
  if (!ReadSiglusLookupEngineView(game, &engine_view) ||
      !RefreshSiglusLegacyGlyphOwners()) {
    fushi_voice_hook::g_geometry_provider_registry.Retire(
        g_header, fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
        fushi_voice_hook::kLookupGeometryProviderIdSiglus);
    ResetSiglusLookupRuntimeLayout();
    return;
  }
  if (!fushi_voice_hook::SameSiglusLookupEngineView(engine_view, g_siglus_lookup_engine_view)) {
    ResetSiglusLookupRuntimeLayout();
    g_siglus_lookup_layout_window = game;
  }
  g_siglus_lookup_engine_view = engine_view;
  ConsumeSiglusLookupCaptures();

  if (g_siglus_lookup_layout.line_has_complete_layout &&
      g_siglus_lookup_text_identity.event_id != 0 &&
      g_siglus_lookup_text_identity.thread_id != 0) {
    fushi_voice_hook::g_geometry_provider_registry.OfferReady(
        g_header,
        fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
        fushi_voice_hook::kLookupGeometryProviderIdSiglus);
  } else {
    fushi_voice_hook::g_geometry_provider_registry.Retire(
        g_header,
        fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
        fushi_voice_hook::kLookupGeometryProviderIdSiglus);
  }

  const bool click_submitted = ProcessSiglusLookupClickSubmissions();

  const uint16_t shift_state =
      static_cast<uint16_t>(GetAsyncKeyState(VK_SHIFT));
  const bool shift_submit = fushi_voice_hook::ConsumeSiglusLookupShiftSample(
      shift_state, &g_siglus_lookup_last_shift_down);
  if (!g_siglus_lookup_layout.current_valid) {
    InvalidateSiglusLookupClickTarget();
    return;
  }
  POINT cursor = {};
  if (!GetCursorPos(&cursor)) {
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
  if (g_header != nullptr) {
    fushi_voice_hook::g_geometry_provider_registry.Retire(
        g_header,
        fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
        fushi_voice_hook::kLookupGeometryProviderIdSiglus);
  }
  SetSiglusLookupRuntimeEnabled(false);
  g_siglus_lookup_message_left_button_latched.store(false,
                                                    std::memory_order_release);
  ResetSiglusLookupRuntimeLayout();
  // Keep Required on this exact Siglus process.  A later/older host must fail
  // closed until a live GetKeyState detour republishes Ready; dropping Required
  // would silently re-enable the HHOOK-only path disproved on the real game.
  RevokeSiglusSampledInputShieldReady(g_siglus_sampled_input_property_window);
}

#else

bool IsSiglusLookupProfileMatched() { return false; }
bool IsSiglusLookupIdentityUndecided() { return false; }
bool ShouldReserveSiglusKeyboardState() { return false; }
void ProcessSiglusLookupTick() {}
void ShutdownSiglusLookup() {}

// x64 构建里 Siglus 查词传感器整个不存在（所有 profile 都是 x86 的）。报
// EngineUnsupported 而不是 IdentityRejected——后者会让用户以为"换个版本的游戏就行"，
// 而真相是这个 helper 架构下根本没有这条路。
fushi_voice_hook::LookupAdmissionReport SiglusLookupAdmission() {
  fushi_voice_hook::LookupAdmissionReport report;
  report.state = fushi_voice_hook::kLookupAdmissionEngineUnsupported;
  return report;
}

#endif // _M_IX86
