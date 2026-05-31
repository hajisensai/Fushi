# Gamepad Long-Press (Hold A) — Design & Implementation Plan

> **Status:** awaiting user confirmation of the A-on-release trade-off + Phase 1 scope.

**Goal:** Let a gamepad trigger "long-press" by **holding A ~500ms**, wherever a long-press is meaningful: the popup (mark a dictionary), the reader/popup caret (long-press the word/element), the book shelf (open book details), etc.

## The core mechanism + the one trade-off

A currently fires on **press** (`gamepad_service.dart:286`, `_handleGamepadButton`). To tell a short A (activate) from a long A (long-press), A must be decided on **release**:

- A pressed → start a timer; nothing fires yet.
- Released < 500ms → fire **A (activate)** — same as today.
- Held ≥ 500ms → fire **A-long (long-press)**; the later release fires nothing.

**Trade-off (global):** on the gamepad, A's *activate* fires on release instead of press. For a normal tap this is imperceptible; it only matters if you hold A. This is exactly how touch tap-vs-long-press works. There is no way to disambiguate without deferring — firing both press-A and a 500ms long-A would double-act (e.g. toggle a collapse AND select a dict). **This needs a yes before building.**

(Page-turn is on RB/LB + D-pad, not A, so A-on-release never affects paging.)

## Three long-press targets (the work is routing A-long to the right one)

The popup caret, the reader caret, and a focused Flutter widget are different worlds; A-long routes by current state:

1. **Popup caret active** → `topPopupState.caretLongPress()` → JS `hoshiCaret.longPress()` → long-press the caret element. For the dict label (`▼ name`) this marks/unmarks the dictionary (popup.js `toggleSelection`, currently touch-only — refactor it into a callable so JS can invoke it without synthesizing touch events).
2. **Reader caret active** → `_controller.longPress()` JS → long-press the word/element at the caret (the reader's existing long-press selection path).
3. **No caret (a Flutter control focused, e.g. a book card)** → invoke the focused widget's long-press via a new `LongPressIntent` Action wired into the shelf cards (→ book details).

## Phasing (deliver incrementally, each independently testable)

- **Phase 1 — input + caret long-press (this plan).** Hold-A detection in the desktop frame processor; new `GamepadButton.aLong`; `CaretAction.longPress`; `_caretLongPress()`; `hoshiCaret.longPress()` JS; popup dict-select via a callable `toggleSelection`. Covers the popup (where the issue was raised) and the reader caret.
- **Phase 2 — Flutter widgets.** `LongPressIntent` + Action wired into book-shelf cards (and other long-pressable lists) so A-long opens details. Separate plan.
- **Phase 3 — Android key path.** Hold-A via `gameButtonA` KeyDown/KeyUp timing in `_handleKeyEvent` (desktop polled path done first; the user is on Windows). Separate plan.
- **Out of scope (note):** "长按移动" (long-press-drag to reorder/move) — drag via gamepad is a distinct interaction (hold + directional to move an item); design separately if wanted.

## Phase 1 — files & tasks

1. `gamepad_service.dart` — frame processor: defer A; emit `GamepadButton.a` on short release, `GamepadButton.aLong` on 500ms hold. Add `aLong` to the `GamepadButton` enum (`input_binding.dart`). Reset clears the A-hold timer.
2. `reader_caret_router.dart` — `CaretAction.longPress`; `decideGamepad(aLong) → longPress` (keyboard: none yet, or Shift+Enter later).
3. `reader_hibiki_page.dart` — `_handleGamepadButton`: route `aLong` (caret active → `_runCaretAction(longPress)`; else fall through). `_runCaretAction`: `case longPress → _caretLongPress()`. `_caretLongPress()`: popup → `topPopupState.caretLongPress()`, reader → `_controller.evaluateJavascript(hoshiCaret.longPress())`.
4. `reader_caret_scripts.dart` — `longPress()` JS: on an element stop, fire its long-press (dispatch the registered long-press / call `toggleSelection` for a dict label, else a `contextmenu`/long-press synthetic); on text, the reader's word long-press.
5. `dictionary_popup_webview.dart` — `caretLongPress()` mirror.
6. `popup.js` — make `toggleSelection` reachable from `hoshiCaret.longPress()` (e.g. expose `window.__hoshiDictLongPress(summaryEl)` or a `data-` hook) instead of only the touch timer.
7. Unit tests: router `aLong→longPress`; frame-processor hold timing (synthetic frames with timestamps — `GamepadFrameProcessor` is already unit-tested this way); JS `longPress` structural assertions.
8. Device-verify on Windows; Opus review.

## Open question for the user
Confirm the **A-on-release** trade-off (required) and that **Phase 1 (popup + reader caret long-press)** is the right first slice, with shelf "book details" and drag as follow-ups.
