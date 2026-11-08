import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/music_audio_effects.dart';
import 'package:fushi/src/media/music/music_audio_effects_prefs.dart';
import 'package:fushi/src/media/music/music_crossfade.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_signal_path.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';

/// 音效（P5，可选）：`af` 链形态（中性 = 不挂、各效果串、余量 / 限幅器取舍）、与交叉淡入
/// 拼链、strip / 识别、预设认定、偏好往返、信号路径判定。真 libmpv 上的增益 / 关与全部中性
/// 时逐样本不变见 music_audio_effects_real_test.dart。
void main() {
  List<double> gains(Map<int, double> at) => <double>[
    for (final int hz in kMusicEqualizerBandsHz) at[hz] ?? 0,
  ];

  String chainOf(MusicAudioEffects fx) {
    final String af = musicAudioEffectsAf(fx)!;
    expect(af, startsWith('@$kMusicEffectsLabel:lavfi=['));
    expect(af, endsWith(']'));
    return af.substring('@$kMusicEffectsLabel:lavfi=['.length, af.length - 1);
  }

  group('中性 = 不挂任何滤镜（bit-perfect 不动）', () {
    test('关着：哪怕各项都不中性', () {
      expect(
        musicAudioEffectsAf(
          MusicAudioEffects(
            gainsDb: gains(<int, double>{1000: 6}),
            preampDb: -3,
            bassDb: 4,
            balance: 0.5,
            mono: true,
            limiter: true,
          ),
        ),
        isNull,
      );
    });

    test('开着但全部中性；单开限幅器也不算生效', () {
      expect(
        musicAudioEffectsAf(const MusicAudioEffects(enabled: true)),
        isNull,
      );
      const MusicAudioEffects lim = MusicAudioEffects(
        enabled: true,
        limiter: true,
        bassHz: 60,
        trebleHz: 12000,
      );
      expect(lim.isNeutral, isTrue);
      expect(musicAudioEffectsAf(lim), isNull);
    });
  });

  test('只有衰减：不加余量、不挂限幅器', () {
    expect(
      chainOf(
        MusicAudioEffects(
          enabled: true,
          gainsDb: gains(<int, double>{62: -3, 8000: -2.5}),
        ),
      ),
      'aformat=sample_fmts=dblp,'
      'equalizer=f=62:t=o:w=1:g=-3.00:precision=f64,'
      'equalizer=f=8000:t=o:w=1:g=-2.50:precision=f64',
    );
  });

  test('单段提升：余量正好等于该段增益（峰值在中心频率上）', () {
    final MusicAudioEffects fx = MusicAudioEffects(
      enabled: true,
      gainsDb: gains(<int, double>{1000: 6}),
    );
    expect(musicAudioEffectsPeakGainDb(fx), closeTo(6, 0.01));
    expect(
      chainOf(fx),
      'aformat=sample_fmts=dblp,'
      'volume=volume=-6.00dB:precision=double,'
      'equalizer=f=1000:t=o:w=1:g=6.00:precision=f64',
    );
  });

  test('相邻两段同时提升：叠加峰值高于单段设定，余量按实际峰值让', () {
    final MusicAudioEffects fx = MusicAudioEffects(
      enabled: true,
      gainsDb: gains(<int, double>{500: 6, 1000: 6}),
    );
    final double peak = musicAudioEffectsPeakGainDb(fx);
    expect(peak, greaterThan(6.5));
    expect(peak, lessThan(12));
    expect(musicAudioEffectsAutoHeadroomDb(fx), closeTo(peak, 1e-9));
  });

  test('前级：限幅器关时只能往下压；正前级被余量吃掉，不会推过 0 dBFS', () {
    const MusicAudioEffects cut = MusicAudioEffects(
      enabled: true,
      preampDb: -4,
    );
    expect(
      chainOf(cut),
      'aformat=sample_fmts=dblp,volume=volume=-4.00dB:precision=double',
    );
    // +3 前级 + 6 dB 提升 → 总增益 −0（=前级 − (前级 + 峰值)）= −6 dB。
    final MusicAudioEffects boost = MusicAudioEffects(
      enabled: true,
      preampDb: 3,
      gainsDb: gains(<int, double>{1000: 6}),
    );
    expect(chainOf(boost), contains('volume=volume=-6.00dB'));
    expect(chainOf(boost), isNot(contains('alimiter')));
  });

  test('限幅器开：前级按设定值、不让余量，链尾挂 alimiter（不做自动电平）', () {
    final MusicAudioEffects fx = MusicAudioEffects(
      enabled: true,
      preampDb: 2,
      gainsDb: gains(<int, double>{1000: 6}),
      limiter: true,
    );
    final String c = chainOf(fx);
    expect(c, contains('volume=volume=2.00dB:precision=double'));
    expect(c, endsWith('alimiter=limit=0.988553:attack=5:release=50:level=0'));
    expect(musicAudioEffectsAutoHeadroomDb(fx), 0);
    // 开着限幅器但链路不可能过 0 dBFS（只有衰减）：不挂，免得白加前瞻延迟。
    expect(
      chainOf(
        const MusicAudioEffects(enabled: true, preampDb: -3, limiter: true),
      ),
      isNot(contains('alimiter')),
    );
  });

  test('低音 / 高音搁架：增益与转折频率进链，峰值 ≈ 搁架增益', () {
    const MusicAudioEffects fx = MusicAudioEffects(
      enabled: true,
      bassDb: 4,
      bassHz: 150,
      trebleDb: -2,
      trebleHz: 6000,
    );
    expect(
      chainOf(fx),
      'aformat=sample_fmts=dblp,'
      'volume=volume=-4.00dB:precision=double,'
      'bass=g=4.00:f=150:t=q:w=0.5:precision=f64,'
      'treble=g=-2.00:f=6000:t=q:w=0.5:precision=f64',
    );
    expect(musicAudioEffectsPeakGainDb(fx), closeTo(4, 0.1));
    // 曲线：低频处 ≈ +4，高频处 ≈ −2，中频接近 0。
    expect(musicAudioEffectsResponseDb(fx, 25), closeTo(4, 0.3));
    expect(musicAudioEffectsResponseDb(fx, 18000), closeTo(-2, 0.3));
  });

  group('声道：平衡 / 宽度 / 单声道 / 互换合成一个 pan 矩阵', () {
    test('单声道：L+R 各一半送两侧，先下混立体声', () {
      expect(
        chainOf(const MusicAudioEffects(enabled: true, mono: true)),
        'aformat=sample_fmts=dblp:channel_layouts=stereo,'
        'pan=stereo|c0=0.500000*c0+0.500000*c1|c1=0.500000*c0+0.500000*c1',
      );
    });

    test('互换', () {
      expect(
        chainOf(const MusicAudioEffects(enabled: true, swapChannels: true)),
        endsWith(
          'pan=stereo|c0=0.000000*c0+1.000000*c1'
          '|c1=1.000000*c0+0.000000*c1',
        ),
      );
    });

    test('平衡只衰减另一侧（不提升，不需要余量）', () {
      const MusicAudioEffects fx = MusicAudioEffects(
        enabled: true,
        balance: -0.25,
      );
      expect(
        chainOf(fx),
        'aformat=sample_fmts=dblp:channel_layouts=stereo,'
        'pan=stereo|c0=1.000000*c0+0.000000*c1|c1=0.000000*c0+0.750000*c1',
      );
      expect(musicAudioEffectsPeakGainDb(fx), closeTo(0, 1e-9));
    });

    test('加宽：负系数写成减号，行绝对值和计入余量', () {
      const MusicAudioEffects fx = MusicAudioEffects(enabled: true, width: 1.5);
      final String c = chainOf(fx);
      expect(
        c,
        contains(
          'pan=stereo|c0=1.250000*c0-0.250000*c1|c1=-0.250000*c0+1.250000*c1',
        ),
      );
      // 1.25 + 0.25 = 1.5 → +3.52 dB。
      expect(musicAudioEffectsPeakGainDb(fx), closeTo(3.52, 0.01));
      expect(c, contains('volume=volume=-3.52dB'));
    });

    test('矩阵：宽度 → 互换 → 平衡', () {
      expect(
        musicChannelMatrix(
          const MusicAudioEffects(width: 0.5, swapChannels: true, balance: 0.5),
        ),
        <List<double>>[
          <double>[0.125, 0.375],
          <double>[0.75, 0.25],
        ],
      );
    });
  });

  test('各效果串的顺序：格式 → 声道 → 余量 → 搁架 → 均衡 → 限幅', () {
    final String c = chainOf(
      MusicAudioEffects(
        enabled: true,
        gainsDb: gains(<int, double>{4000: 3}),
        bassDb: 2,
        trebleDb: 1,
        mono: true,
        limiter: true,
      ),
    );
    final List<String> order = <String>[
      'aformat=',
      'pan=',
      'bass=',
      'treble=',
      'equalizer=',
      'alimiter=',
    ];
    int last = -1;
    for (final String k in order) {
      final int i = c.indexOf(k);
      expect(i, greaterThan(last), reason: '$k 顺序不对：$c');
      last = i;
    }
  });

  test('与交叉淡入拼成同一条逐文件链；两种标签都能从 af 里剥掉', () {
    final String fx = musicAudioEffectsAf(
      MusicAudioEffects(
        enabled: true,
        gainsDb: gains(<int, double>{1000: 3}),
        mono: true,
      ),
    )!;
    final String combined = musicComposeAf(<String?>[
      fx,
      musicCrossfadeAf(fadeIn: const Duration(seconds: 2)),
    ]);
    expect(combined, startsWith('$fx,'));
    expect(musicAfHasAudioEffects(combined), isTrue);
    expect(
      musicAfHasAudioEffects(musicCrossfadeAf(fadeIn: Duration.zero)),
      isFalse,
    );
    expect(
      musicStripAudioEffectsFilters(musicStripCrossfadeFilters(combined)),
      '',
    );
    expect(
      musicStripAudioEffectsFilters('$fx,lavfi=[highpass=f=20]'),
      'lavfi=[highpass=f=20]',
    );
    // 中性时只剩交叉淡入（不留空项）。
    expect(
      musicComposeAf(<String?>[
        musicAudioEffectsAf(const MusicAudioEffects(enabled: true)),
        'x',
      ]),
      'x',
    );
    expect(musicComposeAf(<String?>[null, '', null]), '');
  });

  group('预设', () {
    test('增益表都在 ±12 dB、0.5 dB 档，自定义没有表', () {
      for (final MusicEqPreset p in MusicEqPreset.values) {
        final List<double>? g = p.gainsDb;
        if (p == MusicEqPreset.custom) {
          expect(g, isNull);
          continue;
        }
        expect(g, hasLength(kMusicEqualizerBandsHz.length), reason: p.name);
        for (final double v in g!) {
          expect(v.abs(), lessThanOrEqualTo(kMusicEqualizerMaxGainDb));
          expect((v * 2).roundToDouble(), v * 2, reason: p.name);
        }
      }
      expect(MusicEqPreset.values.first, MusicEqPreset.custom);
    });

    test('认定：存的预设对得上就是它；存自定义恒为自定义；没存按增益认', () {
      final List<double> rock = MusicEqPreset.rock.gainsDb!;
      expect(MusicEqPreset.resolve('rock', rock), MusicEqPreset.rock);
      expect(MusicEqPreset.resolve('custom', rock), MusicEqPreset.custom);
      expect(MusicEqPreset.resolve('', rock), MusicEqPreset.rock);
      expect(
        MusicEqPreset.resolve('', gains(<int, double>{})),
        MusicEqPreset.flat,
      );
      // 选了摇滚又拖了一段：不再匹配 → 自定义。
      final List<double> dragged = List<double>.of(rock)..[3] += 1;
      expect(MusicEqPreset.resolve('rock', dragged), MusicEqPreset.custom);
      expect(MusicEqPreset.resolve('bogus', dragged), MusicEqPreset.custom);
    });
  });

  test('增益串：坏值 / 段数不对回平直，往返不变', () {
    expect(MusicAudioEffects.parseGains(''), everyElement(0));
    expect(MusicAudioEffects.parseGains('1,2,3'), everyElement(0));
    expect(
      MusicAudioEffects.parseGains('0,0,0,0,0,x,0,0,0,0'),
      everyElement(0),
    );
    final List<double> g = MusicAudioEffects.parseGains(
      '-3,0,0,0,0,6,0,0,2.5,99',
    );
    expect(g.last, kMusicEqualizerMaxGainDb);
    expect(MusicAudioEffects.parseGains(MusicAudioEffects.encodeGains(g)), g);
  });

  group('偏好往返', () {
    late FushiDatabase db;
    late PreferencesRepository prefs;

    setUp(() async {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      prefs = PreferencesRepository(db);
      await prefs.loadFromDb();
    });

    tearDown(() => db.close());

    test('默认 = 关 + 全部中性 + 平直预设', () {
      expect(readMusicAudioEffectsPrefs(prefs), const MusicAudioEffects());
      expect(readMusicEqPresetPref(prefs), MusicEqPreset.flat);
    });

    test('写全部字段 → 重载后读回相同；预设一并持久化', () async {
      final MusicAudioEffects fx = MusicAudioEffects(
        enabled: true,
        gainsDb: List<double>.of(MusicEqPreset.vocal.gainsDb!),
        preampDb: -2.5,
        bassDb: 3,
        bassHz: 80,
        trebleDb: -1.5,
        trebleHz: 10000,
        balance: 0.2,
        width: 1.25,
        mono: true,
        swapChannels: true,
        limiter: true,
      );
      await writeMusicAudioEffectsPrefs(prefs, fx, preset: MusicEqPreset.vocal);
      final PreferencesRepository fresh = PreferencesRepository(db);
      await fresh.loadFromDb();
      expect(readMusicAudioEffectsPrefs(fresh), fx);
      expect(readMusicEqPresetPref(fresh), MusicEqPreset.vocal);
      // 旧键名不变：总开关与增益仍在 music_eq_enabled / music_eq_gains。
      expect(fresh.musicEqEnabled, isTrue);
      expect(fresh.musicEqGains, MusicAudioEffects.encodeGains(fx.gainsDb));
    });

    test('越界值读时夹回范围；平直增益写空串', () async {
      await prefs.setMusicEqPreampDb(40);
      await prefs.setMusicEffectsWidth(9);
      await prefs.setMusicEffectsBalance(-3);
      final MusicAudioEffects fx = readMusicAudioEffectsPrefs(prefs);
      expect(fx.preampDb, kMusicEffectsMaxPreampDb);
      expect(fx.width, kMusicStereoWidthMax);
      expect(fx.balance, -1);
      await prefs.setMusicEqGains('1,0,0,0,0,0,0,0,0,0');
      await writeMusicAudioEffectsPrefs(prefs, const MusicAudioEffects());
      expect(prefs.musicEqGains, '');
    });

    test('不在可选档位的转折频率读时回默认档', () async {
      await prefs.setMusicEffectsBassHz(123);
      await prefs.setMusicEffectsTrebleHz(7777);
      final MusicAudioEffects fx = readMusicAudioEffectsPrefs(prefs);
      expect(fx.bassHz, kMusicBassDefaultHz);
      expect(fx.trebleHz, kMusicTrebleDefaultHz);
      await prefs.setMusicEffectsBassHz(kMusicBassFrequenciesHz.first);
      await prefs.setMusicEffectsTrebleHz(kMusicTrebleFrequenciesHz.last);
      final MusicAudioEffects ok = readMusicAudioEffectsPrefs(prefs);
      expect(ok.bassHz, kMusicBassFrequenciesHz.first);
      expect(ok.trebleHz, kMusicTrebleFrequenciesHz.last);
    });
  });

  test('信号路径：音效挂着即一环、判非 bit-perfect', () {
    const MusicAudioFormat f = MusicAudioFormat(
      format: 's16',
      sampleRate: 44100,
      channelCount: 2,
    );
    MusicSignalPathSnapshot snap({required bool fx}) => MusicSignalPathSnapshot(
      platform: MusicOutputPlatform.windows,
      decoded: f,
      output: f,
      currentAo: 'wasapi',
      exclusiveRequested: true,
      effects: fx,
    );
    expect(judgeMusicSignalPath(snap(fx: false)).isBitPerfect, isTrue);
    final MusicSignalPathVerdict v = judgeMusicSignalPath(snap(fx: true));
    expect(v.isBitPerfect, isFalse);
    expect(v.stages, <MusicSignalStage>[MusicSignalStage.effects]);
  });

  test('输出设置相等性包含音效（改了才重新下发）', () {
    const MusicOutputSettings a = MusicOutputSettings(
      gapless: true,
      replayGain: MusicReplayGainMode.off,
    );
    final MusicOutputSettings b = a.copyWith(
      effects: const MusicAudioEffects(enabled: true, width: 1.2),
    );
    expect(a == b, isFalse);
    expect(b == a.copyWith(effects: b.effects), isTrue);
    expect(
      b == a.copyWith(effects: b.effects.copyWith(limiter: true)),
      isFalse,
    );
  });
}
