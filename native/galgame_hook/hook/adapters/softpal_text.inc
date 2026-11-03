// SoftPal text lane and voice runtime.  Engine facts and every rule live in
// softpal_core.h and are unit-tested; this file binds them to MinHook, Win32,
// the text lanes and the voice resource writer.
//
// Threads:
//   * game thread — the Pal export detours.  PalSpriteLock opens a text
//     transaction on the returned buffer, PalFontDrawText on that buffer
//     appends the glyph, PalSpriteUnlock hands a transaction with glyphs to
//     the worker (fixed ring, no allocation, no IO, no conversion).
//     PalSpriteSetPos counts placements (the engine places every sprite every
//     frame, so the count separates engine steps) and keeps the placement of
//     sprites that carry text; PalSoundLoad hands voice loads to the worker.
//   * HookWorker — ProcessSoftpalTextTick: composes each page, drops the
//     speaker plate (softpal::IsSpeakerLabel), publishes the body on the
//     exact lane of its sprite size and exports the voice of the same engine
//     step from the game's archive with that page's text event.
//
// Fail closed: a missing export installs nothing; a page that is not clean
// CP932 publishes nothing; a voice not in an archive is not exported.

#if defined(_M_IX86)

namespace softpal = fushi_voice_hook::softpal;

constexpr uint32_t kSoftpalEventSlots = 16u;
constexpr uint32_t kSoftpalSpriteSlots = 16u;
constexpr uint32_t kSoftpalLogBudget = 4096u;
constexpr uint32_t kSoftpalNameBytes = 64u;

using SoftpalFn = uintptr_t(__cdecl*)(uintptr_t, uintptr_t, uintptr_t,
                                      uintptr_t, uintptr_t, uintptr_t,
                                      uintptr_t, uintptr_t);
// The font size is a 16-bit field returned in AX: the upper half of EAX is
// whatever the getter left there (measured on all three generations).
using SoftpalFontSizeFn = int16_t(__cdecl*)();

enum SoftpalEventKind : uint32_t {
  kSoftpalEventPage = 1u,
  kSoftpalEventVoice = 2u,
};

struct SoftpalEvent {
  uint64_t sequence = 0u;
  uint64_t tick = 0u;
  uint32_t kind = 0u;
  uintptr_t sprite = 0u;
  int32_t buffer_w = 0;
  int32_t buffer_h = 0;
  uint64_t page_seq = 0u;
  // Placements since the previous page's unlock, and the count at this one.
  uint32_t setpos_before = 0u;
  uint32_t setpos_at = 0u;
  uint32_t sound_type = 0u;
  char name[kSoftpalNameBytes] = {};
  uint32_t count = 0u;
  softpal::GlyphDraw draws[softpal::kMaxPageGlyphs] = {};
};

// A sprite that carries text, as the game thread last placed it.
struct SoftpalSpriteSlot {
  std::atomic<uintptr_t> sprite{0u};
  std::atomic<uint64_t> page_seq{0u};
  // The glyphs of that page (game thread only): an identical redraw keeps the
  // page's identity, so the lookup model stays put while the engine repaints.
  uint64_t content_hash = 0u;
  std::atomic<uint32_t> x_bits{0u};
  std::atomic<uint32_t> y_bits{0u};
  std::atomic<uint32_t> placed{0u};
  std::atomic<uint32_t> view{1u};
};

struct SoftpalPage {
  uintptr_t sprite = 0u;
  int32_t buffer_w = 0;
  int32_t buffer_h = 0;
  uint64_t page_seq = 0u;
  uint32_t setpos_at = 0u;
  std::wstring text;
  std::vector<softpal::PageGlyph> glyphs;
};

struct SoftpalPacArchive {
  std::wstring path;
  std::vector<softpal::PacEntry> entries;
};

struct SoftpalTextRuntime {
  // ── HookWorker-owned ──
  bool resolved = false;
  bool installed = false;
  uint64_t processed_seq = 0u;
  uint32_t logged = 0u;
  SoftpalEvent copy;
  bool has_pending = false;
  SoftpalPage pending;
  // The last published page and its text event.
  bool has_published = false;
  SoftpalPage published;
  uint64_t published_event = 0u;
  std::array<std::wstring, kSoftpalSpriteSlots> last_text_by_slot{};
  std::array<uintptr_t, kSoftpalSpriteSlots> last_text_sprite{};
  bool archives_scanned = false;
  std::vector<SoftpalPacArchive> archives;

  // ── resolved once, read everywhere ──
  HMODULE module = nullptr;
  SoftpalFontSizeFn font_size = nullptr;
  uintptr_t get_window = 0u;
  uintptr_t get_parameters = 0u;

  // ── game threads, under page_lock ──
  SRWLOCK page_lock = SRWLOCK_INIT;
  uint32_t last_page_setpos = 0u;
  uint64_t next_page_seq = 0u;

  // ── shared ──
  std::atomic<bool> live{false};
  std::atomic<uint32_t> setpos_calls{0u};
  std::atomic<uint64_t> count{0u};
  std::array<std::atomic<uint64_t>, kSoftpalEventSlots> seq = {};
  std::array<SoftpalEvent, kSoftpalEventSlots> events = {};
  std::array<SoftpalSpriteSlot, kSoftpalSpriteSlots> sprites = {};
  std::atomic<uint32_t> page_hits{0u};
  std::atomic<uint32_t> voice_hits{0u};
};

// One PalSpriteLock .. PalSpriteUnlock transaction.  Pal draws from more
// than one thread (2026: the body on one, small sprites on another, both
// mid-page) and nests locks on one thread, so each thread keeps its own open
// transactions and a draw joins the one whose buffer it writes.
struct SoftpalTransaction {
  bool open = false;
  bool overflow = false;
  uintptr_t sprite = 0u;
  uintptr_t buffer = 0u;
  int32_t w = 0;
  int32_t h = 0;
  uint32_t count = 0u;
  softpal::GlyphDraw draws[softpal::kMaxPageGlyphs] = {};
};

constexpr uint32_t kSoftpalOpenTransactions = 4u;

struct SoftpalThreadTransactions {
  SoftpalTransaction slots[kSoftpalOpenTransactions] = {};
};

SoftpalTextRuntime g_softpal;
thread_local SoftpalThreadTransactions g_softpal_tx;

SoftpalTransaction* FindSoftpalTransaction(uintptr_t sprite,
                                           uintptr_t buffer) {
  for (auto& tx : g_softpal_tx.slots) {
    if (tx.open && (sprite == 0u || tx.sprite == sprite) &&
        (buffer == 0u || tx.buffer == buffer)) {
      return &tx;
    }
  }
  return nullptr;
}
volatile LONG g_softpal_diag = 0;

SoftpalFn g_softpal_lock_original = nullptr;
SoftpalFn g_softpal_unlock_original = nullptr;
SoftpalFn g_softpal_draw_original = nullptr;
SoftpalFn g_softpal_setpos_original = nullptr;
SoftpalFn g_softpal_view_original = nullptr;
SoftpalFn g_softpal_release_original = nullptr;
SoftpalFn g_softpal_sound_original = nullptr;

constexpr LONG kSoftpalDiagHooksInstalled = 0x1;
constexpr LONG kSoftpalDiagPageObserved = 0x2;
constexpr LONG kSoftpalDiagTextPublished = 0x4;
constexpr LONG kSoftpalDiagPageRejected = 0x8;
constexpr LONG kSoftpalDiagVoiceObserved = 0x10;
constexpr LONG kSoftpalDiagVoiceExported = 0x20;
constexpr LONG kSoftpalDiagVoiceMissing = 0x40;

void NoteSoftpalPublishedPage(const SoftpalPage& page, uint64_t text_event);

void SoftpalLog(const wchar_t* format, ...) {
  auto& rt = g_softpal;
  if (rt.logged >= kSoftpalLogBudget) return;
  ++rt.logged;
  wchar_t line[1024] = {};
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
  wchar_t stamped[1200] = {};
  _snwprintf_s(stamped, _TRUNCATE, L"%02u:%02u:%02u.%03u pid=%lu %s\r\n",
               now.wHour, now.wMinute, now.wSecond, now.wMilliseconds,
               GetCurrentProcessId(), line);
  char utf8[3600] = {};
  const int bytes = WideCharToMultiByte(CP_UTF8, 0, stamped, -1, utf8,
                                        sizeof(utf8), nullptr, nullptr);
  if (bytes > 1) {
    DWORD written = 0;
    WriteFile(file, utf8, static_cast<DWORD>(bytes - 1), &written, nullptr);
  }
  g_orig_CloseHandle(file);
}

// ── game thread ────────────────────────────────────────────────────────────

SoftpalSpriteSlot* FindSoftpalSprite(uintptr_t sprite) {
  if (sprite == 0u) return nullptr;
  for (auto& slot : g_softpal.sprites) {
    if (slot.sprite.load(std::memory_order_relaxed) == sprite) return &slot;
  }
  return nullptr;
}

// A slot for a sprite that just showed a page: its own, a free one, or the
// one whose page is oldest.
SoftpalSpriteSlot* ClaimSoftpalSprite(uintptr_t sprite) {
  if (SoftpalSpriteSlot* own = FindSoftpalSprite(sprite)) return own;
  SoftpalSpriteSlot* victim = nullptr;
  for (auto& slot : g_softpal.sprites) {
    if (slot.sprite.load(std::memory_order_relaxed) == 0u) {
      victim = &slot;
      break;
    }
    if (victim == nullptr || slot.page_seq.load(std::memory_order_relaxed) <
                                 victim->page_seq.load(
                                     std::memory_order_relaxed)) {
      victim = &slot;
    }
  }
  victim->page_seq.store(0u, std::memory_order_release);
  victim->content_hash = 0u;
  victim->placed.store(0u, std::memory_order_release);
  victim->view.store(1u, std::memory_order_release);
  victim->sprite.store(sprite, std::memory_order_release);
  return victim;
}

// FNV-1a over what was drawn (not the stale tail of a glyph's byte buffer).
uint64_t HashSoftpalDraws(const softpal::GlyphDraw* draws, uint32_t count) {
  uint64_t hash = 0xcbf29ce484222325ull;
  auto mix = [&hash](const void* data, size_t length) {
    const auto* bytes = static_cast<const uint8_t*>(data);
    for (size_t i = 0u; i < length; ++i) {
      hash = (hash ^ bytes[i]) * 0x100000001b3ull;
    }
  };
  for (uint32_t i = 0u; i < count; ++i) {
    mix(&draws[i].x, sizeof(draws[i].x));
    mix(&draws[i].y, sizeof(draws[i].y));
    mix(&draws[i].font_size, sizeof(draws[i].font_size));
    mix(draws[i].bytes, draws[i].length);
  }
  return hash;
}

SoftpalEvent* BeginSoftpalEvent(uint64_t* sequence) {
  auto& rt = g_softpal;
  *sequence = rt.count.fetch_add(1u, std::memory_order_acq_rel) + 1u;
  auto& slot_seq = rt.seq[*sequence % kSoftpalEventSlots];
  slot_seq.store(0u, std::memory_order_release);
  std::atomic_thread_fence(std::memory_order_release);
  return &rt.events[*sequence % kSoftpalEventSlots];
}

void CommitSoftpalEvent(SoftpalEvent* event, uint64_t sequence) {
  event->sequence = sequence;
  event->tick = GetTickCount64();
  std::atomic_thread_fence(std::memory_order_release);
  g_softpal.seq[sequence % kSoftpalEventSlots].store(sequence,
                                                     std::memory_order_release);
}

uintptr_t __cdecl SoftpalLockDetour(uintptr_t sprite, uintptr_t out_w,
                                    uintptr_t out_h, uintptr_t a3, uintptr_t a4,
                                    uintptr_t a5, uintptr_t a6, uintptr_t a7) {
  const uintptr_t buffer =
      g_softpal_lock_original(sprite, out_w, out_h, a3, a4, a5, a6, a7);
  if (!g_softpal.live.load(std::memory_order_acquire)) return buffer;
  // A relock of a sprite still open on this thread replaces that transaction.
  SoftpalTransaction* tx = FindSoftpalTransaction(sprite, 0u);
  if (tx != nullptr) tx->open = false;
  if (buffer == 0u) return buffer;
  int32_t w = 0, h = 0;
  __try {
    if (out_w != 0u) w = *reinterpret_cast<const int32_t*>(out_w);
    if (out_h != 0u) h = *reinterpret_cast<const int32_t*>(out_h);
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return buffer;
  }
  if (tx == nullptr) {
    for (auto& slot : g_softpal_tx.slots) {
      if (!slot.open) {
        tx = &slot;
        break;
      }
    }
  }
  // More nested locks than slots: that sprite's text is not tracked.
  if (tx == nullptr) return buffer;
  tx->open = true;
  tx->overflow = false;
  tx->sprite = sprite;
  tx->buffer = buffer;
  tx->w = w;
  tx->h = h;
  tx->count = 0u;
  return buffer;
}

uintptr_t __cdecl SoftpalDrawDetour(uintptr_t buffer, uintptr_t text,
                                    uintptr_t x, uintptr_t y, uintptr_t a4,
                                    uintptr_t a5, uintptr_t a6, uintptr_t a7) {
  SoftpalTransaction* tx =
      g_softpal.live.load(std::memory_order_acquire) && buffer != 0u &&
              text != 0u
          ? FindSoftpalTransaction(0u, buffer)
          : nullptr;
  if (tx != nullptr) {
    if (tx->count >= softpal::kMaxPageGlyphs) {
      tx->overflow = true;
    } else {
      softpal::GlyphDraw& draw = tx->draws[tx->count];
      bool ok = false;
      __try {
        const char* source = reinterpret_cast<const char*>(text);
        uint32_t length = 0u;
        while (length < softpal::kMaxGlyphBytes && source[length] != '\0') {
          draw.bytes[length] = source[length];
          ++length;
        }
        ok = length > 0u && length < softpal::kMaxGlyphBytes;
        draw.length = static_cast<uint8_t>(length);
      } __except (EXCEPTION_EXECUTE_HANDLER) {
      }
      if (ok) {
        draw.x = static_cast<int32_t>(x);
        draw.y = static_cast<int32_t>(y);
        draw.font_size =
            g_softpal.font_size != nullptr ? g_softpal.font_size() : 0;
        ++tx->count;
      } else {
        tx->overflow = true;
      }
    }
  }
  return g_softpal_draw_original(buffer, text, x, y, a4, a5, a6, a7);
}

uintptr_t __cdecl SoftpalUnlockDetour(uintptr_t sprite, uintptr_t a1,
                                      uintptr_t a2, uintptr_t a3, uintptr_t a4,
                                      uintptr_t a5, uintptr_t a6,
                                      uintptr_t a7) {
  auto& rt = g_softpal;
  SoftpalTransaction* tx = rt.live.load(std::memory_order_acquire)
                               ? FindSoftpalTransaction(sprite, 0u)
                               : nullptr;
  if (tx != nullptr) {
    tx->open = false;
    // A transaction without glyphs (the typewriter reveal) changes no text.
    if (tx->count != 0u && !tx->overflow) {
      rt.page_hits.fetch_add(1u, std::memory_order_relaxed);
      AcquireSRWLockExclusive(&rt.page_lock);
      const uint32_t setpos = rt.setpos_calls.load(std::memory_order_relaxed);
      SoftpalSpriteSlot* slot = ClaimSoftpalSprite(sprite);
      const uint64_t hash = HashSoftpalDraws(tx->draws, tx->count);
      const uint64_t previous = slot->page_seq.load(std::memory_order_relaxed);
      const uint64_t page_seq = previous != 0u && slot->content_hash == hash
                                    ? previous
                                    : ++rt.next_page_seq;
      slot->content_hash = hash;
      uint64_t sequence = 0u;
      SoftpalEvent* event = BeginSoftpalEvent(&sequence);
      event->kind = kSoftpalEventPage;
      event->sprite = sprite;
      event->buffer_w = tx->w;
      event->buffer_h = tx->h;
      event->page_seq = page_seq;
      event->setpos_before = setpos - rt.last_page_setpos;
      event->setpos_at = setpos;
      event->count = tx->count;
      std::memcpy(event->draws, tx->draws,
                  sizeof(softpal::GlyphDraw) * tx->count);
      CommitSoftpalEvent(event, sequence);
      rt.last_page_setpos = setpos;
      slot->page_seq.store(page_seq, std::memory_order_release);
      ReleaseSRWLockExclusive(&rt.page_lock);
    }
  }
  return g_softpal_unlock_original(sprite, a1, a2, a3, a4, a5, a6, a7);
}

uintptr_t __cdecl SoftpalSetPosDetour(uintptr_t sprite, uintptr_t x,
                                      uintptr_t y, uintptr_t a3, uintptr_t a4,
                                      uintptr_t a5, uintptr_t a6,
                                      uintptr_t a7) {
  auto& rt = g_softpal;
  if (rt.live.load(std::memory_order_acquire)) {
    rt.setpos_calls.fetch_add(1u, std::memory_order_relaxed);
    if (SoftpalSpriteSlot* slot = FindSoftpalSprite(sprite)) {
      slot->x_bits.store(static_cast<uint32_t>(x), std::memory_order_relaxed);
      slot->y_bits.store(static_cast<uint32_t>(y), std::memory_order_relaxed);
      slot->placed.store(1u, std::memory_order_release);
    }
  }
  return g_softpal_setpos_original(sprite, x, y, a3, a4, a5, a6, a7);
}

uintptr_t __cdecl SoftpalViewDetour(uintptr_t sprite, uintptr_t view,
                                    uintptr_t a2, uintptr_t a3, uintptr_t a4,
                                    uintptr_t a5, uintptr_t a6, uintptr_t a7) {
  if (g_softpal.live.load(std::memory_order_acquire)) {
    if (SoftpalSpriteSlot* slot = FindSoftpalSprite(sprite)) {
      slot->view.store(static_cast<uint32_t>(view), std::memory_order_release);
    }
  }
  return g_softpal_view_original(sprite, view, a2, a3, a4, a5, a6, a7);
}

uintptr_t __cdecl SoftpalReleaseDetour(uintptr_t sprite, uintptr_t a1,
                                       uintptr_t a2, uintptr_t a3,
                                       uintptr_t a4, uintptr_t a5,
                                       uintptr_t a6, uintptr_t a7) {
  if (g_softpal.live.load(std::memory_order_acquire)) {
    if (SoftpalSpriteSlot* slot = FindSoftpalSprite(sprite)) {
      slot->page_seq.store(0u, std::memory_order_release);
      slot->placed.store(0u, std::memory_order_release);
      slot->sprite.store(0u, std::memory_order_release);
    }
  }
  return g_softpal_release_original(sprite, a1, a2, a3, a4, a5, a6, a7);
}

uintptr_t __cdecl SoftpalSoundDetour(uintptr_t name, uintptr_t type,
                                     uintptr_t a2, uintptr_t a3, uintptr_t a4,
                                     uintptr_t a5, uintptr_t a6,
                                     uintptr_t a7) {
  auto& rt = g_softpal;
  if (rt.live.load(std::memory_order_acquire) && name != 0u &&
      type == softpal::kSoundTypeVoice) {
    rt.voice_hits.fetch_add(1u, std::memory_order_relaxed);
    uint64_t sequence = 0u;
    SoftpalEvent* event = BeginSoftpalEvent(&sequence);
    bool copied = false;
    __try {
      const char* source = reinterpret_cast<const char*>(name);
      uint32_t i = 0u;
      for (; i + 1u < kSoftpalNameBytes && source[i] != '\0'; ++i) {
        event->name[i] = source[i];
      }
      event->name[i] = '\0';
      copied = i > 0u && source[i] == '\0';
    } __except (EXCEPTION_EXECUTE_HANDLER) {
    }
    if (copied) {
      const uint32_t setpos = rt.setpos_calls.load(std::memory_order_relaxed);
      event->kind = kSoftpalEventVoice;
      event->sound_type = static_cast<uint32_t>(type);
      event->setpos_before = setpos - rt.last_page_setpos;
      event->setpos_at = setpos;
      event->count = 0u;
      CommitSoftpalEvent(event, sequence);
    }
    // A failed copy leaves the slot at 0: the worker skips it.
  }
  return g_softpal_sound_original(name, type, a2, a3, a4, a5, a6, a7);
}

// ── install ────────────────────────────────────────────────────────────────

// One detour; a target someone else already hooked installs nothing.
bool InstallSoftpalHook(void* target, void* detour, SoftpalFn* original) {
  if (!g_cs_ready || target == nullptr) return false;
  EnterCriticalSection(&g_cs);
  bool ok = g_hooked_count + 1 <= 64;
  for (int i = 0; ok && i < g_hooked_count; ++i) {
    ok = g_hooked_fns[i] != target;
  }
  bool created = false;
  if (ok) {
    created = MH_CreateHook(target, detour,
                            reinterpret_cast<void**>(original)) == MH_OK;
    ok = created && MH_QueueEnableHook(target) == MH_OK &&
         MH_ApplyQueued() == MH_OK;
  }
  if (ok) {
    g_hooked_fns[g_hooked_count++] = target;
  } else {
    if (created) MH_RemoveHook(target);
    *original = nullptr;
  }
  LeaveCriticalSection(&g_cs);
  return ok;
}

bool InstallSoftpalText(const wchar_t* module_name) {
  auto& rt = g_softpal;
  if (rt.installed) return true;
  if (rt.resolved) return false;
  const HMODULE module = fushi_voice_hook::FindSoftpalModule(module_name);
  if (module == nullptr) return false;
  rt.resolved = true;
  rt.module = module;
  auto proc = [module](const char* name) {
    return reinterpret_cast<void*>(GetProcAddress(module, name));
  };
  rt.font_size = reinterpret_cast<SoftpalFontSizeFn>(proc("PalFontGetFontSize"));
  rt.get_window = reinterpret_cast<uintptr_t>(proc("PalGetWindowHandle"));
  rt.get_parameters =
      reinterpret_cast<uintptr_t>(proc("PalGetSystemParameters"));
  rt.live.store(true, std::memory_order_release);
  // Placement and the voice first: a page seen before them would carry a
  // wrong step count.  The lock last, so no transaction starts half-hooked.
  const bool setpos = InstallSoftpalHook(
      proc("PalSpriteSetPos"), reinterpret_cast<void*>(&SoftpalSetPosDetour),
      &g_softpal_setpos_original);
  const bool view = InstallSoftpalHook(
      proc("PalSpriteViewCtrl"), reinterpret_cast<void*>(&SoftpalViewDetour),
      &g_softpal_view_original);
  const bool release = InstallSoftpalHook(
      proc("PalSpriteRelease"), reinterpret_cast<void*>(&SoftpalReleaseDetour),
      &g_softpal_release_original);
  const bool sound = InstallSoftpalHook(
      proc("PalSoundLoad"), reinterpret_cast<void*>(&SoftpalSoundDetour),
      &g_softpal_sound_original);
  const bool draw = setpos && InstallSoftpalHook(
      proc("PalFontDrawText"), reinterpret_cast<void*>(&SoftpalDrawDetour),
      &g_softpal_draw_original);
  const bool unlock = draw && InstallSoftpalHook(
      proc("PalSpriteUnlock"), reinterpret_cast<void*>(&SoftpalUnlockDetour),
      &g_softpal_unlock_original);
  const bool lock = unlock && InstallSoftpalHook(
      proc("PalSpriteLock"), reinterpret_cast<void*>(&SoftpalLockDetour),
      &g_softpal_lock_original);
  rt.installed = lock;
  if (!rt.installed) rt.live.store(false, std::memory_order_release);
  if (rt.installed) InterlockedOr(&g_softpal_diag, kSoftpalDiagHooksInstalled);
  wchar_t module_path[MAX_PATH] = {};
  GetModuleFileNameW(module, module_path, MAX_PATH);
  SoftpalLog(L"softpal: module=%s setpos=%d view=%d release=%d sound=%d "
             L"draw=%d unlock=%d lock=%d font=%p window=%p params=%p",
             module_path, setpos ? 1 : 0, view ? 1 : 0, release ? 1 : 0,
             sound ? 1 : 0, draw ? 1 : 0, unlock ? 1 : 0, lock ? 1 : 0,
             rt.font_size, reinterpret_cast<void*>(rt.get_window),
             reinterpret_cast<void*>(rt.get_parameters));
  return rt.installed;
}

// ── HookWorker: archives ───────────────────────────────────────────────────

bool ReadSoftpalFileAt(HANDLE file, uint64_t offset, void* out,
                       uint32_t length) {
  LARGE_INTEGER position = {};
  position.QuadPart = static_cast<LONGLONG>(offset);
  return SetFilePointerEx(file, position, nullptr, FILE_BEGIN) &&
         ReadExact(file, out, length);
}

// Every archive next to the executable, indexed once.
void ScanSoftpalArchives() {
  auto& rt = g_softpal;
  if (rt.archives_scanned) return;
  rt.archives_scanned = true;
  wchar_t exe[MAX_PATH] = {};
  const DWORD chars = GetModuleFileNameW(nullptr, exe, MAX_PATH);
  if (chars == 0u || chars >= MAX_PATH) return;
  std::wstring dir(exe);
  dir.resize(dir.find_last_of(L"\\/") + 1u);
  WIN32_FIND_DATAW found = {};
  HANDLE search = FindFirstFileW((dir + L"*.pac").c_str(), &found);
  if (search == INVALID_HANDLE_VALUE) return;
  do {
    if ((found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0u) continue;
    SoftpalPacArchive archive;
    archive.path = dir + found.cFileName;
    HANDLE file = g_orig_CreateFileW(
        archive.path.c_str(), GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
        OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) continue;
    LARGE_INTEGER size = {};
    uint8_t header[12] = {};
    uint32_t count = 0u;
    bool ok = GetFileSizeEx(file, &size) &&
              ReadSoftpalFileAt(file, 0u, header, sizeof(header)) &&
              softpal::ParsePacHeader(header, sizeof(header), &count);
    std::vector<uint8_t> index;
    if (ok) {
      index.resize(static_cast<size_t>(count) * softpal::kPacEntryBytes);
      ok = ReadSoftpalFileAt(file, softpal::kPacIndexOffset, index.data(),
                             static_cast<uint32_t>(index.size())) &&
           softpal::ParsePacIndex(index.data(), index.size(), count,
                                  static_cast<uint64_t>(size.QuadPart),
                                  &archive.entries);
    }
    g_orig_CloseHandle(file);
    SoftpalLog(L"softpal: archive %s entries=%u ok=%d", found.cFileName,
               static_cast<unsigned>(archive.entries.size()), ok ? 1 : 0);
    if (ok) rt.archives.push_back(std::move(archive));
  } while (FindNextFileW(search, &found));
  FindClose(search);
}

// The voice from the game's archive, written as a resource for `text_event`.
bool ExportSoftpalVoice(const char* name, uint64_t text_event, uint64_t tick) {
  auto& rt = g_softpal;
  ScanSoftpalArchives();
  const std::string key =
      softpal::NormalizeResourceName(name, kSoftpalNameBytes);
  for (const SoftpalPacArchive& archive : rt.archives) {
    const softpal::PacEntry* entry = softpal::FindPacEntry(archive.entries, key);
    if (entry == nullptr) continue;
    if (entry->size == 0u || entry->size > (64u << 20)) return false;
    HANDLE file = g_orig_CreateFileW(
        archive.path.c_str(), GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
        OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return false;
    std::vector<uint8_t> payload(entry->size);
    const bool read =
        ReadSoftpalFileAt(file, entry->offset, payload.data(), entry->size);
    g_orig_CloseHandle(file);
    if (!read || !softpal::IsOggPayload(payload.data(), payload.size())) {
      return false;
    }
    wchar_t wide[kSoftpalNameBytes] = {};
    MultiByteToWideChar(932, 0, key.c_str(), -1, wide, kSoftpalNameBytes);
    if (!WriteVoiceOggAt(payload.data(), entry->size, wide, tick,
                         text_event)) {
      return false;
    }
    // The bytes are the engine's own resource for this line: the host pairs
    // per line instead of staying on the PCM / loopback fallback.
    SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagGameResourcePublished);
    return true;
  }
  return false;
}

// ── HookWorker: pages ──────────────────────────────────────────────────────

constexpr char kSoftpalHookName[] = "SoftPal exact";

uint64_t PublishSoftpalText(const SoftpalPage& page) {
  if (!g_capture_enabled || g_header == nullptr || g_text_base == nullptr ||
      !g_text_cs_ready || page.text.empty() ||
      page.text.size() * sizeof(wchar_t) > fushi_voice_hook::kTextSlotBytes) {
    return 0u;
  }
  // One lane per text sprite size: the message body, the speaker plate and
  // the menus keep apart, stable across runs and sprites.
  wchar_t hook_code[64] = {};
  _snwprintf_s(hook_code, _TRUNCATE, L"ENGINE:SOFTPAL:text_%dx%d",
               page.buffer_w, page.buffer_h);
  const uint64_t identity = (static_cast<uint64_t>(
                                 static_cast<uint32_t>(page.buffer_w))
                             << 32) |
                            static_cast<uint32_t>(page.buffer_h);
  fushi_voice_hook::TextLaneWrite write;
  write.thread_id = fushi_voice_hook::NativeTextThreadIdFrom(
      identity, hook_code, kSoftpalHookName);
  write.thread_address = page.sprite;
  write.thread_context = page.sprite;
  write.process_id = GetCurrentProcessId();
  write.source_kind = fushi_voice_hook::kTextSourceSoftpal;
  write.is_utf8 = 0;
  write.text = page.text.data();
  write.byte_len = static_cast<uint32_t>(page.text.size() * sizeof(wchar_t));
  write.hook_name = kSoftpalHookName;
  write.hook_code = hook_code;
  EnterCriticalSection(&g_text_cs);
  const uint64_t event = fushi_voice_hook::WriteTextLaneEvent(
      g_header, fushi_voice_hook::kNativeThreadPreviewStart,
      fushi_voice_hook::kTextLaneCount, write);
  LeaveCriticalSection(&g_text_cs);
  if (event == 0u) return 0u;
  // An exact engine producer is live: the GDI glyph fallback yields.
  g_header->luna_active = 1;
  return event;
}

// The pending page is a body: publish it (unless the sprite already shows
// exactly that text).
void FlushSoftpalPending() {
  auto& rt = g_softpal;
  if (!rt.has_pending) return;
  rt.has_pending = false;
  SoftpalPage& page = rt.pending;
  size_t slot = kSoftpalSpriteSlots;
  for (size_t i = 0u; i < kSoftpalSpriteSlots; ++i) {
    if (rt.last_text_sprite[i] == page.sprite) slot = i;
  }
  if (slot < kSoftpalSpriteSlots && rt.last_text_by_slot[slot] == page.text) {
    // A redraw: the published page stays current for the voice of this step.
    if (rt.has_published && rt.published.sprite == page.sprite) {
      rt.published.setpos_at = page.setpos_at;
      rt.published.page_seq = page.page_seq;
      NoteSoftpalPublishedPage(rt.published, rt.published_event);
    }
    return;
  }
  const uint64_t event = PublishSoftpalText(page);
  SoftpalLog(L"softpal: page sprite=%p %dx%d glyphs=%u units=%u event=%llu",
             reinterpret_cast<void*>(page.sprite), page.buffer_w,
             page.buffer_h, static_cast<unsigned>(page.glyphs.size()),
             static_cast<unsigned>(page.text.size()),
             static_cast<unsigned long long>(event));
  if (event == 0u) return;
  InterlockedOr(&g_softpal_diag, kSoftpalDiagTextPublished);
  if (slot == kSoftpalSpriteSlots) {
    slot = static_cast<size_t>(page.page_seq % kSoftpalSpriteSlots);
    rt.last_text_sprite[slot] = page.sprite;
  }
  rt.last_text_by_slot[slot] = page.text;
  rt.published = page;
  rt.published_event = event;
  rt.has_published = true;
  NoteSoftpalPublishedPage(rt.published, event);
}

void ProcessSoftpalPageEvent(const SoftpalEvent& event) {
  auto& rt = g_softpal;
  InterlockedOr(&g_softpal_diag, kSoftpalDiagPageObserved);
  SoftpalPage page;
  page.sprite = event.sprite;
  page.buffer_w = event.buffer_w;
  page.buffer_h = event.buffer_h;
  page.page_seq = event.page_seq;
  page.setpos_at = event.setpos_at;
  const softpal::PageResult result = softpal::ComposePage(
      event.draws, event.count, &page.text, &page.glyphs);
  if (rt.has_pending) {
    if (softpal::IsSpeakerLabel(rt.pending.sprite, event.sprite,
                                event.setpos_before)) {
      SoftpalLog(L"softpal: speaker plate sprite=%p units=%u dropped",
                 reinterpret_cast<void*>(rt.pending.sprite),
                 static_cast<unsigned>(rt.pending.text.size()));
      rt.has_pending = false;
    } else {
      FlushSoftpalPending();
    }
  }
  if (result != softpal::PageResult::kComposed) {
    if (result == softpal::PageResult::kRejected) {
      InterlockedOr(&g_softpal_diag, kSoftpalDiagPageRejected);
      SoftpalLog(L"softpal: page sprite=%p glyphs=%u rejected",
                 reinterpret_cast<void*>(event.sprite), event.count);
    }
    return;
  }
  rt.pending = std::move(page);
  rt.has_pending = true;
}

void ProcessSoftpalVoiceEvent(const SoftpalEvent& event) {
  auto& rt = g_softpal;
  InterlockedOr(&g_softpal_diag, kSoftpalDiagVoiceObserved);
  // A voice in the step of a page closes that step: the page is a body.
  if (rt.has_pending && event.setpos_before == 0u) FlushSoftpalPending();
  const bool paired = softpal::VoicePairsWithPage(
      event.sound_type, rt.has_published,
      rt.has_published ? event.setpos_at - rt.published.setpos_at : 1u);
  bool exported = false;
  if (paired) {
    exported = ExportSoftpalVoice(event.name, rt.published_event, event.tick);
    InterlockedOr(&g_softpal_diag, exported ? kSoftpalDiagVoiceExported
                                            : kSoftpalDiagVoiceMissing);
  }
  wchar_t wide[kSoftpalNameBytes] = {};
  MultiByteToWideChar(932, 0, event.name, -1, wide, kSoftpalNameBytes);
  SoftpalLog(L"softpal: voice %s paired=%d event=%llu exported=%d", wide,
             paired ? 1 : 0,
             static_cast<unsigned long long>(paired ? rt.published_event : 0u),
             exported ? 1 : 0);
}

void ProcessSoftpalTextTick() {
  auto& rt = g_softpal;
  if (!rt.installed) return;
  // Read before the events: every event of a step is committed before the
  // engine places its next sprite.
  const uint32_t setpos_now = rt.setpos_calls.load(std::memory_order_acquire);
  const uint64_t latest = rt.count.load(std::memory_order_acquire);
  uint64_t next = rt.processed_seq + 1u;
  if (latest - rt.processed_seq > kSoftpalEventSlots) {
    next = latest - kSoftpalEventSlots + 1u;
  }
  for (; next <= latest; ++next) {
    auto& slot_seq = rt.seq[next % kSoftpalEventSlots];
    if (slot_seq.load(std::memory_order_acquire) != next) {
      // In flight, or the copy faulted: skip it once the producer moved on.
      if (next < latest) {
        rt.processed_seq = next;
        continue;
      }
      break;
    }
    std::atomic_thread_fence(std::memory_order_acquire);
    std::memcpy(&rt.copy, &rt.events[next % kSoftpalEventSlots],
                sizeof(SoftpalEvent));
    std::atomic_thread_fence(std::memory_order_acquire);
    rt.processed_seq = next;
    if (slot_seq.load(std::memory_order_acquire) != next) continue;  // torn
    if (rt.copy.kind == kSoftpalEventPage) {
      ProcessSoftpalPageEvent(rt.copy);
    } else if (rt.copy.kind == kSoftpalEventVoice) {
      ProcessSoftpalVoiceEvent(rt.copy);
    }
  }
  // The engine moved past the step of the pending page: no plate rule can
  // apply any more, it is a body.
  if (rt.has_pending &&
      static_cast<int32_t>(setpos_now - rt.pending.setpos_at) > 0 &&
      next > latest) {
    FlushSoftpalPending();
  }
}

void ShutdownSoftpalText() {
  auto& rt = g_softpal;
  rt.live.store(false, std::memory_order_release);
  rt.installed = false;
}

#else  // !_M_IX86

bool InstallSoftpalText(const wchar_t*) { return false; }
void ProcessSoftpalTextTick() {}
void ShutdownSoftpalText() {}
volatile LONG g_softpal_diag = 0;

#endif  // _M_IX86
