// Exact WHITE ALBUM2 (Leaf/AQUAPLUS) adapter.  Engine-family names and *.pak
// signatures never enable offsets: the one admitted x86 executable digest is
// kept in leaf_aquaplus_profile.h.
#include "leaf_aquaplus_profile.h"

#include <d3d9.h>

volatile LONG g_leaf_aquaplus_profile_state =
    0; // 0 unknown, +1 match, -1 reject
std::atomic<const fushi_voice_hook::LeafAquaplusProfile *>
    g_leaf_aquaplus_profile{nullptr};

using LeafDrawPrimitiveUPFn = HRESULT(STDMETHODCALLTYPE *)(IDirect3DDevice9 *,
                                                           D3DPRIMITIVETYPE,
                                                           UINT, const void *,
                                                           UINT);
using LeafPresentFn = HRESULT(STDMETHODCALLTYPE *)(IDirect3DDevice9 *,
                                                   const RECT *, const RECT *,
                                                   HWND, const RGNDATA *);
using LeafSetTextureFn = HRESULT(STDMETHODCALLTYPE *)(IDirect3DDevice9 *, DWORD,
                                                      IDirect3DBaseTexture9 *);
using LeafRasterDrawFn = int(__cdecl *)(void *, void *);
using LeafTextTraversalFn = int(__cdecl *)(
    uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t,
    uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t,
    uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t,
    uint32_t, uint32_t, uint32_t, uint32_t, uint32_t);
using LeafGetAsyncKeyStateFn = SHORT(WINAPI *)(int);

LeafDrawPrimitiveUPFn g_leaf_draw_primitive_up_original = nullptr;
LeafPresentFn g_leaf_present_original = nullptr;
LeafSetTextureFn g_leaf_set_texture_original = nullptr;
LeafRasterDrawFn g_leaf_raster_draw_original = nullptr;
LeafTextTraversalFn g_leaf_text_traversal_original = nullptr;
LeafGetAsyncKeyStateFn g_leaf_get_async_key_state_original = nullptr;
std::atomic<uint64_t> g_leaf_frame_sequence{0};
std::atomic<uint64_t> g_leaf_next_traversal_id{0};
std::atomic<uintptr_t> g_leaf_texture0{0};
std::atomic<bool> g_leaf_d3d_trace_ready{false};
std::atomic<bool> g_leaf_lookup_runtime_enabled{false};
std::atomic<uint64_t> g_leaf_sentence_epoch_atomic{0};
std::atomic<uint64_t> g_leaf_lookup_activation_epoch{1};
std::atomic<uint32_t> g_leaf_input_poller_owner_tid{0};
// 🔴 「有没有别的线程在争用 admitted poller 区间」是**当前状态**，不是一次性事实。
// 它曾被记成一个没有清除边的 bool 闩：admitted 区间是 374 字节的 RVA 区间
// （0x44a83e~0x44a9b4），WA2 的消息泵或任意二级线程碰一次就永久置位，之后整个进程
// 剩余生命周期查词全废，用户只看到「点了没反应」。改成 worker 每 tick 比较
// FushiLeafD3DTraceV1.input_poller_conflicts 这个单调计数的增量：干扰线程一停，
// 下一 tick 自动恢复；当前判定结果同时发布到 trace 的 input_poller_contended，
// 让「点了没反应」在 ring_probe 里可诊断（共享 lookup_diag 的 32 位已全部分配完，
// 新增一位需要扩 SharedHeader 布局，故落在本 profile 自己的数值 trace 上）。
uint32_t g_leaf_lookup_seen_poller_conflicts = 0;
std::atomic<bool> g_leaf_lookup_click_transaction_active{false};
volatile LONG g_leaf_d3d_trace_writer = 0;

constexpr size_t kLeafLookupTextUnits =
    fushi_voice_hook::kLeafAquaplusLookupMaxTextUnits;
constexpr size_t kLeafLookupCandidateSlots = 16u;
constexpr size_t kLeafPrivateTraversalSlots = 16u;
constexpr size_t kLeafLookupClickEventSlots = 4u;
constexpr ULONGLONG kLeafLookupClickTargetMaxAgeMs = 80u;
constexpr ULONGLONG kLeafLookupDuplicateHitWindowMs = 250u;
constexpr ULONGLONG kLeafSampledInputHealthIntervalMs = 1000u;

struct LeafLookupGeometry {
  uint64_t sentence_epoch = 0;
  uint64_t generation = 0;
  uint32_t text_units = 0;
  uint32_t glyph_count = 0;
  int32_t viewport_x = 0;
  int32_t viewport_y = 0;
  int32_t viewport_width = 0;
  int32_t viewport_height = 0;
  wchar_t text[kLeafLookupTextUnits] = {};
  fushi_voice_hook::LeafAquaplusLookupGlyph glyphs[kLeafLookupTextUnits] = {};
};

struct LeafLookupBatchCandidate {
  uint64_t traversal_id = 0;
  uint64_t frame_sequence = 0;
  uint64_t sentence_epoch = 0;
  uint64_t traversal_sequence = 0;
  uint32_t glyph_count = 0;
  int32_t viewport_x = 0;
  int32_t viewport_y = 0;
  int32_t viewport_width = 0;
  int32_t viewport_height = 0;
  fushi_voice_hook::LeafAquaplusLookupGlyph glyphs[kLeafLookupTextUnits] = {};
};

struct LeafLookupPayload {
  uint64_t activation_epoch = 0;
  uint64_t sentence_epoch = 0;
  uint64_t geometry_generation = 0;
  uint32_t text_units = 0;
  uint32_t char_index = 0;
  fushi_voice_hook::LeafAquaplusLookupRect rect;
  int32_t client_width = 0;
  int32_t client_height = 0;
  wchar_t text[kLeafLookupTextUnits] = {};
};

struct alignas(8) LeafLookupClickTarget {
  volatile LONG64 seq = 0;
  uint32_t valid = 0;
  ULONGLONG published_tick = 0;
  uintptr_t game_window = 0;
  int32_t client_screen_x = 0;
  int32_t client_screen_y = 0;
  int32_t client_width = 0;
  int32_t client_height = 0;
  LeafLookupGeometry geometry;
};

struct alignas(8) LeafLookupClickEvent {
  volatile LONG64 seq = 0;
  LeafLookupPayload payload;
};

uint64_t g_leaf_text_processed_seq = 0;
uint64_t g_leaf_trace_processed_seq = 0;
uint64_t g_leaf_sentence_epoch = 0;
uint64_t g_leaf_sentence_trace_floor = 0;
uint64_t g_leaf_active_line_timestamp_ms = 0;
uint64_t g_leaf_geometry_generation = 0;
uint64_t g_leaf_selected_thread_id = 0;
uint64_t g_leaf_selected_face_id = 0;
bool g_leaf_replay_recent_trace_for_next_line = false;
fushi_voice_hook::LeafAquaplusLookupShiftState g_leaf_lookup_shift_state;
wchar_t g_leaf_active_line[kLeafLookupTextUnits] = {};
uint32_t g_leaf_active_line_units = 0;
LeafLookupGeometry g_leaf_active_geometry;
bool g_leaf_active_geometry_valid = false;
LeafLookupBatchCandidate g_leaf_lookup_candidates[kLeafLookupCandidateSlots] =
    {};

LeafLookupClickTarget g_leaf_lookup_click_target;
volatile LONG64 g_leaf_lookup_click_target_count = 0;
LeafLookupClickEvent g_leaf_lookup_click_events[kLeafLookupClickEventSlots] =
    {};
volatile LONG64 g_leaf_lookup_click_event_count = 0;
uint64_t g_leaf_lookup_click_processed_seq = 0;
uint64_t g_leaf_last_hit_identity = 0;
ULONGLONG g_leaf_last_hit_tick = 0;

// Mutated only by WA2's admitted GetAsyncKeyState poller.
fushi_voice_hook::LeafAquaplusLookupClickSampleState
    g_leaf_lookup_click_sample_state;
LeafLookupClickTarget g_leaf_lookup_click_read_target;
LeafLookupPayload g_leaf_lookup_pending_click;
bool g_leaf_lookup_pending_click_valid = false;
uint64_t g_leaf_lookup_poller_activation_epoch = 0;
fushi_voice_hook::LeafAquaplusSampledInputTailState
    g_leaf_sampled_input_tail_state;
std::atomic<uint8_t> g_leaf_sampled_input_latched_buttons{0};

std::atomic<HWND> g_leaf_sampled_input_game_window{nullptr};
HWND g_leaf_sampled_input_property_window = nullptr;
ULONGLONG g_leaf_sampled_input_last_health_tick = 0;

void SetLeafLookupDiag(uint32_t bits) {
  if (g_header == nullptr)
    return;
  InterlockedOr(reinterpret_cast<volatile LONG *>(&g_header->lookup_diag),
                static_cast<LONG>(bits));
}

HWND GetValidPublishedLeafSampledInputShieldPopup(HWND game) {
  if (game == nullptr)
    return nullptr;
  const HWND popup = reinterpret_cast<HWND>(GetPropW(
      game, fushi_voice_hook::kLeafAquaplusSampledInputShieldWindowProperty));
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

bool IsLeafSampledInputShieldReadyPublished(HWND game) {
  return game != nullptr &&
         reinterpret_cast<uintptr_t>(GetPropW(
             game,
             fushi_voice_hook::kLeafAquaplusSampledInputShieldReadyProperty)) ==
             fushi_voice_hook::kLeafAquaplusSampledInputShieldReadyValue;
}

void RevokeLeafSampledInputShieldReady(HWND game) {
  if (game != nullptr && IsWindow(game)) {
    // Ready is the publication commit fence. Revoke it before Window/Tail so
    // a host racing through its Ready -> SetProp(Window) -> Ready validation
    // cannot commit a popup while this helper is tearing the contract down.
    RemovePropW(game,
                fushi_voice_hook::kLeafAquaplusSampledInputShieldReadyProperty);
    RemovePropW(
        game, fushi_voice_hook::kLeafAquaplusSampledInputShieldWindowProperty);
    RemovePropW(
        game,
        fushi_voice_hook::kLeafAquaplusSampledInputShieldTailRequestProperty);
    RemovePropW(
        game, fushi_voice_hook::kLeafAquaplusSampledInputShieldTailAckProperty);
  }
  g_leaf_sampled_input_game_window.store(nullptr, std::memory_order_release);
  g_leaf_sampled_input_last_health_tick = 0;
  if (g_header != nullptr) {
    InterlockedAnd(reinterpret_cast<volatile LONG *>(&g_header->lookup_diag),
                   static_cast<LONG>(
                       ~fushi_voice_hook::kLookupDiagSampledInputShieldReady));
  }
}

bool RefreshLeafSampledInputPropertyWindow() {
  const HWND previous = g_leaf_sampled_input_property_window;
  const HWND current = FindGameMainWindow();
  if (current == nullptr) {
    if (previous != nullptr && IsWindow(previous))
      return true;
    RevokeLeafSampledInputShieldReady(previous);
    g_leaf_sampled_input_property_window = nullptr;
    return false;
  }
  if (current == previous)
    return true;
  if (GetValidPublishedLeafSampledInputShieldPopup(previous) != nullptr) {
    return true;
  }
  RevokeLeafSampledInputShieldReady(previous);
  if (previous != nullptr && IsWindow(previous)) {
    RemovePropW(
        previous,
        fushi_voice_hook::kLeafAquaplusSampledInputShieldRequiredProperty);
  }
  g_leaf_sampled_input_property_window = current;
  return true;
}

bool PublishLeafSampledInputShieldRequired() {
  const HWND game = g_leaf_sampled_input_property_window;
  if (game == nullptr || !IsWindow(game))
    return false;
  if (reinterpret_cast<uintptr_t>(GetPropW(
          game,
          fushi_voice_hook::kLeafAquaplusSampledInputShieldRequiredProperty)) ==
      fushi_voice_hook::kLeafAquaplusSampledInputShieldRequiredValue) {
    return true;
  }
  return SetPropW(
             game,
             fushi_voice_hook::kLeafAquaplusSampledInputShieldRequiredProperty,
             reinterpret_cast<HANDLE>(
                 fushi_voice_hook::
                     kLeafAquaplusSampledInputShieldRequiredValue)) != FALSE;
}

bool PublishLeafSampledInputShieldReady() {
  const HWND game = g_leaf_sampled_input_property_window;
  if (game == nullptr || !IsWindow(game))
    return false;
  g_leaf_sampled_input_game_window.store(game, std::memory_order_release);
  if (reinterpret_cast<uintptr_t>(GetPropW(
          game,
          fushi_voice_hook::kLeafAquaplusSampledInputShieldReadyProperty)) !=
          fushi_voice_hook::kLeafAquaplusSampledInputShieldReadyValue &&
      !SetPropW(
          game, fushi_voice_hook::kLeafAquaplusSampledInputShieldReadyProperty,
          reinterpret_cast<HANDLE>(
              fushi_voice_hook::kLeafAquaplusSampledInputShieldReadyValue))) {
    g_leaf_sampled_input_game_window.store(nullptr, std::memory_order_release);
    g_leaf_sampled_input_last_health_tick = 0;
    return false;
  }
  g_leaf_sampled_input_last_health_tick = GetTickCount64();
  SetLeafLookupDiag(fushi_voice_hook::kLookupDiagSampledInputShieldReady);
  return true;
}

struct LeafPrivateGlyphRecord {
  uint16_t packed_cp932 = 0;
  uint16_t draw_format = 0;
  uint32_t caller_rva = 0;
  uint32_t vertex_stride = 0;
  uint32_t fvf = 0;
  uint64_t texture0 = 0;
  float left = 0.0f;
  float top = 0.0f;
  float right = 0.0f;
  float bottom = 0.0f;
};

struct LeafPrivateTraversal {
  uint64_t sequence = 0;
  uint64_t timestamp_ms = 0;
  uint64_t frame_sequence = 0;
  uint64_t traversal_id = 0;
  uint64_t sentence_epoch_at_capture = 0;
  uint32_t glyph_count = 0;
  int32_t viewport_x = 0;
  int32_t viewport_y = 0;
  int32_t viewport_width = 0;
  int32_t viewport_height = 0;
  LeafPrivateGlyphRecord glyphs[kLeafLookupTextUnits] = {};
};

struct alignas(8) LeafPrivateTraversalSlot {
  volatile LONG writing = 0;
  uint32_t reserved = 0;
  LeafPrivateTraversal traversal;
};

struct LeafTextTraversalCapture {
  bool active = false;
  bool invalid = false;
  uint32_t suppression_depth = 0;
  LeafPrivateTraversal traversal;
};

struct LeafRasterCapture {
  bool active = false;
  bool invalid = false;
  bool bounds_ready = false;
  uint16_t packed_cp932 = 0;
  uint16_t draw_format = 0;
  uint32_t caller_rva = 0;
  uint32_t vertex_stride = 0;
  uint32_t fvf = 0;
  uint64_t texture0 = 0;
  uint64_t frame_sequence = 0;
  int32_t viewport_x = 0;
  int32_t viewport_y = 0;
  int32_t viewport_width = 0;
  int32_t viewport_height = 0;
  float left = 0.0f;
  float top = 0.0f;
  float right = 0.0f;
  float bottom = 0.0f;
};

thread_local LeafTextTraversalCapture g_leaf_text_traversal_capture;
thread_local LeafRasterCapture g_leaf_raster_capture;
alignas(8) LeafPrivateTraversalSlot
    g_leaf_private_traversal_slots[kLeafPrivateTraversalSlots] = {};
alignas(8) volatile LONG64 g_leaf_private_traversal_next_sequence = 0;
volatile LONG g_leaf_private_traversal_writer = 0;
LeafPrivateTraversal g_leaf_private_traversal_read_copy;

bool Sha256FileForLeafAquaplus(const wchar_t *path,
                               std::array<uint8_t, 32> *digest) {
  if (path == nullptr || digest == nullptr)
    return false;
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
         file_size.QuadPart <= static_cast<LONGLONG>(0xffffffffull);
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

bool IsLeafAquaplusProfileMatched() {
  const LONG cached =
      InterlockedCompareExchange(&g_leaf_aquaplus_profile_state, 0, 0);
  if (cached != 0)
    return cached > 0;

  wchar_t executable[32768] = {};
  const DWORD chars = GetModuleFileNameW(
      nullptr, executable,
      static_cast<DWORD>(sizeof(executable) / sizeof(executable[0])));
  HMODULE module = GetModuleHandleW(nullptr);
  uint16_t machine = 0;
  if (module != nullptr) {
    const auto *dos = reinterpret_cast<const IMAGE_DOS_HEADER *>(module);
    if (dos->e_magic == IMAGE_DOS_SIGNATURE) {
      const auto *nt = reinterpret_cast<const IMAGE_NT_HEADERS *>(
          reinterpret_cast<const uint8_t *>(module) + dos->e_lfanew);
      if (nt->Signature == IMAGE_NT_SIGNATURE)
        machine = nt->FileHeader.Machine;
    }
  }
  std::array<uint8_t, 32> digest = {};
  const bool executable_read =
      chars != 0 && chars < sizeof(executable) / sizeof(executable[0]) &&
      Sha256FileForLeafAquaplus(executable, &digest);
  const auto *profile =
      executable_read && fushi_voice_hook::MatchesLeafAquaplusProfile(
                             fushi_voice_hook::kWhiteAlbum2LeafAquaplusProfile,
                             digest.data(), digest.size(), machine)
          ? &fushi_voice_hook::kWhiteAlbum2LeafAquaplusProfile
          : nullptr;
  g_leaf_aquaplus_profile.store(profile, std::memory_order_release);
  if (profile != nullptr) {
    InterlockedOr(
        reinterpret_cast<volatile LONG *>(&FushiLeafD3DTraceV1.reserved), 0x01);
  }
  InterlockedExchange(&g_leaf_aquaplus_profile_state,
                      profile != nullptr ? 1 : -1);
  return profile != nullptr;
}

// ── WHITE ALBUM2 LAC original-voice capture ────────────────────────────────
// The shared KernelBase detour in siglus_adapter.inc only dispatches metadata.
// This exact profile validates both known VOICE.PAK indices once, publishes an
// immutable offset table, and performs all archive IO/output on HookWorker.
constexpr size_t kLeafVoicePathChars = 520u;
constexpr int kLeafVoiceArchiveSlots = 2;
constexpr int kLeafVoiceHandleSlots = 8;
constexpr int kLeafVoiceTaskSlots = 32;

struct LeafVoiceFileIdentity {
  DWORD volume_serial = 0;
  DWORD file_index_high = 0;
  DWORD file_index_low = 0;
  uint64_t file_bytes = 0;
};

struct LeafVoiceRange {
  uint64_t offset = 0;
  uint32_t size = 0;
  uint32_t id = 0;
  char storage_name[fushi_voice_hook::leaf_aquaplus::kLacStoredNameBytes + 1u] =
      {};
};

struct LeafVoiceArchive {
  wchar_t path[kLeafVoicePathChars] = {};
  LeafVoiceFileIdentity identity;
  LeafVoiceRange *ranges = nullptr;
  uint32_t range_count = 0;
};

struct LeafVoiceHandle {
  HANDLE handle = INVALID_HANDLE_VALUE;
  uint32_t archive_index = 0;
};

// 🔴 游戏线程（Detour_ReadFile）只允许往这里抄「档案槽位 + 文件内偏移 + 本次读
// 长度」这些定值，绝不能解引用 g_leaf_voice_archives[].ranges：那块堆内存的生命周期
// 归 HookWorker（LoadLeafVoiceArchives / StopLeafAquaplusResourceAudio），而
// MH_DisableHook(MH_ALL_HOOKS) 排在 registry.Shutdown() 之后，free 期间 ReadFile
// detour 仍然活着。offset → range_index 的二分因此整段推给 worker 解析，跟 siglus
// 的做法一致；worker 与 Stop 同在 HookWorker 上，不存在跨线程释放窗口。
struct LeafVoiceTask {
  volatile LONG state = 0; // 0=free, 1=producing, 2=pending, 3=consuming
  uint64_t tick_ms = 0;
  uint64_t offset = 0;
  uint32_t read_bytes = 0;
  uint32_t archive_index = 0;
};

LeafVoiceArchive g_leaf_voice_archives[kLeafVoiceArchiveSlots];
LeafVoiceHandle g_leaf_voice_handles[kLeafVoiceHandleSlots];
LeafVoiceTask g_leaf_voice_tasks[kLeafVoiceTaskSlots];
volatile LONG g_leaf_voice_archive_count = 0;
volatile LONG g_leaf_voice_enabled = 0;
uint32_t g_leaf_voice_last_archive = UINT32_MAX;
uint32_t g_leaf_voice_last_range = UINT32_MAX;
uint64_t g_leaf_voice_last_tick = 0;

bool ReadLeafVoiceFileIdentity(HANDLE file, LeafVoiceFileIdentity *out) {
  if (file == INVALID_HANDLE_VALUE || out == nullptr)
    return false;
  BY_HANDLE_FILE_INFORMATION info = {};
  if (!GetFileInformationByHandle(file, &info) ||
      (info.nFileIndexHigh == 0 && info.nFileIndexLow == 0)) {
    return false;
  }
  out->volume_serial = info.dwVolumeSerialNumber;
  out->file_index_high = info.nFileIndexHigh;
  out->file_index_low = info.nFileIndexLow;
  out->file_bytes = (static_cast<uint64_t>(info.nFileSizeHigh) << 32) |
                    static_cast<uint64_t>(info.nFileSizeLow);
  return out->file_bytes != 0;
}

bool SameLeafVoiceFileIdentity(const LeafVoiceFileIdentity &left,
                               const LeafVoiceFileIdentity &right) {
  return left.volume_serial == right.volume_serial &&
         left.file_index_high == right.file_index_high &&
         left.file_index_low == right.file_index_low &&
         left.file_bytes == right.file_bytes;
}

bool IsLeafVoicePakPath(const wchar_t *path) {
  if (path == nullptr)
    return false;
  const wchar_t *slash = wcsrchr(path, L'\\');
  const wchar_t *forward = wcsrchr(path, L'/');
  if (forward != nullptr && (slash == nullptr || forward > slash))
    slash = forward;
  return _wcsicmp(slash == nullptr ? path : slash + 1, L"VOICE.PAK") == 0;
}

int FindLeafVoiceArchive(const LeafVoiceFileIdentity &identity) {
  const LONG count =
      InterlockedCompareExchange(&g_leaf_voice_archive_count, 0, 0);
  for (LONG index = 0; index < count; ++index) {
    if (SameLeafVoiceFileIdentity(g_leaf_voice_archives[index].identity,
                                  identity)) {
      return static_cast<int>(index);
    }
  }
  return -1;
}

bool LoadLeafVoiceArchive(const wchar_t *path, LeafVoiceArchive *out) {
  if (path == nullptr || out == nullptr || g_orig_CreateFileW == nullptr ||
      g_orig_ReadFile == nullptr || g_orig_CloseHandle == nullptr) {
    return false;
  }
  HANDLE file = g_orig_CreateFileW(
      path, GENERIC_READ,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE)
    return false;

  LARGE_INTEGER file_size = {};
  uint8_t header[fushi_voice_hook::leaf_aquaplus::kLacHeaderBytes] = {};
  uint8_t *index = nullptr;
  LeafVoiceRange *ranges = nullptr;
  LeafVoiceFileIdentity identity;
  fushi_voice_hook::leaf_aquaplus::LacArchiveInfo info;
  uint64_t index_bytes = 0;
  bool valid = GetFileSizeEx(file, &file_size) && file_size.QuadPart > 0 &&
               ReadLeafVoiceFileIdentity(file, &identity) &&
               identity.file_bytes == static_cast<uint64_t>(file_size.QuadPart) &&
               ReadExact(file, header, sizeof(header)) &&
               memcmp(header, "LAC\0", 4) == 0;
  if (valid) {
    const uint32_t count =
        fushi_voice_hook::leaf_aquaplus::ReadLe32(header + 4u);
    index_bytes =
        fushi_voice_hook::leaf_aquaplus::kLacHeaderBytes +
        static_cast<uint64_t>(count) *
            fushi_voice_hook::leaf_aquaplus::kLacEntryBytes;
    valid = count > 0 &&
            count <= fushi_voice_hook::leaf_aquaplus::kMaxEntryCount &&
            index_bytes <= static_cast<uint64_t>(file_size.QuadPart) &&
            index_bytes <= UINT32_MAX;
  }
  if (valid) {
    index = static_cast<uint8_t *>(malloc(static_cast<size_t>(index_bytes)));
    valid = index != nullptr;
    if (valid) {
      memcpy(index, header, sizeof(header));
      valid = ReadExact(file, index + sizeof(header),
                        static_cast<uint32_t>(index_bytes - sizeof(header))) &&
              fushi_voice_hook::leaf_aquaplus::ParseVoiceArchiveIndex(
                  index, static_cast<size_t>(index_bytes),
                  static_cast<uint64_t>(file_size.QuadPart), &info);
    }
  }
  if (valid) {
    ranges = static_cast<LeafVoiceRange *>(
        malloc(static_cast<size_t>(info.count) * sizeof(LeafVoiceRange)));
    valid = ranges != nullptr;
    for (uint32_t id = 0; valid && id < info.count; ++id) {
      fushi_voice_hook::leaf_aquaplus::LacEntry entry;
      valid = fushi_voice_hook::leaf_aquaplus::ReadVoiceEntryAtIndex(
          index, static_cast<size_t>(index_bytes),
          static_cast<uint64_t>(file_size.QuadPart), id, &entry);
      if (!valid)
        break;
      ranges[id].offset = entry.offset;
      ranges[id].size = entry.byte_len;
      ranges[id].id = entry.id;
      memcpy(ranges[id].storage_name, entry.storage_name,
             sizeof(ranges[id].storage_name));
    }
  }
  if (valid) {
    wcsncpy_s(out->path, path, _TRUNCATE);
    out->identity = identity;
    out->ranges = ranges;
    out->range_count = info.count;
    ranges = nullptr;
  }
  free(ranges);
  free(index);
  g_orig_CloseHandle(file);
  return valid;
}

bool LoadLeafVoiceArchives() {
  if (InterlockedCompareExchange(&g_leaf_voice_archive_count, 0, 0) > 0)
    return true;
  wchar_t executable[32768] = {};
  const DWORD chars = GetModuleFileNameW(
      nullptr, executable,
      static_cast<DWORD>(sizeof(executable) / sizeof(executable[0])));
  if (chars == 0 || chars >= sizeof(executable) / sizeof(executable[0]))
    return false;
  wchar_t *slash = wcsrchr(executable, L'\\');
  if (slash == nullptr)
    return false;
  *slash = 0;

  LONG loaded = 0;
  for (const wchar_t *relative :
       fushi_voice_hook::kWhiteAlbum2LeafVoiceArchiveRelativePaths) {
    if (loaded >= kLeafVoiceArchiveSlots)
      break;
    const std::wstring path = std::wstring(executable) + L"\\" + relative;
    LeafVoiceArchive archive;
    if (!LoadLeafVoiceArchive(path.c_str(), &archive))
      continue;
    g_leaf_voice_archives[loaded] = archive;
    ++loaded;
  }
  MemoryBarrier();
  InterlockedExchange(&g_leaf_voice_archive_count, loaded);
  return loaded > 0;
}

void RememberLeafAquaplusVoicePak(HANDLE handle, const wchar_t *path) {
  if (InterlockedCompareExchange(&g_leaf_voice_enabled, 0, 0) == 0 ||
      handle == INVALID_HANDLE_VALUE || !IsLeafVoicePakPath(path) ||
      !g_cs_ready) {
    return;
  }
  LeafVoiceFileIdentity identity;
  if (!ReadLeafVoiceFileIdentity(handle, &identity))
    return;
  const int archive_index = FindLeafVoiceArchive(identity);
  if (archive_index < 0)
    return;

  EnterCriticalSection(&g_cs);
  for (int index = 0; index < kLeafVoiceHandleSlots; ++index) {
    if (g_leaf_voice_handles[index].handle == INVALID_HANDLE_VALUE ||
        g_leaf_voice_handles[index].handle == handle) {
      g_leaf_voice_handles[index].handle = handle;
      g_leaf_voice_handles[index].archive_index =
          static_cast<uint32_t>(archive_index);
      SetXAudioDiagnostic(
          fushi_voice_hook::kXAudioDiagLeafLacHandleTracked);
      break;
    }
  }
  LeaveCriticalSection(&g_cs);
}

bool CopyLeafVoiceArchiveIndex(HANDLE handle, uint32_t *archive_index) {
  if (handle == INVALID_HANDLE_VALUE || archive_index == nullptr ||
      !g_cs_ready) {
    return false;
  }
  bool found = false;
  EnterCriticalSection(&g_cs);
  for (int index = 0; index < kLeafVoiceHandleSlots; ++index) {
    if (g_leaf_voice_handles[index].handle == handle) {
      *archive_index = g_leaf_voice_handles[index].archive_index;
      found = true;
      break;
    }
  }
  LeaveCriticalSection(&g_cs);
  return found;
}

void ForgetLeafAquaplusVoicePak(HANDLE handle) {
  if (handle == INVALID_HANDLE_VALUE || !g_cs_ready)
    return;
  EnterCriticalSection(&g_cs);
  for (int index = 0; index < kLeafVoiceHandleSlots; ++index) {
    if (g_leaf_voice_handles[index].handle == handle) {
      g_leaf_voice_handles[index].handle = INVALID_HANDLE_VALUE;
      g_leaf_voice_handles[index].archive_index = 0;
      break;
    }
  }
  LeaveCriticalSection(&g_cs);
}

bool QueueLeafVoice(uint32_t archive_index, uint64_t offset,
                    uint32_t read_bytes, uint64_t tick_ms) {
  for (int index = 0; index < kLeafVoiceTaskSlots; ++index) {
    const LONG state =
        InterlockedCompareExchange(&g_leaf_voice_tasks[index].state, 0, 0);
    if (state >= 2 &&
        g_leaf_voice_tasks[index].archive_index == archive_index &&
        g_leaf_voice_tasks[index].offset == offset) {
      return true;
    }
  }
  for (int index = 0; index < kLeafVoiceTaskSlots; ++index) {
    if (InterlockedCompareExchange(&g_leaf_voice_tasks[index].state, 1, 0) !=
        0) {
      continue;
    }
    g_leaf_voice_tasks[index].tick_ms = tick_ms;
    g_leaf_voice_tasks[index].archive_index = archive_index;
    g_leaf_voice_tasks[index].offset = offset;
    g_leaf_voice_tasks[index].read_bytes = read_bytes;
    MemoryBarrier();
    InterlockedExchange(&g_leaf_voice_tasks[index].state, 2);
    return true;
  }
  return false;
}

// 只在 HookWorker 上调用：ranges 的所有权在那条线程上。
bool FindLeafVoiceRangeIndex(const LeafVoiceArchive &archive, uint64_t offset,
                             uint32_t *range_index) {
  if (archive.ranges == nullptr || range_index == nullptr)
    return false;
  uint32_t first = 0;
  uint32_t last = archive.range_count;
  while (first < last) {
    const uint32_t middle = first + (last - first) / 2u;
    if (offset < archive.ranges[middle].offset) {
      last = middle;
    } else if (offset > archive.ranges[middle].offset) {
      first = middle + 1u;
    } else {
      *range_index = middle;
      return true;
    }
  }
  return false;
}

void ObserveLeafAquaplusVoicePakRead(HANDLE file, const void *buffer,
                                    DWORD done, LPOVERLAPPED overlapped,
                                    const void *caller) {
  if (InterlockedCompareExchange(&g_leaf_voice_enabled, 0, 0) == 0 ||
      buffer == nullptr || done < 4 || overlapped != nullptr) {
    return;
  }
  const auto *profile =
      g_leaf_aquaplus_profile.load(std::memory_order_acquire);
  const uintptr_t module = reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr));
  if (profile == nullptr || module == 0 ||
      reinterpret_cast<uintptr_t>(caller) !=
          module + profile->voice_archive_read_return_rva) {
    return;
  }

  uint32_t archive_index = 0;
  if (!CopyLeafVoiceArchiveIndex(file, &archive_index)) {
    wchar_t path[kLeafVoicePathChars] = {};
    const DWORD path_chars = GetFinalPathNameByHandleW(
        file, path, static_cast<DWORD>(kLeafVoicePathChars),
        FILE_NAME_NORMALIZED);
    if (path_chars == 0 || path_chars >= kLeafVoicePathChars ||
        !IsLeafVoicePakPath(path)) {
      return;
    }
    RememberLeafAquaplusVoicePak(file, path);
    if (!CopyLeafVoiceArchiveIndex(file, &archive_index))
      return;
  }
  const LONG archive_count =
      InterlockedCompareExchange(&g_leaf_voice_archive_count, 0, 0);
  if (archive_index >= static_cast<uint32_t>(archive_count))
    return;

  SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagLeafLacReadObserved);
  __try {
    if (memcmp(buffer, "OggS", 4) != 0)
      return;
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return;
  }

  LARGE_INTEGER zero = {};
  LARGE_INTEGER current = {};
  if (!SetFilePointerEx(file, zero, &current, FILE_CURRENT) ||
      current.QuadPart < done) {
    return;
  }
  const uint64_t start = static_cast<uint64_t>(current.QuadPart) - done;
  // 到此为止只用了定值：档案槽位、文件内偏移、本次读长度。offset 是否真落在某个
  // LAC entry 起点、以及 done 是否越过该 entry，都由 worker 在自己拥有的 ranges
  // 上判定（ProcessLeafVoiceTask）。游戏线程一律不碰那块堆内存。
  const bool queued = QueueLeafVoice(archive_index, start, done,
                                     GetTickCount64());
  SetXAudioDiagnostic(queued
                          ? fushi_voice_hook::kXAudioDiagLeafLacVoiceQueued
                          : fushi_voice_hook::kXAudioDiagLeafLacTaskRejected);
}

void ProcessLeafVoiceTask(LeafVoiceTask *task) {
  const LONG archive_count =
      InterlockedCompareExchange(&g_leaf_voice_archive_count, 0, 0);
  if (task == nullptr ||
      task->archive_index >= static_cast<uint32_t>(archive_count)) {
    SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagLeafLacTaskRejected);
    return;
  }
  const LeafVoiceArchive &archive =
      g_leaf_voice_archives[task->archive_index];
  uint32_t range_index = 0;
  if (!FindLeafVoiceRangeIndex(archive, task->offset, &range_index) ||
      range_index >= archive.range_count) {
    SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagLeafLacTaskRejected);
    return;
  }
  const LeafVoiceRange range = archive.ranges[range_index];
  if (task->read_bytes > range.size) {
    SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagLeafLacTaskRejected);
    return;
  }
  if (task->archive_index == g_leaf_voice_last_archive &&
      range_index == g_leaf_voice_last_range &&
      task->tick_ms >= g_leaf_voice_last_tick &&
      task->tick_ms - g_leaf_voice_last_tick <= 2000u) {
    return;
  }

  HANDLE file = g_orig_CreateFileW(
      archive.path, GENERIC_READ,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagLeafLacTaskRejected);
    return;
  }
  LeafVoiceFileIdentity identity;
  LARGE_INTEGER at = {};
  at.QuadPart = range.offset;
  uint8_t *ogg = static_cast<uint8_t *>(malloc(range.size));
  bool valid = ReadLeafVoiceFileIdentity(file, &identity) &&
               SameLeafVoiceFileIdentity(identity, archive.identity) &&
               ogg != nullptr &&
               SetFilePointerEx(file, at, nullptr, FILE_BEGIN) != FALSE &&
               ReadExact(file, ogg, range.size) &&
               fushi_voice_hook::leaf_aquaplus::CompleteOggBytes(
                   ogg, range.size) == range.size;
  if (valid) {
    wchar_t member_name[64] = {};
    if (MultiByteToWideChar(CP_ACP, 0, range.storage_name, -1, member_name,
                            static_cast<int>(std::size(member_name))) == 0) {
      wcscpy_s(member_name, L"voice.ogg");
    }
    wchar_t storage_name[128] = {};
    swprintf_s(storage_name, L"wa2-lac%u-%u-%s", task->archive_index,
               range.id, member_name);
    valid = WriteVoiceOggAt(ogg, range.size, storage_name, task->tick_ms);
  }
  if (valid) {
    g_leaf_voice_last_archive = task->archive_index;
    g_leaf_voice_last_range = range_index;
    g_leaf_voice_last_tick = task->tick_ms;
    SetXAudioDiagnostic(
        fushi_voice_hook::kXAudioDiagLeafLacVoicePublished |
        fushi_voice_hook::kXAudioDiagGameResourcePublished);
  } else {
    SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagLeafLacTaskRejected);
  }
  free(ogg);
  g_orig_CloseHandle(file);
}

void ProcessLeafVoiceTasks() {
  for (int index = 0; index < kLeafVoiceTaskSlots; ++index) {
    if (InterlockedCompareExchange(&g_leaf_voice_tasks[index].state, 3, 2) ==
        2) {
      ProcessLeafVoiceTask(&g_leaf_voice_tasks[index]);
      InterlockedExchange(&g_leaf_voice_tasks[index].state, 0);
    }
  }
}

bool TryHookLeafAquaplusResourceAudio() {
  if (!IsLeafAquaplusProfileMatched())
    return false;
  if (InterlockedCompareExchange(&g_leaf_voice_enabled, 0, 0) != 0)
    return true;
  if (!TryHookSiglusOvk() || !LoadLeafVoiceArchives())
    return false;
  InterlockedExchange(&g_leaf_voice_enabled, 1);
  SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagLeafLacHooksReady);
  return true;
}

void StopLeafAquaplusResourceAudio() {
  InterlockedExchange(&g_leaf_voice_enabled, 0);
  if (g_cs_ready) {
    EnterCriticalSection(&g_cs);
    for (int index = 0; index < kLeafVoiceHandleSlots; ++index) {
      g_leaf_voice_handles[index].handle = INVALID_HANDLE_VALUE;
      g_leaf_voice_handles[index].archive_index = 0;
    }
    LeaveCriticalSection(&g_cs);
  }
  // 🔴 顺序不可颠倒：先把 count 撤成 0（这是任何消费者判定「档案表可用」的唯一
  // 闸门），再摘指针，最后才 free。反过来写会让 free 与「还没被撤发布的表」重叠。
  // 与 catsystem2_adapter.inc 的 StopCatSystem2PcmVoice 同一模式。
  InterlockedExchange(&g_leaf_voice_archive_count, 0);
  for (int index = 0; index < kLeafVoiceArchiveSlots; ++index) {
    LeafVoiceRange *ranges = g_leaf_voice_archives[index].ranges;
    g_leaf_voice_archives[index] = {};
    free(ranges);
  }
  g_leaf_voice_last_archive = UINT32_MAX;
  g_leaf_voice_last_range = UINT32_MAX;
  g_leaf_voice_last_tick = 0;
}

bool PublishLeafPrivateTraversal(const LeafPrivateTraversal &traversal) {
  if (traversal.glyph_count == 0 ||
      traversal.glyph_count > kLeafLookupTextUnits ||
      InterlockedCompareExchange(&g_leaf_private_traversal_writer, 1, 0) != 0) {
    return false;
  }
  const uint64_t next = static_cast<uint64_t>(InterlockedCompareExchange64(
                            &g_leaf_private_traversal_next_sequence, 0, 0)) +
                        1u;
  auto *slot =
      &g_leaf_private_traversal_slots[(next - 1u) % kLeafPrivateTraversalSlots];
  InterlockedExchange(&slot->writing, 1);
  slot->traversal = traversal;
  slot->traversal.sequence = next;
  MemoryBarrier();
  InterlockedExchange(&slot->writing, 0);
  InterlockedExchange64(&g_leaf_private_traversal_next_sequence,
                        static_cast<LONG64>(next));
  InterlockedExchange(&g_leaf_private_traversal_writer, 0);
  return true;
}

void PublishLeafD3DTraceTraversal(const LeafPrivateTraversal &traversal) {
  auto *trace = &FushiLeafD3DTraceV1;
  if (traversal.glyph_count == 0 ||
      traversal.glyph_count > kLeafLookupTextUnits) {
    return;
  }
  // Publish the completed traversal as one transaction.  The exported copy is
  // intentionally geometry-only; packed CP932 never crosses this ABI.
  if (InterlockedCompareExchange(&g_leaf_d3d_trace_writer, 1, 0) != 0) {
    InterlockedIncrement64(
        reinterpret_cast<volatile LONG64 *>(&trace->dropped_busy));
    return;
  }
  const uint64_t first =
      static_cast<uint64_t>(InterlockedCompareExchange64(
          reinterpret_cast<volatile LONG64 *>(&trace->next_sequence), 0, 0)) +
      1u;
  for (uint32_t index = 0; index < traversal.glyph_count; ++index) {
    const uint64_t sequence = first + index;
    auto *slot = &trace->slots[(sequence - 1u) % trace->capacity];
    InterlockedExchange(reinterpret_cast<volatile LONG *>(&slot->writing), 1);
    const auto &glyph = traversal.glyphs[index];
    fushi_voice_hook::LeafD3DTraceEvent event;
    event.sequence = sequence;
    event.timestamp_ms = traversal.timestamp_ms;
    event.frame_sequence = traversal.frame_sequence;
    event.traversal_id = traversal.traversal_id;
    event.texture0 = glyph.texture0;
    event.caller_rva = glyph.caller_rva;
    event.primitive_type = D3DPT_TRIANGLESTRIP;
    event.primitive_count = 2u;
    event.vertex_stride = glyph.vertex_stride;
    event.fvf = glyph.fvf;
    event.vertex_count = 4u;
    event.glyph_index = index;
    event.glyph_count = traversal.glyph_count;
    event.match_reserved = 0;
    event.left = glyph.left;
    event.top = glyph.top;
    event.right = glyph.right;
    event.bottom = glyph.bottom;
    slot->event = event;
  }
  MemoryBarrier();
  for (uint32_t index = 0; index < traversal.glyph_count; ++index) {
    const uint64_t sequence = first + index;
    auto *slot = &trace->slots[(sequence - 1u) % trace->capacity];
    InterlockedExchange(reinterpret_cast<volatile LONG *>(&slot->writing), 0);
  }
  InterlockedExchange64(
      reinterpret_cast<volatile LONG64 *>(&trace->next_sequence),
      static_cast<LONG64>(first + traversal.glyph_count - 1u));
  InterlockedExchange(&g_leaf_d3d_trace_writer, 0);
}

bool CaptureLeafQuadBounds(const void *vertices, UINT stride, UINT count,
                           float *left, float *top, float *right,
                           float *bottom) {
  if (vertices == nullptr || stride < sizeof(float) * 2u || stride > 256u ||
      count < 3u || count > 16u || left == nullptr || top == nullptr ||
      right == nullptr || bottom == nullptr) {
    return false;
  }
  bool valid = false;
  __try {
    const auto *bytes = static_cast<const uint8_t *>(vertices);
    for (UINT index = 0; index < count; ++index) {
      const auto *xy = reinterpret_cast<const float *>(bytes + index * stride);
      const float x = xy[0];
      const float y = xy[1];
      if (!std::isfinite(x) || !std::isfinite(y) || x < -8192.0f ||
          x > 8192.0f || y < -8192.0f || y > 8192.0f) {
        return false;
      }
      if (!valid) {
        *left = *right = x;
        *top = *bottom = y;
        valid = true;
      } else {
        *left = (std::min)(*left, x);
        *top = (std::min)(*top, y);
        *right = (std::max)(*right, x);
        *bottom = (std::max)(*bottom, y);
      }
    }
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return false;
  }
  return valid && *right > *left && *bottom > *top;
}

bool MatchesLeafEntry(const uint8_t *target, const uint8_t *expected,
                      size_t expected_bytes) {
  if (target == nullptr)
    return false;
  __try {
    for (size_t index = 0; index < expected_bytes; ++index) {
      if (target[index] != expected[index])
        return false;
    }
    return true;
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return false;
  }
}

bool MatchesLeafTextTraversalEntry(const uint8_t *target) {
  static constexpr uint8_t kEntry[] = {
      0x81, 0xec, 0x3c, 0x01, 0x00, 0x00, 0xa1, 0x30, 0x16, 0x4d,
      0x00, 0x33, 0xc4, 0x89, 0x84, 0x24, 0x38, 0x01, 0x00, 0x00,
  };
  return MatchesLeafEntry(target, kEntry, sizeof(kEntry));
}

bool MatchesLeafRasterDrawEntry(const uint8_t *target) {
  static constexpr uint8_t kEntry[] = {
      0x55, 0x8b, 0xec, 0x83, 0xe4, 0xf8, 0xb8, 0xa4, 0x16, 0x00, 0x00,
  };
  return MatchesLeafEntry(target, kEntry, sizeof(kEntry));
}

bool DecodeLeafPackedCp932(uint16_t packed, wchar_t *decoded) {
  if (decoded == nullptr)
    return false;
  fushi_voice_hook::LeafAquaplusPackedCp932Bytes unpacked;
  if (!fushi_voice_hook::UnpackLeafAquaplusCp932(packed, &unpacked)) {
    return false;
  }
  char bytes[2] = {static_cast<char>(unpacked.bytes[0]),
                   static_cast<char>(unpacked.bytes[1])};
  wchar_t value = 0;
  if (MultiByteToWideChar(932u, MB_ERR_INVALID_CHARS, bytes,
                          static_cast<int>(unpacked.count), &value, 1) != 1 ||
      value == L'\0' || (value >= 0xd800 && value <= 0xdfff)) {
    return false;
  }
  *decoded = value;
  return true;
}

void InvalidateLeafLookupClickTarget() {
  const uint64_t next = static_cast<uint64_t>(
      InterlockedIncrement64(&g_leaf_lookup_click_target_count));
  InterlockedExchange64(&g_leaf_lookup_click_target.seq, 0);
  g_leaf_lookup_click_target.valid = 0;
  g_leaf_lookup_click_target.published_tick = GetTickCount64();
  g_leaf_lookup_click_target.game_window = 0;
  g_leaf_lookup_click_target.geometry = {};
  InterlockedExchange64(&g_leaf_lookup_click_target.seq,
                        static_cast<LONG64>(next));
}

void PublishLeafLookupClickTarget(HWND game, const POINT &client_origin,
                                  int32_t client_width, int32_t client_height) {
  if (game == nullptr || !g_leaf_active_geometry_valid ||
      g_leaf_active_geometry.text_units == 0 ||
      g_leaf_active_geometry.glyph_count == 0) {
    InvalidateLeafLookupClickTarget();
    return;
  }
  const uint64_t next = static_cast<uint64_t>(
      InterlockedIncrement64(&g_leaf_lookup_click_target_count));
  InterlockedExchange64(&g_leaf_lookup_click_target.seq, 0);
  g_leaf_lookup_click_target.valid = 1;
  g_leaf_lookup_click_target.published_tick = GetTickCount64();
  g_leaf_lookup_click_target.game_window = reinterpret_cast<uintptr_t>(game);
  g_leaf_lookup_click_target.client_screen_x = client_origin.x;
  g_leaf_lookup_click_target.client_screen_y = client_origin.y;
  g_leaf_lookup_click_target.client_width = client_width;
  g_leaf_lookup_click_target.client_height = client_height;
  g_leaf_lookup_click_target.geometry = g_leaf_active_geometry;
  MemoryBarrier();
  InterlockedExchange64(&g_leaf_lookup_click_target.seq,
                        static_cast<LONG64>(next));
}

bool ReadLeafLookupClickTarget(LeafLookupClickTarget *copy) {
  if (copy == nullptr)
    return false;
  const uint64_t before = static_cast<uint64_t>(
      InterlockedCompareExchange64(&g_leaf_lookup_click_target.seq, 0, 0));
  if (before == 0)
    return false;
  memcpy(copy, &g_leaf_lookup_click_target, sizeof(*copy));
  const uint64_t after = static_cast<uint64_t>(
      InterlockedCompareExchange64(&g_leaf_lookup_click_target.seq, 0, 0));
  if (after != before || after == 0 || copy->valid != 1)
    return false;
  const ULONGLONG now = GetTickCount64();
  return now >= copy->published_tick &&
         now - copy->published_tick <= kLeafLookupClickTargetMaxAgeMs &&
         copy->game_window != 0 && copy->client_width > 0 &&
         copy->client_height > 0 && copy->geometry.sentence_epoch != 0 &&
         copy->geometry.text_units != 0 &&
         copy->geometry.text_units <= kLeafLookupTextUnits &&
         copy->geometry.glyph_count != 0 &&
         copy->geometry.glyph_count <= kLeafLookupTextUnits &&
         copy->geometry.viewport_width > 0 &&
         copy->geometry.viewport_height > 0;
}

bool BuildLeafLookupPayloadAtPress(const LeafLookupClickTarget &target,
                                   HWND game, const POINT &screen_point,
                                   LeafLookupPayload *payload) {
  if (payload == nullptr || target.valid != 1 || game == nullptr ||
      reinterpret_cast<HWND>(target.game_window) != game || !IsWindow(game) ||
      GetForegroundWindow() != game) {
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
  fushi_voice_hook::LeafAquaplusLookupRect rect;
  const int glyph_index = fushi_voice_hook::FindLeafAquaplusLookupGlyph(
      target.geometry.glyphs, target.geometry.glyph_count,
      target.geometry.viewport_x, target.geometry.viewport_y,
      target.geometry.viewport_width, target.geometry.viewport_height,
      client_width, client_height, screen_point.x - origin.x,
      screen_point.y - origin.y, &rect);
  if (glyph_index < 0)
    return false;
  const uint32_t char_index = target.geometry.glyphs[glyph_index].char_index;
  if (char_index >= target.geometry.text_units)
    return false;
  *payload = {};
  payload->activation_epoch =
      g_leaf_lookup_activation_epoch.load(std::memory_order_acquire);
  payload->sentence_epoch = target.geometry.sentence_epoch;
  payload->geometry_generation = target.geometry.generation;
  payload->text_units = target.geometry.text_units;
  payload->char_index = char_index;
  payload->rect = rect;
  payload->client_width = client_width;
  payload->client_height = client_height;
  memcpy(payload->text, target.geometry.text,
         static_cast<size_t>(target.geometry.text_units) * sizeof(wchar_t));
  return true;
}

void QueueLeafLookupClickSubmit(const LeafLookupPayload &payload) {
  if (payload.activation_epoch == 0 || payload.sentence_epoch == 0 ||
      payload.text_units == 0 || payload.text_units > kLeafLookupTextUnits ||
      payload.char_index >= payload.text_units) {
    return;
  }
  const uint64_t next = static_cast<uint64_t>(
      InterlockedIncrement64(&g_leaf_lookup_click_event_count));
  auto *event = &g_leaf_lookup_click_events[next % kLeafLookupClickEventSlots];
  InterlockedExchange64(&event->seq, 0);
  event->payload = payload;
  MemoryBarrier();
  InterlockedExchange64(&event->seq, static_cast<LONG64>(next));
}

bool ReadLatestLeafLookupClickSubmit(LeafLookupClickEvent *copy,
                                     uint64_t *seq) {
  if (copy == nullptr || seq == nullptr)
    return false;
  const uint64_t latest = static_cast<uint64_t>(
      InterlockedCompareExchange64(&g_leaf_lookup_click_event_count, 0, 0));
  if (latest == 0 || latest == g_leaf_lookup_click_processed_seq)
    return false;
  auto *source =
      &g_leaf_lookup_click_events[latest % kLeafLookupClickEventSlots];
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

int LeafMouseButtonIndex(int virtual_key) {
  if (virtual_key == VK_LBUTTON)
    return 0;
  if (virtual_key == VK_RBUTTON)
    return 1;
  if (virtual_key == VK_MBUTTON)
    return 2;
  return -1;
}

bool ClaimLeafInputPollerThread(uint32_t thread_id) {
  if (thread_id == 0)
    return false;
  uint32_t owner = 0;
  if (g_leaf_input_poller_owner_tid.compare_exchange_strong(
          owner, thread_id, std::memory_order_acq_rel,
          std::memory_order_acquire)) {
    InterlockedExchange(reinterpret_cast<volatile LONG *>(
                            &FushiLeafD3DTraceV1.input_poller_owner_tid),
                        static_cast<LONG>(thread_id));
    return true;
  }
  if (owner == thread_id)
    return true;
  InterlockedIncrement(reinterpret_cast<volatile LONG *>(
      &FushiLeafD3DTraceV1.input_poller_conflicts));
  InterlockedExchange(reinterpret_cast<volatile LONG *>(
                          &FushiLeafD3DTraceV1.input_poller_last_conflict_tid),
                      static_cast<LONG>(thread_id));
  return false;
}

// owner_tid 只在第一次 CAS 时认领，之后从不释放。认领它的线程一旦退出（WA2 在场景
// 切换/全屏重建时会重建工作线程），真正的 poller 就会**每次调用**都判为冲突，争用状态
// 于是永远为真——闩虽然去掉了，实质仍是死锁。所以争用发生时要在 worker 上校验 owner
// 是否还活着，死了就把槽位撤回 0 让下一次 admitted 调用重新认领。这两个 syscall 只能
// 放在 worker 上：游戏线程那条 detour 每秒被调上千次。
void ReleaseDeadLeafInputPollerOwner() {
  const uint32_t owner =
      g_leaf_input_poller_owner_tid.load(std::memory_order_acquire);
  if (owner == 0)
    return;
  bool alive = false;
  const HANDLE thread =
      OpenThread(SYNCHRONIZE, FALSE, static_cast<DWORD>(owner));
  if (thread != nullptr) {
    alive = WaitForSingleObject(thread, 0) == WAIT_TIMEOUT;
    CloseHandle(thread);
  }
  if (alive)
    return;
  g_leaf_input_poller_owner_tid.store(0, std::memory_order_release);
  InterlockedExchange(reinterpret_cast<volatile LONG *>(
                          &FushiLeafD3DTraceV1.input_poller_owner_tid),
                      0);
}

bool IsLeafAdmittedInputPoller(uintptr_t return_address) {
  const auto *profile = g_leaf_aquaplus_profile.load(std::memory_order_acquire);
  const uintptr_t module =
      reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr));
  return profile != nullptr && module != 0 && return_address >= module &&
         return_address - module >= profile->input_poller_first_return_rva &&
         return_address - module <= profile->input_poller_last_return_rva;
}

SHORT WINAPI Detour_LeafGetAsyncKeyState(int virtual_key) {
  const auto original = g_leaf_get_async_key_state_original;
  if (original == nullptr)
    return 0;
  const SHORT raw_signed = original(virtual_key);
  const int button_index = LeafMouseButtonIndex(virtual_key);
  if (button_index < 0 || !g_capture_enabled)
    return raw_signed;

  const uint16_t raw = static_cast<uint16_t>(raw_signed);
  const uint8_t button_bit = static_cast<uint8_t>(1u << button_index);
  const bool raw_active =
      (raw & fushi_voice_hook::kLeafAquaplusAsyncPressedMask) != 0;
  const bool admitted_poller =
      IsLeafAdmittedInputPoller(reinterpret_cast<uintptr_t>(_ReturnAddress()));
  const bool poller_owner =
      !admitted_poller || ClaimLeafInputPollerThread(GetCurrentThreadId());
  HWND game = g_leaf_sampled_input_game_window.load(std::memory_order_acquire);
  if (game == nullptr || !IsWindow(game))
    game = FindGameMainWindow();
  const HWND direct_popup = GetValidPublishedLeafSampledInputShieldPopup(game);
  const bool direct_shield =
      direct_popup != nullptr && IsLeafSampledInputShieldReadyPublished(game);
  const bool bitmap_popup_visible = IsLookupOverlayInputShieldVisible();
  const bool popup_shield = direct_shield || bitmap_popup_visible;
  uint32_t tail_request =
      game == nullptr
          ? 0u
          : static_cast<uint32_t>(reinterpret_cast<uintptr_t>(GetPropW(
                game, fushi_voice_hook::
                          kLeafAquaplusSampledInputShieldTailRequestProperty)));
  uint32_t tail_buttons =
      fushi_voice_hook::LeafAquaplusSampledInputTailButtons(tail_request);
  const bool orphaned_tail =
      fushi_voice_hook::LeafAquaplusTailRequestIsOrphaned(
          tail_request, direct_popup != nullptr);
  bool tail_consume = !orphaned_tail && (tail_buttons & button_bit) != 0;
  if (admitted_poller && !poller_owner) {
    bool published_glyph_hit = false;
    if (virtual_key == VK_LBUTTON &&
        g_leaf_lookup_runtime_enabled.load(std::memory_order_acquire)) {
      POINT pointer = {};
      LeafLookupClickTarget target;
      LeafLookupPayload ignored_payload;
      published_glyph_hit = GetCursorPos(&pointer) != FALSE &&
                            ReadLeafLookupClickTarget(&target) &&
                            BuildLeafLookupPayloadAtPress(target, game, pointer,
                                                          &ignored_payload);
    }
    const uint8_t latched =
        g_leaf_sampled_input_latched_buttons.load(std::memory_order_acquire);
    const bool consume =
        fushi_voice_hook::LeafAquaplusConflictingPollerMustConsume(
            popup_shield, tail_consume, (latched & button_bit) != 0,
            g_leaf_lookup_click_transaction_active.load(
                std::memory_order_acquire),
            published_glyph_hit);
    return static_cast<SHORT>(
        fushi_voice_hook::FilterLeafAquaplusAsyncKeyState(raw, consume));
  }
  if (admitted_poller && orphaned_tail) {
    // Window properties outlive their publishing process.  If Fushi/popup
    // died, no real tail acknowledgement can ever be delivered; consuming the
    // stale token would lock this mouse button until the game exits.  Hidden
    // popups keep a valid HWND and therefore retain the normal drain path.
    if (game != nullptr && IsWindow(game)) {
      if (static_cast<uint32_t>(reinterpret_cast<uintptr_t>(GetPropW(
              game, fushi_voice_hook::
                        kLeafAquaplusSampledInputShieldTailRequestProperty))) ==
          tail_request) {
        RemovePropW(game,
                    fushi_voice_hook::
                        kLeafAquaplusSampledInputShieldTailRequestProperty);
      }
      if (static_cast<uint32_t>(reinterpret_cast<uintptr_t>(GetPropW(
              game, fushi_voice_hook::
                        kLeafAquaplusSampledInputShieldTailAckProperty))) ==
          tail_request) {
        RemovePropW(
            game,
            fushi_voice_hook::kLeafAquaplusSampledInputShieldTailAckProperty);
      }
    }
    g_leaf_sampled_input_tail_state = {};
    tail_request = 0;
    tail_buttons = 0;
  }
  if (admitted_poller) {
    const uint64_t activation =
        g_leaf_lookup_activation_epoch.load(std::memory_order_acquire);
    if (activation != g_leaf_lookup_poller_activation_epoch) {
      g_leaf_lookup_click_sample_state = {};
      g_leaf_lookup_pending_click = {};
      g_leaf_lookup_pending_click_valid = false;
      g_leaf_lookup_click_transaction_active.store(false,
                                                   std::memory_order_release);
      g_leaf_lookup_poller_activation_epoch = activation;
    }
  }
  if (admitted_poller) {
    const auto tail = fushi_voice_hook::AdvanceLeafAquaplusSampledInputTail(
        tail_request, tail_buttons, button_bit, raw,
        &g_leaf_sampled_input_tail_state);
    tail_consume = tail_consume || tail.consume;
    if (tail.acknowledge) {
      bool published = false;
      if (game != nullptr && IsWindow(game) &&
          SetPropW(
              game,
              fushi_voice_hook::kLeafAquaplusSampledInputShieldTailAckProperty,
              reinterpret_cast<HANDLE>(static_cast<uintptr_t>(tail.token)))) {
        const HWND popup = GetValidPublishedLeafSampledInputShieldPopup(game);
        published =
            popup != nullptr &&
            PostMessageW(
                popup,
                static_cast<UINT>(
                    fushi_voice_hook::kSampledInputShieldReleaseWindowMessage),
                0, 0) != FALSE;
      }
      if (!published) {
        g_leaf_sampled_input_tail_state.acknowledged_token = 0;
      }
    }
  }
  if (popup_shield && raw_active) {
    g_leaf_sampled_input_latched_buttons.fetch_or(button_bit,
                                                  std::memory_order_acq_rel);
  }

  bool decision_consume = false;
  if (virtual_key == VK_LBUTTON && admitted_poller) {
    const bool runtime_enabled =
        g_leaf_lookup_runtime_enabled.load(std::memory_order_acquire);
    const bool may_begin =
        g_leaf_lookup_click_sample_state.synchronized &&
        g_leaf_lookup_click_sample_state.owner ==
            fushi_voice_hook::LeafAquaplusLookupClickOwner::kIdle &&
        (((raw & 0x8000u) != 0 &&
          !g_leaf_lookup_click_sample_state.last_high_down) ||
         ((raw & 0x8000u) == 0 && (raw & 0x0001u) != 0));
    POINT pointer = {};
    const bool pointer_valid = !may_begin || GetCursorPos(&pointer) != FALSE;
    LeafLookupPayload pressed_payload;
    bool glyph_hit = false;
    if (may_begin && runtime_enabled && !popup_shield && pointer_valid &&
        ReadLeafLookupClickTarget(&g_leaf_lookup_click_read_target)) {
      glyph_hit = BuildLeafLookupPayloadAtPress(
          g_leaf_lookup_click_read_target, game, pointer, &pressed_payload);
    }
    const auto owner_before = g_leaf_lookup_click_sample_state.owner;
    const auto decision =
        fushi_voice_hook::AdvanceLeafAquaplusLookupClickSample(
            raw, runtime_enabled && pointer_valid, popup_shield, glyph_hit,
            g_leaf_sentence_epoch_atomic.load(std::memory_order_acquire),
            &g_leaf_lookup_click_sample_state);
    if (decision.begin && decision.popup_transaction && pointer_valid &&
        !direct_shield && bitmap_popup_visible && game != nullptr &&
        GetForegroundWindow() == game) {
      const HWND point_window = WindowFromPoint(pointer);
      if (point_window != nullptr &&
          (point_window == game || IsChild(game, point_window))) {
        RequestLookupOverlayOutsideDismiss();
      }
    }
    if (decision.begin && glyph_hit && !decision.popup_transaction) {
      g_leaf_lookup_pending_click = pressed_payload;
      g_leaf_lookup_pending_click_valid = true;
    }
    if (decision.submit) {
      if (g_leaf_lookup_pending_click_valid && runtime_enabled) {
        QueueLeafLookupClickSubmit(g_leaf_lookup_pending_click);
      }
      g_leaf_lookup_pending_click_valid = false;
    } else if (owner_before ==
                   fushi_voice_hook::LeafAquaplusLookupClickOwner::kLookup &&
               (raw & 0x8000u) == 0) {
      g_leaf_lookup_pending_click_valid = false;
    }
    g_leaf_lookup_click_transaction_active.store(
        g_leaf_lookup_click_sample_state.owner !=
                fushi_voice_hook::LeafAquaplusLookupClickOwner::kIdle ||
            g_leaf_lookup_pending_click_valid,
        std::memory_order_release);
    decision_consume = decision.consume;
    if (decision.consume) {
      g_leaf_sampled_input_latched_buttons.fetch_or(button_bit,
                                                    std::memory_order_acq_rel);
    }
  }

  const uint8_t latched =
      g_leaf_sampled_input_latched_buttons.load(std::memory_order_acquire);
  const bool consume = popup_shield || tail_consume || decision_consume ||
                       (latched & button_bit) != 0;
  const SHORT filtered = static_cast<SHORT>(
      fushi_voice_hook::FilterLeafAquaplusAsyncKeyState(raw, consume));
  if (!raw_active) {
    g_leaf_sampled_input_latched_buttons.fetch_and(
        static_cast<uint8_t>(~button_bit), std::memory_order_acq_rel);
  }
  return filtered;
}

HRESULT STDMETHODCALLTYPE Detour_LeafSetTexture(
    IDirect3DDevice9 *device, DWORD stage, IDirect3DBaseTexture9 *texture) {
  if (stage == 0) {
    g_leaf_texture0.store(reinterpret_cast<uintptr_t>(texture),
                          std::memory_order_release);
  }
  return g_leaf_set_texture_original != nullptr
             ? g_leaf_set_texture_original(device, stage, texture)
             : D3DERR_INVALIDCALL;
}

HRESULT STDMETHODCALLTYPE Detour_LeafPresent(IDirect3DDevice9 *device,
                                             const RECT *source,
                                             const RECT *destination,
                                             HWND override_window,
                                             const RGNDATA *dirty) {
  g_leaf_frame_sequence.fetch_add(1u, std::memory_order_acq_rel);
  return g_leaf_present_original != nullptr
             ? g_leaf_present_original(device, source, destination,
                                       override_window, dirty)
             : D3DERR_INVALIDCALL;
}

HRESULT STDMETHODCALLTYPE Detour_LeafDrawPrimitiveUP(
    IDirect3DDevice9 *device, D3DPRIMITIVETYPE primitive_type,
    UINT primitive_count, const void *vertices, UINT stride) {
  auto &traversal = g_leaf_text_traversal_capture;
  auto &raster = g_leaf_raster_capture;
  const bool glyph_active = traversal.active && !traversal.invalid &&
                            traversal.suppression_depth == 0 && raster.active;
  if (glyph_active) {
    InterlockedIncrement64(reinterpret_cast<volatile LONG64 *>(
        &FushiLeafD3DTraceV1.armed_draw_calls));
  }
  const auto *profile = g_leaf_aquaplus_profile.load(std::memory_order_acquire);
  const uintptr_t module =
      reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr));
  const uintptr_t caller = reinterpret_cast<uintptr_t>(_ReturnAddress());
  if (glyph_active) {
    InterlockedExchange(reinterpret_cast<volatile LONG *>(
                            &FushiLeafD3DTraceV1.last_primitive_type),
                        static_cast<LONG>(primitive_type));
    InterlockedExchange(reinterpret_cast<volatile LONG *>(
                            &FushiLeafD3DTraceV1.last_primitive_count),
                        static_cast<LONG>(primitive_count));
    InterlockedExchange(reinterpret_cast<volatile LONG *>(
                            &FushiLeafD3DTraceV1.last_vertex_stride),
                        static_cast<LONG>(stride));
    if (module != 0 && caller >= module && caller - module <= 0xffffffffull) {
      InterlockedExchange(reinterpret_cast<volatile LONG *>(
                              &FushiLeafD3DTraceV1.last_caller_rva),
                          static_cast<LONG>(caller - module));
    }
  }
  if (glyph_active && profile != nullptr && module != 0) {
    uint16_t draw_format = 0;
    uint32_t expected_stride = 0;
    uint32_t expected_fvf = 0;
    uint32_t caller_rva = 0;
    if (caller == module + profile->quad_draw_return_rva) {
      draw_format = 1u;
      expected_stride = profile->quad_vertex_stride;
      expected_fvf = profile->quad_fvf;
      caller_rva = static_cast<uint32_t>(profile->quad_draw_return_rva);
    } else if (caller == module + profile->alternate_quad_draw_return_rva) {
      draw_format = 2u;
      expected_stride = profile->alternate_quad_vertex_stride;
      expected_fvf = profile->alternate_quad_fvf;
      caller_rva =
          static_cast<uint32_t>(profile->alternate_quad_draw_return_rva);
    } else {
      InterlockedIncrement64(reinterpret_cast<volatile LONG64 *>(
          &FushiLeafD3DTraceV1.caller_rejects));
    }
    if (draw_format != 0) {
      DWORD fvf = 0;
      D3DVIEWPORT9 viewport = {};
      if (primitive_type != D3DPT_TRIANGLESTRIP) {
        InterlockedIncrement64(reinterpret_cast<volatile LONG64 *>(
            &FushiLeafD3DTraceV1.primitive_type_rejects));
        raster.invalid = true;
      } else if (primitive_count != 2u) {
        InterlockedIncrement64(reinterpret_cast<volatile LONG64 *>(
            &FushiLeafD3DTraceV1.primitive_count_rejects));
        raster.invalid = true;
      } else if (stride != expected_stride) {
        InterlockedIncrement64(reinterpret_cast<volatile LONG64 *>(
            &FushiLeafD3DTraceV1.vertex_stride_rejects));
        raster.invalid = true;
      } else if (device == nullptr || FAILED(device->GetFVF(&fvf)) ||
                 fvf != expected_fvf ||
                 FAILED(device->GetViewport(&viewport)) ||
                 viewport.Width == 0 || viewport.Height == 0 ||
                 viewport.Width > 16384u || viewport.Height > 16384u) {
        raster.invalid = true;
      } else if (raster.draw_format != 0 && raster.draw_format != draw_format) {
        // One 0x43b590 glyph closure must not mix the tiled and alternate
        // descriptor formats.  Ambiguous geometry is discarded wholesale.
        raster.invalid = true;
      } else {
        float left = 0.0f;
        float top = 0.0f;
        float right = 0.0f;
        float bottom = 0.0f;
        if (!CaptureLeafQuadBounds(vertices, stride, 4u, &left, &top, &right,
                                   &bottom)) {
          InterlockedIncrement64(reinterpret_cast<volatile LONG64 *>(
              &FushiLeafD3DTraceV1.bounds_rejects));
          raster.invalid = true;
        } else {
          const float viewport_left = static_cast<float>(viewport.X);
          const float viewport_top = static_cast<float>(viewport.Y);
          const float viewport_right =
              static_cast<float>(viewport.X + viewport.Width);
          const float viewport_bottom =
              static_cast<float>(viewport.Y + viewport.Height);
          left = (std::max)(left, viewport_left);
          top = (std::max)(top, viewport_top);
          right = (std::min)(right, viewport_right);
          bottom = (std::min)(bottom, viewport_bottom);
          if (!(right > left) || !(bottom > top) ||
              (raster.bounds_ready &&
               (raster.viewport_x != static_cast<int32_t>(viewport.X) ||
                raster.viewport_y != static_cast<int32_t>(viewport.Y) ||
                raster.viewport_width != static_cast<int32_t>(viewport.Width) ||
                raster.viewport_height !=
                    static_cast<int32_t>(viewport.Height)))) {
            InterlockedIncrement64(reinterpret_cast<volatile LONG64 *>(
                &FushiLeafD3DTraceV1.bounds_rejects));
            raster.invalid = true;
          } else {
            InterlockedIncrement64(reinterpret_cast<volatile LONG64 *>(
                &FushiLeafD3DTraceV1.quad_candidates));
            InterlockedIncrement64(reinterpret_cast<volatile LONG64 *>(
                draw_format == 1u
                    ? &FushiLeafD3DTraceV1.primary_quad_candidates
                    : &FushiLeafD3DTraceV1.alternate_quad_candidates));
            if (!raster.bounds_ready) {
              raster.left = left;
              raster.top = top;
              raster.right = right;
              raster.bottom = bottom;
              raster.bounds_ready = true;
            } else {
              raster.left = (std::min)(raster.left, left);
              raster.top = (std::min)(raster.top, top);
              raster.right = (std::max)(raster.right, right);
              raster.bottom = (std::max)(raster.bottom, bottom);
            }
            raster.viewport_x = static_cast<int32_t>(viewport.X);
            raster.viewport_y = static_cast<int32_t>(viewport.Y);
            raster.viewport_width = static_cast<int32_t>(viewport.Width);
            raster.viewport_height = static_cast<int32_t>(viewport.Height);
            raster.draw_format = draw_format;
            raster.caller_rva = caller_rva;
            raster.vertex_stride = stride;
            raster.fvf = fvf;
            raster.texture0 = static_cast<uint64_t>(
                g_leaf_texture0.load(std::memory_order_acquire));
          }
        }
      }
    }
  }
  return g_leaf_draw_primitive_up_original != nullptr
             ? g_leaf_draw_primitive_up_original(
                   device, primitive_type, primitive_count, vertices, stride)
             : D3DERR_INVALIDCALL;
}

int __cdecl Detour_LeafRasterDraw(void *descriptor, void *vertices) {
  const LeafRasterDrawFn original = g_leaf_raster_draw_original;
  if (original == nullptr)
    return 0;
  InterlockedIncrement64(
      reinterpret_cast<volatile LONG64 *>(&FushiLeafD3DTraceV1.glyph_calls));
  auto &traversal = g_leaf_text_traversal_capture;
  auto &raster = g_leaf_raster_capture;
  if (raster.active) {
    // A nested raster call would otherwise merge two glyphs into one union.
    traversal.invalid = true;
    LeafRasterCapture saved = raster;
    raster.active = false;
    int nested_result = 0;
    __try {
      nested_result = original(descriptor, vertices);
    } __finally {
      raster = saved;
    }
    return nested_result;
  }
  const auto *profile = g_leaf_aquaplus_profile.load(std::memory_order_acquire);
  const uintptr_t module =
      reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr));
  const uintptr_t caller = reinterpret_cast<uintptr_t>(_ReturnAddress());
  const auto *return_address_slot =
      static_cast<const uint8_t *>(_AddressOfReturnAddress());
  if (!traversal.active || traversal.invalid ||
      traversal.suppression_depth != 0 || profile == nullptr || module == 0 ||
      caller != module + profile->raster_glyph_return_rva) {
    return original(descriptor, vertices);
  }
  uint16_t packed_cp932 = 0;
  uintptr_t glyph_parent_return = 0;
  __try {
    glyph_parent_return = *reinterpret_cast<const uintptr_t *>(
        return_address_slot + profile->raster_parent_return_stack_offset);
    packed_cp932 = *reinterpret_cast<const uint16_t *>(
        return_address_slot + profile->raster_packed_cp932_stack_offset);
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    glyph_parent_return = 0;
    packed_cp932 = 0;
  }
  if (glyph_parent_return != module + profile->glyph_single_return_rva &&
      glyph_parent_return != module + profile->glyph_double_first_return_rva &&
      glyph_parent_return != module + profile->glyph_double_second_return_rva) {
    return original(descriptor, vertices);
  }
  packed_cp932 =
      fushi_voice_hook::NormalizeLeafAquaplusPackedCp932(packed_cp932);
  fushi_voice_hook::LeafAquaplusPackedCp932Bytes unpacked;
  if (!fushi_voice_hook::UnpackLeafAquaplusCp932(packed_cp932, &unpacked)) {
    InterlockedIncrement64(reinterpret_cast<volatile LONG64 *>(
        &FushiLeafD3DTraceV1.glyph_describe_failures));
    return original(descriptor, vertices);
  }
  raster = {};
  raster.active = true;
  raster.packed_cp932 = packed_cp932;
  raster.frame_sequence = traversal.traversal.frame_sequence;
  InterlockedIncrement64(reinterpret_cast<volatile LONG64 *>(
      &FushiLeafD3DTraceV1.glyph_armed_calls));
  int result = 0;
  bool completed = false;
  __try {
    result = original(descriptor, vertices);
    completed = true;
  } __finally {
    const bool first_glyph = traversal.traversal.glyph_count == 0;
    const bool viewport_matches =
        first_glyph ||
        (traversal.traversal.viewport_x == raster.viewport_x &&
         traversal.traversal.viewport_y == raster.viewport_y &&
         traversal.traversal.viewport_width == raster.viewport_width &&
         traversal.traversal.viewport_height == raster.viewport_height);
    if (!completed || AbnormalTermination() || raster.invalid ||
        !raster.bounds_ready || raster.draw_format == 0 ||
        raster.viewport_width <= 0 || raster.viewport_height <= 0 ||
        !viewport_matches ||
        raster.frame_sequence !=
            g_leaf_frame_sequence.load(std::memory_order_acquire) ||
        traversal.traversal.glyph_count >= kLeafLookupTextUnits) {
      traversal.invalid = true;
    } else {
      if (first_glyph) {
        traversal.traversal.viewport_x = raster.viewport_x;
        traversal.traversal.viewport_y = raster.viewport_y;
        traversal.traversal.viewport_width = raster.viewport_width;
        traversal.traversal.viewport_height = raster.viewport_height;
      }
      auto &glyph =
          traversal.traversal.glyphs[traversal.traversal.glyph_count++];
      glyph.packed_cp932 = raster.packed_cp932;
      glyph.draw_format = raster.draw_format;
      glyph.caller_rva = raster.caller_rva;
      glyph.vertex_stride = raster.vertex_stride;
      glyph.fvf = raster.fvf;
      glyph.texture0 = raster.texture0;
      glyph.left = raster.left;
      glyph.top = raster.top;
      glyph.right = raster.right;
      glyph.bottom = raster.bottom;
    }
    raster = {};
  }
  return result;
}

int __cdecl Detour_LeafTextTraversal(uint32_t a01, uint32_t a02, uint32_t a03,
                                     uint32_t a04, uint32_t a05, uint32_t a06,
                                     uint32_t a07, uint32_t a08, uint32_t a09,
                                     uint32_t a10, uint32_t a11, uint32_t a12,
                                     uint32_t a13, uint32_t a14, uint32_t a15,
                                     uint32_t a16, uint32_t a17, uint32_t a18,
                                     uint32_t a19, uint32_t a20, uint32_t a21,
                                     uint32_t a22, uint32_t a23, uint32_t a24,
                                     uint32_t a25, uint32_t a26) {
  const LeafTextTraversalFn original = g_leaf_text_traversal_original;
  if (original == nullptr)
    return 0;
  auto &capture = g_leaf_text_traversal_capture;
  if (capture.active) {
    capture.invalid = true;
    ++capture.suppression_depth;
    int nested_result = 0;
    __try {
      nested_result = original(a01, a02, a03, a04, a05, a06, a07, a08, a09, a10,
                               a11, a12, a13, a14, a15, a16, a17, a18, a19, a20,
                               a21, a22, a23, a24, a25, a26);
    } __finally {
      --capture.suppression_depth;
    }
    return nested_result;
  }
  capture = {};
  capture.active = true;
  capture.traversal.frame_sequence =
      g_leaf_frame_sequence.load(std::memory_order_acquire);
  capture.traversal.sentence_epoch_at_capture =
      g_leaf_sentence_epoch_atomic.load(std::memory_order_acquire);
  capture.traversal.traversal_id =
      g_leaf_next_traversal_id.fetch_add(1u, std::memory_order_acq_rel) + 1u;
  int result = 0;
  bool completed = false;
  __try {
    result = original(a01, a02, a03, a04, a05, a06, a07, a08, a09, a10, a11,
                      a12, a13, a14, a15, a16, a17, a18, a19, a20, a21, a22,
                      a23, a24, a25, a26);
    completed = true;
  } __finally {
    if (completed && !AbnormalTermination() && !capture.invalid &&
        capture.traversal.glyph_count != 0 &&
        capture.traversal.frame_sequence ==
            g_leaf_frame_sequence.load(std::memory_order_acquire)) {
      capture.traversal.timestamp_ms = GetTickCount64();
      PublishLeafPrivateTraversal(capture.traversal);
      PublishLeafD3DTraceTraversal(capture.traversal);
    }
    capture = {};
  }
  return result;
}

void ResetLeafLookupCandidates() {
  memset(g_leaf_lookup_candidates, 0, sizeof(g_leaf_lookup_candidates));
}

bool ReadLeafPrivateTraversal(uint64_t expected, LeafPrivateTraversal *copy) {
  if (expected == 0 || copy == nullptr)
    return false;
  auto *slot = &g_leaf_private_traversal_slots[(expected - 1u) %
                                               kLeafPrivateTraversalSlots];
  const LONG writing_before = InterlockedCompareExchange(&slot->writing, 0, 0);
  const uint64_t sequence_before =
      static_cast<uint64_t>(InterlockedCompareExchange64(
          reinterpret_cast<volatile LONG64 *>(&slot->traversal.sequence), 0,
          0));
  if (writing_before != 0 || sequence_before != expected)
    return false;
  memcpy(copy, &slot->traversal, sizeof(*copy));
  const uint64_t sequence_after =
      static_cast<uint64_t>(InterlockedCompareExchange64(
          reinterpret_cast<volatile LONG64 *>(&slot->traversal.sequence), 0,
          0));
  const LONG writing_after = InterlockedCompareExchange(&slot->writing, 0, 0);
  return writing_after == 0 && sequence_after == expected &&
         copy->sequence == expected;
}

LeafLookupBatchCandidate *FindLeafLookupCandidateReplacement() {
  LeafLookupBatchCandidate *replacement = nullptr;
  for (auto &candidate : g_leaf_lookup_candidates) {
    if (replacement == nullptr || candidate.traversal_id == 0 ||
        candidate.frame_sequence < replacement->frame_sequence) {
      replacement = &candidate;
      if (candidate.traversal_id == 0)
        break;
    }
  }
  return replacement;
}

bool StageLeafLookupPrivateTraversal(const LeafPrivateTraversal &traversal) {
  const auto *profile = g_leaf_aquaplus_profile.load(std::memory_order_acquire);
  const bool initial_replay = traversal.sentence_epoch_at_capture == 0 &&
                              g_leaf_sentence_epoch == 1 &&
                              g_leaf_active_line_timestamp_ms == 0;
  if (profile == nullptr || g_leaf_sentence_epoch == 0 ||
      g_leaf_active_line_units == 0 || traversal.traversal_id == 0 ||
      traversal.glyph_count == 0 ||
      traversal.glyph_count > kLeafLookupTextUnits ||
      traversal.viewport_width <= 0 || traversal.viewport_height <= 0 ||
      (!initial_replay &&
       traversal.sentence_epoch_at_capture != g_leaf_sentence_epoch) ||
      !fushi_voice_hook::IsLeafAquaplusTraceForSentence(
          traversal.sequence, traversal.timestamp_ms,
          g_leaf_sentence_trace_floor, g_leaf_active_line_timestamp_ms)) {
    return false;
  }
  uint32_t char_indices[kLeafLookupTextUnits] = {};
  size_t visible_count = 0;
  if (!fushi_voice_hook::CollectLeafAquaplusVisibleCharMap(
          g_leaf_active_line, g_leaf_active_line_units, char_indices,
          kLeafLookupTextUnits, &visible_count) ||
      visible_count > traversal.glyph_count) {
    return false;
  }
  fushi_voice_hook::LeafAquaplusGlyphDrawIdentity
      draw_identities[kLeafLookupTextUnits] = {};
  for (uint32_t index = 0; index < traversal.glyph_count; ++index) {
    const auto &captured = traversal.glyphs[index];
    draw_identities[index] = {captured.draw_format, captured.caller_rva,
                              captured.vertex_stride, captured.fvf};
  }
  if (!fushi_voice_hook::AreLeafAquaplusMatchedGlyphDrawsPrimary(
          draw_identities, traversal.glyph_count,
          static_cast<uint32_t>(profile->quad_draw_return_rva),
          profile->quad_vertex_stride, profile->quad_fvf)) {
    return false;
  }
  wchar_t decoded[kLeafLookupTextUnits] = {};
  for (uint32_t index = 0; index < traversal.glyph_count; ++index) {
    if (!DecodeLeafPackedCp932(traversal.glyphs[index].packed_cp932,
                               &decoded[index])) {
      return false;
    }
  }

  fushi_voice_hook::LeafAquaplusLookupGlyph best[kLeafLookupTextUnits] = {};
  bool found = false;
  uint32_t best_skipped = UINT32_MAX;
  double best_score = 0.0;
  for (uint32_t start = 0; start < traversal.glyph_count; ++start) {
    const wchar_t first_expected = g_leaf_active_line[char_indices[0]];
    if (!fushi_voice_hook::LeafAquaplusDecodedGlyphMatchesText(
            decoded[start], &first_expected, 1u, 0u)) {
      continue;
    }
    fushi_voice_hook::LeafAquaplusLookupGlyph matched[kLeafLookupTextUnits] =
        {};
    uint32_t source_index = start;
    uint32_t matched_count = 0;
    for (uint32_t expected = 0; expected < visible_count; ++expected) {
      bool glyph_found = false;
      for (; source_index < traversal.glyph_count; ++source_index) {
        if (!fushi_voice_hook::LeafAquaplusDecodedGlyphMatchesText(
                decoded[source_index], g_leaf_active_line,
                g_leaf_active_line_units, char_indices[expected])) {
          continue;
        }
        const auto &captured = traversal.glyphs[source_index];
        fushi_voice_hook::LeafAquaplusLookupGlyph glyph = {
            captured.left, captured.top, captured.right, captured.bottom,
            char_indices[expected]};
        if (!fushi_voice_hook::IsSaneLeafAquaplusLookupGlyph(
                glyph, traversal.viewport_x, traversal.viewport_y,
                traversal.viewport_width, traversal.viewport_height)) {
          continue;
        }
        if (matched_count != 0) {
          fushi_voice_hook::LeafAquaplusLookupGlyph pair[2] = {
              matched[matched_count - 1u], glyph};
          if (!fushi_voice_hook::IsLeafAquaplusGlyphSequenceSpatiallyMonotonic(
                  pair, 2u)) {
            continue;
          }
        }
        matched[matched_count++] = glyph;
        ++source_index;
        glyph_found = true;
        break;
      }
      if (!glyph_found)
        break;
    }
    if (matched_count != visible_count ||
        !fushi_voice_hook::IsLeafAquaplusGlyphSequenceSpatiallyMonotonic(
            matched, matched_count)) {
      continue;
    }
    const uint32_t skipped = source_index - start - matched_count;
    float max_bottom = matched[0].bottom;
    for (uint32_t index = 1; index < matched_count; ++index) {
      max_bottom = (std::max)(max_bottom, matched[index].bottom);
    }
    const double score = static_cast<double>(max_bottom);
    if (!found || skipped < best_skipped ||
        (skipped == best_skipped && score > best_score)) {
      memcpy(best, matched,
             static_cast<size_t>(matched_count) * sizeof(matched[0]));
      found = true;
      best_skipped = skipped;
      best_score = score;
    }
  }
  if (!found)
    return false;

  auto *candidate = FindLeafLookupCandidateReplacement();
  if (candidate == nullptr)
    return false;
  *candidate = {};
  candidate->traversal_id = traversal.traversal_id;
  candidate->frame_sequence = traversal.frame_sequence;
  candidate->sentence_epoch = g_leaf_sentence_epoch;
  candidate->traversal_sequence = traversal.sequence;
  candidate->glyph_count = static_cast<uint32_t>(visible_count);
  candidate->viewport_x = traversal.viewport_x;
  candidate->viewport_y = traversal.viewport_y;
  candidate->viewport_width = traversal.viewport_width;
  candidate->viewport_height = traversal.viewport_height;
  memcpy(candidate->glyphs, best, visible_count * sizeof(candidate->glyphs[0]));
  return true;
}

bool BuildLeafLookupGeometryFromCandidate(
    const LeafLookupBatchCandidate &candidate, LeafLookupGeometry *geometry,
    double *score) {
  if (geometry == nullptr || score == nullptr ||
      candidate.sentence_epoch != g_leaf_sentence_epoch ||
      candidate.traversal_id == 0 || candidate.traversal_sequence == 0 ||
      candidate.glyph_count == 0 ||
      candidate.glyph_count > kLeafLookupTextUnits ||
      candidate.viewport_width <= 0 || candidate.viewport_height <= 0) {
    return false;
  }
  LeafLookupGeometry built;
  built.sentence_epoch = candidate.sentence_epoch;
  built.text_units = g_leaf_active_line_units;
  built.viewport_x = candidate.viewport_x;
  built.viewport_y = candidate.viewport_y;
  built.viewport_width = candidate.viewport_width;
  built.viewport_height = candidate.viewport_height;
  memcpy(built.text, g_leaf_active_line,
         static_cast<size_t>(built.text_units) * sizeof(wchar_t));
  float min_left =
      static_cast<float>(candidate.viewport_x + candidate.viewport_width);
  float min_top =
      static_cast<float>(candidate.viewport_y + candidate.viewport_height);
  float max_right = 0.0f;
  float max_bottom = 0.0f;
  for (uint32_t index = 0; index < candidate.glyph_count; ++index) {
    const auto &glyph = candidate.glyphs[index];
    built.glyphs[built.glyph_count++] = glyph;
    min_left = (std::min)(min_left, glyph.left);
    min_top = (std::min)(min_top, glyph.top);
    max_right = (std::max)(max_right, glyph.right);
    max_bottom = (std::max)(max_bottom, glyph.bottom);
  }
  if (built.glyph_count == 0 ||
      max_bottom < static_cast<float>(candidate.viewport_y) +
                       static_cast<float>(candidate.viewport_height) * 0.40f) {
    return false;
  }
  // Dialogue is the lowest complete text batch matching the exact selected
  // sentence. Width is only a tie-breaker; frame animation never changes the
  // semantic sentence epoch.
  *score = static_cast<double>(max_bottom) * 10000.0 +
           static_cast<double>(min_top) * 10.0 +
           static_cast<double>(max_right - min_left);
  *geometry = built;
  return true;
}

void CommitBestLeafLookupGeometry() {
  if (g_leaf_active_geometry_valid &&
      g_leaf_active_geometry.sentence_epoch == g_leaf_sentence_epoch) {
    return;
  }
  LeafLookupGeometry best;
  bool found = false;
  uint64_t best_frame = 0;
  double best_score = 0.0;
  for (const auto &candidate : g_leaf_lookup_candidates) {
    LeafLookupGeometry geometry;
    double score = 0.0;
    if (!BuildLeafLookupGeometryFromCandidate(candidate, &geometry, &score)) {
      continue;
    }
    if (!found || candidate.frame_sequence > best_frame ||
        (candidate.frame_sequence == best_frame && score > best_score)) {
      found = true;
      best_frame = candidate.frame_sequence;
      best_score = score;
      best = geometry;
    }
  }
  if (!found)
    return;
  best.generation = ++g_leaf_geometry_generation;
  g_leaf_active_geometry = best;
  g_leaf_active_geometry_valid = true;
  SetLeafLookupDiag(fushi_voice_hook::kLookupDiagGeometryObserved);
}

uint64_t CutLeafPrivateTraversalCommittedSequence() {
  // The renderer never waits. The worker briefly owns this private publication
  // gate so a sentence cut cannot split one completed text-object traversal.
  while (InterlockedCompareExchange(&g_leaf_private_traversal_writer, 1, 0) !=
         0) {
    SwitchToThread();
  }
  const uint64_t committed = static_cast<uint64_t>(InterlockedCompareExchange64(
      &g_leaf_private_traversal_next_sequence, 0, 0));
  InterlockedExchange(&g_leaf_private_traversal_writer, 0);
  return committed;
}

void InvalidateLeafLookupSentence(bool advance_epoch,
                                  bool replay_recent_trace = false) {
  const uint64_t committed = CutLeafPrivateTraversalCommittedSequence();
  memset(g_leaf_active_line, 0, sizeof(g_leaf_active_line));
  g_leaf_active_line_units = 0;
  g_leaf_active_line_timestamp_ms = 0;
  g_leaf_sentence_trace_floor =
      replay_recent_trace ? fushi_voice_hook::LeafAquaplusRecentTraceFloor(
                                committed, kLeafPrivateTraversalSlots)
                          : committed;
  if (replay_recent_trace &&
      g_leaf_trace_processed_seq > g_leaf_sentence_trace_floor) {
    g_leaf_trace_processed_seq = g_leaf_sentence_trace_floor;
  }
  g_leaf_active_geometry = {};
  g_leaf_active_geometry_valid = false;
  ResetLeafLookupCandidates();
  InvalidateLeafLookupClickTarget();
  g_leaf_last_hit_identity = 0;
  g_leaf_last_hit_tick = 0;
  if (advance_epoch) {
    if (++g_leaf_sentence_epoch == 0)
      ++g_leaf_sentence_epoch;
    g_leaf_sentence_epoch_atomic.store(g_leaf_sentence_epoch,
                                       std::memory_order_release);
  }
}

void ConsumeLeafLookupSelectedText() {
  const auto *profile = g_leaf_aquaplus_profile.load(std::memory_order_acquire);
  if (profile == nullptr || g_header == nullptr)
    return;
  const uint64_t selected = fushi_voice_hook::SelectedTextThreadId(g_header);
  const bool selection_changed = selected != g_leaf_selected_thread_id;
  if (selection_changed) {
    const bool had_semantic_state =
        g_leaf_selected_thread_id != 0 || g_leaf_active_line_units != 0;
    g_leaf_selected_thread_id = selected;
    g_leaf_selected_face_id = 0;
    g_leaf_text_processed_seq = 0;
    InvalidateLeafLookupSentence(had_semantic_state);
    g_leaf_replay_recent_trace_for_next_line =
        selected != 0 && !had_semantic_state;
  }
  if (selected == 0)
    return;
  const uintptr_t module =
      reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr));
  if (module == 0)
    return;
  const uint64_t exact_address = module + profile->embed_leaf_hook_rva;
  const fushi_voice_hook::TextSlot *slots[fushi_voice_hook::kTextSlotCount] =
      {};
  const uint32_t found = fushi_voice_hook::CollectTextSlotsBySeq(
      g_header, slots, fushi_voice_hook::kTextSlotCount, 0);

  // Resolve the selected hook face before evaluating any sibling lane in this
  // batch. v13 intentionally keeps ctx in thread_id but not in face_id; exact
  // thread matching would lose later lines when WA2 changes call context.
  uint64_t selected_face_seq = 0;
  for (uint32_t index = 0; index < found; ++index) {
    const auto *slot = slots[index];
    if (slot == nullptr)
      continue;
    const uint64_t lane_before =
        fushi_voice_hook::AtomicLoadPreview64(&slot->lane_seq);
    const uint64_t global_seq =
        fushi_voice_hook::AtomicLoadPreview64(&slot->seq);
    const uint64_t thread_id = slot->thread_id;
    const uint64_t face_id = slot->face_id;
    const uint64_t thread_address = slot->thread_address;
    const uint32_t source_kind = slot->source_kind;
    const uint32_t event_kind = slot->event_kind;
    const uint64_t lane_after =
        fushi_voice_hook::AtomicLoadPreview64(&slot->lane_seq);
    if (lane_before == 0 || lane_after != lane_before || global_seq == 0 ||
        thread_id != selected || face_id == 0 ||
        source_kind != fushi_voice_hook::kTextSourceLuna ||
        event_kind != fushi_voice_hook::kTextEventLine ||
        thread_address != exact_address || global_seq <= selected_face_seq) {
      continue;
    }
    selected_face_seq = global_seq;
    g_leaf_selected_face_id = face_id;
  }

  constexpr uint32_t kLeafTextPayloadCapacity =
      fushi_voice_hook::kTextSlotBytes -
      static_cast<uint32_t>(sizeof(fushi_voice_hook::TextSlot));
  uint64_t newest_selected_event_seq = 0;
  auto newest_disposition =
      fushi_voice_hook::LeafAquaplusSelectedLineEventDisposition::kIgnore;
  uint64_t newest_timestamp_ms = 0;
  wchar_t newest[kLeafLookupTextUnits] = {};
  uint32_t newest_units = 0;
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
    const bool is_utf8 = slot->is_utf8 != 0;
    const bool selected_lane = fushi_voice_hook::LunaSelectedThreadAccepts(
        selected, slot->thread_id, g_leaf_selected_face_id, slot->face_id);
    const bool selected_exact_line =
        selected_lane &&
        slot->source_kind == fushi_voice_hook::kTextSourceLuna &&
        slot->event_kind == fushi_voice_hook::kTextEventLine &&
        slot->thread_address == exact_address;
    const bool payload_shape_valid =
        !is_utf8 && byte_len != 0 && (byte_len % sizeof(wchar_t)) == 0 &&
        byte_len <= kLeafTextPayloadCapacity &&
        byte_len / sizeof(wchar_t) <= kLeafLookupTextUnits;
    wchar_t candidate[kLeafLookupTextUnits] = {};
    uint32_t candidate_units = 0;
    uint64_t candidate_timestamp_ms = 0;
    if (selected_exact_line && payload_shape_valid) {
      const auto *payload = reinterpret_cast<const uint8_t *>(slot) +
                            sizeof(fushi_voice_hook::TextSlot);
      candidate_units = byte_len / sizeof(wchar_t);
      candidate_timestamp_ms = slot->timestamp_ms;
      memcpy(candidate, payload, byte_len);
    }
    const uint64_t lane_after =
        fushi_voice_hook::AtomicLoadPreview64(&slot->lane_seq);
    if (lane_after != lane_before || lane_after == 0)
      continue;
    const uint64_t consumed_sequence =
        (std::max)(g_leaf_text_processed_seq, newest_selected_event_seq);
    const auto disposition =
        fushi_voice_hook::ClassifyLeafAquaplusSelectedLineEvent(
            global_seq, consumed_sequence, selected_exact_line, is_utf8,
            byte_len, kLeafTextPayloadCapacity, kLeafLookupTextUnits);
    if (disposition ==
        fushi_voice_hook::LeafAquaplusSelectedLineEventDisposition::kIgnore) {
      continue;
    }
    newest_selected_event_seq = global_seq;
    newest_disposition = disposition;
    newest_units = 0;
    newest_timestamp_ms = 0;
    memset(newest, 0, sizeof(newest));
    if (disposition ==
        fushi_voice_hook::LeafAquaplusSelectedLineEventDisposition::
            kUseUtf16Payload) {
      newest_units = candidate_units;
      newest_timestamp_ms = candidate_timestamp_ms;
      memcpy(newest, candidate,
             static_cast<size_t>(candidate_units) * sizeof(wchar_t));
    }
  }
  if (newest_disposition ==
      fushi_voice_hook::LeafAquaplusSelectedLineEventDisposition::kIgnore) {
    return;
  }
  g_leaf_text_processed_seq = newest_selected_event_seq;
  if (newest_disposition !=
      fushi_voice_hook::LeafAquaplusSelectedLineEventDisposition::
          kUseUtf16Payload) {
    InvalidateLeafLookupSentence(g_leaf_active_line_units != 0);
    g_leaf_replay_recent_trace_for_next_line = false;
    return;
  }
  wchar_t normalized[kLeafLookupTextUnits] = {};
  size_t normalized_units = 0;
  if (!fushi_voice_hook::NormalizeLeafAquaplusLookupText(
          newest, newest_units, normalized, kLeafLookupTextUnits,
          &normalized_units) ||
      normalized_units == 0 || normalized_units > UINT32_MAX) {
    InvalidateLeafLookupSentence(g_leaf_active_line_units != 0);
    g_leaf_replay_recent_trace_for_next_line = false;
    return;
  }
  const uint32_t normalized_count = static_cast<uint32_t>(normalized_units);
  const bool same = normalized_count == g_leaf_active_line_units &&
                    normalized_count != 0 &&
                    memcmp(normalized, g_leaf_active_line,
                           normalized_units * sizeof(wchar_t)) == 0;
  if (same)
    return;

  // Fence out every renderer event committed before the semantic sentence
  // change. Trace records carry no sentence id; without this boundary an old
  // equal-length batch can be relabelled as the new line by worker ordering.
  const bool replay_recent_trace =
      g_leaf_replay_recent_trace_for_next_line && g_leaf_active_line_units == 0;
  InvalidateLeafLookupSentence(g_leaf_active_line_units != 0,
                               replay_recent_trace);
  memcpy(g_leaf_active_line, normalized, normalized_units * sizeof(wchar_t));
  g_leaf_active_line_units = normalized_count;
  g_leaf_active_line_timestamp_ms =
      replay_recent_trace ? 0 : newest_timestamp_ms;
  g_leaf_replay_recent_trace_for_next_line = false;
  if (g_leaf_sentence_epoch == 0) {
    g_leaf_sentence_epoch = 1;
    g_leaf_sentence_epoch_atomic.store(1, std::memory_order_release);
  }
}

void ConsumeLeafLookupPrivateTraversals() {
  const uint64_t latest = static_cast<uint64_t>(InterlockedCompareExchange64(
      &g_leaf_private_traversal_next_sequence, 0, 0));
  if (latest == 0 || latest == g_leaf_trace_processed_seq)
    return;
  uint64_t first = g_leaf_trace_processed_seq + 1u;
  if (latest >= kLeafPrivateTraversalSlots &&
      first <= latest - kLeafPrivateTraversalSlots) {
    first = latest - kLeafPrivateTraversalSlots + 1u;
  }
  for (uint64_t sequence = first; sequence <= latest; ++sequence) {
    if (ReadLeafPrivateTraversal(sequence,
                                 &g_leaf_private_traversal_read_copy)) {
      StageLeafLookupPrivateTraversal(g_leaf_private_traversal_read_copy);
    }
  }
  g_leaf_trace_processed_seq = latest;
  CommitBestLeafLookupGeometry();
}

bool InstallLeafAquaplusD3DTrace() {
  if (!IsLeafAquaplusProfileMatched())
    return false;
  if (g_leaf_d3d_trace_ready.load(std::memory_order_acquire))
    return true;
#if defined(_M_IX86)
  const auto *profile = g_leaf_aquaplus_profile.load(std::memory_order_acquire);
  HMODULE module = GetModuleHandleW(nullptr);
  if (profile == nullptr || module == nullptr)
    return false;
  IDirect3DDevice9 *device = nullptr;
  __try {
    device = *reinterpret_cast<IDirect3DDevice9 **>(
        reinterpret_cast<uintptr_t>(module) + profile->d3d9_device_pointer_rva);
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return false;
  }
  if (device == nullptr)
    return false;
  InterlockedOr(
      reinterpret_cast<volatile LONG *>(&FushiLeafD3DTraceV1.reserved), 0x02);
  auto *traversal_target =
      reinterpret_cast<uint8_t *>(module) + profile->text_traversal_rva;
  const bool traversal_ready =
      g_leaf_text_traversal_original != nullptr ||
      (MatchesLeafTextTraversalEntry(traversal_target) &&
       HookFn(traversal_target,
              reinterpret_cast<void *>(&Detour_LeafTextTraversal),
              reinterpret_cast<void **>(&g_leaf_text_traversal_original)) &&
       g_leaf_text_traversal_original != nullptr);
  auto *raster_target =
      reinterpret_cast<uint8_t *>(module) + profile->raster_draw_rva;
  const bool raster_ready =
      g_leaf_raster_draw_original != nullptr ||
      (MatchesLeafRasterDrawEntry(raster_target) &&
       HookFn(raster_target, reinterpret_cast<void *>(&Detour_LeafRasterDraw),
              reinterpret_cast<void **>(&g_leaf_raster_draw_original)) &&
       g_leaf_raster_draw_original != nullptr);
  if (traversal_ready && raster_ready) {
    InterlockedOr(
        reinterpret_cast<volatile LONG *>(&FushiLeafD3DTraceV1.reserved), 0x04);
  }
  const bool present_ready = HookFn(
      VtableSlot(device, 17), reinterpret_cast<void *>(&Detour_LeafPresent),
      reinterpret_cast<void **>(&g_leaf_present_original));
  if (present_ready && g_leaf_present_original != nullptr) {
    InterlockedOr(
        reinterpret_cast<volatile LONG *>(&FushiLeafD3DTraceV1.reserved), 0x08);
  }
  const bool texture_ready = HookFn(
      VtableSlot(device, 65), reinterpret_cast<void *>(&Detour_LeafSetTexture),
      reinterpret_cast<void **>(&g_leaf_set_texture_original));
  if (texture_ready && g_leaf_set_texture_original != nullptr) {
    InterlockedOr(
        reinterpret_cast<volatile LONG *>(&FushiLeafD3DTraceV1.reserved), 0x10);
  }
  const bool draw_ready =
      HookFn(VtableSlot(device, 83),
             reinterpret_cast<void *>(&Detour_LeafDrawPrimitiveUP),
             reinterpret_cast<void **>(&g_leaf_draw_primitive_up_original));
  if (draw_ready && g_leaf_draw_primitive_up_original != nullptr) {
    InterlockedOr(
        reinterpret_cast<volatile LONG *>(&FushiLeafD3DTraceV1.reserved), 0x20);
  }
  const bool ready = traversal_ready && raster_ready && present_ready &&
                     texture_ready && draw_ready &&
                     g_leaf_text_traversal_original != nullptr &&
                     g_leaf_raster_draw_original != nullptr &&
                     g_leaf_present_original != nullptr &&
                     g_leaf_set_texture_original != nullptr &&
                     g_leaf_draw_primitive_up_original != nullptr;
  g_leaf_d3d_trace_ready.store(ready, std::memory_order_release);
  if (ready) {
    InterlockedOr(
        reinterpret_cast<volatile LONG *>(&FushiLeafD3DTraceV1.reserved), 0x40);
  }
  return ready;
#else
  return false;
#endif
}

bool InstallLeafSampledInputShield() {
  if (!IsLeafAquaplusProfileMatched())
    return false;
  const ULONGLONG now = GetTickCount64();
  const HWND cached_game =
      g_leaf_sampled_input_game_window.load(std::memory_order_acquire);
  if (g_leaf_get_async_key_state_original != nullptr &&
      cached_game != nullptr &&
      cached_game == g_leaf_sampled_input_property_window &&
      IsWindow(cached_game) && g_leaf_sampled_input_last_health_tick != 0 &&
      now - g_leaf_sampled_input_last_health_tick <
          kLeafSampledInputHealthIntervalMs) {
    return true;
  }
  if (!RefreshLeafSampledInputPropertyWindow() ||
      !PublishLeafSampledInputShieldRequired()) {
    RevokeLeafSampledInputShieldReady(g_leaf_sampled_input_property_window);
    return false;
  }
  if (g_leaf_get_async_key_state_original == nullptr) {
    HMODULE user32 = GetModuleHandleW(L"user32.dll");
    if (user32 == nullptr)
      user32 = LoadLibraryW(L"user32.dll");
    void *target = user32 == nullptr ? nullptr
                                     : reinterpret_cast<void *>(GetProcAddress(
                                           user32, "GetAsyncKeyState"));
    if (target == nullptr ||
        !HookFn(
            target, reinterpret_cast<void *>(&Detour_LeafGetAsyncKeyState),
            reinterpret_cast<void **>(&g_leaf_get_async_key_state_original)) ||
        g_leaf_get_async_key_state_original == nullptr) {
      RevokeLeafSampledInputShieldReady(g_leaf_sampled_input_property_window);
      return false;
    }
  }
  if (!PublishLeafSampledInputShieldReady()) {
    RevokeLeafSampledInputShieldReady(g_leaf_sampled_input_property_window);
    return false;
  }
  return true;
}

bool PublishLeafLookupHit(const LeafLookupPayload &payload) {
  if (g_header == nullptr || payload.sentence_epoch == 0 ||
      payload.sentence_epoch != g_leaf_sentence_epoch ||
      payload.text_units == 0 || payload.text_units > kLeafLookupTextUnits ||
      payload.text_units != g_leaf_active_line_units ||
      payload.char_index >= payload.text_units ||
      memcmp(payload.text, g_leaf_active_line,
             static_cast<size_t>(payload.text_units) * sizeof(wchar_t)) != 0) {
    return false;
  }
  auto *slot = fushi_voice_hook::LookupHitOf(g_header);
  if (slot == nullptr)
    return false;
  char utf8[fushi_voice_hook::kLookupLineBytes] = {};
  const int bytes = WideCharToMultiByte(
      CP_UTF8, 0, payload.text, static_cast<int>(payload.text_units), utf8,
      static_cast<int>(sizeof(utf8)), nullptr, nullptr);
  if (bytes <= 0)
    return false;
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
  MemoryBarrier();
  InterlockedExchange64(reinterpret_cast<volatile LONG64 *>(&slot->seq),
                        static_cast<LONG64>(next));
  InterlockedExchange64(
      reinterpret_cast<volatile LONG64 *>(&g_header->lookup_hit_count),
      static_cast<LONG64>(next));
  SetLeafLookupDiag(fushi_voice_hook::kLookupDiagHitSubmitted);
  return true;
}

bool PublishLeafLookupPayload(const LeafLookupPayload &payload) {
  if (!g_leaf_lookup_runtime_enabled.load(std::memory_order_acquire) ||
      payload.activation_epoch !=
          g_leaf_lookup_activation_epoch.load(std::memory_order_acquire) ||
      payload.sentence_epoch != g_leaf_sentence_epoch ||
      payload.text_units == 0 || payload.char_index >= payload.text_units) {
    return false;
  }
  const ULONGLONG now = GetTickCount64();
  uint64_t identity = 1469598103934665603ull;
  const auto hash_value = [&identity](uint64_t value) {
    identity ^= value;
    identity *= 1099511628211ull;
  };
  hash_value(payload.sentence_epoch);
  hash_value(payload.text_units);
  for (uint32_t index = 0; index < payload.text_units; ++index) {
    hash_value(static_cast<uint32_t>(payload.text[index]));
  }
  hash_value(payload.char_index);
  hash_value(static_cast<uint32_t>(payload.rect.x));
  hash_value(static_cast<uint32_t>(payload.rect.y));
  if (identity == g_leaf_last_hit_identity && now >= g_leaf_last_hit_tick &&
      now - g_leaf_last_hit_tick <= kLeafLookupDuplicateHitWindowMs) {
    return false;
  }
  if (!PublishLeafLookupHit(payload))
    return false;
  g_leaf_last_hit_identity = identity;
  g_leaf_last_hit_tick = now;
  return true;
}

void SetLeafLookupRuntimeEnabled(bool enabled) {
  const bool previous = g_leaf_lookup_runtime_enabled.exchange(
      enabled, std::memory_order_acq_rel);
  if (previous != enabled) {
    g_leaf_lookup_activation_epoch.fetch_add(1u, std::memory_order_acq_rel);
  }
  if (!enabled) {
    // The worker owns this cursor. Advance it to the latest publication so a
    // submit queued just before disable cannot surface after a later re-enable;
    // the payload activation epoch rejects a racing in-flight publisher too.
    g_leaf_lookup_click_processed_seq = static_cast<uint64_t>(
        InterlockedCompareExchange64(&g_leaf_lookup_click_event_count, 0, 0));
  }
}

void ProcessLeafAquaplusLookupTick() {
  const uint32_t poller_conflicts =
      static_cast<uint32_t>(InterlockedCompareExchange(
          reinterpret_cast<volatile LONG *>(
              &FushiLeafD3DTraceV1.input_poller_conflicts),
          0, 0));
  const bool poller_contended =
      poller_conflicts != g_leaf_lookup_seen_poller_conflicts;
  g_leaf_lookup_seen_poller_conflicts = poller_conflicts;
  InterlockedExchange(reinterpret_cast<volatile LONG *>(
                          &FushiLeafD3DTraceV1.input_poller_contended),
                      poller_contended ? 1 : 0);
  if (poller_contended) {
    ReleaseDeadLeafInputPollerOwner();
    SetLeafLookupRuntimeEnabled(false);
    InvalidateLeafLookupClickTarget();
    return;
  }
  if (g_stop || g_header == nullptr ||
      !fushi_voice_hook::HasLookupRegion(g_header) ||
      g_header->lookup_enabled == 0) {
    SetLeafLookupRuntimeEnabled(false);
    InvalidateLeafLookupClickTarget();
    return;
  }
  const bool input_ready = InstallLeafSampledInputShield();
  const bool geometry_ready = InstallLeafAquaplusD3DTrace();
  if (!input_ready || !geometry_ready) {
    SetLeafLookupRuntimeEnabled(false);
    InvalidateLeafLookupClickTarget();
    return;
  }
  SetLeafLookupDiag(fushi_voice_hook::kLookupDiagSensorInstalled);
  ConsumeLeafLookupSelectedText();
  ConsumeLeafLookupPrivateTraversals();
  SetLeafLookupRuntimeEnabled(true);

  bool click_submitted = false;
  LeafLookupClickEvent click_event;
  uint64_t click_sequence = 0;
  if (ReadLatestLeafLookupClickSubmit(&click_event, &click_sequence)) {
    g_leaf_lookup_click_processed_seq = click_sequence;
    click_submitted = PublishLeafLookupPayload(click_event.payload);
  }

  const uint16_t shift_state =
      static_cast<uint16_t>(GetAsyncKeyState(VK_SHIFT));
  const uint64_t activation_epoch =
      g_leaf_lookup_activation_epoch.load(std::memory_order_acquire);
  const bool shift_submit =
      fushi_voice_hook::ConsumeLeafAquaplusLookupShiftSample(
          shift_state, activation_epoch, &g_leaf_lookup_shift_state);
  if (!g_leaf_active_geometry_valid ||
      g_leaf_active_geometry.sentence_epoch != g_leaf_sentence_epoch) {
    InvalidateLeafLookupClickTarget();
    return;
  }

  HWND game = FindGameMainWindow();
  RECT client = {};
  POINT origin = {0, 0};
  POINT cursor = {};
  if (game == nullptr || !GetClientRect(game, &client) ||
      !ClientToScreen(game, &origin) || !GetCursorPos(&cursor)) {
    InvalidateLeafLookupClickTarget();
    return;
  }
  const int32_t client_width = client.right - client.left;
  const int32_t client_height = client.bottom - client.top;
  const HWND direct_popup = GetValidPublishedLeafSampledInputShieldPopup(game);
  const bool direct_popup_visible =
      direct_popup != nullptr && IsLeafSampledInputShieldReadyPublished(game);
  const bool popup_visible =
      direct_popup_visible || IsLookupOverlayInputShieldVisible();
  if (!popup_visible) {
    PublishLeafLookupClickTarget(game, origin, client_width, client_height);
  } else {
    InvalidateLeafLookupClickTarget();
  }

  const HWND point_window = WindowFromPoint(cursor);
  const bool game_point = GetForegroundWindow() == game &&
                          point_window != nullptr &&
                          (point_window == game || IsChild(game, point_window));
  if (!shift_submit || click_submitted || popup_visible || !game_point)
    return;
  LeafLookupClickTarget target;
  if (!ReadLeafLookupClickTarget(&target))
    return;
  LeafLookupPayload payload;
  if (BuildLeafLookupPayloadAtPress(target, game, cursor, &payload)) {
    PublishLeafLookupPayload(payload);
  }
}

class LeafAquaplusAdapter final : public fushi_voice_hook::EngineAdapter {
public:
  const char *id() const override { return "leaf_aquaplus"; }
  bool probe() const override { return IsLeafAquaplusProfileMatched(); }
  bool install() override {
    const bool resource_ready = TryHookLeafAquaplusResourceAudio();
    const bool input_ready = InstallLeafSampledInputShield();
    const bool geometry_ready = InstallLeafAquaplusD3DTrace();
    installed_ = resource_ready || (input_ready && geometry_ready) ||
                 installed_;
    return installed_;
  }
  void ProcessPendingEvents() {
    install();
    ProcessLeafVoiceTasks();
    ProcessLeafAquaplusLookupTick();
  }
  fushi_voice_hook::AdapterCapability capabilities() const override {
    return fushi_voice_hook::AdapterCapability::kText |
           fushi_voice_hook::AdapterCapability::kResourceAudio |
           fushi_voice_hook::AdapterCapability::kPcmAudio;
  }
  void onModuleLoaded(const wchar_t *) override { install(); }
  void shutdown() override {
    StopLeafAquaplusResourceAudio();
    SetLeafLookupRuntimeEnabled(false);
    g_leaf_d3d_trace_ready.store(false, std::memory_order_release);
    g_leaf_sampled_input_latched_buttons.store(0, std::memory_order_release);
    // 争用账本也要收干净：owner 槽位撤回 0，当前争用状态清零，并把 worker 侧的
    // 冲突基线对齐到当前计数，免得下一次 install 把旧计数当成新增量。
    g_leaf_input_poller_owner_tid.store(0, std::memory_order_release);
    InterlockedExchange(reinterpret_cast<volatile LONG *>(
                            &FushiLeafD3DTraceV1.input_poller_owner_tid),
                        0);
    InterlockedExchange(reinterpret_cast<volatile LONG *>(
                            &FushiLeafD3DTraceV1.input_poller_contended),
                        0);
    g_leaf_lookup_seen_poller_conflicts =
        static_cast<uint32_t>(InterlockedCompareExchange(
            reinterpret_cast<volatile LONG *>(
                &FushiLeafD3DTraceV1.input_poller_conflicts),
            0, 0));
    InvalidateLeafLookupClickTarget();
    RevokeLeafSampledInputShieldReady(g_leaf_sampled_input_property_window);
    installed_ = false;
  }
  fushi_voice_hook::AdapterDiagnostics diagnostics() const override {
    return {id(), probe(), installed_,
            g_header == nullptr ? 0u : g_header->lookup_diag};
  }

private:
  bool installed_ = false;
};
