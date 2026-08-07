#ifndef RUNNER_FOREGROUND_SELECTION_H_
#define RUNNER_FOREGROUND_SELECTION_H_

// TODO-1030 M0 — Windows UI Automation foreground-selection context capture.
//
// The global-lookup hotkey fires while the user has text selected in ANY
// foreground app (browser, Word, Notepad, ...). The legacy path
// (selection_capture_ffi.dart) injects Ctrl+C and reads the clipboard, which
// yields ONLY the selected substring — no surrounding context. To show the word
// in its sentence (Yomitan {sentence}-style) we ask UI Automation for the
// focused element's Text pattern, read the live selection range, then expand it
// by a bounded number of characters on each side to grab the neighbourhood.
//
// Everything here is UIA + COM only (no clipboard, no key injection) and MUST be
// called OFF the UI thread: a cross-process UIA call can block 50-200ms. The
// caller (flutter_window.cpp) dispatches it to a worker thread and replies to
// the Dart method channel asynchronously.

#include <string>

// The maximum number of characters to expand PAST the selection on EACH side
// when grabbing context. Bounded for privacy (never scrape a whole document)
// and latency. ~600 comfortably covers one long sentence either way.
constexpr int kForegroundContextExpand = 600;

// The result of one capture attempt. On success [ok] is true and [text] holds
// the UTF-8 expanded-context window, with [sel_start]/[sel_len] locating the
// ORIGINAL selection inside that window (UTF-16 code-unit offsets — the same
// unit Dart String indexing uses). On failure [ok] is false and the other
// fields are meaningless (the Dart side falls back to clipboard capture).
//
// Deliberately carries NO diagnostic strings that could leak body text; the
// caller logs only lengths / timings / ok, never [text].
struct ForegroundSelectionResult {
  bool ok = false;
  std::string text;
  int sel_start = 0;
  int sel_len = 0;
};

// Captures the foreground app's current text selection plus up to
// [max_expand] characters of context on each side via UI Automation.
//
// Contract:
//   - initialises COM (apartment-threaded) for the CALLING thread and uninits
//     it before returning, so it is safe to run on a fresh worker thread;
//   - returns ok=false (never throws) when there is no focused element, the
//     element has no Text pattern, or the selection is empty/unavailable;
//   - the offsets are computed against the FINAL expanded text so the caller can
//     re-base the sentence without re-reading the selection.
//
// This is the single native entry point; the sentence trimming happens in Dart
// (sentence_extraction.dart) so the boundary logic stays testable and shared
// with the reader.
ForegroundSelectionResult CaptureForegroundSelectionContext(int max_expand);

#endif  // RUNNER_FOREGROUND_SELECTION_H_
