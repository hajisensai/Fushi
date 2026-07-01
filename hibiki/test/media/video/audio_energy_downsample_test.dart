import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/audio_energy_probe.dart';

/// TODO-1051 阶段A：波形包络「纯降采样函数」单测。
///
/// 覆盖：桶数正确、桶内取峰值、归一化到 0..1、退化输入（空/单帧/桶数>帧数/桶数<=0）
/// 不崩且 sane、幂等。全为纯计算，headless 可跑，不碰 UI / IO / 持久化。
void main() {
  group('downsampleEnergyEnvelope', () {
    test('桶数 < 帧数：输出长度恰为 targetBuckets', () {
      final List<double> frames =
          List<double>.generate(1000, (int i) => i.toDouble());
      expect(downsampleEnergyEnvelope(frames, 100).length, 100);
      expect(downsampleEnergyEnvelope(frames, 37).length, 37);
      expect(downsampleEnergyEnvelope(frames, 1).length, 1);
    });

    test('桶内取峰值（保留瞬态，非平均/RMS）', () {
      // 8 帧 -> 2 桶：桶0=frames[0..4)，桶1=frames[4..8)。
      // 每桶埋一个尖峰，峰值应被保留而非被同桶低值拉平。
      final List<double> frames = <double>[
        -50, -10, -60, -55, // 桶0 峰值 -10
        -70, -80, -20, -75, // 桶1 峰值 -20
      ];
      final List<double> out = downsampleEnergyEnvelope(frames, 2);
      expect(out.length, 2);
      // 峰值 -10 > -20 -> 归一化后桶0=1.0（最大），桶1=0.0（最小）。
      expect(out[0], 1.0);
      expect(out[1], 0.0);
    });

    test('归一化到 0..1：min->0，max->1，中间线性', () {
      // 3 帧 3 桶，每桶单帧峰值即帧值：-30,-20,-10 -> range=20。
      final List<double> out =
          downsampleEnergyEnvelope(<double>[-30, -20, -10], 3);
      expect(out.length, 3);
      expect(out[0], closeTo(0.0, 1e-9)); // (-30 - -30)/20
      expect(out[1], closeTo(0.5, 1e-9)); // (-20 - -30)/20
      expect(out[2], closeTo(1.0, 1e-9)); // (-10 - -30)/20
      for (final double v in out) {
        expect(v, greaterThanOrEqualTo(0.0));
        expect(v, lessThanOrEqualTo(1.0));
      }
    });

    test('每桶跨多帧时仍夹在 0..1', () {
      final List<double> frames =
          List<double>.generate(500, (int i) => -120.0 + (i % 90));
      final List<double> out = downsampleEnergyEnvelope(frames, 64);
      expect(out.length, 64);
      for (final double v in out) {
        expect(v, greaterThanOrEqualTo(0.0));
        expect(v, lessThanOrEqualTo(1.0));
      }
      // 至少有一个桶达到峰 1.0 与一个桶落到 0.0（min/max 拉满）。
      expect(out.reduce((double a, double b) => a > b ? a : b), 1.0);
      expect(out.reduce((double a, double b) => a < b ? a : b), 0.0);
    });

    group('退化输入 sane（不抛、不越界）', () {
      test('空输入 -> []', () {
        expect(downsampleEnergyEnvelope(const <double>[], 100), isEmpty);
      });

      test('targetBuckets = 0 -> []', () {
        expect(downsampleEnergyEnvelope(<double>[-10, -20], 0), isEmpty);
      });

      test('targetBuckets < 0 -> []', () {
        expect(downsampleEnergyEnvelope(<double>[-10, -20], -5), isEmpty);
      });

      test('单帧输入：任意正桶数都收敛到长度 1', () {
        expect(downsampleEnergyEnvelope(<double>[-42.0], 1), <double>[0.0]);
        expect(downsampleEnergyEnvelope(<double>[-42.0], 100), <double>[0.0]);
      });

      test('targetBuckets > 帧数：每帧一桶，不上采样补桶', () {
        final List<double> out =
            downsampleEnergyEnvelope(<double>[-30, -20, -10], 1000);
        expect(out.length, 3); // 收敛到帧数，不产出 1000 桶
        expect(out[0], closeTo(0.0, 1e-9));
        expect(out[2], closeTo(1.0, 1e-9));
      });

      test('targetBuckets == 帧数：每帧一桶', () {
        final List<double> out =
            downsampleEnergyEnvelope(<double>[-30, -20, -10], 3);
        expect(out.length, 3);
      });

      test('全同值（含全静音）：不除零，输出全 0', () {
        expect(
          downsampleEnergyEnvelope(<double>[-120, -120, -120, -120], 2),
          <double>[0.0, 0.0],
        );
        expect(
          downsampleEnergyEnvelope(List<double>.filled(50, -7.5), 10),
          List<double>.filled(10, 0.0),
        );
      });
    });

    test('幂等：同输入恒定同输出', () {
      final List<double> frames =
          List<double>.generate(777, (int i) => -100.0 + (i * 0.37) % 60);
      final List<double> a = downsampleEnergyEnvelope(frames, 120);
      final List<double> b = downsampleEnergyEnvelope(frames, 120);
      expect(a, b);
      // 不修改入参。
      expect(frames.length, 777);
    });
  });
}
