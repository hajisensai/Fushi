#pragma once

// KiriKiri bootstrap stage diagnostics: the pure, unit-tested half.
//
// Both main-thread installs (the lookup sensor and the KAG text lane) cross the
// same chain of boundaries before anything reaches the log:
//
//   exporter ready -> install requested -> main-thread seam armed / fired
//   -> engine main thread id resolved -> install entered on that thread
//   -> TJS host functions resolved -> bootstrap script allocated and
//   registered -> bootstrap continuous callback fired -> TVPExecuteScript
//   -> TJS bootstrap waits for KAG (kag / kag.fore / kag.fore.messages ...)
//   -> TJS install body -> installed / failed at stage N
//
// Before this header every one of those boundaries failed the same way on a
// real machine: no line at all (KiriKiri Z 1.3.3.7 fullscreen sample: neither
// `[FushiKagText] bootstrap installed=` nor a lookup sensor; KiriKiri2 sample:
// text lane fine, lookup sensor never installed).  Each boundary now owns one
// integer phase value.  The engine main thread only stores integers
// (Interlocked); HookWorker turns a *changed* value into one log line, at most
// kMaxLinesPerPhase per phase, so the whole session is bounded and the log
// never carries game text -- every value is a small code or a thread id.
//
// TJS codes are written by the bootstrap scripts in kirikiri_adapter.inc
// (global.fushiLookupBootstrapStage / global.fushiKagTextStage) right before
// each early return; tests/kirikiri_lookup_source_guard_test.py keeps the
// literals in the scripts aligned with the constants below.

#include <cstdint>
#include <cstdio>
#include <cwchar>

namespace fushi_voice_hook::kirikiri_bootstrap_diag {

enum class Phase : uint32_t {
  kSeam = 0,         // shared WH_GETMESSAGE main-thread seam
  kMainThread,       // resolved engine main thread id (value = tid)
  kInstallCallers,   // which threads reached an install entry (bit mask)
  kHostFunctions,    // TJS host function table (shared by both lanes)
  kLookupNative,     // lookup sensor install, native side
  kLookupTjs,        // lookup sensor bootstrap, TJS side
  kKagTextNative,    // KAG text lane install, native side
  kKagTextTjs,       // KAG text lane bootstrap, TJS side
  kCount
};

inline constexpr uint32_t kPhaseCount = static_cast<uint32_t>(Phase::kCount);
inline constexpr uint32_t kMaxLinesPerPhase = 8u;

// kSeam
inline constexpr int32_t kSeamArmed = 1;
inline constexpr int32_t kSeamFired = 2;
inline constexpr int32_t kSeamReleased = 3;
inline constexpr int32_t kSeamHookFailed = -1;
inline constexpr int32_t kSeamNoMainWindow = -2;

// kInstallCallers (bit mask, only grows)
inline constexpr int32_t kCallerMainThread = 1;    // passed the identity check
inline constexpr int32_t kCallerOtherThread = 2;   // main tid known, caller differs
inline constexpr int32_t kCallerUnresolved = 4;    // main tid not resolvable yet

// kHostFunctions
inline constexpr int32_t kHostOk = 1;
inline constexpr int32_t kHostExportQueryFailed = -1;
inline constexpr int32_t kHostExpressionQueryFailed = -2;
inline constexpr int32_t kHostNullFunction = -3;

// kLookupNative / kKagTextNative
inline constexpr int32_t kNativeRequested = 1;
inline constexpr int32_t kNativeRegistered = 2;      // script allocated, callbacks added
inline constexpr int32_t kNativeCallbackFired = 3;   // bootstrap continuous callback ran
inline constexpr int32_t kNativeExecuted = 4;        // TVPExecuteScript returned
inline constexpr int32_t kNativeAllocFailed = -1;    // TJSAllocVariantString gave null
inline constexpr int32_t kNativeExecuteFaulted = -2; // TVPExecuteScript threw (SEH)
inline constexpr int32_t kNativeInstallThrew = -3;   // registering the callbacks threw

// Value HookWorker stores when the TJS stage global is not an Integer although
// the script was executed (the script never defined it: compile error, or a
// different global object).
inline constexpr int32_t kTjsStageUndefined = -1;

// kLookupTjs (global.fushiLookupBootstrapStage)
inline constexpr int32_t kLookupTjsArmed = 1;              // handler registered
inline constexpr int32_t kLookupTjsNoKag = 2;              // global.kag not an object
inline constexpr int32_t kLookupTjsTextRenderPartial = 3;  // TextRender class half ready
inline constexpr int32_t kLookupTjsInstalling = 4;         // inside the install body
inline constexpr int32_t kLookupTjsFailedBase = 100;       // + installStage of the throw
inline constexpr int32_t kLookupTjsInstalledBase = 1000;   // + seams + rejected * 32
inline constexpr int32_t kLookupTjsInstalledLimit = 2000;
// fushiLookupKagSeams bits (input seams that ended up installed)
inline constexpr int32_t kLookupSeamViaAddHook = 0x01;
inline constexpr int32_t kLookupSeamClick = 0x02;
inline constexpr int32_t kLookupSeamMove = 0x04;
inline constexpr int32_t kLookupSeamWheel = 0x08;
inline constexpr int32_t kLookupSeamKey = 0x10;
inline constexpr int32_t kLookupSeamMask = 0x1F;
// Multiplier for fushiLookupKagSeamsRejected (inputs whose kag.addHook threw).
inline constexpr int32_t kLookupRejectedShift = 32;

// kKagTextTjs (global.fushiKagTextStage)
inline constexpr int32_t kKagTjsArmed = 1;
inline constexpr int32_t kKagTjsNoKag = 2;
inline constexpr int32_t kKagTjsNoFore = 3;
inline constexpr int32_t kKagTjsNoMessages = 4;
inline constexpr int32_t kKagTjsForeThrew = 5;
inline constexpr int32_t kKagTjsDone = 6;  // handler removed; result in fushiKagTextInstalled

// fushiKagTextInstalled values that are not a seam mask.
inline constexpr int32_t kKagInstalledNoWaitMethods = -1;  // no showLineBreak / showPageBreak
inline constexpr int32_t kKagInstalledThrew = -2;
inline constexpr int32_t kKagInstalledNoSeam = -3;         // nothing could be wrapped

inline const wchar_t* PhaseName(Phase phase) {
  switch (phase) {
    case Phase::kSeam: return L"seam";
    case Phase::kMainThread: return L"main_tid";
    case Phase::kInstallCallers: return L"install_callers";
    case Phase::kHostFunctions: return L"host_fns";
    case Phase::kLookupNative: return L"lookup.native";
    case Phase::kLookupTjs: return L"lookup.tjs";
    case Phase::kKagTextNative: return L"kag_text.native";
    case Phase::kKagTextTjs: return L"kag_text.tjs";
    case Phase::kCount: break;
  }
  return L"?";
}

inline const wchar_t* NativeName(int32_t value) {
  switch (value) {
    case 0: return L"idle";
    case kNativeRequested: return L"requested";
    case kNativeRegistered: return L"registered";
    case kNativeCallbackFired: return L"callback-fired";
    case kNativeExecuted: return L"executed";
    case kNativeAllocFailed: return L"alloc-failed";
    case kNativeExecuteFaulted: return L"execute-faulted";
    case kNativeInstallThrew: return L"install-threw";
    default: return nullptr;
  }
}

// Writes "<phase>=<decoded value>" into out.  Unknown codes are printed raw
// (value(<n>)) instead of being dropped: an unexpected value is evidence too.
inline void FormatPhase(Phase phase, int32_t value, wchar_t* out, size_t capacity) {
  if (out == nullptr || capacity == 0) return;
  const wchar_t* name = PhaseName(phase);
  const wchar_t* text = nullptr;
  switch (phase) {
    case Phase::kSeam:
      switch (value) {
        case 0: text = L"none"; break;
        case kSeamArmed: text = L"armed"; break;
        case kSeamFired: text = L"fired"; break;
        case kSeamReleased: text = L"released"; break;
        case kSeamHookFailed: text = L"hook-failed"; break;
        case kSeamNoMainWindow: text = L"no-main-window"; break;
        default: break;
      }
      break;
    case Phase::kMainThread:
      _snwprintf_s(out, capacity, _TRUNCATE, L"%ls=%lu", name,
                   static_cast<unsigned long>(static_cast<uint32_t>(value)));
      return;
    case Phase::kInstallCallers: {
      const bool main = (value & kCallerMainThread) != 0;
      const bool other = (value & kCallerOtherThread) != 0;
      const bool unresolved = (value & kCallerUnresolved) != 0;
      _snwprintf_s(out, capacity, _TRUNCATE, L"%ls=%ls%ls%ls%ls%ls", name,
                   main ? L"main" : L"", main && (other || unresolved) ? L"+" : L"",
                   other ? L"other" : L"", other && unresolved ? L"+" : L"",
                   unresolved ? L"unresolved" : L"");
      return;
    }
    case Phase::kHostFunctions:
      switch (value) {
        case kHostOk: text = L"ok"; break;
        case kHostExportQueryFailed: text = L"export-query-failed"; break;
        case kHostExpressionQueryFailed: text = L"expression-query-failed"; break;
        case kHostNullFunction: text = L"null-function"; break;
        default: break;
      }
      break;
    case Phase::kLookupNative:
    case Phase::kKagTextNative:
      text = NativeName(value);
      break;
    case Phase::kLookupTjs:
      if (value >= kLookupTjsInstalledBase && value < kLookupTjsInstalledLimit) {
        const int32_t packed = value - kLookupTjsInstalledBase;
        _snwprintf_s(out, capacity, _TRUNCATE,
                     L"%ls=installed(seams=0x%02lx,addhook_rejected=0x%02lx)", name,
                     static_cast<unsigned long>(packed & kLookupSeamMask),
                     static_cast<unsigned long>((packed / kLookupRejectedShift) &
                                                kLookupSeamMask));
        return;
      }
      if (value >= kLookupTjsFailedBase && value < kLookupTjsInstalledBase) {
        _snwprintf_s(out, capacity, _TRUNCATE, L"%ls=failed-at-stage(%ld)", name,
                     static_cast<long>(value - kLookupTjsFailedBase));
        return;
      }
      switch (value) {
        case kTjsStageUndefined: text = L"undefined"; break;
        case kLookupTjsArmed: text = L"armed"; break;
        case kLookupTjsNoKag: text = L"no-kag"; break;
        case kLookupTjsTextRenderPartial: text = L"textrender-partial"; break;
        case kLookupTjsInstalling: text = L"installing"; break;
        default: break;
      }
      break;
    case Phase::kKagTextTjs:
      switch (value) {
        case kTjsStageUndefined: text = L"undefined"; break;
        case kKagTjsArmed: text = L"armed"; break;
        case kKagTjsNoKag: text = L"no-kag"; break;
        case kKagTjsNoFore: text = L"no-fore"; break;
        case kKagTjsNoMessages: text = L"no-messages"; break;
        case kKagTjsForeThrew: text = L"fore-threw"; break;
        case kKagTjsDone: text = L"done"; break;
        default: break;
      }
      break;
    case Phase::kCount:
      break;
  }
  if (text != nullptr) {
    _snwprintf_s(out, capacity, _TRUNCATE, L"%ls=%ls", name, text);
  } else {
    _snwprintf_s(out, capacity, _TRUNCATE, L"%ls=value(%ld)", name,
                 static_cast<long>(value));
  }
}

// HookWorker-private: remembers the last value seen per phase and how many
// lines the phase has written.  0 is every phase's "nothing yet" and is never
// logged as a first observation.
class Tracker {
 public:
  // True = the caller should write one line for (phase, value).
  bool Observe(Phase phase, int32_t value) {
    const uint32_t index = static_cast<uint32_t>(phase);
    if (index >= kPhaseCount) return false;
    if (value == last_[index]) return false;
    last_[index] = value;
    if (lines_[index] >= kMaxLinesPerPhase) return false;
    ++lines_[index];
    return true;
  }
  uint32_t lines(Phase phase) const {
    const uint32_t index = static_cast<uint32_t>(phase);
    return index < kPhaseCount ? lines_[index] : 0u;
  }

 private:
  int32_t last_[kPhaseCount] = {};
  uint32_t lines_[kPhaseCount] = {};
};

// A lookup TJS stage that will not change any more by itself: the install
// body ran to its end (installed) or its catch removed the handler (failed).
// Once there, the frame pump stops evaluating the stage global.
inline bool IsLookupTjsTerminal(int32_t value) {
  return value >= kLookupTjsFailedBase && value < kLookupTjsInstalledLimit;
}

}  // namespace fushi_voice_hook::kirikiri_bootstrap_diag
