import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/asr_transcribe_sheet.dart';
import 'package:fushi_asr_core/asr_core.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_engine/media/audiobook/audiobook_alignment_service.dart';
import 'package:path/path.dart' as p;

/// 正文三句；听写一条 cue 横跨第二、三句且没有句号。
const String _book = 'たとえば、夢見る時がある。転入生がやってくる。その子は素敵な子。';
const String _heard = '夢見る時がある転入生がやってくる';
const List<EpubSection> _sections = <EpubSection>[
  EpubSection(index: 0, href: 'ch0.xhtml', text: _book),
];

AudioCue _cue({bool withTiming = false}) {
  final AudioCue cue = AudioCue()
    ..bookKey = 'b'
    ..chapterHref = ''
    ..sentenceIndex = 0
    ..textFragmentId = ''
    ..text = _heard
    ..startMs = 10000
    ..endMs = 13500
    ..audioFileIndex = 0;
  if (withTiming) {
    cue.tokenTiming = CueTokenTiming(
      tokens: _heard.split(''),
      offsetsMs: <int>[
        for (int i = 0; i < 7; i++) 100 + i * 100,
        for (int i = 0; i < 9; i++) 2000 + i * 100,
      ],
    );
  }
  return cue;
}

void main() {
  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('asr_aligned_export_');
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// 造一个转录任务目录：`transcript.srt` + `state.json`（后者是「ASR 产物」判据）。
  String asrJob({bool state = true}) {
    final Directory dir = Directory(p.join(tmp.path, 'job'))..createSync();
    final File srt = File(p.join(dir.path, AsrJobFiles.srt))
      ..writeAsStringSync('1\n00:00:10,000 --> 00:00:13,500\n$_heard\n\n');
    if (state) {
      File(p.join(dir.path, AsrJobFiles.state)).writeAsStringSync('{}');
    }
    return srt.path;
  }

  Future<({List<AudioCue> cues, MatchResult result})> finalize(
    String subtitlePath, {
    required bool withTiming,
  }) async {
    final List<AudioCue> cues = <AudioCue>[_cue(withTiming: withTiming)];
    final MatchResult result = EpubCueMatcher.match(
      sections: _sections,
      cues: cues,
    );
    expect(result.matchedCues, 1, reason: '语料应当命中，否则后面全是空壳断言');
    return finalizeAlignedCues(
      sections: _sections,
      cues: cues,
      result: result,
      subtitlePath: subtitlePath,
      hasTokenTiming: withTiming,
    );
  }

  group('finalizeAlignedCues', () {
    test('ASR 产物 + 逐词时间：按句界重切、换成带标点正文、旁边写出对齐版 SRT', () async {
      final String srt = asrJob();
      final ({List<AudioCue> cues, MatchResult result}) out = await finalize(
        srt,
        withTiming: true,
      );
      expect(out.cues.map((AudioCue c) => c.text), <String>[
        '夢見る時がある。',
        '転入生がやってくる。',
      ]);
      expect(out.cues.first.startMs, 10000);
      expect(out.cues.last.endMs, 13500);
      expect(out.result.totalCues, 2);

      final File aligned = File(asrAlignedTranscriptPathFor(srt));
      expect(aligned.existsSync(), isTrue);
      // 对齐版能被本仓 SRT 解析器读回，且内容就是替换后的 cue。
      final List<AudioCue> reread = await SrtParser.parse(
        srtFile: aligned,
        bookKey: 'b',
        audioFileIndex: 0,
      );
      expect(reread.map((AudioCue c) => c.text), <String>[
        '夢見る時がある。',
        '転入生がやってくる。',
      ]);
      expect(reread.first.startMs, 10000);
      expect(reread.last.endMs, 13500);
      // 原始听写稿一个字节都不动：它是 sidecar 行号基准。
      expect(File(srt).readAsStringSync(), contains('$_heard\n'));
      expect(File(srt).readAsStringSync(), isNot(contains('。')));
    });

    test('ASR 产物但无逐词时间：只换文本不重切，cue 数不变', () async {
      final String srt = asrJob();
      final ({List<AudioCue> cues, MatchResult result}) out = await finalize(
        srt,
        withTiming: false,
      );
      expect(out.cues, hasLength(1));
      expect(out.cues.single.text, '夢見る時がある。転入生がやってくる。');
      expect(out.cues.single.startMs, 10000);
      expect(out.cues.single.endMs, 13500);
      expect(File(asrAlignedTranscriptPathFor(srt)).existsSync(), isTrue);
    });

    test('不是 ASR 产物（同名但没有 state.json）：文本不动、不写对齐版', () async {
      final String srt = asrJob(state: false);
      final ({List<AudioCue> cues, MatchResult result}) out = await finalize(
        srt,
        withTiming: false,
      );
      expect(out.cues.single.text, _heard);
      expect(File(asrAlignedTranscriptPathFor(srt)).existsSync(), isFalse);
      // 匹配结果照样编进 cue（与替换无关的第三步不能被 ASR 判据一起门掉）。
      expect(out.cues.single.textFragmentId, isNotEmpty);
    });
  });

  group('导出优先拷对齐版', () {
    test('preferredTranscriptExportPath：有对齐版取它，没有回退原始', () {
      final String srt = asrJob();
      expect(preferredTranscriptExportPath(srt), srt);
      File(asrAlignedTranscriptPathFor(srt)).writeAsStringSync('aligned');
      expect(
        preferredTranscriptExportPath(srt),
        asrAlignedTranscriptPathFor(srt),
      );
    });

    test('exportTranscribedSrt 拷出的是对齐版内容；原始产物留在任务目录', () async {
      final String srt = asrJob();
      File(
        asrAlignedTranscriptPathFor(srt),
      ).writeAsStringSync('1\n00:00:10,000 --> 00:00:13,500\n夢見る時がある。\n\n');
      final String target = p.join(tmp.path, 'exported.srt');
      final bool ok = await exportTranscribedSrt(
        srtPath: srt,
        audioPaths: <String>[p.join(tmp.path, 'a.m4b')],
        desktop: true,
        saveFilePicker: ({
          required String fileName,
          required String? initialDirectory,
        }) async =>
            target,
      );
      expect(ok, isTrue);
      expect(File(target).readAsStringSync(), contains('夢見る時がある。'));
      expect(File(srt).readAsStringSync(), isNot(contains('。')));
    });

    test('没有对齐版时导出原始听写稿（「使用字幕」之前的首次导出）', () async {
      final String srt = asrJob();
      final String target = p.join(tmp.path, 'exported.srt');
      await exportTranscribedSrt(
        srtPath: srt,
        audioPaths: const <String>[],
        desktop: true,
        saveFilePicker: ({
          required String fileName,
          required String? initialDirectory,
        }) async =>
            target,
      );
      expect(File(target).readAsStringSync(), File(srt).readAsStringSync());
    });
  });

  test('serializeAudioCuesToSrt：跳过空文本、序号连续、换行压成空格', () {
    final List<AudioCue> cues = <AudioCue>[
      _cue()..text = '',
      _cue()..text = 'a\nb',
      _cue()
        ..startMs = 3600000
        ..endMs = 3600123
        ..text = 'c',
    ];
    expect(
      serializeAudioCuesToSrt(cues),
      '1\n00:00:10,000 --> 00:00:13,500\na b\n\n'
      '2\n01:00:00,000 --> 01:00:00,123\nc\n\n',
    );
  });
}
