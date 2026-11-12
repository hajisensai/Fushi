// AliceSoft System 4 text lane.  Engine facts and every rule live in
// system4_core.h and are unit-tested; this file binds them to MinHook, Win32
// and the text lanes.
//
// Threads:
//   * VM thread — the VM's MSG handler detour appends the message line to the
//     page group; the SP_TextDraw detour matches each drawn character to the
//     group and records its sprite-local cell; SP_TextClear / SP_Delete end a
//     group on its sprite; SP_SetPos / SP_SetShow / SP_Delete keep the
//     placement of the sprite that shows the latest page.  A finished group
//     is copied into a fixed ring (no allocation, no IO, no conversion).
//   * HookWorker — ProcessSystem4TextTick: converts each group to UTF-16,
//     publishes it on the engine's message lane and hands a group with
//     complete geometry to the lookup (system4_lookup.inc).
//
// Fail closed: without both the SACT2 surface and a decoded MSG handler
// nothing is installed; a line that is not clean CP932 publishes nothing; a
// group whose draws did not cover every character has no geometry.

#if defined(_M_IX86)

namespace system4 = fushi_voice_hook::system4;

constexpr uint32_t kSystem4EventSlots = 16u;
constexpr uint32_t kSystem4SpriteSlots = 4u;
constexpr uint32_t kSystem4LogBudget = 4096u;

// The HLL string object: first virtual returns the CP932 bytes.
struct System4HllString {
  virtual const char* __thiscall Bytes() = 0;
};
// The HLL text metrics object: fourth virtual returns the raw block.
struct System4HllMetrics {
  virtual void* __thiscall V0() = 0;
  virtual void* __thiscall V1() = 0;
  virtual void* __thiscall V2() = 0;
  virtual const uint8_t* __thiscall Raw(int) = 0;
};

using System4IntFn0 = int(__cdecl*)();
using System4IntFn1 = int(__cdecl*)(int);
using System4TextDrawFn = int(__cdecl*)(int, System4HllString*,
                                        System4HllMetrics*);
using System4SpriteFn = int(__cdecl*)(int);
using System4SpriteIntFn = int(__cdecl*)(int, int);
using System4SetPosFn = int(__cdecl*)(int, int, int);
using System4MsgFn = char(__stdcall*)(uint8_t*);

// A finished group, as the VM thread copied it.
struct System4Event {
  uint64_t sequence = 0u;
  uint64_t tick = 0u;
  uint64_t page_seq = 0u;  // non-zero: the geometry is complete
  int32_t sprite = 0;
  int32_t origin_x = 0;  // the sprite on the design screen
  int32_t origin_y = 0;
  int32_t design_w = 0;
  int32_t design_h = 0;
  uint32_t thread = 0u;  // the VM thread (owns the game window)
  uint32_t line_count = 0u;
  uint32_t bytes_len = 0u;
  uint32_t char_count = 0u;
  char bytes[system4::kMaxGroupBytes] = {};
  uint16_t char_start[system4::kMaxGroupChars] = {};
  uint8_t char_len[system4::kMaxGroupChars] = {};
  system4::GroupGlyph glyphs[system4::kMaxGroupChars] = {};
};

// The sprite showing a page with geometry, as the VM thread last placed it.
struct System4SpriteSlot {
  std::atomic<int32_t> sprite{0};
  std::atomic<uint64_t> page_seq{0u};  // 0: the page is gone
  std::atomic<int32_t> x{0};
  std::atomic<int32_t> y{0};
  std::atomic<uint32_t> view{0u};
};

struct System4Page {
  int32_t sprite = 0;
  uint64_t page_seq = 0u;
  int32_t origin_x = 0;
  int32_t origin_y = 0;
  int32_t design_w = 0;
  int32_t design_h = 0;
  uint32_t thread = 0u;
  std::wstring text;
  std::vector<system4::PageGlyph> glyphs;
};

struct System4TextRuntime {
  // ── HookWorker-owned ──
  bool resolved = false;
  bool installed = false;
  uint64_t processed_seq = 0u;
  uint32_t logged = 0u;
  System4Event copy;
  uint32_t vm_thread = 0u;

  // ── resolved once, read everywhere ──
  HMODULE sact2 = nullptr;
  HMODULE vm = nullptr;
  system4::MsgLayout layout;
  System4IntFn1 get_text_x = nullptr;
  System4IntFn1 get_text_y = nullptr;
  System4IntFn1 get_x = nullptr;
  System4IntFn1 get_y = nullptr;
  System4IntFn1 get_show = nullptr;
  System4IntFn0 screen_w = nullptr;
  System4IntFn0 screen_h = nullptr;

  // ── VM thread, under group_lock ──
  SRWLOCK group_lock = SRWLOCK_INIT;
  system4::Group group;
  int32_t group_origin_x = 0;
  int32_t group_origin_y = 0;
  int32_t group_design_w = 0;
  int32_t group_design_h = 0;
  uint64_t next_page_seq = 0u;

  // ── shared ──
  std::atomic<bool> live{false};
  std::atomic<uint32_t> thread{0u};
  std::atomic<uint64_t> count{0u};
  std::array<std::atomic<uint64_t>, kSystem4EventSlots> seq = {};
  std::array<System4Event, kSystem4EventSlots> events = {};
  std::array<System4SpriteSlot, kSystem4SpriteSlots> sprites = {};
  std::atomic<uint32_t> messages{0u};
  std::atomic<uint32_t> draws{0u};
  std::atomic<uint32_t> groups{0u};
};

System4TextRuntime g_system4;
volatile LONG g_system4_diag = 0;

System4MsgFn g_system4_msg_original = nullptr;
System4TextDrawFn g_system4_draw_original = nullptr;
System4SpriteFn g_system4_clear_original = nullptr;
System4SpriteFn g_system4_delete_original = nullptr;
System4SpriteIntFn g_system4_show_original = nullptr;
System4SetPosFn g_system4_setpos_original = nullptr;

constexpr LONG kSystem4DiagHooksInstalled = 0x1;
constexpr LONG kSystem4DiagMessageObserved = 0x2;
constexpr LONG kSystem4DiagTextPublished = 0x4;
constexpr LONG kSystem4DiagLineRejected = 0x8;
constexpr LONG kSystem4DiagGeometryComplete = 0x10;
constexpr LONG kSystem4DiagGeometryBroken = 0x20;
constexpr LONG kSystem4DiagEventsLost = 0x80;

void NoteSystem4PublishedPage(const System4Page& page, uint64_t text_event);

void System4Log(const wchar_t* format, ...) {
  auto& rt = g_system4;
  if (rt.logged >= kSystem4LogBudget) return;
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

// ── VM thread ──────────────────────────────────────────────────────────────

System4SpriteSlot* FindSystem4Sprite(int32_t sprite) {
  if (sprite == 0) return nullptr;
  for (auto& slot : g_system4.sprites) {
    if (slot.sprite.load(std::memory_order_relaxed) == sprite) return &slot;
  }
  return nullptr;
}

// A slot for a sprite that just showed a page: its own, a free one, or the
// one whose page is oldest.
System4SpriteSlot* ClaimSystem4Sprite(int32_t sprite) {
  if (System4SpriteSlot* own = FindSystem4Sprite(sprite)) return own;
  System4SpriteSlot* victim = nullptr;
  for (auto& slot : g_system4.sprites) {
    if (slot.sprite.load(std::memory_order_relaxed) == 0) {
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
  victim->sprite.store(sprite, std::memory_order_release);
  return victim;
}

int System4Query(System4IntFn1 fn, int sprite, int fallback) {
  return fn != nullptr ? fn(sprite) : fallback;
}

// Under group_lock: copy the group into the ring and reset it.
void CommitSystem4Group() {
  auto& rt = g_system4;
  system4::Group& g = rt.group;
  if (g.char_count == 0u) {
    system4::ResetGroup(&g);
    return;
  }
  const bool complete = system4::GroupComplete(g);
  InterlockedOr(&g_system4_diag, complete ? kSystem4DiagGeometryComplete
                                          : kSystem4DiagGeometryBroken);
  uint64_t page_seq = 0u;
  if (complete) {
    page_seq = ++rt.next_page_seq;
    System4SpriteSlot* slot = ClaimSystem4Sprite(g.sprite);
    slot->x.store(rt.group_origin_x, std::memory_order_relaxed);
    slot->y.store(rt.group_origin_y, std::memory_order_relaxed);
    slot->view.store(
        System4Query(rt.get_show, g.sprite, 0) != 0 ? 1u : 0u,
        std::memory_order_relaxed);
    slot->page_seq.store(page_seq, std::memory_order_release);
  }
  const uint64_t sequence = rt.count.fetch_add(1u, std::memory_order_acq_rel) + 1u;
  auto& slot_seq = rt.seq[sequence % kSystem4EventSlots];
  slot_seq.store(0u, std::memory_order_release);
  std::atomic_thread_fence(std::memory_order_release);
  System4Event& event = rt.events[sequence % kSystem4EventSlots];
  event.page_seq = page_seq;
  event.sprite = g.sprite;
  event.origin_x = rt.group_origin_x;
  event.origin_y = rt.group_origin_y;
  event.design_w = rt.group_design_w;
  event.design_h = rt.group_design_h;
  event.thread = rt.thread.load(std::memory_order_relaxed);
  event.line_count = g.line_count;
  event.bytes_len = g.bytes_len;
  event.char_count = g.char_count;
  std::memcpy(event.bytes, g.bytes, g.bytes_len);
  std::memcpy(event.char_start, g.char_start,
              sizeof(g.char_start[0]) * g.char_count);
  std::memcpy(event.char_len, g.char_len, sizeof(g.char_len[0]) * g.char_count);
  if (complete) {
    std::memcpy(event.glyphs, g.glyphs, sizeof(g.glyphs[0]) * g.char_count);
  }
  event.sequence = sequence;
  event.tick = GetTickCount64();
  std::atomic_thread_fence(std::memory_order_release);
  slot_seq.store(sequence, std::memory_order_release);
  rt.groups.fetch_add(1u, std::memory_order_relaxed);
  system4::ResetGroup(&g);
}

// The CP932 line of the message the handler is about to show; 0 bytes when
// there is none (no message function, an operand out of the code or the
// table).
uint32_t ReadSystem4Message(uint8_t* vm, char* out, uint32_t capacity) {
  const system4::MsgLayout& layout = g_system4.layout;
  uint32_t length = 0u;
  __try {
    if (*reinterpret_cast<const int32_t*>(vm + layout.msg_func) < 0) return 0u;
    const auto* code = *reinterpret_cast<const uint8_t* const*>(
        vm + layout.code_ptr);
    const auto* code_end = *reinterpret_cast<const uint8_t* const*>(
        vm + layout.code_end);
    if (code == nullptr || code + 4 > code_end) return 0u;
    const int32_t number = *reinterpret_cast<const int32_t*>(code);
    const auto* begin = *reinterpret_cast<const uint8_t* const*>(
        vm + layout.table_begin);
    const auto* end = *reinterpret_cast<const uint8_t* const*>(
        vm + layout.table_end);
    if (number < 0 || begin == nullptr || end < begin ||
        static_cast<uint64_t>(number) >=
            static_cast<uint64_t>(end - begin) / system4::kMsgEntryBytes) {
      return 0u;
    }
    const char* text = *reinterpret_cast<const char* const*>(
        begin + static_cast<size_t>(number) * system4::kMsgEntryBytes +
        system4::kMsgEntryTextOffset);
    if (text == nullptr) return 0u;
    while (length < capacity && text[length] != '\0') {
      out[length] = text[length];
      ++length;
    }
    // Longer than a page holds: not taken.
    if (length == capacity) length = 0u;
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    length = 0u;
  }
  return length;
}

char __stdcall System4MsgDetour(uint8_t* vm) {
  auto& rt = g_system4;
  if (rt.live.load(std::memory_order_acquire) && vm != nullptr) {
    char line[system4::kMaxGroupBytes];
    const uint32_t length = ReadSystem4Message(vm, line, sizeof(line));
    if (length != 0u) {
      rt.messages.fetch_add(1u, std::memory_order_relaxed);
      rt.thread.store(GetCurrentThreadId(), std::memory_order_relaxed);
      AcquireSRWLockExclusive(&rt.group_lock);
      system4::MessageResult result =
          system4::OnMessage(&rt.group, line, length);
      if (result == system4::MessageResult::kCommitFirst) {
        CommitSystem4Group();
        result = system4::OnMessage(&rt.group, line, length);
      }
      ReleaseSRWLockExclusive(&rt.group_lock);
      if (result == system4::MessageResult::kRejected) {
        InterlockedOr(&g_system4_diag, kSystem4DiagLineRejected);
      }
    }
  }
  return g_system4_msg_original(vm);
}

int __cdecl System4TextDrawDetour(int sprite, System4HllString* text,
                                  System4HllMetrics* metrics) {
  auto& rt = g_system4;
  if (!rt.live.load(std::memory_order_acquire) || text == nullptr ||
      metrics == nullptr) {
    return g_system4_draw_original(sprite, text, metrics);
  }
  char bytes[8] = {};
  uint32_t length = 0u;
  int32_t font_size = 0;
  __try {
    const char* source = text->Bytes();
    const uint8_t* raw = metrics->Raw(0);
    if (source != nullptr) {
      while (length < sizeof(bytes) && source[length] != '\0') {
        bytes[length] = source[length];
        ++length;
      }
      if (length == sizeof(bytes)) length = 0u;  // not one character
    }
    if (raw != nullptr) font_size = *reinterpret_cast<const int32_t*>(raw + 0x0c);
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    length = 0u;
  }
  const int32_t x_before = System4Query(rt.get_text_x, sprite, 0);
  const int32_t y_before = System4Query(rt.get_text_y, sprite, 0);
  const int result = g_system4_draw_original(sprite, text, metrics);
  if (length == 0u || !system4::FontSizePlausible(font_size)) return result;
  rt.draws.fetch_add(1u, std::memory_order_relaxed);
  const int32_t x_after = System4Query(rt.get_text_x, sprite, x_before);
  const system4::GroupGlyph glyph =
      system4::GlyphFromDraw(x_before, y_before, x_after, font_size);
  AcquireSRWLockExclusive(&rt.group_lock);
  const bool first = rt.group.matched == 0u;
  const system4::DrawResult drawn =
      system4::OnDraw(&rt.group, sprite, bytes, length, glyph);
  if (first && (drawn == system4::DrawResult::kMatched ||
                drawn == system4::DrawResult::kComplete)) {
    // The page's placement, as the engine shows it while drawing.
    rt.group_origin_x = System4Query(rt.get_x, sprite, 0);
    rt.group_origin_y = System4Query(rt.get_y, sprite, 0);
    rt.group_design_w = rt.screen_w != nullptr ? rt.screen_w() : 0;
    rt.group_design_h = rt.screen_h != nullptr ? rt.screen_h() : 0;
  }
  if (drawn == system4::DrawResult::kComplete) CommitSystem4Group();
  ReleaseSRWLockExclusive(&rt.group_lock);
  return result;
}

// The sprite's page is gone (cleared or deleted).
void EndSystem4SpritePage(int sprite) {
  auto& rt = g_system4;
  AcquireSRWLockExclusive(&rt.group_lock);
  if (system4::OnSpriteCleared(rt.group, sprite)) CommitSystem4Group();
  ReleaseSRWLockExclusive(&rt.group_lock);
  if (System4SpriteSlot* slot = FindSystem4Sprite(sprite)) {
    slot->page_seq.store(0u, std::memory_order_release);
  }
}

int __cdecl System4TextClearDetour(int sprite) {
  if (g_system4.live.load(std::memory_order_acquire)) {
    EndSystem4SpritePage(sprite);
  }
  return g_system4_clear_original(sprite);
}

int __cdecl System4DeleteDetour(int sprite) {
  if (g_system4.live.load(std::memory_order_acquire)) {
    EndSystem4SpritePage(sprite);
  }
  return g_system4_delete_original(sprite);
}

int __cdecl System4SetShowDetour(int sprite, int show) {
  if (g_system4.live.load(std::memory_order_acquire)) {
    if (System4SpriteSlot* slot = FindSystem4Sprite(sprite)) {
      slot->view.store(show != 0 ? 1u : 0u, std::memory_order_release);
    }
  }
  return g_system4_show_original(sprite, show);
}

// Called every frame for every sprite: a lookup of four slots at most.
int __cdecl System4SetPosDetour(int sprite, int x, int y) {
  if (g_system4.live.load(std::memory_order_acquire)) {
    if (System4SpriteSlot* slot = FindSystem4Sprite(sprite)) {
      slot->x.store(x, std::memory_order_relaxed);
      slot->y.store(y, std::memory_order_release);
    }
  }
  return g_system4_setpos_original(sprite, x, y);
}

// ── install ────────────────────────────────────────────────────────────────

// One detour; a target someone else already hooked installs nothing.
bool InstallSystem4Hook(void* target, void* detour, void** original) {
  if (!g_cs_ready || target == nullptr) return false;
  EnterCriticalSection(&g_cs);
  bool ok = g_hooked_count + 1 <= 64;
  for (int i = 0; ok && i < g_hooked_count; ++i) {
    ok = g_hooked_fns[i] != target;
  }
  bool created = false;
  if (ok) {
    created = MH_CreateHook(target, detour, original) == MH_OK;
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

template <typename Fn>
bool InstallSystem4Detour(void* target, Fn detour, Fn* original) {
  return InstallSystem4Hook(target, reinterpret_cast<void*>(detour),
                            reinterpret_cast<void**>(original));
}

bool InstallSystem4Text(const wchar_t* module_name) {
  auto& rt = g_system4;
  if (rt.installed) return true;
  if (rt.resolved) return false;
  const HMODULE sact2 = fushi_voice_hook::FindSystem4Sact2Module(module_name);
  if (sact2 == nullptr) return false;
  system4::MsgLayout layout;
  const HMODULE vm = fushi_voice_hook::FindSystem4VmModule(&layout);
  wchar_t sact2_path[MAX_PATH] = {};
  GetModuleFileNameW(sact2, sact2_path, MAX_PATH);
  if (vm == nullptr) {
    // The VM loads before its HLL libraries: a SACT2 without a decodable VM
    // is another build of the VM; nothing is installed.
    rt.resolved = true;
    System4Log(L"system4: sact2=%s vm handler not decoded", sact2_path);
    return false;
  }
  rt.resolved = true;
  rt.sact2 = sact2;
  rt.vm = vm;
  rt.layout = layout;
  auto proc = [sact2](const char* name) {
    return reinterpret_cast<void*>(GetProcAddress(sact2, name));
  };
  rt.get_text_x = reinterpret_cast<System4IntFn1>(proc("SP_GetTextPosX"));
  rt.get_text_y = reinterpret_cast<System4IntFn1>(proc("SP_GetTextPosY"));
  rt.get_x = reinterpret_cast<System4IntFn1>(proc("SP_GetPosX"));
  rt.get_y = reinterpret_cast<System4IntFn1>(proc("SP_GetPosY"));
  rt.get_show = reinterpret_cast<System4IntFn1>(proc("SP_GetShow"));
  rt.screen_w = reinterpret_cast<System4IntFn0>(proc("GetScreenWidth"));
  rt.screen_h = reinterpret_cast<System4IntFn0>(proc("GetScreenHeight"));
  rt.live.store(true, std::memory_order_release);
  // Placement first, so a page is never committed with its sprite untracked;
  // the MSG handler last, so no group starts half-hooked.
  const bool setpos = InstallSystem4Detour(proc("SP_SetPos"),
                                           &System4SetPosDetour,
                                           &g_system4_setpos_original);
  const bool show = setpos && InstallSystem4Detour(proc("SP_SetShow"),
                                                   &System4SetShowDetour,
                                                   &g_system4_show_original);
  const bool del = show && InstallSystem4Detour(proc("SP_Delete"),
                                                &System4DeleteDetour,
                                                &g_system4_delete_original);
  const bool clear = del && InstallSystem4Detour(proc("SP_TextClear"),
                                                 &System4TextClearDetour,
                                                 &g_system4_clear_original);
  const bool draw = clear && InstallSystem4Detour(proc("SP_TextDraw"),
                                                  &System4TextDrawDetour,
                                                  &g_system4_draw_original);
  void* handler = reinterpret_cast<uint8_t*>(vm) + layout.handler_rva;
  const bool msg = draw && InstallSystem4Detour(handler, &System4MsgDetour,
                                                &g_system4_msg_original);
  rt.installed = msg;
  if (!rt.installed) rt.live.store(false, std::memory_order_release);
  if (rt.installed) InterlockedOr(&g_system4_diag, kSystem4DiagHooksInstalled);
  wchar_t vm_path[MAX_PATH] = {};
  GetModuleFileNameW(vm, vm_path, MAX_PATH);
  System4Log(L"system4: sact2=%s vm=%s handler=+%x code=%x end=%x msgf=%x "
             L"table=%x setpos=%d show=%d delete=%d clear=%d draw=%d msg=%d",
             sact2_path, vm_path, layout.handler_rva, layout.code_ptr,
             layout.code_end, layout.msg_func, layout.table_begin,
             setpos ? 1 : 0, show ? 1 : 0, del ? 1 : 0, clear ? 1 : 0,
             draw ? 1 : 0, msg ? 1 : 0);
  return rt.installed;
}

// ── HookWorker ─────────────────────────────────────────────────────────────

constexpr char kSystem4HookName[] = "System4 MSG";
constexpr wchar_t kSystem4HookCode[] = L"ENGINE:SYSTEM4:message";

uint64_t PublishSystem4Text(const std::wstring& text) {
  if (!g_capture_enabled || g_header == nullptr || g_text_base == nullptr ||
      !g_text_cs_ready || text.empty() ||
      text.size() * sizeof(wchar_t) > fushi_voice_hook::kTextSlotBytes) {
    return 0u;
  }
  fushi_voice_hook::TextLaneWrite write;
  // One lane: the engine's message instruction is the body text.
  write.thread_id = fushi_voice_hook::NativeTextThreadIdFrom(
      0x5359533455ull, kSystem4HookCode, kSystem4HookName);
  write.thread_address = 0u;
  write.thread_context = 0u;
  write.process_id = GetCurrentProcessId();
  write.source_kind = fushi_voice_hook::kTextSourceSystem4;
  write.is_utf8 = 0;
  write.text = text.data();
  write.byte_len = static_cast<uint32_t>(text.size() * sizeof(wchar_t));
  write.hook_name = kSystem4HookName;
  write.hook_code = kSystem4HookCode;
  write.event_flags = fushi_voice_hook::kTextEventFlagLaneUniqueHookCode;
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

// The event's characters as UTF-16, each glyph with its place in the text.
bool ComposeSystem4Page(const System4Event& event, System4Page* page) {
  page->text.clear();
  page->glyphs.clear();
  for (uint32_t i = 0u; i < event.char_count; ++i) {
    wchar_t units[2] = {};
    const int count = MultiByteToWideChar(
        932, MB_ERR_INVALID_CHARS, event.bytes + event.char_start[i],
        event.char_len[i], units, 2);
    if (count <= 0) return false;
    if (event.page_seq != 0u) {
      system4::PageGlyph glyph;
      glyph.x = event.glyphs[i].x;
      glyph.y = event.glyphs[i].y;
      glyph.w = event.glyphs[i].w;
      glyph.h = event.glyphs[i].h;
      glyph.source_index = static_cast<uint16_t>(page->text.size());
      glyph.source_length = static_cast<uint16_t>(count);
      page->glyphs.push_back(glyph);
    }
    page->text.append(units, static_cast<size_t>(count));
  }
  page->sprite = event.sprite;
  page->page_seq = event.page_seq;
  page->origin_x = event.origin_x;
  page->origin_y = event.origin_y;
  page->design_w = event.design_w;
  page->design_h = event.design_h;
  page->thread = event.thread;
  return !page->text.empty();
}

void ProcessSystem4Event(const System4Event& event) {
  InterlockedOr(&g_system4_diag, kSystem4DiagMessageObserved);
  if (event.thread != 0u) g_system4.vm_thread = event.thread;
  System4Page page;
  if (!ComposeSystem4Page(event, &page)) {
    InterlockedOr(&g_system4_diag, kSystem4DiagLineRejected);
    System4Log(L"system4: group chars=%u rejected", event.char_count);
    return;
  }
  const uint64_t text_event = PublishSystem4Text(page.text);
  System4Log(L"system4: group lines=%u chars=%u sprite=%d geometry=%d "
             L"origin=%d,%d design=%dx%d event=%llu",
             event.line_count, event.char_count, event.sprite,
             event.page_seq != 0u ? 1 : 0, event.origin_x, event.origin_y,
             event.design_w, event.design_h,
             static_cast<unsigned long long>(text_event));
  if (text_event == 0u) return;
  InterlockedOr(&g_system4_diag, kSystem4DiagTextPublished);
  if (event.page_seq != 0u) NoteSystem4PublishedPage(page, text_event);
}

void ProcessSystem4TextTick() {
  auto& rt = g_system4;
  if (!rt.installed) return;
  const uint64_t latest = rt.count.load(std::memory_order_acquire);
  const system4::RingCursor start =
      system4::RingStart(rt.processed_seq, latest, kSystem4EventSlots);
  if (start.lost) {
    InterlockedOr(&g_system4_diag, kSystem4DiagEventsLost);
    System4Log(L"system4: events %llu..%llu overwritten before processing",
               static_cast<unsigned long long>(rt.processed_seq + 1u),
               static_cast<unsigned long long>(start.next - 1u));
    rt.processed_seq = start.next - 1u;
  }
  for (uint64_t next = start.next; next <= latest; ++next) {
    auto& slot_seq = rt.seq[next % kSystem4EventSlots];
    // Not committed yet (a producer still copying): wait for it, in order.
    if (!system4::RingSlotReady(slot_seq.load(std::memory_order_acquire),
                                next)) {
      break;
    }
    std::atomic_thread_fence(std::memory_order_acquire);
    std::memcpy(&rt.copy, &rt.events[next % kSystem4EventSlots],
                sizeof(System4Event));
    std::atomic_thread_fence(std::memory_order_acquire);
    // Overwritten while copying: the next tick reports the loss.
    if (slot_seq.load(std::memory_order_acquire) != next) break;
    rt.processed_seq = next;
    ProcessSystem4Event(rt.copy);
  }
}

void ShutdownSystem4Text() {
  auto& rt = g_system4;
  rt.live.store(false, std::memory_order_release);
  rt.installed = false;
}

#else  // !_M_IX86

bool InstallSystem4Text(const wchar_t*) { return false; }
void ProcessSystem4TextTick() {}
void ShutdownSystem4Text() {}
volatile LONG g_system4_diag = 0;

#endif  // _M_IX86
