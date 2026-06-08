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

    test('mp4 mov_text 行含 [0x..] 十六进制流 id（新版 ffmpeg）仍解析', () {
      // 新版 ffmpeg 对 mp4 字幕流多打印一个十六进制流 id：
      //   Stream #0:1[0x2](und): Subtitle: mov_text (tx3g / 0x67337874)
      // 旧正则（#\d+:\d+ 后紧跟可选 (lang)）因这个 [0x2] 整条漏掉
      // → mp4 内封字幕枚举为 0（BUG-071 表面 2/2）。
      const String stderr = '''
  Stream #0:0[0x1](und): Video: h264 (High)
  Stream #0:1[0x2](und): Subtitle: mov_text (tx3g / 0x67337874), 0 kb/s (default)
''';
      final List<EmbeddedSubtitleTrack> tracks =
          parseSubtitleStreamsFromFfmpegLog(stderr);
      expect(tracks, hasLength(1));
      expect(tracks[0].streamIndex, 0);
      expect(tracks[0].language, 'und');
      expect(tracks[0].codec, 'mov_text');
    });

    test('mkv 无 [0x..] 与 mp4 有 [0x..] 混合：两条都解析、相对序号递增', () {
      const String stderr = '''
  Stream #0:2(jpn): Subtitle: subrip
  Stream #0:3[0x4](eng): Subtitle: mov_text
''';
      final List<EmbeddedSubtitleTrack> tracks =
          parseSubtitleStreamsFromFfmpegLog(stderr);
      expect(tracks.map((EmbeddedSubtitleTrack t) => t.codec).toList(),
          <String>['subrip', 'mov_text']);
      expect(tracks[0].streamIndex, 0);
      expect(tracks[1].streamIndex, 1);
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
    test('更多图形字幕 codec 也 → null（位图，需 OCR）', () {
      expect(subtitleFormatForCodec('dvb_subtitle'), isNull);
      expect(subtitleFormatForCodec('xsub'), isNull);
      expect(subtitleFormatForCodec('pgssub'), isNull);
    });
    test('mov_text / tx3g / text（mp4 文本字幕）→ srt（经 ffmpeg 转码，BUG-071）', () {
      expect(subtitleFormatForCodec('mov_text'), SubtitleFormat.srt);
      expect(subtitleFormatForCodec('tx3g'), SubtitleFormat.srt);
      expect(subtitleFormatForCodec('text'), SubtitleFormat.srt);
    });
    test('未知文本 codec 默认按 srt 处理（fail-open；真图形轨由 ffmpeg 转码失败兜底空）', () {
      expect(subtitleFormatForCodec('microdvd'), SubtitleFormat.srt);
      expect(subtitleFormatForCodec('subviewer'), SubtitleFormat.srt);
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

    test('isGraphicEmbedded：图形内封轨 true，文本/外挂 false（BUG-122）', () {
      // 图形（位图）内嵌轨：codec 无文本格式映射 → 不能转 cue → 交 libmpv 画面渲染。
      const SubtitleSource pgs = SubtitleSource.embedded(
        streamIndex: 0,
        label: '内封 0: jpn / hdmv_pgs_subtitle',
        codec: 'hdmv_pgs_subtitle',
      );
      expect(pgs.isGraphicEmbedded, isTrue);
      expect(
        const SubtitleSource.embedded(
                streamIndex: 1, label: 'x', codec: 'dvd_subtitle')
            .isGraphicEmbedded,
        isTrue,
      );

      // 文本内嵌轨（ass/subrip/mov_text）：能转 cue → 不是图形轨。
      expect(
        const SubtitleSource.embedded(streamIndex: 0, label: 'x', codec: 'ass')
            .isGraphicEmbedded,
        isFalse,
      );
      expect(
        const SubtitleSource.embedded(
                streamIndex: 0, label: 'x', codec: 'subrip')
            .isGraphicEmbedded,
        isFalse,
      );
      expect(
        const SubtitleSource.embedded(
                streamIndex: 0, label: 'x', codec: 'mov_text')
            .isGraphicEmbedded,
        isFalse,
      );

      // 未知/空 codec：fail-open 当文本（subtitleFormatForCodec→srt）→ 非图形。
      expect(
        const SubtitleSource.embedded(streamIndex: 0, label: 'x')
            .isGraphicEmbedded,
        isFalse,
      );

      // 外挂源恒非图形（codec 永远 null，但 isEmbedded=false 先短路）。
      expect(
        const SubtitleSource.external(externalPath: r'D:\v\a.srt', label: 'a')
            .isGraphicEmbedded,
        isFalse,
      );
    });
  });

  group('firstSubtitlePath', () {
    test('从混合路径里挑第一个受支持字幕', () {
      expect(
        firstSubtitlePath(<String>[
          r'C:\v\EP01.mkv',
          r'C:\v\EP01.ja.srt',
          r'C:\v\cover.jpg',
        ]),
        r'C:\v\EP01.ja.srt',
      );
    });

    test('支持 srt/ass/ssa/vtt 四类，大小写不敏感', () {
      expect(firstSubtitlePath(<String>['/a/x.Srt']), '/a/x.Srt');
      expect(firstSubtitlePath(<String>['/a/x.ASS']), '/a/x.ASS');
      expect(firstSubtitlePath(<String>['/a/x.Ssa']), '/a/x.Ssa');
      expect(firstSubtitlePath(<String>['/a/x.VTT']), '/a/x.VTT');
    });

    test('无受支持字幕返回 null', () {
      expect(
        firstSubtitlePath(<String>['/a/v.mp4', '/a/n.txt', '/a/i.png']),
        isNull,
      );
    });

    test('空列表返回 null', () {
      expect(firstSubtitlePath(const <String>[]), isNull);
    });
  });

  group('embeddedSubtitleCacheKey（BUG-104 缓存键）', () {
    test('同名+同尺寸+同 mtime → 同键（命中缓存）', () {
      expect(
        embeddedSubtitleCacheKey('movie', 27000000000, 1700000000000),
        embeddedSubtitleCacheKey('movie', 27000000000, 1700000000000),
      );
    });

    test('文件被原地替换（尺寸或 mtime 变）→ 键变（不吃旧缓存）', () {
      final String base = embeddedSubtitleCacheKey('movie', 1000, 111);
      expect(embeddedSubtitleCacheKey('movie', 2000, 111), isNot(base));
      expect(embeddedSubtitleCacheKey('movie', 1000, 222), isNot(base));
    });

    test('基名里的非法目录字符折叠为下划线', () {
      final String key =
          embeddedSubtitleCacheKey('My Movie:S01 (BD)/x', 10, 20);
      expect(key, isNot(contains(' ')));
      expect(key, isNot(contains(':')));
      expect(key, isNot(contains('/')));
      expect(key, isNot(contains('(')));
      expect(key, startsWith('My_Movie_S01_'));
      expect(key, endsWith('_10_20'));
    });
  });

  group('subtitleExtractTimeoutForBytes（BUG-104 超时按体积放宽）', () {
    test('小文件取 ~60s 下限（不再是固定 30s 静默失败）', () {
      expect(subtitleExtractTimeoutForBytes(0).inSeconds, 60);
      // 100MB ≈ 0.1GB → 60 + 0.1*8 ≈ 61s，紧贴下限、远超旧 30s。
      final int small =
          subtitleExtractTimeoutForBytes(100 * 1024 * 1024).inSeconds;
      expect(small, inInclusiveRange(60, 61));
      expect(small, greaterThan(30));
    });

    test('27GB REMUX 远超旧 30s（实测单趟 demux ~20s，给足裕量）', () {
      const int gb27 = 27 * 1024 * 1024 * 1024;
      final int seconds = subtitleExtractTimeoutForBytes(gb27).inSeconds;
      // 60 + 27*8 = 276s。
      expect(seconds, 276);
      expect(seconds, greaterThan(30));
    });

    test('超大文件夹紧到 1200s 上限', () {
      const int gb1000 = 1000 * 1024 * 1024 * 1024;
      expect(subtitleExtractTimeoutForBytes(gb1000).inSeconds, 1200);
    });

    test('随体积单调不减', () {
      final int t1 =
          subtitleExtractTimeoutForBytes(5 * 1024 * 1024 * 1024).inSeconds;
      final int t2 =
          subtitleExtractTimeoutForBytes(50 * 1024 * 1024 * 1024).inSeconds;
      expect(t2, greaterThanOrEqualTo(t1));
    });
  });

  group('isImportedExternalSubtitlePath (BUG-126)', () {
    test('app 文档目录里的导入字幕路径 → true（应直接按路径恢复）', () {
      expect(
        isImportedExternalSubtitlePath(
            '/data/app/docs/video_subtitles/Show S01E01.ja.srt'),
        isTrue,
      );
      expect(
        isImportedExternalSubtitlePath('C:/docs/video_subtitles/movie.ass'),
        isTrue,
      );
    });

    test('内嵌轨指针 embedded:<n> → false（不按路径恢复，走内封枚举）', () {
      expect(isImportedExternalSubtitlePath('embedded:0'), isFalse);
      expect(isImportedExternalSubtitlePath('embedded:3'), isFalse);
    });

    test('空 / 非字幕扩展名 → false', () {
      expect(isImportedExternalSubtitlePath(''), isFalse);
      expect(isImportedExternalSubtitlePath('/x/video.mkv'), isFalse);
      expect(isImportedExternalSubtitlePath('/x/cover.png'), isFalse);
    });

    test('四种受支持字幕扩展名都识别（大小写不敏感）', () {
      for (final String ext in <String>['srt', 'ass', 'ssa', 'vtt']) {
        expect(isImportedExternalSubtitlePath('/d/sub.$ext'), isTrue,
            reason: ext);
        expect(isImportedExternalSubtitlePath('/d/SUB.${ext.toUpperCase()}'),
            isTrue,
            reason: ext);
      }
    });
  });
}
