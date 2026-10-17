import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
      'Android FFmpegKitNext plugin answers FFMPEG_KIT_UNAVAILABLE instead of '
      'crashing when native libs fail to load', () {
    final String plugin = File(
      '../third_party/ffmpeg_kit_next_flutter/android/src/main/java/com/arthenica/ffmpegkit/flutter/FFmpegKitFlutterPlugin.java',
    ).readAsStringSync();

    expect(plugin, contains('isNativeLibraryAvailable'));
    expect(plugin, contains('nativeLibraryAvailable'));
    expect(plugin, contains('FFMPEG_KIT_UNAVAILABLE'));

    // The probe must run before the first FFmpegKitConfig touch of every call:
    // the dispatch `switch (call.method)` is where sessions / redirection are
    // reached, and an UnsatisfiedLinkError there kills the activity.
    final int handler = plugin.indexOf('public void onMethodCall(');
    expect(handler, isNonNegative);
    final int guardIndex = plugin.indexOf('isNativeLibraryAvailable()', handler);
    final int dispatchIndex = plugin.indexOf('switch (call.method)', handler);
    expect(guardIndex, isNonNegative);
    expect(dispatchIndex, isNonNegative);
    expect(
      guardIndex,
      lessThan(dispatchIndex),
      reason: 'Native library availability must be checked before the method '
          'dispatch touches FFmpegKitConfig, otherwise a device without a '
          'working libffmpegkit.so crashes on the first ffmpeg call.',
    );
  });
}
