import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// BUG-3296 source guard: Windows libmpv must carry the vo=gpu dumb-mode crop fix.
///
/// 画质增强「无」= 全 bilinear + linear/sigmoid/correct scaling 全关 + 无着色器，
/// 正好命中 mpv 的 dumb mode；上游 `pass_render_frame_dumb()` 按图像尺寸而不是
/// 映射平面尺寸算源变换，d3d11va 零拷贝的 1920x1088 解码面就被整张压进 1080 行
/// （底部 8 行编码填充进画面、纵向压扁 1080/1088）。修复在本仓自编 libmpv 的
/// `patches/gpu-dumb-mode-hwdec-crop.patch`。本守卫钉住：补丁内容、构建脚本应用它、
/// 打包产物的 provenance 记录与仓内补丁逐字节一致（换了补丁却没重编 / 重新 vendor
/// 会在这里红）。真像素验证：`tool/bluray/verify_hwdec_crop.py`（离屏、真 ANGLE +
/// 真 libmpv）与 `integration_test/video_hwdec_crop_probe_itest.dart`（真 app）。
void main() {
  const String pkg = '../third_party/media_kit_libs_windows_video';
  final File patch = File('$pkg/patches/gpu-dumb-mode-hwdec-crop.patch');

  test('patch sets the dumb-path texture size from the reference plane', () {
    expect(patch.existsSync(), isTrue);
    final String text = patch.readAsStringSync();
    expect(text, contains('+++ b/video/out/gpu/video.c'));
    // The hunk must sit in pass_render_frame_dumb, right before the source
    // transform is computed from p->texture_w/h.
    final int hunk = text.indexOf('pass_get_images(p, &p->image, img, off);');
    final int fixW = text.indexOf('+            p->texture_w = img[n].w;');
    final int fixH = text.indexOf('+            p->texture_h = img[n].h;');
    final int transform = text.indexOf('compute_src_transform(p, &transform);');
    expect(hunk, greaterThanOrEqualTo(0));
    expect(fixW, greaterThan(hunk));
    expect(fixH, greaterThan(fixW));
    expect(transform, greaterThan(fixH));
  });

  test('build script applies the patch after the navigation patch', () {
    final String script = File(
      '../tool/bluray/build_libmpv.ps1',
    ).readAsStringSync();
    final int nav = script.indexOf(r'patches\disc-navigation-state.patch');
    final int crop = script.indexOf(r'patches\gpu-dumb-mode-hwdec-crop.patch');
    expect(nav, greaterThanOrEqualTo(0));
    expect(crop, greaterThan(nav));
  });

  test('vendored build provenance records this exact patch', () {
    final Map<String, dynamic> provenance =
        jsonDecode(
              File('$pkg/native-source-provenance.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
    final Map<String, dynamic> renderPatches =
        provenance['render_patches'] as Map<String, dynamic>;
    expect(
      renderPatches['gpu-dumb-mode-hwdec-crop.patch'],
      sha256.convert(patch.readAsBytesSync()).toString(),
      reason:
          'patch changed without rebuilding and re-vendoring libmpv '
          '(tool/bluray/build_libmpv.ps1)',
    );
  });
}
