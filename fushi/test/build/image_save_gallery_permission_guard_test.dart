import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 长按图片「保存图片」写系统相册（gal）的平台契约：缺了这些声明，iOS 第一次
/// 写相册直接 SIGABRT（同 BUG-531 的隐私用途串），Android 10 及以下写公共
/// Pictures 目录静默失败——两者在本地与 CI 都是绿的，只在真机上炸。
void main() {
  // Tests run with CWD = `fushi/`.
  final String saver = File(
    'lib/src/utils/misc/image_file_saver.dart',
  ).readAsStringSync();

  test('保存实现确实在写系统相册（否则下面的契约失去意义）', () {
    expect(saver, contains('Gal.putImage('));
    expect(saver, contains('Gal.requestAccess('));
  });

  test('iOS Info.plist 声明「仅添加照片」用途串', () {
    final String plist = File('ios/Runner/Info.plist').readAsStringSync();
    expect(plist, contains('<key>NSPhotoLibraryAddUsageDescription</key>'));
  });

  test('iOS 不建相簿（建相簿要完整相册读写权限，只申请了仅添加）', () {
    expect(
      saver,
      contains(
        'album: platform == TargetPlatform.android ? kImageSaveAndroidAlbum : null',
      ),
    );
  });

  test('Android 10 及以下的写存储权限与分区存储豁免', () {
    final String manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync().replaceAll(RegExp(r'\s+'), ' ');
    expect(
      manifest,
      contains(
        '<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" '
        'android:maxSdkVersion="29" />',
      ),
    );
    expect(manifest, contains('android:requestLegacyExternalStorage="true"'));
  });
}
