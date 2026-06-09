import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_mpv_config.dart';

void main() {
  group('parseMpvConf', () {
    test('parses key=value, ignores comments/blank', () {
      final Map<String, String> m = parseMpvConf('''
# comment
hwdec=auto-safe

scale=ewa_lanczossharp
keep-open=yes
''');
      expect(m['hwdec'], 'auto-safe');
      expect(m['scale'], 'ewa_lanczossharp');
      expect(m['keep-open'], 'yes');
      expect(m.containsKey('# comment'), isFalse);
    });

    test('bare flag -> yes', () {
      final Map<String, String> m = parseMpvConf('save-position-on-quit');
      expect(m['save-position-on-quit'], 'yes');
    });

    test('strips wrapping quotes', () {
      final Map<String, String> m = parseMpvConf('screenshot-dir="~/Pictures"');
      expect(m['screenshot-dir'], '~/Pictures');
    });
  });

  group('buildMpvProperties', () {
    test(
        'defaults auto-detect hardware decoding while staying visually neutral',
        () {
      final Map<String, String> m = buildMpvProperties(VideoMpvConfig.defaults);
      expect(m['hwdec'], 'auto-safe');
      expect(m['scale'], 'bilinear');
      expect(m['deband'], 'no');
      expect(m['dither-depth'], 'no');
      expect(m['brightness'], '0');
      expect(m['contrast'], '0');
      expect(m['saturation'], '0');
      expect(m['gamma'], '0');
      expect(m['hue'], '0');
      expect(m['video-rotate'], '0');
      expect(m['loop-file'], 'no');
      // 新增结构化项的中性默认（= mpv 默认，视觉等价）。
      expect(m['sigmoid-upscaling'], 'yes'); // mpv 默认 yes
      expect(m['correct-downscaling'], 'no');
      expect(m['panscan'], '0.0');
      expect(m['audio-delay'], '0.0');
      expect(m['audio-pitch-correction'], 'yes'); // mpv 默认 yes
      expect(m['audio-channels'], 'auto-safe');
      expect(m['audio-normalize-downmix'], 'no');
    });

    test('audio group passes through', () {
      final Map<String, String> m =
          buildMpvProperties(VideoMpvConfig.defaults.copyWith(
        audioDelayMs: 250,
        audioPitchCorrection: false,
        audioChannels: 'stereo',
        normalizeDownmix: true,
      ));
      expect(m['audio-delay'], '0.25'); // 250ms = 0.25s
      expect(m['audio-pitch-correction'], 'no');
      expect(m['audio-channels'], 'stereo');
      expect(m['audio-normalize-downmix'], 'yes');
    });

    test('hwdec value passes through', () {
      final Map<String, String> m = buildMpvProperties(
          VideoMpvConfig.defaults.copyWith(hwdec: 'auto-safe'));
      expect(m['hwdec'], 'auto-safe');
    });

    test('highQuality on -> high-quality scale chain', () {
      final Map<String, String> m = buildMpvProperties(
          VideoMpvConfig.defaults.copyWith(highQuality: true));
      expect(m['scale'], 'ewa_lanczossharp');
      expect(m['cscale'], 'ewa_lanczossharp');
      expect(m['dscale'], 'mitchell');
    });

    test('toggles off -> explicit mpv defaults (so runtime switch-off resets)',
        () {
      final Map<String, String> m = buildMpvProperties(
          VideoMpvConfig.defaults.copyWith(highQuality: false, deband: false));
      expect(m['scale'], 'bilinear');
      expect(m['deband'], 'no');
    });

    test('interpolation on -> interpolation+video-sync+tscale', () {
      final Map<String, String> m = buildMpvProperties(
          VideoMpvConfig.defaults.copyWith(interpolation: true));
      expect(m['interpolation'], 'yes');
      expect(m['video-sync'], 'display-resample');
      expect(m['tscale'], 'oversample');
    });

    test('color equalizer + geometry pass through', () {
      final Map<String, String> m =
          buildMpvProperties(VideoMpvConfig.defaults.copyWith(
        brightness: 10,
        contrast: -5,
        saturation: 20,
        videoRotate: 90,
        videoZoom: 0.5,
        aspectOverride: '16:9',
      ));
      expect(m['brightness'], '10');
      expect(m['contrast'], '-5');
      expect(m['saturation'], '20');
      expect(m['video-rotate'], '90');
      expect(m['video-zoom'], '0.5');
      expect(m['video-aspect-override'], '16:9');
    });

    test('raw overrides toggle-derived', () {
      final Map<String, String> m = buildMpvProperties(VideoMpvConfig.defaults
          .copyWith(hwdec: 'auto-safe', rawConf: 'hwdec=no'));
      expect(m['hwdec'], 'no'); // raw 优先
    });
  });

  group('encode/decode', () {
    test('round-trips all fields', () {
      final VideoMpvConfig c = VideoMpvConfig.defaults.copyWith(
        hwdec: 'auto-copy',
        highQuality: true,
        deband: true,
        dither: true,
        interpolation: true,
        deinterlace: true,
        videoRotate: 180,
        videoZoom: -0.5,
        aspectOverride: '4:3',
        brightness: 5,
        contrast: 6,
        saturation: 7,
        gamma: 8,
        hue: 9,
        sigmoidUpscaling: false,
        correctDownscaling: true,
        panscan: 0.3,
        audioDelayMs: -150,
        audioPitchCorrection: false,
        audioChannels: 'mono',
        normalizeDownmix: true,
        loopFile: true,
        rawConf: 'vo=gpu-next',
      );
      final VideoMpvConfig back =
          VideoMpvConfig.decode(VideoMpvConfig.encode(c));
      expect(back.hwdec, 'auto-copy');
      expect(back.highQuality, isTrue);
      expect(back.deinterlace, isTrue);
      expect(back.videoRotate, 180);
      expect(back.videoZoom, -0.5);
      expect(back.aspectOverride, '4:3');
      expect(back.brightness, 5);
      expect(back.hue, 9);
      expect(back.sigmoidUpscaling, isFalse);
      expect(back.correctDownscaling, isTrue);
      expect(back.panscan, 0.3);
      expect(back.audioDelayMs, -150);
      expect(back.audioPitchCorrection, isFalse);
      expect(back.audioChannels, 'mono');
      expect(back.normalizeDownmix, isTrue);
      expect(back.loopFile, isTrue);
      expect(back.rawConf, 'vo=gpu-next');
    });

    test('decode empty/garbage -> defaults', () {
      expect(VideoMpvConfig.decode('').hwdec, 'auto-safe');
      expect(VideoMpvConfig.decode('garbage').rawConf, '');
      expect(VideoMpvConfig.decode('garbage').brightness, 0);
    });

    test('decode invalid hwdec falls back to automatic safe detection', () {
      final VideoMpvConfig c = VideoMpvConfig.decode('{"hwdec":"bad"}');
      expect(c.hwdec, 'auto-safe');
    });

    test('legacy default hwdec=no migrates to automatic safe detection', () {
      final VideoMpvConfig c = VideoMpvConfig.decode('{"hwdec":"no"}');
      expect(c.hwdec, 'auto-safe');
    });

    test('encoded explicit hwdec off remains off', () {
      final VideoMpvConfig c = VideoMpvConfig.decode(VideoMpvConfig.encode(
        VideoMpvConfig.defaults.copyWith(hwdec: 'no'),
      ));
      expect(c.hwdec, 'no');
    });

    test('decode clamps out-of-range color/rotate', () {
      final VideoMpvConfig c = VideoMpvConfig.decode(
          '{"brightness":999,"contrast":-999,"videoRotate":45,"videoZoom":99}');
      expect(c.brightness, lessThanOrEqualTo(100));
      expect(c.contrast, greaterThanOrEqualTo(-100));
      expect(<int>[0, 90, 180, 270].contains(c.videoRotate), isTrue);
      expect(c.videoZoom, lessThanOrEqualTo(2.0));
    });
  });
}
