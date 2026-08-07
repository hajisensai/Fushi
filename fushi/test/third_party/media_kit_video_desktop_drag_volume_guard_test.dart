import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1097 source-scan guard: the vendored `media_kit_video` desktop controls
/// must NOT re-introduce the drag-to-adjust-volume gesture.
///
/// Root cause: upstream `media_kit_video` 2.0.1 binds the central
/// `GestureDetector.onPanUpdate` (gated by `modifyVolumeOnScroll`) so holding
/// the left mouse button and dragging vertically changes the volume by
/// `e.delta.dy`. Hibiki users found this accidental — any click-and-drag on the
/// video surface silently jumped the volume — so TODO-1097 removes the drag
/// handler while keeping the scroll-wheel volume path and every tap gesture.
///
/// Fix: the package is vendored to `third_party/media_kit_video/` and the
/// `onPanUpdate` handler is deleted. This test guards the *patch* — if a future
/// re-vendor of media_kit_video restores `onPanUpdate` → `setVolume`, the
/// accidental drag-volume returns and this goes red. See
/// `third_party/media_kit_video/PATCHES.md`.
void main() {
  // Tests run with CWD = `hibiki/`; vendored packages live at the workspace root.
  const String controlsPath =
      '../third_party/media_kit_video/lib/media_kit_video_controls/'
      'src/controls/material_desktop.dart';

  late String source;

  setUp(() {
    source = File(controlsPath).readAsStringSync();
  });

  test('vendored media_kit_video override is wired in pubspec', () {
    final String pubspec = File('pubspec.yaml').readAsStringSync();
    final RegExp override = RegExp(
      r'media_kit_video:\s*\n\s*path:\s*\.\./third_party/media_kit_video',
    );
    expect(
      override.hasMatch(pubspec),
      isTrue,
      reason: 'dependency_overrides must point media_kit_video at '
          '../third_party/media_kit_video. Without it the pub.dev package '
          'returns and the desktop drag-to-adjust-volume gesture (TODO-1097) '
          'comes back.',
    );
  });

  test('desktop controls no longer bind onPanUpdate', () {
    expect(
      source.contains(RegExp(r'onPanUpdate\s*:')),
      isFalse,
      reason: 'TODO-1097: the desktop GestureDetector must not bind '
          'onPanUpdate. Holding the left mouse button and dragging vertically '
          'must not change the volume. Removing this handler is the fix; '
          're-adding it (e.g. on re-vendor) reintroduces the accidental '
          'drag-volume behavior.',
    );
  });

  test('scroll-wheel volume path (onPointerSignal) is preserved', () {
    // The wheel path lives on the Listener above the GestureDetector and is a
    // deliberate feature users did not complain about; it must survive.
    expect(
      source.contains(RegExp(r'onPointerSignal\s*:')),
      isTrue,
      reason: 'TODO-1097 must keep the scroll-wheel volume path '
          '(Listener.onPointerSignal); only the drag gesture was removed.',
    );
    expect(
      source.contains('PointerScrollEvent'),
      isTrue,
      reason: 'the scroll-wheel handler must still react to PointerScrollEvent '
          'and adjust the volume (TODO-1097 keeps this).',
    );
  });

  test('tap play/pause and double-press fullscreen gestures are preserved', () {
    // The sibling tap handlers on the same GestureDetector must stay intact.
    for (final String handler in <String>['onTap', 'onTapDown', 'onTapUp']) {
      expect(
        source.contains(RegExp('$handler\\s*:')),
        isTrue,
        reason: 'TODO-1097 only removes onPanUpdate; the $handler handler '
            '(play/pause / double-press fullscreen) must remain.',
      );
    }
  });
}
