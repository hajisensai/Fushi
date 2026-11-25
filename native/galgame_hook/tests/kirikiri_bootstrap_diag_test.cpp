// CI builds with --config Release, where MSVC defines NDEBUG and compiles
// bare assert() out entirely. Undefine it before any include or this test is
// green no matter what it checks. Guard: tests/assert_liveness_guard_test.py
#undef NDEBUG

// KiriKiri bootstrap stage diagnostics: change-only, bounded logging and the
// decoding of every phase code into a log token.  No game content involved.
#include <windows.h>

#include <cassert>
#include <cstdint>
#include <cstdio>
#include <string>

#include "adapters/kirikiri_bootstrap_diag.h"

namespace bd = fushi_voice_hook::kirikiri_bootstrap_diag;

namespace {

int g_failures = 0;
int g_checks = 0;

void Check(bool condition, const std::string& what) {
  ++g_checks;
  if (!condition) {
    ++g_failures;
    fprintf(stderr, "FAIL: %s\n", what.c_str());
  }
}

std::wstring Format(bd::Phase phase, int32_t value) {
  wchar_t text[128] = {};
  bd::FormatPhase(phase, value, text, 128);
  return text;
}

void CheckFormat(bd::Phase phase, int32_t value, const wchar_t* want,
                 const std::string& what) {
  const std::wstring got = Format(phase, value);
  Check(got == want, what);
  if (got != want) fwprintf(stderr, L"  got '%ls' want '%ls'\n", got.c_str(), want);
}

void TestTrackerLogsOnlyChanges() {
  bd::Tracker tracker;
  Check(!tracker.Observe(bd::Phase::kSeam, 0), "initial zero is not a line");
  Check(tracker.Observe(bd::Phase::kSeam, bd::kSeamArmed), "first value is a line");
  Check(!tracker.Observe(bd::Phase::kSeam, bd::kSeamArmed), "same value is not a line");
  Check(!tracker.Observe(bd::Phase::kSeam, bd::kSeamArmed), "steady state stays silent");
  Check(tracker.Observe(bd::Phase::kSeam, bd::kSeamFired), "a change is a line");
  Check(tracker.lines(bd::Phase::kSeam) == 2u, "two lines for two changes");
  // Phases are independent.
  Check(tracker.Observe(bd::Phase::kKagTextTjs, bd::kKagTjsNoKag), "other phase logs");
  Check(tracker.lines(bd::Phase::kSeam) == 2u, "other phase does not count here");
  // Negative codes (failures) are observations like any other.
  Check(tracker.Observe(bd::Phase::kHostFunctions, bd::kHostExportQueryFailed),
        "negative failure code logs");
}

void TestTrackerIsBoundedPerPhase() {
  bd::Tracker tracker;
  uint32_t logged = 0;
  // A phase flapping between two values every poll must not flood the log.
  for (int i = 0; i < 1000; ++i) {
    if (tracker.Observe(bd::Phase::kLookupTjs, (i % 2) == 0 ? 2 : 3)) ++logged;
  }
  Check(logged == bd::kMaxLinesPerPhase, "flapping phase capped at kMaxLinesPerPhase");
  Check(tracker.lines(bd::Phase::kLookupTjs) == bd::kMaxLinesPerPhase,
        "line counter stops at the cap");
  // The cap is per phase: another phase still gets its lines.
  Check(tracker.Observe(bd::Phase::kLookupNative, bd::kNativeRequested),
        "cap of one phase does not silence another");
  Check(!tracker.Observe(bd::Phase::kCount, 1), "out-of-range phase is ignored");
}

void TestShared() {
  CheckFormat(bd::Phase::kSeam, bd::kSeamArmed, L"seam=armed", "seam armed");
  CheckFormat(bd::Phase::kSeam, bd::kSeamFired, L"seam=fired", "seam fired");
  CheckFormat(bd::Phase::kSeam, bd::kSeamReleased, L"seam=released", "seam released");
  CheckFormat(bd::Phase::kSeam, bd::kSeamHookFailed, L"seam=hook-failed", "seam failed");
  CheckFormat(bd::Phase::kSeam, bd::kSeamNoMainWindow, L"seam=no-main-window",
              "seam blocked by main window");
  CheckFormat(bd::Phase::kMainThread, 4660, L"main_tid=4660", "main tid printed raw");
  CheckFormat(bd::Phase::kInstallCallers, bd::kCallerMainThread, L"install_callers=main",
              "main-thread caller only");
  CheckFormat(bd::Phase::kInstallCallers, bd::kCallerOtherThread | bd::kCallerUnresolved,
              L"install_callers=other+unresolved", "never the main thread");
  CheckFormat(bd::Phase::kInstallCallers,
              bd::kCallerMainThread | bd::kCallerOtherThread | bd::kCallerUnresolved,
              L"install_callers=main+other+unresolved", "all caller kinds");
  CheckFormat(bd::Phase::kInstallCallers, bd::kCallerMainThread | bd::kCallerUnresolved,
              L"install_callers=main+unresolved", "main and unresolved");
  CheckFormat(bd::Phase::kHostFunctions, bd::kHostOk, L"host_fns=ok", "host ok");
  CheckFormat(bd::Phase::kHostFunctions, bd::kHostExportQueryFailed,
              L"host_fns=export-query-failed", "host export query");
  CheckFormat(bd::Phase::kHostFunctions, bd::kHostExpressionQueryFailed,
              L"host_fns=expression-query-failed", "host expression query");
  CheckFormat(bd::Phase::kHostFunctions, bd::kHostNullFunction, L"host_fns=null-function",
              "host null function");
}

void TestNative() {
  CheckFormat(bd::Phase::kLookupNative, 0, L"lookup.native=idle", "request withdrawn");
  CheckFormat(bd::Phase::kLookupNative, bd::kNativeRequested, L"lookup.native=requested",
              "requested");
  CheckFormat(bd::Phase::kKagTextNative, bd::kNativeRegistered,
              L"kag_text.native=registered", "registered");
  CheckFormat(bd::Phase::kKagTextNative, bd::kNativeCallbackFired,
              L"kag_text.native=callback-fired", "callback fired");
  CheckFormat(bd::Phase::kKagTextNative, bd::kNativeExecuted, L"kag_text.native=executed",
              "executed");
  CheckFormat(bd::Phase::kKagTextNative, bd::kNativeAllocFailed,
              L"kag_text.native=alloc-failed", "alloc failed");
  CheckFormat(bd::Phase::kLookupNative, bd::kNativeExecuteFaulted,
              L"lookup.native=execute-faulted", "execute faulted");
  CheckFormat(bd::Phase::kLookupNative, bd::kNativeInstallThrew,
              L"lookup.native=install-threw", "install threw");
  CheckFormat(bd::Phase::kLookupNative, 77, L"lookup.native=value(77)",
              "unknown native code printed raw, not dropped");
}

void TestLookupTjs() {
  CheckFormat(bd::Phase::kLookupTjs, bd::kTjsStageUndefined, L"lookup.tjs=undefined",
              "stage global missing");
  CheckFormat(bd::Phase::kLookupTjs, bd::kLookupTjsArmed, L"lookup.tjs=armed", "armed");
  CheckFormat(bd::Phase::kLookupTjs, bd::kLookupTjsNoKag, L"lookup.tjs=no-kag", "no kag");
  CheckFormat(bd::Phase::kLookupTjs, bd::kLookupTjsTextRenderPartial,
              L"lookup.tjs=textrender-partial", "textrender half ready");
  CheckFormat(bd::Phase::kLookupTjs, bd::kLookupTjsInstalling, L"lookup.tjs=installing",
              "installing");
  CheckFormat(bd::Phase::kLookupTjs, bd::kLookupTjsFailedBase + 40,
              L"lookup.tjs=failed-at-stage(40)", "failed in the kag seam install");
  CheckFormat(bd::Phase::kLookupTjs, bd::kLookupTjsFailedBase + 0,
              L"lookup.tjs=failed-at-stage(0)", "failed before the first stage");
  // All four inputs through addHook.
  CheckFormat(bd::Phase::kLookupTjs, bd::kLookupTjsInstalledBase + 0x1F,
              L"lookup.tjs=installed(seams=0x1f,addhook_rejected=0x00)",
              "installed through addHook");
  // addHook refused the wheel hook name: wheel fell back to the kag instance wrapper.
  CheckFormat(bd::Phase::kLookupTjs,
              bd::kLookupTjsInstalledBase + 0x1F + bd::kLookupSeamWheel * bd::kLookupRejectedShift,
              L"lookup.tjs=installed(seams=0x1f,addhook_rejected=0x08)",
              "wheel rejected by addHook, instance fallback");
  // Classic KAG3 without addHook.
  CheckFormat(bd::Phase::kLookupTjs, bd::kLookupTjsInstalledBase + 0x1E,
              L"lookup.tjs=installed(seams=0x1e,addhook_rejected=0x00)",
              "installed through instance wrappers");
  // Maximum packed value stays inside the installed range.
  const int32_t max_packed = bd::kLookupTjsInstalledBase + bd::kLookupSeamMask +
                             0x1E * bd::kLookupRejectedShift;
  Check(max_packed < bd::kLookupTjsInstalledLimit, "packed installed code fits its range");

  Check(!bd::IsLookupTjsTerminal(bd::kTjsStageUndefined), "undefined is not terminal");
  Check(!bd::IsLookupTjsTerminal(bd::kLookupTjsNoKag), "waiting is not terminal");
  Check(!bd::IsLookupTjsTerminal(bd::kLookupTjsInstalling), "installing is not terminal");
  Check(bd::IsLookupTjsTerminal(bd::kLookupTjsFailedBase + 43), "failure is terminal");
  Check(bd::IsLookupTjsTerminal(bd::kLookupTjsInstalledBase + 0x1F), "installed is terminal");
  Check(!bd::IsLookupTjsTerminal(bd::kLookupTjsInstalledLimit), "beyond range is not");
}

void TestKagTextTjs() {
  CheckFormat(bd::Phase::kKagTextTjs, bd::kTjsStageUndefined, L"kag_text.tjs=undefined",
              "stage global missing");
  CheckFormat(bd::Phase::kKagTextTjs, bd::kKagTjsArmed, L"kag_text.tjs=armed", "armed");
  CheckFormat(bd::Phase::kKagTextTjs, bd::kKagTjsNoKag, L"kag_text.tjs=no-kag", "no kag");
  CheckFormat(bd::Phase::kKagTextTjs, bd::kKagTjsNoFore, L"kag_text.tjs=no-fore", "no fore");
  CheckFormat(bd::Phase::kKagTextTjs, bd::kKagTjsNoMessages, L"kag_text.tjs=no-messages",
              "no messages");
  CheckFormat(bd::Phase::kKagTextTjs, bd::kKagTjsForeThrew, L"kag_text.tjs=fore-threw",
              "fore threw");
  CheckFormat(bd::Phase::kKagTextTjs, bd::kKagTjsDone, L"kag_text.tjs=done", "done");
  CheckFormat(bd::Phase::kKagTextTjs, 99, L"kag_text.tjs=value(99)", "unknown printed raw");
}

void TestFormatIsBoundedAndTerminated() {
  wchar_t tiny[8];
  for (wchar_t& ch : tiny) ch = L'#';
  bd::FormatPhase(bd::Phase::kLookupTjs, bd::kLookupTjsInstalledBase + 0x1F, tiny, 8);
  Check(tiny[7] == L'\0', "truncated output stays terminated");
  bd::FormatPhase(bd::Phase::kSeam, bd::kSeamArmed, nullptr, 8);  // must not crash
  wchar_t empty[1] = {L'#'};
  bd::FormatPhase(bd::Phase::kSeam, bd::kSeamArmed, empty, 0);
  Check(empty[0] == L'#', "zero capacity writes nothing");
}

}  // namespace

int main() {
  TestTrackerLogsOnlyChanges();
  TestTrackerIsBoundedPerPhase();
  TestShared();
  TestNative();
  TestLookupTjs();
  TestKagTextTjs();
  TestFormatIsBoundedAndTerminated();
  printf("kirikiri_bootstrap_diag_test: %d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
