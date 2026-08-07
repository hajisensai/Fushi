import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/audio_energy_probe.dart';

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

    test('归一化到 0..1：min->0，max->1（线性振幅域，非线性拉伸 dB）', () {
      // 3 帧 3 桶，每桶单帧峰值即帧值。归一化在**线性振幅**域做（先 dB->10^(dB/20)）：
      // -30dB->0.03162, -20dB->0.1, -10dB->0.31623。桶数<=2 时分位落到最大值，退化为
      // min/max 归一化：min=0.03162 -> 0，max=0.31623 -> 1，中间桶按线性振幅比例落点。
      final List<double> out =
          downsampleEnergyEnvelope(<double>[-30, -20, -10], 3);
      expect(out.length, 3);
      expect(out[0], closeTo(0.0, 1e-6)); // 最小振幅 -> 地基 0
      // (0.1 - 0.03162) / (0.31623 - 0.03162) = 0.24025（不是线性拉伸 dB 的 0.5）。
      expect(out[1], closeTo(0.24025, 1e-4));
      expect(out[2], closeTo(1.0, 1e-6)); // 最大振幅 -> 顶 1
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

  group('dbToLinearAmplitude（TODO-1244 波形密度根因）', () {
    test('0dB=满刻度 1.0；每 -20dB 掉一个数量级', () {
      expect(dbToLinearAmplitude(0.0), closeTo(1.0, 1e-12));
      expect(dbToLinearAmplitude(-20.0), closeTo(0.1, 1e-9));
      expect(dbToLinearAmplitude(-40.0), closeTo(0.01, 1e-9));
      expect(dbToLinearAmplitude(-6.020599913), closeTo(0.5, 1e-6)); // -6dB≈半幅
    });

    test('静音底（-120dB）塌到接近 0', () {
      expect(dbToLinearAmplitude(-120.0), closeTo(1e-6, 1e-9));
      expect(dbToLinearAmplitude(-120.0), lessThan(0.001));
    });

    test('单调：越响振幅越大', () {
      expect(
          dbToLinearAmplitude(-10.0), greaterThan(dbToLinearAmplitude(-30.0)));
    });
  });

  group('波形对比：句间静音可辨（TODO-1244）', () {
    test('中等安静段（-50dB）在线性域接近底部，而非线性拉伸 dB 的半高', () {
      // 静音 -80dB / 中等 -50dB / 语音 -20dB 三桶。
      // 线性拉伸 dB（旧）会把 -50dB 画成 0.5（半高，看着像有声）；线性振幅域（新）把它
      // 压到 ~0.03——安静段贴地、语音尖峰凸出，句子边界可辨。
      final List<double> out =
          downsampleEnergyEnvelope(<double>[-80, -50, -20], 3);
      expect(out.length, 3);
      expect(out[0], closeTo(0.0, 1e-3)); // 静音 -> 地基
      expect(out[1], lessThan(0.1)); // 中等安静段远低于旧的 0.5
      expect(out[2], closeTo(1.0, 1e-6)); // 语音 -> 顶
    });

    test('纯静音（全 -120dB）画平：全 0，不被归一化放大到满高', () {
      final List<double> out =
          downsampleEnergyEnvelope(List<double>.filled(20, -120.0), 8);
      expect(out, List<double>.filled(8, 0.0));
    });
  });

  group('离群瞬态抑制：单个爆音不压垮语音（TODO-1244）', () {
    test('高分位上限让语音仍占满高，不被单个 0dB 尖峰压成一线', () {
      // 400 帧 -> 200 桶：2 帧静音(-80) + 396 帧语音(-25) + 2 帧爆音(0dB)。
      final List<double> frames = <double>[
        -80,
        -80,
        ...List<double>.filled(396, -25.0),
        0.0,
        0.0,
      ];
      final List<double> out = downsampleEnergyEnvelope(frames, 200);
      expect(out.length, 200);
      // 静音桶贴地。
      expect(out.first, closeTo(0.0, 1e-3));
      // 语音桶（中段）仍接近满高——若用绝对峰值(0dB)归一化会被压到 ~0.05。
      expect(out[100], greaterThan(0.9));
      // 爆音桶 clamp 到 1.0（不越界）。
      expect(out.last, closeTo(1.0, 1e-9));
      for (final double v in out) {
        expect(v, greaterThanOrEqualTo(0.0));
        expect(v, lessThanOrEqualTo(1.0));
      }
    });

    test('normalizeCeilingPercentile=1.0 退化为绝对峰值归一化（语音被爆音压低）', () {
      final List<double> frames = <double>[
        ...List<double>.filled(398, -25.0),
        0.0,
        0.0,
      ];
      final List<double> out = downsampleEnergyEnvelope(
        frames,
        200,
        normalizeCeilingPercentile: 1.0,
      );
      // 绝对峰值(0dB=1.0)当上限：语音(-25dB≈0.056)被压到很低。
      expect(out[100], lessThan(0.1));
    });
  });
}
