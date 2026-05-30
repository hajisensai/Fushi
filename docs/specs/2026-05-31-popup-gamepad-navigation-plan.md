# Popup Gamepad Navigation — Implementation Plan

> **For agentic workers:** Implement task-by-task. Steps use checkbox (`- [ ]`) syntax. JS lives inside a Dart raw string (`reader_caret_scripts.dart`) — `flutter analyze` does NOT check it; JS correctness is asserted structurally in unit tests and verified on the Windows device.

**Goal:** Make the dictionary popup fully gamepad-navigable: the Flutter header toolbar (★ ↺ ▶ ▶) becomes reachable as a sibling layer of the popup content, the caret ring never paints outside the popup, and the caret stops on meaningful targets (not punctuation slivers).

**Architecture:** The popup mirrors the reader's proven *sibling-layer* model. The popup WebView caret and the Flutter header toolbar are siblings: **Up** at the top of popup content moves Flutter focus to the header (standard `HibikiFocusRing`), **Down** returns to the caret, **A** activates the focused `IconButton` natively, **B** dismisses the popup. This reuses the exact pattern already shipped for reader-content ↔ bottom-bar (`_chromeFocusScope`). Ring overflow and punctuation stops are fixed in the caret JS.

**Tech Stack:** Flutter 3.41.6 / Dart 3.11.4; `flutter_inappwebview` (WebView2 on Windows); `window.hoshiCaret` JS in `reader_caret_scripts.dart`; `FocusScopeNode` + `GamepadButtonIntent`/`_handleKeyEvent` routing.

---

## Background facts (verified, with file:line)

- The 4 header buttons are Flutter `IconButton`s built by `buildPopupAudioControls()` ([reader_hibiki_page.dart:4837](../../hibiki/lib/src/pages/implementations/reader_hibiki_page.dart#L4837)), passed as `DictionaryPopupLayer.headerWidget` (only for `index == 0`, [base_source_page.dart:365](../../hibiki/lib/src/pages/base_source_page.dart#L365)) and rendered in a Flutter `Column` ABOVE the WebView ([dictionary_popup_layer.dart:179-188](../../hibiki/lib/src/pages/implementations/dictionary_popup_layer.dart#L179-L188)). They are NOT in the WebView DOM → `hoshiCaret` (JS) cannot reach them.
- While the popup caret is active, `_handleKeyEvent`/`_handleGamepadButton` route all directional + A input to the caret state machine; at the top of popup content `caretMove('up')` returns `'blocked'`, which `_caretMove`'s popup branch currently discards ([reader_hibiki_page.dart:3582-3586](../../hibiki/lib/src/pages/implementations/reader_hibiki_page.dart#L3582-L3586)) — a dead end.
- The reader already implements the sibling pattern for the bottom bar: chrome-focus branch in `_handleKeyEvent` ([:3284-3300](../../hibiki/lib/src/pages/implementations/reader_hibiki_page.dart#L3284-L3300)) and `_handleGamepadButton` ([:3368-3404](../../hibiki/lib/src/pages/implementations/reader_hibiki_page.dart#L3368-L3404)) using `_chromeFocusScope` ([:194](../../hibiki/lib/src/pages/implementations/reader_hibiki_page.dart#L194)).
- Caret ring is a `position:fixed` div; `_drawRing` paints the raw rect with no viewport clamp ([reader_caret_scripts.dart:517-525](../../hibiki/lib/src/reader/reader_caret_scripts.dart#L517-L525)); `_viewport()` is the host client area ([:275-282](../../hibiki/lib/src/reader/reader_caret_scripts.dart#L275-L282)). Popup passes `insetTop:0, insetBottom:0` so `_viewport()` == the whole popup.
- Popup clickable targets in the DOM: `.expression` headword (cursor:pointer, [popup.css:69-71](../../hibiki/assets/popup/popup.css#L69-L71)), `.kanji-tag` ([popup.css:85-95](../../hibiki/assets/popup/popup.css#L85-L95)), `a[href]` (cross-refs + Wiktionary/Kaikki), plus `summary`/audio/add controls. The " | " separator between source links is a plain text node → currently a thin char stop (the SS1 sliver).

## File structure

- **Modify** `hibiki/lib/src/reader/reader_caret_scripts.dart` — Fix B (ring clamp), Fix C (skip punctuation stops in popup).
- **Modify** `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart` — Fix A (popup-header sibling layer: scope field, focus helpers, `_caretMove` status handling, header-focus branches in both key handlers, wrap `buildPopupAudioControls`).
- **Modify** `hibiki/test/reader/reader_caret_scripts_test.dart` — structural assertions for Fix B/C.
- **Verify on Windows device** — all three symptoms (analyze + JS can't cover the WebView).

---

## Task 1: Fix B — clamp the caret ring to the viewport (no off-popup ring)

**Files:**
- Modify: `hibiki/lib/src/reader/reader_caret_scripts.dart` (`_drawRing`, ~517-525)
- Test: `hibiki/test/reader/reader_caret_scripts_test.dart`

- [ ] **Step 1: Add a failing structural test**

In the `ReaderCaretScripts.source contract` group, add:

```dart
test('ring is clamped to the viewport so it never paints outside the host', () {
  // _drawRing must intersect the drawn rect with _viewport() before painting,
  // so a stop near the popup edge cannot draw a ring outside the popup.
  expect(js, contains('_viewport()'));
  expect(js, contains('Math.max(rect.left'));
  expect(js, contains('Math.min(rect.left + rect.width'));
});
```

- [ ] **Step 2: Run it — expect FAIL**

Run: `cd /d/APP/vs_claude_code/hibiki/hibiki && D:/flutter_sdk/flutter_extracted/flutter/bin/flutter.bat test test/reader/reader_caret_scripts_test.dart -p vm`
Expected: FAIL (the `Math.max(rect.left` substring is absent).

- [ ] **Step 3: Implement the clamp**

Replace `_drawRing` (reader_caret_scripts.dart ~517-525) with:

```js
  _drawRing: function(rect) {
    var r = this._ensureRing();
    var pad = 1;
    // Clamp the ring to the current viewport: a stop whose rect overflows the
    // host (e.g. a popup-edge element taller than the popup) must never paint a
    // ring outside it. _viewport() is the host client area (the whole popup,
    // since the popup passes zero insets; the reading viewport in the reader).
    var vp = this._viewport();
    var left = Math.max(rect.left - pad, vp.left);
    var top = Math.max(rect.top - pad, vp.top);
    var right = Math.min(rect.left + rect.width + pad, vp.right);
    var bottom = Math.min(rect.top + rect.height + pad, vp.bottom);
    r.style.display = 'block';
    r.style.left = left + 'px';
    r.style.top = top + 'px';
    r.style.width = Math.max(0, right - left) + 'px';
    r.style.height = Math.max(0, bottom - top) + 'px';
  },
```

- [ ] **Step 4: Run the test — expect PASS**

Run: same as Step 2. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add hibiki/lib/src/reader/reader_caret_scripts.dart hibiki/test/reader/reader_caret_scripts_test.dart
git commit -m "fix(reader): clamp caret ring to viewport so it never paints outside the popup"
```

---

## Task 2: Fix C — skip lone punctuation/symbol stops in the popup (no separator sliver)

**Files:**
- Modify: `hibiki/lib/src/reader/reader_caret_scripts.dart` (`_isStop`, ~180-198)
- Test: `hibiki/test/reader/reader_caret_scripts_test.dart`

- [ ] **Step 1: Add a failing structural test**

```dart
test('popup caret skips lone punctuation/symbol glyphs (e.g. the " | " separator)', () {
  // In the popup (no hoshiReader) a single punctuation/symbol char is not a
  // useful lookup target and must not be a stop, so the caret never lands on
  // the thin "|" separator between source links.
  expect(js, contains(r'\p{P}'));
  expect(js, contains(r'\p{S}'));
});
```

- [ ] **Step 2: Run it — expect FAIL**

Run: `cd /d/APP/vs_claude_code/hibiki/hibiki && D:/flutter_sdk/flutter_extracted/flutter/bin/flutter.bat test test/reader/reader_caret_scripts_test.dart -p vm`
Expected: FAIL.

- [ ] **Step 3: Implement the punctuation skip (popup-only)**

In `_isStop` (reader_caret_scripts.dart), inside the existing `if (!window.hoshiReader) { ... }` block (the popup-only branch, ~189-192), add the punctuation guard BEFORE the interactive-element check:

```js
  _isStop: function(node, offset) {
    var text = node.textContent;
    if (offset < 0 || offset >= text.length) return false;
    var ch = text[offset];
    if (/^[\s　]$/.test(ch)) return false; // skip whitespace/newlines
    if (!window.hoshiReader) {
      // Popup-only: a lone punctuation/symbol glyph (the " | " separator between
      // source links, list bullets, brackets) is not a useful lookup target —
      // don't stop on it, so the cursor never lands on a thin separator sliver.
      // Words/kanji (the real targets) are unaffected.
      if (/^[\p{P}\p{S}]$/u.test(ch)) return false;
      // Text inside an interactive element is not its own stop — the element is
      // an atomic stop (the ring covers the whole control, e.g. a <summary>
      // collapse toggle). The reader reaches links via their text stops.
      var ie = node.parentElement;
      if (ie && ie.closest(this._interactiveSelector)) return false;
    }
    if (this.scopeSelector) {
      var el = node.parentElement;
      if (!el || !el.closest(this.scopeSelector)) return false;
    }
    return true;
  },
```

- [ ] **Step 4: Run the test — expect PASS**

Run: same as Step 2. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add hibiki/lib/src/reader/reader_caret_scripts.dart hibiki/test/reader/reader_caret_scripts_test.dart
git commit -m "fix(reader): popup caret skips lone punctuation glyphs (no separator sliver)"
```

---

## Task 3: Fix A — popup header toolbar as a sibling focus layer

This is the architectural fix. It adds a `FocusScopeNode` for the header, threads it through the reader's `buildPopupAudioControls()` override, and adds the *header-focused* branch to both key handlers — exactly mirroring the existing `_chromeFocusScope` bottom-bar pattern.

**Files:**
- Modify: `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart`

### Task 3a: Add the header focus scope + dispose + wrap the toolbar

- [ ] **Step 1: Declare the scope field**

Next to `_chromeFocusScope` ([reader_hibiki_page.dart:194](../../hibiki/lib/src/pages/implementations/reader_hibiki_page.dart#L194)), add:

```dart
  // The dictionary popup's Flutter header toolbar (favourite / replay / play /
  // play-from-cue) is a sibling layer of the popup WebView content, reached by
  // Up at the top of the content — exactly like the reader bottom bar relative
  // to the reading content. Its own scope so focus can move into it and back.
  final FocusScopeNode _popupHeaderScope =
      FocusScopeNode(debugLabel: 'popupHeader');
```

- [ ] **Step 2: Dispose it**

In `dispose()`, right after `_chromeFocusScope.dispose();` ([:922](../../hibiki/lib/src/pages/implementations/reader_hibiki_page.dart#L922)):

```dart
    _popupHeaderScope.dispose();
```

- [ ] **Step 3: Wrap the toolbar in the scope**

In `buildPopupAudioControls()` ([:4837](../../hibiki/lib/src/pages/implementations/reader_hibiki_page.dart#L4837)), wrap the returned widget so the IconButtons live in `_popupHeaderScope`. Replace the trailing `if (!hasAudio) { return Builder(...); } return ListenableBuilder(...);` with:

```dart
    final Widget inner = hasAudio
        ? ListenableBuilder(
            listenable: ctrl,
            builder: (context, _) => buildRow(Theme.of(context)),
          )
        : Builder(builder: (context) => buildRow(Theme.of(context)));
    // Own focus scope so the gamepad can move focus into the header (Up from the
    // popup content top) and the buttons traverse with Left/Right. The node is a
    // State field (stable across rebuilds); only the index==0 popup gets a
    // header, so exactly one widget ever uses this node at a time.
    return FocusScope(node: _popupHeaderScope, child: inner);
```

- [ ] **Step 4: Analyze**

Run: `cd /d/APP/vs_claude_code/hibiki/hibiki && D:/flutter_sdk/flutter_extracted/flutter/bin/flutter.bat analyze lib/src/pages/implementations/reader_hibiki_page.dart`
Expected: No issues found.

### Task 3b: Add the focus-transfer helpers

- [ ] **Step 1: Add `_focusPopupHeader()` and `_returnToPopupContent()`**

Place after `_caretDismissOrExit()` ([:3552-3562](../../hibiki/lib/src/pages/implementations/reader_hibiki_page.dart#L3552-L3562)):

```dart
  /// Move focus from the popup content caret UP to the Flutter header toolbar
  /// (sibling layer). Called when the caret is at the top of the popup content
  /// and Up is pressed. Hides the popup caret ring so the header's standard
  /// HibikiFocusRing is the single indicator. No-op (focus stays on content) if
  /// the header has no focusable button.
  void _focusPopupHeader() {
    if (!mounted || _caretSurface != CaretSurface.popup) return;
    _popupHeaderScope.requestFocus();
    if (_popupHeaderScope.nextFocus()) {
      topPopupState?.caretExit(); // header owns focus → hide the popup caret ring
    } else {
      _focusNode.requestFocus(); // nothing focusable in the header — undo
    }
  }

  /// Move focus from the header toolbar back DOWN to the popup content caret
  /// (sibling layer). Re-shows the popup caret ring at its remembered position.
  void _returnToPopupContent() {
    if (!mounted || _caretSurface != CaretSurface.popup) return;
    _focusNode.requestFocus(); // take Flutter focus off the header buttons
    unawaited(topPopupState?.caretEnter()); // re-show + re-place the popup caret
  }
```

- [ ] **Step 2: Analyze** — Run the same analyze command. Expected: No issues found.

### Task 3c: Make `_caretMove` route Up-at-top to the header

- [ ] **Step 1: Capture the popup move status and react to top-edge `blocked`**

Replace the popup branch of `_caretMove` ([:3583-3586](../../hibiki/lib/src/pages/implementations/reader_hibiki_page.dart#L3583-L3586)):

```dart
    if (_caretSurface == CaretSurface.popup) {
      final String status =
          await topPopupState?.caretMove(physicalDir) ?? 'blocked';
      if (!mounted) return;
      // At the top edge of the popup content, an upward move is blocked. Treat
      // that as crossing into the sibling header layer (like reader content →
      // bottom bar, but upward). Only 'up' promotes; left/right/down that block
      // simply stay put.
      if (status == 'blocked' && physicalDir == 'up') {
        _focusPopupHeader();
      }
      return;
    }
```

- [ ] **Step 2: Analyze** — Expected: No issues found.

### Task 3d: Add the header-focused branch to both key handlers

- [ ] **Step 1: Keyboard handler (`_handleKeyEvent`)**

At the very top of `_handleKeyEvent`, right after the `if (event is! KeyDownEvent) return KeyEventResult.ignored;` line ([:3277](../../hibiki/lib/src/pages/implementations/reader_hibiki_page.dart#L3277)) and BEFORE the `_chromeFocusScope.hasFocus` block, add:

```dart
    // The popup header toolbar (sibling of the popup content). Down returns to
    // the content caret; B/Escape dismiss the popup (ascend out of it). Left/
    // Right/Enter fall through to the framework so the buttons traverse and
    // activate natively (and the global HibikiFocusRing rings the focused one).
    if (_popupHeaderScope.hasFocus) {
      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        _returnToPopupContent();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.gameButtonB ||
          event.logicalKey == LogicalKeyboardKey.escape) {
        _caretDismissOrExit() // popup surface → dismissTopPopup()
            .ignore();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
```

(Note: `Future.ignore()` is a valid Dart extension; if lint objects, use `unawaited(_caretDismissOrExit());`.)

- [ ] **Step 2: Gamepad handler (`_handleGamepadButton`)**

At the very top of `_handleGamepadButton` ([:3367](../../hibiki/lib/src/pages/implementations/reader_hibiki_page.dart#L3367)), BEFORE the `_chromeFocusScope.hasFocus` block, add:

```dart
    // Popup header toolbar (sibling of the popup content). Down → content caret;
    // B → dismiss the popup. Left/Right/A fall through (return false) so the
    // GamepadService traverses the buttons and activates the focused one.
    if (_popupHeaderScope.hasFocus) {
      if (button == GamepadButton.dpadDown) {
        _returnToPopupContent();
        return true;
      }
      if (button == GamepadButton.b) {
        unawaited(_caretDismissOrExit());
        return true;
      }
      return false;
    }
```

- [ ] **Step 3: Analyze** — Expected: No issues found.

- [ ] **Step 4: Run the full unit suite**

Run: `cd /d/APP/vs_claude_code/hibiki/hibiki && D:/flutter_sdk/flutter_extracted/flutter/bin/flutter.bat test`
Expected: All tests pass (no regression; routing logic is device-verified separately).

- [ ] **Step 5: Commit**

```bash
git add hibiki/lib/src/pages/implementations/reader_hibiki_page.dart
git commit -m "feat(reader): popup header toolbar reachable as a sibling focus layer (Up/Down/B)"
```

---

## Task 4: Device verification on Windows + final review

- [ ] **Step 1: Build & launch**

```bash
cd /d/APP/vs_claude_code/hibiki/hibiki
D:/flutter_sdk/flutter_extracted/flutter/bin/flutter.bat build windows --debug
./build/windows/x64/runner/Debug/hibiki.exe
```

- [ ] **Step 2: Verify each symptom with the gamepad**
  - Open a book, look up a word → popup opens, caret transfers in.
  - At the top of the popup content press **Up** → focus jumps to the ★ toolbar with the standard ring; **Left/Right** move between ★ ↺ ▶ ▶; **A** activates (e.g. star toggles, ▶ plays); **Down** returns to the content caret; **B** dismisses the popup. (Symptom 3 fixed.)
  - Move the caret to a long/edge element → the ring stays fully inside the popup (Symptom 2 fixed).
  - Move the caret across the `Wiktionary | Kaikki` row → it stops on the links (whole-box), never on the thin " | " separator (Symptom 1 fixed).

- [ ] **Step 3: Opus code review** (mandatory per CLAUDE.md — `model: "opus"`), then fix Critical/Important and re-verify.

- [ ] **Step 4: Update the gamepad-nav design doc** (`docs/specs/2026-05-30-gamepad-reader-navigation-design.md`, 单元4) to record the popup-header sibling layer, and commit.

---

## Self-review

- **Spec coverage:** Symptom 3 (buttons unreachable) → Task 3 (sibling header). Symptom 2 (ring off-popup) → Task 1 (clamp). Symptom 1 (separator sliver) → Task 2 (punctuation skip). ✓
- **Placeholders:** none — every step has concrete code/commands. ✓
- **Type/name consistency:** `_popupHeaderScope` (3a) used in 3b/3c/3d; `_focusPopupHeader`/`_returnToPopupContent` defined in 3b, called in 3c/3d; `caretExit`/`caretEnter`/`caretMove` are existing `DictionaryPopupWebViewState` methods. ✓
- **Backward compatibility:** all new branches gate on `_popupHeaderScope.hasFocus` / `_caretSurface == popup`; touch and Android paths unaffected; reader content ↔ bottom-bar untouched. ✓
- **Risk:** the header-focus branches must be ABOVE the `_chromeFocusScope`/`_caretActive` branches in both handlers (added at the top) so they win while the header is focused. Verified placement in 3d.
