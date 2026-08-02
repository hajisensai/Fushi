import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../helpers/source_guard.dart';
import '../helpers/win32_interactivity_guard.dart';

/// BUG-951 — source-scan guards for the galgame hook overlay's pass-through
/// design.
///
/// Why a source scan: the load-bearing code is a pair of Win32 windows in
/// `windows/runner/`. It cannot be instantiated from `flutter test` (no message
/// loop, no Direct2D, and the failure is defined by another PROCESS receiving a
/// click). These guards therefore pin the wiring whose loss would silently
/// re-introduce one of the two failure modes we have already shipped:
///
///  1. HTTRANSPARENT-only pass-through — swallowed the click entirely, because
///     that hit-test result only walks same-thread windows and the game is a
///     different process (the original BUG-951).
///  2. Timer-driven WS_EX_TRANSPARENT flipping — a starved timer leaves the bit
///     set while the cursor is already over the toolbar, so the click falls
///     into the game and advances dialogue / picks a branch (PR#460, reverted).
///
/// The shipped design has no state to lose a race over: the body window is
/// click-through for exactly as long as the user keeps pass-through on, and the
/// toolbar is a separate window that is never transparent.
///
/// Limitation, stated plainly: a text scan pins the WIRING, not the runtime
/// behaviour. Cross-process click delivery and the "toolbar always clickable"
/// property still need the Windows real-device pass recorded in
/// `docs/bugs/BUG-951-gal-overlay-click-through-cross-process.md`.
void main() {
  late String body;
  late String toolbar;
  late String toolbarHeader;
  late String bodyHeader;
  late String cmake;
  late String host;
  late String dartChannel;

  setUpAll(() {
    dartChannel = File('lib/src/platform/gal_hook_text_overlay_channel.dart')
        .readAsStringSync();
    body = File('windows/runner/floating_lyric_window.cpp').readAsStringSync();
    bodyHeader =
        File('windows/runner/floating_lyric_window.h').readAsStringSync();
    toolbar = File('windows/runner/hook_toolbar_window.cpp').readAsStringSync();
    toolbarHeader =
        File('windows/runner/hook_toolbar_window.h').readAsStringSync();
    cmake = File('windows/runner/CMakeLists.txt').readAsStringSync();
    host = File('windows/runner/flutter_window.cpp').readAsStringSync();
  });

  /// Returns the body of `signature { ... }`, brace-matched, so an assertion
  /// about "inside function X" cannot be satisfied by a match elsewhere.
  String functionBody(String source, String signature) {
    final int start = source.indexOf(signature);
    expect(start, isNot(-1), reason: 'missing $signature');
    int i = source.indexOf('{', start);
    expect(i, isNot(-1), reason: 'no opening brace after $signature');
    int depth = 0;
    for (int j = i; j < source.length; j++) {
      if (source[j] == '{') depth++;
      if (source[j] == '}') {
        depth--;
        if (depth == 0) return source.substring(i, j + 1);
      }
    }
    fail('unbalanced braces after $signature');
  }

  int countOf(String haystack, String needle) =>
      needle.allMatches(haystack).length;

  /// Drops `// ...` comments so a call-site count cannot be thrown off (in
  /// either direction) by prose that mentions the symbol.
  String stripLineComments(String source) => maskComments(source);

  group('BUG-951 · the body window is really click-through', () {
    test('WS_EX_TRANSPARENT is applied, and only from one function', () {
      // The whole point of the fix: HTTRANSPARENT does not cross a process
      // boundary, WS_EX_TRANSPARENT does. The bit must actually be used.
      expect(body.contains('WS_EX_TRANSPARENT'), isTrue,
          reason: 'Cross-process pass-through needs the ex-style bit.');

      // ...but from exactly one place, so there can never be a second code path
      // that strips clicks without also putting the escape hatch on screen.
      // Count the *expression*, not the word: the token also appears in
      // explanatory comments, which are harmless. The cast is the only way the
      // bit reaches an ex-style, and it must exist exactly once, inside the
      // single setter.
      const String applyExpr = 'static_cast<LONG_PTR>(WS_EX_TRANSPARENT)';
      final String setter = functionBody(
          body, 'void FloatingLyricWindow::SetBodyExTransparent(bool enabled)');
      expect(countOf(setter, applyExpr), 1);
      expect(countOf(body, applyExpr), 1,
          reason: 'The ex-style bit must only be applied inside '
              'SetBodyExTransparent.');
      expect(setter.contains('SetWindowLongPtr(hwnd_, GWL_EXSTYLE'), isTrue);
      expect(setter.contains('SWP_FRAMECHANGED'), isTrue,
          reason: 'Without SWP_FRAMECHANGED the window keeps hit-testing with '
              'the old ex-style.');
    });

    test('SetBodyExTransparent is only ever called by ApplyPassThroughExStyle',
        () {
      final String applier = functionBody(
          body, 'void FloatingLyricWindow::ApplyPassThroughExStyle()');
      // 3 call sites total: the two inside ApplyPassThroughExStyle (off-path,
      // failure-path) plus the enable at its end. Any call from elsewhere means
      // some other code path can take clicks away.
      expect(countOf(applier, 'SetBodyExTransparent('), 3,
          reason: 'off-path, toolbar-failed path, enable path');
      expect(countOf(body, 'SetBodyExTransparent('), 3 + 1 /* definition */,
          reason: 'unexpected extra caller outside ApplyPassThroughExStyle');
      expect(bodyHeader.contains('void SetBodyExTransparent(bool enabled);'),
          isTrue);
    });

    test('the discredited HTTRANSPARENT mechanism is gone', () {
      expect(body.contains('return HTTRANSPARENT;'), isFalse,
          reason: 'HTTRANSPARENT never reaches another process — that IS '
              'BUG-951.');
      expect(toolbar.contains('return HTTRANSPARENT;'), isFalse);
    });

    test('pass-through is not driven by a timer (PR#460 regression)', () {
      // PR#749 UPDATE — this used to ban the token `Timer(` outright. That
      // judged the KEYWORD, not the BEHAVIOUR, and it was wrong in both
      // directions: a `TIMERPROC` callback rebuilds PR#460 verbatim without the
      // body ever containing `WM_TIMER`, while a timer that merely reads the
      // cursor to dispatch a word lookup — which is what the Shift-hover lookup
      // poll does, and it explicitly stands down under `pass_through_` — was
      // failed on sight.
      //
      // The predicate is now the invariant itself: from every timer callback,
      // walk the real call graph and fail if anything reachable WRITES the
      // window's mouse interactivity. It also pins that the callbacks are
      // enumerable at all (TIMERPROC must be nullptr), so the reachability
      // analysis cannot be dodged by installing a timer with its own callback.
      expectTimerCannotFlipInteractivity(body,
          className: 'FloatingLyricWindow', label: 'floating_lyric_window.cpp');
      expectTimerCannotFlipInteractivity(toolbar,
          className: 'HookToolbarWindow', label: 'hook_toolbar_window.cpp');
      // The toolbar is the escape hatch; it has no pass-through state to flip
      // and no reason to own a timer at all, so the stricter ban still applies
      // there. Losing this would mean the one always-clickable window grew a
      // way to stop being clickable.
      expect(stripLineComments(toolbar).contains('Timer('), isFalse,
          reason: 'The escape-hatch toolbar has no legitimate timer.');
      // Symbol-level tombstones for PR#460's own helpers, in either file. Cheap
      // belt-and-braces on top of the behavioural predicate: a resurrection by
      // copy-paste is caught by name even before the call graph is walked.
      for (final String source in <String>[body, toolbar]) {
        final String code = stripLineComments(source);
        expect(code.contains('PollCursorInteractivity'), isFalse);
        expect(code.contains('ApplyPassThroughHitTest'), isFalse);
        expect(code.contains('UpdatePassThroughFromCursor'), isFalse);
      }
    });

    test('only the three lifecycle edges may re-apply pass-through', () {
      // SetBodyExTransparent being funnelled through ApplyPassThroughExStyle is
      // worth nothing if some cursor-driven poller may call the funnel itself.
      // Show / Hide / SetPassThrough are the only legal callers; anything else
      // means the "no state to race over" property has been given up.
      final String code = stripLineComments(body);
      expect(countOf(code, 'ApplyPassThroughExStyle()'), 3 + 1 /* definition */,
          reason: 'Callers must stay exactly Show(), Hide(), SetPassThrough(). '
              'A fourth caller is how a hover race gets back in.');
    });

    test('show / hide both route through the single applier', () {
      expect(
          functionBody(body, 'bool FloatingLyricWindow::Show(HWND owner)')
              .contains('ApplyPassThroughExStyle()'),
          isTrue);
      expect(
          functionBody(body, 'void FloatingLyricWindow::Hide()')
              .contains('ApplyPassThroughExStyle()'),
          isTrue);
      expect(
          functionBody(body,
                  'void FloatingLyricWindow::SetPassThrough(bool enabled)')
              .contains('ApplyPassThroughExStyle()'),
          isTrue);
    });
  });

  group('BUG-951 · the user can always get back out', () {
    test('the escape hatch is shown BEFORE the body stops taking clicks', () {
      final String applier = functionBody(
          body, 'void FloatingLyricWindow::ApplyPassThroughExStyle()');
      final int show = applier.indexOf('pass_through_toolbar_.Show(');
      final int enable = applier.indexOf('SetBodyExTransparent(true)');
      expect(show, isNot(-1));
      expect(enable, isNot(-1));
      expect(show < enable, isTrue,
          reason: 'Ordering is the invariant: the body may only go '
              'click-through once the toolbar window exists.');
    });

    test('a toolbar that cannot be created cancels pass-through', () {
      final String applier = functionBody(
          body, 'void FloatingLyricWindow::ApplyPassThroughExStyle()');
      expect(applier.contains('if (!pass_through_toolbar_.Show('), isTrue,
          reason: 'The Show() result must be checked, not ignored.');
      expect(applier.contains('pass_through_ = false;'), isTrue,
          reason: 'Better to drop the toggle than to strand the user behind '
              'an overlay they can no longer click.');
      // ...and the veto must be reported, or Dart's own flag stays true and the
      // user's next press on the button is a press that does nothing visible.
      expect(applier.contains('on_pass_through_(false)'), isTrue,
          reason: 'A silently vetoed toggle desyncs Dart and eats the next '
              'press on the escape-hatch button.');
      expect(host.contains('"passThroughChanged"'), isTrue,
          reason: 'The veto must reach Dart over the gal_hook_text channel.');
    });

    test('the toolbar window is never mouse-transparent', () {
      final int create = toolbar.indexOf('CreateWindowExW(');
      expect(create, isNot(-1));
      final String flags = toolbar.substring(
          create, toolbar.indexOf('kWindowClassName', create));
      expect(flags.contains('WS_EX_TRANSPARENT'), isFalse,
          reason: 'This window IS the escape hatch; it must always be '
              'clickable.');
      expect(flags.contains('WS_EX_NOACTIVATE'), isTrue,
          reason: 'Clicking a button must not steal focus from the game.');
      expect(flags.contains('WS_EX_TOPMOST'), isTrue,
          reason: 'It has to float above both the game and the overlay body.');
      // Nowhere else either — not even a later SetWindowLongPtr.
      expect(toolbar.contains('SetWindowLongPtr(hwnd_, GWL_EXSTYLE'), isFalse);
    });

    test('the overlay can still be moved while the body takes no input', () {
      // With the body click-through, dragging it is impossible; the toolbar
      // carries the drag and asks the owner to move (which clamps to the work
      // area, so the overlay cannot be dragged off-screen).
      expect(toolbar.contains('on_drag_('), isTrue);
      expect(toolbarHeader.contains('using DragCallback'), isTrue);
      expect(
          body.contains('void FloatingLyricWindow::MoveBodyTo(int x, int y)'),
          isTrue);
      expect(
          functionBody(
                  body, 'void FloatingLyricWindow::MoveBodyTo(int x, int y)')
              .contains('ClampOriginToWorkArea('),
          isTrue);
    });
  });

  group('BUG-951 · the two windows cannot drift apart', () {
    test('slot -> action is one shared table', () {
      // Both windows index hook_toolbar::kSlotActions, so button 3 is
      // togglePassThrough in both or in neither.
      expect(toolbarHeader.contains('kSlotActions'), isTrue);
      expect(body.contains('hook_toolbar::kSlotActions[slot]'), isTrue,
          reason: 'The body must not keep a private copy of the mapping.');
      expect(toolbar.contains('hook_toolbar::kSlotActions[slot]'), isTrue);

      final String table = toolbarHeader.substring(
          toolbarHeader.indexOf('kSlotActions'),
          toolbarHeader.indexOf('};', toolbarHeader.indexOf('kSlotActions')));
      // Spelled out on purpose: the row's left-to-right order is muscle memory
      // (rightmost is always 关闭), so a reorder must be a deliberate edit here
      // and not something a refactor can do quietly. `topmost` joined at slot 7
      // in PR#749 — ahead of close, so slots 0..6 kept their index.
      const List<String> expected = <String>[
        'replayVoice',
        'recaptureVoice',
        'toggleFollow',
        'togglePassThrough',
        'toggleTransparency',
        'lock',
        'openWorkbench',
        'topmost',
        'close',
      ];
      final List<String> found = RegExp('"([a-zA-Z]+)"')
          .allMatches(table)
          .map((RegExpMatch m) => m.group(1)!)
          .toList();
      expect(found, expected,
          reason: 'Slot order is the wire contract with the Dart controller.');
      // Derived, not a second literal to keep in sync: a table that grows while
      // kSlotCount does not is an out-of-bounds read in both windows.
      expect(
          toolbarHeader
              .contains('constexpr int kSlotCount = ${expected.length}'),
          isTrue,
          reason: 'kSlotCount must equal the shared table length.');
      expect(
          body.contains('kHookTextControlSlotCount = hook_toolbar::kSlotCount'),
          isTrue,
          reason: 'The body must derive its slot count from the shared table.');

      // No dead buttons. Every slot must actually be executed somewhere: either
      // natively in DispatchControlAction (`lock` / `topmost` deliberately skip
      // the Dart round-trip) or by the Dart controller's action switch. Without
      // this, adding a slot to the table draws a button that does nothing —
      // and the hardcoded list above would happily bless it.
      final String dispatcher = functionBody(body,
          'void FloatingLyricWindow::DispatchControlAction(const std::string& action)');
      for (final String action in expected) {
        final bool nativelyHandled = dispatcher.contains('== "$action"');
        final bool dartHandled = dartChannel.contains("case '$action':");
        expect(nativelyHandled || dartHandled, isTrue,
            reason: 'Slot "$action" is drawn and hit-tested but nothing runs '
                'it — neither DispatchControlAction nor the Dart controller '
                'handles it.');
      }
    });

    test('glyph + active tint are shared too', () {
      expect(body.contains('hook_toolbar::SlotGlyph(slot, tb_states)'), isTrue);
      expect(
          body.contains('hook_toolbar::SlotActive(slot, tb_states)'), isTrue);
      expect(
          toolbar.contains('hook_toolbar::SlotGlyph(slot, states_)'), isTrue);
    });

    test('one dispatcher runs a button, whichever window was clicked', () {
      expect(bodyHeader.contains('void DispatchControlAction('), isTrue);
      final String applier = functionBody(
          body, 'void FloatingLyricWindow::ApplyPassThroughExStyle()');
      expect(applier.contains('DispatchControlAction(action)'), isTrue,
          reason: 'The toolbar action callback must reuse the body dispatcher, '
              'not a second copy of the lock / topmost logic.');
      // The lock + topmost toggles live in the dispatcher only.
      final String dispatcher = functionBody(body,
          'void FloatingLyricWindow::DispatchControlAction(const std::string& action)');
      expect(dispatcher.contains('on_lock_'), isTrue);
      // PR#749 UPDATE — this used to be `contains('topmost_ = !topmost_')`,
      // an inline write that PR#749 correctly extracted into SetTopmost() so
      // the pin button and Dart's session reset drive the same code. Pinning
      // the literal would have punished the better structure, so pin the
      // structure instead: the dispatcher toggles through the single applier,
      // and the applier is the ONLY writer of topmost_. Every window-Z
      // SetWindowPos reads that member, so a second writer is how the pin ends
      // up lit while the window is no longer topmost.
      expect(dispatcher.contains('SetTopmost(!topmost_)'), isTrue,
          reason: 'The pin button must toggle through the single applier.');
      expect(countOf(stripLineComments(body), 'topmost_ ='), 1,
          reason: 'SetTopmost() must be the only writer of topmost_.');
      expect(
          functionBody(
                  body, 'void FloatingLyricWindow::SetTopmost(bool enabled)')
              .contains('topmost_ = enabled'),
          isTrue,
          reason: 'That one writer must be SetTopmost().');
    });

    test('geometry is pushed from the body, not recomputed in the toolbar', () {
      expect(
          body.contains(
              'hook_toolbar::Layout FloatingLyricWindow::ComputePassThroughToolbarLayout()'),
          isTrue);
      // The toolbar hit-tests against the layout it was given; if it grew its
      // own dip constants the two toolbars could disagree about where a button
      // is, which is exactly the class of bug that makes a click land on the
      // wrong function.
      expect(toolbar.contains('layout_.button_px'), isTrue);
      expect(toolbar.contains('kButtonSizeDip'), isFalse);
      expect(toolbar.contains('kControlsTopDip'), isFalse);
    });

    test('the in-body toolbar is not painted while the body is click-through',
        () {
      expect(
          body.contains(
              'const bool draw_body_toolbar = !(hook_text_mode_ && pass_through_);'),
          isTrue,
          reason: 'Two toolbars drawn at the same spot, one of them dead, is '
              'the UI lie this design exists to remove.');
    });
  });

  test('the new translation unit is actually built', () {
    expect(cmake.contains('"hook_toolbar_window.cpp"'), isTrue,
        reason: 'A file missing from CMakeLists silently never ships.');
  });
}
