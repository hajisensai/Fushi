import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki/src/media/video/ffmpeg_backend.dart';
import 'package:hibiki/src/media/video/video_subtitle_source.dart';
import 'package:path/path.dart' as p;

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

  group('parseSubtitleContentAsync (TODO-475 async parser route)', () {
    const String bookUid = 'video_book_x://book/async';

    test('routes small vtt content through the async parser entry point',
        () async {
      const String vtt = '''
WEBVTT

00:00:01.000 --> 00:00:03.000
hello async vtt
''';

      final List<AudioCue> cues = await parseSubtitleContentAsync(
        SubtitleFormat.vtt,
        content: vtt,
        bookUid: bookUid,
      );

      expect(cues, hasLength(1));
      expect(cues.single.bookKey, bookUid);
      expect(cues.single.text, 'hello async vtt');
    });

    test('parses large srt content through the async entry point', () async {
      final String srt = _largeSrt(cueCount: 5000);
      expect(srt.length, greaterThan(1024 * 1024),
          reason: 'The large-content path should be exercised.');

      final List<AudioCue> cues = await parseSubtitleContentAsync(
        SubtitleFormat.srt,
        content: srt,
        bookUid: bookUid,
      );

      expect(cues, hasLength(5000));
      expect(cues.first.text, startsWith('large async srt cue 0'));
      expect(cues.last.text, startsWith('large async srt cue 4999'));
    });

    test('parses large ass content through the async entry point', () async {
      final String ass = _largeAss(cueCount: 5000);
      expect(ass.length, greaterThan(1024 * 1024),
          reason: 'The large-content path should be exercised.');

      final List<AudioCue> cues = await parseSubtitleContentAsync(
        SubtitleFormat.ass,
        content: ass,
        bookUid: bookUid,
      );

      expect(cues, hasLength(5000));
      expect(cues.first.text, startsWith('large async ass cue 0'));
      expect(cues.last.text, startsWith('large async ass cue 4999'));
    });

    test('parses large vtt content through the async entry point', () async {
      final String vtt = _largeVtt(cueCount: 5000);
      expect(vtt.length, greaterThan(1024 * 1024),
          reason: 'The large-content path should be exercised.');

      final List<AudioCue> cues = await parseSubtitleContentAsync(
        SubtitleFormat.vtt,
        content: vtt,
        bookUid: bookUid,
      );

      expect(cues, hasLength(5000));
      expect(cues.first.text, startsWith('large async cue 0'));
      expect(cues.last.text, startsWith('large async cue 4999'));
    });

    test('video subtitle load paths await the async parser entry point', () {
      final String source = File(
        p.join(
          Directory.current.path,
          'lib',
          'src',
          'media',
          'video',
          'video_subtitle_source.dart',
        ),
      ).readAsStringSync();

      expect(
        _functionBody(source, 'Future<List<AudioCue>> _loadEmbeddedCues'),
        contains('await parseSubtitleContentAsync('),
      );
      expect(
        _functionBody(source, 'Future<List<AudioCue>> _loadExternalCues'),
        contains('await parseSubtitleContentAsync('),
      );
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

  group('isImportedExternalSubtitlePath (BUG-132)', () {
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

  group('includeCurrentPersistedSubtitleForMenu (TODO-016)', () {
    late Directory tempDir;
    late File video;
    late File imported;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('hibiki_todo016_menu_');
      video = File(p.join(tempDir.path, 'Miss Kobayashi S01E01.mkv'))
        ..writeAsStringSync('fake video bytes');
      imported = File(p.join(
        tempDir.path,
        'video_subtitles',
        'todo016-imported-reentry.srt',
      ))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
1
00:00:00,000 --> 00:00:01,000
TODO016 imported subtitle survives reopen.
''');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
        'uses already loaded cues as evidence for the current persisted source',
        () async {
      final List<SubtitleSource> sources =
          await includeCurrentPersistedSubtitleForMenu(
        const <SubtitleSource>[
          SubtitleSource.embedded(streamIndex: 0, label: '内封 0: eng / ass'),
        ],
        videoPath: video.path,
        bookUid: 'video/todo016',
        currentSubtitleSource: imported.path,
        currentCues: <AudioCue>[
          _cue('video/todo016', 'TODO016 imported subtitle survives reopen.'),
        ],
        loadCues: (_, __, ___) {
          fail('已有 DB cues 时菜单不应再因为二次解析失败隐藏当前持久化字幕源');
        },
      );

      expect(
        sources.map((SubtitleSource s) => s.label).toList(),
        <String>[
          'todo016-imported-reentry.srt',
          '内封 0: eng / ass',
        ],
      );
    });

    test('parses the current persisted source when no cues are loaded',
        () async {
      final List<SubtitleSource> sources =
          await includeCurrentPersistedSubtitleForMenu(
        const <SubtitleSource>[],
        videoPath: video.path,
        bookUid: 'video/todo016',
        currentSubtitleSource: imported.path,
      );

      expect(sources, hasLength(1));
      expect(sources.single.externalPath, imported.path);
    });

    test('dedupes an existing source for the same canonical path', () async {
      final List<SubtitleSource> sources =
          await includeCurrentPersistedSubtitleForMenu(
        <SubtitleSource>[
          SubtitleSource.external(
            externalPath: p.normalize(imported.path),
            label: 'already-listed.srt',
          ),
        ],
        videoPath: video.path,
        bookUid: 'video/todo016',
        currentSubtitleSource: imported.path,
        currentCues: <AudioCue>[_cue('video/todo016', 'already loaded')],
      );

      expect(sources, hasLength(1));
      expect(sources.single.label, 'already-listed.srt');
    });
  });

  group('embedded subtitle cache prewarm (TODO-011)', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('hibiki_vsub_prewarm_');
    });

    tearDown(() {
      setFfmpegBackendForTesting(null);
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('prewarm extracts all text embedded subtitles without parsing cues',
        () async {
      final File video = File(p.join(tempDir.path, 'movie.mkv'))
        ..writeAsStringSync('fake video bytes');
      final _FakeFfmpegBackend backend = _FakeFfmpegBackend();
      setFfmpegBackendForTesting(backend);

      await prewarmEmbeddedSubtitleCache(video.path);

      expect(backend.probeCount, 1);
      expect(backend.extractCount, 1);
      expect(backend.extractedSubtitleIndices, <int>[0, 1]);
      final Directory cacheDir = embeddedSubtitleCacheDir(video.path);
      expect(File(p.join(cacheDir.path, 'sub_0.srt')).existsSync(), isTrue);
      expect(File(p.join(cacheDir.path, 'sub_1.ass')).existsSync(), isTrue);
      expect(
        File(p.join(cacheDir.path, 'sub_2.srt')).existsSync(),
        isFalse,
        reason: 'PGS/image subtitles must not be prewarmed into text overlay.',
      );
    });

    test('manual switch reuses a pending background extraction', () async {
      final File video = File(p.join(tempDir.path, 'pending.mkv'))
        ..writeAsStringSync('fake video bytes');
      final _FakeFfmpegBackend backend = _FakeFfmpegBackend.blockingExtract();
      setFfmpegBackendForTesting(backend);

      final Future<void> prewarm = prewarmEmbeddedSubtitleCache(video.path);
      await backend.extractStarted.future;

      final Future<List<AudioCue>> manualLoad = loadCuesForSource(
        const SubtitleSource.embedded(
          streamIndex: 0,
          label: '内封 0: jpn / subrip',
          language: 'jpn',
          codec: 'subrip',
        ),
        video.path,
        'video_book_x://book/pending',
      );

      await Future<void>.delayed(Duration.zero);
      expect(backend.extractCount, 1,
          reason: 'manual switch should await the pending prewarm task.');

      backend.completeExtract();
      await prewarm;
      final List<AudioCue> cues = await manualLoad;

      expect(backend.extractCount, 1);
      expect(cues, isNotEmpty);
    });

    test(
        'two playlist episode prewarms keep separate caches for later switches',
        () async {
      final File first = File(p.join(tempDir.path, 'episode1.mkv'))
        ..writeAsStringSync('fake episode 1 bytes');
      final File second = File(p.join(tempDir.path, 'episode2.mkv'))
        ..writeAsStringSync('fake episode 2 bytes');
      final _FakeFfmpegBackend backend = _FakeFfmpegBackend();
      setFfmpegBackendForTesting(backend);

      await prewarmEmbeddedSubtitleCache(first.path);
      await prewarmEmbeddedSubtitleCache(second.path);

      expect(backend.extractCount, 2);
      expect(
        File(p.join(embeddedSubtitleCacheDir(first.path).path, 'sub_0.srt'))
            .existsSync(),
        isTrue,
      );
      expect(
        File(p.join(embeddedSubtitleCacheDir(second.path).path, 'sub_0.srt'))
            .existsSync(),
        isTrue,
      );

      final List<AudioCue> secondCues = await loadCuesForSource(
        const SubtitleSource.embedded(
          streamIndex: 0,
          label: '内封 0: jpn / subrip',
          language: 'jpn',
          codec: 'subrip',
        ),
        second.path,
        'video_book_x://book/episode2',
      );

      expect(secondCues, isNotEmpty);
      expect(backend.extractCount, 2,
          reason: 'manual switch for prewarmed next episode must hit cache');
    });

    test('prewarm failures complete without affecting later manual fallback',
        () async {
      final File video = File(p.join(tempDir.path, 'broken.mkv'))
        ..writeAsStringSync('fake video bytes');
      final _FakeFfmpegBackend backend =
          _FakeFfmpegBackend(extractReturnCode: 1, writeOutputs: false);
      setFfmpegBackendForTesting(backend);

      await prewarmEmbeddedSubtitleCache(video.path);

      final List<AudioCue> cues = await loadCuesForSource(
        const SubtitleSource.embedded(
          streamIndex: 0,
          label: '内封 0: jpn / subrip',
          language: 'jpn',
          codec: 'subrip',
        ),
        video.path,
        'video_book_x://book/broken',
      );

      expect(cues, isEmpty);
      expect(backend.extractCount, 2,
          reason: 'failed prewarm must clear in-flight state for fallback.');
    });
  });

  group('listEmbeddedSubtitleTracks 超时 size-scaled（BUG-303 / TODO-412）', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('hibiki_vsub_enum_');
    });

    tearDown(() {
      setFfmpegBackendForTesting(null);
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test(
        '真实 BanG Dream S01E01 ffmpeg -i 日志（1 条 ass + attachment 流 + '
        '"Could not find codec parameters" 警告）枚举出 1 条字幕', () {
      // 本机对真文件 `ffmpeg -hide_banner -i` 的真实 stderr：那条 ass 字幕轨在
      // 一连串 attachment 流的 "Could not find codec parameters" 警告之后。
      // 守住「解析层永远能从这段真实日志里挑出那条 ass」——根因不在解析。
      const String stderr = '''
[in#0/matroska,webm @ 0] Could not find codec parameters for stream 3 (Attachment: none): unknown codec
[in#0/matroska,webm @ 0] Could not find codec parameters for stream 16 (Attachment: none): unknown codec
[in#0/matroska,webm @ 0] Could not find codec parameters for stream 17 (Attachment: none): unknown codec
Input #0, matroska,webm, from 'BanG Dream! - S01E01.mkv':
  Stream #0:0(zxx): Video: hevc (Main 10), yuv420p10le, 1920x1080 (default)
  Stream #0:1(jpn): Audio: flac, 48000 Hz, stereo (default)
  Stream #0:2(eng): Subtitle: ass (ssa) (default)
  Stream #0:3: Attachment: none
  Stream #0:17: Attachment: none
At least one output file must be specified
''';
      final List<EmbeddedSubtitleTrack> tracks =
          parseSubtitleStreamsFromFfmpegLog(stderr);
      expect(tracks, hasLength(1));
      expect(tracks.single.streamIndex, 0);
      expect(tracks.single.language, 'eng');
      expect(tracks.single.codec, 'ass');
    });

    test(
        '枚举 -i 的超时随容器体积放大（不再固定 30s）——用 '
        'subtitleExtractTimeoutForBytes，与抽取路径一致', () async {
      // 根因：原固定 30s 超时，大体积交错容器在冷缓存 + 并发抽取 + 播放争用磁盘
      // 时 `-i` 探测可能超时 → 返回空 → 菜单「一个字幕没有」。捕获实际传给后端的
      // timeout，断言它等于按文件字节算的 size-scaled 值，且 > 旧的 30s。
      final File big = File(p.join(tempDir.path, 'big.mkv'))
        ..writeAsBytesSync(List<int>.filled(2048, 0));
      final int realSize = big.lengthSync();
      final _TimeoutCapturingBackend backend = _TimeoutCapturingBackend();
      setFfmpegBackendForTesting(backend);

      final List<EmbeddedSubtitleTrack> tracks =
          await listEmbeddedSubtitleTracks(big.path);

      expect(backend.lastTimeout, isNotNull);
      expect(backend.lastTimeout, subtitleExtractTimeoutForBytes(realSize));
      expect(backend.lastTimeout!.inSeconds, greaterThan(30),
          reason: '固定 30s 已被 size-scaled 超时取代（下限 60s）');
      expect(tracks, hasLength(1));
      expect(tracks.single.codec, 'ass');
    });

    test('1GB 与 27GB 容器的枚举超时 = 抽取路径同一公式（回归 BUG-104 同源）', () {
      const int oneGb = 1024 * 1024 * 1024;
      const int twentySevenGb = 27 * oneGb;
      expect(subtitleExtractTimeoutForBytes(oneGb).inSeconds, greaterThan(30));
      expect(subtitleExtractTimeoutForBytes(twentySevenGb).inSeconds,
          greaterThan(200));
    });

    test('诊断 API 区分枚举 timeout 与真无字幕', () async {
      final File video = File(p.join(tempDir.path, 'timeout.mkv'))
        ..writeAsBytesSync(<int>[0, 1, 2]);
      setFfmpegBackendForTesting(
        const _ProbeResultBackend(
          FfmpegRunResult(returnCode: null, output: ''),
        ),
      );

      final EmbeddedSubtitleTrackProbeResult timedOut =
          await probeEmbeddedSubtitleTracks(video.path);

      expect(timedOut.status, EmbeddedSubtitleTrackProbeStatus.timeout);
      expect(timedOut.tracks, isEmpty);
      expect(
          timedOut.timeout, subtitleExtractTimeoutForBytes(video.lengthSync()));

      setFfmpegBackendForTesting(
        const _ProbeResultBackend(
          FfmpegRunResult(
            returnCode: 1,
            output: '  Stream #0:0: Video: h264\n'
                'At least one output file must be specified',
          ),
        ),
      );

      final EmbeddedSubtitleTrackProbeResult noSubtitles =
          await probeEmbeddedSubtitleTracks(video.path);

      expect(noSubtitles.status, EmbeddedSubtitleTrackProbeStatus.success);
      expect(noSubtitles.tracks, isEmpty);
    });
  });

  group('默认文本内封字幕加载（TODO-446）', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('hibiki_vsub_default_');
    });

    tearDown(() {
      setFfmpegBackendForTesting(null);
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('跳过 PGS/DVD 图形轨，默认抽第一条可转 cue 的文本轨', () async {
      final File video = File(p.join(tempDir.path, 'movie.mkv'))
        ..writeAsBytesSync(<int>[1, 2, 3, 4]);
      final _DefaultSubtitleFfmpegBackend backend =
          _DefaultSubtitleFfmpegBackend();
      setFfmpegBackendForTesting(backend);

      final DefaultEmbeddedSubtitleLoadResult result =
          await loadDefaultTextEmbeddedSubtitleCues(
        videoPath: video.path,
        bookUid: 'video/book',
      );

      expect(result.status, DefaultEmbeddedSubtitleLoadStatus.loaded);
      expect(result.source?.streamIndex, 1,
          reason: 'stream 0 is PGS and must stay out of searchable cues');
      expect(result.cues.map((AudioCue c) => c.text), <String>['hello mov']);
      expect(backend.extractedSubtitleIndices, <int>[1],
          reason:
              'default load should demux the first text-capable track only');
    });

    test('文本轨抽取为空时返回可提示的失败状态，不静默空屏', () async {
      final File video = File(p.join(tempDir.path, 'bad-text.mkv'))
        ..writeAsBytesSync(<int>[1, 2, 3, 4]);
      setFfmpegBackendForTesting(
        _DefaultSubtitleFfmpegBackend(writeOutputs: false),
      );

      final DefaultEmbeddedSubtitleLoadResult result =
          await loadDefaultTextEmbeddedSubtitleCues(
        videoPath: video.path,
        bookUid: 'video/book',
      );

      expect(result.status, DefaultEmbeddedSubtitleLoadStatus.emptyCues);
      expect(result.source?.streamIndex, 1);
      expect(result.cues, isEmpty);
    });

    test('真实 ffmpeg 合成 mkv+SRT 与 mp4 mov_text 都能默认显示文本内封', () async {
      final String? ffmpeg = await _workingFfmpegExecutable();
      if (ffmpeg == null) {
        markTestSkipped('ffmpeg 不可用，跳过合成内封字幕自验');
        return;
      }
      setFfmpegBackendForTesting(null);
      final File srt = File(p.join(tempDir.path, 'sample.srt'))
        ..writeAsStringSync('''
1
00:00:00,000 --> 00:00:01,000
synthetic subtitle
''');

      final File mkv = File(p.join(tempDir.path, 'sample.mkv'));
      final String? mkvError = await _runFfmpeg(
        ffmpeg,
        <String>[
          '-y',
          '-f',
          'lavfi',
          '-i',
          'color=c=black:s=16x16:d=2',
          '-f',
          'srt',
          '-i',
          srt.path,
          '-map',
          '0:v:0',
          '-map',
          '1:0',
          '-c:v',
          'mpeg4',
          '-c:s',
          'srt',
          '-t',
          '2',
          mkv.path,
        ],
      );
      if (mkvError != null) {
        markTestSkipped('ffmpeg 无法合成 mkv+srt: $mkvError');
        return;
      }

      final DefaultEmbeddedSubtitleLoadResult mkvResult =
          await loadDefaultTextEmbeddedSubtitleCues(
        videoPath: mkv.path,
        bookUid: 'video/mkv',
      );
      expect(mkvResult.status, DefaultEmbeddedSubtitleLoadStatus.loaded);
      expect(mkvResult.source?.codec, 'subrip');
      expect(mkvResult.cues.single.text, 'synthetic subtitle');

      final File mp4 = File(p.join(tempDir.path, 'sample.mp4'));
      final String? mp4Error = await _runFfmpeg(
        ffmpeg,
        <String>[
          '-y',
          '-f',
          'lavfi',
          '-i',
          'color=c=black:s=16x16:d=2',
          '-f',
          'srt',
          '-i',
          srt.path,
          '-map',
          '0:v:0',
          '-map',
          '1:0',
          '-c:v',
          'mpeg4',
          '-c:s',
          'mov_text',
          '-t',
          '2',
          mp4.path,
        ],
      );
      if (mp4Error != null) {
        markTestSkipped('ffmpeg 无法合成 mp4 mov_text: $mp4Error');
        return;
      }

      final DefaultEmbeddedSubtitleLoadResult mp4Result =
          await loadDefaultTextEmbeddedSubtitleCues(
        videoPath: mp4.path,
        bookUid: 'video/mp4',
      );
      expect(mp4Result.status, DefaultEmbeddedSubtitleLoadStatus.loaded);
      expect(mp4Result.source?.codec, 'mov_text');
      expect(mp4Result.cues.single.text, 'synthetic subtitle');
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}

AudioCue _cue(String bookKey, String text) {
  return AudioCue()
    ..bookKey = bookKey
    ..chapterHref = 'video://default'
    ..sentenceIndex = 0
    ..textFragmentId = ''
    ..text = text
    ..startMs = 0
    ..endMs = 1000
    ..audioFileIndex = 0;
}

String _largeSrt({required int cueCount}) {
  final String filler = List<String>.filled(240, 'x').join();
  final StringBuffer buffer = StringBuffer();
  for (int i = 0; i < cueCount; i++) {
    final int startMs = i * 1000;
    buffer
      ..writeln(i + 1)
      ..writeln('${_srtTimestamp(startMs)} --> '
          '${_srtTimestamp(startMs + 750)}')
      ..writeln('<i>large async srt cue $i</i> $filler')
      ..writeln();
  }
  return buffer.toString();
}

String _largeAss({required int cueCount}) {
  final String filler = List<String>.filled(240, 'y').join();
  final StringBuffer buffer = StringBuffer('''
[Script Info]
PlayResX: 1920
PlayResY: 1080

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
''');
  for (int i = 0; i < cueCount; i++) {
    final int startMs = i * 1000;
    buffer.writeln('Dialogue: 0,${_assTimestamp(startMs)},'
        '${_assTimestamp(startMs + 750)},Default,,0,0,0,,'
        '{\\an8}large async ass cue $i $filler');
  }
  return buffer.toString();
}

String _largeVtt({required int cueCount}) {
  final String filler = List<String>.filled(240, 'x').join();
  final StringBuffer buffer = StringBuffer('WEBVTT\n\n');
  for (int i = 0; i < cueCount; i++) {
    final int startMs = i * 1000;
    buffer
      ..writeln(i)
      ..writeln('${_vttTimestamp(startMs)} --> '
          '${_vttTimestamp(startMs + 750)}')
      ..writeln('large async cue $i $filler')
      ..writeln();
  }
  return buffer.toString();
}

String _srtTimestamp(int millis) {
  return _subtitleTimestamp(millis, millisecondSeparator: ',');
}

String _vttTimestamp(int millis) {
  return _subtitleTimestamp(millis, millisecondSeparator: '.');
}

String _subtitleTimestamp(
  int millis, {
  required String millisecondSeparator,
}) {
  final int hours = millis ~/ 3600000;
  final int minutes = (millis ~/ 60000) % 60;
  final int seconds = (millis ~/ 1000) % 60;
  final int ms = millis % 1000;
  return '${hours.toString().padLeft(2, '0')}:'
      '${minutes.toString().padLeft(2, '0')}:'
      '${seconds.toString().padLeft(2, '0')}$millisecondSeparator'
      '${ms.toString().padLeft(3, '0')}';
}

String _assTimestamp(int millis) {
  final int hours = millis ~/ 3600000;
  final int minutes = (millis ~/ 60000) % 60;
  final int seconds = (millis ~/ 1000) % 60;
  final int centiseconds = (millis % 1000) ~/ 10;
  return '$hours:${minutes.toString().padLeft(2, '0')}:'
      '${seconds.toString().padLeft(2, '0')}.'
      '${centiseconds.toString().padLeft(2, '0')}';
}

String _functionBody(String source, String signature) {
  final int start = source.indexOf(signature);
  if (start < 0) return '';
  final int open = source.indexOf('{', start);
  if (open < 0) return '';
  int depth = 0;
  for (int i = open; i < source.length; i++) {
    final String char = source[i];
    if (char == '{') {
      depth++;
    } else if (char == '}') {
      depth--;
      if (depth == 0) return source.substring(open, i + 1);
    }
  }
  return source.substring(open);
}

class _FakeFfmpegBackend implements FfmpegBackend {
  _FakeFfmpegBackend({
    this.extractReturnCode = 0,
    this.writeOutputs = true,
  }) : _blockExtract = false;

  _FakeFfmpegBackend.blockingExtract()
      : extractReturnCode = 0,
        writeOutputs = true,
        _blockExtract = true;

  final int extractReturnCode;
  final bool writeOutputs;
  final bool _blockExtract;

  int probeCount = 0;
  int extractCount = 0;
  final List<int> extractedSubtitleIndices = <int>[];
  final Completer<void> extractStarted = Completer<void>();
  final Completer<void> _allowExtract = Completer<void>();

  void completeExtract() {
    if (!_allowExtract.isCompleted) _allowExtract.complete();
  }

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async {
    if (args.contains('-hide_banner')) {
      probeCount++;
      return const FfmpegRunResult(returnCode: 1, output: '''
  Stream #0:0: Video: h264
  Stream #0:1(jpn): Subtitle: subrip (srt) (default)
  Stream #0:2(eng): Subtitle: ass (ssa)
  Stream #0:3(jpn): Subtitle: hdmv_pgs_subtitle
''');
    }

    extractCount++;
    if (!extractStarted.isCompleted) extractStarted.complete();
    if (_blockExtract) await _allowExtract.future;

    for (int i = 0; i < args.length - 2; i++) {
      if (args[i] == '-map' && args[i + 1].startsWith('0:s:')) {
        final int index = int.parse(args[i + 1].substring('0:s:'.length));
        extractedSubtitleIndices.add(index);
        if (writeOutputs) {
          final File output = File(args[i + 2]);
          output.parent.createSync(recursive: true);
          output.writeAsStringSync(_subtitleTextFor(output.path));
        }
      }
    }
    return FfmpegRunResult(returnCode: extractReturnCode, output: '');
  }

  String _subtitleTextFor(String outputPath) {
    if (outputPath.toLowerCase().endsWith('.ass')) {
      return '''
[Script Info]
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,hello
''';
    }
    return '''
1
00:00:01,000 --> 00:00:02,000
こんにちは
''';
  }
}

class _TimeoutCapturingBackend implements FfmpegBackend {
  Duration? lastTimeout;

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async {
    lastTimeout = timeout;
    // Mimic a working `ffmpeg -i` enumeration of a single ass embedded track.
    return const FfmpegRunResult(
      returnCode: 1,
      output: '  Stream #0:2(eng): Subtitle: ass (ssa) (default)\n'
          'At least one output file must be specified',
    );
  }
}

class _ProbeResultBackend implements FfmpegBackend {
  const _ProbeResultBackend(this.result);

  final FfmpegRunResult result;

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async {
    return result;
  }
}

class _DefaultSubtitleFfmpegBackend implements FfmpegBackend {
  _DefaultSubtitleFfmpegBackend({this.writeOutputs = true});

  final bool writeOutputs;
  final List<int> extractedSubtitleIndices = <int>[];

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async {
    if (args.contains('-hide_banner')) {
      return const FfmpegRunResult(returnCode: 1, output: '''
  Stream #0:0: Video: h264
  Stream #0:1(jpn): Subtitle: hdmv_pgs_subtitle
  Stream #0:2(jpn): Subtitle: mov_text (tx3g / 0x67337874) (default)
  Stream #0:3(eng): Subtitle: dvd_subtitle
''');
    }

    for (int i = 0; i < args.length - 2; i++) {
      if (args[i] == '-map' && args[i + 1].startsWith('0:s:')) {
        final int index = int.parse(args[i + 1].substring('0:s:'.length));
        extractedSubtitleIndices.add(index);
        if (writeOutputs) {
          final File output = File(args[i + 2]);
          output.parent.createSync(recursive: true);
          output.writeAsStringSync('''
1
00:00:01,000 --> 00:00:02,000
hello mov
''');
        }
      }
    }
    return const FfmpegRunResult(returnCode: 0, output: '');
  }
}

Future<String?> _workingFfmpegExecutable() async {
  for (final String executable in <String>[
    'ffmpeg',
    p.normalize('../third_party/ffmpeg-min/windows/ffmpeg.exe'),
  ]) {
    try {
      final ProcessResult result = await Process.run(
        executable,
        <String>['-hide_banner', '-version'],
      ).timeout(const Duration(seconds: 10));
      if (result.exitCode == 0) return executable;
    } catch (_) {
      // Try the next candidate.
    }
  }
  return null;
}

Future<String?> _runFfmpeg(String executable, List<String> args) async {
  try {
    final ProcessResult result = await Process.run(
      executable,
      args,
    ).timeout(const Duration(seconds: 20));
    if (result.exitCode == 0) return null;
    return '${result.exitCode}: ${result.stderr}'.trim();
  } catch (e) {
    return e.toString();
  }
}
