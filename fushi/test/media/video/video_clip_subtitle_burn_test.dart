import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_clip_subtitle_burn.dart';

/// 随包 `ffmpeg-min`（n7.1.x，`--disable-everything` + 白名单）`-filters` 的真实开头。
/// flag 列是 **3 位**（`T..` / `..C`），且**没有** overlay——这正是当前发行版烧不了
/// 字幕的原因。表头那几行是图例，不能被当成 filter 解析出来。
const String _kFiltersMinReal = '''
Filters:
  T.. = Timeline support
  .S. = Slice threading
  ..C = Command support
  A = Audio input/output
  V = Video input/output
  N = Dynamic number and/or type of input/output
  | = Source or sink filter
 ... aformat           A->A       (null)
 T.. ametadata         A->A       (null)
 ... copy              V->V       (null)
 ..C crop              V->V       (null)
 ... format            V->V       (null)
 ... fps               V->V       (null)
 ... palettegen        V->V       (null)
 ... paletteuse        VV->V      (null)
 ..C scale             V->V       (null)
 ... split             V->N       (null)
 ... buffer            |->V       (null)
 ... buffersink        V->|       (null)
''';

/// 用户自带的完整版 ffmpeg（N-123122）`-filters` 的真实开头。flag 列是 **2 位**
/// （`TS` / `T.`），列宽与上面那份不同——解析器必须两种都吃。
const String _kFiltersFullReal = '''
Filters:
  T.. = Timeline support
  .S. = Slice threading
  A = Audio input/output
  V = Video input/output
  N = Dynamic number and/or type of input/output
  | = Source or sink filter
  ------
 .. ass               V->V       Render ASS subtitles onto input video using the libass library.
 TS colorize          V->V       Overlay a solid color on the video stream.
 T. drawtext          V->V       Draw text on top of video frames using libfreetype library.
 TS overlay           VV->V      Overlay a video source on top of the input.
 .. subtitles         V->V       Render text subtitles onto input video using the libass library.
''';

/// 报告文件那次 `ffmpeg -i` 的真实视频流行（K-ON 片段，1920x1080）。
const String _kProbeLogReal = '''
Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'clip.mp4':
  Duration: 00:00:04.09, start: 0.000000, bitrate: 1173 kb/s
  Stream #0:0[0x1](und): Video: h264 (High) (avc1 / 0x31637661), yuv420p(tv, bt709, progressive), 1920x1080 [SAR 1:1 DAR 16:9], 994 kb/s, 23.98 fps, 23.98 tbr, 24k tbn
  Stream #0:1[0x2](jpn): Audio: aac (LC) (mp4a / 0x6134706D), 48000 Hz, stereo, fltp, 193 kb/s
  Stream #0:2[0x3](und): Subtitle: mov_text (tx3g / 0x67337874), 0 kb/s
''';

ClipBurnCue _cue(int a, int b, [String p = 'c.png']) =>
    ClipBurnCue(startMs: a, endMs: b, pngPath: p);

void main() {
  group('parseFfmpegFilterNames', () {
    test('reads the 3-flag ffmpeg-min listing and skips the legend', () {
      final Set<String> names = parseFfmpegFilterNames(_kFiltersMinReal);

      expect(names, contains('scale'));
      expect(names, contains('paletteuse')); // VV->V，双输入
      expect(names, contains('split')); // V->N，动态输出
      expect(names, contains('buffer')); // |->V，source filter
      // 表头图例行（`T.. = Timeline support` / `A = Audio input/output`）没有
      // `->`，绝不能被当成 filter 名收进来。
      expect(names, isNot(contains('=')));
      expect(names.any((String n) => n.contains(' ')), isFalse);
      expect(names, isNot(contains('Timeline')));
      expect(names, isNot(contains('Audio')));
    });

    test('reads the 2-flag full build despite the different column width', () {
      final Set<String> names = parseFfmpegFilterNames(_kFiltersFullReal);

      expect(names, contains('overlay'));
      expect(names, contains('subtitles'));
      expect(names, contains('drawtext'));
    });

    test('an empty or garbage listing yields no names', () {
      expect(parseFfmpegFilterNames(''), isEmpty);
      expect(parseFfmpegFilterNames('ffmpeg: command not found'), isEmpty);
    });
  });

  group('ffmpegCanBurnClipSubtitles', () {
    test('current bundled ffmpeg-min cannot burn (no overlay)', () {
      // 这条断言是本次改动的**起点事实**：发行版里的 ffmpeg 没有 overlay，所以
      // 烧录必须等构建脚本把它加进白名单、CI 重编一版二进制之后才会真正生效。
      final Set<String> names = parseFfmpegFilterNames(_kFiltersMinReal);
      expect(names, isNot(contains('overlay')));
      expect(ffmpegCanBurnClipSubtitles(names), isFalse);
    });

    test('a build carrying overlay can burn', () {
      expect(
        ffmpegCanBurnClipSubtitles(parseFfmpegFilterNames(_kFiltersFullReal)),
        isTrue,
      );
    });

    test('a failed probe degrades to "cannot burn", never to "can"', () {
      // 探测挂了要往「不能烧」倒：那只是导出一个无字幕但到处能播的片段；
      // 反过来误判成能烧会让整次导出直接失败。
      expect(ffmpegCanBurnClipSubtitles(const <String>{}), isFalse);
    });
  });

  group('parseClipFrameSize', () {
    test('takes the frame size off the real probe log', () {
      expect(parseClipFrameSize(_kProbeLogReal), const ClipFrameSize(1920, 1080));
    });

    test('is not fooled by DAR / SAR / bitrate / fps on the same line', () {
      // `[SAR 1:1 DAR 16:9]`、`994 kb/s`、`23.98 fps` 都在同一行，且 `16:9` 这种
      // 形状很容易被松散的正则凑成尺寸。
      final ClipFrameSize? size = parseClipFrameSize(_kProbeLogReal);
      expect(size?.width, 1920);
      expect(size?.height, 1080);
    });

    test('returns null when there is no video stream at all', () {
      expect(
        parseClipFrameSize(
          '  Stream #0:0: Audio: aac (LC), 48000 Hz, stereo, fltp, 193 kb/s\n',
        ),
        isNull,
      );
      expect(parseClipFrameSize(''), isNull);
    });

    test('returns null rather than guessing when the size field is missing',
        () {
      // 尺寸猜错会让字幕被 overlay 拉伸或裁掉，比没有字幕更糟——所以宁可返回
      // null 让调用方不烧。
      expect(
        parseClipFrameSize(
          '  Stream #0:0: Video: h264 (High), yuv420p, 994 kb/s\n',
        ),
        isNull,
      );
    });
  });

  group('buildClipBurnFilterGraph', () {
    test('chains one overlay per cue and ends on the mapped label', () {
      final String graph = buildClipBurnFilterGraph(<ClipBurnCue>[
        _cue(83, 1447, 'c0.png'),
        _cue(1547, 3867, 'c1.png'),
      ]);

      expect(
        graph,
        "[0:v][1:v]overlay=0:0:enable='between(t,0.083,1.447)'[vb0];"
        "[vb0][2:v]overlay=0:0:enable='between(t,1.547,3.867)'[vout]",
      );
    });

    test('a single cue goes straight from the source to the output label', () {
      expect(
        buildClipBurnFilterGraph(<ClipBurnCue>[_cue(0, 2000, 'c0.png')]),
        "[0:v][1:v]overlay=0:0:enable='between(t,0.000,2.000)'[vout]",
      );
    });

    test('keeps the single quotes around enable — they are ffmpeg syntax', () {
      // filtergraph 里 `,` 是链接分隔符：between(t,a,b) 不加引号会被 ffmpeg 自己的
      // 词法器拆成三段。参数是按列表传给进程、不经 shell 的，所以引号必须留在
      // 字符串里，不能当成 shell 引号删掉。
      final String graph =
          buildClipBurnFilterGraph(<ClipBurnCue>[_cue(500, 1500)]);
      expect(graph, contains("enable='between(t,0.500,1.500)'"));
      expect(graph, isNot(contains('enable=between(')));
    });

    test('no cues means no graph at all', () {
      expect(buildClipBurnFilterGraph(const <ClipBurnCue>[]), isEmpty);
    });

    test('labels stay unique across a long chain', () {
      final List<ClipBurnCue> cues = List<ClipBurnCue>.generate(
        20,
        (int i) => _cue(i * 1000, i * 1000 + 500, 'c$i.png'),
      );
      final String graph = buildClipBurnFilterGraph(cues);

      // 每个中间标签恰好出现两次（一次作为上一节点的输出，一次作为下一节点的
      // 输入）；输出标签只出现一次。标签撞车会让 ffmpeg 报 "Duplicate label"。
      for (int i = 0; i < cues.length - 1; i++) {
        expect(
          RegExp(RegExp.escape('[vb$i]')).allMatches(graph).length,
          2,
          reason: 'vb$i',
        );
      }
      expect(
        RegExp(RegExp.escape(kClipBurnOutputLabel)).allMatches(graph).length,
        1,
      );
    });
  });

  group('buildClipBurnInputArgs', () {
    test('one -i per cue, in order, after the source input', () {
      expect(
        buildClipBurnInputArgs(<ClipBurnCue>[
          _cue(0, 1, 'a.png'),
          _cue(1, 2, 'b.png'),
        ]),
        <String>['-i', 'a.png', '-i', 'b.png'],
      );
    });

    test('no cues means no extra inputs', () {
      expect(buildClipBurnInputArgs(const <ClipBurnCue>[]), isEmpty);
    });

    test('input index lines up with the graph stream references', () {
      // 图里第 i 条 cue 引用 `${i+1}:v`；输入段第 i 个 `-i` 就必须是第 i 条 cue 的
      // 图。两者错位的话字幕会张冠李戴（第 1 句显示第 2 句的图），而 ffmpeg 不会报错。
      final List<ClipBurnCue> cues = <ClipBurnCue>[
        _cue(0, 1000, 'first.png'),
        _cue(1000, 2000, 'second.png'),
        _cue(2000, 3000, 'third.png'),
      ];
      final List<String> inputs = buildClipBurnInputArgs(cues);
      final String graph = buildClipBurnFilterGraph(cues);

      for (int i = 0; i < cues.length; i++) {
        expect(inputs[i * 2 + 1], cues[i].pngPath);
        expect(graph, contains('[${i + 1}:v]'));
      }
      expect(graph, isNot(contains('[${cues.length + 1}:v]')));
    });
  });

  group('canBurnClipCues', () {
    test('accepts a normal batch', () {
      expect(canBurnClipCues(<ClipBurnCue>[_cue(0, 1000), _cue(1000, 2000)]),
          isTrue);
    });

    test('refuses an empty batch', () {
      expect(canBurnClipCues(const <ClipBurnCue>[]), isFalse);
    });

    test('refuses more cues than the command line can carry', () {
      List<ClipBurnCue> n(int count) => List<ClipBurnCue>.generate(
            count,
            (int i) => _cue(i * 100, i * 100 + 50, 'c$i.png'),
          );

      expect(canBurnClipCues(n(kMaxClipBurnCues)), isTrue);
      // 超一条就整段不烧，**不静默截断**——只烧前 N 条会产出「后半段突然没字幕」
      // 的诡异片段，比干脆没有更难排查。
      expect(canBurnClipCues(n(kMaxClipBurnCues + 1)), isFalse);
    });

    test('refuses an empty or inverted time window', () {
      // enable='between(t,a,b)' 在 a>=b 时恒假，那条字幕永远不显示。
      expect(canBurnClipCues(<ClipBurnCue>[_cue(1000, 1000)]), isFalse);
      expect(canBurnClipCues(<ClipBurnCue>[_cue(2000, 1000)]), isFalse);
      expect(canBurnClipCues(<ClipBurnCue>[_cue(-1, 1000)]), isFalse);
    });

    test('refuses a cue with no rendered image', () {
      expect(
        canBurnClipCues(<ClipBurnCue>[_cue(0, 1000, '')]),
        isFalse,
      );
    });

    test('one bad cue disqualifies the whole batch', () {
      expect(
        canBurnClipCues(<ClipBurnCue>[_cue(0, 1000), _cue(2000, 1500)]),
        isFalse,
      );
    });
  });
}
