import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_hdr_output.dart';

import '../helpers/android_vendored_libmpv.dart';
import '../helpers/darwin_vendored_libmpv.dart';

/// BUG-2691：Windows / macOS / iOS / Android 不再提示「杜比视界 P5 画不对」，前提是
/// 随包 libmpv 带 `mpv-gl-dovi-p5.patch`（gl_video 的 DV 重整）。这个前提在 Dart 里
/// 看不见——谁把 CMakeLists / Makefile / build.gradle 换回没打补丁的产物，紫绿反色就会
/// 静默回来、提示也不再出现（Windows 更没有别的渲染器可退：gpu-next 宿主窗已删除）。
/// 所以把 [textureRendererReshapesDolbyVision] 与产物绑定：Darwin 和 Android 核对真实
/// 包里每个 CPU 的 GL shader；Windows 的 7z 归档 Dart 解不开，核对构建脚本、打包
/// provenance 记录的补丁散列与 CMake 钉住的 `-dovi1` 产物（真像素门在
/// `tool/bluray/verify_dovi_p5.py`，`build_libmpv.ps1` 每次重编都跑）。
void main() {
  test('Windows libmpv 是带 DV 重整补丁的产物', () {
    const String pkg = '../third_party/media_kit_libs_windows_video';
    final File patch = File(
      '../tool/bluray/platforms/patches/mpv-gl-dovi-p5.patch',
    );
    final String script = File(
      '../tool/bluray/build_libmpv.ps1',
    ).readAsStringSync();
    expect(
      script,
      contains(r'tool\bluray\platforms\patches\mpv-gl-dovi-p5.patch'),
    );
    expect(script, contains('verify_dovi_p5.py'));
    final Map<String, dynamic> provenance =
        jsonDecode(
              File('$pkg/native-source-provenance.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
    expect(
      (provenance['render_patches']
          as Map<String, dynamic>)['mpv-gl-dovi-p5.patch'],
      sha256.convert(patch.readAsBytesSync()).toString(),
      reason:
          'mpv-gl-dovi-p5.patch changed without rebuilding and re-vendoring '
          'Windows libmpv (tool/bluray/build_libmpv.ps1)',
    );
    final String cmake = File('$pkg/windows/CMakeLists.txt').readAsStringSync();
    final RegExpMatch? archive = RegExp(
      r'set\(LIBMPV "([^"]+)"\)',
    ).firstMatch(cmake);
    expect(archive, isNotNull);
    expect(archive!.group(1), contains('-dovi1'));
    expect(File('$pkg/vendored/${archive.group(1)}').existsSync(), isTrue);
    expect(
      textureRendererReshapesDolbyVision(
        isWindows: true,
        isApple: false,
        isAndroid: false,
      ),
      isTrue,
    );
  });

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
      textureRendererReshapesDolbyVision(
        isWindows: false,
        isApple: true,
        isAndroid: false,
      ),
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
      textureRendererReshapesDolbyVision(
        isWindows: false,
        isApple: false,
        isAndroid: true,
      ),
      isTrue,
    );
  });
}
