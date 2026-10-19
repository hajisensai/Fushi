import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/subtitle/app_video_subtitle_service.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_generate_sheet.dart';
import 'package:fushi/src/media/video/video_playback_remote.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/ai_text_completer.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_recognizer_factory.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../../../helpers/fake_ai_text_completer.dart';
import '../../../helpers/fake_video_subtitle.dart';

class _FakePrefs implements VideoSubtitleGeneratePrefs {
  _FakePrefs({this.proofread = false, this.consented = false});

  @override
  bool proofread;

  @override
  bool consented;

  @override
  VideoSubtitleSegmenterMode segmenter = VideoSubtitleSegmenterMode.window;

  @override
  MossBackendPreference get mossBackend => MossBackendPreference.auto;

  @override
  Future<void> setProofread(bool value) async => proofread = value;

  @override
  Future<void> setConsented(bool value) async => consented = value;

  @override
  Future<void> setSegmenter(VideoSubtitleSegmenterMode value) async =>
      segmenter = value;
}

void main() {
  late FushiDatabase db;
  late Directory tmp;
  late FakeVideoSubtitleSettings settings;
  late AppVideoSubtitleTarget target;
  AiTextCompleter completer = FakeAiCompleter(answerAll);

  setUpAll(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
  tearDownAll(() => db.close());
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('vsub_sheet_');
    settings = FakeVideoSubtitleSettings();
    final File video = File(p.join(tmp.path, 'ep01.mkv'))
      ..writeAsBytesSync(List<int>.filled(32, 1));
    target = AppVideoSubtitleTarget(
      title: 'K-ON 01',
      work: const SubtitleWorkContext(
        workKey: 'collection:1',
        title: 'K-ON',
        originalTitle: 'けいおん!',
      ),
      episodes: <AppVideoSubtitleEpisode>[
        AppVideoSubtitleEpisode(
          bookUid: 'a',
          videoPath: video.path,
          title: 'K-ON 01',
        ),
      ],
      bookUid: 'a',
    );
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  AppVideoSubtitleService buildService() => AppVideoSubtitleService(
    database: db,
    settings: settings,
    glossaryStore: MemoryGlossaryStore(),
    jobRegistry: VideoRemoteJobRegistry(),
    jobsRoot: () async => Directory(p.join(tmp.path, 'jobs')),
    probeDurationMs: (String _) async => 24 * 60 * 1000,
    mossPort: const ReadyModels(),
    asrModelPort: const ReadyModels(),
    recognizerResolver:
        ({
          required VideoSubtitleSegmenterMode mode,
          MossBackendPreference mossBackend = MossBackendPreference.auto,
        }) async =>
            VideoSubtitleRecognizerChoice(recognizer: FakeVideoRecognizer()),
    completerFactory: (AiProviderConfig _) =>
        (completer: completer, close: () {}),
  );

  Future<int> pumpSheet(
    WidgetTester tester,
    AppVideoSubtitleService service,
    _FakePrefs prefs,
  ) async {
    int openedSettings = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 900,
            child: VideoSubtitleGenerateSheet(
              service: service,
              target: target,
              prefs: prefs,
              openAiSettings: (BuildContext _) async => openedSettings++,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return openedSettings;
  }

  VoidCallback? startPressed(WidgetTester tester) => tester
      .widget<FushiFilledButton>(
        find.byKey(const ValueKey<String>('video-subtitle-ai-start')),
      )
      .onPressed;

  testWidgets('AI 校对开着但没指派提供商：显示引导，「开始」不可点', (WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(900, 1400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final _FakePrefs prefs = _FakePrefs(proofread: true, consented: true);
    int opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VideoSubtitleGenerateSheet(
            service: buildService(),
            target: target,
            prefs: prefs,
            openAiSettings: (BuildContext _) async => opened++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('video-subtitle-ai-no-provider')),
      findsOneWidget,
    );
    expect(startPressed(tester), isNull);
    await tester.tap(
      find.byKey(const ValueKey<String>('video-subtitle-ai-open-settings')),
    );
    await tester.pumpAndSettle();
    expect(opened, 1);

    // 指派之后回到面板：显示提供商与费用预估，「开始」可点。
    settings.provider = testProvider();
    await tester.tap(
      find.byKey(const ValueKey<String>('video-subtitle-ai-open-settings')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('video-subtitle-ai-provider')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('video-subtitle-ai-estimate')),
      findsOneWidget,
    );
    expect(startPressed(tester), isNotNull);
  });

  testWidgets('首次开启 AI 校对先说明会发送什么：取消则不开，同意才开并记下', (WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(900, 1400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final _FakePrefs prefs = _FakePrefs();
    await pumpSheet(tester, buildService(), prefs);
    final Finder toggle = find.byKey(
      const ValueKey<String>('video-subtitle-ai-proofread'),
    );
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.text('What AI proofreading sends'), findsOneWidget);
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(prefs.proofread, isFalse);
    expect(prefs.consented, isFalse);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Turn on'));
    await tester.pumpAndSettle();
    expect(prefs.consented, isTrue);
    expect(prefs.proofread, isTrue);

    // 同意过：再关再开不再弹说明。
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.text('What AI proofreading sends'), findsNothing);
    expect(prefs.proofread, isTrue);
  });

  testWidgets('AI 请求失败的任务：重开面板接回，显示「暂停：AI 请求失败（原因）」与「继续」', (
    WidgetTester tester,
  ) async {
    tester.view
      ..physicalSize = const Size(900, 1400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    settings.provider = testProvider();
    final AppVideoSubtitleService service = buildService();
    completer = ExplodingAiCompleter('quota_exhausted');
    await tester.runAsync(() async {
      await service
          .start(target, const AppVideoSubtitleOptions(proofread: true))
          .done;
    });
    await pumpSheet(
      tester,
      service,
      _FakePrefs(proofread: true, consented: true),
    );
    expect(find.textContaining('Paused: AI request failed'), findsOneWidget);
    expect(find.textContaining(t.ai_error_quota_exhausted), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('video-subtitle-ai-resume')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('video-subtitle-ai-start')),
      findsNothing,
    );
  });
}
