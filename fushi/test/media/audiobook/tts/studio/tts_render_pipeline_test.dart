import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_render_encode.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_render_verify.dart';
import 'package:fushi/src/media/audiobook/tts/tts_book_plan.dart';
import 'package:fushi_asr_core/asr_core.dart' show AsrCueTokenTiming;
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/tts/render/tts_render_queue.dart';
import 'package:path/path.dart' as p;

TtsPlanSentence _s(int section, String text, int start, {String? spoken}) =>
    TtsPlanSentence(
      section: section,
      href: 'ch$section.xhtml',
      text: text,
      spokenText: spoken ?? text,
      matchStart: start,
      matchEnd: start + text.length,
      studyStart: 0,
      studyEnd: 0,
    );

AudioCue _cue(int start, int end, String text, {int file = 0}) => AudioCue()
  ..bookKey = 'b'
  ..chapterHref = 'x'
  ..sentenceIndex = 0
  ..textFragmentId = ''
  ..text = text
  ..startMs = start
  ..endMs = end
  ..audioFileIndex = file;

// 构造函数带 length 断言，不能写成 const 字面量。
AsrCueTokenTiming _timing(List<String> tokens, List<int> offsetsMs) =>
    AsrCueTokenTiming(tokens: tokens, offsetsMs: offsetsMs);

/// 16 kHz 单声道 16-bit PCM WAV（[ms] 毫秒的方波，非静音）。
Uint8List _wav(int ms) {
  const int rate = 16000;
  final int samples = rate * ms ~/ 1000;
  final ByteData b = ByteData(44 + samples * 2);
  void ascii(int at, String s) {
    for (int i = 0; i < s.length; i++) {
      b.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  b.setUint32(4, 36 + samples * 2, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little);
  b.setUint16(22, 1, Endian.little);
  b.setUint32(24, rate, Endian.little);
  b.setUint32(28, rate * 2, Endian.little);
  b.setUint16(32, 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  b.setUint32(40, samples * 2, Endian.little);
  for (int i = 0; i < samples; i++) {
    b.setInt16(44 + i * 2, (i ~/ 20).isEven ? 3000 : -3000, Endian.little);
  }
  return b.buffer.asUint8List();
}

/// 读 mp4 `mvhd` 的时长（毫秒）。
int? _mp4DurationMs(Uint8List bytes) {
  for (int i = 4; i + 24 < bytes.length; i++) {
    if (bytes[i] == 0x6d &&
        bytes[i + 1] == 0x76 &&
        bytes[i + 2] == 0x68 &&
        bytes[i + 3] == 0x64) {
      final ByteData d = ByteData.sublistView(bytes, i + 4);
      final int version = d.getUint8(0);
      if (version == 1) {
        final int scale = d.getUint32(20);
        return d.getUint64(24) * 1000 ~/ scale;
      }
      final int scale = d.getUint32(12);
      return d.getUint32(16) * 1000 ~/ scale;
    }
  }
  return null;
}

void main() {
  group('groupTtsRenderChapters', () {
    final List<TtsPlanSentence> plan = <TtsPlanSentence>[
      _s(1, 'あ', 0),
      _s(1, 'い', 1),
      _s(3, 'う', 0),
      _s(4, 'え', 0),
      _s(4, 'お', 1),
    ];

    test('全书：按章分组、保持计划顺序、文件下标连续', () {
      final List<TtsRenderChapter> chapters = groupTtsRenderChapters(plan);
      expect(chapters.map((TtsRenderChapter c) => c.section), <int>[1, 3, 4]);
      expect(chapters.map((TtsRenderChapter c) => c.fileIndex), <int>[0, 1, 2]);
      expect(chapters[0].planIndices, <int>[0, 1]);
      expect(chapters[2].planIndices, <int>[3, 4]);
      expect(chapters[2].stem, 'tts_002');
    });

    test('选章：只留选中的章，文件下标按成品重新编号、句下标仍是全书下标', () {
      final List<TtsRenderChapter> chapters = groupTtsRenderChapters(
        plan,
        sections: <int>{4},
      );
      expect(chapters, hasLength(1));
      expect(chapters.single.fileIndex, 0);
      expect(chapters.single.planIndices, <int>[3, 4]);
    });

    test('选中的章没有句子 → 空', () {
      expect(groupTtsRenderChapters(plan, sections: <int>{2}), isEmpty);
    });
  });

  group('cue 时间轴', () {
    final List<TtsPlanSentence> plan = <TtsPlanSentence>[
      _s(0, 'one', 0),
      _s(0, 'two', 3),
      _s(2, 'three', 0),
    ];
    final List<TtsRenderChapter> chapters = groupTtsRenderChapters(plan);

    test('章内累加时长、片段 id 编码计划坐标', () {
      final List<AudioCue> cues = buildTtsChapterCues(
        bookKey: 'book',
        sentences: plan,
        chapter: chapters[0],
        durationsMs: <int>[1200, 800],
      );
      expect(cues.map((AudioCue c) => (c.startMs, c.endMs)), <(int, int)>[
        (0, 1200),
        (1200, 2000),
      ]);
      expect(cues[1].sentenceIndex, 1);
      expect(cues[1].chapterHref, 'ch0.xhtml');
      expect(cues[1].audioFileIndex, 0);
      expect(
        cues[1].textFragmentId,
        SubtitleRematchCodec.encodeHit(
          sectionIndex: 0,
          normCharStart: 3,
          normCharEnd: 6,
        ),
      );
    });

    test('时长个数与句数不符直接报错', () {
      expect(
        () => buildTtsChapterCues(
          bookKey: 'book',
          sentences: plan,
          chapter: chapters[0],
          durationsMs: <int>[1],
        ),
        throwsArgumentError,
      );
    });

    test('单时间轴：第二个文件整体后移第一个文件的时长', () {
      final List<AudioCue> perFile = <AudioCue>[
        ...buildTtsChapterCues(
          bookKey: 'book',
          sentences: plan,
          chapter: chapters[0],
          durationsMs: <int>[1200, 800],
        ),
        ...buildTtsChapterCues(
          bookKey: 'book',
          sentences: plan,
          chapter: chapters[1],
          durationsMs: <int>[500],
        ),
      ];
      final List<AudioCue> single = ttsCuesOnSingleTimeline(perFile);
      expect(single.last.startMs, 2000);
      expect(single.last.endMs, 2500);
      expect(single.every((AudioCue c) => c.audioFileIndex == 0), isTrue);
      // 原 cue 不被改动（逐文件版本照样落库）。
      expect(perFile.last.startMs, 0);
      expect(perFile.last.audioFileIndex, 1);
    });
  });

  group('concat 清单与编码参数', () {
    test('Windows 路径转正斜杠、单引号转义、每个文件带 duration、不重复末尾', () {
      final String list = buildTtsConcatList(<({String path, int durationMs})>[
        (path: r'C:\cache\a.audio', durationMs: 1234),
        (path: "/tmp/it's.audio", durationMs: 50),
      ]);
      expect(
        list,
        'ffconcat version 1.0\n'
        "file 'C:/cache/a.audio'\n"
        'duration 1.234\n'
        "file '/tmp/it'\\''s.audio'\n"
        'duration 0.050\n',
      );
    });

    test('m4a 显式 -f mp4（ffmpeg-min 没有 ipod 封装器）', () {
      final List<String> args = buildTtsChapterEncodeArgs(
        listPath: 'l.ffconcat',
        outputPath: 'o.m4a',
      );
      expect(args.sublist(0, 7), <String>[
        '-y',
        '-f',
        'concat',
        '-safe',
        '0',
        '-i',
        'l.ffconcat',
      ]);
      expect(args.sublist(args.length - 3), <String>['-f', 'mp4', 'o.m4a']);
      expect(args, containsAllInOrder(<String>['-c:a', 'aac']));
    });
  });

  group('TtsChapterManifest', () {
    test('往返 + 键序 / 停顿预设 / 响度开关比较', () {
      const TtsChapterManifest m = TtsChapterManifest(
        section: 3,
        keys: <String>['a', 'b', 'a'],
        durationsMs: <int>[10, 20, 10],
        pausePreset: 'standard',
        loudnorm: true,
      );
      final TtsChapterManifest? back = TtsChapterManifest.decode(m.encode());
      expect(back, isNotNull);
      expect(back!.durationsMs, <int>[10, 20, 10]);
      bool matches(
        int section,
        List<String> keys, {
        String pause = 'standard',
        bool loudnorm = true,
      }) => back.matches(section, keys, pausePreset: pause, loudnorm: loudnorm);
      expect(matches(3, <String>['a', 'b', 'a']), isTrue);
      expect(matches(3, <String>['b', 'a', 'a']), isFalse);
      expect(matches(4, <String>['a', 'b', 'a']), isFalse);
      // 换停顿预设 / 响度开关都要重编码。
      expect(matches(3, <String>['a', 'b', 'a'], pause: 'literary'), isFalse);
      expect(matches(3, <String>['a', 'b', 'a'], loudnorm: false), isFalse);
    });

    test('损坏 / 长度不一致 / 旧版本 → null', () {
      expect(TtsChapterManifest.decode('not json'), isNull);
      const String tail = '"pause":"standard","loudnorm":false';
      expect(
        TtsChapterManifest.decode(
          '{"v":2,"section":0,"keys":["a"],"durationsMs":[1,2],$tail}',
        ),
        isNull,
      );
      expect(
        TtsChapterManifest.decode(
          '{"v":2,"section":0,"keys":["a"],"durationsMs":[0],$tail}',
        ),
        isNull,
      );
      // v1（没有停顿 / 响度字段）当作没编码过。
      expect(
        TtsChapterManifest.decode(
          '{"v":1,"section":0,"keys":["a"],"durationsMs":[1]}',
        ),
        isNull,
      );
      expect(
        TtsChapterManifest.decode(
          '{"v":2,"section":0,"keys":["a"],"durationsMs":[1],$tail}',
        ),
        isNotNull,
      );
    });
  });

  group('校对', () {
    test('相似度：归一化后比较（标点 / 片假名不计差异）', () {
      expect(ttsTextSimilarity('こんにちは。', 'コンニチハ'), 1);
      expect(ttsTextSimilarity('', ''), 1);
      expect(ttsTextSimilarity('abcd', 'abxd'), closeTo(0.75, 1e-9));
      expect(ttsTextSimilarity('', 'abc'), 0);
    });

    test('句相似度取原文与读音的较高者', () {
      expect(
        ttsSentenceSimilarity(
          heard: 'きょうはいいてんき',
          text: '今日はいい天気',
          spokenText: 'きょうはいいてんき',
        ),
        1,
      );
    });

    test('token 按 cue 起点 + 偏移落到句窗；无 token 时按 cue 中点', () {
      final List<AudioCue> asr = <AudioCue>[
        _cue(1000, 3000, 'あいう'),
        _cue(3000, 4000, 'えお'),
      ];
      final List<TtsHeardToken> tokens = ttsHeardTokensFromAsr(
        asr,
        <AsrCueTokenTiming>[
          _timing(<String>['あ', 'い', 'う'], <int>[0, 500, 1500]),
          _timing(<String>['え', 'お'], <int>[100, 200]),
        ],
      );
      expect(tokens.map((TtsHeardToken t) => t.atMs), <int>[
        1000,
        1500,
        2500,
        3100,
        3200,
      ]);
      expect(
        ttsHeardTextPerWindow(tokens, const <({int startMs, int endMs})>[
          (startMs: 0, endMs: 2000),
          (startMs: 2000, endMs: 5000),
        ]),
        <String>['あい', 'うえお'],
      );
      final List<TtsHeardToken> coarse = ttsHeardTokensFromAsr(asr, null);
      expect(coarse.map((TtsHeardToken t) => t.atMs), <int>[2000, 3500]);
    });

    test('低于阈值的句被标出，带计划下标与听到的文本', () {
      final List<TtsRenderFlag> flags = flagTtsChapterSentences(
        sentences: const <TtsVerifySentence>[
          TtsVerifySentence(
            planIndex: 7,
            text: 'あいう',
            spokenText: 'あいう',
            startMs: 0,
            endMs: 1000,
          ),
          TtsVerifySentence(
            planIndex: 8,
            text: 'かきくけこ',
            spokenText: 'かきくけこ',
            startMs: 1000,
            endMs: 2000,
          ),
          TtsVerifySentence(
            planIndex: 9,
            text: 'さしす',
            spokenText: 'さしす',
            startMs: 2000,
            endMs: 3000,
          ),
        ],
        heard: const <TtsHeardToken>[
          TtsHeardToken(atMs: 100, text: 'あいう'),
          TtsHeardToken(atMs: 1200, text: 'たちつ'),
        ],
      );
      expect(flags.map((TtsRenderFlag f) => f.sentence), <int>[8, 9]);
      expect(flags.first.heard, 'たちつ');
      expect(flags.last.heard, '');
      expect(flags.last.similarity, 0);
    });
  });

  // 真 ffmpeg 冒烟：只在显式给了 FUSHI_FFMPEG（如 third_party/ffmpeg-min）时跑，
  // 不依赖 CI 机器碰巧装没装 ffmpeg。
  final String? ffmpeg = Platform.environment['FUSHI_FFMPEG'];
  test('ffmpeg 冒烟：两段 WAV（无扩展名后缀 .audio）→ m4a，时长 ≈ 时长之和', () async {
    final Directory tmp = await Directory.systemTemp.createTemp(
      'tts_render_smoke',
    );
    addTearDown(() => tmp.delete(recursive: true));
    final List<({String path, int durationMs})> entries =
        <({String path, int durationMs})>[];
    for (final int ms in <int>[1500, 700, 2300]) {
      final File f = File(p.join(tmp.path, 'k$ms.audio'));
      await f.writeAsBytes(_wav(ms));
      entries.add((path: f.path, durationMs: ms));
    }
    final String out = p.join(tmp.path, 'work dir', 'tts_000.m4a');
    final List<String> failures = <String>[];
    await encodeTtsChapterAudio(
      backend: const CliFfmpegBackend(),
      entries: entries,
      outputPath: out,
      cancel: TtsRenderCancelToken(),
      onFailure: failures.add,
    );
    expect(failures, isEmpty);
    final Uint8List bytes = await File(out).readAsBytes();
    expect(bytes.length, greaterThan(0));
    final int? duration = _mp4DurationMs(bytes);
    expect(duration, isNotNull);
    expect((duration! - 4500).abs(), lessThan(120));
    // 临时清单与半成品都已清理。
    expect(
      Directory(
        p.dirname(out),
      ).listSync().map((FileSystemEntity e) => p.basename(e.path)),
      <String>['tts_000.m4a'],
    );
  }, skip: ffmpeg == null || ffmpeg.isEmpty ? 'FUSHI_FFMPEG not set' : false);
}
