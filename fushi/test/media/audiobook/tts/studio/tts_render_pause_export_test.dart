import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_audiobook_export.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_render_encode.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_render_mix.dart';
import 'package:fushi/src/media/audiobook/tts/tts_book_plan.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_engine/epub/epub_book.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/tts/render/tts_pause.dart';
import 'package:fushi_engine/tts/render/tts_render_queue.dart';
import 'package:path/path.dart' as p;

EpubBook _book(String body) => EpubBook(
  title: 'b',
  chapters: <EpubChapter>[
    EpubChapter(
      id: 'c',
      href: 'c.xhtml',
      mediaType: 'application/xhtml+xml',
      html: '<html><body>$body</body></html>',
    ),
  ],
);

TtsPlanSentence _s(String text, {bool paragraph = false, bool scene = false}) =>
    TtsPlanSentence(
      section: 0,
      href: 'c.xhtml',
      text: text,
      spokenText: text,
      matchStart: 0,
      matchEnd: 1,
      studyStart: 0,
      studyEnd: 0,
      endsParagraph: paragraph,
      sceneBreakAfter: scene,
    );

AudioCue _cue(int file, int start, int end, String href) => AudioCue()
  ..bookKey = 'b'
  ..chapterHref = href
  ..sentenceIndex = 0
  ..textFragmentId = ''
  ..text = 'x'
  ..startMs = start
  ..endMs = end
  ..audioFileIndex = file;

/// [rate] Hz 单声道 16-bit 方波 WAV。
Uint8List _toneWav(int ms, {int rate = 24000}) {
  final Uint8List bytes = buildTtsSilenceWav(
    ms: ms,
    sampleRate: rate,
    channels: 1,
  );
  final ByteData b = ByteData.sublistView(bytes);
  for (int i = 0; 44 + i * 2 + 1 < bytes.length; i++) {
    b.setInt16(44 + i * 2, (i ~/ 10).isEven ? 6000 : -6000, Endian.little);
  }
  return bytes;
}

/// 解码出的 mov（pcm_s16le 单声道）里的样本。
Int16List _movPcmSamples(Uint8List bytes) {
  final ByteData d = ByteData.sublistView(bytes);
  int offset = 0;
  while (offset + 8 <= bytes.length) {
    int size = d.getUint32(offset);
    final String type = String.fromCharCodes(
      bytes.sublist(offset + 4, offset + 8),
    );
    int header = 8;
    if (size == 1) {
      size = d.getUint64(offset + 8);
      header = 16;
    }
    if (type == 'mdat') {
      final int count = (size - header) ~/ 2;
      final Int16List out = Int16List(count);
      for (int i = 0; i < count; i++) {
        out[i] = d.getInt16(offset + header + i * 2, Endian.little);
      }
      return out;
    }
    offset += size;
  }
  throw StateError('no mdat');
}

/// 5 ms 窗 RMS 从静到响的时刻（毫秒）。
List<int> _toneOnsetsMs(Int16List samples, int rate) {
  final int window = rate * 5 ~/ 1000;
  final List<int> onsets = <int>[];
  bool loud = false;
  for (int start = 0; start + window <= samples.length; start += window) {
    double sum = 0;
    for (int i = start; i < start + window; i++) {
      sum += samples[i] * samples[i];
    }
    final bool nowLoud = sum / window > 500 * 500;
    if (nowLoud && !loud) onsets.add(start * 1000 ~/ rate);
    loud = nowLoud;
  }
  return onsets;
}

/// 指定可执行文件的 ffmpeg 后端（测完整版 ffmpeg 的能力用）。
class _ExeBackend implements FfmpegBackend {
  const _ExeBackend(this.exe);

  final String exe;

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) =>
      runFfmpegProcess(exe, args, timeout);

  @override
  Future<FfmpegRunResult> runQuery(List<String> args, Duration timeout) =>
      runFfmpegQueryProcess(exe, args, timeout);

  @override
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout) =>
      throw UnsupportedError('runProbe');
}

/// 一章「三句 + standard 停顿」的冒烟：编码、解码、比对句首时刻与总时长。
Future<void> _pauseSmoke(
  FfmpegBackend backend, {
  required bool loudnorm,
}) async {
  final Directory tmp = await Directory.systemTemp.createTemp('tts_pause');
  addTearDown(() => tmp.delete(recursive: true));
  final List<({String key, String path, int durationMs})> sentences =
      <({String key, String path, int durationMs})>[];
  for (final (String key, int ms) in <(String, int)>[
    ('a', 600),
    ('b', 400),
    ('c', 300),
  ]) {
    final File f = File(p.join(tmp.path, 'cache', '$key.audio'));
    await f.parent.create(recursive: true);
    await f.writeAsBytes(_toneWav(ms));
    sentences.add((key: key, path: f.path, durationMs: ms));
  }
  final List<TtsPlanSentence> plan = <TtsPlanSentence>[
    _s('a', paragraph: true),
    _s('b', paragraph: true, scene: true),
    _s('c', paragraph: true),
  ];
  final TtsRenderChapter chapter = groupTtsRenderChapters(plan).single;
  final List<int> gaps = ttsChapterGapsMs(
    sentences: plan,
    chapter: chapter,
    preset: TtsPausePreset.standard,
  );
  expect(gaps, <int>[800, 600, 1500, 2000]);
  final Directory work = Directory(p.join(tmp.path, 'work'));
  final List<String> failures = <String>[];
  final ({
    List<({String path, int durationMs})> entries,
    TtsAudioStreamInfo target,
  })
  prepared = await prepareTtsUniformEntries(
    backend: backend,
    sentences: sentences,
    mixDir: Directory(p.join(work.path, 'mix')),
    cancel: TtsRenderCancelToken(),
    onFailure: failures.add,
    requirePcm16: true,
  );
  // 全章 24 kHz PCM WAV：不必转码，静音按同参数生成。
  expect(prepared.target.sampleRate, 24000);
  expect(
    prepared.entries.map((({String path, int durationMs}) e) => e.path),
    sentences.map((({String key, String path, int durationMs}) s) => s.path),
  );
  final String out = p.join(work.path, 'tts_000.m4a');
  await encodeTtsChapterAudio(
    backend: backend,
    entries: interleaveTtsPauses(
      sentences: prepared.entries,
      gapsMs: gaps,
      silenceFor: (int ms) => ttsSilenceFile(
        Directory(p.join(work.path, 'silence')),
        ms: ms,
        sampleRate: prepared.target.sampleRate,
        channels: prepared.target.channels,
      ),
    ),
    outputPath: out,
    cancel: TtsRenderCancelToken(),
    onFailure: failures.add,
    loudnorm: loudnorm,
  );
  expect(failures, isEmpty);

  final List<AudioCue> cues = buildTtsChapterCues(
    bookKey: 'b',
    sentences: plan,
    chapter: chapter,
    durationsMs: <int>[600, 400, 300],
    gapsMs: gaps,
  );
  final String decoded = p.join(tmp.path, 'decoded.mov');
  final FfmpegRunResult result = await backend.run(<String>[
    '-y',
    '-i',
    out,
    '-ac',
    '1',
    '-ar',
    '48000',
    '-c:a',
    'pcm_s16le',
    '-f',
    'mov',
    decoded,
  ], const Duration(seconds: 60));
  expect(result.isSuccess, isTrue, reason: result.failureSummary);
  final List<int> onsets = _toneOnsetsMs(
    _movPcmSamples(await File(decoded).readAsBytes()),
    48000,
  );
  final List<int> expected = <int>[for (final AudioCue c in cues) c.startMs];
  expect(expected, <int>[800, 2000, 3900]);
  expect(onsets, hasLength(3), reason: 'onsets=$onsets');
  for (int i = 0; i < 3; i++) {
    expect(
      (onsets[i] - expected[i]).abs(),
      lessThanOrEqualTo(25),
      reason: 'onsets=$onsets expected=$expected',
    );
  }
  final int? total = await readMp4PresentationDurationMs(out);
  expect(total, isNotNull);
  expect(
    (total! - ttsChapterFileDurationMs(<int>[600, 400, 300], gaps)).abs(),
    lessThan(60),
    reason: 'total=$total',
  );
}

void main() {
  group('段落 / 场景边界', () {
    test('块末尾 = 段落结束；◇ 分隔块 / 空段落 / <hr> = 场景分隔；插图段不算', () {
      final EpubBook book = _book(
        '<p>一。二。</p><p>三。</p><p>◇　◇　◇</p><p>四。</p>'
        '<p><br/></p><p>五。</p><hr/><p>六。</p>'
        '<p><img src="x.png"/></p><div><p>七。</p></div>',
      );
      final TtsBookPlan plan = buildTtsBookPlanSync(book, maxLength: 120);
      expect(plan.sentences.map((TtsPlanSentence s) => s.text), <String>[
        '一。',
        '二。',
        '三。',
        '四。',
        '五。',
        '六。',
        '七。',
      ]);
      expect(plan.sentences.map((TtsPlanSentence s) => s.endsParagraph), <bool>[
        false,
        true,
        true,
        true,
        true,
        true,
        true,
      ]);
      expect(
        plan.sentences.map((TtsPlanSentence s) => s.sceneBreakAfter),
        <bool>[false, false, true, true, true, false, false],
      );
    });

    test('块边界不改纯文本（与 chapterPlainText 逐码元相同）', () {
      const String body =
          '<p>一。</p>\n<p>◇</p>\n<hr/>\n<p>  <ruby>漢<rt>かん</rt></ruby>。</p>';
      final EpubBook book = _book(body);
      final EpubPlainTextWithRuby rich = book.chapterPlainTextWithRuby(0);
      expect(rich.text, book.chapterPlainText(0));
      expect(rich.blockEnds, isNotEmpty);
      for (final int e in <int>[...rich.blockEnds, ...rich.sceneBreaks]) {
        expect(e, inInclusiveRange(0, rich.text.length));
      }
    });

    test('边界紧贴下一句（块之间没有空白）也归前一句', () {
      expect(
        ttsSentenceBoundaryMarks(
          sentences: const <({int start, int end})>[
            (start: 0, end: 2),
            (start: 2, end: 4),
            (start: 5, end: 7),
          ],
          blockEnds: const <int>[2, 7],
          sceneBreaks: const <int>[5],
        ),
        <({bool endsParagraph, bool sceneBreakAfter})>[
          (endsParagraph: true, sceneBreakAfter: false),
          (endsParagraph: false, sceneBreakAfter: true),
          (endsParagraph: true, sceneBreakAfter: false),
        ],
      );
    });
  });

  group('停顿', () {
    final List<TtsPlanSentence> plan = <TtsPlanSentence>[
      _s('a'),
      _s('b', paragraph: true),
      _s('c', paragraph: true, scene: true),
      _s('d', paragraph: true),
    ];
    final TtsRenderChapter chapter = groupTtsRenderChapters(plan).single;

    test('章首 / 句间（按段落 / 场景）/ 章尾', () {
      expect(
        ttsChapterGapsMs(
          sentences: plan,
          chapter: chapter,
          preset: TtsPausePreset.standard,
        ),
        <int>[800, 150, 600, 1500, 2000],
      );
      expect(
        ttsChapterGapsMs(
          sentences: plan,
          chapter: chapter,
          preset: TtsPausePreset.none,
        ),
        everyElement(0),
      );
    });

    test('cue 只覆盖句音频，停顿在句与句之间；文件总长含首尾静音', () {
      const List<int> durations = <int>[1000, 500, 700, 300];
      const List<int> gaps = <int>[800, 150, 600, 1500, 2000];
      final List<AudioCue> cues = buildTtsChapterCues(
        bookKey: 'b',
        sentences: plan,
        chapter: chapter,
        durationsMs: durations,
        gapsMs: gaps,
      );
      expect(cues.map((AudioCue c) => (c.startMs, c.endMs)), <(int, int)>[
        (800, 1800),
        (1950, 2450),
        (3050, 3750),
        (5250, 5550),
      ]);
      expect(ttsChapterFileDurationMs(durations, gaps), 7550);
      // 单时间轴按真实文件时长（含章尾 2 s）拼，而不是 cue 的最大 end。
      final List<AudioCue> second = buildTtsChapterCues(
        bookKey: 'b',
        sentences: plan,
        chapter: TtsRenderChapter(
          fileIndex: 1,
          section: 0,
          planIndices: chapter.planIndices,
        ),
        durationsMs: durations,
        gapsMs: gaps,
      );
      final List<AudioCue> single = ttsCuesOnSingleTimeline(
        <AudioCue>[...cues, ...second],
        fileDurationsMs: const <int>[7550, 7550],
      );
      expect(single[4].startMs, 7550 + 800);
    });

    test('静音插在句前后；0 毫秒的位置不插', () {
      final List<({String path, int durationMs})> out = interleaveTtsPauses(
        sentences: const <({String path, int durationMs})>[
          (path: 'a', durationMs: 10),
          (path: 'b', durationMs: 20),
        ],
        gapsMs: const <int>[5, 0, 7],
        silenceFor: (int ms) => 'sil$ms',
      );
      expect(out, const <({String path, int durationMs})>[
        (path: 'sil5', durationMs: 5),
        (path: 'a', durationMs: 10),
        (path: 'b', durationMs: 20),
        (path: 'sil7', durationMs: 7),
      ]);
    });

    test('静音 WAV：样本数与流参数', () {
      final Uint8List wav = buildTtsSilenceWav(
        ms: 150,
        sampleRate: 22050,
        channels: 2,
      );
      expect(wav.length, 44 + 3308 * 2 * 2);
      expect(
        parseTtsAudioStreamInfo(wav),
        const TtsAudioStreamInfo(
          codec: 'pcm_s16le',
          sampleRate: 22050,
          channels: 2,
        ),
      );
      expect(wav.sublist(44).every((int b) => b == 0), isTrue);
    });
  });

  group('响度', () {
    test('滤镜链：时间轴对齐在前、loudnorm 可选、最后统一 44.1 kHz', () {
      expect(
        buildTtsChapterFilter(loudnorm: false),
        'aresample=async=1:min_hard_comp=0.010:first_pts=0,aresample=44100',
      );
      expect(
        buildTtsChapterFilter(loudnorm: true),
        'aresample=async=1:min_hard_comp=0.010:first_pts=0,'
        'loudnorm=I=-19:TP=-3:LRA=11,aresample=44100',
      );
    });

    test('-filters 列表解析', () {
      const String filters =
          'Filters:\n'
          '  T.. = Timeline support\n'
          ' ... aresample         A->A       Resample audio data.\n'
          ' ... loudnorm          A->A       EBU R128 loudness normalization\n';
      expect(ffmpegFiltersListHas(filters, 'loudnorm'), isTrue);
      expect(ffmpegFiltersListHas(filters, 'aresample'), isTrue);
      expect(ffmpegFiltersListHas(filters, 'loud'), isFalse);
      expect(
        ffmpegFiltersListHas(' ... aresample   A->A  x\n', 'loudnorm'),
        isFalse,
      );
    });
  });

  group('M4B 导出', () {
    const String demuxers =
        'File formats:\n'
        ' D. = Demuxing supported\n'
        ' .E = Muxing supported\n'
        ' --\n'
        ' D   concat           Virtual concatenation script\n'
        ' D   image2           image2 sequence\n'
        ' D   mov,mp4,m4a,3gp,3g2,mj2 QuickTime / MOV\n';
    const String muxers =
        ' --\n'
        '  E  mov              QuickTime / MOV\n'
        '  E  mp4              MP4 (MPEG-4 Part 14)\n';

    test('能力解析：精简版缺 ffmetadata 与 ipod', () {
      final AudiobookExportCapabilities caps =
          AudiobookExportCapabilities.parse(demuxers: demuxers, muxers: muxers);
      expect(caps.concat, isTrue);
      expect(caps.image2, isTrue);
      expect(caps.mp4, isTrue);
      expect(caps.ipod, isFalse);
      expect(caps.ffmetadata, isFalse);
      expect(caps.missing, <String>['ffmetadata demuxer']);
      expect(ffmpegFormatsListHas(demuxers, 'm4a', demux: true), isTrue);
      expect(ffmpegFormatsListHas(demuxers, 'mp4', demux: false), isFalse);
      final AudiobookExportCapabilities full =
          AudiobookExportCapabilities.parse(
            demuxers: '$demuxers D  ffmetadata      FFmpeg metadata in text\n',
            muxers: '$muxers  E  ipod             iPod H.264 MP4\n',
          );
      expect(full.missing, isEmpty);
      expect(full.ipod, isTrue);
    });

    test('ffmpeg -i 输出：时长与音频流参数', () {
      const String out =
          "Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'a.m4a':\n"
          '  Duration: 00:01:02.35, start: 0.000000, bitrate: 98 kb/s\n'
          '  Stream #0:0[0x1](und): Audio: aac (LC) (mp4a / 0x6134706D), '
          '44100 Hz, mono, fltp, 96 kb/s (default)\n';
      final ({
        int? durationMs,
        String? codec,
        int? sampleRate,
        String? channels,
      })
      info = parseFfmpegInputInfo(out);
      expect(info.durationMs, 62350);
      expect(info.codec, 'aac');
      expect(info.sampleRate, 44100);
      expect(info.channels, 'mono');
      expect(parseFfmpegInputInfo('nothing').durationMs, isNull);
    });

    test('章节：换到有目录标题的章才开新章，无标题的 spine 文件并入前一章', () {
      final List<AudiobookExportChapter> chapters =
          buildAudiobookExportChapters(
            timelineCues: <AudioCue>[
              _cue(0, 0, 900, 'front.xhtml'),
              _cue(0, 1000, 2000, 'c1.xhtml'),
              _cue(0, 2000, 3000, 'c1b.xhtml'),
              _cue(0, 3500, 4000, 'c2.xhtml'),
            ],
            totalMs: 6000,
            titleFor: (String href) => switch (href) {
              'c1.xhtml' => '第一章',
              'c2.xhtml' => '第二章',
              _ => null,
            },
            fallbackTitle: '书名',
          );
      expect(
        chapters.map(
          (AudiobookExportChapter c) => (c.startMs, c.endMs, c.title),
        ),
        <(int, int, String)>[
          (0, 1000, '书名'),
          (1000, 3500, '第一章'),
          (3500, 6000, '第二章'),
        ],
      );
    });

    test('FFMETADATA：全局元数据 + 毫秒时基章节 + 转义', () {
      final String meta = buildFfmetadata(
        title: 'A=B;C',
        artist: '作者',
        chapters: const <AudiobookExportChapter>[
          AudiobookExportChapter(startMs: 0, endMs: 1500, title: '一#\\'),
          AudiobookExportChapter(startMs: 1500, endMs: 4000, title: '二'),
        ],
      );
      expect(meta, startsWith(';FFMETADATA1\ntitle=A\\=B\\;C\n'));
      expect(meta, contains('artist=作者\n'));
      expect(
        meta,
        contains(
          '[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=1500\ntitle=一\\#\\\\\n',
        ),
      );
      expect('[CHAPTER]'.allMatches(meta), hasLength(2));
    });

    test('导出参数：带封面时映射图片并标 attached_pic', () {
      final List<String> args = buildAudiobookExportArgs(
        listPath: 'l',
        metadataPath: 'm',
        coverPath: 'c.jpg',
        muxer: 'ipod',
        outputPath: 'o.m4b',
      );
      expect(
        args,
        containsAllInOrder(<String>[
          '-i', 'l', '-f', 'ffmetadata', '-i', 'm', '-i', 'c.jpg', //
          '-map', '0:a', '-map', '2:v', '-map_metadata', '1',
          '-map_chapters', '1', '-c', 'copy',
          '-disposition:v:0', 'attached_pic', '-f', 'ipod', 'o.m4b',
        ]),
      );
      expect(
        buildAudiobookExportArgs(
          listPath: 'l',
          metadataPath: 'm',
          coverPath: null,
          muxer: 'mp4',
          outputPath: 'o.m4b',
        ),
        isNot(contains('attached_pic')),
      );
    });
  });

  // 真 ffmpeg 冒烟。FUSHI_FFMPEG：捆绑的 ffmpeg-min；FUSHI_FFMPEG_FULL：完整版
  // ffmpeg（有 loudnorm / ffmetadata / ipod）。都不设就跳过。
  final String? minFfmpeg = Platform.environment['FUSHI_FFMPEG'];
  final String? fullFfmpeg = Platform.environment['FUSHI_FFMPEG_FULL'];

  test(
    'ffmpeg 冒烟（FUSHI_FFMPEG）：停顿后的句首时刻与 cue 一致',
    () => _pauseSmoke(const CliFfmpegBackend(), loudnorm: false),
    skip: minFfmpeg == null || minFfmpeg.isEmpty
        ? 'FUSHI_FFMPEG not set'
        : false,
  );

  test(
    'ffmpeg 冒烟（FUSHI_FFMPEG_FULL）：loudnorm 不改时间轴',
    () async {
      final _ExeBackend backend = _ExeBackend(fullFfmpeg!);
      final FfmpegRunResult filters = await backend.runQuery(const <String>[
        '-hide_banner',
        '-filters',
      ], const Duration(seconds: 20));
      expect(ffmpegFiltersListHas(filters.output, 'loudnorm'), isTrue);
      await _pauseSmoke(backend, loudnorm: true);
    },
    skip: fullFfmpeg == null || fullFfmpeg.isEmpty
        ? 'FUSHI_FFMPEG_FULL not set'
        : false,
  );

  test(
    'ffmpeg 冒烟（FUSHI_FFMPEG_FULL）：两章 m4a → M4B，章节与封面写进去',
    () async {
      final _ExeBackend backend = _ExeBackend(fullFfmpeg!);
      final AudiobookExportCapabilities caps =
          AudiobookExportCapabilities.parse(
            demuxers: (await backend.runQuery(const <String>[
              '-hide_banner',
              '-demuxers',
            ], const Duration(seconds: 20))).output,
            muxers: (await backend.runQuery(const <String>[
              '-hide_banner',
              '-muxers',
            ], const Duration(seconds: 20))).output,
          );
      expect(caps.missing, isEmpty);
      final Directory tmp = await Directory.systemTemp.createTemp('tts_m4b');
      addTearDown(() => tmp.delete(recursive: true));
      final List<String> chapters = <String>[];
      final List<int> durations = <int>[];
      for (final int ms in <int>[1500, 700]) {
        final File wav = File(p.join(tmp.path, 'src$ms.wav'));
        await wav.writeAsBytes(_toneWav(ms));
        final String out = p.join(tmp.path, 'tts_$ms.m4a');
        await encodeTtsChapterAudio(
          backend: backend,
          entries: <({String path, int durationMs})>[
            (path: wav.path, durationMs: ms),
          ],
          outputPath: out,
          cancel: TtsRenderCancelToken(),
          onFailure: (String s) => fail(s),
        );
        chapters.add(out);
        durations.add((await readMp4PresentationDurationMs(out))!);
      }
      expect(durations, <int>[1500, 700]);
      final File cover = File(p.join(tmp.path, 'cover.png'));
      final FfmpegRunResult png = await backend.run(<String>[
        '-y',
        '-f',
        'lavfi',
        '-i',
        'color=c=red:s=32x32',
        '-frames:v',
        '1',
        cover.path,
      ], const Duration(seconds: 30));
      expect(png.isSuccess, isTrue, reason: png.failureSummary);
      final File list = File(p.join(tmp.path, 'l.ffconcat'))
        ..writeAsStringSync(
          buildTtsConcatList(<({String path, int durationMs})>[
            for (int i = 0; i < 2; i++)
              (path: chapters[i], durationMs: durations[i]),
          ]),
        );
      final File meta = File(p.join(tmp.path, 'm.txt'))
        ..writeAsStringSync(
          buildFfmetadata(
            title: '本',
            artist: '著者',
            chapters: const <AudiobookExportChapter>[
              AudiobookExportChapter(startMs: 0, endMs: 1500, title: '第一章'),
              AudiobookExportChapter(startMs: 1500, endMs: 2200, title: '第二章'),
            ],
          ),
        );
      final String m4b = p.join(tmp.path, 'book.m4b');
      final FfmpegRunResult result = await backend.run(
        buildAudiobookExportArgs(
          listPath: list.path,
          metadataPath: meta.path,
          coverPath: cover.path,
          muxer: 'ipod',
          outputPath: m4b,
        ),
        const Duration(seconds: 60),
      );
      expect(result.isSuccess, isTrue, reason: result.failureSummary);
      final String info = (await backend.runQuery(<String>[
        '-hide_banner',
        '-i',
        m4b,
      ], const Duration(seconds: 20))).output;
      expect(info, contains('Chapter #0:0: start 0.000000, end 1.500000'));
      expect(info, contains('Chapter #0:1: start 1.500000, end 2.200000'));
      expect(info, contains('第二章'));
      expect(info, contains('(attached pic)'));
      expect(info, contains('著者'));
      expect(
        ((await readMp4PresentationDurationMs(m4b))! - 2200).abs(),
        lessThan(60),
      );
    },
    skip: fullFfmpeg == null || fullFfmpeg.isEmpty
        ? 'FUSHI_FFMPEG_FULL not set'
        : false,
  );

  group('移动端分享导出的暂存目录', () {
    test('每次导出前清掉上一次留下的整本 M4B / SRT，返回空目录', () async {
      final Directory tmp = await Directory.systemTemp.createTemp(
        'm4b_staging_test_',
      );
      addTearDown(() => tmp.delete(recursive: true));
      final Directory root = Directory(
        p.join(tmp.path, kTtsAudiobookShareStagingDirName),
      );

      final Directory first = await prepareTtsAudiobookShareStagingDir(root);
      expect(first.existsSync(), isTrue);
      expect(first.listSync(), isEmpty);
      await File(p.join(first.path, 'old.m4b')).writeAsBytes(<int>[1, 2, 3]);
      await File(p.join(first.path, 'old.srt')).writeAsString('1');

      final Directory second = await prepareTtsAudiobookShareStagingDir(root);
      expect(second.path, root.path);
      expect(second.listSync(), isEmpty, reason: '上一次的导出文件必须被清掉');
    });

    test('制作台移动端导出走自管暂存目录，不再每次 createTemp 一个新目录', () {
      final String src = File(
        'lib/src/media/audiobook/tts/studio/tts_studio_page.dart',
      ).readAsStringSync();
      expect(src, contains('prepareTtsAudiobookShareStagingDir('));
      expect(src, contains('kTtsAudiobookShareStagingDirName'));
      expect(
        RegExp(r"createTemp\(\s*'fushi_m4b").hasMatch(src),
        isFalse,
        reason: '每次导出新建的临时目录没人删，整本 M4B 会在临时目录里越积越多',
      );
    });
  });
}
