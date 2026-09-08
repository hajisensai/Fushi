#ifdef NDEBUG
#undef NDEBUG
#endif
#define NOMINMAX
#include <windows.h>
#include <windowsx.h>
#include <atomic>
#include <cassert>
#include <cstdio>
#include <cstring>
#include <thread>
#include <vector>
#include "../hook/adapters/siglus_lookup.h"
#include "../hook/geometry_provider_registry.h"

namespace {
using namespace fushi_voice_hook;
#include "../hook/adapters/siglus_lookup_worker_types.inc"
SharedHeader* g_header = nullptr;
bool g_capture_enabled = true;
std::atomic<bool> g_siglus_lookup_click_runtime_enabled{true};
std::atomic<bool> g_siglus_lookup_left_button_filter_latched{false};
std::atomic<bool> g_siglus_lookup_message_left_button_latched{false};
std::atomic<uint32_t> g_siglus_lookup_click_epoch{1};
uint32_t g_siglus_lookup_click_observed_epoch = 1;
SiglusLookupClickSampleState g_siglus_lookup_click_sample_state;
SiglusLookupPayload g_siglus_lookup_pending_click;
bool g_siglus_lookup_pending_click_valid = false;
SiglusLookupClickTarget g_siglus_lookup_click_target;
SiglusLookupClickTarget g_siglus_lookup_click_read_target;
const HWND test_game = reinterpret_cast<HWND>(uintptr_t{1});
const HWND other = reinterpret_cast<HWND>(uintptr_t{2});
std::atomic<HWND> g_siglus_sampled_input_game_window{test_game};
SiglusLookupProfile test_profile = kAnemoiSiglusLookupProfile;
bool profile_valid = true, view_valid = true, popup = false;
bool window_valid = true, cursor_valid = true, client_valid = true;
bool copy_race = false;
void (*on_memcpy)(void*, size_t) = nullptr;
HWND foreground = test_game, test_point_window = test_game;
POINT cursor = {110, 210}, test_origin = {0, 0};
RECT test_client = {0, 0, 1920, 1080};
ULONGLONG tick = 1000;
SiglusLookupEngineView view;
int queue_calls = 0, view_reads = 0;
SiglusLookupPayload test_queued;
const SiglusLookupProfile* ActiveSiglusLookupProfile() { return profile_valid ? &test_profile : nullptr; }
HWND GetValidPublishedSiglusSampledInputShieldPopup(HWND) { return nullptr; }
bool IsSiglusSampledInputShieldReadyPublished(HWND) { return false; }
bool IsLookupOverlayInputShieldVisible() { return popup; }
HWND FindGameMainWindow() { return test_game; }
void SetSiglusLookupDiag(uint32_t) {}
void RequestLookupOverlayOutsideDismiss() {}
bool ReadSiglusLookupEngineView(HWND, SiglusLookupEngineView* result) {
  ++view_reads;
  *result = view;
  return view_valid;
}
bool SiglusLookupViewAllowsInput(HWND window) {
  SiglusLookupEngineView result;
  return ReadSiglusLookupEngineView(window, &result);
}
void QueueSiglusLookupClickSubmit(const SiglusLookupPayload& value) {
  ++queue_calls; test_queued = value;
}
HMODULE TestGetModuleHandleW(LPCWSTR) { return reinterpret_cast<HMODULE>(uintptr_t{0x400000}); }
BOOL TestIsWindow(HWND window) { return window_valid && window == test_game; }
HWND TestGetForegroundWindow() { return foreground; }
HWND TestWindowFromPoint(POINT) { return test_point_window; }
BOOL TestIsChild(HWND, HWND) { return FALSE; }
BOOL TestGetClientRect(HWND, RECT* value) { *value = test_client; return client_valid; }
BOOL TestClientToScreen(HWND, POINT* value) {
  value->x += test_origin.x; value->y += test_origin.y; return client_valid;
}
BOOL TestGetCursorPos(POINT* value) { *value = cursor; return cursor_valid; }
ULONGLONG TestGetTickCount64() { return tick; }
void* TestMemcpy(void* dest, const void* source, size_t size) {
  if (on_memcpy != nullptr) on_memcpy(dest, size);
  void* result = std::memcpy(dest, source, size);
  if (copy_race && source == &g_siglus_lookup_click_target)
    InterlockedIncrement64(&g_siglus_lookup_click_target.seq);
  return result;
}
#define GetModuleHandleW TestGetModuleHandleW
#define IsWindow TestIsWindow
#define GetForegroundWindow TestGetForegroundWindow
#define WindowFromPoint TestWindowFromPoint
#define IsChild TestIsChild
#define GetClientRect TestGetClientRect
#define ClientToScreen TestClientToScreen
#define GetCursorPos TestGetCursorPos
#define GetTickCount64 TestGetTickCount64
#define memcpy TestMemcpy
#include "../hook/adapters/siglus_lookup_input_diagnostics.inc"
#include "../hook/adapters/siglus_lookup_click_target.inc"
#include "../hook/adapters/siglus_lookup_click_policy.inc"
#undef GetModuleHandleW
#undef IsWindow
#undef GetForegroundWindow
#undef WindowFromPoint
#undef IsChild
#undef GetClientRect
#undef ClientToScreen
#undef GetCursorPos
#undef GetTickCount64
#undef memcpy

struct Fixture {
  std::vector<uint8_t> bytes;
  Fixture() {
    bytes.resize(static_cast<size_t>(sizeof(SharedHeader) + LookupRegionBytes(
        kLookupInputSlotCount, kLookupFrameCount, kLookupBitmapBytes)));
    g_header = reinterpret_cast<SharedHeader*>(bytes.data());
    g_header->magic = kSharedMagic; g_header->version = kSharedVersion;
    g_header->lookup_region_offset = sizeof(SharedHeader);
    g_header->lookup_bitmap_bytes = kLookupBitmapBytes;
    g_header->lookup_frame_count = kLookupFrameCount;
    g_header->lookup_input_slot_count = kLookupInputSlotCount;
    g_header->lookup_enabled = 1;
    assert(PublishLookupGeometryAdmission(g_header, kLookupGeometryAdmissionAuto, false, true));
    g_geometry_provider_registry.Reset(g_header);
    assert(g_geometry_provider_registry.OfferReady(g_header,
        kLookupGeometryProviderEngineExactLayout, kLookupGeometryProviderIdSiglus));
    test_profile = kAnemoiSiglusLookupProfile;
    test_profile.get_key_state_return_rva = 100;
    test_profile.get_keyboard_state_return_rva = 200;
    test_profile.main_input_message_return_rva = 300;
    profile_valid = view_valid = window_valid = cursor_valid = client_valid = true;
    popup = copy_race = false;
    on_memcpy = nullptr;
    foreground = test_point_window = test_game;
    cursor = {110, 210}; test_origin = {0, 0}; test_client = {0, 0, 1920, 1080};
    tick = 1000; view = {}; queue_calls = view_reads = 0;
    g_capture_enabled = true;
    g_siglus_lookup_click_runtime_enabled = true;
    g_siglus_lookup_left_button_filter_latched = false;
    g_siglus_lookup_message_left_button_latched = false;
    g_siglus_lookup_click_epoch = g_siglus_lookup_click_observed_epoch = 1;
    g_siglus_lookup_click_sample_state = {true, SiglusLookupClickOwner::kIdle, kSiglusLookupNoGlyph};
    g_siglus_lookup_pending_click = {}; g_siglus_lookup_pending_click_valid = false;
    g_siglus_lookup_diagnostic_button_down[0] = g_siglus_lookup_diagnostic_button_down[1] = false;
    g_siglus_lookup_diagnostic_epoch[0] = g_siglus_lookup_diagnostic_epoch[1] = 0;
    g_siglus_lookup_press_diagnostic_count = g_siglus_lookup_press_diagnostic_dropped = 0;
    g_siglus_lookup_click_target = {};
    auto& target = g_siglus_lookup_click_target;
    target.seq = 7; target.valid = 1; target.text_identity = {42, 9};
    target.published_tick = tick; target.game_window = reinterpret_cast<uintptr_t>(test_game);
    target.client_width = 1920; target.client_height = 1080;
    target.geometry_generation = 3; target.snapshot_epoch = 5;
    target.text_units = 1; target.text[0] = L'A';
    target.geometry.glyph_count = 1; target.geometry.viewport_width = 1920;
    target.geometry.viewport_height = 1080;
    target.geometry.glyphs[0] = {u'A', 0, 0, {100, 200, 40, 40}};
  }
};
SHORT Sample(bool down, bool keyboard = false) {
  return FilterSiglusLookupLeftButtonSample(static_cast<SHORT>(down ? 0x8001 : 1),
      0x400000 + (keyboard ? 200 : 100), keyboard);
}
SiglusLookupPressReason LastReason() {
  const auto count = static_cast<uint64_t>(g_siglus_lookup_press_diagnostic_count);
  assert(count != 0);
  const auto& value = g_siglus_lookup_press_diagnostics[count % 8];
  assert(static_cast<uint64_t>(value.seq) == count);
  return value.reason;
}
void TestActualDownRejections() {
  using R = SiglusLookupPressReason;
  const R reasons[] = {R::kRuntimeDisabled, R::kLiveViewRejected,
      R::kNativeAdmissionRejected, R::kCursorUnavailable, R::kTargetUnpublished,
      R::kTargetChanged, R::kTargetInvalid, R::kTargetIdentity, R::kTargetTextUnits,
      R::kTargetGlyphCount, R::kTargetGeneration, R::kTargetEpoch,
      R::kTargetTimestamp, R::kTargetExpired, R::kForegroundMismatch,
      R::kPointWindowMismatch, R::kClientUnavailable, R::kClientChanged,
      R::kEngineViewChanged, R::kNoProjectedGlyph, R::kPointMiss, R::kCharacterIndex};
  for (int surface = 0; surface < 3; ++surface) {
   for (size_t which = 0; which < std::size(reasons); ++which) {
    if (surface == 2 && which == 3) continue; // WM uses lparam, not GetCursorPos.
    Fixture f;
    auto& target = g_siglus_lookup_click_target;
    switch(which) {
      case 0: g_siglus_lookup_click_runtime_enabled = false; break;
      case 1: view_valid = false; break;
      case 2: g_header->lookup_geometry_admission_request_seq |= kLookupGeometryAdmissionWriteInProgress; break;
      case 3: cursor_valid = false; break;
      case 4: target.seq = 0; break;
      case 5: copy_race = true; break;
      case 6: target.valid = 0; break;
      case 7: target.text_identity.event_id = 0; break;
      case 8: target.text_units = 0; break;
      case 9: target.geometry.glyph_count = 0; break;
      case 10: target.geometry_generation = 0; break;
      case 11: target.snapshot_epoch = 0; break;
      case 12: target.published_tick = tick + 1; break;
      case 13: target.published_tick = tick - 65; break;
      case 14: foreground = other; break;
      case 15: test_point_window = other; break;
      case 16: client_valid = false; break;
      case 17: test_origin.x = 1; break;
      case 18: target.engine_view.owner = 2; break;
      case 19: target.geometry.glyphs[0].rect.width = 0; break;
      case 20: cursor.x = 10; break;
      case 21: target.geometry.glyphs[0].char_index = 1; break;
    }
    if (surface == 2) {
      assert(!ConsumeSiglusLookupInputMessage(WM_LBUTTONDOWN,
          MAKELPARAM(cursor.x, cursor.y), 0x400000 + 300));
    } else {
      assert(static_cast<uint16_t>(Sample(true, surface == 1)) == 0x8001);
    }
    if (LastReason() != reasons[which]) {
      std::printf("rejection case %zu got %u expected %u\n", which,
          static_cast<unsigned>(LastReason()), static_cast<unsigned>(reasons[which]));
      std::abort();
    }
    assert(view_reads == (which == 0 ? 0 : which >= 18 ? 2 : 1));
    if (surface == 2) {
      assert(!ConsumeSiglusLookupInputMessage(WM_LBUTTONUP,
          MAKELPARAM(cursor.x, cursor.y), 0x400000 + 300));
    } else {
      for (int i = 0; i < 100; ++i) Sample(true, surface == 1);
      Sample(false, surface == 1);
    }
    assert(queue_calls == 0 && g_siglus_lookup_press_diagnostic_count == 1);
    if (which == 5) {
      assert((g_siglus_lookup_press_diagnostics[1].flags & 64u) == 0);
      assert(g_siglus_lookup_press_diagnostics[1].event_id == 0);
    }
   }
  }
}
void TestSuccessAndEpochReleaseRejection() {
  for (bool change_epoch : {false, true}) {
    Fixture f;
    assert(Sample(true) == 1 && LastReason() == SiglusLookupPressReason::kLookupOwned);
    const auto& record = g_siglus_lookup_press_diagnostics[1];
    assert(record.event_id == 42 && record.geometry_generation == 3 && record.snapshot_epoch == 5);
    if (change_epoch) ++g_siglus_lookup_click_target.snapshot_epoch;
    assert(Sample(false) == 1);
    assert(queue_calls == (change_epoch ? 0 : 1));
    assert(g_siglus_lookup_press_diagnostic_count == (change_epoch ? 2 : 1));
    if (change_epoch) {
      assert(LastReason() == SiglusLookupPressReason::kPendingEpoch);
      const auto& completion = g_siglus_lookup_press_diagnostics[2];
      assert(completion.pending_event_id == 42 && completion.event_id == 42);
      assert(completion.pending_snapshot_epoch == 5 && completion.snapshot_epoch == 6);
    }
    if (!change_epoch) assert(test_queued.text_identity.event_id == 42);
  }
}
void TestUnsynchronizedAndMissOwnership() {
  Fixture f;
  g_siglus_lookup_click_epoch = 2;
  assert(static_cast<uint16_t>(Sample(true)) == 0x8001);
  assert(LastReason() == SiglusLookupPressReason::kUnsynchronized);
  assert(g_siglus_lookup_press_diagnostics[1].sample_epoch == 2 &&
         g_siglus_lookup_press_diagnostics[1].previous_sample_epoch == 1);
  for (int i = 0; i < 100; ++i) Sample(true);
  assert(g_siglus_lookup_press_diagnostic_count == 1);
  Sample(false);
  g_siglus_lookup_click_target.valid = 0;
  Sample(true);
  assert(LastReason() == SiglusLookupPressReason::kTargetInvalid);
  g_siglus_lookup_click_target.valid = 1;
  assert(static_cast<uint16_t>(Sample(true)) == 0x8001);
  Sample(false);
  assert(queue_calls == 0);
  assert(Sample(true) == 1);
  Sample(false); assert(queue_calls == 1);
}
void TestMessageAndSurfaceBoundaries() {
  Fixture f;
  const LPARAM point = MAKELPARAM(110, 210);
  assert(!ConsumeSiglusLookupInputMessage(WM_LBUTTONDOWN, point, 0x400301));
  assert(g_siglus_lookup_press_diagnostic_count == 0);
  assert(ConsumeSiglusLookupInputMessage(WM_LBUTTONDOWN, point, 0x400000 + 300));
  assert(LastReason() == SiglusLookupPressReason::kLookupOwned);
  assert(g_siglus_lookup_press_diagnostics[1].surface == SiglusLookupPressSurface::kEngineMessage);
  assert(ConsumeSiglusLookupInputMessage(WM_LBUTTONUP, point, 0x400000 + 300));
  assert(queue_calls == 0 && g_siglus_lookup_press_diagnostic_count == 1);
  Sample(true); Sample(true, true);
  assert(g_siglus_lookup_press_diagnostic_count == 3);
  assert(g_siglus_lookup_press_diagnostics[2].surface == SiglusLookupPressSurface::kKeyState);
  assert(g_siglus_lookup_press_diagnostics[3].surface == SiglusLookupPressSurface::kKeyboardState);
  Sample(false); Sample(false, true); assert(queue_calls == 1);
  popup = true;
  assert(ConsumeSiglusLookupInputMessage(WM_LBUTTONDBLCLK, point, 0x400000 + 300));
  assert(LastReason() == SiglusLookupPressReason::kPopupOwned);
}
void TestDiagnosticLifecycleAndThreadIsolation() {
  for (bool advance_epoch : {false, true}) {
    Fixture f;
    Sample(true);
    assert(g_siglus_lookup_press_diagnostic_count == 1);
    g_capture_enabled = false;
    Sample(false); // Original policy early-return deliberately leaves sample state.
    g_capture_enabled = true;
    if (advance_epoch) ++g_siglus_lookup_click_epoch;
    Sample(true);
    assert(g_siglus_lookup_press_diagnostic_count == 2);
    assert(LastReason() == (advance_epoch ? SiglusLookupPressReason::kUnsynchronized
                                         : SiglusLookupPressReason::kExistingTransaction));
    for (int hold = 0; hold < 100; ++hold) Sample(true);
    assert(g_siglus_lookup_press_diagnostic_count == 2);
  }
  Fixture f;
  assert(ObserveSiglusLookupDiagnosticDown(true, false, 1));
  std::atomic<int> edges{0};
  auto lane = [&edges] {
    if (ObserveSiglusLookupDiagnosticDown(true, false, 1)) ++edges;
    assert(!ObserveSiglusLookupDiagnosticDown(true, false, 1));
    if (ObserveSiglusLookupDiagnosticDown(true, false, 2)) ++edges;
    assert(!ObserveSiglusLookupDiagnosticDown(true, false, 2));
  };
  std::thread a(lane), b(lane); a.join(); b.join();
  assert(edges == 4);
  assert(!ObserveSiglusLookupDiagnosticDown(true, false, 1));
}
void TestOwnedUpFailures() {
  using R = SiglusLookupPressReason;
  const R expected[] = {R::kPendingUnavailable, R::kNativeAdmissionRejected,
      R::kLiveViewRejected, R::kTargetInvalid, R::kPendingTextIdentity,
      R::kPendingGeneration, R::kPendingClient, R::kSampleEpochReset};
  for (size_t which = 0; which < std::size(expected); ++which) {
    Fixture f;
    Sample(true);
    auto& target = g_siglus_lookup_click_target;
    switch(which) {
      case 0: g_siglus_lookup_pending_click_valid = false; break;
      case 1: g_header->lookup_geometry_admission_request_seq |= kLookupGeometryAdmissionWriteInProgress; break;
      case 2: view_valid = false; break;
      case 3: target.valid = 0; break;
      case 4: ++target.text_identity.event_id; break;
      case 5: ++target.geometry_generation; break;
      case 6: ++target.client_width; break;
      case 7: ++g_siglus_lookup_click_epoch; break;
    }
    Sample(false);
    assert(queue_calls == 0 && g_siglus_lookup_press_diagnostic_count == 2);
    assert(LastReason() == expected[which]);
    assert(g_siglus_lookup_press_diagnostics[2].surface == SiglusLookupPressSurface::kKeyStateCompletion);
    Sample(false); // Idle up never creates another completion.
    assert(g_siglus_lookup_press_diagnostic_count == 2);
  }
}
bool ReadDiagnosticRecord(uint64_t seq, SiglusLookupPressDiagnostic* result) {
  const auto* source = const_cast<const SiglusLookupPressDiagnostic*>(
      &g_siglus_lookup_press_diagnostics[seq % 8]);
  auto read = [](const void* from, void* to, size_t size) {
    SIZE_T got = 0;
    return ReadProcessMemory(GetCurrentProcess(), from, to, size, &got) && got == size;
  };
  uint64_t before = 0, after = 0;
  return read(source, &before, 8) && read(source, result, sizeof(*result)) &&
      read(source, &after, 8) && before == seq && after == seq &&
      static_cast<uint64_t>(result->seq) == seq && seq != 0;
}
void TestConcurrentReadPublication() {
  Fixture f;
  static std::atomic<bool> entered{false}, release{false};
  entered = false; release = false;
  on_memcpy = [](void*, size_t) {
    entered.store(true, std::memory_order_release);
    for (int wait = 0; wait < 1000000 && !release.load(std::memory_order_acquire); ++wait)
      std::this_thread::yield();
    assert(release.load(std::memory_order_acquire));
  };
  std::thread producer([] {
    SiglusLookupPressDiagnostic d;
    d.event_id = d.thread_id = d.geometry_generation = d.snapshot_epoch = 42;
    RecordSiglusLookupPressDiagnostic(d);
  });
  for (int wait = 0; wait < 1000000 && !entered.load(std::memory_order_acquire); ++wait)
    std::this_thread::yield();
  assert(entered.load(std::memory_order_acquire));
  SiglusLookupPressDiagnostic result;
  for (int read = 0; read < 16; ++read) assert(!ReadDiagnosticRecord(1, &result));
  assert(g_siglus_lookup_press_diagnostic_count == 0);
  release.store(true, std::memory_order_release); producer.join(); on_memcpy = nullptr;
  assert(ReadDiagnosticRecord(1, &result) && result.event_id == 42);
}
void TestBoundedPublicationAndContention() {
  Fixture f;
  AcquireSRWLockExclusive(&g_siglus_lookup_press_diagnostic_lock);
  assert(Sample(true) == 1); // Diagnostic contention must not revoke ownership.
  ReleaseSRWLockExclusive(&g_siglus_lookup_press_diagnostic_lock);
  assert(g_siglus_lookup_press_diagnostic_count == 0 && g_siglus_lookup_press_diagnostic_dropped == 1);
  Sample(false); assert(queue_calls == 1);
  g_siglus_lookup_press_diagnostic_dropped = 0;
  // Inspect the real copy boundary: readers cannot accept a half-written slot,
  // and the count must still describe the preceding completed publication.
  bool fence_seen = false;
  static bool* fence_result = nullptr;
  fence_result = &fence_seen;
  on_memcpy = [](void* dest, size_t size) {
    assert(size == sizeof(SiglusLookupPressDiagnostic) - sizeof(LONG64));
    const auto* record = reinterpret_cast<const SiglusLookupPressDiagnostic*>(
        static_cast<const unsigned char*>(dest) - sizeof(LONG64));
    assert(record->seq == 0 && g_siglus_lookup_press_diagnostic_count == 0);
    *fence_result = true;
  };
  SiglusLookupPressDiagnostic value;
  RecordSiglusLookupPressDiagnostic(value);
  on_memcpy = nullptr;
  assert(fence_seen && g_siglus_lookup_press_diagnostic_count == 1);
  g_siglus_lookup_press_diagnostic_count = 0;
  auto writer = [] {
    for (int i = 0; i < 1000; ++i) {
      SiglusLookupPressDiagnostic d;
      d.event_id = d.thread_id = d.geometry_generation = d.snapshot_epoch = static_cast<uint64_t>(i + 1);
      RecordSiglusLookupPressDiagnostic(d);
    }
  };
  std::thread a(writer), b(writer);
  for (int wait = 0; wait < 1000000 &&
       InterlockedCompareExchange64(&g_siglus_lookup_press_diagnostic_count, 0, 0) == 0; ++wait)
    std::this_thread::yield();
  unsigned accepted = 0;
  for (int read = 0; read < 2000; ++read) {
    const auto current = static_cast<uint64_t>(InterlockedCompareExchange64(
        &g_siglus_lookup_press_diagnostic_count, 0, 0));
    SiglusLookupPressDiagnostic d;
    if (current != 0 && ReadDiagnosticRecord(current, &d)) {
      assert(d.event_id == d.thread_id && d.event_id == d.geometry_generation &&
             d.event_id == d.snapshot_epoch);
      ++accepted;
    }
  }
  a.join(); b.join();
  assert(accepted != 0);
  const auto count = static_cast<uint64_t>(g_siglus_lookup_press_diagnostic_count);
  assert(count >= 8 && count + g_siglus_lookup_press_diagnostic_dropped == 2000);
  for (uint64_t seq = count - 7; seq <= count; ++seq) {
    const auto& d = g_siglus_lookup_press_diagnostics[seq % 8];
    assert(static_cast<uint64_t>(d.seq) == seq && d.event_id == d.thread_id &&
           d.event_id == d.geometry_generation && d.event_id == d.snapshot_epoch);
  }
}
} // namespace
int main() {
  TestActualDownRejections();
  TestSuccessAndEpochReleaseRejection();
  TestUnsynchronizedAndMissOwnership();
  TestMessageAndSurfaceBoundaries();
  TestDiagnosticLifecycleAndThreadIsolation();
  TestOwnedUpFailures();
  TestConcurrentReadPublication();
  TestBoundedPublicationAndContention();
  std::puts("siglus_lookup_input_diagnostics_test: 8 groups, 65 down rejection cases and 9 owned-up cases passed");
}
