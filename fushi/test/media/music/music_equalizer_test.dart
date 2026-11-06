import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/music_crossfade.dart';
import 'package:fushi/src/media/music/music_equalizer.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_signal_path.dart';

/// 图示均衡器（P5，可选）：`af` 链形态、与交叉淡入拼链、信号路径判定。真 libmpv 上的增益 /
/// 关时逐样本不变见 music_equalizer_real_test.dart。
void main() {
  List<double> gains(Map<int, double> at) => <double>[
    for (final int hz in kMusicEqualizerBandsHz) at[hz] ?? 0,
  ];

  test('关 / 平直：不挂任何滤镜（bit-perfect 不受影响）', () {
    expect(musicEqualizerAf(const MusicEqualizerSettings()), isNull);
    expect(
      musicEqualizerAf(const MusicEqualizerSettings(enabled: true)),
      isNull,
    );
    expect(
      musicEqualizerAf(
        MusicEqualizerSettings(gainsDb: gains(<int, double>{1000: 6})),
      ),
      isNull,
      reason: '开关关着时有增益也不挂',
    );
  });

  test('开：带标签的 lavfi 链，余量 = 最大提升量，只挂非 0 段，双精度', () {
    final String af = musicEqualizerAf(
      MusicEqualizerSettings(
        enabled: true,
        gainsDb: gains(<int, double>{62: -3, 1000: 6, 8000: 2.5}),
      ),
    )!;
    expect(
      af,
      '@fushi-eq:lavfi=[volume=volume=-6.00dB:precision=double,'
      'equalizer=f=62:t=o:w=1:g=-3.00:precision=f64,'
      'equalizer=f=1000:t=o:w=1:g=6.00:precision=f64,'
      'equalizer=f=8000:t=o:w=1:g=2.50:precision=f64]',
    );
    // 只衰减不提升：不需要余量。
    expect(
      musicEqualizerAf(
        MusicEqualizerSettings(
          enabled: true,
          gainsDb: gains(<int, double>{31: -4}),
        ),
      ),
      '@fushi-eq:lavfi=[equalizer=f=31:t=o:w=1:g=-4.00:precision=f64]',
    );
  });

  test('偏好串解析：坏值 / 段数不对回平直；越界夹到 ±12', () {
    expect(MusicEqualizerSettings.parseGains(''), everyElement(0));
    expect(MusicEqualizerSettings.parseGains('1,2,3'), everyElement(0));
    expect(
      MusicEqualizerSettings.parseGains('0,0,0,0,0,x,0,0,0,0'),
      everyElement(0),
    );
    final List<double> g = MusicEqualizerSettings.parseGains(
      '20,-20,0,0,0,1.5,0,0,0,0',
    );
    expect(g.take(2), <double>[12, -12]);
    expect(g[5], 1.5);
    expect(
      MusicEqualizerSettings.parseGains(MusicEqualizerSettings.encodeGains(g)),
      g,
    );
  });

  test('与交叉淡入拼成同一条逐文件链；两种标签都能从 af 里剥掉', () {
    final String eq = musicEqualizerAf(
      MusicEqualizerSettings(
        enabled: true,
        gainsDb: gains(<int, double>{1000: 3}),
      ),
    )!;
    final String combined = musicComposeAf(<String?>[
      eq,
      musicCrossfadeAf(fadeIn: const Duration(seconds: 2)),
    ]);
    expect(combined, startsWith('$eq,'));
    expect(musicAfHasEqualizer(combined), isTrue);
    expect(
      musicStripEqualizerFilters(musicStripCrossfadeFilters(combined)),
      '',
    );
    expect(
      musicStripEqualizerFilters('$eq,lavfi=[highpass=f=20]'),
      'lavfi=[highpass=f=20]',
    );
    expect(musicComposeAf(<String?>[null, '', null]), '');
  });

  test('信号路径：均衡器挂着即一环、判非 bit-perfect', () {
    const MusicAudioFormat f = MusicAudioFormat(
      format: 's16',
      sampleRate: 44100,
      channelCount: 2,
    );
    MusicSignalPathSnapshot snap({required bool eq}) => MusicSignalPathSnapshot(
      platform: MusicOutputPlatform.windows,
      decoded: f,
      output: f,
      currentAo: 'wasapi',
      exclusiveRequested: true,
      equalizer: eq,
    );
    expect(judgeMusicSignalPath(snap(eq: false)).isBitPerfect, isTrue);
    final MusicSignalPathVerdict v = judgeMusicSignalPath(snap(eq: true));
    expect(v.isBitPerfect, isFalse);
    expect(v.stages, <MusicSignalStage>[MusicSignalStage.equalizer]);
  });

  test('输出设置相等性包含均衡器（改了才重新下发）', () {
    const MusicOutputSettings a = MusicOutputSettings(
      gapless: true,
      replayGain: MusicReplayGainMode.off,
    );
    final MusicOutputSettings b = a.copyWith(
      equalizer: MusicEqualizerSettings(
        enabled: true,
        gainsDb: gains(<int, double>{1000: 1}),
      ),
    );
    expect(a == b, isFalse);
    expect(b == a.copyWith(equalizer: b.equalizer), isTrue);
  });
}
