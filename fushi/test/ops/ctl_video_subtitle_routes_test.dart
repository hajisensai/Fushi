import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/subtitle/app_video_subtitle_service.dart';
import 'package:fushi/src/media/video/video_playback_remote.dart';
import 'package:fushi/src/ops/ctl_video_subtitle_routes.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_recognizer_factory.dart';
import 'package:path/path.dart' as p;

import '../helpers/fake_ai_text_completer.dart';
import '../helpers/fake_video_subtitle.dart';

void main() {
  late FushiDatabase db;
  late Directory tmp;
  late FakeVideoSubtitleSettings settings;
  late MemoryGlossaryStore store;
  late AppVideoSubtitleService service;
  late CtlVideoSubtitleHandlers handlers;
  late bool consented;
  late bool videoModule;
  late List<VideoSubtitleSegmenterMode> resolvedModes;
  late List<MossBackendPreference> resolvedBackends;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    tmp = Directory.systemTemp.createTempSync('ctl_vsub_');
    settings = FakeVideoSubtitleSettings();
    store = MemoryGlossaryStore();
    consented = false;
    videoModule = true;
    resolvedModes = <VideoSubtitleSegmenterMode>[];
    resolvedBackends = <MossBackendPreference>[];
    service = AppVideoSubtitleService(
      database: db,
      settings: settings,
      glossaryStore: store,
      jobRegistry: VideoRemoteJobRegistry(),
      jobsRoot: () async => Directory(p.join(tmp.path, 'jobs')),
      probeDurationMs: (String _) async => 60000 * 24,
      mossPort: const ReadyModels(),
      asrModelPort: const ReadyModels(),
      recognizerResolver:
          ({
            required VideoSubtitleSegmenterMode mode,
            MossBackendPreference mossBackend = MossBackendPreference.auto,
          }) async {
            resolvedModes.add(mode);
            resolvedBackends.add(mossBackend);
            return VideoSubtitleRecognizerChoice(
              recognizer: FakeVideoRecognizer(),
            );
          },
      completerFactory: (AiProviderConfig _) =>
          (completer: FakeAiCompleter(answerAll), close: () {}),
    );
    handlers = CtlVideoSubtitleHandlers(
      service: () => service,
      consented: () => consented,
      acceptConsent: () async => consented = true,
      defaultSegmenter: () => VideoSubtitleSegmenterMode.window,
      defaultMossBackend: () => MossBackendPreference.cpu,
      videoModuleEnabled: () => videoModule,
      asrSupported: () => true,
    );
    final File video = File(p.join(tmp.path, 'ep01.mkv'))
      ..writeAsBytesSync(List<int>.filled(40, 1));
    await db.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: const Value<String>('a'),
        title: const Value<String>('K-ON 01'),
        videoPath: Value<String>(video.path),
      ),
    );
  });
  tearDown(() async {
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  CtlCall post(Map<String, Object?> body) =>
      CtlCall(method: 'POST', path: kCtlVideoSubtitleGenPath, body: body);

  Matcher failure(int status, [String? code]) => throwsA(
    isA<CtlFailure>()
        .having((CtlFailure f) => f.status, 'status', status)
        .having((CtlFailure f) => f.code, 'code', code ?? anything),
  );

  test('目标：bookUid / collectionId 恰好一个；不存在 404', () async {
    await expectLater(
      handlers.generate(post(<String, Object?>{})),
      failure(400),
    );
    await expectLater(
      handlers.generate(
        post(<String, Object?>{'bookUid': 'a', 'collectionId': 1}),
      ),
      failure(400),
    );
    await expectLater(
      handlers.generate(
        post(<String, Object?>{'bookUid': 'zzz', 'proofread': false}),
      ),
      failure(404),
    );
  });

  test('「视频」模块关闭：422', () async {
    videoModule = false;
    await expectLater(
      handlers.generate(
        post(<String, Object?>{'bookUid': 'a', 'proofread': false}),
      ),
      failure(422, 'rejected'),
    );
  });

  test('缺省开 AI：没指派提供商 422，不起任务', () async {
    await expectLater(
      handlers.generate(post(<String, Object?>{'bookUid': 'a'})),
      failure(422, 'rejected'),
    );
    expect(service.activeJob, isNull);
  });

  test('有提供商但没同意：422；带 consentAi 写入同意并起任务，wait 返回结果', () async {
    settings.provider = testProvider();
    await expectLater(
      handlers.generate(post(<String, Object?>{'bookUid': 'a'})),
      failure(422, 'rejected'),
    );
    expect(consented, isFalse);
    final Object? data = await handlers.generate(
      post(<String, Object?>{'bookUid': 'a', 'consentAi': true, 'wait': true}),
    );
    expect(consented, isTrue);
    final Map<String, Object?> json = data! as Map<String, Object?>;
    expect(json['status'], 'succeeded');
    expect(json['kind'], 'subtitleGenerate');
    final Map<String, Object?> result = json['result']! as Map<String, Object?>;
    final List<Object?> episodes = result['episodes']! as List<Object?>;
    expect((episodes.single! as Map<String, Object?>)['status'], 'exported');
    expect(resolvedModes, <VideoSubtitleSegmenterMode>[
      VideoSubtitleSegmenterMode.window,
    ], reason: '没给 segmenter 用设置里的值');
    expect(resolvedBackends, <MossBackendPreference>[
      MossBackendPreference.cpu,
    ], reason: '没给 mossBackend 用设置里的值');
  });

  test('--no-ai：不要提供商也不要同意；segmenter 显式值透传，非法值 400', () async {
    final Object? data = await handlers.generate(
      post(<String, Object?>{
        'bookUid': 'a',
        'proofread': false,
        'segmenter': 'auto',
        'mossBackend': 'vulkan',
        'wait': true,
      }),
    );
    expect((data! as Map<String, Object?>)['status'], 'succeeded');
    expect(resolvedModes, <VideoSubtitleSegmenterMode>[
      VideoSubtitleSegmenterMode.auto,
    ]);
    expect(resolvedBackends, <MossBackendPreference>[
      MossBackendPreference.vulkan,
    ]);
    await expectLater(
      handlers.generate(
        post(<String, Object?>{
          'bookUid': 'a',
          'proofread': false,
          'segmenter': 'magic',
        }),
      ),
      failure(400),
    );
  });

  test('已有任务在跑：409', () async {
    final Object? first = await handlers.generate(
      post(<String, Object?>{'bookUid': 'a', 'proofread': false}),
    );
    expect((first! as Map<String, Object?>)['status'], 'running');
    await expectLater(
      handlers.generate(
        post(<String, Object?>{'bookUid': 'a', 'proofread': false}),
      ),
      failure(409, 'conflict'),
    );
    await service.activeJob?.done;
  });

  test('专名表：GET 读、PUT 整表替换（标 userEdited），重复 / 缺 ja 400', () async {
    final Map<String, Object?> empty =
        await handlers.glossary(
              CtlCall(
                method: 'GET',
                path: kCtlVideoSubtitleGlossaryPath,
                query: const <String, String>{'bookUid': 'a'},
              ),
            )
            as Map<String, Object?>;
    expect(empty['entries'], isEmpty);
    final String workKey = empty['workKey']! as String;

    CtlCall put(List<Object?> entries) => CtlCall(
      method: 'PUT',
      path: kCtlVideoSubtitleGlossaryPath,
      body: <String, Object?>{'bookUid': 'a', 'entries': entries},
    );
    await expectLater(
      handlers.setGlossary(
        put(<Object?>[
          <String, Object?>{'ja': '唯'},
          <String, Object?>{'ja': '唯'},
        ]),
      ),
      failure(400),
    );
    await expectLater(
      handlers.setGlossary(
        put(<Object?>[
          <String, Object?>{'reading': 'ゆい'},
        ]),
      ),
      failure(400),
    );
    final Map<String, Object?> saved =
        await handlers.setGlossary(
              put(<Object?>[
                <String, Object?>{
                  'ja': '唯',
                  'reading': 'ゆい',
                  'kind': '人名',
                  'misrecognitions': <String>['結衣'],
                },
              ]),
            )
            as Map<String, Object?>;
    final List<Object?> entries = saved['entries']! as List<Object?>;
    expect((entries.single! as Map<String, Object?>)['userEdited'], isTrue);
    final SubtitleGlossary stored = store.rows[workKey]!;
    expect(stored.entries.single.misrecognitions, <String>['結衣']);
  });
}
