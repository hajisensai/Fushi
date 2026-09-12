// Exact ChronoClock x64 loop observer. The callback brackets script update,
// layout update and drawing (0xd400), then publishes its root pointer; all
// memory reads, text decoding and IPC
// work stay on HookWorker. No GDI raster hook or guessed heap scan is installed.
namespace cmvs_lookup = fushi_voice_hook::cmvs_layout;
using CmvsFrameFn = void(__fastcall*)(void*);
CmvsFrameFn g_cmvs_frame_original = nullptr;
cmvs_lookup::HookInstallation g_cmvs_hook_installation;
std::atomic<uint64_t> g_cmvs_frame_sequence{0};
bool g_cmvs_identity_checked = false;
bool g_cmvs_identity_matched = false;
bool g_cmvs_shift_down = false;

struct CmvsRawBlock { uint64_t address = 0; uint32_t offset = 0, bytes = 0; };
struct CmvsRawFrame {
  uint64_t sequence = 0, root = 0, tick = 0;
  bool valid = false;
  uint32_t count = 0, used = 0;
  std::array<CmvsRawBlock, 4 * cmvs_lookup::kMaxGlyphs + 64> blocks{};
  std::array<uint8_t, 4 * 1024 * 1024> payload{};
};
CmvsRawFrame g_cmvs_raw_frame;
SRWLOCK g_cmvs_raw_lock = SRWLOCK_INIT;

bool CopyCmvsRawBytes(uint64_t address, void* output, size_t bytes) {
  if (!address || address > UINTPTR_MAX || bytes > UINTPTR_MAX - address) return false;
  __try { memcpy(output, reinterpret_cast<const void*>(address), bytes); return true; }
  __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

const uint8_t* CopyCmvsRawBlock(CmvsRawFrame* frame, uint64_t address, uint32_t bytes) {
  if (!address || !bytes) return nullptr;
  for (uint32_t i = 0; i < frame->count; ++i) {
    const auto& block = frame->blocks[i];
    if (block.address == address && block.bytes >= bytes)
      return frame->payload.data() + block.offset;
  }
  if (frame->count == frame->blocks.size() || bytes > frame->payload.size() - frame->used)
    return nullptr;
  auto* destination = frame->payload.data() + frame->used;
  if (!CopyCmvsRawBytes(address, destination, bytes)) return nullptr;
  frame->blocks[frame->count++] = {address, frame->used, bytes};
  frame->used += bytes;
  return destination;
}

uint64_t CmvsRawPointer(const uint8_t* bytes, size_t offset) {
  uint64_t value = 0; memcpy(&value, bytes + offset, sizeof(value)); return value;
}

// Fixed byte copies and bounded pointer traversal only: no decoding,
// projection, heap allocation, file/IPC access or waiting on the worker.
bool CopyCmvsFrameGraph(CmvsRawFrame* frame, uint64_t root) {
  const auto* root_bytes = CopyCmvsRawBlock(frame, root, 0x1080);
  if (!root_bytes) return false;
  const auto* renderer = CopyCmvsRawBlock(frame, CmvsRawPointer(root_bytes, 0x7b0), 16);
  if (!renderer) return false;
  const auto* manager = CopyCmvsRawBlock(frame, CmvsRawPointer(renderer, 0), 0x128);
  if (!manager || !CopyCmvsRawBlock(frame, CmvsRawPointer(renderer, 8), 0xd0)) return false;
  const uint64_t post = CmvsRawPointer(manager, 0x120);
  if (post && !CopyCmvsRawBlock(frame, post, 12)) return false;
  size_t nodes = 0, children = 0;
  for (size_t slot = 0; slot < cmvs_lookup::kSlotCount; ++slot) {
    const uint64_t owner_address = CmvsRawPointer(root_bytes, 0x1020 + slot * 8);
    if (!owner_address) continue;
    const auto* owner = CopyCmvsRawBlock(frame, owner_address, 0x180);
    if (!owner) return false;
    uint64_t node = CmvsRawPointer(owner, 0xa8);
    if (!node) continue;
    while (node) {
      if (++nodes > cmvs_lookup::kMaxGlyphs) return false;
      const auto* bytes = CopyCmvsRawBlock(frame, node, 0x48);
      if (!bytes) return false;
      node = CmvsRawPointer(bytes, 0);
    }
    const auto* parent = CopyCmvsRawBlock(frame, CmvsRawPointer(owner, 0), 0x1880);
    if (!parent || !CopyCmvsRawBlock(frame, CmvsRawPointer(parent, 0x1830), 0x70)) return false;
    uint64_t item = CmvsRawPointer(parent, 0x1808);
    while (item) {
      if (++children > cmvs_lookup::kMaxGlyphs) return false;
      const auto* link = CopyCmvsRawBlock(frame, item, 0x18);
      if (!link) return false;
      const auto* sprite = CopyCmvsRawBlock(frame, CmvsRawPointer(link, 0x10), 0x1880);
      if (!sprite || !CopyCmvsRawBlock(frame, CmvsRawPointer(sprite, 0x1830), 0x70)) return false;
      item = CmvsRawPointer(link, 0);
    }
  }
  return true;
}

bool ReadCmvsCapturedMemory(void* context, uint64_t address, void* output, size_t bytes) {
  const auto& frame = *static_cast<const CmvsRawFrame*>(context);
  for (uint32_t i = 0; i < frame.count; ++i) {
    const auto& block = frame.blocks[i];
    if (address >= block.address && address - block.address <= block.bytes &&
        bytes <= block.bytes - (address - block.address)) {
      memcpy(output, frame.payload.data() + block.offset + (address - block.address), bytes);
      return true;
    }
  }
  return false;
}

struct CmvsRawReadScope {
  CmvsRawReadScope() { AcquireSRWLockShared(&g_cmvs_raw_lock); }
  ~CmvsRawReadScope() { ReleaseSRWLockShared(&g_cmvs_raw_lock); }
};

void __fastcall CmvsFrameDetour(void* root) {
  if (g_cmvs_frame_original) g_cmvs_frame_original(root);
  if (g_stop) return;
  // Invalidate the previous capture even if the worker currently owns the
  // buffer. A full queue can drop geometry, but never keep old text clickable.
  const uint64_t sequence = g_cmvs_frame_sequence.fetch_add(1, std::memory_order_acq_rel) + 1;
  if (!TryAcquireSRWLockExclusive(&g_cmvs_raw_lock)) return;
  auto& frame = g_cmvs_raw_frame;
  frame.valid = false; frame.count = 0; frame.used = 0;
  frame.root = reinterpret_cast<uintptr_t>(root); frame.sequence = sequence;
  frame.tick = GetTickCount64();
  frame.valid = CopyCmvsFrameGraph(&frame, frame.root);
  ReleaseSRWLockExclusive(&g_cmvs_raw_lock);
}

bool InstallCmvsLookup() {
  if (!g_cmvs_identity_checked) {
    g_cmvs_identity_matched = cmvs_lookup::MatchesExecutable();
    g_cmvs_identity_checked = true;
  }
  if (!g_cmvs_identity_matched) return false;
#ifdef _WIN64
  const uintptr_t base = reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr));
  return g_cmvs_hook_installation.Install(HookFn,
                reinterpret_cast<void*>(base + 0xd400),
                reinterpret_cast<void*>(&CmvsFrameDetour),
                reinterpret_cast<void**>(&g_cmvs_frame_original));
#else
  return false;
#endif
}

bool ReadCmvsSelectedText(std::wstring* line, uint64_t* event,
                          uint64_t* selected_thread) {
  return fushi_voice_hook::ReadSelectedLookupText(g_header, line, event,
      selected_thread, cmvs_lookup::kMaxGlyphs);
}

struct CmvsDpiScope {
  DPI_AWARENESS_CONTEXT previous = SetThreadDpiAwarenessContext(
      DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  ~CmvsDpiScope() { if (previous) SetThreadDpiAwarenessContext(previous); }
};

void RetireCmvsLookup() {
  if (g_header) fushi_voice_hook::g_geometry_provider_registry.Retire(
      g_header, fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
      fushi_voice_hook::kLookupGeometryProviderIdCmvs);
  ClearLookupHoverHighlight();
}

void ProcessCmvsLookupTick() {
  if (!g_cmvs_identity_matched || !g_cmvs_hook_installation.enabled()) return;
  const bool shift = (GetAsyncKeyState(VK_SHIFT) & 0x8000) != 0;
  const bool submit = shift && !g_cmvs_shift_down;
  g_cmvs_shift_down = shift;
  if (g_stop || !g_header || !fushi_voice_hook::HasLookupRegion(g_header) ||
      !g_header->lookup_enabled) { RetireCmvsLookup(); return; }
  CmvsRawReadScope captured_lock;
  auto* memory = &g_cmvs_raw_frame;
  const uint64_t frame = memory->sequence;
  const uint64_t root = memory->root;
  const uint64_t tick = memory->tick;
  const uint64_t now = GetTickCount64();
  if (!memory->valid || !root || !frame || !tick || now < tick || now - tick > 100 ||
      frame != g_cmvs_frame_sequence.load(std::memory_order_acquire)) {
    RetireCmvsLookup(); return;
  }
  uint64_t window = 0;
  if (!ReadCmvsCapturedMemory(memory, root + 8, &window, sizeof(window))) {
    RetireCmvsLookup(); return;
  }
  const HWND game = reinterpret_cast<HWND>(window);
  DWORD process = 0;
  GetWindowThreadProcessId(game, &process);
  CmvsDpiScope dpi;
  RECT client{};
  if (!dpi.previous || process != GetCurrentProcessId() || !IsWindowVisible(game) ||
      IsIconic(game) || !GetClientRect(game, &client)) { RetireCmvsLookup(); return; }
  const uint64_t base = reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr));
  cmvs_lookup::Presentation presentation;
  if (cmvs_lookup::CapturePresentation(ReadCmvsCapturedMemory, memory, base, root,
      client.right, client.bottom, &presentation) != cmvs_lookup::Result::kCaptured) {
    RetireCmvsLookup(); return;
  }
  std::wstring text;
  uint64_t event = 0, thread = 0;
  if (!ReadCmvsSelectedText(&text, &event, &thread)) { RetireCmvsLookup(); return; }
  cmvs_lookup::Snapshot chosen;
  cmvs_lookup::TextIdentity identity;
  std::array<cmvs_lookup::PixelRect, cmvs_lookup::kMaxGlyphs> quads{};
  size_t matches = 0;
  for (size_t slot = 0; slot < cmvs_lookup::kSlotCount; ++slot) {
    cmvs_lookup::Snapshot candidate;
    cmvs_lookup::TextIdentity mapping;
    if (cmvs_lookup::Capture(ReadCmvsCapturedMemory, memory, base, root, slot, &candidate) !=
        cmvs_lookup::Result::kCaptured ||
        !cmvs_lookup::ResolveSelectedText(candidate, text.data(), text.size(), &mapping)) continue;
    std::array<cmvs_lookup::PixelRect, cmvs_lookup::kMaxGlyphs> projected{};
    if (cmvs_lookup::CaptureQuads(ReadCmvsCapturedMemory, memory, candidate, presentation,
                                 &projected) != cmvs_lookup::Result::kCaptured) continue;
    ++matches;
    chosen = candidate; identity = mapping; quads = projected;
  }
  if (matches != 1 || g_cmvs_frame_sequence.load(std::memory_order_acquire) != frame ||
      fushi_voice_hook::AtomicLoadPreview64(&g_header->selected_text_thread_id) != thread) {
    RetireCmvsLookup(); return;
  }
  fushi_voice_hook::g_geometry_provider_registry.OfferReady(g_header,
      fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
      fushi_voice_hook::kLookupGeometryProviderIdCmvs);
  POINT cursor{}, origin{};
  if (GetForegroundWindow() != game || !GetCursorPos(&cursor) ||
      !ClientToScreen(game, &origin) || IsLookupOverlayInputShieldVisible()) {
    ClearLookupHoverHighlight(); return;
  }
  const HWND under = WindowFromPoint(cursor);
  if (under != game && !IsChild(game, under)) { ClearLookupHoverHighlight(); return; }
  cursor.x -= origin.x; cursor.y -= origin.y;
  size_t hit = chosen.count;
  for (size_t i = 0; i < chosen.count; ++i) {
    const auto& rect = quads[i];
    if (identity.source_indices[i] == cmvs_lookup::kNoSourceIndex ||
        cursor.x < rect.x || cursor.y < rect.y || cursor.x >= rect.x + rect.width ||
        cursor.y >= rect.y + rect.height) continue;
    if (hit != chosen.count) { ClearLookupHoverHighlight(); return; }
    hit = i;
  }
  if (hit == chosen.count) { ClearLookupHoverHighlight(); return; }
  const auto& rect = quads[hit];
  RequestLookupHoverHighlight(origin.x + rect.x, origin.y + rect.y, rect.width, rect.height);
  if (!submit) return;
  char utf8[fushi_voice_hook::kLookupLineBytes]{};
  const int bytes = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(),
      static_cast<int>(text.size()), utf8, sizeof(utf8), nullptr, nullptr);
  if (bytes <= 0) return;
  fushi_voice_hook::LookupGeometryHitPublication publication;
  publication.provider_kind = fushi_voice_hook::kLookupGeometryProviderEngineExactLayout;
  publication.provider_id = fushi_voice_hook::kLookupGeometryProviderIdCmvs;
  publication.char_index = identity.source_indices[hit];
  publication.source_length = 1;
  publication.char_count = static_cast<uint32_t>(text.size());
  publication.coordinate_space = fushi_voice_hook::kLookupCoordinateSpaceClientPhysicalPixels;
  publication.writing_mode = fushi_voice_hook::kLookupWritingModeHorizontal;
  publication.text_generation = event;
  publication.geometry_generation = frame;
  publication.glyph_x = rect.x; publication.glyph_y = rect.y;
  publication.glyph_w = rect.width; publication.glyph_h = rect.height;
  publication.view_w = client.right; publication.view_h = client.bottom;
  publication.line_utf8 = reinterpret_cast<const uint8_t*>(utf8);
  publication.line_bytes = bytes;
  std::wstring current_text;
  uint64_t current_event = 0, current_thread = 0;
  RECT current_client{};
  if (g_cmvs_frame_sequence.load(std::memory_order_acquire) != frame ||
      !GetClientRect(game, &current_client) ||
      current_client.right != client.right || current_client.bottom != client.bottom ||
      !ReadCmvsSelectedText(&current_text, &current_event, &current_thread) ||
      current_event != event || current_thread != thread || current_text != text) return;
  fushi_voice_hook::g_geometry_provider_registry.PublishHit(g_header, publication);
}
