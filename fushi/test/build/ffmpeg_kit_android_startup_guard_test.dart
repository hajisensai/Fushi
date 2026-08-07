import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android ffmpeg-kit plugin guards startup when native libs are missing',
      () {
    final String plugin = File(
      '../third_party/ffmpeg_kit_flutter/android/src/main/java/com/arthenica/ffmpegkit/flutter/FFmpegKitFlutterPlugin.java',
    ).readAsStringSync();

    expect(plugin, contains('isNativeLibraryAvailable'));
    expect(plugin, contains('nativeLibraryAvailable'));
    expect(plugin, contains('FFMPEG_KIT_UNAVAILABLE'));

    final int guardIndex = plugin.indexOf('isNativeLibraryAvailable');
    final int callbackIndex = plugin.indexOf('registerGlobalCallbacks();');
    expect(guardIndex, isNonNegative);
    expect(callbackIndex, isNonNegative);
    expect(
      guardIndex,
      lessThan(callbackIndex),
      reason:
          'Native library availability must be checked before FFmpegKitConfig '
          'is touched, otherwise x86_64 emulators crash during Activity attach.',
    );
  });
}
