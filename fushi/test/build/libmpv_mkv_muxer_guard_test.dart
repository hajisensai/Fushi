import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-2939（#1953）：在线视频制卡的缓冲副本（`snapshotCachedRange` → mpv
/// `dump-cache` 写 `.mkv`）要 libavformat 的 matroska muxer。上游 full flavor 把
/// muxer 全关了，Android / iOS / macOS 每次都报 `Output format not found`，失败又被
/// 静默吞掉回到远端抽取——缺了它不会有任何红，只是优化永远不生效。所以自编产物带
/// `--enable-muxer=matroska`，产物名一律带 `mkvmux`；谁换回不带 muxer 的产物，
/// 这里先红。Windows 的 `libmpv-2.dll` 是完整构建，本来就带。
void main() {
  String read(String path) => File(path).readAsStringSync();

  test('macOS / iOS xcframework 带 matroska muxer', () {
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
        contains('mkvmux'),
        reason:
            '$plat：产物名不带 mkvmux 说明换回了没有 matroska muxer 的 libmpv，'
            'dump-cache 会恒失败',
      );
    }
  });

  test('Android 四个 ABI 的 jar 都带 matroska muxer', () {
    final String gradle = read(
      '../third_party/media_kit_libs_android_video/android/build.gradle',
    );
    final List<String> jars = RegExp(
      r'"url": "[^"]*/vendor-libmpv/(libmpv-android-full-[\w.-]+\.jar)"',
    ).allMatches(gradle).map((RegExpMatch m) => m.group(1)!).toList();
    expect(jars, hasLength(4), reason: '四个 ABI 各一个 jar');
    for (final String jar in jars) {
      expect(jar, contains('-mkvmux-'), reason: jar);
    }
  });
}
