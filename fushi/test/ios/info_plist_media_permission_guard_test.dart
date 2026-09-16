import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../helpers/scan_scale.dart';

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
/// BUG-641: iOS 27 also aborts the process when the audiobook/audio import
/// path opens `FilePicker` with `FileType.audio` unless Info.plist declares
/// `NSAppleMusicUsageDescription`.
///
/// The actual crash is an OS-level assertion (can't run here), so this guards
/// the *contract*: if any Dart source under `lib/` still reaches for a given
/// [ImageSource] but Info.plist drops its usage key, this test goes red.
void main() {
  // Tests run with CWD = `fushi/`.
  final Directory libDir = Directory('lib');
  final File plistFile = File('ios/Runner/Info.plist');

  // libUses 命中即短路返回，数不出扫描规模，所以枚举面单独抽出来——它是这条守卫
  // 唯一的输入，塌成空集时 `libUses` 恒 false，两条 test 都会静默全绿。
  List<File> scannedDartFiles() => libDir
      .listSync(recursive: true)
      .whereType<File>()
      .where((File f) => f.path.endsWith('.dart'))
      .toList();

  bool libUses(String needle) {
    for (final File entity in scannedDartFiles()) {
      if (entity.readAsStringSync().contains(needle)) {
        return true;
      }
    }
    return false;
  }

  test('扫描规模哨兵：lib/ 确实被枚举到了', () {
    expectScanScale(scannedDartFiles().length,
        what: 'lib/ 下的 .dart', atLeast: 750, measured: 939);
  });

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

  test(
      'BUG-2558: iOS Info.plist declares background audio when audio_service '
      'is wired', () {
    // 与本文件其余几条同形（「lib/ 用了某能力 → plist 必须声明」），但后果不是
    // SIGABRT 而是**静默失效**：缺 UIBackgroundModes/audio 时 iOS 在 app 进后台那
    // 一刻挂起进程，有声书立刻断声——锁屏听书、控制中心播放控件、Now Playing 全部
    // 形同虚设，而「后台播放有声书时照常计学习统计」这条行为更是以它为前提（进程被
    // 挂起就没有播放态可言）。静默失效比崩溃更难发现，所以钉在这里。
    expect(libDir.existsSync(), isTrue,
        reason: 'lib/ must exist to scan for audio_service wiring');
    expect(plistFile.existsSync(), isTrue,
        reason: 'BUG-2558 fix lives in this Info.plist');

    final String plist = plistFile.readAsStringSync();
    final bool wiresAudioService = libUses('AudioService.init');

    if (wiresAudioService) {
      final int modesIdx = plist.indexOf('<key>UIBackgroundModes</key>');
      expect(
        modesIdx,
        isNonNegative,
        reason: 'BUG-2558: lib/ wires audio_service (AudioService.init) but '
            'ios/Runner/Info.plist is missing UIBackgroundModes; iOS suspends '
            'the process on backgrounding, so audiobook playback dies the '
            'moment the app leaves the foreground',
      );
      // 只断言「声明了 audio」，不锁整个数组——将来加别的后台模式不该让这条红。
      final int arrayEnd = plist.indexOf('</array>', modesIdx);
      expect(arrayEnd, isNonNegative, reason: 'UIBackgroundModes 必须是 <array>');
      expect(
        plist.substring(modesIdx, arrayEnd).contains('<string>audio</string>'),
        isTrue,
        reason: 'BUG-2558: UIBackgroundModes 必须含 audio 一项',
      );
    }
  });

  test('iOS Info.plist declares Apple Music usage when audio files are picked',
      () {
    expect(libDir.existsSync(), isTrue,
        reason: 'lib/ must exist to scan for FileType.audio usage');
    expect(plistFile.existsSync(), isTrue,
        reason: 'BUG-641 fix lives in this Info.plist');

    final String plist = plistFile.readAsStringSync();
    final bool usesAudioPicker = libUses('FileType.audio');

    if (usesAudioPicker) {
      expect(
        plist.contains('<key>NSAppleMusicUsageDescription</key>'),
        isTrue,
        reason: 'BUG-641: lib/ opens FilePicker with FileType.audio but '
            'ios/Runner/Info.plist is missing NSAppleMusicUsageDescription; '
            'iOS hard-crashes (SIGABRT/TCC) the first time audio import '
            'requests media access',
      );
    }
  });
}
