// RealLive in-game lookup runtime (EngineExactLayout /
// kLookupGeometryProviderIdReallive).  Engine facts, signatures and every
// decision rule live in reallive_lookup_core.h and are unit-tested; this file
// only binds them to MinHook, Win32 and the v19 registry.
//
// Threads:
//   * game thread — three detours, all bounded and allocation-free:
//       TextRender glyph join   records {surface, code, pen cell} of every
//                               rendered character (LunaHook keeps the entry
//                               and its call-site hook; this is a mid-body
//                               join, reached by both cache paths);
//       compositor Blit         updates per-glyph visibility (last writer of
//                               each cell in the presented screen buffer);
//       key poll join           publishes the tracker snapshot when it
//                               changed, then owns a bare left press that
//                               lands on a presented, mapped glyph: VK_LBUTTON
//                               is masked in the engine's own key table from
//                               press to release, so the click never reaches
//                               the script.
//   * HookWorker — ProcessRealliveLookupTick: matches the selected LunaHook
//     line against the visible glyphs of exactly one text surface, projects
//     them to physical client pixels, offers/retires the provider, publishes
//     the model the game thread hit-tests against, and turns queued presses
//     into registry hits.
//
// Fail closed everywhere: an unresolved signature installs nothing, a stale
// key poll, a text mismatch, an ambiguous surface, a client that is not the
// screen size or a missing native-input admission retires the provider or
// refuses the click, and the click then reaches the game unchanged.

#if defined(_M_IX86)

namespace reallive_lookup = fushi_voice_hook::reallive_lookup;

constexpr uint32_t kRealliveModelSlots = 2u;
constexpr uint32_t kRealliveSubmitSlots = 8u;
constexpr uint64_t kRealliveFrameStaleMs = 250u;
constexpr uint32_t kRealliveModelLogBudget = 24u;
constexpr size_t kRealliveSnapshotGlyphs =
    reallive_lookup::kMaxSurfaceGlyphs * 2u;

struct RealliveSnapshotSurface {
  uintptr_t bits = 0u;
  int32_t width = 0;
  int32_t height = 0;
  uint32_t first = 0u;
  uint32_t count = 0u;
};

struct RealliveSnapshot {
  uint64_t version = 0u;
  uint32_t surface_count = 0u;
  std::array<RealliveSnapshotSurface, reallive_lookup::kSurfaceSlots>
      surfaces{};
  uint32_t glyph_count = 0u;
  std::array<reallive_lookup::LineGlyph, kRealliveSnapshotGlyphs> glyphs{};
};

struct RealliveModelGlyph {
  reallive_lookup::LineGlyph line;
  reallive_lookup::PixelRect rect;  // physical client pixels
};

struct RealliveModel {
  uint64_t generation = 0u;
  uintptr_t window = 0u;
  uintptr_t surface_bits = 0u;
  int32_t surface_w = 0;
  int32_t surface_h = 0;
  int32_t screen_w = 0;
  int32_t screen_h = 0;
  int32_t physical_w = 0;
  int32_t physical_h = 0;
  uint32_t count = 0u;
  std::array<RealliveModelGlyph, reallive_lookup::kMaxSurfaceGlyphs> glyphs{};
};

struct RealliveSubmit {
  uint64_t generation = 0u;
  uint32_t glyph = 0u;
};

struct RealliveLookupRuntime {
  // ── HookWorker-owned ──
  bool resolved = false;
  bool hooks_installed = false;
  bool installed = false;
  reallive_lookup::SiteResult site_result =
      reallive_lookup::SiteResult::kNotX86;
  bool provider_offered = false;
  uint64_t processed_submit_seq = 0u;
  uint64_t next_generation = 0u;
  uint32_t logged_models = 0u;
  RealliveModel model;          // the published model (worker copy)
  std::wstring model_line;      // selected text the model was matched against
  uint64_t model_text_event = 0u;
  RealliveSnapshot snapshot_copy;  // scratch for the seqlock read
  std::array<reallive_lookup::LineGlyph, reallive_lookup::kMaxSurfaceGlyphs>
      match_scratch{};

  // ── resolved once, read everywhere ──
  reallive_lookup::Sites sites;
  const uint8_t* module = nullptr;

  // ── game-thread-owned ──
  reallive_lookup::GlyphTracker tracker;
  uint64_t published_version = UINT64_MAX;
  RealliveSnapshot building;
  reallive_lookup::ClaimState claim;
  DWORD game_thread = 0u;
  RealliveModel game_model;  // scratch for the press-time model read
  std::array<reallive_lookup::LineGlyph, reallive_lookup::kMaxSurfaceGlyphs>
      game_lines{};  // scratch for the press-time hit test

  // ── shared ──
  std::atomic<bool> live{false};
  std::atomic<uint64_t> last_poll_tick{0u};
  std::array<std::atomic<uint32_t>, 2u> snapshot_seq = {};
  std::array<RealliveSnapshot, 2u> snapshots = {};
  std::atomic<uint32_t> published_snapshot{UINT32_MAX};
  std::array<std::atomic<uint32_t>, kRealliveModelSlots> model_seq = {};
  std::array<RealliveModel, kRealliveModelSlots> models = {};
  std::atomic<uint32_t> published_model{UINT32_MAX};
  std::array<std::atomic<uint64_t>, kRealliveSubmitSlots> submit_seq = {};
  std::array<RealliveSubmit, kRealliveSubmitSlots> submits = {};
  std::atomic<uint64_t> submit_count{0u};
  std::atomic<uint64_t> claimed_presses{0u};
};

RealliveLookupRuntime g_reallive_lookup;
using RealliveBlitFn = int(__cdecl*)(uintptr_t, int32_t, int32_t, uintptr_t,
                                     int32_t, int32_t, int32_t, int32_t,
                                     int32_t, int32_t, int32_t, int32_t,
                                     int32_t, int32_t, int32_t, int32_t);
RealliveBlitFn g_reallive_blit_original = nullptr;
void* g_reallive_glyph_join_original = nullptr;
void* g_reallive_key_join_original = nullptr;

// ── two-slot seqlocks ──────────────────────────────────────────────────────

template <typename T, size_t Slots>
void PublishRealliveSlot(std::array<std::atomic<uint32_t>, Slots>& seqs,
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
bool ReadRealliveSlot(const std::array<std::atomic<uint32_t>, Slots>& seqs,
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

size_t RealliveSnapshotBytes(uint32_t glyphs) {
  return offsetof(RealliveSnapshot, glyphs) +
         static_cast<size_t>(glyphs) * sizeof(reallive_lookup::LineGlyph);
}

size_t RealliveModelBytes(uint32_t count) {
  return offsetof(RealliveModel, glyphs) +
         static_cast<size_t>(count) * sizeof(RealliveModelGlyph);
}

bool ReadRealliveModel(RealliveModel* out) {
  auto& rt = g_reallive_lookup;
  if (!ReadRealliveSlot(rt.model_seq, rt.models, rt.published_model, out,
                        offsetof(RealliveModel, glyphs))) {
    return false;
  }
  const uint32_t count = (std::min)(
      out->count, static_cast<uint32_t>(reallive_lookup::kMaxSurfaceGlyphs));
  return ReadRealliveSlot(rt.model_seq, rt.models, rt.published_model, out,
                          RealliveModelBytes(count)) &&
         out->count == count;
}

bool ReadRealliveSnapshot(RealliveSnapshot* out) {
  auto& rt = g_reallive_lookup;
  if (!ReadRealliveSlot(rt.snapshot_seq, rt.snapshots, rt.published_snapshot,
                        out, offsetof(RealliveSnapshot, glyphs))) {
    return false;
  }
  const uint32_t count = (std::min)(
      out->glyph_count, static_cast<uint32_t>(kRealliveSnapshotGlyphs));
  return ReadRealliveSlot(rt.snapshot_seq, rt.snapshots, rt.published_snapshot,
                          out, RealliveSnapshotBytes(count)) &&
         out->glyph_count == count;
}

void InvalidateRealliveModel() {
  g_reallive_lookup.published_model.store(UINT32_MAX,
                                          std::memory_order_release);
}

// Engine data globals, read in place.
uint32_t ReadRealliveGlobal(uintptr_t rva) {
  const uint8_t* module = g_reallive_lookup.module;
  if (module == nullptr || rva == 0u) return 0u;
  uint32_t value = 0u;
  __try {
    std::memcpy(&value, module + rva, sizeof(value));
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return 0u;
  }
  return value;
}

// ── game-thread detours ────────────────────────────────────────────────────

// TextRender join.  `frame` is esp at the join (see kFrame* offsets).
std::atomic<uint32_t> g_reallive_join_hits{0u};
std::atomic<uint32_t> g_reallive_join_other_thread{0u};

void __cdecl RealliveGlyphJoinObserve(const uint8_t* frame) {
  auto& rt = g_reallive_lookup;
  g_reallive_join_hits.fetch_add(1u, std::memory_order_relaxed);
  if (!rt.live.load(std::memory_order_acquire) || rt.game_thread == 0u ||
      GetCurrentThreadId() != rt.game_thread) {
    g_reallive_join_other_thread.fetch_add(1u, std::memory_order_relaxed);
    return;
  }
  __try {
    uint32_t surface = 0u, code = 0u;
    int32_t width = 0, height = 0, x = 0, y = 0;
    std::memcpy(&surface, frame + reallive_lookup::kFrameSurfaceOffset, 4u);
    std::memcpy(&width, frame + reallive_lookup::kFrameSurfaceWidthOffset, 4u);
    std::memcpy(&height, frame + reallive_lookup::kFrameSurfaceHeightOffset,
                4u);
    std::memcpy(&code, frame + reallive_lookup::kFrameCodeOffset, 4u);
    std::memcpy(&x, frame + reallive_lookup::kFramePenXOffset, 4u);
    std::memcpy(&y, frame + reallive_lookup::kFramePenYOffset, 4u);
    const int32_t size =
        static_cast<int32_t>(ReadRealliveGlobal(rt.sites.font_size_rva));
    rt.tracker.RecordGlyph(surface, width, height, code, x, y, size);
  } __except (EXCEPTION_EXECUTE_HANDLER) {
  }
}

__declspec(naked) void RealliveGlyphJoinStub() {
  __asm {
    pushfd
    pushad
    lea eax, [esp + 0x24]
    push eax
    call RealliveGlyphJoinObserve
    add esp, 4
    popad
    popfd
    jmp dword ptr [g_reallive_glyph_join_original]
  }
}

int __cdecl RealliveBlitDetour(uintptr_t dst, int32_t dst_w, int32_t dst_h,
                               uintptr_t src, int32_t src_w, int32_t src_h,
                               int32_t a7, int32_t a8, int32_t a9, int32_t dx,
                               int32_t dy, int32_t clip_x0, int32_t clip_y0,
                               int32_t clip_x1, int32_t clip_y1,
                               int32_t alpha) {
  auto& rt = g_reallive_lookup;
  if (rt.live.load(std::memory_order_acquire) && rt.game_thread != 0u &&
      GetCurrentThreadId() == rt.game_thread) {
    reallive_lookup::CompositeBlit blit;
    blit.dst = dst;
    blit.dst_w = dst_w;
    blit.dst_h = dst_h;
    blit.src = src;
    blit.src_w = src_w;
    blit.src_h = src_h;
    blit.dx = dx;
    blit.dy = dy;
    blit.clip_x0 = clip_x0;
    blit.clip_y0 = clip_y0;
    blit.clip_x1 = clip_x1;
    blit.clip_y1 = clip_y1;
    rt.tracker.RecordComposite(
        blit, ReadRealliveGlobal(rt.sites.screen_bits_rva),
        static_cast<int32_t>(ReadRealliveGlobal(rt.sites.screen_width_rva)),
        static_cast<int32_t>(ReadRealliveGlobal(rt.sites.screen_height_rva)));
  }
  return g_reallive_blit_original(dst, dst_w, dst_h, src, src_w, src_h, a7, a8,
                                  a9, dx, dy, clip_x0, clip_y0, clip_x1,
                                  clip_y1, alpha);
}

// Publishes the visible glyphs of every placed surface when the tracker
// changed since the last publication.
void PublishRealliveSnapshot() {
  auto& rt = g_reallive_lookup;
  const uint64_t version = rt.tracker.version();
  if (version == rt.published_version) return;
  rt.published_version = version;
  RealliveSnapshot& snapshot = rt.building;
  snapshot.version = version;
  snapshot.surface_count = 0u;
  snapshot.glyph_count = 0u;
  for (const auto& slot : rt.tracker.slots()) {
    if (slot.bits == 0u || !slot.placed) continue;
    const size_t room = kRealliveSnapshotGlyphs - snapshot.glyph_count;
    const size_t count = reallive_lookup::CollectVisibleGlyphs(
        slot, snapshot.glyphs.data() + snapshot.glyph_count, room);
    if (count == 0u) continue;
    RealliveSnapshotSurface& surface =
        snapshot.surfaces[snapshot.surface_count++];
    surface.bits = slot.bits;
    surface.width = slot.width;
    surface.height = slot.height;
    surface.first = snapshot.glyph_count;
    surface.count = static_cast<uint32_t>(count);
    snapshot.glyph_count += static_cast<uint32_t>(count);
  }
  PublishRealliveSlot(rt.snapshot_seq, rt.snapshots, rt.published_snapshot,
                      snapshot, RealliveSnapshotBytes(snapshot.glyph_count));
}

void QueueRealliveSubmit(const RealliveSubmit& submit) {
  auto& rt = g_reallive_lookup;
  const uint64_t sequence =
      rt.submit_count.load(std::memory_order_acquire) + 1u;
  auto& slot_seq = rt.submit_seq[sequence % kRealliveSubmitSlots];
  slot_seq.store(0u, std::memory_order_release);
  std::atomic_thread_fence(std::memory_order_release);
  rt.submits[sequence % kRealliveSubmitSlots] = submit;
  std::atomic_thread_fence(std::memory_order_release);
  slot_seq.store(sequence, std::memory_order_release);
  rt.submit_count.store(sequence, std::memory_order_release);
}

bool RealliveShieldActive(HWND game) {
  if (IsLookupOverlayInputShieldVisible()) return true;
  if (g_header == nullptr) return false;
  const auto request = fushi_voice_hook::ReadLookupShieldRequest(g_header);
  return request.valid && request.active_buttons != 0u &&
         request.target_hwnd ==
             static_cast<uint64_t>(reinterpret_cast<uintptr_t>(game));
}

// The hit glyph's surface must still be tracked at the model's origin, and
// its opaque pixels must be what the screen buffer presents right now.
bool RealliveGlyphPresentedNow(const RealliveModel& model,
                               const reallive_lookup::LineGlyph& glyph) {
  auto& rt = g_reallive_lookup;
  const int32_t origin_x = glyph.x - glyph.local_x;
  const int32_t origin_y = glyph.y - glyph.local_y;
  bool tracked = false;
  for (const auto& slot : rt.tracker.slots()) {
    if (slot.bits == model.surface_bits && slot.width == model.surface_w &&
        slot.height == model.surface_h && slot.placed &&
        slot.origin_x == origin_x && slot.origin_y == origin_y) {
      tracked = true;
      break;
    }
  }
  const uintptr_t screen = ReadRealliveGlobal(rt.sites.screen_bits_rva);
  const int32_t screen_w =
      static_cast<int32_t>(ReadRealliveGlobal(rt.sites.screen_width_rva));
  const int32_t screen_h =
      static_cast<int32_t>(ReadRealliveGlobal(rt.sites.screen_height_rva));
  if (!tracked || screen == 0u || screen_w != model.screen_w ||
      screen_h != model.screen_h) {
    return false;
  }
  reallive_lookup::PresentationCount count;
  __try {
    count = reallive_lookup::CountPresentedPixels(
        reinterpret_cast<const uint32_t*>(model.surface_bits), model.surface_w,
        model.surface_h, reinterpret_cast<const uint32_t*>(screen), screen_w,
        screen_h, origin_x, origin_y, glyph.local_x, glyph.local_y, glyph.w,
        glyph.h);
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return false;
  }
  return reallive_lookup::GlyphPresented(count);
}

// A fresh engine-sampled press: may it become a lookup?  Only a bare left
// press on exactly one mapped, presented glyph of the current model, in the
// foreground game window, with the host's native-input admission applied and
// no lookup card already shielding the game.
bool ReallivePressEligible(RealliveSubmit* submit) {
  auto& rt = g_reallive_lookup;
  if (g_header == nullptr || g_stop ||
      !fushi_voice_hook::HasLookupRegion(g_header) ||
      fushi_voice_hook::AtomicLoadShared32(&g_header->lookup_enabled) == 0u) {
    return false;
  }
  RealliveModel& model = rt.game_model;
  if (!ReadRealliveModel(&model) || model.generation == 0u ||
      model.count == 0u) {
    return false;
  }
  const HWND game = reinterpret_cast<HWND>(
      static_cast<uintptr_t>(ReadRealliveGlobal(rt.sites.window_rva)));
  if (game == nullptr || reinterpret_cast<uintptr_t>(game) != model.window ||
      !fushi_voice_hook::g_geometry_provider_registry.NativeInputAllowed(
          g_header, fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
          fushi_voice_hook::kLookupGeometryProviderIdReallive) ||
      RealliveShieldActive(game) || GetForegroundWindow() != game ||
      (GetKeyState(VK_SHIFT) & 0x8000) != 0 ||
      (GetKeyState(VK_CONTROL) & 0x8000) != 0 ||
      (GetKeyState(VK_MENU) & 0x8000) != 0) {
    return false;
  }
  // The game thread is DPI-unaware: cursor and client are in the engine's
  // logical pixels, which equal screen-buffer pixels when the client is the
  // screen size (the only projection the worker admits).
  POINT cursor = {};
  RECT client = {};
  if (!GetCursorPos(&cursor)) return false;
  const HWND under = WindowFromPoint(cursor);
  if ((under != game && !IsChild(game, under)) ||
      !ScreenToClient(game, &cursor) || !GetClientRect(game, &client) ||
      client.right - client.left != model.screen_w ||
      client.bottom - client.top != model.screen_h) {
    return false;
  }
  auto& lines = rt.game_lines;
  for (uint32_t index = 0u; index < model.count; ++index) {
    lines[index] = model.glyphs[index].line;
  }
  size_t hit = 0u;
  if (!reallive_lookup::HitTestLine(lines.data(), model.count, cursor.x,
                                    cursor.y,
                                    &hit) ||
      !RealliveGlyphPresentedNow(model, lines[hit])) {
    return false;
  }
  submit->generation = model.generation;
  submit->glyph = static_cast<uint32_t>(hit);
  return true;
}

// Key poll join.  `frame` is esp at the join; the key table is at +0x10.
void __cdecl RealliveKeyJoinObserve(uint8_t* frame) {
  auto& rt = g_reallive_lookup;
  if (!rt.live.load(std::memory_order_acquire)) return;
  if (rt.game_thread == 0u) rt.game_thread = GetCurrentThreadId();
  if (GetCurrentThreadId() != rt.game_thread) return;
  __try {
    rt.last_poll_tick.store(GetTickCount64(), std::memory_order_release);
    PublishRealliveSnapshot();
    uint8_t* key =
        frame + reallive_lookup::kKeyTableOffset + static_cast<size_t>(VK_LBUTTON);
    const uint8_t raw = *key;
    RealliveSubmit submit;
    const bool eligible = reallive_lookup::IsFreshPress(raw, rt.claim) &&
                          ReallivePressEligible(&submit);
    const auto decision =
        reallive_lookup::DecideLeftButton(raw, eligible, &rt.claim);
    if (decision.submit) {
      QueueRealliveSubmit(submit);
      rt.claimed_presses.fetch_add(1u, std::memory_order_relaxed);
    }
    if (decision.mask) {
      *key = static_cast<uint8_t>(raw & ~reallive_lookup::kKeyDownBit);
    }
  } __except (EXCEPTION_EXECUTE_HANDLER) {
  }
}

__declspec(naked) void RealliveKeyJoinStub() {
  __asm {
    pushfd
    pushad
    lea eax, [esp + 0x24]
    push eax
    call RealliveKeyJoinObserve
    add esp, 4
    popad
    popfd
    jmp dword ptr [g_reallive_key_join_original]
  }
}

// ── HookWorker ─────────────────────────────────────────────────────────────

// Worker-only, bounded diagnostics in %TEMP%\fushi_galhook.log (the injected
// side has no other text channel).  Never logs dialogue text.
void RealliveLookupLog(const wchar_t* format, ...) {
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

// Creates the three detours first and enables them in one MinHook
// transaction.  All or nothing: a target someone else already hooked, or any
// MinHook failure, installs none.
bool InstallRealliveHooksBatched(const reallive_lookup::Sites& sites) {
  struct Site {
    void* target;
    void* detour;
    void** original;
  };
  const Site plan[] = {
      {reinterpret_cast<void*>(sites.glyph_join),
       reinterpret_cast<void*>(&RealliveGlyphJoinStub),
       &g_reallive_glyph_join_original},
      {reinterpret_cast<void*>(sites.composite_blit),
       reinterpret_cast<void*>(&RealliveBlitDetour),
       reinterpret_cast<void**>(&g_reallive_blit_original)},
      {reinterpret_cast<void*>(sites.key_join),
       reinterpret_cast<void*>(&RealliveKeyJoinStub),
       &g_reallive_key_join_original},
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

bool InstallRealliveLookup() {
  auto& rt = g_reallive_lookup;
  if (rt.installed) return true;
  if (rt.resolved) {
    // Re-install after a shutdown: the MinHook detours are still chained and
    // only need to start recording again.  A rejected image stays rejected.
    if (!rt.hooks_installed) return false;
    rt.claim = reallive_lookup::ClaimState();
    rt.live.store(true, std::memory_order_release);
    rt.installed = true;
    return true;
  }
  rt.resolved = true;
  LARGE_INTEGER frequency = {}, started = {}, finished = {};
  QueryPerformanceFrequency(&frequency);
  QueryPerformanceCounter(&started);
  fushi_voice_hook::exact_lookup::LoadedPeImage image;
  reallive_lookup::ImportSlots imports;
  if (!fushi_voice_hook::exact_lookup::OpenLoadedPeImage(
          GetModuleHandleW(nullptr), &image)) {
    rt.site_result = reallive_lookup::SiteResult::kGlyphPathMissing;
  } else {
    imports.get_keyboard_state = reallive_lookup::FindImportSlotRva(
        image, "user32.dll", "GetKeyboardState");
    imports.get_focus = reallive_lookup::FindImportSlotRva(
        image, "user32.dll", "GetFocus");
    imports.get_glyph_outline = reallive_lookup::FindImportSlotRva(
        image, "gdi32.dll", "GetGlyphOutlineA");
    rt.site_result = reallive_lookup::ResolveSites(image, imports, &rt.sites);
  }
  QueryPerformanceCounter(&finished);
  const double scan_ms =
      frequency.QuadPart > 0
          ? 1000.0 * static_cast<double>(finished.QuadPart - started.QuadPart) /
                static_cast<double>(frequency.QuadPart)
          : 0.0;
  if (rt.site_result != reallive_lookup::SiteResult::kResolved) {
    RealliveLookupLog(L"reallive-lookup: sites unresolved result=%u scan=%.1fms",
                      static_cast<unsigned>(rt.site_result), scan_ms);
    return false;
  }
  const uintptr_t base = reinterpret_cast<uintptr_t>(image.base);
  rt.module = image.base;
  rt.tracker.Clear();
  rt.published_version = UINT64_MAX;
  rt.claim = reallive_lookup::ClaimState();
  rt.game_thread = 0u;
  // Detours read `live` before touching any state; publish the state first.
  rt.live.store(true, std::memory_order_release);
  const bool hooked = InstallRealliveHooksBatched(rt.sites);
  rt.hooks_installed = hooked;
  rt.installed = hooked;
  if (!rt.installed) rt.live.store(false, std::memory_order_release);
  RealliveLookupLog(
      L"reallive-lookup: sites join=+0x%lx raster=+0x%lx key=+0x%lx "
      L"blit=+0x%lx size=+0x%lx screen=+0x%lx w=+0x%lx h=+0x%lx "
      L"hwnd=+0x%lx hooks=%d scan=%.1fms",
      static_cast<unsigned long>(rt.sites.glyph_join - base),
      static_cast<unsigned long>(rt.sites.raster - base),
      static_cast<unsigned long>(rt.sites.key_join - base),
      static_cast<unsigned long>(rt.sites.composite_blit - base),
      static_cast<unsigned long>(rt.sites.font_size_rva),
      static_cast<unsigned long>(rt.sites.screen_bits_rva),
      static_cast<unsigned long>(rt.sites.screen_width_rva),
      static_cast<unsigned long>(rt.sites.screen_height_rva),
      static_cast<unsigned long>(rt.sites.window_rva), hooked ? 1 : 0,
      scan_ms);
  if (rt.installed && g_header != nullptr) {
    fushi_voice_hook::AtomicOrShared32(
        &g_header->lookup_diag, fushi_voice_hook::kLookupDiagSensorInstalled);
  }
  return rt.installed;
}

void RetireRealliveLookup() {
  auto& rt = g_reallive_lookup;
  InvalidateRealliveModel();
  rt.model.generation = 0u;
  rt.model.count = 0u;
  rt.model_line.clear();
  rt.model_text_event = 0u;
  if (!rt.provider_offered) return;
  rt.provider_offered = false;
  if (g_header != nullptr) {
    fushi_voice_hook::g_geometry_provider_registry.Retire(
        g_header, fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
        fushi_voice_hook::kLookupGeometryProviderIdReallive);
  }
}

struct RealliveDpiScope {
  explicit RealliveDpiScope(DPI_AWARENESS_CONTEXT context)
      : previous(SetThreadDpiAwarenessContext(context)) {}
  ~RealliveDpiScope() {
    if (previous != nullptr) SetThreadDpiAwarenessContext(previous);
  }
  DPI_AWARENESS_CONTEXT previous;
};

// Builds the candidate model from the newest snapshot and the selected line.
// Diagnostic detail of the last model-build failure (worker only).
struct RealliveModelFailure {
  uint32_t step = 0u;  // 1 window 2 dpi 3 screen/client 4 no match 5 ambiguous 6 projection
  int32_t a = 0, b = 0, c = 0, d = 0;
};
RealliveModelFailure g_reallive_model_failure;

bool FailRealliveModel(uint32_t step, int32_t a = 0, int32_t b = 0,
                       int32_t c = 0, int32_t d = 0) {
  g_reallive_model_failure = {step, a, b, c, d};
  return false;
}

bool BuildRealliveModel(const RealliveSnapshot& snapshot,
                        const std::wstring& line, RealliveModel* model,
                        uint32_t* first_glyph) {
  auto& rt = g_reallive_lookup;
  const HWND game = reinterpret_cast<HWND>(
      static_cast<uintptr_t>(ReadRealliveGlobal(rt.sites.window_rva)));
  DWORD pid = 0;
  if (game == nullptr || !IsWindow(game) ||
      GetWindowThreadProcessId(game, &pid) == 0 ||
      pid != GetCurrentProcessId() || !IsWindowVisible(game) || IsIconic(game)) {
    return FailRealliveModel(1u);
  }
  const int32_t screen_w =
      static_cast<int32_t>(ReadRealliveGlobal(rt.sites.screen_width_rva));
  const int32_t screen_h =
      static_cast<int32_t>(ReadRealliveGlobal(rt.sites.screen_height_rva));
  RECT logical = {};
  RECT physical = {};
  {
    RealliveDpiScope unaware(DPI_AWARENESS_CONTEXT_UNAWARE);
    if (unaware.previous == nullptr || !GetClientRect(game, &logical)) {
      return FailRealliveModel(2u);
    }
  }
  {
    RealliveDpiScope aware(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    if (aware.previous == nullptr || !GetClientRect(game, &physical)) {
      return FailRealliveModel(2u);
    }
  }
  // The screen buffer is presented 1:1 at the client origin: the engine's
  // logical client must be exactly the screen size, else this is not the
  // projection the engine uses and nothing is claimed.
  if (screen_w <= 0 || screen_h <= 0 ||
      logical.right - logical.left != screen_w ||
      logical.bottom - logical.top != screen_h) {
    return FailRealliveModel(3u, screen_w, screen_h,
                             logical.right - logical.left,
                             logical.bottom - logical.top);
  }
  const int32_t physical_w = physical.right - physical.left;
  const int32_t physical_h = physical.bottom - physical.top;
  if (physical_w <= 0 || physical_h <= 0) return false;

  // Exactly one text surface's visible glyphs must end with the line.
  const RealliveSnapshotSurface* matched = nullptr;
  size_t matched_first = 0u;
  size_t matched_count = 0u;
  for (uint32_t index = 0u; index < snapshot.surface_count; ++index) {
    const RealliveSnapshotSurface& surface = snapshot.surfaces[index];
    if (surface.count == 0u || surface.first > snapshot.glyph_count ||
        surface.count > snapshot.glyph_count - surface.first ||
        surface.count > rt.match_scratch.size()) {
      continue;
    }
    std::copy_n(snapshot.glyphs.data() + surface.first, surface.count,
                rt.match_scratch.data());
    const size_t first = reallive_lookup::MapSelectedSuffix(
        rt.match_scratch.data(), surface.count, line.data(), line.size());
    if (first >= surface.count) continue;
    if (matched != nullptr) return FailRealliveModel(5u);  // ambiguous
    matched = &surface;
    matched_first = first;
    matched_count = surface.count;
  }
  if (matched == nullptr) {
    return FailRealliveModel(4u, static_cast<int32_t>(snapshot.surface_count),
                             static_cast<int32_t>(snapshot.glyph_count),
                             static_cast<int32_t>(line.size()));
  }
  std::copy_n(snapshot.glyphs.data() + matched->first, matched_count,
              rt.match_scratch.data());
  reallive_lookup::MapSelectedSuffix(rt.match_scratch.data(), matched_count,
                                     line.data(), line.size());

  model->window = reinterpret_cast<uintptr_t>(game);
  model->surface_bits = matched->bits;
  model->surface_w = matched->width;
  model->surface_h = matched->height;
  model->screen_w = screen_w;
  model->screen_h = screen_h;
  model->physical_w = physical_w;
  model->physical_h = physical_h;
  model->count = 0u;
  for (size_t index = matched_first; index < matched_count; ++index) {
    const auto& glyph = rt.match_scratch[index];
    if (glyph.source_index == reallive_lookup::kNoSource) continue;
    RealliveModelGlyph& out = model->glyphs[model->count];
    // Every mapped glyph must project into the client: a partially visible
    // line is not a line the user can be looking at.
    if (!reallive_lookup::ProjectCell(glyph, screen_w, screen_h, physical_w,
                                      physical_h, &out.rect)) {
      return FailRealliveModel(6u, glyph.x, glyph.y, physical_w, physical_h);
    }
    out.line = glyph;
    ++model->count;
  }
  *first_glyph = static_cast<uint32_t>(matched_first);
  return model->count != 0u;
}

bool SameRealliveModelGeometry(const RealliveModel& left,
                               const RealliveModel& right) {
  if (left.window != right.window || left.surface_bits != right.surface_bits ||
      left.screen_w != right.screen_w || left.screen_h != right.screen_h ||
      left.physical_w != right.physical_w ||
      left.physical_h != right.physical_h || left.count != right.count) {
    return false;
  }
  for (uint32_t index = 0u; index < left.count; ++index) {
    const auto& a = left.glyphs[index];
    const auto& b = right.glyphs[index];
    if (a.rect.x != b.rect.x || a.rect.y != b.rect.y || a.rect.w != b.rect.w ||
        a.rect.h != b.rect.h || a.line.x != b.line.x || a.line.y != b.line.y ||
        a.line.source_index != b.line.source_index ||
        a.line.source_length != b.line.source_length) {
      return false;
    }
  }
  return true;
}

bool PublishRealliveLookupHit(const RealliveSubmit& submit) {
  auto& rt = g_reallive_lookup;
  const RealliveModel& model = rt.model;
  if (g_header == nullptr || submit.generation == 0u ||
      submit.generation != model.generation || submit.glyph >= model.count ||
      rt.model_line.empty()) {
    return false;
  }
  const auto& glyph = model.glyphs[submit.glyph];
  const size_t units = rt.model_line.size();
  if (glyph.line.source_index == reallive_lookup::kNoSource ||
      glyph.line.source_length == 0u || glyph.line.source_index >= units ||
      glyph.line.source_length > units - glyph.line.source_index ||
      fushi_voice_hook::LookupUtf16SourceLength(
          rt.model_line.data(), static_cast<uint32_t>(units),
          glyph.line.source_index) != glyph.line.source_length) {
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
  publication.provider_id = fushi_voice_hook::kLookupGeometryProviderIdReallive;
  publication.char_index = glyph.line.source_index;
  publication.source_length = glyph.line.source_length;
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
  RealliveLookupLog(
      L"reallive-lookup: hit gen=%llu glyph=%u char=%u+%u rect=%d,%d %dx%d "
      L"design=%d,%d %dx%d view=%dx%d published=%d",
      static_cast<unsigned long long>(model.generation), submit.glyph,
      glyph.line.source_index, glyph.line.source_length, glyph.rect.x,
      glyph.rect.y, glyph.rect.w, glyph.rect.h, glyph.line.x, glyph.line.y,
      glyph.line.w, glyph.line.h, model.physical_w, model.physical_h,
      published ? 1 : 0);
  return published;
}

bool ReadLatestRealliveSubmit(RealliveSubmit* out) {
  auto& rt = g_reallive_lookup;
  const uint64_t sequence = rt.submit_count.load(std::memory_order_acquire);
  if (sequence == 0u || sequence == rt.processed_submit_seq) return false;
  rt.processed_submit_seq = sequence;
  auto& slot_seq = rt.submit_seq[sequence % kRealliveSubmitSlots];
  if (slot_seq.load(std::memory_order_acquire) != sequence) return false;
  std::atomic_thread_fence(std::memory_order_acquire);
  *out = rt.submits[sequence % kRealliveSubmitSlots];
  std::atomic_thread_fence(std::memory_order_acquire);
  return slot_seq.load(std::memory_order_acquire) == sequence;
}

// Why the last tick retired (0 = published).  Logged once per change so a
// silent provider always says which gate it is waiting on.
void NoteRealliveRetire(uint32_t reason) {
  static uint32_t last = UINT32_MAX;
  static uint32_t budget = 24u;
  const uint32_t key =
      reason == 4u ? 100u + g_reallive_model_failure.step : reason;
  if (key == last || budget == 0u) return;
  last = key;
  --budget;
  static const wchar_t* const kNames[] = {
      L"offered", L"lookup-disabled", L"key-poll-stale", L"no-selected-text",
      L"model-unbuilt", L"offer-rejected"};
  if (reason == 4u) {
    const auto& f = g_reallive_model_failure;
    const auto& t = g_reallive_lookup.tracker.stats();
    RealliveLookupLog(
        L"reallive-lookup: gate=%s step=%u %d,%d,%d,%d joins=%u other=%u "
        L"rec=%u args=%u bounds=%u reset=%u last=%d,%d surf=%dx%d "
        L"size=%d",
        kNames[reason], f.step, f.a, f.b, f.c, f.d,
        g_reallive_join_hits.load(), g_reallive_join_other_thread.load(),
        t.recorded, t.rejected_args, t.rejected_bounds, t.page_resets, t.last_x, t.last_y, t.last_w, t.last_h, t.last_size);
    return;
  }
  RealliveLookupLog(L"reallive-lookup: gate=%s",
                    reason < 6u ? kNames[reason] : L"?");
}

void ProcessRealliveLookupTick() {
  auto& rt = g_reallive_lookup;
  if (!rt.installed) return;
  if (g_stop || g_header == nullptr ||
      !fushi_voice_hook::HasLookupRegion(g_header) ||
      fushi_voice_hook::AtomicLoadShared32(&g_header->lookup_enabled) == 0u) {
    NoteRealliveRetire(1u);
    RetireRealliveLookup();
    return;
  }
  fushi_voice_hook::AtomicOrShared32(
      &g_header->lookup_diag, fushi_voice_hook::kLookupDiagSensorInstalled);

  // The engine polls its keys many times per frame while it runs; a silent
  // poller is a suspended, minimised or dying game.
  const uint64_t now = GetTickCount64();
  const uint64_t polled = rt.last_poll_tick.load(std::memory_order_acquire);
  RealliveSnapshot& snapshot = rt.snapshot_copy;
  if (polled == 0u || now < polled || now - polled > kRealliveFrameStaleMs ||
      !ReadRealliveSnapshot(&snapshot)) {
    NoteRealliveRetire(2u);
    RetireRealliveLookup();
    return;
  }

  std::wstring line;
  uint64_t event = 0u;
  uint64_t thread = 0u;
  if (!fushi_voice_hook::ReadSelectedLookupText(
          g_header, &line, &event, &thread,
          reallive_lookup::kMaxSurfaceGlyphs)) {
    NoteRealliveRetire(3u);
    RetireRealliveLookup();
    return;
  }
  RealliveModel candidate;
  uint32_t first_glyph = 0u;
  if (!BuildRealliveModel(snapshot, line, &candidate, &first_glyph)) {
    NoteRealliveRetire(4u);
    RetireRealliveLookup();
    return;
  }

  const bool same = rt.model.generation != 0u && rt.model_text_event == event &&
                    rt.model_line == line &&
                    SameRealliveModelGeometry(rt.model, candidate);
  if (!same) {
    candidate.generation = ++rt.next_generation;
    rt.model = candidate;
    rt.model_line = line;
    rt.model_text_event = event;
    PublishRealliveSlot(rt.model_seq, rt.models, rt.published_model, rt.model,
                        RealliveModelBytes(rt.model.count));
    if (rt.logged_models < kRealliveModelLogBudget) {
      ++rt.logged_models;
      const auto& first = rt.model.glyphs[0];
      const auto& last = rt.model.glyphs[rt.model.count - 1u];
      RealliveLookupLog(
          L"reallive-lookup: model gen=%llu event=%llu units=%u glyphs=%u "
          L"skipped=%u first=%d,%d %dx%d (design %d,%d) last=%d,%d %dx%d "
          L"view=%dx%d screen=%dx%d",
          static_cast<unsigned long long>(rt.model.generation),
          static_cast<unsigned long long>(event),
          static_cast<unsigned>(line.size()), rt.model.count, first_glyph,
          first.rect.x, first.rect.y, first.rect.w, first.rect.h, first.line.x,
          first.line.y, last.rect.x, last.rect.y, last.rect.w, last.rect.h,
          rt.model.physical_w, rt.model.physical_h, rt.model.screen_w,
          rt.model.screen_h);
    }
  }
  if (fushi_voice_hook::g_geometry_provider_registry.OfferReady(
          g_header, fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
          fushi_voice_hook::kLookupGeometryProviderIdReallive)) {
    if (!rt.provider_offered) {
      RealliveLookupLog(L"reallive-lookup: OfferReady gen=%llu glyphs=%u",
                        static_cast<unsigned long long>(rt.model.generation),
                        rt.model.count);
    }
    rt.provider_offered = true;
    fushi_voice_hook::AtomicOrShared32(
        &g_header->lookup_diag, fushi_voice_hook::kLookupDiagGeometryObserved);
    NoteRealliveRetire(0u);
  } else {
    NoteRealliveRetire(5u);
    RetireRealliveLookup();
    return;
  }

  RealliveSubmit submit;
  if (ReadLatestRealliveSubmit(&submit)) (void)PublishRealliveLookupHit(submit);
}

void ShutdownRealliveLookup() {
  auto& rt = g_reallive_lookup;
  // The detours stay chained (MinHook owns them for the process lifetime);
  // clearing `live` turns each into a pure forwarder and drops any claim.
  rt.live.store(false, std::memory_order_release);
  RetireRealliveLookup();
  rt.installed = false;
}

bool RealliveLookupSensorInstalled() { return g_reallive_lookup.installed; }
bool RealliveLookupSitesRejected() {
  return g_reallive_lookup.resolved && !g_reallive_lookup.hooks_installed;
}

#else  // !_M_IX86

bool InstallRealliveLookup() { return false; }
void ProcessRealliveLookupTick() {}
void ShutdownRealliveLookup() {}
bool RealliveLookupSensorInstalled() { return false; }
bool RealliveLookupSitesRejected() { return false; }

#endif  // _M_IX86
