import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/floating_ball/floating_ball_config.dart';

/// Linux desktop system ball: offered only in X11 sessions, and without the
/// buttons whose result needs the global lookup card (when the card helper is
/// missing).
void main() {
  group('linuxSessionIsX11', () {
    test('Plasma X11 session (Steam Deck desktop mode)', () {
      expect(linuxSessionIsX11(<String, String>{'DISPLAY': ':0'}), isTrue);
    });

    test('Wayland session, even with Xwayland running', () {
      expect(
        linuxSessionIsX11(<String, String>{
          'DISPLAY': ':0',
          'WAYLAND_DISPLAY': 'wayland-0',
        }),
        isFalse,
      );
    });

    test('GDK_BACKEND decides when set (first entry wins)', () {
      expect(
        linuxSessionIsX11(<String, String>{
          'DISPLAY': ':0',
          'WAYLAND_DISPLAY': 'wayland-0',
          'GDK_BACKEND': 'x11',
        }),
        isTrue,
      );
      expect(
        linuxSessionIsX11(<String, String>{
          'DISPLAY': ':0',
          'GDK_BACKEND': 'wayland,x11',
        }),
        isFalse,
      );
    });

    test('no display at all (headless, Game Mode service)', () {
      expect(linuxSessionIsX11(<String, String>{}), isFalse);
    });
  });

  test('without the global lookup card the desktop system ball hides '
      'selection lookup and screen OCR, keeps the rest', () {
    Set<FloatingBallGlobalAction> available({required bool card}) =>
        <FloatingBallGlobalAction>{
          for (final FloatingBallGlobalAction action
              in FloatingBallGlobalAction.values)
            if (action.availableIn(
              FloatingBallScope.system,
              isAndroid: false,
              isIOS: false,
              isDesktop: true,
              lookupModuleEnabled: true,
              globalLookupSupported: card,
            ))
              action,
        };

    expect(
      available(card: true).difference(available(card: false)),
      <FloatingBallGlobalAction>{
        FloatingBallGlobalAction.popupLookup,
        FloatingBallGlobalAction.screenOcr,
      },
    );
    expect(
      available(card: false),
      containsAll(<FloatingBallGlobalAction>[
        FloatingBallGlobalAction.lookup,
        FloatingBallGlobalAction.clipboard,
        FloatingBallGlobalAction.sync,
      ]),
    );
  });
}
