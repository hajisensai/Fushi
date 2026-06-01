# Gamepad Long-Press (Hold A) — Design & Implementation Plan

> **Status:** implemented for the desktop polled gamepad path, Android reader key-event path, and reader/popup caret; Flutter widget long-press wrappers are partially wired; real-device verification remains open.

**Goal:** Let a gamepad trigger "long-press" by **holding A ~500ms**, wherever a long-press is meaningful: the popup (mark a dictionary), the reader/popup caret (long-press the word/element), the book shelf (open book details), etc.

## The core mechanism + the one trade-off

A on the desktop polled gamepad path is now decided on **release** by `GamepadFrameProcessor`. To tell a short A (activate) from a long A (long-press), A is handled this way:

- A pressed → start a timer; nothing fires yet.
- Released < 500ms → fire **A (activate)** — same as today.
- Held ≥ 500ms → fire **A-long (long-press)**; the later release fires nothing.

**Trade-off (gamepad path):** A's *activate* fires on release instead of press in the desktop poller and Android reader key-event path. For a normal tap this is imperceptible; it only matters if you hold A. This is exactly how touch tap-vs-long-press works. There is no way to disambiguate without deferring — firing both press-A and a 500ms long-A would double-act (e.g. toggle a collapse AND select a dict).

(Page-turn is on RB/LB + D-pad, not A, so A-on-release never affects paging.)

## Three long-press targets (the work is routing A-long to the right one)

The popup caret, the reader caret, and a focused Flutter widget are different worlds; A-long routes by current state:

1. **Popup caret active** → `topPopupState.caretLongPress()` → JS `hoshiCaret.longPress()` → long-press the caret element. For the dict label (`▼ name`) this marks/unmarks the dictionary through `window.__hoshiDictLongPress(summaryEl)`, without synthesizing touch events.
2. **Reader caret active** → `ReaderCaretScripts.longPressInvocation()` → JS `hoshiCaret.longPress()` → long-press at the caret. Plain text currently reuses the lookup pipeline; element stops dispatch a context menu fallback unless they have a specific helper.
3. **No caret (a Flutter control focused, e.g. a book card)** → `GamepadLongPressIntent` bubbles to `GamepadLongPressActions`, which invokes the same callback as mouse/touch `onLongPress` for wrapped widgets.

## Phasing (deliver incrementally, each independently testable)

- **Phase 1 — input + caret long-press.** Done in code: hold-A detection in the desktop frame processor; `GamepadLongPressIntent`; `CaretAction.longPress`; `_caretLongPress()`; `hoshiCaret.longPress()` JS; popup dict-select via callable `window.__hoshiDictLongPress`.
- **Phase 2 — Flutter widgets.** Partially done: `GamepadLongPressActions` exists and wraps history/collection/search-history surfaces found in the current audit. Continue adding it only where an existing mouse/touch long-press callback already exists.
- **Phase 3 — Android key path.** Done for the reader content/caret layer: `gameButtonA` KeyDown starts the hold timer, KeyUp emits short activate/enter, and repeats are swallowed. Chrome/header controls keep native framework activation.
- **Out of scope (note):** "长按移动" (long-press-drag to reorder/move) — drag via gamepad is a distinct interaction (hold + directional to move an item); design separately if wanted.

## Phase 1 — files & tasks

1. `gamepad_service.dart` — done: frame processor defers A when `onLongPress` is present, emits `onButton(GamepadButton.a)` on short release, emits `onLongPress(GamepadButton.a)` once after 500ms, and suppresses the release activate.
2. `reader_caret_router.dart` — done: `CaretAction.longPress` exists as the caret-level action.
3. `reader_hibiki_page.dart` — done: `GamepadLongPressIntent` is handled by `_handleGamepadLongPress`; active caret routes to `_runCaretAction(CaretAction.longPress)`; `_caretLongPress()` dispatches to the popup or reader WebView.
4. `reader_caret_scripts.dart` — done: `longPress()` JS calls popup dictionary summary helpers, uses lookup for text, and dispatches a `contextmenu` fallback for other element stops.
5. `dictionary_popup_webview.dart` — done: `caretLongPress()` mirrors the other caret bridge methods.
6. `popup.js` — done: summary selection is exposed as `window.__hoshiDictLongPress(summaryEl)` via the summary's stored `__hoshiToggleSelection`.
7. Unit tests — done for structure and input semantics: `gamepad_frame_processor_test.dart`, `reader_caret_router_test.dart`, `reader_caret_scripts_test.dart`, `reader_caret_long_press_static_test.dart`.
8. Android reader key-event path — done: `_handleGamepadAKeyEvent` defers `LogicalKeyboardKey.gameButtonA` until release, supports `KeyUpEvent`/`KeyRepeatEvent`, and clears timers on dispose.
9. Device verification — open: no Android device/AVD was connected in the 2026-06-01 run; Windows real-controller verification still needs hardware evidence.

## Remaining Work

- Device evidence: verify hold-A in reader text, popup `summary.dict-label`, and at least one Flutter `GamepadLongPressActions` list item on real Windows controller hardware or Android emulator/device.
- Drag/reorder by long-hold remains out of scope; use explicit up/down reorder buttons unless a separate design is approved.
