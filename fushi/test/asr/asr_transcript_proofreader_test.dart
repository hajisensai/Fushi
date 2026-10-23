import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_asr_core/asr_core.dart'
    show
        AsrCue,
        AsrCueTokenTiming,
        AsrJobFiles,
        parseAsrCueTokenTimings,
        serializeAsrCueTokens,
        serializeAsrCuesToSrt;
import 'package:fushi_engine/asr/asr_transcript_proofreader.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/ai_text_completer.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_pipeline_cancel.dart';
import 'package:path/path.dart' as p;

import '../helpers/fake_ai_text_completer.dart';

/// 提示词里本批目标行（`{"<id>": "<原文>"}`）。
Map<String, String> _targetsOf(String prompt) {
  final List<String> lines = const LineSplitter().convert(prompt);
  final int at = lines.indexOf(kAsrProofreadTargetHeader);
  expect(at, greaterThanOrEqualTo(0), reason: 'prompt has no target section');
  return (jsonDecode(lines[at + 1]) as Map<String, Object?>)
      .cast<String, String>();
}

/// 把每条目标行补上句号（已有就不动）。
String _addPeriods(String prompt, int call) => jsonEncode(<String, String>{
  for (final MapEntry<String, String> e in _targetsOf(prompt).entries)
    e.key: e.value.endsWith('。') ? e.value : '${e.value}。',
});

/// 一条按字符切 token 的 cue：token i 起点 = i*100，终点 = i*100+80。
AsrCue _cue(int index, String text, {bool withEnds = true}) {
  final List<String> tokens = text.split('');
  return AsrCue(
    startMs: index * 2000,
    endMs: index * 2000 + 1500,
    text: text,
    audioFileIndex: 0,
    tokens: tokens,
    tokenOffsetsMs: <int>[for (int i = 0; i < tokens.length; i++) i * 100],
    tokenEndOffsetsMs: withEnds
        ? <int>[for (int i = 0; i < tokens.length; i++) i * 100 + 80]
        : null,
  );
}

void _expectWellFormed(AsrCue cue) {
  expect(cue.tokens.join(), cue.text);
  expect(cue.tokenOffsetsMs.length, cue.tokens.length);
  if (cue.tokenEndOffsetsMs != null) {
    expect(cue.tokenEndOffsetsMs!.length, cue.tokens.length);
  }
  for (int i = 0; i < cue.tokens.length; i++) {
    expect(cue.tokenOffsetsMs[i], inInclusiveRange(0, cue.durationMs));
    if (i > 0) {
      expect(
        cue.tokenOffsetsMs[i],
        greaterThanOrEqualTo(cue.tokenOffsetsMs[i - 1]),
      );
    }
    final List<int>? ends = cue.tokenEndOffsetsMs;
    if (ends != null) {
      expect(ends[i], inInclusiveRange(0, cue.durationMs));
      expect(ends[i], greaterThanOrEqualTo(cue.tokenOffsetsMs[i]));
      if (i > 0) expect(ends[i], greaterThanOrEqualTo(ends[i - 1]));
    }
  }
}

const List<String> _texts = <String>[
  '今日はいい天気',
  'そうですね',
  '散歩に行きましょう',
  'いいですよ',
  'じゃあ行こう',
];

void main() {
  group('asrCueWithProofreadText', () {
    test('LCS 对齐：匹配字继承旧时间，插入的标点取前一字的时间', () {
      const AsrCue cue = AsrCue(
        startMs: 10000,
        endMs: 11200,
        text: '今日はいい天気',
        audioFileIndex: 3,
        tokens: <String>['今日', 'は', 'いい', '天気'],
        tokenOffsetsMs: <int>[0, 300, 500, 800],
        tokenEndOffsetsMs: <int>[250, 450, 750, 1100],
      );
      final AsrCue out = asrCueWithProofreadText(cue, '今日は、いい天気。');
      expect(out.startMs, 10000);
      expect(out.endMs, 11200);
      expect(out.audioFileIndex, 3);
      expect(out.tokens, <String>['今', '日', 'は', '、', 'い', 'い', '天', '気', '。']);
      expect(out.tokenOffsetsMs, <int>[
        0,
        0,
        300,
        300,
        500,
        500,
        800,
        800,
        800,
      ]);
      expect(out.tokenEndOffsetsMs, <int>[
        250,
        250,
        450,
        450,
        750,
        750,
        1100,
        1100,
        1100,
      ]);
      _expectWellFormed(out);
    });

    test('开头未匹配的字取其后第一个匹配字的时间', () {
      const AsrCue cue = AsrCue(
        startMs: 0,
        endMs: 1000,
        text: 'いい天気',
        audioFileIndex: 0,
        tokens: <String>['いい', '天気'],
        tokenOffsetsMs: <int>[200, 600],
      );
      final AsrCue out = asrCueWithProofreadText(cue, '「いい天気」');
      expect(out.tokenOffsetsMs, <int>[200, 200, 200, 600, 600, 600]);
      expect(out.tokenEndOffsetsMs, isNull);
      _expectWellFormed(out);
    });

    test('旧 cue 没有 token 时按时长线性分配', () {
      const AsrCue cue = AsrCue(
        startMs: 0,
        endMs: 1000,
        text: 'abcd',
        audioFileIndex: 0,
        tokenEndOffsetsMs: <int>[],
      );
      final AsrCue out = asrCueWithProofreadText(cue, 'abcd.');
      expect(out.tokenOffsetsMs, <int>[0, 200, 400, 600, 800]);
      expect(out.tokenEndOffsetsMs, <int>[200, 400, 600, 800, 1000]);
      _expectWellFormed(out);
    });

    test('完全不匹配时线性分配；超长文本跳过 LCS 也线性分配', () {
      final AsrCue noMatch = asrCueWithProofreadText(_cue(0, 'abc'), 'xyz');
      expect(noMatch.tokenOffsetsMs, <int>[0, 500, 1000]);
      _expectWellFormed(noMatch);

      final String long = 'あ' * 2500;
      final AsrCue big = asrCueWithProofreadText(
        AsrCue(
          startMs: 0,
          endMs: 2500,
          text: long,
          audioFileIndex: 0,
          tokens: <String>[long],
          tokenOffsetsMs: const <int>[100],
        ),
        '$long。',
      );
      expect(big.tokens.length, 2501);
      expect(big.tokenOffsetsMs.first, 0);
      expect(big.tokenOffsetsMs[1], 0);
      expect(big.tokenOffsetsMs.last, 2499);
      _expectWellFormed(big);
    });

    test('旧偏移越界时夹到 [0, duration]', () {
      const AsrCue cue = AsrCue(
        startMs: 0,
        endMs: 500,
        text: 'ab',
        audioFileIndex: 0,
        tokens: <String>['a', 'b'],
        tokenOffsetsMs: <int>[-50, 900],
        tokenEndOffsetsMs: <int>[100, 1200],
      );
      final AsrCue out = asrCueWithProofreadText(cue, 'ab!');
      expect(out.tokenOffsetsMs, <int>[0, 500, 500]);
      expect(out.tokenEndOffsetsMs, <int>[100, 500, 500]);
      _expectWellFormed(out);
    });
  });

  group('AsrTranscriptProofreader.proofread', () {
    test('补标点：cue 数与时间不变、token 重建合法、提示前缀各批一致', () async {
      final List<AsrCue> cues = <AsrCue>[
        for (int i = 0; i < _texts.length; i++) _cue(i, _texts[i]),
      ];
      final FakeAiCompleter fake = FakeAiCompleter(_addPeriods);
      final List<(int, int)> progress = <(int, int)>[];
      final AsrTranscriptProofreadOutcome out = await AsrTranscriptProofreader(
        completer: fake,
        batchSize: 2,
        contextLines: 1,
        languageTag: 'ja',
      ).proofread(cues, onProgress: (int d, int t) => progress.add((d, t)));

      expect(out.totalBatches, 3);
      expect(out.appliedBatches, 3);
      expect(out.skippedBatches, 0);
      expect(out.changedCues, 5);
      expect(fake.calls, 3);
      expect(progress.last, (3, 3));
      expect(out.cues.length, cues.length);
      for (int i = 0; i < cues.length; i++) {
        expect(out.cues[i].text, '${_texts[i]}。');
        expect(out.cues[i].startMs, cues[i].startMs);
        expect(out.cues[i].endMs, cues[i].endMs);
        expect(out.cues[i].audioFileIndex, cues[i].audioFileIndex);
        _expectWellFormed(out.cues[i]);
      }
      // 提示缓存：规则前缀逐字相同，且写明了语言。
      expect(fake.prefixes.toSet().length, 1);
      expect(fake.prefixes.first, contains('"ja"'));
      // 第二批（id 2、3）带前后各一条只读上下文。
      final String middle = fake.bodies.firstWhere(
        (String b) => _targetsOf(b).containsKey('2'),
      );
      expect(_targetsOf(middle).keys, <String>['2', '3']);
      expect(middle, contains(kAsrProofreadContextBeforeHeader));
      expect(middle, contains(kAsrProofreadContextAfterHeader));
      expect(middle, contains(_texts[1]));
      expect(middle, contains(_texts[4]));
    });

    test('未改动的 cue 原样保留（同一实例）', () async {
      final List<AsrCue> cues = <AsrCue>[_cue(0, 'そうですね。'), _cue(1, 'はい')];
      final AsrTranscriptProofreadOutcome out = await AsrTranscriptProofreader(
        completer: FakeAiCompleter(_addPeriods),
      ).proofread(cues);
      expect(identical(out.cues[0], cues[0]), isTrue);
      expect(out.cues[1].text, 'はい。');
      expect(out.changedCues, 1);
    });

    test('回复缺 id / 多 id / 空值 / 非字符串 / 非 JSON：该批保持原文，其它批照常', () async {
      final List<AsrCue> cues = <AsrCue>[
        for (int i = 0; i < 6; i++) _cue(i, 'テキスト$i'),
      ];
      const String secret = 'SECRET_REPLY_TEXT';
      String answer(String prompt, int call) {
        final Map<String, String> t = _targetsOf(prompt);
        final String id = t.keys.single;
        switch (id) {
          case '0': // 缺 id
            return '{}';
          case '1': // 多 id
            return jsonEncode(<String, String>{id: 'x', '99': secret});
          case '2': // 空值
            return jsonEncode(<String, String>{id: '  \n '});
          case '3': // 非字符串
            return jsonEncode(<String, Object>{id: 42});
          case '4': // 非 JSON
            return 'sorry, $secret';
          default:
            return '```json\n${jsonEncode(<String, String>{id: '直した\n$id'})}\n```';
        }
      }

      final List<String> logs = <String>[];
      final AsrTranscriptProofreadOutcome out = await AsrTranscriptProofreader(
        completer: FakeAiCompleter(answer),
        batchSize: 1,
        log: logs.add,
      ).proofread(cues);

      expect(out.totalBatches, 6);
      expect(out.skippedBatches, 5);
      expect(out.appliedBatches, 1);
      expect(out.changedCues, 1);
      expect(out.usage.calls, 6);
      for (int i = 0; i < 5; i++) {
        expect(identical(out.cues[i], cues[i]), isTrue);
      }
      // 换行换成空格并 trim。
      expect(out.cues[5].text, '直した 5');
      _expectWellFormed(out.cues[5]);
      expect(logs, hasLength(5));
      for (final String l in logs) {
        expect(l, isNot(contains(secret)));
      }
    });

    test('请求失败等在途批结束后原样抛出', () async {
      final List<AsrCue> cues = <AsrCue>[
        for (int i = 0; i < 4; i++) _cue(i, 'テキスト$i'),
      ];
      final Future<AsrTranscriptProofreadOutcome> run =
          AsrTranscriptProofreader(
            completer: ExplodingAiCompleter('quota_exhausted'),
            batchSize: 1,
          ).proofread(cues);
      await expectLater(
        run,
        throwsA(
          isA<SubtitleAiRequestFailure>().having(
            (SubtitleAiRequestFailure f) => f.reason,
            'reason',
            'quota_exhausted',
          ),
        ),
      );
    });

    test('已取消抛 SubtitlePipelineCancelled', () async {
      final SubtitleCancelSource cancel = SubtitleCancelSource()..cancel();
      final FakeAiCompleter fake = FakeAiCompleter(_addPeriods);
      await expectLater(
        AsrTranscriptProofreader(
          completer: fake,
        ).proofread(<AsrCue>[_cue(0, 'はい')], cancel: cancel),
        throwsA(isA<SubtitlePipelineCancelled>()),
      );
      expect(fake.calls, 0);
    });
  });

  group('proofreadAsrTranscriptFile', () {
    late Directory dir;
    late String srtPath;
    late String tokensPath;
    late String originalSrt;
    late String originalTokens;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('asr_proofread_test_');
      srtPath = p.join(dir.path, AsrJobFiles.srt);
      tokensPath = p.join(dir.path, AsrJobFiles.cueTokens);
      final List<AsrCue> cues = <AsrCue>[
        for (int i = 0; i < _texts.length; i++) _cue(i, _texts[i]),
      ];
      originalSrt = serializeAsrCuesToSrt(cues);
      originalTokens = serializeAsrCueTokens(cues);
      File(srtPath).writeAsStringSync(originalSrt);
      File(tokensPath).writeAsStringSync(originalTokens);
    });

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    String rawSrt() =>
        File(p.join(dir.path, kAsrRawTranscriptFileName)).readAsStringSync();
    String rawTokens() =>
        File(p.join(dir.path, kAsrRawCueTokensFileName)).readAsStringSync();

    test('写回校对稿与 sidecar，备份原稿；时间轴与行数不变', () async {
      expect(asrTranscriptHasProofreadBackup(srtPath), isFalse);
      final AsrTranscriptProofreadFileOutcome out =
          await proofreadAsrTranscriptFile(
            srtPath: srtPath,
            proofreader: AsrTranscriptProofreader(
              completer: FakeAiCompleter(_addPeriods),
              batchSize: 2,
            ),
          );
      expect(out.tokenSidecarWritten, isTrue);
      expect(out.changedCues, 5);
      expect(out.cueCount, 5);
      expect(asrTranscriptHasProofreadBackup(srtPath), isTrue);
      expect(rawSrt(), originalSrt);
      expect(rawTokens(), originalTokens);

      final List<AsrCue> written = parseAsrTranscriptSrt(
        File(srtPath).readAsStringSync(),
      );
      final List<AsrCue> before = parseAsrTranscriptSrt(originalSrt);
      expect(written.length, before.length);
      final List<AsrCueTokenTiming> timings = parseAsrCueTokenTimings(
        File(tokensPath).readAsStringSync(),
      )!;
      expect(timings.length, written.length);
      for (int i = 0; i < written.length; i++) {
        expect(written[i].text, '${_texts[i]}。');
        expect(written[i].startMs, before[i].startMs);
        expect(written[i].endMs, before[i].endMs);
        expect(timings[i].tokens.join(), written[i].text);
        expect(timings[i].endOffsetsMs, isNotNull);
      }
      expect(File('$srtPath.tmp').existsSync(), isFalse);
    });

    test('重跑从备份读原稿，备份只写一次', () async {
      await proofreadAsrTranscriptFile(
        srtPath: srtPath,
        proofreader: AsrTranscriptProofreader(
          completer: FakeAiCompleter(_addPeriods),
        ),
      );
      final List<String> seen = <String>[];
      String bang(String prompt, int call) {
        final Map<String, String> t = _targetsOf(prompt);
        seen.addAll(t.values);
        return jsonEncode(<String, String>{
          for (final MapEntry<String, String> e in t.entries)
            e.key: '${e.value}！',
        });
      }

      await proofreadAsrTranscriptFile(
        srtPath: srtPath,
        proofreader: AsrTranscriptProofreader(completer: FakeAiCompleter(bang)),
      );
      // 第二轮看到的是原稿（没有第一轮补的句号）。
      expect(seen, _texts);
      expect(rawSrt(), originalSrt);
      expect(rawTokens(), originalTokens);
      final List<AsrCue> written = parseAsrTranscriptSrt(
        File(srtPath).readAsStringSync(),
      );
      expect(written.map((AsrCue c) => c.text), <String>[
        for (final String t in _texts) '$t！',
      ]);
      final List<AsrCueTokenTiming> timings = parseAsrCueTokenTimings(
        File(tokensPath).readAsStringSync(),
      )!;
      expect(timings.map((AsrCueTokenTiming t) => t.tokens.join()), <String>[
        for (final String t in _texts) '$t！',
      ]);
    });

    test('sidecar 行数与 cue 数不符：照常校对 SRT，不写 sidecar', () async {
      final List<String> rows = const LineSplitter().convert(originalTokens);
      final String broken = '${rows.take(3).join('\n')}\n';
      File(tokensPath).writeAsStringSync(broken);
      final AsrTranscriptProofreadFileOutcome out =
          await proofreadAsrTranscriptFile(
            srtPath: srtPath,
            proofreader: AsrTranscriptProofreader(
              completer: FakeAiCompleter(_addPeriods),
            ),
          );
      expect(out.tokenSidecarWritten, isFalse);
      expect(out.changedCues, 5);
      expect(File(tokensPath).readAsStringSync(), broken);
      expect(
        parseAsrTranscriptSrt(
          File(srtPath).readAsStringSync(),
        ).map((AsrCue c) => c.text),
        <String>[for (final String t in _texts) '$t。'],
      );
    });

    test('sidecar 不是 JSON 也当作没有 token 时间', () async {
      File(tokensPath).writeAsStringSync('not json\n');
      final AsrTranscriptProofreadFileOutcome out =
          await proofreadAsrTranscriptFile(
            srtPath: srtPath,
            proofreader: AsrTranscriptProofreader(
              completer: FakeAiCompleter(_addPeriods),
            ),
          );
      expect(out.tokenSidecarWritten, isFalse);
      expect(File(tokensPath).readAsStringSync(), 'not json\n');
    });

    test('请求失败：原文件不动', () async {
      await expectLater(
        proofreadAsrTranscriptFile(
          srtPath: srtPath,
          proofreader: AsrTranscriptProofreader(
            completer: ExplodingAiCompleter('network_error'),
          ),
        ),
        throwsA(isA<SubtitleAiRequestFailure>()),
      );
      expect(File(srtPath).readAsStringSync(), originalSrt);
      expect(File(tokensPath).readAsStringSync(), originalTokens);
    });

    test('restore 把原稿拷回并保留备份', () async {
      expect(await restoreAsrTranscriptOriginal(srtPath), isFalse);
      await proofreadAsrTranscriptFile(
        srtPath: srtPath,
        proofreader: AsrTranscriptProofreader(
          completer: FakeAiCompleter(_addPeriods),
        ),
      );
      expect(File(srtPath).readAsStringSync(), isNot(originalSrt));
      expect(await restoreAsrTranscriptOriginal(srtPath), isTrue);
      expect(File(srtPath).readAsStringSync(), originalSrt);
      expect(File(tokensPath).readAsStringSync(), originalTokens);
      expect(asrTranscriptHasProofreadBackup(srtPath), isTrue);
    });

    test('SRT 解析容忍 CRLF，格式错误抛 FormatException', () {
      final List<AsrCue> crlf = parseAsrTranscriptSrt(
        originalSrt.replaceAll('\n', '\r\n'),
      );
      expect(crlf.map((AsrCue c) => c.text), _texts);
      expect(crlf[1].startMs, 2000);
      expect(crlf[1].endMs, 3500);
      expect(
        () => parseAsrTranscriptSrt('1\n00:00:00.000 --> 00:00:01,000\nx\n'),
        throwsFormatException,
      );
      expect(
        () => parseAsrTranscriptSrt('2\n00:00:00,000 --> 00:00:01,000\nx\n'),
        throwsFormatException,
      );
    });
  });
}
