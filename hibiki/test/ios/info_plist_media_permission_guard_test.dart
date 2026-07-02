import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-531 / TODO-1020 source-scan guard: iOS hard-crashes (SIGABRT) the first
/// time it touches the camera or photo library unless Info.plist declares the
/// matching usage-description key. `image_picker` with `ImageSource.camera`
/// needs `NSCameraUsageDescription`; `ImageSource.gallery` needs
/// `NSPhotoLibraryUsageDescription`.
///
/// Root cause: `lib/src/creator/enhancements/camera_enhancement.dart` opens
/// `ImageSource.camera` and several call sites open `ImageSource.gallery`, but
/// `ios/Runner/Info.plist` originally shipped only Microphone / LocalNetwork /
/// Bonjour keys. On iOS the OS aborts the process when a privacy-sensitive API
/// is hit with no purpose string, so mining a card via camera/gallery crashed.
///
/// The actual crash is an OS-level assertion (can't run here), so this guards
/// the *contract*: if any Dart source under `lib/` still reaches for a given
/// [ImageSource] but Info.plist drops its usage key, this test goes red.
void main() {
  // Tests run with CWD = `hibiki/`.
  final Directory libDir = Directory('lib');
  final File plistFile = File('ios/Runner/Info.plist');

  bool libUses(String needle) {
    for (final FileSystemEntity entity in libDir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) {
        continue;
      }
      if (entity.readAsStringSync().contains(needle)) {
        return true;
      }
    }
    return false;
  }

  test('iOS Info.plist declares media usage keys for used ImageSources', () {
    expect(libDir.existsSync(), isTrue,
        reason: 'lib/ must exist to scan for ImageSource usage');
    expect(plistFile.existsSync(), isTrue,
        reason: 'BUG-531/TODO-1020 fix lives in this Info.plist');

    final String plist = plistFile.readAsStringSync();
    final bool usesCamera = libUses('ImageSource.camera');
    final bool usesGallery = libUses('ImageSource.gallery');

    if (usesCamera) {
      expect(
        plist.contains('<key>NSCameraUsageDescription</key>'),
        isTrue,
        reason: 'BUG-531/TODO-1020: lib/ opens ImageSource.camera but '
            'ios/Runner/Info.plist is missing NSCameraUsageDescription; iOS '
            'hard-crashes (SIGABRT) the first time the camera is accessed',
      );
    }

    if (usesGallery) {
      expect(
        plist.contains('<key>NSPhotoLibraryUsageDescription</key>'),
        isTrue,
        reason: 'BUG-531/TODO-1020: lib/ opens ImageSource.gallery but '
            'ios/Runner/Info.plist is missing NSPhotoLibraryUsageDescription; '
            'iOS hard-crashes (SIGABRT) the first time the photo library is '
            'accessed',
      );
    }
  });
}
