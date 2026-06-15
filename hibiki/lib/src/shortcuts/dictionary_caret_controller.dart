import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart';

/// Which WebView surface the char-level reading cursor lives on. The cursor is
/// on the reader content, or — after a dictionary lookup — on the top popup,
/// following the popup stack as the user looks up deeper words and backs out.
///
/// [lyrics] only ever appears on the reader (audiobook lyrics mode); video, the
/// home dictionary tab and the standalone popup window only use [none] / [popup]
/// (and, where applicable, their own primary surface). Keeping all four values
/// in one enum lets every dictionary-bearing surface share the same caret state
/// machine ([DictionaryCaretController]).
enum CaretSurface { none, reader, popup, lyrics }

/// Side-effect seams the caret state machine needs from its host page. The
/// controller owns the *state* and the popup-transition *algorithm*; the host
/// supplies the WebView-touching / `setState` parts so each surface (reader,
/// later video / home / standalone window) plugs in its own primary-surface
/// behaviour without the controller depending on any one page.
abstract class DictionaryCaretHost {
  /// Whether the host [State] is still mounted. Mirrors `State.mounted`; guards
  /// every async continuation so a disposed page never touches dead state.
  bool get caretHostMounted;

  /// The top-most VISIBLE dictionary popup's WebView state — the surface the
  /// cursor drives while it lives in the dictionary. Null when no popup is up.
  DictionaryPopupWebViewState? get caretTopPopupState;

  /// Index of the top-most visible popup, or -1. Used only for diagnostics /
  /// future surfaces; the reader does not branch on it inside the controller.
  int get caretTopVisiblePopupIndex;

  /// Apply a state mutation and rebuild the host. The controller funnels every
  /// surface change through here so the host's `setState` (focus ring, debug
  /// hooks) stays in charge of the rebuild, exactly as before extraction.
  void caretSetState(VoidCallback fn);

  /// Hide the host's primary READER-content caret ring when the cursor leaves it
  /// for a popup (called only when [surface] == [CaretSurface.reader], matching
  /// the pre-extraction behaviour — the lyrics ring is intentionally left up).
  /// On the reader this evaluates `ReaderCaretScripts.exit` on the reader
  /// WebView; surfaces with no own ring can no-op.
  void caretExitPrimaryRing();
}

/// The char-level dictionary reading-cursor state machine, extracted from the
/// reader page so video / the home dictionary tab / the standalone popup window
/// can reuse it (TODO-387). It owns:
///
///   * which [CaretSurface] holds the cursor ([surface]);
///   * the popup WebView state that currently holds it ([popupState]);
///   * the in-flight async guard ([busy]) that serialises cursor JS ops;
///   * the popup-surface transitions (transfer to top popup, resume after a
///     touch→hardware-nav flip, follow the popup stack on dismiss/render).
///
/// Surface-specific behaviour (reader vs. lyrics JS invocations, keyboard
/// routing, the focus "sandwich" between content / header / bottom chrome) stays
/// in the host page — the controller only moves the *ownership* of the shared
/// state and the popup algorithm, not those reader-specific branches.
class DictionaryCaretController {
  DictionaryCaretController(this._host);

  final DictionaryCaretHost _host;

  // ── State ───────────────────────────────────────────────────────────

  /// Which surface holds the char-level reading cursor (a focused character
  /// inside a WebView's DOM). The cursor lives on the primary surface (reader
  /// content / lyrics) or — after a lookup — on the top dictionary popup, and
  /// follows the popup stack as the user goes deeper / backs out. The host's
  /// existing `setState(() => surface = …)` call sites write this directly (they
  /// own the rebuild); [setSurface] / [resetWithState] wrap a rebuild for callers
  /// that do not.
  CaretSurface surface = CaretSurface.none;

  /// The popup-WebView state that currently holds the cursor (when [surface] ==
  /// [CaretSurface.popup]), so a re-render of the SAME popup (load-more) only
  /// re-measures the ring instead of re-seeding the cursor.
  DictionaryPopupWebViewState? popupState;

  /// Serialises the cursor's async JS operations. A gamepad D-pad auto-repeats
  /// ~9×/s and a move that turns the page round-trips slower than that, so
  /// overlapping calls would evaluate against a mid-pagination DOM and make the
  /// cursor jump. New directional input is dropped while an op is in flight.
  bool busy = false;

  bool get active => surface != CaretSurface.none;
  bool get onReader => surface == CaretSurface.reader;
  bool get onLyrics => surface == CaretSurface.lyrics;
  bool get onPopup => surface == CaretSurface.popup;

  /// Apply a surface change *with* a host rebuild. Funnels through
  /// [DictionaryCaretHost.caretSetState] so the host's `setState` semantics
  /// (focus ring, debug hooks) are preserved.
  void setSurface(CaretSurface value) {
    _host.caretSetState(() => surface = value);
  }

  /// Full reset of the cursor state with a rebuild (cursor fully left its
  /// surface). The host first hides whatever ring is showing; this only clears
  /// the shared fields.
  void resetWithState() {
    _host.caretSetState(() {
      surface = CaretSurface.none;
      popupState = null;
    });
  }

  // ── Popup-surface transitions (reusable across surfaces) ─────────────

  /// Re-validate the popup caret surface when the user picks the controller back
  /// up after using the mouse. If the top popup changed underneath the suspended
  /// caret, transfer to it; if the popup is gone, drop to [CaretSurface.none].
  void resumePopupCaretForHardwareNav() {
    final DictionaryPopupWebViewState? state = _host.caretTopPopupState;
    if (state == null) {
      popupState = null;
      surface = CaretSurface.none;
      return;
    }
    if (!identical(state, popupState)) {
      unawaited(transferToTopPopup(state));
      return;
    }
    state.caretResume();
  }

  /// A deeper popup layer was dismissed (B/Esc or swipe) but a parent popup
  /// remains: keep the cursor on the popup surface, follow it to the new top, and
  /// re-measure its ring. No-op when the cursor is not on a popup.
  void onDictionaryStackChanged() {
    if (!_host.caretHostMounted || surface != CaretSurface.popup) return;
    final DictionaryPopupWebViewState? newTop = _host.caretTopPopupState;
    if (newTop == null) return;
    if (!identical(newTop, popupState)) {
      _host.caretSetState(() => popupState = newTop);
      unawaited(newTop.caretRefresh());
    }
  }

  /// Hand the char-level cursor to the freshly rendered top popup when in cursor
  /// mode. Pure-touch users ([surface] == [CaretSurface.none]) are unaffected.
  void onDictionaryPopupRendered(int index) {
    if (surface == CaretSurface.none) return;
    if (index != _host.caretTopVisiblePopupIndex) return;
    final DictionaryPopupWebViewState? state = _host.caretTopPopupState;
    if (state == null) return;
    if (surface == CaretSurface.popup && identical(state, popupState)) {
      // Same popup re-rendered (e.g. load-more) — just re-measure its ring.
      unawaited(state.caretRefresh());
      return;
    }
    unawaited(transferToTopPopup(state));
  }

  /// Move the cursor onto [state] (the top popup). Seeds the popup caret, then
  /// hides the host's primary ring if the cursor was leaving the primary surface
  /// (a parent popup's ring is occluded by the new top, so it is left for the
  /// return trip). Retries once if the popup's body has not laid out yet.
  Future<void> transferToTopPopup(DictionaryPopupWebViewState state) async {
    await state.caretInit();
    String status = await state.caretEnter();
    if (!_host.caretHostMounted || _host.caretTopPopupState != state) return;
    if (status != 'moved') {
      // The popup may not have laid out its definition body yet (the cursor only
      // stops inside .glossary-content). Give it a frame and retry once.
      await Future<void>.delayed(const Duration(milliseconds: 120));
      if (!_host.caretHostMounted || _host.caretTopPopupState != state) return;
      status = await state.caretEnter();
      if (!_host.caretHostMounted) return;
    }
    if (status != 'moved') {
      debugPrint('[DictionaryCaret] caret transfer to popup failed: $status');
      return; // leave the cursor on its current surface (ring still shown)
    }
    // Success: hide the primary ring when leaving the READER content (it's the
    // large background). The lyrics surface keeps its ring (matching the
    // pre-extraction behaviour), and a parent popup's ring is occluded by the
    // new top, so it is left for the return trip (re-shown when the top closes).
    if (surface == CaretSurface.reader) {
      _host.caretExitPrimaryRing();
    }
    _host.caretSetState(() {
      surface = CaretSurface.popup;
      popupState = state;
    });
  }
}
