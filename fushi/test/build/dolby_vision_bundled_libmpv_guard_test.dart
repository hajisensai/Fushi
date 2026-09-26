import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_hdr_output.dart';

/// BUG-2691：macOS / iOS / Android 不再提示「杜比视界 P5 画不对」，前提是随包 libmpv
/// 带 `mpv-gl-dovi-p5.patch`（gl_video 的 DV 重整）。这个前提在 Dart 里看不见——
/// 谁把 Makefile / build.gradle 换回没打补丁的产物，紫绿反色就会静默回来、提示也
/// 不再出现。所以把 [textureRendererReshapesDolbyVision] 与产物名钉在一起：
/// 带补丁的产物名一律带 `-dovi` 后缀，去掉后缀就必须同步改回 Dart 判断。
void main() {
  String read(String path) => File(path).readAsStringSync();

  test('macOS / iOS xcframework 是带 DV 重整补丁的产物', () {
    for (final String plat in <String>['macos', 'ios']) {
      final String mk = read(
        '../third_party/media_kit_libs_${plat}_video/$plat/Makefile',
      );
      final RegExpMatch? version = RegExp(
        r'^MPV_XCFRAMEWORKS_VERSION=(\S+)$',
        multiLine: true,
      ).firstMatch(mk);
      expect(version, isNotNull, reason: plat);
      expect(
        version!.group(1),
        endsWith('-dovi'),
        reason:
            '$plat：产物名去掉 -dovi 说明换回了没打补丁的 libmpv，'
            'textureRendererReshapesDolbyVision(isApple) 必须同步改回 false',
      );
    }
    expect(
      textureRendererReshapesDolbyVision(isApple: true, isAndroid: false),
      isTrue,
    );
  });

  test('Android jar 全部是带 DV 重整补丁的产物', () {
    final String gradle = read(
      '../third_party/media_kit_libs_android_video/android/build.gradle',
    );
    final List<String> jars = RegExp(
      r'"url": "[^"]*/vendor-libmpv/(libmpv-android-full-[\w.-]+\.jar)"',
    ).allMatches(gradle).map((RegExpMatch m) => m.group(1)!).toList();
    expect(jars, hasLength(4), reason: '四个 ABI 各一个 jar');
    for (final String jar in jars) {
      expect(jar, endsWith('-dovi.jar'), reason: jar);
    }
    expect(
      textureRendererReshapesDolbyVision(isApple: false, isAndroid: true),
      isTrue,
    );
  });
}
