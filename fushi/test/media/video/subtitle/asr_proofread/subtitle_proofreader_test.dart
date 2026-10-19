import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_rate_limiter.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/ai_text_completer.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_draft.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_proofreader.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

import '../../../../helpers/fake_ai_text_completer.dart';

/// S3 校对：回复覆盖全部 id 才落批缓存；缺 id 重试、最终失败报错；请求失败（额度）
/// 绝不被当成「没有修改」写进缓存（基准里真踩过：30 段静默通过）。
void main() {
  late Directory tmp;
  late Directory cacheDir;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('s3_proofread_');
    cacheDir = Directory(p.join(tmp.path, 'proofread'));
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  List<SubtitleDraftCue> cues(int n) => <SubtitleDraftCue>[
    for (int i = 0; i < n; i++)
      SubtitleDraftCue(
        startMs: i * 2000,
        endMs: i * 2000 + 1500,
        text: 'line$i',
        alternatives: i == 0 ? const <String>['候补零'] : const <String>[],
      ),
  ];

  const SubtitleGlossary glossary = SubtitleGlossary(
    entries: <SubtitleGlossaryEntry>[
      SubtitleGlossaryEntry(
        ja: '唯',
        reading: 'ゆい',
        kind: '人名',
        misrecognitions: <String>['結衣'],
      ),
    ],
  );

  List<String> cacheFiles() => cacheDir.existsSync()
      ? (cacheDir
            .listSync()
            .map((FileSystemEntity e) => p.basename(e.path))
            .toList()
          ..sort())
      : <String>[];

  test('全 id 覆盖：落批缓存、只改文字、!? 全角、空结果删行', () async {
    final FakeAiCompleter ai = FakeAiCompleter(
      (String prompt, int call) => replyForIds(
        prompt,
        (int id) => switch (id) {
          1 => 'ゆいちゃん!?',
          2 => '',
          _ => 'line$id',
        },
      ),
      usage: const AiChatUsage(inputTokens: 100, outputTokens: 10),
    );
    final SubtitleProofreadResult r = await SubtitleProofreader(completer: ai)
        .proofread(
          cues: cues(5),
          title: 'けいおん!!',
          glossary: glossary,
          cacheDir: cacheDir,
        );
    expect(ai.calls, 1);
    expect(r.cues.map((SubtitleDraftCue c) => c.text), <String>[
      'line0',
      'ゆいちゃん！？',
      'line3',
      'line4',
    ]);
    expect(r.cues[1].startMs, 2000);
    expect(r.cues[1].endMs, 3500);
    expect(r.removedCount, 1);
    expect(r.changedCount, 2);
    expect(cacheFiles(), <String>['00000.json']);
    final Map<String, Object?> cached =
        jsonDecode(File(p.join(cacheDir.path, '00000.json')).readAsStringSync())
            as Map<String, Object?>;
    expect((cached['usage']! as Map<String, Object?>)['input'], 100);

    // 提示词：规则原文、作品名、专名表行、候选稿。
    final String prompt = ai.prompts.single;
    expect(prompt, startsWith('あなたは日本語アニメ字幕の校正者です。'));
    expect(prompt, contains('作品名: けいおん!!'));
    expect(prompt, contains('唯(ゆい) 人名 誤: 結衣'));
    expect(prompt, contains('id=0 [00:00.00-00:01.50] 主: line0'));
    expect(prompt, contains('    候補(1): 候补零'));
  });

  test('前后 3 句只读上下文、每批 30 句、批文件按起点 5 位命名', () async {
    final FakeAiCompleter ai = FakeAiCompleter(
      (String prompt, int call) => replyForIds(prompt, (int id) => 'line$id'),
    );
    await SubtitleProofreader(completer: ai, concurrency: 2).proofread(
      cues: cues(65),
      title: 't',
      glossary: SubtitleGlossary.empty,
      cacheDir: cacheDir,
    );
    expect(ai.calls, 3);
    expect(cacheFiles(), <String>['00000.json', '00030.json', '00060.json']);
    final String middle = ai.prompts.firstWhere(
      (String s) => targetIdsOf(s).first == 30,
    );
    expect(targetIdsOf(middle), List<int>.generate(30, (int i) => 30 + i));
    expect(middle, contains('参考(直前の行、修正不要):\n  [00:54.00] line27'));
    expect(middle, contains('参考(直後の行、修正不要):\n  [02:00.00] line60'));
    expect(middle, isNot(contains('固有名詞表:\n')), reason: '空表不出这一段');
  });

  test('缺 id：不缓存、重试；第 2 次覆盖全部 id 才落盘，用量两次都计', () async {
    final FakeAiCompleter ai = FakeAiCompleter((String prompt, int call) {
      if (call == 0) {
        return jsonEncode(<String, String>{'0': 'x'}); // 缺 1..4
      }
      return replyForIds(prompt, (int id) => 'fixed$id');
    }, usage: const AiChatUsage(outputTokens: 7));
    final SubtitleProofreadResult r = await SubtitleProofreader(completer: ai)
        .proofread(
          cues: cues(5),
          title: 't',
          glossary: SubtitleGlossary.empty,
          cacheDir: cacheDir,
        );
    expect(ai.calls, 2);
    expect(r.cues.first.text, 'fixed0');
    expect(r.usage.calls, 2);
    expect(r.usage.outputTokens, 14);
  });

  test('3 次都缺 id / 不是 JSON：抛 reply_incomplete，批缓存一个都不写', () async {
    final FakeAiCompleter ai = FakeAiCompleter(
      (String prompt, int call) => call.isEven ? '修正はありません' : '{"0": "x"}',
    );
    await expectLater(
      SubtitleProofreader(completer: ai).proofread(
        cues: cues(5),
        title: 't',
        glossary: SubtitleGlossary.empty,
        cacheDir: cacheDir,
      ),
      throwsA(
        isA<SubtitleAiRequestFailure>().having(
          (SubtitleAiRequestFailure f) => f.reason,
          'reason',
          kSubtitleAiReplyIncomplete,
        ),
      ),
    );
    expect(ai.calls, 3);
    expect(cacheFiles(), isEmpty);
  });

  test('额度耗尽（真 AiChatClient 收到 402）：抛 quota_exhausted，不当成空修改缓存', () async {
    final AiChatClient client = AiChatClient(
      rateLimiter: AiRateLimiter(),
      client: MockClient(
        (http.Request request) async => http.Response(
          '{"error": {"message": "Insufficient Balance"}}',
          402,
        ),
      ),
    );
    addTearDown(client.close);
    final AiChatTextCompleter completer = AiChatTextCompleter(
      client: client,
      provider: AiProviderConfig(
        id: 'quota-test',
        presetId: kAiCustomPresetId,
        name: 'p',
        baseUrl: Uri.parse('https://example.com/v1'),
        apiKey: 'k',
        model: 'm',
      ),
    );
    await expectLater(
      SubtitleProofreader(completer: completer).proofread(
        cues: cues(5),
        title: 't',
        glossary: SubtitleGlossary.empty,
        cacheDir: cacheDir,
      ),
      throwsA(
        isA<SubtitleAiRequestFailure>().having(
          (SubtitleAiRequestFailure f) => f.reason,
          'reason',
          'quota_exhausted',
        ),
      ),
    );
    expect(cacheFiles(), isEmpty);
  });

  test('模型回空正文（真 AiChatClient 的 empty_response）：当一次不合格回复重试，用量记未知', () async {
    int calls = 0;
    final AiChatClient client = AiChatClient(
      rateLimiter: AiRateLimiter(),
      client: MockClient((http.Request request) async {
        calls++;
        final String content = calls == 1
            ? ''
            : jsonEncode(<String, String>{
                for (int i = 0; i < 3; i++) '$i': 'ok$i',
              });
        return http.Response.bytes(
          utf8.encode(
            jsonEncode(<String, Object?>{
              'choices': <Object?>[
                <String, Object?>{
                  'message': <String, Object?>{'content': content},
                },
              ],
              if (calls > 1)
                'usage': <String, Object?>{
                  'prompt_tokens': 10,
                  'completion_tokens': 5,
                },
            }),
          ),
          200,
        );
      }),
    );
    addTearDown(client.close);
    final SubtitleProofreadResult r =
        await SubtitleProofreader(
          completer: AiChatTextCompleter(
            client: client,
            provider: AiProviderConfig(
              id: 'empty-test',
              presetId: kAiCustomPresetId,
              name: 'p',
              baseUrl: Uri.parse('https://example.com/v1'),
              apiKey: 'k',
              model: 'm',
            ),
          ),
        ).proofread(
          cues: cues(3),
          title: 't',
          glossary: SubtitleGlossary.empty,
          cacheDir: cacheDir,
        );
    expect(calls, 2);
    expect(r.cues.map((SubtitleDraftCue c) => c.text), <String>[
      'ok0',
      'ok1',
      'ok2',
    ]);
    expect(r.usage.calls, 2);
    expect(r.usage.callsWithoutUsage, 1);
    expect(r.usage.inputTokens, 10);
  });

  test('续跑：已缓存的批不再请求；用量从缓存里带出', () async {
    final FakeAiCompleter first = FakeAiCompleter(
      (String prompt, int call) => replyForIds(prompt, (int id) => 'fixed$id'),
      usage: const AiChatUsage(inputTokens: 50),
    );
    await SubtitleProofreader(completer: first).proofread(
      cues: cues(40),
      title: 't',
      glossary: SubtitleGlossary.empty,
      cacheDir: cacheDir,
    );
    expect(first.calls, 2);

    final ExplodingAiCompleter again = ExplodingAiCompleter();
    final SubtitleProofreadResult r =
        await SubtitleProofreader(completer: again).proofread(
          cues: cues(40),
          title: 't',
          glossary: SubtitleGlossary.empty,
          cacheDir: cacheDir,
        );
    expect(again.calls, 0);
    expect(r.cues.last.text, 'fixed39');
    expect(r.usage.inputTokens, 100);
  });

  test('一批失败：其余批照常落缓存，重跑只问失败那批', () async {
    final FakeAiCompleter flaky = FakeAiCompleter((String prompt, int call) {
      if (targetIdsOf(prompt).first == 30) return 'not json';
      return replyForIds(prompt, (int id) => 'fixed$id');
    });
    await expectLater(
      SubtitleProofreader(completer: flaky, concurrency: 1).proofread(
        cues: cues(40),
        title: 't',
        glossary: SubtitleGlossary.empty,
        cacheDir: cacheDir,
      ),
      throwsA(isA<SubtitleAiRequestFailure>()),
    );
    expect(cacheFiles(), <String>['00000.json']);

    final FakeAiCompleter good = FakeAiCompleter(
      (String prompt, int call) => replyForIds(prompt, (int id) => 'fixed$id'),
    );
    await SubtitleProofreader(completer: good).proofread(
      cues: cues(40),
      title: 't',
      glossary: SubtitleGlossary.empty,
      cacheDir: cacheDir,
    );
    expect(good.calls, 1);
    expect(targetIdsOf(good.prompts.single).first, 30);
  });

  test('formatProofreadTime 同 fmt_t（mm:ss.ss）', () {
    expect(formatProofreadTime(0), '00:00.00');
    expect(formatProofreadTime(65430), '01:05.43');
    expect(formatProofreadTime(3725000), '62:05.00');
  });
}
