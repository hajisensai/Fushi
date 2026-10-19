import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/ai_text_completer.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_draft.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary_drift_store.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_pipeline_cancel.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_work_context_loader.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_recognizer.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_recognizer_factory.dart';
import 'package:fushi_server/src/commands/subgen_commands.dart';
import 'package:fushi_server/src/config/server_ai_config.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'command_harness.dart';

class _Recognizer implements VideoSubtitleRecognizer {
  final List<String> seen = <String>[];

  @override
  String get id => 'fake';

  @override
  Future<List<SubtitleDraftCue>> recognize({
    required String videoPath,
    required Directory workDir,
    required VideoSubtitleRecognizeProgress onProgress,
    required SubtitleCancelToken cancel,
  }) async {
    seen.add(p.basename(videoPath));
    onProgress(1, 'transcribing');
    return <SubtitleDraftCue>[
      for (int i = 0; i < 4; i++)
        SubtitleDraftCue(
          startMs: i * 2000,
          endMs: i * 2000 + 1500,
          text: '結衣ちゃん$i',
        ),
    ];
  }
}

/// 按 `id=N` 行回 `{"N": "唯ちゃんN"}`，记下每次的前缀。
class _Completer implements AiTextCompleter {
  final List<String> prefixes = <String>[];

  @override
  Future<AiChatCompletion> complete(
    String prompt, {
    String stablePrefix = '',
  }) async {
    prefixes.add(stablePrefix);
    final Map<String, String> fix = <String, String>{
      for (final RegExpMatch m in RegExp(
        r'^id=(\d+) ',
        multiLine: true,
      ).allMatches(prompt))
        m.group(1)!: '唯ちゃん${m.group(1)}',
    };
    return AiChatCompletion(
      text: jsonEncode(fix),
      usage: const AiChatUsage(inputTokens: 7, outputTokens: 3),
    );
  }
}

void main() {
  late CommandHarness h;
  late Directory season;
  late _Recognizer recognizer;
  final List<(VideoSubtitleSegmenterMode, MossBackendPreference, String?)>
  asked = <(VideoSubtitleSegmenterMode, MossBackendPreference, String?)>[];

  setUp(() async {
    h = await CommandHarness.create();
    season = Directory(p.join(h.tmp.path, 'Show', 'Season 01'))
      ..createSync(recursive: true);
    File(p.join(season.path, 'Show - 01.mkv')).writeAsBytesSync(<int>[1]);
    File(p.join(season.path, 'Show - 02.mkv')).writeAsBytesSync(<int>[1, 2]);
    File(p.join(season.path, 'Show - 02.ja.srt')).writeAsStringSync('old');
    File(p.join(season.path, 'notes.txt')).writeAsStringSync('x');
    Directory(p.join(season.path, 'extras')).createSync();
    File(
      p.join(season.path, 'extras', 'NCOP.mp4'),
    ).writeAsBytesSync(<int>[1, 2, 3]);
    recognizer = _Recognizer();
    asked.clear();
  });
  tearDown(() => h.dispose());

  SubgenModule module({_Completer? completer}) => SubgenModule(
    io: h.io,
    deps: SubgenDeps(
      resolveRecognizer:
          (
            VideoSubtitleSegmenterMode mode,
            MossBackendPreference backend, {
            String? mossCli,
            String? mossModel,
          }) async {
            asked.add((mode, backend, mossCli));
            return VideoSubtitleRecognizerChoice(recognizer: recognizer);
          },
      probeDurationMs: (String _) async => 1440000,
      completerFactory: completer == null
          ? null
          : (AiProviderConfig _) => completer,
    ),
  );

  Future<void> configureAi() async {
    final ServerConfig config = await ServerConfig.load(h.configFile);
    await config
        .copyWith(
          ai: const ServerAiConfig(
            preset: kAiCustomPresetId,
            baseUrl: 'https://example.com/v1',
            model: 'm',
            apiKey: 'k',
            webKnowledge: false,
          ),
        )
        .save(h.configFile);
  }

  test('参数解析：枚举、覆盖路径、out-dir；没有输入 / 后缀不合法是用法错误', () {
    final ArgParser parser = ArgParser();
    module().register(parser);
    final SubgenOptions o = parseSubgenOptions(
      parser.parse(<String>[
        'subgen',
        season.path,
        '--no-ai',
        '--segmenter',
        'moss',
        '--moss-backend',
        'vulkan',
        '--suffix',
        'ja',
        '--out-dir',
        'out',
        '--moss-cli',
        'C:/a/audiocpp_cli.exe',
        '--moss-model',
        'C:/m.gguf',
        '--regen-glossary',
        '--season',
      ]).command!,
    );
    expect(o.ai, isFalse);
    expect(o.segmenter, VideoSubtitleSegmenterMode.moss);
    expect(o.mossBackend, MossBackendPreference.vulkan);
    expect(o.outDir, 'out');
    expect(o.mossCli, 'C:/a/audiocpp_cli.exe');
    expect(o.regenerateGlossary, isTrue);
    expect(o.season, isTrue);
    expect(o.inputs.single, p.absolute(season.path));
    expect(
      () => parseSubgenOptions(parser.parse(<String>['subgen']).command!),
      throwsFormatException,
    );
    expect(
      () => parseSubgenOptions(
        parser.parse(<String>['subgen', 'x', '--suffix', 'a/b']).command!,
      ),
      throwsFormatException,
    );
    expect(
      () => parser.parse(<String>['subgen', 'x', '--segmenter', 'whisper']),
      throwsFormatException,
    );
  });

  test('分组：目录递归找视频（整季）、文件合一组；不存在 / 不是视频报错', () {
    final List<SubgenGroup> groups = collectSubgenGroups(<String>[
      season.path,
      p.join(season.path, 'Show - 01.mkv'),
    ]);
    expect(groups, hasLength(2));
    expect(groups.first.wholeSeason, isTrue);
    expect(
      groups.first.videos.map(p.basename),
      // 按完整路径排序：`Season 01/Show …` 在 `Season 01/extras/…` 之前。
      <String>['Show - 01.mkv', 'Show - 02.mkv', 'NCOP.mp4'],
    );
    expect(groups.last.wholeSeason, isFalse);
    expect(
      collectSubgenGroups(<String>[
        p.join(season.path, 'Show - 01.mkv'),
      ], season: true).single.wholeSeason,
      isTrue,
    );
    expect(
      () => collectSubgenGroups(<String>[p.join(season.path, 'nope.mkv')]),
      throwsA(isA<FileSystemException>()),
    );
    expect(
      () => collectSubgenGroups(<String>[p.join(season.path, 'notes.txt')]),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('--dry-run：列出处理 / 跳过（整季已有字幕的集），不识别不写盘', () async {
    expect(
      await h.run(module(), <String>[
        'subgen',
        season.path,
        '--no-ai',
        '--dry-run',
      ]),
      0,
      reason: '${h.err}',
    );
    final String out = h.out.toString();
    expect(out, contains('跳过  Show - 02.mkv'));
    expect(out, contains('处理  Show - 01.mkv'));
    expect(out, contains('处理  NCOP.mp4'));
    expect(recognizer.seen, isEmpty);
    expect(File(p.join(season.path, 'Show - 01.ja.srt')).existsSync(), isFalse);
  });

  test('--dry-run + AI：给出按时长估的校对费用', () async {
    await configureAi();
    expect(
      await h.run(module(), <String>[
        'subgen',
        season.path,
        '--dry-run',
        '--json',
      ]),
      0,
      reason: '${h.err}',
    );
    final Map<String, Object?> json = h.json();
    final Map<String, Object?> group =
        ((json['groups']! as List<Object?>).single! as Map<Object?, Object?>)
            .cast<String, Object?>();
    final Map<Object?, Object?> estimate = group['estimate']! as Map;
    expect(estimate['fromDuration'], isTrue);
    expect(estimate['batches'], greaterThan(0));
    expect(estimate['inputTokens'], greaterThan(0));
  });

  test('没配 AI 又没给 --no-ai：69，不悄悄跳过校对', () async {
    expect(await h.run(module(), <String>['subgen', season.path]), 69);
    expect(h.err.toString(), contains('--no-ai'));
    expect(recognizer.seen, isEmpty);
  });

  test('--no-ai --out-dir：字幕全写进 out-dir，不碰视频目录；已有字幕的集跳过', () async {
    final String outDir = p.join(h.tmp.path, 'out');
    expect(
      await h.run(module(), <String>[
        'subgen',
        season.path,
        '--no-ai',
        '--segmenter',
        'moss',
        '--moss-cli',
        'cli.exe',
        '--out-dir',
        outDir,
      ]),
      0,
      reason: '${h.err}',
    );
    expect(asked.single, (
      VideoSubtitleSegmenterMode.moss,
      MossBackendPreference.auto,
      'cli.exe',
    ));
    expect(File(p.join(outDir, 'Show - 01.ja.srt')).existsSync(), isTrue);
    expect(File(p.join(outDir, 'NCOP.ja.srt')).existsSync(), isTrue);
    expect(File(p.join(season.path, 'Show - 01.ja.srt')).existsSync(), isFalse);
    // 整季跳过看的是 out-dir：那里没有 Show - 02.ja.srt，所以也处理了。
    expect(recognizer.seen, hasLength(3));
    expect(h.out.toString(), contains('exported'));
  });

  test('--glossary：导入成用户编辑的专名表、资料指纹按当前资料算（不再自动生成），校对用上它', () async {
    await configureAi();
    final File glossary = File(p.join(h.tmp.path, 'g.json'))
      ..writeAsStringSync(
        jsonEncode(<Object?>[
          <String, Object?>{
            'ja': '唯',
            'reading': 'ゆい',
            'kind': '人名',
            'misrecognitions': <String>['結衣'],
          },
        ]),
      );
    final _Completer completer = _Completer();
    final String outDir = p.join(h.tmp.path, 'out');
    expect(
      await h.run(module(completer: completer), <String>[
        'subgen',
        p.join(season.path, 'Show - 01.mkv'),
        '--title',
        'けいおん!',
        '--glossary',
        glossary.path,
        '--out-dir',
        outDir,
      ]),
      0,
      reason: '${h.err}',
    );
    // 没有生成专名表的请求（S0 提示词开头是「日本のアニメ」）。
    expect(completer.prefixes, isNotEmpty);
    expect(
      completer.prefixes.where((String s) => s.startsWith('日本のアニメ')),
      isEmpty,
    );
    expect(completer.prefixes.first, contains('唯(ゆい) 人名 誤: 結衣'));
    expect(
      File(p.join(outDir, 'Show - 01.ja.srt')).readAsStringSync(),
      contains('唯ちゃん0'),
    );
    expect(h.out.toString(), contains('AI 用量'));

    final FushiDatabase db = h.openDb();
    addTearDown(db.close);
    final SubtitleGlossary? saved = await SubtitleGlossaryDriftStore(
      db,
    ).load(fallbackSubtitleWorkKey(title: 'けいおん!'));
    expect(saved!.entries.single.userEdited, isTrue);
  });

  test('专名表校验失败：退出 1，结果里如实带出已花的 AI 用量（不是 0 次）、候选表路径', () async {
    await configureAi();
    final _WrongWork completer = _WrongWork();
    expect(
      await h.run(module(completer: completer), <String>[
        'subgen',
        p.join(season.path, 'Show - 01.mkv'),
        '--out-dir',
        p.join(h.tmp.path, 'out'),
        '--json',
      ]),
      1,
      reason: '${h.err}',
    );
    final Map<String, Object?> group =
        ((h.json()['groups']! as List<Object?>).single!
                as Map<Object?, Object?>)
            .cast<String, Object?>();
    expect(group['failure'], 'glossary_wrongWork');
    expect((group['usage']! as Map<Object?, Object?>)['calls'], 3);
    expect((group['usage']! as Map<Object?, Object?>)['input'], 21);
    expect(File('${group['glossaryCandidate']}').existsSync(), isTrue);
    expect((h.json()['usage']! as Map<Object?, Object?>)['calls'], 3);
    expect(h.err.toString(), contains('失败前已调用 AI 3 次'));
  });
}

/// 永远给一张与识别稿无关的表（无刮削路径 → 身份校验硬失败）。
class _WrongWork extends _Completer {
  @override
  Future<AiChatCompletion> complete(
    String prompt, {
    String stablePrefix = '',
  }) async => const AiChatCompletion(
    text:
        '[{"ja":"別人甲","kind":"人名"},{"ja":"別人乙","kind":"人名"},'
        '{"ja":"別人丙","kind":"人名"},{"ja":"別人丁","kind":"人名"}]',
    usage: AiChatUsage(inputTokens: 7, outputTokens: 3),
  );
}
