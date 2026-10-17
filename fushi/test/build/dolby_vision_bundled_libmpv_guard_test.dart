import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_hdr_output.dart';

import '../helpers/android_vendored_libmpv.dart';
import '../helpers/darwin_vendored_libmpv.dart';

/// BUG-2691：macOS / iOS / Android 不再提示「杜比视界 P5 画不对」，前提是随包 libmpv
/// 带 `mpv-gl-dovi-p5.patch`（gl_video 的 DV 重整）。这个前提在 Dart 里看不见——
/// 谁把 Makefile / build.gradle 换回没打补丁的产物，紫绿反色就会静默回来、提示也
/// 不再出现。所以把 [textureRendererReshapesDolbyVision] 与产物绑定：
/// Darwin 和 Android 都核对真实包、补丁 provenance 以及每个 CPU 的 GL shader。
void main() {
  test('macOS / iOS xcframework 是带 DV 重整补丁的产物', () {
    for (final String platform in <String>['macos', 'ios']) {
      for (final DarwinLibmpvSlice slice in verifiedDarwinLibmpv(platform)) {
        // These are gl_video P5 uniforms; gpu-next's generic DOVI support
        // cannot satisfy this renderer contract.
        expect(
          slice.mpv,
          contains('dv_poly_%d_%d'),
          reason: '${slice.platform}/${slice.identity}',
        );
        expect(
          slice.mpv,
          contains('dv_mmr_k_%d_%d'),
          reason: '${slice.platform}/${slice.identity}',
        );
      }
    }
    expect(
      textureRendererReshapesDolbyVision(isApple: true, isAndroid: false),
      isTrue,
    );
  });

  test('Android jar 全部是带 DV 重整补丁的产物', () {
    for (final ({String abi, String contents}) artifact
        in verifiedAndroidLibmpv()) {
      // These uniforms belong to the gl_video P5 patch, not libplacebo's
      // independently compiled gpu-next implementation.
      expect(
        artifact.contents,
        contains('dv_poly_%d_%d'),
        reason: artifact.abi,
      );
      expect(
        artifact.contents,
        contains('dv_mmr_k_%d_%d'),
        reason: artifact.abi,
      );
    }
    expect(
      textureRendererReshapesDolbyVision(isApple: false, isAndroid: true),
      isTrue,
    );
  });
}
