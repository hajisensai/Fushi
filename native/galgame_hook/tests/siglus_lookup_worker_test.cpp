#ifdef NDEBUG
#undef NDEBUG
#endif
#include "../hook/adapters/siglus_lookup.h"
#include "../hook/geometry_provider_registry.h"
#include <Windows.h>
#include <atomic>
#include <cassert>
#include <cstring>
#include <cstdio>
#include <vector>

namespace {
using namespace fushi_voice_hook;
#include "../hook/adapters/siglus_lookup_worker_types.inc"
SharedHeader* g_header = nullptr;
SiglusLookupGlyphEvent g_siglus_lookup_glyph_events[kSiglusLookupGlyphEventSlots];
volatile LONG64 g_siglus_lookup_glyph_event_count = 0;
uint64_t g_siglus_lookup_glyph_processed_seq = 0;
SiglusLookupGlyphCaptureBuffer g_siglus_lookup_glyph_captures;
SiglusLookupTextSnapshot g_siglus_lookup_text_snapshots[kSiglusLookupTextSlots];
volatile LONG64 g_siglus_lookup_text_count = 0;
uint64_t g_siglus_lookup_text_processed_seq = 0;
wchar_t g_siglus_lookup_active_line[kSiglusLookupMaxTextUnits];
uint32_t g_siglus_lookup_active_line_units = 0;
SiglusLookupTextIdentity g_siglus_lookup_text_identity;
SiglusLookupLayoutState g_siglus_lookup_layout;
HWND g_siglus_lookup_layout_window = nullptr;
SiglusLookupClickEvent g_siglus_lookup_click_events[kSiglusLookupClickEventSlots];
volatile LONG64 g_siglus_lookup_click_event_count = 0;
uint64_t g_siglus_lookup_click_processed_seq = 0;
uint64_t g_siglus_lookup_last_hit_identity = 0;
ULONGLONG g_siglus_lookup_last_hit_tick = 0;
const HWND kWindow = reinterpret_cast<HWND>(uintptr_t{1});
std::atomic<HWND> g_siglus_sampled_input_game_window{kWindow};
HWND foreground = kWindow;
bool window_valid = true;
ULONGLONG tick = 1000;
void (*before_second_validation)() = nullptr;
SiglusLookupProfile active_profile = kAnemoiSiglusLookupProfile;
SiglusLookupEngineView active_view;
bool view_valid = true;

const SiglusLookupProfile* ActiveSiglusLookupProfile() {
  return &active_profile;
}
void ConsumeSiglusLookupLunaScenarioText() {}
void InvalidateSiglusLookupClickTarget() {}
void SetSiglusLookupDiag(uint32_t value) { g_header->lookup_diag |= value; }
bool ReadSiglusLookupEngineView(HWND, SiglusLookupEngineView* view) {
  *view = active_view;
  return view_valid;
}
SiglusLookupClientSnapshot SiglusLookupPayloadClientSnapshot(
    const SiglusLookupPayload& payload) {
  return {payload.game_window, payload.client_screen_x, payload.client_screen_y,
          payload.client_width, payload.client_height};
}
BOOL TestIsWindow(HWND window) { return window_valid && window == kWindow; }
HWND TestGetForegroundWindow() { return foreground; }
BOOL TestGetClientRect(HWND window, RECT* rect) {
  if (!TestIsWindow(window)) return FALSE;
  *rect = {0, 0, 1920, 1080};
  return TRUE;
}
BOOL TestClientToScreen(HWND window, POINT*) { return TestIsWindow(window); }
ULONGLONG TestGetTickCount64() {
  if (before_second_validation != nullptr) {
    const auto callback = before_second_validation;
    before_second_validation = nullptr;
    active_profile = kAnemoiSiglusLookupProfile;
    active_view = {};
    view_valid = true;
    callback();
  }
  return tick;
}
#define IsWindow TestIsWindow
#define GetForegroundWindow TestGetForegroundWindow
#define GetClientRect TestGetClientRect
#define ClientToScreen TestClientToScreen
#define GetTickCount64 TestGetTickCount64
#include "../hook/adapters/siglus_lookup_text_snapshot.inc"
#include "../hook/adapters/siglus_lookup_worker.inc"
#undef IsWindow
#undef GetForegroundWindow
#undef GetClientRect
#undef ClientToScreen
#undef GetTickCount64

struct Fixture {
  std::vector<uint8_t> bytes;
  Fixture() {
    bytes.resize(static_cast<size_t>(sizeof(SharedHeader) + LookupRegionBytes(
        kLookupInputSlotCount, kLookupFrameCount, kLookupBitmapBytes)));
    g_header = reinterpret_cast<SharedHeader*>(bytes.data());
    g_header->magic = kSharedMagic;
    g_header->version = kSharedVersion;
    g_header->lookup_region_offset = sizeof(SharedHeader);
    g_header->lookup_bitmap_bytes = kLookupBitmapBytes;
    g_header->lookup_frame_count = kLookupFrameCount;
    g_header->lookup_input_slot_count = kLookupInputSlotCount;
    g_header->lookup_enabled = 1;
    assert(PublishLookupGeometryAdmission(g_header, kLookupGeometryAdmissionAuto,
                                         false, true) != 0);
    g_geometry_provider_registry.Reset(g_header);
    g_siglus_lookup_glyph_event_count = 0;
    g_siglus_lookup_glyph_processed_seq = 0;
    g_siglus_lookup_glyph_captures = {};
    g_siglus_lookup_text_count = 0;
    g_siglus_lookup_text_processed_seq = 0;
    g_siglus_lookup_active_line_units = 0;
    g_siglus_lookup_text_identity = {};
    g_siglus_lookup_layout = {};
    g_siglus_lookup_click_event_count = 0;
    g_siglus_lookup_click_processed_seq = 0;
    g_siglus_lookup_waiting_click_seq = 0;
    g_siglus_lookup_waiting_glyph_seq = 0;
    g_siglus_lookup_last_hit_identity = 0;
    g_siglus_lookup_last_hit_tick = 0;
    foreground = kWindow;
    window_valid = true;
    tick = 1000;
    before_second_validation = nullptr;
    g_siglus_sampled_input_game_window = kWindow;
    for (auto& slot : g_siglus_lookup_click_events) slot = {};
    for (auto& slot : g_siglus_lookup_glyph_events) slot = {};
    for (auto& slot : g_siglus_lookup_text_snapshots) slot = {};
  }
};

void Glyph(char16_t character, int32_t x) {
  const uint64_t next = static_cast<uint64_t>(
      InterlockedIncrement64(&g_siglus_lookup_glyph_event_count));
  auto& slot = g_siglus_lookup_glyph_events[next % kSiglusLookupGlyphEventSlots];
  slot.seq = 0;
  slot.code_unit = character;
  slot.design_x = x;
  slot.design_y = 200;
  slot.extent = 40;
  InterlockedExchange64(&slot.seq, static_cast<LONG64>(next));
}
void FullRedraw() {
  Glyph(u'A', 100); Glyph(u'B', 140); Glyph(u'C', 180);
}
void Consume() {
  ConsumeSiglusLookupCaptures();
  if (g_siglus_lookup_layout.line_has_complete_layout) {
    assert(g_geometry_provider_registry.OfferReady(
        g_header, kLookupGeometryProviderEngineExactLayout,
        kLookupGeometryProviderIdSiglus));
  }
}
void Begin() {
  PublishSiglusLookupTextSnapshot(L"ABC", 3, {42, 7});
  FullRedraw();
  Consume();
  assert(g_siglus_lookup_layout.current_valid);
}
SiglusLookupPayload Press(uint32_t character = 0) {
  SiglusLookupPayload payload;
  payload.text_identity = g_siglus_lookup_text_identity;
  payload.geometry_generation = g_siglus_lookup_layout.generation;
  payload.snapshot_epoch = g_siglus_lookup_layout.snapshot_epoch;
  payload.text_units = 3;
  payload.char_index = character;
  payload.rect = g_siglus_lookup_layout.geometry.glyphs[character].rect;
  payload.engine_view = active_view;
  assert(ProjectSiglusLookupRect(active_profile, active_view, payload.rect,
                                1920, 1080, &payload.rect));
  payload.game_window = reinterpret_cast<uintptr_t>(kWindow);
  payload.client_width = 1920;
  payload.client_height = 1080;
  memcpy(payload.text, L"ABC", 3 * sizeof(wchar_t));
  return payload;
}

void TestUnreadCompleteRedrawDoesNotAcknowledgeClick() {
  Fixture fixture;
  Begin();
  QueueSiglusLookupClickSubmit(Press());
  // Exact production interleaving: tick consumes a complete layout, then the
  // renderer publishes another unchanged batch before queued up is checked.
  FullRedraw();
  assert(!ProcessSiglusLookupClickSubmissions());
  assert(g_header->lookup_hit_count == 0);
  assert(g_siglus_lookup_click_processed_seq == 0);
  Consume();
  assert(ProcessSiglusLookupClickSubmissions());
  assert(g_header->lookup_hit_count == 1);
  assert(g_siglus_lookup_click_processed_seq == 1);
  assert(LookupHitOf(g_header)->text_generation == 42);
  assert(!ProcessSiglusLookupClickSubmissions());
  assert(g_header->lookup_hit_count == 1);
}

void TestRedrawBetweenBothPublicationChecks() {
  Fixture fixture;
  Begin();
  QueueSiglusLookupClickSubmit(Press());
  before_second_validation = FullRedraw;
  assert(!ProcessSiglusLookupClickSubmissions());
  assert(g_siglus_lookup_click_processed_seq == 0);
  assert(g_siglus_lookup_waiting_glyph_seq == 6);
  Consume();
  assert(ProcessSiglusLookupClickSubmissions());
  assert(g_header->lookup_hit_count == 1);
}

void TestNoProgressAndContinuingCompleteRedraws() {
  Fixture fixture;
  Begin();
  QueueSiglusLookupClickSubmit(Press());
  FullRedraw();
  assert(!ProcessSiglusLookupClickSubmissions());
  for (int same_frontier = 0; same_frontier < 20; ++same_frontier) {
    assert(!ProcessSiglusLookupClickSubmissions());
    assert(g_siglus_lookup_waiting_glyph_seq == 6);
    assert(g_siglus_lookup_click_processed_seq == 0);
  }
  // No retry-count expiration. Every deferral depends on an actual new batch;
  // preserving the pending-glyph safety gate cannot promise delivery while
  // the producer is perpetually ahead at every validation instant.
  for (int frame = 0; frame < 100; ++frame) {
    Consume();
    FullRedraw();
    assert(!ProcessSiglusLookupClickSubmissions());
    assert(g_siglus_lookup_click_processed_seq == 0);
    assert(g_header->lookup_hit_count == 0);
  }
  Consume();
  assert(ProcessSiglusLookupClickSubmissions());
  assert(!ProcessSiglusLookupClickSubmissions());
  assert(g_header->lookup_hit_count == 1);
}

void TestPartialRedrawPermanentlyRejectsOldRelease() {
  Fixture fixture;
  Begin();
  const auto payload = Press();
  QueueSiglusLookupClickSubmit(payload);
  Glyph(u'A', 100);
  assert(!ProcessSiglusLookupClickSubmissions());
  Consume();
  assert(g_siglus_lookup_layout.snapshot_epoch != payload.snapshot_epoch);
  assert(!ProcessSiglusLookupClickSubmissions());
  assert(g_siglus_lookup_click_processed_seq == 1);
  Glyph(u'B', 140); Glyph(u'C', 180);
  Consume();
  assert(g_siglus_lookup_layout.generation == payload.geometry_generation);
  assert(!ProcessSiglusLookupClickSubmissions());
  assert(g_header->lookup_hit_count == 0);
}

void TestFirstPartialHasNoEligibleRelease() {
  Fixture fixture;
  Begin();
  const auto payload = Press();
  ResetSiglusLookupRuntimeLayout();
  Glyph(u'A', 100);
  Consume();
  QueueSiglusLookupClickSubmit(payload);
  assert(!ProcessSiglusLookupClickSubmissions());
  assert(g_siglus_lookup_click_processed_seq == 1);
  assert(!g_siglus_lookup_layout.line_has_complete_layout);
}

void TestNewOccurrenceEvenWithIdenticalTextRejects() {
  Fixture fixture;
  Begin();
  QueueSiglusLookupClickSubmit(Press());
  FullRedraw();
  assert(!ProcessSiglusLookupClickSubmissions());
  PublishSiglusLookupTextSnapshot(L"ABC", 3, {43, 7});
  Consume();
  assert(!ProcessSiglusLookupClickSubmissions());
  assert(g_siglus_lookup_click_processed_seq == 1);
  assert(g_header->lookup_hit_count == 0);
}

void TestUnreadTextRejectsWithoutWaitingForGlyphs() {
  Fixture fixture;
  Begin();
  QueueSiglusLookupClickSubmit(Press());
  FullRedraw();
  assert(!ProcessSiglusLookupClickSubmissions());
  PublishSiglusLookupTextSnapshot(L"XYZ", 3, {43, 7});
  assert(!ProcessSiglusLookupClickSubmissions());
  assert(g_siglus_lookup_click_processed_seq == 1);
}

void TestCoordinateChangeRejects() {
  Fixture fixture;
  Begin();
  QueueSiglusLookupClickSubmit(Press());
  Glyph(u'A', 300); Glyph(u'B', 340); Glyph(u'C', 380);
  assert(!ProcessSiglusLookupClickSubmissions());
  Consume();
  assert(!ProcessSiglusLookupClickSubmissions());
  assert(g_siglus_lookup_click_processed_seq == 1);
  assert(g_header->lookup_hit_count == 0);
}

void TestForegroundLossDuringWaitIsTerminal() {
  Fixture fixture;
  Begin();
  QueueSiglusLookupClickSubmit(Press());
  FullRedraw();
  assert(!ProcessSiglusLookupClickSubmissions());
  foreground = nullptr;
  assert(!ProcessSiglusLookupClickSubmissions());
  assert(g_siglus_lookup_click_processed_seq == 1);
  foreground = kWindow;
  Consume();
  assert(!ProcessSiglusLookupClickSubmissions());
  assert(g_header->lookup_hit_count == 0);
}

void TestSessionLossCancelsPendingQueue() {
  Fixture fixture;
  Begin();
  QueueSiglusLookupClickSubmit(Press());
  FullRedraw();
  assert(!ProcessSiglusLookupClickSubmissions());
  ResetSiglusLookupRuntimeLayout();
  assert(g_siglus_lookup_click_processed_seq == 1);
  assert(g_siglus_lookup_waiting_click_seq == 0);
  FullRedraw();
  Consume();
  assert(!ProcessSiglusLookupClickSubmissions());
  assert(g_header->lookup_hit_count == 0);
}

void TestGlyphRingLossInvalidatesPendingEpoch() {
  Fixture fixture;
  Begin();
  QueueSiglusLookupClickSubmit(Press());
  for (size_t i = 0; i < kSiglusLookupGlyphEventSlots + 1; ++i) Glyph(u'X', 300);
  FullRedraw();
  assert(!ProcessSiglusLookupClickSubmissions());
  Consume();
  assert(g_siglus_lookup_layout.current_valid);
  assert(!ProcessSiglusLookupClickSubmissions());
  assert(g_siglus_lookup_click_processed_seq == 1);
  assert(g_header->lookup_hit_count == 0);
}

void TestClicksStayInOrderAcrossWaitingAndOverflow() {
  Fixture fixture;
  Begin();
  QueueSiglusLookupClickSubmit(Press(0));
  FullRedraw();
  assert(!ProcessSiglusLookupClickSubmissions());
  for (uint32_t index = 1; index <= 5; ++index)
    QueueSiglusLookupClickSubmit(Press(index % 3));
  // The oldest two events were overwritten; only surviving 3..6 may publish.
  assert(!ProcessSiglusLookupClickSubmissions());
  assert(g_siglus_lookup_click_processed_seq == 2);
  Consume();
  for (uint64_t seq = 3; seq <= 6; ++seq) {
    tick += 300;
    assert(ProcessSiglusLookupClickSubmissions());
    assert(g_siglus_lookup_click_processed_seq == seq);
    assert(LookupHitOf(g_header)->char_index == (seq - 1) % 3);
  }
  assert(g_header->lookup_hit_count == 4);
  assert(!ProcessSiglusLookupClickSubmissions());
}

void TestReservedClickSlotCannotSkipToNewerEvent() {
  Fixture fixture;
  Begin();
  QueueSiglusLookupClickSubmit(Press(0));
  const auto first = g_siglus_lookup_click_events[1];
  g_siglus_lookup_click_events[1].seq = 0;
  QueueSiglusLookupClickSubmit(Press(1));
  assert(!ProcessSiglusLookupClickSubmissions());
  assert(g_siglus_lookup_click_processed_seq == 0);
  g_siglus_lookup_click_events[1] = first;
  assert(ProcessSiglusLookupClickSubmissions());
  assert(LookupHitOf(g_header)->char_index == 0);
  assert(ProcessSiglusLookupClickSubmissions());
  assert(LookupHitOf(g_header)->char_index == 1);
}

void TestRegistryRejectionIsTerminal() {
  Fixture fixture;
  Begin();
  QueueSiglusLookupClickSubmit(Press());
  g_header->lookup_enabled = 0;
  assert(!ProcessSiglusLookupClickSubmissions());
  assert(g_siglus_lookup_click_processed_seq == 1);
  g_header->lookup_enabled = 1;
  assert(!ProcessSiglusLookupClickSubmissions());
  assert(g_header->lookup_hit_count == 0);
}

void TestWindowInvalidationIsTerminal() {
  Fixture fixture;
  Begin();
  QueueSiglusLookupClickSubmit(Press());
  FullRedraw();
  assert(!ProcessSiglusLookupClickSubmissions());
  window_valid = false;
  assert(!ProcessSiglusLookupClickSubmissions());
  assert(g_siglus_lookup_click_processed_seq == 1);
}
void TestLegacyViewAndVisibilityRecheckedBeforePublish() {
  for (int changed = 0; changed < 7; ++changed) {
    Fixture fixture;
    active_profile.glyph_abi = SiglusGlyphLayoutAbi::kStackSixteenArguments;
    active_view = {0x123400, {20, 10, 1600, 900}};
    Begin();
    const auto payload = Press();
    assert(IsSiglusLookupPayloadEligible(payload));
    QueueSiglusLookupClickSubmit(payload);
    switch (changed) {
      case 0: view_valid = false; break; // menu, dead alias or invalid HWND
      case 1: ++active_view.owner; break;
      case 2: ++active_view.viewport.x; break;
      case 3: ++active_view.viewport.y; break;
      case 4: ++active_view.viewport.width; break;
      case 5: ++active_view.viewport.height; break;
      case 6: before_second_validation = [] { view_valid = false; }; break;
    }
    assert(!ProcessSiglusLookupClickSubmissions());
    assert(g_header->lookup_hit_count == 0 && g_siglus_lookup_click_processed_seq == 1);
    active_view = payload.engine_view;
    view_valid = true;
    assert(!ProcessSiglusLookupClickSubmissions()); // old release stays retired
  }
  Fixture fixture;
  active_profile.glyph_abi = SiglusGlyphLayoutAbi::kStackSixteenArguments;
  active_view = {0x123400, {20, 10, 1600, 900}};
  Begin();
  QueueSiglusLookupClickSubmit(Press());
  assert(ProcessSiglusLookupClickSubmissions() && g_header->lookup_hit_count == 1);
}
}  // namespace

int main() {
  TestUnreadCompleteRedrawDoesNotAcknowledgeClick();
  TestRedrawBetweenBothPublicationChecks();
  TestNoProgressAndContinuingCompleteRedraws();
  TestPartialRedrawPermanentlyRejectsOldRelease();
  TestFirstPartialHasNoEligibleRelease();
  TestNewOccurrenceEvenWithIdenticalTextRejects();
  TestUnreadTextRejectsWithoutWaitingForGlyphs();
  TestCoordinateChangeRejects();
  TestForegroundLossDuringWaitIsTerminal();
  TestSessionLossCancelsPendingQueue();
  TestGlyphRingLossInvalidatesPendingEpoch();
  TestClicksStayInOrderAcrossWaitingAndOverflow();
  TestReservedClickSlotCannotSkipToNewerEvent();
  TestRegistryRejectionIsTerminal();
  TestWindowInvalidationIsTerminal();
  TestLegacyViewAndVisibilityRecheckedBeforePublish();
  std::puts("siglus_lookup_worker_test: 16 scenarios passed");
}
