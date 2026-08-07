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

  group('resolveClipSubtitleCodec', () {
    test('mp4 family needs 3GPP Timed Text', () {
      // 片段导出输出恒 .mp4（BUG-917），所以这是实际生效的分支。
      expect(resolveClipSubtitleCodec('/out/clip.mp4'), 'mov_text');
      expect(resolveClipSubtitleCodec('/out/clip.MP4'), 'mov_text');
      expect(resolveClipSubtitleCodec('/out/clip.m4v'), 'mov_text');
      expect(resolveClipSubtitleCodec('/out/clip.mov'), 'mov_text');
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
