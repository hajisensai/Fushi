import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/music_platform_output.dart';
import 'package:fushi/src/media/music/music_signal_path.dart';

const MusicAudioFormat _hi = MusicAudioFormat(
  format: 's32',
  sampleRate: 96000,
  channelCount: 2,
  channels: 'stereo',
);

MusicSignalPathSnapshot _snap({
  MusicOutputPlatform platform = MusicOutputPlatform.windows,
  MusicAudioFormat? out = _hi,
  String ao = 'wasapi',
  bool exclusive = true,
  String? device,
  double volume = 100,
  double gain = 0,
  double speed = 1,
  String codec = 'flac',
  int? bitDepth = 24,
  MusicBitPerfectResult? android,
}) => MusicSignalPathSnapshot(
  platform: platform,
  codec: codec,
  sourceBitDepth: bitDepth,
  decoded: _hi,
  output: out,
  currentAo: ao,
  audioDevice: device,
  exclusiveRequested: exclusive,
  volume: volume,
  volumeGainDb: gain,
  speed: speed,
  androidBitPerfect: android,
);

void main() {
  test('mpv JSON → 格式；属性不可用（空串）为 null', () {
    final MusicAudioFormat f = MusicAudioFormat.fromMpvJson(
      '{"samplerate":96000,"channel-count":2,"channels":"stereo","format":"floatp"}',
    )!;
    expect(f.packedFormat, 'float');
    expect(MusicAudioFormat.fromMpvJson(''), isNull);
    expect(
      MusicAudioDevice.listFromMpvJson(
        '[{"name":"auto","description":"Autoselect device"},'
        '{"name":"alsa/hw:CARD=D","description":"DAC"}]',
      ).last.isAlsaHardware,
      isTrue,
    );
  });

  test('独占且链上零修改 = bit-perfect', () {
    final MusicSignalPathVerdict v = judgeMusicSignalPath(_snap());
    expect(v.quality, MusicSignalQuality.bitPerfect);
    expect(v.stages, isEmpty);
  });

  test('任何一环生效就降为高品质并指出那一环', () {
    expect(
      judgeMusicSignalPath(_snap(exclusive: false)).stages,
      <MusicSignalStage>[MusicSignalStage.systemMixer],
    );
    expect(judgeMusicSignalPath(_snap(gain: -3.2)).stages, <MusicSignalStage>[
      MusicSignalStage.replayGain,
    ]);
    expect(judgeMusicSignalPath(_snap(volume: 99)).stages, <MusicSignalStage>[
      MusicSignalStage.volume,
    ]);
    expect(judgeMusicSignalPath(_snap(speed: 1.25)).stages, <MusicSignalStage>[
      MusicSignalStage.speed,
    ]);
    expect(
      judgeMusicSignalPath(
        _snap(
          out: const MusicAudioFormat(
            format: 's16',
            sampleRate: 48000,
            channelCount: 2,
            channels: 'stereo',
          ),
        ),
      ).stages,
      <MusicSignalStage>[
        MusicSignalStage.resampler,
        MusicSignalStage.formatConversion,
      ],
    );
    expect(
      judgeMusicSignalPath(_snap(out: null)).stages,
      contains(MusicSignalStage.noOutput),
    );
    final MusicSignalPathVerdict dsd = judgeMusicSignalPath(
      _snap(codec: 'dsd_lsbf_planar', bitDepth: 1),
    );
    expect(dsd.isBitPerfect, isFalse);
    expect(dsd.stages.first, MusicSignalStage.dsdToPcm);
  });

  test('24 bit 源 s32 → s24 不改样本；16 bit 源则算转换', () {
    const MusicAudioFormat s24 = MusicAudioFormat(
      format: 's24',
      sampleRate: 96000,
      channelCount: 2,
      channels: 'stereo',
    );
    expect(judgeMusicSignalPath(_snap(out: s24)).isBitPerfect, isTrue);
    expect(
      judgeMusicSignalPath(_snap(out: s24, bitDepth: 32)).stages,
      <MusicSignalStage>[MusicSignalStage.formatConversion],
    );
  });

  test('各平台「绕过系统混音」的判据', () {
    expect(
      judgeMusicSignalPath(
        _snap(platform: MusicOutputPlatform.macos, ao: 'coreaudio_exclusive'),
      ).isBitPerfect,
      isTrue,
    );
    expect(
      judgeMusicSignalPath(
        _snap(platform: MusicOutputPlatform.macos, ao: 'coreaudio'),
      ).isBitPerfect,
      isFalse,
    );
    expect(
      judgeMusicSignalPath(
        _snap(
          platform: MusicOutputPlatform.linux,
          ao: 'alsa',
          device: 'alsa/hw:CARD=DAC,DEV=0',
        ),
      ).isBitPerfect,
      isTrue,
    );
    expect(
      judgeMusicSignalPath(
        _snap(platform: MusicOutputPlatform.linux, ao: 'pipewire'),
      ).isBitPerfect,
      isFalse,
    );
    expect(
      judgeMusicSignalPath(
        _snap(
          platform: MusicOutputPlatform.android,
          ao: 'audiotrack',
          android: const MusicBitPerfectResult(
            state: MusicBitPerfectState.enabled,
          ),
        ),
      ).isBitPerfect,
      isTrue,
    );
    expect(
      judgeMusicSignalPath(
        _snap(
          platform: MusicOutputPlatform.android,
          ao: 'audiotrack',
          android: const MusicBitPerfectResult(
            state: MusicBitPerfectState.unsupportedByDevice,
          ),
        ),
      ).stages,
      <MusicSignalStage>[MusicSignalStage.systemMixer],
    );
    expect(
      judgeMusicSignalPath(
        _snap(platform: MusicOutputPlatform.ios, ao: 'audiounit'),
      ).stages,
      <MusicSignalStage>[MusicSignalStage.systemMixer],
      reason: 'iOS 没有独占，恒为系统混音',
    );
  });

  test('mpv 采样格式 → Android 编码（24 bit 源经 s32 报 pcm24）', () {
    expect(musicPcmEncodingOf('s16'), MusicPcmEncoding.pcm16);
    expect(
      musicPcmEncodingOf('s32', sourceBitDepth: 24),
      MusicPcmEncoding.pcm24,
    );
    expect(musicPcmEncodingOf('s32p'), MusicPcmEncoding.pcm32);
    expect(musicPcmEncodingOf('floatp'), MusicPcmEncoding.float);
    expect(musicPcmEncodingOf('u8'), isNull);
  });
}
