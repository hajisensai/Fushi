import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_subtitle_overlay.dart';

/// BUG-742：听力沉浸「模糊态」的高斯模糊强度守卫。
///
/// 旧实现把 sigma 硬编码为绝对 8px（与字号无关），字号调大后字仍读得清 →「模糊度不够」。
/// 修复把 sigma 改成随字号缩放的纯函数 [VideoSubtitleOverlay.obscureBlurSigma]，本测试
/// 把「随字号单调递增 + 默认字号显著强于旧的 8 + 小字号有下限 + 比例正确」钉成不变式，
/// 防止有人再退回固定值。
void main() {
  group('VideoSubtitleOverlay.obscureBlurSigma', () {
    test('默认字号 36 时明显强于旧的固定 8px', () {
      final double sigma = VideoSubtitleOverlay.obscureBlurSigma(36);
      expect(sigma, greaterThan(8),
          reason: '默认字号下的模糊必须比旧值 8 更强，否则仍读得出（BUG-742）');
      // 36×0.45 = 16.2
      expect(sigma, closeTo(16.2, 1e-9));
    });

    test('随字号单调递增：字号越大糊得越狠', () {
      final double small = VideoSubtitleOverlay.obscureBlurSigma(30);
      final double mid = VideoSubtitleOverlay.obscureBlurSigma(48);
      final double large = VideoSubtitleOverlay.obscureBlurSigma(72);
      expect(mid, greaterThan(small));
      expect(large, greaterThan(mid));
      // 48×0.45 = 21.6，72×0.45 = 32.4
      expect(mid, closeTo(21.6, 1e-9));
      expect(large, closeTo(32.4, 1e-9));
    });

    test('小字号取下限 12（保证再小也真糊掉）', () {
      // 20×0.45 = 9 < 12 → 下限 12
      expect(VideoSubtitleOverlay.obscureBlurSigma(20), 12);
      expect(VideoSubtitleOverlay.obscureBlurSigma(10), 12);
      // 下限拐点：fontSize=12/0.45≈26.67，略高于此走比例
      expect(VideoSubtitleOverlay.obscureBlurSigma(28), closeTo(12.6, 1e-9));
    });

    test('比例恒为 0.45（大字号未被上限截断）', () {
      for (final double fontSize in <double>[36, 48, 60, 100]) {
        expect(VideoSubtitleOverlay.obscureBlurSigma(fontSize),
            closeTo(fontSize * 0.45, 1e-9),
            reason: '$fontSize 的 sigma 应等于 fontSize×0.45');
      }
    });
  });
}
