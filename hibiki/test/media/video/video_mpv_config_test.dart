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
    test('defaults enable conservative built-in image enhancement', () {
      // isAndroid:false 钉非 Android：hwdec 透传 auto-safe（Android 改写见 resolveAndroidHwdec 组）。
      final Map<String, String> m =
          buildMpvProperties(VideoMpvConfig.defaults, isAndroid: false);
      expect(m['hwdec'], 'auto-safe');
      expect(VideoMpvConfig.defaults.highQuality, isTrue);
      expect(VideoMpvConfig.decode('').highQuality, isTrue);
      expect(m['scale'], 'ewa_lanczossharp');
      expect(m['cscale'], 'ewa_lanczossharp');
      expect(m['dscale'], 'mitchell');
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

    test('hwdec value passes through (non-Android)', () {
      final Map<String, String> m = buildMpvProperties(
          VideoMpvConfig.defaults.copyWith(hwdec: 'auto-safe'),
          isAndroid: false);
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

  group('resolveAndroidHwdec (BUG-465 Android HEVC surface-null)', () {
    // 根因：media_kit Android 纹理渲染（vo=gpu/gpu-context=android，无直渲 surface），
    // 而 auto-safe/auto 在 Android 选 surface-直渲 mediacodec → Both surface and
    // native_window are NULL。修复=Android 改写成 copy 变体。
    test('Android: auto-safe -> auto-copy', () {
      expect(resolveAndroidHwdec('auto-safe', isAndroid: true), 'auto-copy');
    });
    test('Android: auto -> auto-copy', () {
      expect(resolveAndroidHwdec('auto', isAndroid: true), 'auto-copy');
    });
    test('Android: no (software) passes through', () {
      expect(resolveAndroidHwdec('no', isAndroid: true), 'no');
    });
    test('Android: auto-copy (already copy) passes through', () {
      expect(resolveAndroidHwdec('auto-copy', isAndroid: true), 'auto-copy');
    });
    test('non-Android: every value passes through unchanged', () {
      expect(resolveAndroidHwdec('auto-safe', isAndroid: false), 'auto-safe');
      expect(resolveAndroidHwdec('auto', isAndroid: false), 'auto');
      expect(resolveAndroidHwdec('no', isAndroid: false), 'no');
      expect(resolveAndroidHwdec('auto-copy', isAndroid: false), 'auto-copy');
    });
    test('buildMpvProperties on Android downs auto-safe to copy variant', () {
      // 守卫：下发到 libmpv 的 hwdec 在 Android 必为 copy 变体，不被回退成 surface-直渲。
      final Map<String, String> m = buildMpvProperties(
        VideoMpvConfig.defaults, // 默认 hwdec=auto-safe
        isAndroid: true,
      );
      expect(m['hwdec'], 'auto-copy');
    });
    test('buildMpvProperties keeps explicit no (software) on Android', () {
      final Map<String, String> m = buildMpvProperties(
        VideoMpvConfig.defaults.copyWith(hwdec: 'no'),
        isAndroid: true,
      );
      expect(m['hwdec'], 'no');
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
      expect(VideoMpvConfig.decode('').highQuality, isTrue);
      expect(VideoMpvConfig.decode('garbage').rawConf, '');
      expect(VideoMpvConfig.decode('garbage').brightness, 0);
    });

    test('legacy config missing image enhancement migrates to new default', () {
      final VideoMpvConfig c = VideoMpvConfig.decode('{"hwdec":"auto-safe"}');
      expect(c.highQuality, isTrue);
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

    test('encoded explicit image enhancement off remains off', () {
      final VideoMpvConfig c = VideoMpvConfig.decode(VideoMpvConfig.encode(
        VideoMpvConfig.defaults.copyWith(highQuality: false),
      ));
      expect(c.highQuality, isFalse);
      expect(buildMpvProperties(c)['scale'], 'bilinear');
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

  group('isNetworkStreamUri (TODO-033 #1)', () {
    test('http(s) stream URIs are network streams', () {
      expect(
        isNetworkStreamUri('http://192.168.1.34:19632/api/library/videos/'
            'video%2Ffilm/stream?token=abc'),
        isTrue,
      );
      expect(isNetworkStreamUri('https://host/clip.mkv'), isTrue);
      // 大小写无关（Uri.scheme 归一化，再保险小写比较）。
      expect(isNetworkStreamUri('HTTP://host/clip.mkv'), isTrue);
    });

    test('local file URIs / bare paths are NOT network streams', () {
      // mediaUriForVideoPath 对本地文件产出的就是 file:// URI。
      expect(isNetworkStreamUri('file:///home/u/clip.mkv'), isFalse);
      expect(isNetworkStreamUri('file://C:/videos/clip.mp4'), isFalse);
      // 其它非网络 scheme 也不注入。
      expect(isNetworkStreamUri('content://media/external/video/1'), isFalse);
      expect(isNetworkStreamUri(''), isFalse);
    });
  });

  group('buildSubtitleSuppressionProperties (TODO-080/092, BUG-190)', () {
    test('emits exactly sub-auto=no + sub-visibility=no', () {
      final Map<String, String> m = buildSubtitleSuppressionProperties();
      // 禁止 libmpv 自动重选字幕轨（根治异步轨就绪后的自动重选竞态）。
      expect(m['sub-auto'], 'no');
      // 即便某轨仍被选中也不渲染画面字幕（字幕走可点 overlay）。
      expect(m['sub-visibility'], 'no');
      // 只发这两个 key，不碰画质/解码/几何/网络等属性。
      expect(m.keys.toSet(), <String>{'sub-auto', 'sub-visibility'});
    });
  });

  group('buildGraphicSubtitleVisibilityProperties (BUG-190 图形 PGS 例外)', () {
    test('reopens only sub-visibility=yes, never touches sub-auto', () {
      final Map<String, String> m = buildGraphicSubtitleVisibilityProperties();
      // 图形轨走 libmpv 画面渲染：重新打开可见性。
      expect(m['sub-visibility'], 'yes');
      // sub-auto 必须保持「不自动选」——轨由代码显式 setSubtitleTrack 选定，
      // 这里若重发 sub-auto 会让 mpv 又自动选轨，破坏抑制。
      expect(m.containsKey('sub-auto'), isFalse);
      // 只发 sub-visibility 这一个 key。
      expect(m.keys.toSet(), <String>{'sub-visibility'});
    });
  });

  group('buildSecondarySubtitleProperties (TODO-857 视频双字幕 Path A)', () {
    test('sets secondary-sid + secondary-sub-visibility, never main sub-*', () {
      final Map<String, String> m = buildSecondarySubtitleProperties('2');
      expect(m['secondary-sid'], '2');
      expect(m['secondary-sub-visibility'], 'yes');
      // 副字幕只动 secondary-* 属性，绝不碰主字幕 sid / sub-visibility（否则会
      // 误关/误开主字幕，破坏可查词 overlay）。
      expect(m.containsKey('sid'), isFalse);
      expect(m.containsKey('sub-visibility'), isFalse);
      expect(m.keys.toSet(),
          <String>{'secondary-sid', 'secondary-sub-visibility'});
    });

    test('libmpv track id is passed through verbatim (not streamIndex)', () {
      // secondary-sid 吃的是 libmpv 内部 track id（由 controller 经 tracks.subtitle
      // 去 auto/no 取第 N 条的 .id 解析），不是 ffmpeg streamIndex；此处纯透传。
      final Map<String, String> m = buildSecondarySubtitleProperties('5');
      expect(m['secondary-sid'], '5');
    });
  });

  group('buildSecondarySubtitleClearProperties (TODO-857)', () {
    test('clears secondary-sid to no, never touches main sub-*', () {
      final Map<String, String> m = buildSecondarySubtitleClearProperties();
      expect(m['secondary-sid'], 'no');
      expect(m['secondary-sub-visibility'], 'no');
      expect(m.containsKey('sid'), isFalse);
      expect(m.containsKey('sub-visibility'), isFalse);
      expect(m.keys.toSet(),
          <String>{'secondary-sid', 'secondary-sub-visibility'});
    });
  });

  group('buildSubtitleDelayProperty (BUG-301 图形字幕调轴)', () {
    test('positive delay -> sub-delay seconds, same sign (no flip)', () {
      // _delayMs 正＝字幕延后，mpv sub-delay 正＝字幕延后，同向不翻符号。
      final Map<String, String> m = buildSubtitleDelayProperty(1500);
      expect(m['sub-delay'], '1.5');
      expect(m.keys.toSet(), <String>{'sub-delay'});
    });

    test('negative delay -> negative sub-delay seconds', () {
      final Map<String, String> m = buildSubtitleDelayProperty(-2000);
      expect(m['sub-delay'], '-2.0');
    });

    test('zero delay -> sub-delay 0 (复位)', () {
      // 非图形模式 setDelayMs 用它显式复位，防上一段图形轨的 sub-delay 残留。
      final Map<String, String> m = buildSubtitleDelayProperty(0);
      expect(m['sub-delay'], '0.0');
    });

    test('only sub-delay key (不碰画质/抑制属性)', () {
      final Map<String, String> m = buildSubtitleDelayProperty(500);
      expect(m.containsKey('sub-visibility'), isFalse);
      expect(m.containsKey('sub-auto'), isFalse);
      expect(m.containsKey('audio-delay'), isFalse);
    });
  });

  group('buildNetworkCacheProperties (TODO-033 #1)', () {
    test('emits conservative network cache/readahead tuning', () {
      final Map<String, String> m = buildNetworkCacheProperties();
      // 流缓存显式开启。
      expect(m['cache'], 'yes');
      // 预读时长目标（受字节上限封顶）。
      expect(m['cache-secs'], '30');
      // 字节上限是缓存真实约束：128MiB（> media_kit 默认 32MiB）。
      expect(m['demuxer-max-bytes'], '${128 * 1024 * 1024}');
      // 向后缓冲（回退 seek 不重拉），取前向一半。
      expect(m['demuxer-max-back-bytes'], '${64 * 1024 * 1024}');
      // 容忍 WiFi 抖动：放宽 media_kit 默认 5s 超时到 30s。
      expect(m['network-timeout'], '30');
    });

    test('byte caps stay bounded (no runaway memory)', () {
      final Map<String, String> m = buildNetworkCacheProperties();
      final int fwd = int.parse(m['demuxer-max-bytes']!);
      final int back = int.parse(m['demuxer-max-back-bytes']!);
      // 上界守卫：单段会话总缓冲 <= 256MiB，避免大码率流爆内存。
      expect(fwd, lessThanOrEqualTo(256 * 1024 * 1024));
      expect(back, lessThanOrEqualTo(fwd));
      // 下界守卫：必须比 media_kit 默认 32MiB 大，否则调优无意义。
      expect(fwd, greaterThan(32 * 1024 * 1024));
    });

    test('only network-relevant keys are emitted (no codec/scale knobs)', () {
      final Map<String, String> m = buildNetworkCacheProperties();
      // 不碰画质/解码/几何属性——那些归 buildMpvProperties 管。
      expect(m.containsKey('scale'), isFalse);
      expect(m.containsKey('hwdec'), isFalse);
      expect(m.containsKey('video-rotate'), isFalse);
      // 全是网络缓存族属性。
      expect(
        m.keys.toSet(),
        <String>{
          'cache',
          'cache-secs',
          'demuxer-max-bytes',
          'demuxer-max-back-bytes',
          'network-timeout',
        },
      );
    });
  });
}
