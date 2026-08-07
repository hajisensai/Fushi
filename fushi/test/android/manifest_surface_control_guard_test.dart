import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1110 / BUG-535 source-scan guard: the Android manifest must disable
/// Flutter's SurfaceControl backend
/// (`io.flutter.embedding.android.EnableSurfaceControl` = `false`).
///
/// Root cause: media_kit_video 1.3.0+ renders Android video through Flutter's
/// `TextureRegistry.SurfaceProducer` (replacing the old `SurfaceTextureEntry`).
/// On certain Android 11 ROM/GPU drivers (reported: RMX3085 / realme 8) the
/// SurfaceControl-backed SurfaceProducer never fires its first
/// `onSurfaceAvailable` callback. Without that callback the native
/// `VideoOutput` never publishes a non-zero `wid`
/// (`VideoOutput.java` `newGlobalObjectRef(surface)`), so
/// `android_video_controller/real.dart` `widListener` keeps `vo=null`
/// permanently. libmpv then never builds its GL surface
/// (`current-vo`/`gpu-api` stay empty, texture id stays null) → video decodes
/// frames but shows nothing (black screen). See flutter/flutter#156488 /
/// #162902 for the SurfaceProducer surface-lifecycle issue.
///
/// Disabling SurfaceControl makes SurfaceProducer fall back to the classic
/// ImageReader/SurfaceTexture-backed path whose surface is available
/// synchronously — the widest-compatibility media rendering route, and a
/// Flutter-documented backend switch (not a symptom-masking hack). The
/// recreate-vs-keep-alive decision is a device-side framework behavior we
/// cannot exercise here, so this guards the *manifest contract*: if the flag
/// is dropped or flipped back to `true`, the Android no-picture path silently
/// regresses and this test goes red.
void main() {
  // Tests run with CWD = `hibiki/`.
  final File manifestFile = File('android/app/src/main/AndroidManifest.xml');

  test('manifest disables SurfaceControl backend (EnableSurfaceControl=false)',
      () {
    expect(manifestFile.existsSync(), isTrue,
        reason: 'TODO-1110/BUG-535 fix lives in this manifest');
    final String manifest = manifestFile.readAsStringSync();

    // Match the <meta-data> pair regardless of attribute order / whitespace.
    final RegExp metaData = RegExp(
      r'<meta-data\b[^>]*?'
      r'io\.flutter\.embedding\.android\.EnableSurfaceControl'
      r'[^>]*?android:value="([^"]*)"',
      dotAll: true,
    );
    // Also accept the reverse attribute order (value before name).
    final RegExp metaDataReversed = RegExp(
      r'<meta-data\b[^>]*?android:value="([^"]*)"[^>]*?'
      r'io\.flutter\.embedding\.android\.EnableSurfaceControl',
      dotAll: true,
    );

    final RegExpMatch? match =
        metaData.firstMatch(manifest) ?? metaDataReversed.firstMatch(manifest);

    expect(
      match,
      isNotNull,
      reason: 'TODO-1110/BUG-535: manifest must declare a '
          '<meta-data android:name="io.flutter.embedding.android.'
          'EnableSurfaceControl" .../> entry; without it Android video can '
          'show no picture (vo=null / texture never created) on ROMs where '
          'SurfaceProducer.onSurfaceAvailable never fires',
    );
    expect(
      match!.group(1),
      'false',
      reason: 'TODO-1110/BUG-535: EnableSurfaceControl must be "false" so '
          'SurfaceProducer falls back to the classic surface path; flipping '
          'it to "true" re-exposes the RMX3085/Android-11 black-screen bug',
    );
  });
}
