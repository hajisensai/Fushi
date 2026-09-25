import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-2674 / BUG-2675: a glyph click waits ~200 ms for the injected shield to
/// acknowledge its down. A sync inside that window used to treat the pending
/// acknowledgement as a lost handshake, hide the surface and cancel the
/// gesture, so the click was swallowed without a lookup.
void main() {
  final String surface = File(
    'windows/runner/attached_text_surface_window.cpp',
  ).readAsStringSync();

  String functionBody(String signature) {
    final int start = surface.indexOf(signature);
    expect(start, isNonNegative, reason: signature);
    final int next = surface.indexOf(
      '\nvoid AttachedTextSurfaceWindow::',
      start + 1,
    );
    return surface.substring(start, next < 0 ? surface.length : next);
  }

  test('an in-flight own glyph click is not hidden by the handshake gate', () {
    final String sync = functionBody(
      'void AttachedTextSurfaceWindow::SyncToTarget()',
    );
    final int ensure = sync.indexOf(
      'const ShieldHandshakeState handshake = EnsureShieldHandshake();',
    );
    final int inFlight = sync.indexOf('OwnGlyphTransactionInFlight()', ensure);
    final int gateHide = sync.indexOf('HideSurface();', ensure);
    expect(ensure, isNonNegative);
    expect(inFlight, isNonNegative);
    expect(
      inFlight < gateHide,
      isTrue,
      reason: 'the own-transaction check must run before the gate hides',
    );
    final String keep = sync.substring(ensure, gateHide);
    expect(keep, contains('return;'));
    expect(keep, contains('!layout_dirty_'));
  });

  test('click judgement uses the full drag rectangle and logs drops', () {
    final String update = functionBody(
      'void AttachedTextSurfaceWindow::UpdatePointerGesture(',
    );
    expect(update, isNot(contains('SM_CXDRAG) / 2')));
    expect(update, contains('GetSystemMetricsForDpi(SM_CXDRAG'));
    final String end = functionBody(
      'void AttachedTextSurfaceWindow::EndPointerGesture(',
    );
    expect(
      end,
      contains('pressed_cluster == released_cluster || !pointer_dragged_'),
    );
    expect(end, contains('LogDroppedClick('));
    final String cancel = functionBody(
      'void AttachedTextSurfaceWindow::CancelPointerGesture()',
    );
    expect(cancel, contains('LogDroppedClick("gesture_cancelled")'));
  });
}
