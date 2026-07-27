import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

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

  setUpAll(() {
    body = File('windows/runner/floating_lyric_window.cpp').readAsStringSync();
    bodyHeader =
        File('windows/runner/floating_lyric_window.h').readAsStringSync();
    toolbar = File('windows/runner/hook_toolbar_window.cpp').readAsStringSync();
    toolbarHeader =
        File('windows/runner/hook_toolbar_window.h').readAsStringSync();
    cmake = File('windows/runner/CMakeLists.txt').readAsStringSync();
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
      for (final String source in <String>[body, toolbar]) {
        expect(source.contains('SetTimer('), isFalse);
        expect(source.contains('KillTimer('), isFalse);
        expect(source.contains('PollCursorInteractivity'), isFalse);
        expect(source.contains('ApplyPassThroughHitTest'), isFalse);
      }
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
      const List<String> expected = <String>[
        'replayVoice',
        'recaptureVoice',
        'toggleFollow',
        'togglePassThrough',
        'toggleTransparency',
        'lock',
        'openWorkbench',
        'close',
      ];
      final List<String> found = RegExp('"([a-zA-Z]+)"')
          .allMatches(table)
          .map((RegExpMatch m) => m.group(1)!)
          .toList();
      expect(found, expected,
          reason: 'Slot order is the wire contract with the Dart controller.');
      expect(toolbarHeader.contains('constexpr int kSlotCount = 8'), isTrue);
      expect(
          body.contains('kHookTextControlSlotCount = hook_toolbar::kSlotCount'),
          isTrue,
          reason: 'The body must derive its slot count from the shared table.');
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
      expect(dispatcher.contains('topmost_ = !topmost_'), isTrue);
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
