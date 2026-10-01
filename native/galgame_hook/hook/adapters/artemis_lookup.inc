// Artemis Engine in-game lookup runtime (EngineExactLayout /
// kLookupGeometryProviderIdArtemis).  Engine facts, signatures and every
// decision rule live in artemis_lookup_core.h and are unit-tested; this file
// only binds them to MinHook, Win32 and the v19 registry.
//
// Threads:
//   * game thread — three detours, all bounded and allocation-free:
//       Layer::CreateGlyph  remembers {glyph address -> character, creation
//                           seq} (LunaHook keeps its own constructor hook);
//       glyph vtable slot 4 appends the drawn glyph's world cell to the frame
//                           being built (only visible glyphs are drawn);
//       Input::Update       publishes the finished frame, then owns a bare
//                           left press that lands on a mapped glyph: the
//                           engine key state is masked from press to release so
//                           the click never advances the script.
//   * HookWorker — ProcessArtemisLookupTick: matches the selected LunaHook line
//     against the newest drawn glyphs, checks each glyph's world scale against
//     the engine's root letterbox scale (world units are engine client
//     pixels), scales them to physical client pixels, offers/retires the
//     provider,
//     publishes the model the game thread hit-tests against, and turns queued
//     presses into registry hits.
//
// Fail closed everywhere: an unresolved signature installs nothing, a frame
// older than kArtemisFrameStaleMs, a text mismatch, a glyph outside the client
// or a missing native-input admission all retire the provider or refuse the
// click, and the click then reaches the game unchanged.

#if defined(_M_X64)

namespace artemis_lookup = fushi_voice_hook::artemis_lookup;

using ArtemisGlyphFactoryFn = void*(__fastcall*)(void*, const char*, void*,
                                                 void*);
using ArtemisGlyphDrawFn = uint64_t(__fastcall*)(void*, void*, float);
using ArtemisInputUpdateFn = uint64_t(__fastcall*)(void*, uintptr_t,
                                                   uintptr_t, uintptr_t);

constexpr uint32_t kArtemisModelSlots = 2u;
constexpr uint32_t kArtemisSubmitSlots = 8u;
constexpr uint64_t kArtemisFrameStaleMs = 250u;
constexpr uint32_t kArtemisModelLogBudget = 24u;

struct ArtemisFrame {
  uint64_t frame = 0u;
  uint64_t tick = 0u;
  uintptr_t window = 0u;
  artemis_lookup::EngineProjection projection;
  uint32_t count = 0u;
  bool overflow = false;
  std::array<artemis_lookup::FrameGlyph, artemis_lookup::kMaxFrameGlyphs>
      glyphs{};
};

struct ArtemisModel {
  uint64_t generation = 0u;
  uintptr_t window = 0u;
  int32_t physical_w = 0;
  int32_t physical_h = 0;
  int32_t engine_w = 0;
  int32_t engine_h = 0;
  uint32_t count = 0u;
  std::array<artemis_lookup::ModelGlyph, artemis_lookup::kMaxFrameGlyphs>
      glyphs{};
};

struct ArtemisSubmit {
  uint64_t generation = 0u;
  uint32_t glyph = 0u;
};

struct ArtemisLookupRuntime {
  // ── HookWorker-owned ──
  bool resolved = false;
  bool hooks_installed = false;
  bool installed = false;
  artemis_lookup::SiteResult site_result = artemis_lookup::SiteResult::kNotX64;
  artemis_lookup::Sites sites;
  bool provider_offered = false;
  uint64_t processed_submit_seq = 0u;
  uint64_t next_generation = 0u;
  uint32_t logged_models = 0u;
  ArtemisModel model;          // the published model (worker copy)
  std::wstring model_line;     // selected text the model was matched against
  uint64_t model_text_event = 0u;
  ArtemisFrame frame_copy;     // scratch for the seqlock read

  // ── game-thread-owned ──
  artemis_lookup::GlyphCodeTable<> codes;
  uint64_t glyph_seq = 0u;
  ArtemisFrame building;
  artemis_lookup::ClaimState claim;
  DWORD game_thread = 0u;
  ArtemisModel game_model;  // scratch for the press-time model read

  // ── shared ──
  std::atomic<bool> live{false};
  SRWLOCK codes_lock = SRWLOCK_INIT;
  std::array<std::atomic<uint32_t>, 2u> frame_seq = {};
  std::array<ArtemisFrame, 2u> frames = {};
  std::atomic<uint32_t> published_frame{UINT32_MAX};
  std::array<std::atomic<uint32_t>, kArtemisModelSlots> model_seq = {};
  std::array<ArtemisModel, kArtemisModelSlots> models = {};
  std::atomic<uint32_t> published_model{UINT32_MAX};
  std::array<std::atomic<uint64_t>, kArtemisSubmitSlots> submit_seq = {};
  std::array<ArtemisSubmit, kArtemisSubmitSlots> submits = {};
  std::atomic<uint64_t> submit_count{0u};
  std::atomic<uint64_t> claimed_presses{0u};
};

ArtemisLookupRuntime g_artemis_lookup;
ArtemisGlyphFactoryFn g_artemis_glyph_factory_original = nullptr;
ArtemisGlyphDrawFn g_artemis_glyph_draw_original = nullptr;
ArtemisInputUpdateFn g_artemis_input_update_original = nullptr;

// ── two-slot seqlocks ──────────────────────────────────────────────────────

template <typename T, size_t Slots>
void PublishArtemisSlot(std::array<std::atomic<uint32_t>, Slots>& seqs,
                        std::array<T, Slots>& slots,
                        std::atomic<uint32_t>& published, const T& value,
                        size_t bytes) {
  const uint32_t current = published.load(std::memory_order_acquire);
  const uint32_t slot =
      current >= Slots ? 0u : static_cast<uint32_t>((current + 1u) % Slots);
  const uint32_t seq = seqs[slot].load(std::memory_order_relaxed);
  seqs[slot].store(seq | 1u, std::memory_order_release);
  std::atomic_thread_fence(std::memory_order_release);
  std::memcpy(&slots[slot], &value, bytes);
  std::atomic_thread_fence(std::memory_order_release);
  seqs[slot].store((seq | 1u) + 1u, std::memory_order_release);
  published.store(slot, std::memory_order_release);
}

template <typename T, size_t Slots>
bool ReadArtemisSlot(const std::array<std::atomic<uint32_t>, Slots>& seqs,
                     const std::array<T, Slots>& slots,
                     const std::atomic<uint32_t>& published, T* out,
                     size_t bytes) {
  const uint32_t slot = published.load(std::memory_order_acquire);
  if (out == nullptr || slot >= Slots) return false;
  const uint32_t before = seqs[slot].load(std::memory_order_acquire);
  if (before == 0u || (before & 1u) != 0u) return false;
  std::atomic_thread_fence(std::memory_order_acquire);
  std::memcpy(out, &slots[slot], bytes);
  std::atomic_thread_fence(std::memory_order_acquire);
  return seqs[slot].load(std::memory_order_acquire) == before &&
         published.load(std::memory_order_acquire) == slot;
}

// Only the header and the used prefix of the glyph array are copied.
size_t ArtemisFrameBytes(uint32_t count) {
  return offsetof(ArtemisFrame, glyphs) +
         static_cast<size_t>(count) * sizeof(artemis_lookup::FrameGlyph);
}

size_t ArtemisModelBytes(uint32_t count) {
  return offsetof(ArtemisModel, glyphs) +
         static_cast<size_t>(count) * sizeof(artemis_lookup::ModelGlyph);
}

bool ReadArtemisModel(ArtemisModel* out) {
  auto& rt = g_artemis_lookup;
  // Copy the header first to learn the count, then the whole used prefix
  // under the same sequence check.
  if (!ReadArtemisSlot(rt.model_seq, rt.models, rt.published_model, out,
                       offsetof(ArtemisModel, glyphs))) {
    return false;
  }
  const uint32_t count = (std::min)(
      out->count, static_cast<uint32_t>(artemis_lookup::kMaxFrameGlyphs));
  return ReadArtemisSlot(rt.model_seq, rt.models, rt.published_model, out,
                         ArtemisModelBytes(count)) &&
         out->count == count;
}

void InvalidateArtemisModel() {
  g_artemis_lookup.published_model.store(UINT32_MAX, std::memory_order_release);
}

// ── game-thread detours ─────────────────────────────────────────────────────

uint32_t ReadArtemisFactoryCharacter(const char* text) {
  __try {
    return artemis_lookup::DecodeFactoryCharacter(
        reinterpret_cast<const uint8_t*>(text));
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return 0u;
  }
}

void* __fastcall ArtemisGlyphFactoryDetour(void* layer, const char* text,
                                           void* extra, void* extra2) {
  void* glyph =
      g_artemis_glyph_factory_original(layer, text, extra, extra2);
  auto& rt = g_artemis_lookup;
  if (glyph != nullptr && text != nullptr &&
      rt.live.load(std::memory_order_acquire)) {
    const uint32_t codepoint = ReadArtemisFactoryCharacter(text);
    AcquireSRWLockExclusive(&rt.codes_lock);
    rt.codes.Remember(reinterpret_cast<uintptr_t>(glyph), codepoint,
                      ++rt.glyph_seq);
    ReleaseSRWLockExclusive(&rt.codes_lock);
  }
  return glyph;
}

// Reads one drawn glyph.  `glyph` is the object the engine is drawing right
// now; the vptr check keeps other node classes that may share this forwarder
// out of the frame.
void RecordArtemisDrawnGlyph(const uint8_t* glyph) {
  auto& rt = g_artemis_lookup;
  if (GetCurrentThreadId() != rt.game_thread) return;
  uintptr_t vptr = 0u, matrix_vptr = 0u, parent_matrix_vptr = 0u;
  std::memcpy(&vptr, glyph, sizeof(vptr));
  if (vptr != rt.sites.glyph_vtable) return;
  std::memcpy(&matrix_vptr, glyph + artemis_lookup::kGlyphMatrixVptrOffset,
              sizeof(matrix_vptr));
  std::memcpy(&parent_matrix_vptr,
              glyph + artemis_lookup::kGlyphParentMatrixVptrOffset,
              sizeof(parent_matrix_vptr));
  if (matrix_vptr == 0u || matrix_vptr != parent_matrix_vptr) return;
  if (rt.building.count >= artemis_lookup::kMaxFrameGlyphs) {
    rt.building.overflow = true;
    return;
  }
  artemis_lookup::GlyphCode code;
  if (!TryAcquireSRWLockShared(&rt.codes_lock)) return;
  const bool known = rt.codes.Find(reinterpret_cast<uintptr_t>(glyph), &code);
  ReleaseSRWLockShared(&rt.codes_lock);
  if (!known) return;
  float matrix[6] = {};
  float cell[2] = {};
  std::memcpy(matrix, glyph + artemis_lookup::kGlyphWorldMatrixOffset,
              sizeof(matrix));
  std::memcpy(cell, glyph + artemis_lookup::kGlyphCellOffset, sizeof(cell));
  artemis_lookup::FrameGlyph& out = rt.building.glyphs[rt.building.count];
  if (!artemis_lookup::ComputeCellBounds(matrix, cell[0], cell[1],
                                         &out.bounds)) {
    return;
  }
  std::memcpy(out.matrix, matrix, sizeof(matrix));
  out.seq = code.seq;
  out.codepoint = code.codepoint;
  ++rt.building.count;
}

void RecordArtemisDrawnGlyphGuarded(void* glyph) {
  __try {
    RecordArtemisDrawnGlyph(static_cast<const uint8_t*>(glyph));
  } __except (EXCEPTION_EXECUTE_HANDLER) {
  }
}

uint64_t __fastcall ArtemisGlyphDrawDetour(void* glyph, void* context,
                                           float value) {
  if (glyph != nullptr &&
      g_artemis_lookup.live.load(std::memory_order_acquire)) {
    RecordArtemisDrawnGlyphGuarded(glyph);
  }
  return g_artemis_glyph_draw_original(glyph, context, value);
}

bool ReadArtemisInputProjection(const uint8_t* input, uintptr_t* window,
                                artemis_lookup::EngineProjection* projection) {
  __try {
    std::memcpy(&projection->design_per_client,
                input + artemis_lookup::kInputScaleOffset, sizeof(float));
    std::memcpy(&projection->offset_x,
                input + artemis_lookup::kInputOffsetXOffset, sizeof(float));
    std::memcpy(&projection->offset_y,
                input + artemis_lookup::kInputOffsetYOffset, sizeof(float));
    std::memcpy(window, input + artemis_lookup::kInputWindowOffset,
                sizeof(uintptr_t));
    return true;
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return false;
  }
}

// Frame boundary: every draw of the previous frame has run by the time the
// next Input::Update starts.
void PublishArtemisFrame(void* input) {
  auto& rt = g_artemis_lookup;
  ArtemisFrame& frame = rt.building;
  frame.tick = GetTickCount64();
  ++frame.frame;
  uintptr_t window = 0u;
  RECT client = {};
  if (ReadArtemisInputProjection(static_cast<const uint8_t*>(input), &window,
                                 &frame.projection) &&
      window != 0u && GetClientRect(reinterpret_cast<HWND>(window), &client)) {
    frame.window = window;
    frame.projection.engine_client_w = client.right - client.left;
    frame.projection.engine_client_h = client.bottom - client.top;
  } else {
    frame.window = 0u;
    frame.projection = {};
  }
  PublishArtemisSlot(rt.frame_seq, rt.frames, rt.published_frame, frame,
                     ArtemisFrameBytes(frame.count));
  frame.count = 0u;
  frame.overflow = false;
}

void QueueArtemisSubmit(const ArtemisSubmit& submit) {
  auto& rt = g_artemis_lookup;
  const uint64_t sequence =
      rt.submit_count.load(std::memory_order_acquire) + 1u;
  auto& slot_seq = rt.submit_seq[sequence % kArtemisSubmitSlots];
  slot_seq.store(0u, std::memory_order_release);
  std::atomic_thread_fence(std::memory_order_release);
  rt.submits[sequence % kArtemisSubmitSlots] = submit;
  std::atomic_thread_fence(std::memory_order_release);
  slot_seq.store(sequence, std::memory_order_release);
  rt.submit_count.store(sequence, std::memory_order_release);
}

bool ArtemisShieldActive(HWND game) {
  if (IsLookupOverlayInputShieldVisible()) return true;
  if (g_header == nullptr) return false;
  const auto request = fushi_voice_hook::ReadLookupShieldRequest(g_header);
  return request.valid && request.active_buttons != 0u &&
         request.target_hwnd ==
             static_cast<uint64_t>(reinterpret_cast<uintptr_t>(game));
}

// A fresh engine-reported press: may this press become a lookup?  Only a
// bare left press on exactly one mapped glyph of the current model, in the
// foreground game window, with the host's native-input admission applied and
// no lookup card already shielding the game.
bool ArtemisPressEligible(const uint8_t* input, ArtemisSubmit* submit) {
  if (g_header == nullptr || g_stop ||
      !fushi_voice_hook::HasLookupRegion(g_header) ||
      fushi_voice_hook::AtomicLoadShared32(&g_header->lookup_enabled) == 0u) {
    return false;
  }
  ArtemisModel& model = g_artemis_lookup.game_model;
  if (!ReadArtemisModel(&model) || model.generation == 0u ||
      model.count == 0u) {
    return false;
  }
  uintptr_t window = 0u;
  artemis_lookup::EngineProjection ignored;
  if (!ReadArtemisInputProjection(input, &window, &ignored) ||
      window != model.window) {
    return false;
  }
  const HWND game = reinterpret_cast<HWND>(window);
  if (!fushi_voice_hook::g_geometry_provider_registry.NativeInputAllowed(
          g_header, fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
          fushi_voice_hook::kLookupGeometryProviderIdArtemis) ||
      ArtemisShieldActive(game) || GetForegroundWindow() != game ||
      (GetKeyState(VK_SHIFT) & 0x8000) != 0 ||
      (GetKeyState(VK_CONTROL) & 0x8000) != 0 ||
      (GetKeyState(VK_MENU) & 0x8000) != 0) {
    return false;
  }
  POINT cursor = {};
  RECT client = {};
  if (!GetCursorPos(&cursor)) return false;
  const HWND under = WindowFromPoint(cursor);
  if ((under != game && !IsChild(game, under)) ||
      !ScreenToClient(game, &cursor) || !GetClientRect(game, &client) ||
      client.right - client.left != model.engine_w ||
      client.bottom - client.top != model.engine_h) {
    return false;
  }
  size_t hit = 0u;
  if (!artemis_lookup::HitTestModel(model.glyphs.data(), model.count,
                                    model.physical_w, model.physical_h,
                                    model.engine_w, model.engine_h, cursor.x,
                                    cursor.y, &hit)) {
    return false;
  }
  submit->generation = model.generation;
  submit->glyph = static_cast<uint32_t>(hit);
  return true;
}

void ClaimArtemisLeftButton(void* input) {
  auto& rt = g_artemis_lookup;
  auto* state = reinterpret_cast<uint32_t*>(
      static_cast<uint8_t*>(input) + artemis_lookup::kInputKeyStateOffset +
      artemis_lookup::kLeftButtonKey * sizeof(uint32_t));
  const uint32_t value = *state;
  ArtemisSubmit submit;
  const bool eligible =
      !rt.claim.owned && value == artemis_lookup::kKeyStatePressed &&
      ArtemisPressEligible(static_cast<const uint8_t*>(input), &submit);
  const auto decision =
      artemis_lookup::DecideLeftButton(value, eligible, &rt.claim);
  if (decision.submit) {
    QueueArtemisSubmit(submit);
    rt.claimed_presses.fetch_add(1u, std::memory_order_relaxed);
  }
  if (decision.mask) *state = artemis_lookup::kKeyStateIdle;
}

void ClaimArtemisLeftButtonGuarded(void* input) {
  __try {
    ClaimArtemisLeftButton(input);
  } __except (EXCEPTION_EXECUTE_HANDLER) {
  }
}

void PublishArtemisFrameGuarded(void* input) {
  __try {
    PublishArtemisFrame(input);
  } __except (EXCEPTION_EXECUTE_HANDLER) {
  }
}

uint64_t __fastcall ArtemisInputUpdateDetour(void* input, uintptr_t now,
                                             uintptr_t r8, uintptr_t r9) {
  auto& rt = g_artemis_lookup;
  const bool live = input != nullptr && rt.live.load(std::memory_order_acquire);
  if (live) {
    if (rt.game_thread == 0u) rt.game_thread = GetCurrentThreadId();
    if (GetCurrentThreadId() == rt.game_thread) PublishArtemisFrameGuarded(input);
  }
  const uint64_t result = g_artemis_input_update_original(input, now, r8, r9);
  if (live && GetCurrentThreadId() == rt.game_thread) {
    ClaimArtemisLeftButtonGuarded(input);
  }
  return result;
}

// ── HookWorker ──────────────────────────────────────────────────────────────

// Worker-only, bounded diagnostics in %TEMP%\fushi_galhook.log (the injected
// side has no other text channel).  Never logs dialogue text.
void ArtemisLookupLog(const wchar_t* format, ...) {
  wchar_t line[512] = {};
  va_list args;
  va_start(args, format);
  _vsnwprintf_s(line, _TRUNCATE, format, args);
  va_end(args);
  wchar_t path[MAX_PATH] = {};
  const DWORD length = GetTempPathW(MAX_PATH, path);
  if (length == 0 || length >= MAX_PATH - 20) return;
  wcscat_s(path, L"fushi_galhook.log");
  HANDLE file = g_orig_CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ,
                                   nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL,
                                   nullptr);
  if (file == INVALID_HANDLE_VALUE) return;
  SYSTEMTIME now = {};
  GetLocalTime(&now);
  wchar_t stamped[640] = {};
  _snwprintf_s(stamped, _TRUNCATE, L"%02u:%02u:%02u.%03u pid=%lu %s\r\n",
               now.wHour, now.wMinute, now.wSecond, now.wMilliseconds,
               GetCurrentProcessId(), line);
  char utf8[1920] = {};
  const int bytes = WideCharToMultiByte(CP_UTF8, 0, stamped, -1, utf8,
                                        sizeof(utf8), nullptr, nullptr);
  if (bytes > 1) {
    DWORD written = 0;
    WriteFile(file, utf8, static_cast<DWORD>(bytes - 1), &written, nullptr);
  }
  g_orig_CloseHandle(file);
}

bool ComputeArtemisExecutableSha256(uint8_t digest[32]) {
  wchar_t path[MAX_PATH] = {};
  if (GetModuleFileNameW(nullptr, path, MAX_PATH) == 0) return false;
  HANDLE file = g_orig_CreateFileW(
      path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
      nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  BCRYPT_HASH_HANDLE hash = nullptr;
  bool ok = BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM,
                                        nullptr, 0) >= 0 &&
            BCryptCreateHash(algorithm, &hash, nullptr, 0, nullptr, 0, 0) >= 0;
  std::vector<uint8_t> buffer(1u << 20);
  while (ok) {
    DWORD read = 0;
    if (!ReadFile(file, buffer.data(), static_cast<DWORD>(buffer.size()), &read,
                  nullptr)) {
      ok = false;
      break;
    }
    if (read == 0) break;
    ok = BCryptHashData(hash, buffer.data(), read, 0) >= 0;
  }
  ok = ok && BCryptFinishHash(hash, digest, 32, 0) >= 0;
  if (hash != nullptr) BCryptDestroyHash(hash);
  if (algorithm != nullptr) BCryptCloseAlgorithmProvider(algorithm, 0);
  g_orig_CloseHandle(file);
  return ok;
}

// Milliseconds since the game process was created: tells whether the hooks
// landed before the injector resumed the suspended game.
uint64_t ArtemisProcessAgeMs() {
  FILETIME created = {}, exited = {}, kernel = {}, user = {}, now = {};
  if (!GetProcessTimes(GetCurrentProcess(), &created, &exited, &kernel,
                       &user)) {
    return 0u;
  }
  GetSystemTimeAsFileTime(&now);
  const uint64_t start =
      (static_cast<uint64_t>(created.dwHighDateTime) << 32) |
      created.dwLowDateTime;
  const uint64_t current =
      (static_cast<uint64_t>(now.dwHighDateTime) << 32) | now.dwLowDateTime;
  return current > start ? (current - start) / 10000u : 0u;
}

// Creates the three detours first and enables them in one MinHook
// transaction: one freeze of the game's threads instead of three.  Each
// freeze suspends every thread and reads its context; the adapter can run
// after the injector resumed the game (the PF8 index parse and earlier
// adapters outlive the startup budget), so fewer freezes means fewer chances
// to catch a renderer/driver thread mid-initialisation.  All or nothing: a
// target someone else already hooked, or any MinHook failure, installs none.
bool InstallArtemisHooksBatched(const artemis_lookup::Sites& sites) {
  struct Site {
    void* target;
    void* detour;
    void** original;
  };
  const Site plan[] = {
      {reinterpret_cast<void*>(sites.glyph_factory),
       reinterpret_cast<void*>(&ArtemisGlyphFactoryDetour),
       reinterpret_cast<void**>(&g_artemis_glyph_factory_original)},
      {reinterpret_cast<void*>(sites.glyph_draw),
       reinterpret_cast<void*>(&ArtemisGlyphDrawDetour),
       reinterpret_cast<void**>(&g_artemis_glyph_draw_original)},
      {reinterpret_cast<void*>(sites.input_update),
       reinterpret_cast<void*>(&ArtemisInputUpdateDetour),
       reinterpret_cast<void**>(&g_artemis_input_update_original)},
  };
  constexpr int kSites = static_cast<int>(sizeof(plan) / sizeof(plan[0]));
  if (!g_cs_ready) return false;
  EnterCriticalSection(&g_cs);
  bool ok = g_hooked_count + kSites <= 64;
  for (int i = 0; ok && i < g_hooked_count; ++i) {
    for (const Site& site : plan) ok = ok && g_hooked_fns[i] != site.target;
  }
  int created = 0;
  for (; ok && created < kSites; ++created) {
    const Site& site = plan[created];
    if (site.target == nullptr ||
        MH_CreateHook(site.target, site.detour, site.original) != MH_OK) {
      ok = false;
      break;
    }
  }
  for (int i = 0; ok && i < kSites; ++i) {
    ok = MH_QueueEnableHook(plan[i].target) == MH_OK;
  }
  ok = ok && MH_ApplyQueued() == MH_OK;
  if (ok) {
    for (const Site& site : plan) g_hooked_fns[g_hooked_count++] = site.target;
  } else {
    for (int i = 0; i < created; ++i) MH_RemoveHook(plan[i].target);
    for (const Site& site : plan) *site.original = nullptr;
  }
  LeaveCriticalSection(&g_cs);
  return ok;
}

bool InstallArtemisLookup() {
  auto& rt = g_artemis_lookup;
  if (rt.installed) return true;
  if (rt.resolved) {
    // Re-install after a shutdown: the MinHook detours are still chained and
    // only need to start recording again.  A rejected image stays rejected.
    if (!rt.hooks_installed) return false;
    rt.live.store(true, std::memory_order_release);
    rt.installed = true;
    return true;
  }
  rt.resolved = true;
  LARGE_INTEGER frequency = {}, started = {}, finished = {};
  QueryPerformanceFrequency(&frequency);
  QueryPerformanceCounter(&started);
  fushi_voice_hook::exact_lookup::LoadedPeImage image;
  if (!fushi_voice_hook::exact_lookup::OpenLoadedPeImage(
          GetModuleHandleW(nullptr), &image)) {
    rt.site_result = artemis_lookup::SiteResult::kFactoryMissing;
  } else {
    rt.site_result = artemis_lookup::ResolveSites(image, &rt.sites);
  }
  QueryPerformanceCounter(&finished);
  const double scan_ms =
      frequency.QuadPart > 0
          ? 1000.0 * static_cast<double>(finished.QuadPart - started.QuadPart) /
                static_cast<double>(frequency.QuadPart)
          : 0.0;
  const uintptr_t base = reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr));
  if (rt.site_result != artemis_lookup::SiteResult::kResolved) {
    uint8_t digest[32] = {};
    if (ComputeArtemisExecutableSha256(digest)) {
      fushi_voice_hook::PublishHostExecutableSha256(digest, sizeof(digest));
    }
    ArtemisLookupLog(L"artemis-lookup: sites unresolved result=%u scan=%.1fms",
                     static_cast<unsigned>(rt.site_result), scan_ms);
    return false;
  }
  rt.codes.Clear();
  rt.glyph_seq = 0u;
  rt.building = ArtemisFrame();
  rt.claim = artemis_lookup::ClaimState();
  rt.game_thread = 0u;
  // Detours read `live` before touching any state; publish the state first.
  rt.live.store(true, std::memory_order_release);
  const bool hooked = InstallArtemisHooksBatched(rt.sites);
  const bool factory = hooked, draw = hooked, update = hooked;
  rt.hooks_installed = factory && draw && update;
  rt.installed = rt.hooks_installed;
  if (!rt.installed) rt.live.store(false, std::memory_order_release);
  ArtemisLookupLog(
      L"artemis-lookup: sites factory=+0x%llx ctor=+0x%llx vtable=+0x%llx "
      L"draw=+0x%llx update=+0x%llx hooks=%d%d%d scan=%.1fms "
      L"process_age=%llums",
      static_cast<unsigned long long>(rt.sites.glyph_factory - base),
      static_cast<unsigned long long>(rt.sites.glyph_ctor - base),
      static_cast<unsigned long long>(rt.sites.glyph_vtable - base),
      static_cast<unsigned long long>(rt.sites.glyph_draw - base),
      static_cast<unsigned long long>(rt.sites.input_update - base),
      factory ? 1 : 0, draw ? 1 : 0, update ? 1 : 0, scan_ms,
      static_cast<unsigned long long>(ArtemisProcessAgeMs()));
  if (rt.installed && g_header != nullptr) {
    fushi_voice_hook::AtomicOrShared32(
        &g_header->lookup_diag, fushi_voice_hook::kLookupDiagSensorInstalled);
  }
  return rt.installed;
}

void RetireArtemisLookup() {
  auto& rt = g_artemis_lookup;
  InvalidateArtemisModel();
  rt.model.generation = 0u;
  rt.model.count = 0u;
  rt.model_line.clear();
  rt.model_text_event = 0u;
  if (!rt.provider_offered) return;
  rt.provider_offered = false;
  if (g_header != nullptr) {
    fushi_voice_hook::g_geometry_provider_registry.Retire(
        g_header, fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
        fushi_voice_hook::kLookupGeometryProviderIdArtemis);
  }
}

struct ArtemisDpiScope {
  DPI_AWARENESS_CONTEXT previous = SetThreadDpiAwarenessContext(
      DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  ~ArtemisDpiScope() {
    if (previous != nullptr) SetThreadDpiAwarenessContext(previous);
  }
};

// Builds the candidate model from the newest frame and the selected line.
bool BuildArtemisModel(ArtemisFrame& frame, const std::wstring& line,
                       ArtemisModel* model, uint32_t* first_glyph) {
  const HWND game = reinterpret_cast<HWND>(frame.window);
  DWORD pid = 0;
  if (game == nullptr || !IsWindow(game) ||
      GetWindowThreadProcessId(game, &pid) == 0 ||
      pid != GetCurrentProcessId() || !IsWindowVisible(game) || IsIconic(game)) {
    return false;
  }
  RECT physical = {};
  {
    ArtemisDpiScope dpi;
    if (dpi.previous == nullptr || !GetClientRect(game, &physical)) return false;
  }
  const int32_t physical_w = physical.right - physical.left;
  const int32_t physical_h = physical.bottom - physical.top;
  if (physical_w <= 0 || physical_h <= 0) return false;

  auto* glyphs = frame.glyphs.data();
  const size_t count = artemis_lookup::OrderFrameGlyphs(glyphs, frame.count);
  artemis_lookup::TextMapping mapping;
  if (count == 0u ||
      !artemis_lookup::ResolveSelectedSuffix(glyphs, count, line.data(),
                                             line.size(), &mapping)) {
    return false;
  }
  model->window = frame.window;
  model->physical_w = physical_w;
  model->physical_h = physical_h;
  model->engine_w = frame.projection.engine_client_w;
  model->engine_h = frame.projection.engine_client_h;
  model->count = 0u;
  for (size_t index = mapping.first_glyph; index < count; ++index) {
    if (mapping.source_index[index] == artemis_lookup::kNoSource) continue;
    // World units must be engine client pixels (root scale 1/k, no
    // shear); a glyph under its own scale/rotate effect stays unclickable.
    if (!artemis_lookup::GlyphInEngineClientSpace(
            glyphs[index].matrix, frame.projection.design_per_client)) {
      continue;
    }
    artemis_lookup::ModelGlyph& out = model->glyphs[model->count];
    // Every mapped glyph must project into the client: a partially visible
    // line is not a line the user can be looking at.
    if (!artemis_lookup::ProjectCell(glyphs[index].bounds, frame.projection,
                                     physical_w, physical_h, &out.rect)) {
      return false;
    }
    out.source_index = mapping.source_index[index];
    out.source_length = mapping.source_length[index];
    ++model->count;
  }
  *first_glyph = static_cast<uint32_t>(mapping.first_glyph);
  return model->count != 0u;
}

bool SameArtemisModelGeometry(const ArtemisModel& left,
                              const ArtemisModel& right) {
  if (left.window != right.window || left.physical_w != right.physical_w ||
      left.physical_h != right.physical_h || left.engine_w != right.engine_w ||
      left.engine_h != right.engine_h || left.count != right.count) {
    return false;
  }
  for (uint32_t index = 0u; index < left.count; ++index) {
    const auto& a = left.glyphs[index];
    const auto& b = right.glyphs[index];
    if (a.rect.x != b.rect.x || a.rect.y != b.rect.y || a.rect.w != b.rect.w ||
        a.rect.h != b.rect.h || a.source_index != b.source_index ||
        a.source_length != b.source_length) {
      return false;
    }
  }
  return true;
}

bool PublishArtemisLookupHit(const ArtemisSubmit& submit) {
  auto& rt = g_artemis_lookup;
  const ArtemisModel& model = rt.model;
  if (g_header == nullptr || submit.generation == 0u ||
      submit.generation != model.generation || submit.glyph >= model.count ||
      rt.model_line.empty()) {
    return false;
  }
  const auto& glyph = model.glyphs[submit.glyph];
  const size_t units = rt.model_line.size();
  if (glyph.source_index == artemis_lookup::kNoSource ||
      glyph.source_length == 0u || glyph.source_index >= units ||
      glyph.source_length > units - glyph.source_index ||
      fushi_voice_hook::LookupUtf16SourceLength(
          rt.model_line.data(), static_cast<uint32_t>(units),
          glyph.source_index) != glyph.source_length) {
    return false;
  }
  const int required = WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, rt.model_line.data(),
      static_cast<int>(units), nullptr, 0, nullptr, nullptr);
  if (required <= 0 ||
      static_cast<uint32_t>(required) > fushi_voice_hook::kLookupLineBytes) {
    return false;
  }
  char utf8[fushi_voice_hook::kLookupLineBytes] = {};
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, rt.model_line.data(),
                          static_cast<int>(units), utf8, required, nullptr,
                          nullptr) != required) {
    return false;
  }
  fushi_voice_hook::LookupGeometryHitPublication publication;
  publication.provider_kind =
      fushi_voice_hook::kLookupGeometryProviderEngineExactLayout;
  publication.provider_id = fushi_voice_hook::kLookupGeometryProviderIdArtemis;
  publication.char_index = glyph.source_index;
  publication.source_length = glyph.source_length;
  publication.char_count = static_cast<uint32_t>(units);
  publication.coordinate_space =
      fushi_voice_hook::kLookupCoordinateSpaceClientPhysicalPixels;
  publication.writing_mode = fushi_voice_hook::kLookupWritingModeHorizontal;
  publication.text_generation = rt.model_text_event;
  publication.geometry_generation = model.generation;
  publication.glyph_x = glyph.rect.x;
  publication.glyph_y = glyph.rect.y;
  publication.glyph_w = glyph.rect.w;
  publication.glyph_h = glyph.rect.h;
  publication.view_w = model.physical_w;
  publication.view_h = model.physical_h;
  publication.flags = fushi_voice_hook::kLookupHitFlagSubmit;
  publication.line_utf8 = reinterpret_cast<const uint8_t*>(utf8);
  publication.line_bytes = static_cast<uint32_t>(required);
  const bool published =
      fushi_voice_hook::g_geometry_provider_registry.PublishHit(g_header,
                                                                publication);
  ArtemisLookupLog(
      L"artemis-lookup: hit gen=%llu glyph=%u char=%u+%u rect=%d,%d %dx%d "
      L"view=%dx%d published=%d",
      static_cast<unsigned long long>(model.generation), submit.glyph,
      glyph.source_index, glyph.source_length, glyph.rect.x, glyph.rect.y,
      glyph.rect.w, glyph.rect.h, model.physical_w, model.physical_h,
      published ? 1 : 0);
  return published;
}

bool ReadLatestArtemisSubmit(ArtemisSubmit* out) {
  auto& rt = g_artemis_lookup;
  const uint64_t sequence = rt.submit_count.load(std::memory_order_acquire);
  if (sequence == 0u || sequence == rt.processed_submit_seq) return false;
  rt.processed_submit_seq = sequence;
  auto& slot_seq = rt.submit_seq[sequence % kArtemisSubmitSlots];
  if (slot_seq.load(std::memory_order_acquire) != sequence) return false;
  std::atomic_thread_fence(std::memory_order_acquire);
  *out = rt.submits[sequence % kArtemisSubmitSlots];
  std::atomic_thread_fence(std::memory_order_acquire);
  return slot_seq.load(std::memory_order_acquire) == sequence;
}

void ProcessArtemisLookupTick() {
  auto& rt = g_artemis_lookup;
  if (!rt.installed) return;
  if (g_stop || g_header == nullptr ||
      !fushi_voice_hook::HasLookupRegion(g_header) ||
      fushi_voice_hook::AtomicLoadShared32(&g_header->lookup_enabled) == 0u) {
    RetireArtemisLookup();
    return;
  }
  fushi_voice_hook::AtomicOrShared32(
      &g_header->lookup_diag, fushi_voice_hook::kLookupDiagSensorInstalled);

  ArtemisFrame& frame = rt.frame_copy;
  if (!ReadArtemisSlot(rt.frame_seq, rt.frames, rt.published_frame, &frame,
                       offsetof(ArtemisFrame, glyphs))) {
    RetireArtemisLookup();
    return;
  }
  const uint32_t frame_count = (std::min)(
      frame.count, static_cast<uint32_t>(artemis_lookup::kMaxFrameGlyphs));
  const uint64_t now = GetTickCount64();
  if (!ReadArtemisSlot(rt.frame_seq, rt.frames, rt.published_frame, &frame,
                       ArtemisFrameBytes(frame_count)) ||
      frame.count != frame_count || frame.overflow || frame.tick == 0u ||
      now < frame.tick || now - frame.tick > kArtemisFrameStaleMs ||
      !artemis_lookup::ProjectionUsable(frame.projection)) {
    RetireArtemisLookup();
    return;
  }

  std::wstring line;
  uint64_t event = 0u;
  uint64_t thread = 0u;
  if (!fushi_voice_hook::ReadSelectedLookupText(
          g_header, &line, &event, &thread, artemis_lookup::kMaxFrameGlyphs)) {
    RetireArtemisLookup();
    return;
  }
  ArtemisModel candidate;
  uint32_t first_glyph = 0u;
  if (!BuildArtemisModel(frame, line, &candidate, &first_glyph)) {
    RetireArtemisLookup();
    return;
  }

  const bool same = rt.model.generation != 0u && rt.model_text_event == event &&
                    rt.model_line == line &&
                    SameArtemisModelGeometry(rt.model, candidate);
  if (!same) {
    candidate.generation = ++rt.next_generation;
    rt.model = candidate;
    rt.model_line = line;
    rt.model_text_event = event;
    PublishArtemisSlot(rt.model_seq, rt.models, rt.published_model, rt.model,
                       ArtemisModelBytes(rt.model.count));
    if (rt.logged_models < kArtemisModelLogBudget) {
      ++rt.logged_models;
      const auto& first = rt.model.glyphs[0];
      const auto& last = rt.model.glyphs[rt.model.count - 1u];
      ArtemisLookupLog(
          L"artemis-lookup: model gen=%llu event=%llu units=%u glyphs=%u "
          L"skipped=%u first=%d,%d %dx%d last=%d,%d %dx%d view=%dx%d "
          L"engine=%dx%d k=%.4f off=%.1f,%.1f",
          static_cast<unsigned long long>(rt.model.generation),
          static_cast<unsigned long long>(event),
          static_cast<unsigned>(line.size()), rt.model.count, first_glyph,
          first.rect.x, first.rect.y, first.rect.w, first.rect.h, last.rect.x,
          last.rect.y, last.rect.w, last.rect.h, rt.model.physical_w,
          rt.model.physical_h, rt.model.engine_w, rt.model.engine_h,
          static_cast<double>(frame.projection.design_per_client),
          static_cast<double>(frame.projection.offset_x),
          static_cast<double>(frame.projection.offset_y));
    }
  }
  if (fushi_voice_hook::g_geometry_provider_registry.OfferReady(
          g_header, fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
          fushi_voice_hook::kLookupGeometryProviderIdArtemis)) {
    if (!rt.provider_offered) {
      ArtemisLookupLog(L"artemis-lookup: OfferReady gen=%llu glyphs=%u",
                       static_cast<unsigned long long>(rt.model.generation),
                       rt.model.count);
    }
    rt.provider_offered = true;
    fushi_voice_hook::AtomicOrShared32(
        &g_header->lookup_diag, fushi_voice_hook::kLookupDiagGeometryObserved);
  } else {
    RetireArtemisLookup();
    return;
  }

  ArtemisSubmit submit;
  if (ReadLatestArtemisSubmit(&submit)) (void)PublishArtemisLookupHit(submit);
}

void ShutdownArtemisLookup() {
  auto& rt = g_artemis_lookup;
  // The detours stay chained (MinHook owns them for the process lifetime);
  // clearing `live` turns each into a pure forwarder and drops any claim.
  rt.live.store(false, std::memory_order_release);
  RetireArtemisLookup();
  rt.installed = false;
}

bool ArtemisLookupSensorInstalled() { return g_artemis_lookup.installed; }
bool ArtemisLookupSitesRejected() {
  return g_artemis_lookup.resolved && !g_artemis_lookup.hooks_installed;
}

#else  // !_M_X64

bool InstallArtemisLookup() { return false; }
void ProcessArtemisLookupTick() {}
void ShutdownArtemisLookup() {}
bool ArtemisLookupSensorInstalled() { return false; }
bool ArtemisLookupSitesRejected() { return false; }

#endif  // _M_X64
