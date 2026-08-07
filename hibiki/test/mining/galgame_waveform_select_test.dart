import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/galgame_waveform_select.dart';

/// galgame 波形选区纯函数单测（docs/specs/galgame-mining A5）：
/// 像素 ↔ 毫秒往返映射 + VAD 默认框。纯逻辑，无 widget pump。
void main() {
  group('pixelToMs / msToPixel', () {
    test('往返一致（误差 < 1 像素对应的毫秒粒度）', () {
      const double width = 300.0;
      const int total = 5000;
      // 1 像素 ≈ total/width 毫秒，round 引入至多半像素误差，容差取一个像素粒度。
      const double toleranceMs = total / width + 1;
      for (final int ms in <int>[0, 137, 1000, 2499, 2500, 4999, 5000]) {
        final double x = msToPixel(ms, width, total);
        final int back = pixelToMs(x, width, total);
        expect((back - ms).abs(), lessThanOrEqualTo(toleranceMs),
            reason: 'ms=$ms -> x=$x -> back=$back 往返漂移过大');
      }
    });

    test('像素端点映射到毫秒端点并 clamp 出界输入', () {
      const double width = 200.0;
      const int total = 4000;
      expect(pixelToMs(0, width, total), 0);
      expect(pixelToMs(width, width, total), total);
      // 出界像素 clamp 到 [0, total]。
      expect(pixelToMs(-15, width, total), 0);
      expect(pixelToMs(width + 50, width, total), total);
      // 出界毫秒 clamp 到 [0, width]。
      expect(msToPixel(-100, width, total), 0.0);
      expect(msToPixel(total + 100, width, total), width);
    });

    test('退化输入返回 0', () {
      expect(pixelToMs(10, 0, 1000), 0);
      expect(pixelToMs(10, -5, 1000), 0);
      expect(pixelToMs(10, 300, 0), 0);
      expect(pixelToMs(10, 300, -1), 0);
      expect(msToPixel(100, 0, 1000), 0.0);
      expect(msToPixel(100, -5, 1000), 0.0);
      expect(msToPixel(100, 300, 0), 0.0);
      expect(msToPixel(100, 300, -1), 0.0);
    });
  });

  group('defaultVadRange', () {
    const int windowMs = 20;

    test('前静后响：默认框落在尾部响区', () {
      // 50 帧 -100dB 静音 + 10 帧 -10dB 语音，total = 60 帧 × 20ms = 1200ms。
      final List<double> frames = <double>[
        ...List<double>.filled(50, -100.0),
        ...List<double>.filled(10, -10.0),
      ];
      const int total = 60 * windowMs;
      final GalWaveformRange r = defaultVadRange(
        frames,
        windowMs: windowMs,
        totalDurationMs: total,
      );
      // 峰值 -10，阈值 = max(-30, -40) = -30，响区 = 帧 50..59。
      expect(r.startMs, 50 * windowMs);
      expect(r.endMs, total);
    });

    test('多段响区：只取最后一段', () {
      // 10 响 + 20 静 + 5 响 + 10 静，total = 45 帧 × 20ms = 900ms。
      final List<double> frames = <double>[
        ...List<double>.filled(10, -10.0),
        ...List<double>.filled(20, -100.0),
        ...List<double>.filled(5, -12.0),
        ...List<double>.filled(10, -100.0),
      ];
      const int total = 45 * windowMs;
      final GalWaveformRange r = defaultVadRange(
        frames,
        windowMs: windowMs,
        totalDurationMs: total,
      );
      // 最后一段响区 = 帧 30..34 → [600, 700)。
      expect(r.startMs, 30 * windowMs);
      expect(r.endMs, 35 * windowMs);
    });

    test('全静音：fail-open 返回全段', () {
      final List<double> frames = List<double>.filled(60, -100.0);
      const int total = 60 * windowMs;
      final GalWaveformRange r = defaultVadRange(
        frames,
        windowMs: windowMs,
        totalDurationMs: total,
      );
      // 峰值 -100，阈值 = max(-120, -40) = -40，无帧过阈 → 全段。
      expect(r.startMs, 0);
      expect(r.endMs, total);
    });

    test('空帧 / 非法 windowMs：fail-open 返回全段', () {
      final GalWaveformRange empty = defaultVadRange(
        const <double>[],
        windowMs: windowMs,
        totalDurationMs: 1200,
      );
      expect(empty.startMs, 0);
      expect(empty.endMs, 1200);

      final GalWaveformRange badWindow = defaultVadRange(
        List<double>.filled(10, -10.0),
        windowMs: 0,
        totalDurationMs: 1200,
      );
      expect(badWindow.startMs, 0);
      expect(badWindow.endMs, 1200);
    });

    test('末帧右界被 totalDurationMs clamp', () {
      // 3 帧全响，但 total 只有 50ms（< 3×20=60），endMs 不得超过 total。
      final List<double> frames = List<double>.filled(3, -10.0);
      final GalWaveformRange r = defaultVadRange(
        frames,
        windowMs: windowMs,
        totalDurationMs: 50,
      );
      expect(r.startMs, 0);
      expect(r.endMs, 50);
    });
  });
}
