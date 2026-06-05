import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_subtitle_source.dart';

void main() {
  group('parseSubtitleStreamsFromFfmpegLog', () {
    test('解析龙女仆 S01E01 真实 ffmpeg stderr：2 条字幕轨（eng/ass）', () {
      // 真实 `ffmpeg -i "...S01E01.mkv"` stderr 片段（HEVC + 2 opus 音轨 +
      // 2 条 ass 字幕 + 大量字体附件）。字幕在 #0:3 / #0:4，但相对字幕序号是 0/1。
      const String stderr = '''
Input #0, matroska,webm, from 'S01E01.mkv':
  Metadata:
    encoder         : libebml v1.4.4 + libmatroska v1.7.1
  Duration: 00:24:11.30, start: 0.007000, bitrate: 3500 kb/s
  Stream #0:0: Video: hevc (Main 10), yuv420p10le(tv, bt709), 1920x1080 [SAR 1:1 DAR 16:9], 23.98 fps, 23.98 tbr, 1k tbn, start 0.007000 (default)
  Stream #0:1(eng): Audio: opus, 48000 Hz, 5.1, fltp (default)
  Stream #0:2(jpn): Audio: opus, 48000 Hz, stereo, fltp
  Stream #0:3(eng): Subtitle: ass (ssa) (forced)
  Stream #0:4(eng): Subtitle: ass (ssa) (default)
  Stream #0:5: Attachment: ttf
  Stream #0:6: Attachment: ttf
''';

      final List<EmbeddedSubtitleTrack> tracks =
          parseSubtitleStreamsFromFfmpegLog(stderr);

      expect(tracks, hasLength(2));

      expect(tracks[0].streamIndex, 0);
      expect(tracks[0].language, 'eng');
      expect(tracks[0].codec, 'ass');

      expect(tracks[1].streamIndex, 1);
      expect(tracks[1].language, 'eng');
      expect(tracks[1].codec, 'ass');
    });

    test('subrip(srt) 字幕轨 + 多语言 + 无语言括号', () {
      const String stderr = '''
  Stream #0:0: Video: h264
  Stream #0:1(jpn): Audio: aac
  Stream #0:2(jpn): Subtitle: subrip (default)
  Stream #0:3: Subtitle: subrip
  Stream #0:4(eng): Subtitle: hdmv_pgs_subtitle
''';
      final List<EmbeddedSubtitleTrack> tracks =
          parseSubtitleStreamsFromFfmpegLog(stderr);

      expect(tracks, hasLength(3));
      expect(tracks[0].streamIndex, 0);
      expect(tracks[0].language, 'jpn');
      expect(tracks[0].codec, 'subrip');
      // 无语言括号：language 为 null。
      expect(tracks[1].streamIndex, 1);
      expect(tracks[1].language, isNull);
      expect(tracks[1].codec, 'subrip');
      // 图形字幕（pgs）也照样枚举，相对序号继续递增。
      expect(tracks[2].streamIndex, 2);
      expect(tracks[2].codec, 'hdmv_pgs_subtitle');
    });

    test('无字幕轨返回空列表', () {
      const String stderr = '''
  Stream #0:0: Video: h264
  Stream #0:1: Audio: aac
''';
      expect(parseSubtitleStreamsFromFfmpegLog(stderr), isEmpty);
    });

    test('空字符串返回空列表', () {
      expect(parseSubtitleStreamsFromFfmpegLog(''), isEmpty);
    });
  });

  group('subtitleParserForExtension（格式路由覆盖 srt/ass/ssa/vtt）', () {
    test('.srt → srt', () {
      expect(subtitleFormatForPath('/x/a.srt'), SubtitleFormat.srt);
      expect(subtitleFormatForPath('/x/a.JA.SRT'), SubtitleFormat.srt);
    });
    test('.ass / .ssa → ass', () {
      expect(subtitleFormatForPath('/x/a.ass'), SubtitleFormat.ass);
      expect(subtitleFormatForPath('/x/a.ssa'), SubtitleFormat.ass);
    });
    test('.vtt → vtt', () {
      expect(subtitleFormatForPath('/x/a.vtt'), SubtitleFormat.vtt);
    });
    test('未知扩展名 → null', () {
      expect(subtitleFormatForPath('/x/a.txt'), isNull);
    });
  });

  group('subtitleFormatForCodec（内嵌轨 codec → 解析格式）', () {
    test('ass / ssa → ass', () {
      expect(subtitleFormatForCodec('ass'), SubtitleFormat.ass);
      expect(subtitleFormatForCodec('ssa'), SubtitleFormat.ass);
    });
    test('subrip / srt → srt', () {
      expect(subtitleFormatForCodec('subrip'), SubtitleFormat.srt);
      expect(subtitleFormatForCodec('srt'), SubtitleFormat.srt);
    });
    test('webvtt / vtt → vtt', () {
      expect(subtitleFormatForCodec('webvtt'), SubtitleFormat.vtt);
      expect(subtitleFormatForCodec('vtt'), SubtitleFormat.vtt);
    });
    test('图形字幕 codec → null（无法转文本 cue）', () {
      expect(subtitleFormatForCodec('hdmv_pgs_subtitle'), isNull);
      expect(subtitleFormatForCodec('dvd_subtitle'), isNull);
    });
  });

  group('parseSubtitleContent（按格式路由到对应 parser）', () {
    const String bookUid = 'video_book_x://book/1';

    test('srt 内容路由到 SrtParser', () {
      const String srt = '''
1
00:00:01,000 --> 00:00:03,000
こんにちは
''';
      final cues = parseSubtitleContent(SubtitleFormat.srt,
          content: srt, bookUid: bookUid);
      expect(cues, hasLength(1));
      expect(cues.first.text, 'こんにちは');
    });

    test('ass 内容路由到 AssParser', () {
      const String ass = '''
[Script Info]
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,おはよう
''';
      final cues = parseSubtitleContent(SubtitleFormat.ass,
          content: ass, bookUid: bookUid);
      expect(cues, hasLength(1));
      expect(cues.first.text, 'おはよう');
    });

    test('vtt 内容路由到 VttParser', () {
      const String vtt = '''
WEBVTT

00:00:01.000 --> 00:00:03.000
さようなら
''';
      final cues = parseSubtitleContent(SubtitleFormat.vtt,
          content: vtt, bookUid: bookUid);
      expect(cues, hasLength(1));
      expect(cues.first.text, 'さようなら');
    });
  });

  group('SubtitleSource', () {
    test('内嵌源序列化为 embedded:<n>，外挂源序列化为 path', () {
      const SubtitleSource embedded = SubtitleSource.embedded(
        streamIndex: 1,
        label: '内嵌 1: eng / ass',
        language: 'eng',
        codec: 'ass',
      );
      expect(embedded.toPersistedValue(), 'embedded:1');
      expect(embedded.isEmbedded, isTrue);

      const SubtitleSource external = SubtitleSource.external(
        externalPath: r'D:\v\a.ja.srt',
        label: 'a.ja.srt',
      );
      expect(external.toPersistedValue(), r'D:\v\a.ja.srt');
      expect(external.isEmbedded, isFalse);
    });

    test('matchesPersisted 区分内嵌/外挂当前选中', () {
      const SubtitleSource embedded = SubtitleSource.embedded(
        streamIndex: 1,
        label: 'x',
      );
      expect(embedded.matchesPersisted('embedded:1'), isTrue);
      expect(embedded.matchesPersisted('embedded:0'), isFalse);
      expect(embedded.matchesPersisted(r'D:\v\a.srt'), isFalse);

      const SubtitleSource external = SubtitleSource.external(
        externalPath: r'D:\v\a.srt',
        label: 'a.srt',
      );
      expect(external.matchesPersisted(r'D:\v\a.srt'), isTrue);
      expect(external.matchesPersisted('embedded:1'), isFalse);
    });
  });
}
