import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_clip_subtitle.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// 只填 [buildClipSrtContent] 真正读到的三个字段；AudioCue 其余 late 字段（bookKey /
/// chapterHref / …）在本路径上不被访问，刻意不初始化，读到就说明实现越权了。
AudioCue _cue(int startMs, int endMs, String text) {
  final AudioCue cue = AudioCue();
  cue.startMs = startMs;
  cue.endMs = endMs;
  cue.text = text;
  return cue;
}

void main() {
  group('formatSrtTimestamp', () {
    test('formats as HH:MM:SS,mmm', () {
      expect(formatSrtTimestamp(0), '00:00:00,000');
      expect(formatSrtTimestamp(1234), '00:00:01,234');
      expect(formatSrtTimestamp(61005), '00:01:01,005');
      expect(formatSrtTimestamp(3723456), '01:02:03,456');
    });

    test('clamps negative input to zero (SRT has no negative timeline)', () {
      expect(formatSrtTimestamp(-1), '00:00:00,000');
    });
  });

  group('buildClipSrtContent', () {
    test('keeps only cues overlapping the clip and rebases them to zero', () {
      final String? srt = buildClipSrtContent(
        cues: <AudioCue>[
          _cue(1000, 2000, '区间之前'),
          _cue(11000, 12000, '第一句'),
          _cue(13000, 14000, '第二句'),
          _cue(30000, 31000, '区间之后'),
        ],
        startMs: 10000,
        endMs: 20000,
      );

      expect(
        srt,
        '1\n'
        '00:00:01,000 --> 00:00:02,000\n'
        '第一句\n'
        '\n'
        '2\n'
        '00:00:03,000 --> 00:00:04,000\n'
        '第二句\n'
        '\n',
      );
    });

    test('renumbers sequentially from 1 regardless of source cue index', () {
      final String? srt = buildClipSrtContent(
        cues: <AudioCue>[
          _cue(0, 500, '丢弃'),
          _cue(1000, 1500, '丢弃2'),
          _cue(10500, 11000, '保留'),
        ],
        startMs: 10000,
        endMs: 20000,
      );
      expect(srt, startsWith('1\n'));
      expect(srt, contains('保留'));
      expect(srt, isNot(contains('丢弃')));
    });

    test('clamps cues that straddle the clip boundaries', () {
      // 头尾各有一句跨界：起点被 clamp 到 0，终点被 clamp 到片段时长。
      final String? srt = buildClipSrtContent(
        cues: <AudioCue>[
          _cue(9000, 10500, '跨入'),
          _cue(19500, 21000, '跨出'),
        ],
        startMs: 10000,
        endMs: 20000,
      );

      expect(
        srt,
        '1\n'
        '00:00:00,000 --> 00:00:00,500\n'
        '跨入\n'
        '\n'
        '2\n'
        '00:00:09,500 --> 00:00:10,000\n'
        '跨出\n'
        '\n',
      );
    });

    test('shifts cue times by the user subtitle delay (video-axis)', () {
      // overlay 用 effective = pos - delay 查 cue，所以 cue 在**视频轴**上的真实
      // 出现时间是 cue + delay。delay=+2000 的 cue@11s 实际在视频 13s 出现，
      // 片段从 10s 起 → 输出 3s。不按视频轴算，用户调过轴的字幕导出后整体错位。
      final String? srt = buildClipSrtContent(
        cues: <AudioCue>[_cue(11000, 12000, '调轴句')],
        startMs: 10000,
        endMs: 20000,
        delayMs: 2000,
      );
      expect(srt, contains('00:00:03,000 --> 00:00:04,000'));
    });

    test('delay can pull a cue into the clip that was otherwise outside', () {
      // cue@9.5s 本来在片段之前，delay=+1000 把它推到视频轴 10.5s → 进片段。
      final String? srt = buildClipSrtContent(
        cues: <AudioCue>[_cue(9500, 9800, '被推进来')],
        startMs: 10000,
        endMs: 20000,
        delayMs: 1000,
      );
      expect(srt, isNotNull);
      expect(srt, contains('被推进来'));
      expect(srt, contains('00:00:00,500 --> 00:00:00,800'));
    });

    test('returns null when no cue overlaps the clip', () {
      expect(
        buildClipSrtContent(
          cues: <AudioCue>[_cue(0, 1000, 'OP 之前'), _cue(90000, 91000, 'ED')],
          startMs: 10000,
          endMs: 20000,
        ),
        isNull,
      );
    });

    test('returns null for empty cue list and for a non-positive range', () {
      expect(
        buildClipSrtContent(cues: <AudioCue>[], startMs: 0, endMs: 1000),
        isNull,
      );
      expect(
        buildClipSrtContent(
          cues: <AudioCue>[_cue(0, 1000, 'x')],
          startMs: 5000,
          endMs: 5000,
        ),
        isNull,
      );
    });

    test('strips blank lines inside cue text so SRT blocks stay parseable', () {
      // SRT 用空行分隔块——文本内部一旦漏出空行，后续所有块都会错位解析。
      final String? srt = buildClipSrtContent(
        cues: <AudioCue>[
          _cue(10000, 11000, '第一行\r\n\r\n  \n第二行  '),
          _cue(12000, 13000, '后一句'),
        ],
        startMs: 10000,
        endMs: 20000,
      );

      expect(
        srt,
        '1\n'
        '00:00:00,000 --> 00:00:01,000\n'
        '第一行\n'
        '第二行\n'
        '\n'
        '2\n'
        '00:00:02,000 --> 00:00:03,000\n'
        '后一句\n'
        '\n',
      );
    });

    test('skips cues whose text is blank after sanitising', () {
      expect(
        buildClipSrtContent(
          cues: <AudioCue>[_cue(10000, 11000, '   \n\n  ')],
          startMs: 10000,
          endMs: 20000,
        ),
        isNull,
      );
    });

    test('gives zero-length cues a 1ms visible span', () {
      final String? srt = buildClipSrtContent(
        cues: <AudioCue>[_cue(10500, 10500, '瞬时句')],
        startMs: 10000,
        endMs: 20000,
      );
      expect(srt, contains('00:00:00,500 --> 00:00:00,501'));
    });
  });

  group('buildClipSubtitleCues (BUG-2202)', () {
    test('shifts the timeline to the clip start and clamps to its edges', () {
      final List<ClipSubtitleCue> out = buildClipSubtitleCues(
        cues: <AudioCue>[
          _cue(9000, 11000, '跨入'), // 跨左边界
          _cue(11500, 12500, '整条在内'),
          _cue(13000, 20000, '跨出'), // 跨右边界
          _cue(30000, 31000, '完全在外'),
        ],
        startMs: 10000,
        endMs: 14000,
      );

      expect(out.length, 3);
      // 跨界的半句宁可显示半句，也不整条丢掉——与 SRT 路径同一约定。
      expect(out[0].startMs, 0);
      expect(out[0].endMs, 1000);
      expect(out[1].startMs, 1500);
      expect(out[1].endMs, 2500);
      expect(out[2].startMs, 3000);
      expect(out[2].endMs, 4000);
    });

    test('applies the subtitle delay before deciding what is in range', () {
      // delay 把 cue 轴换算到视频轴；不加它的话用户调过轴的字幕会整体错位，
      // 导出的字幕就不是他屏幕上看到的那条。
      final List<ClipSubtitleCue> out = buildClipSubtitleCues(
        cues: <AudioCue>[_cue(9000, 9500, '延后进区间')],
        startMs: 10000,
        endMs: 14000,
        delayMs: 1500,
      );

      expect(out.length, 1);
      expect(out.single.startMs, 500);
      expect(out.single.endMs, 1000);
    });

    test('drops cues whose text washes out to nothing', () {
      expect(
        buildClipSubtitleCues(
          cues: <AudioCue>[_cue(0, 1000, '   '), _cue(1000, 2000, '')],
          startMs: 0,
          endMs: 3000,
        ),
        isEmpty,
      );
    });

    test('gives a zero-length cue a 1ms floor', () {
      // overlay 的 enable='between(t,a,b)' 在 a>=b 时恒假，那条字幕永远不显示；
      // SRT 侧同病（多数播放器也不显示零长 cue）。
      final List<ClipSubtitleCue> out = buildClipSubtitleCues(
        cues: <AudioCue>[_cue(1000, 1000, '瞬间')],
        startMs: 0,
        endMs: 3000,
      );
      expect(out.single.endMs, greaterThan(out.single.startMs));
    });

    test('marks the secondary layer so the two do not overprint', () {
      // 主副两层在屏幕上锚在画面对侧（主底 → 副顶）。扁平成一个列表后靠这个标记
      // 还原层归属，丢了它副字幕会盖在主字幕上。
      expect(
        buildClipSubtitleCues(
          cues: <AudioCue>[_cue(0, 1000, 'x')],
          startMs: 0,
          endMs: 2000,
        ).single.isSecondary,
        isFalse,
      );
      expect(
        buildClipSubtitleCues(
          cues: <AudioCue>[_cue(0, 1000, 'x')],
          startMs: 0,
          endMs: 2000,
          isSecondary: true,
        ).single.isSecondary,
        isTrue,
      );
    });

    test('picks exactly the same cues the SRT path writes', () {
      // 两条路径必须同源：烧出来的字幕和 SRT 里的逐条一致，不能因为各挑各的而
      // 显示出两套内容。buildClipSrtContent 现在就建在本函数之上，这条守住它。
      final List<AudioCue> cues = <AudioCue>[
        _cue(9000, 11000, '一'),
        _cue(11500, 12500, '二'),
        _cue(13000, 20000, '三'),
        _cue(30000, 31000, '四'),
      ];
      final List<ClipSubtitleCue> picked = buildClipSubtitleCues(
        cues: cues,
        startMs: 10000,
        endMs: 14000,
      );
      final String? srt = buildClipSrtContent(
        cues: cues,
        startMs: 10000,
        endMs: 14000,
      );

      expect(srt, isNotNull);
      for (final ClipSubtitleCue c in picked) {
        expect(srt, contains(c.text));
        expect(srt, contains(formatSrtTimestamp(c.startMs)));
        expect(srt, contains(formatSrtTimestamp(c.endMs)));
      }
      // 条数也要对上：SRT 的序号从 1 连续递增到 picked.length。
      expect(srt, contains('${picked.length}\n'));
      expect(srt, isNot(contains('${picked.length + 1}\n')));
    });

    test('an empty cue list or an inverted range yields nothing', () {
      expect(
        buildClipSubtitleCues(cues: const <AudioCue>[], startMs: 0, endMs: 1000),
        isEmpty,
      );
      expect(
        buildClipSubtitleCues(
          cues: <AudioCue>[_cue(0, 1000, 'x')],
          startMs: 5000,
          endMs: 1000,
        ),
        isEmpty,
      );
    });
  });

  group('resolveClipSubtitleCodec', () {
    test('mp4 family carries no soft subtitle track at all (BUG-2202)', () {
      // 片段导出输出恒 .mp4（BUG-917），所以这是实际生效的分支。
      //
      // 这里曾经返回 'mov_text'（tx3g）。改掉是因为带 tx3g 轨的片段会被 QQ 这类
      // IM 的内置播放器整个判为不可播——用户在真 QQ 上二分过：同一份源，只差字幕
      // 轨的两个变体，带轨打不开、去轨能放；再把轨 tkhd 的 enabled 位清零、或把
      // hdlr 从 sbtl 改成规范的 text，两种补丁都仍然打不开。而即便能播，QQ 也不
      // 渲染 tx3g，所以内封在「导出→分享」里是纯负资产。字幕以硬字幕形式回来
      // （video_clip_subtitle_burn.dart 的 overlay 烧录），走另一条路径。
      expect(resolveClipSubtitleCodec('/out/clip.mp4'), isNull);
      expect(resolveClipSubtitleCodec('/out/clip.MP4'), isNull);
      expect(resolveClipSubtitleCodec('/out/clip.m4v'), isNull);
      expect(resolveClipSubtitleCodec('/out/clip.mov'), isNull);
    });

    test('matroska/webm can copy SRT verbatim', () {
      expect(resolveClipSubtitleCodec('/out/clip.mkv'), 'copy');
      expect(resolveClipSubtitleCodec('/out/clip.webm'), 'copy');
    });

    test('returns null for containers that cannot carry text subtitles', () {
      // null = 跳过字幕、只导视频音频。绝不能对这些容器硬塞字幕流：ffmpeg 会让
      // **整个导出**失败，把原本能成功的片段一起拖垮。
      expect(resolveClipSubtitleCodec('/out/clip.ts'), isNull);
      expect(resolveClipSubtitleCodec('/out/clip.avi'), isNull);
      expect(resolveClipSubtitleCodec('/out/clip.flv'), isNull);
      expect(resolveClipSubtitleCodec('/out/clip'), isNull);
    });
  });
}
