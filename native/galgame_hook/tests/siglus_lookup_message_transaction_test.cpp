#undef NDEBUG
// Reuse the real target, registry and Win32 seams; exercise both production
// entrypoints through click_policy, which includes message_transaction.inc.
// The imported standalone test entry is deliberately not invoked here.
#define NOMINMAX
#include <windows.h>
const DWORD transaction_window_thread = GetCurrentThreadId();
DWORD TestTransactionWindowThread(HWND window, DWORD* process) {
  if (process) *process = GetCurrentProcessId();
  return window == reinterpret_cast<HWND>(uintptr_t{1}) ? transaction_window_thread : 0;
}
#define GetWindowThreadProcessId TestTransactionWindowThread
#define main ImportedSiglusInputDiagnosticsMain
#include "siglus_lookup_input_diagnostics_test.cpp"
#undef main
#undef GetWindowThreadProcessId

namespace {
unsigned transaction_checks = 0;
void Verify(bool condition) { ++transaction_checks; assert(condition); }
struct MessageFixture : Fixture {
  explicit MessageFixture(SiglusGlyphLayoutAbi abi = SiglusGlyphLayoutAbi::kEcxEightArguments) {
    g_siglus_lookup_message_transaction = {};
    g_siglus_lookup_message_popup_sample = {};
    g_siglus_lookup_message_popup_epoch = 0;
    test_profile.glyph_abi = abi;
    test_profile.viewport_width = 1920;
    test_profile.viewport_height = 1080;
    view.owner = abi == SiglusGlyphLayoutAbi::kEcxTenArguments ? 0 : 0x10000;
    view.occurrence = abi == SiglusGlyphLayoutAbi::kEcxEightArguments ? 17 : 0;
    view.viewport = {0, 0, 1920, 1080};
    g_siglus_lookup_click_target.engine_view = view;
  }
};
bool Message(UINT message, int x = 110, int y = 210, uintptr_t caller = 0x400000 + 300) {
  return ConsumeSiglusLookupInputMessage(message, MAKELPARAM(x, y), caller);
}
void TestWmOnlyAndSamplingInterleavings() {
  for (int schedule = 0; schedule < 5; ++schedule) {
    MessageFixture f;
    if (schedule == 1) { Sample(true); Sample(false); Verify(queue_calls == 0); }
    Verify(Message(WM_LBUTTONDOWN));
    Verify(queue_calls == 0 && g_siglus_lookup_message_transaction.pending);
    const auto frozen = g_siglus_lookup_message_transaction.payload;
    if (schedule >= 2) {
      for (bool keyboard : {false, true}) {
        Verify(Sample(true, keyboard) == 1);
        Verify(Sample(false, keyboard) == 1);
      }
      Verify(g_siglus_lookup_message_left_button_latched && queue_calls == 0);
    }
    if (schedule == 3)
      Verify(FilterSiglusLookupLeftButtonSample(static_cast<SHORT>(0x8001), 0x400555, false) == 1);
    Verify(Message(WM_LBUTTONUP));
    Verify(queue_calls == 1 && !g_siglus_lookup_message_transaction.pending);
    Verify(test_queued.text_identity.event_id == frozen.text_identity.event_id &&
        test_queued.snapshot_epoch == frozen.snapshot_epoch &&
        test_queued.geometry_generation == frozen.geometry_generation);
    Verify(!Message(WM_LBUTTONUP) && queue_calls == 1);
    Sample(false); Sample(true); Sample(false); Sample(true, true); Sample(false, true);
    Verify(queue_calls == 1); // Neither exact sampler can independently submit.
    Verify(Message(WM_LBUTTONDBLCLK) && Message(WM_LBUTTONUP) && queue_calls == 2);
  }
}
void TestMissPopupAndCaller() {
  MessageFixture f;
  Verify(!Message(WM_LBUTTONDOWN, 110, 210, 0x400301));
  Verify(!Message(WM_LBUTTONUP) && queue_calls == 0);
  Verify(!Message(WM_MOUSEMOVE));
  Verify(!Message(WM_LBUTTONDOWN, 10, 10));
  Verify(!Message(WM_LBUTTONUP) && queue_calls == 0);
  popup = true;
  Verify(Message(WM_LBUTTONDOWN));
  Verify(!g_siglus_lookup_message_transaction.pending);
  popup = false; // Dismissal removes the popup before the physical up.
  Verify(Message(WM_LBUTTONUP) && queue_calls == 0);
  Verify(!Message(WM_LBUTTONUP));
  Verify(Message(WM_LBUTTONDOWN) && Message(WM_LBUTTONUP) && queue_calls == 1);
}
void TestPopupSampleTail() {
  for (bool synchronized : {false, true}) {
    MessageFixture f;
    if (synchronized) Sample(false);
    popup = true;
    Verify(Sample(true) == 1);
    Verify(g_siglus_lookup_left_button_filter_latched && queue_calls == 0);
    popup = false;
    for (int repeat = 0; repeat < 8; ++repeat) Verify(Sample(true) == 1);
    Verify(Sample(false) == 1 && queue_calls == 0);
    Verify(!g_siglus_lookup_left_button_filter_latched);
    Verify(static_cast<uint16_t>(Sample(true)) == 0x8001);
    Sample(false); Verify(queue_calls == 0);
  }
}
void TestCancellationAndChangedTarget() {
  for (int change = 0; change < 12; ++change) {
    MessageFixture f; Verify(Message(WM_LBUTTONDOWN));
    if (change == 0) ++g_siglus_lookup_click_epoch;
    if (change == 1) ++g_siglus_lookup_click_target.text_identity.event_id;
    if (change == 2) ++g_siglus_lookup_click_target.geometry_generation;
    if (change == 3) ++g_siglus_lookup_click_target.snapshot_epoch;
    if (change == 4) g_siglus_lookup_click_target.valid = 0;
    if (change == 5) ++view.occurrence;
    if (change == 6) foreground = other;
    if (change == 7) view_valid = false;
    if (change == 8) g_siglus_lookup_click_runtime_enabled = false;
    if (change == 9) popup = true;
    if (change == 10) ++g_siglus_lookup_click_target.client_width;
    if (change == 11)
      Verify(PublishLookupGeometryAdmission(g_header, kLookupGeometryAdmissionAuto, false, false));
    Verify(Message(WM_LBUTTONUP)); // Preserve the owned tail even on failure.
    Verify(queue_calls == 0 && !g_siglus_lookup_message_transaction.pending);
    Verify(!Message(WM_LBUTTONUP) && queue_calls == 0);
  }
  for (UINT cancel : {WM_CANCELMODE, WM_CAPTURECHANGED, WM_KILLFOCUS}) {
    MessageFixture f; Verify(Message(WM_LBUTTONDOWN));
    Verify(!Message(cancel));
    Verify(!g_siglus_lookup_message_transaction.pending);
    Verify(Message(WM_LBUTTONUP) && queue_calls == 0);
    Verify(Message(WM_LBUTTONDOWN) && Message(WM_LBUTTONUP) && queue_calls == 1);
  }
  MessageFixture f; Verify(Message(WM_LBUTTONDOWN));
  bool consumed = true, cancelled = true;
  std::thread foreign([&] {
    cancelled = Message(WM_CANCELMODE);
    consumed = Message(WM_LBUTTONUP);
  }); foreign.join();
  Verify(!consumed && !cancelled && queue_calls == 0);
  Verify(g_siglus_lookup_message_transaction.pending && g_siglus_lookup_message_left_button_latched);
  Verify(Message(WM_LBUTTONUP) && queue_calls == 1); // Foreign messages cannot clear the owner.
}
void TestLostUpAndOtherFamilies() {
  {
    MessageFixture f; Verify(Message(WM_LBUTTONDOWN));
    g_siglus_lookup_click_target.text_identity.event_id = 43;
    Verify(Message(WM_LBUTTONDOWN)); // New down supersedes the missing up.
    Verify(Message(WM_LBUTTONUP) && queue_calls == 1 && test_queued.text_identity.event_id == 43);
    Verify(Message(WM_LBUTTONDOWN));
    Verify(!Message(WM_LBUTTONDOWN, 10, 10)); // A miss must release stale ownership.
    Verify(!Message(WM_LBUTTONUP) && queue_calls == 1);
  }
  for (auto abi : {SiglusGlyphLayoutAbi::kEcxTenArguments,
                  SiglusGlyphLayoutAbi::kStackSixteenArguments}) {
    MessageFixture f(abi);
    Verify(!IsSiglusLookupMessageTransactionProfile());
    Verify(Message(WM_LBUTTONDOWN) && Message(WM_LBUTTONUP));
    Verify(queue_calls == 0 && !g_siglus_lookup_message_transaction.pending);
    Verify(Sample(true) == 1); Sample(false);
    Verify(queue_calls == 1); // Original sample-owned transaction is unchanged.
  }
}
} // namespace
int main() {
  TestWmOnlyAndSamplingInterleavings(); TestMissPopupAndCaller(); TestPopupSampleTail();
  TestCancellationAndChangedTarget(); TestLostUpAndOtherFamilies();
  std::printf("siglus_lookup_message_transaction: %u checks passed\n", transaction_checks);
}
