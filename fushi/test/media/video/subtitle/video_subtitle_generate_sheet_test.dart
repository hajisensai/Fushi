import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/subtitle/app_video_subtitle_service.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_generate_sheet.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_model_ports.dart';
import 'package:fushi/src/media/video/video_playback_remote.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi_asr_core/asr_core.dart' show ModelDownloadEvent;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/ai_text_completer.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_language.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_recognizer_factory.dart';
import 'package:fushi_engine/media/video/video_duration_probe.dart';
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

  /// 「开始」前问联网搜索抓页确认的次数。
  int webSearchAsks = 0;

  @override
  Future<void> ensureWebSearchPageFetchDecided(BuildContext context) async =>
      webSearchAsks++;
}

/// 模型没下好、而另一处（之前那次弹层 / 设置页）正在下（kZZmXQBv7E）。
class _DownloadingAsr implements VideoSubtitleAsrModelPort {
  final StreamController<ModelDownloadEvent> running =
      StreamController<ModelDownloadEvent>.broadcast();
  int downloads = 0;

  @override
  Future<bool> isReady({
    VideoSubtitleLanguage language = VideoSubtitleLanguage.japanese,
  }) async => false;

  @override
  Stream<ModelDownloadEvent> download({
    VideoSubtitleLanguage language = VideoSubtitleLanguage.japanese,
  }) {
    downloads++;
    return running.stream;
  }

  @override
  Stream<ModelDownloadEvent>? resumeDownload({
    VideoSubtitleLanguage language = VideoSubtitleLanguage.japanese,
  }) => running.isClosed ? null : running.stream;
}

void main() {
  late FushiDatabase db;
  late Directory tmp;
  late FakeVideoSubtitleSettings settings;
  late AppVideoSubtitleTarget target;
  AiTextCompleter completer = FakeAiCompleter(answerAll);
  final List<String> probedAudio = <String>[];

  setUpAll(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
  tearDownAll(() => db.close());
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('vsub_sheet_');
    probedAudio.clear();
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

  AppVideoSubtitleService buildService({
    VideoSubtitleAsrModelPort asrModelPort = const ReadyModels(),
    List<AudioTrackFacts> audioTracks = const <AudioTrackFacts>[],
  }) => AppVideoSubtitleService(
    database: db,
    settings: settings,
    glossaryStore: MemoryGlossaryStore(),
    jobRegistry: VideoRemoteJobRegistry(),
    jobsRoot: () async => Directory(p.join(tmp.path, 'jobs')),
    probeDurationMs: (String _) async => 24 * 60 * 1000,
    probeAudioTracks: (String path) async {
      probedAudio.add(path);
      return audioTracks;
    },
    mossPort: const ReadyModels(),
    asrModelPort: asrModelPort,
    recognizerResolver:
        ({
          required VideoSubtitleSegmenterMode mode,
          MossBackendPreference mossBackend = MossBackendPreference.auto,
          VideoSubtitleLanguage language = VideoSubtitleLanguage.japanese,
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

  VideoSubtitleLanguage selectedLanguage(WidgetTester tester) => tester
      .widget<SegmentedButton<VideoSubtitleLanguage>>(
        find.descendant(
          of: find.byKey(const ValueKey<String>('video-subtitle-ai-language')),
          matching: find.byWidgetPredicate(
            (Widget w) => w is SegmentedButton<VideoSubtitleLanguage>,
          ),
        ),
      )
      .selected
      .single;

  VoidCallback? startPressed(WidgetTester tester) => tester
      .widget<FushiFilledButton>(
        find.byKey(const ValueKey<String>('video-subtitle-ai-start')),
      )
      .onPressed;

  testWidgets('重开弹层接回进行中的模型下载：显示进度、下载钮不再可点（不另起写者）', (
    WidgetTester tester,
  ) async {
    tester.view
      ..physicalSize = const Size(900, 1400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final _DownloadingAsr asr = _DownloadingAsr();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VideoSubtitleGenerateSheet(
            service: buildService(asrModelPort: asr),
            target: target,
            prefs: _FakePrefs(),
            openAiSettings: (BuildContext _) async {},
          ),
        ),
      ),
    );
    asr.running.add(
      const ModelDownloadEvent(
        fileName: 'model.onnx_data',
        receivedBytes: 40,
        totalBytes: 100,
      ),
    );
    await tester.pump();
    await tester.pump();

    final Finder button = find.byKey(
      const ValueKey<String>('video-subtitle-ai-model-download'),
    );
    expect(button, findsOneWidget);
    expect(tester.widget<FushiOutlinedButton>(button).onPressed, isNull);
    expect(asr.downloads, 0, reason: '接回而不是重新发起');

    await asr.running.close();
    await tester.pump();
    await tester.pump();
    expect(
      tester.widget<FushiOutlinedButton>(button).onPressed,
      isNotNull,
      reason: '那条结束后（仍未就绪）才允许再点',
    );
  });

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

  testWidgets('开 AI 时「开始」先过联网搜索抓页确认', (WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(900, 1400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    settings.provider = testProvider();
    final _FakePrefs ai = _FakePrefs(proofread: true, consented: true);
    await pumpSheet(tester, buildService(), ai);
    await tester.tap(
      find.byKey(const ValueKey<String>('video-subtitle-ai-start')),
    );
    // 任务跑起来后进度条一直在动，不能 pumpAndSettle。
    await tester.pump();
    expect(ai.webSearchAsks, 1);
  });

  testWidgets('不开 AI：「开始」不问联网搜索抓页确认', (WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(900, 1400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final _FakePrefs plain = _FakePrefs();
    await pumpSheet(tester, buildService(), plain);
    await tester.tap(
      find.byKey(const ValueKey<String>('video-subtitle-ai-start')),
    );
    await tester.pump();
    expect(plain.webSearchAsks, 0);
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

  testWidgets('只有中文音轨：语言默认中文，可手动改回日语', (WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(900, 1400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpSheet(
      tester,
      buildService(
        audioTracks: const <AudioTrackFacts>[
          AudioTrackFacts(index: 1, language: 'chi'),
        ],
      ),
      _FakePrefs(),
    );
    expect(selectedLanguage(tester), VideoSubtitleLanguage.mandarin);

    final Finder ja = find.byKey(
      const ValueKey<String>('video-subtitle-ai-language-ja'),
    );
    await tester.ensureVisible(ja);
    await tester.tap(ja);
    await tester.pumpAndSettle();
    expect(selectedLanguage(tester), VideoSubtitleLanguage.japanese);
  });

  testWidgets('日中双音轨：语言默认日语（原有行为）', (WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(900, 1400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpSheet(
      tester,
      buildService(
        audioTracks: const <AudioTrackFacts>[
          AudioTrackFacts(index: 1, language: 'jpn'),
          AudioTrackFacts(index: 2, language: 'chi'),
        ],
      ),
      _FakePrefs(),
    );
    expect(selectedLanguage(tester), VideoSubtitleLanguage.japanese);
  });

  AppVideoSubtitleTarget retarget({
    String? contentLanguage,
    String? originalLanguage,
  }) => AppVideoSubtitleTarget(
    title: target.title,
    work: SubtitleWorkContext(
      workKey: target.work.workKey,
      title: target.work.title,
      originalTitle: target.work.originalTitle,
      originalLanguage: originalLanguage,
    ),
    episodes: <AppVideoSubtitleEpisode>[
      for (final AppVideoSubtitleEpisode e in target.episodes)
        AppVideoSubtitleEpisode(
          bookUid: e.bookUid,
          videoPath: e.videoPath,
          title: e.title,
          contentLanguage: contentLanguage,
        ),
    ],
    bookUid: target.bookUid,
  );

  String? languageHint(WidgetTester tester) {
    final Finder f = find.byKey(
      const ValueKey<String>('video-subtitle-ai-language-source'),
    );
    return f.evaluate().isEmpty ? null : tester.widget<Text>(f).data;
  }

  testWidgets('视频设了内容语言 zh：压过只有 jpn 的音轨，不探测音轨，提示来由', (
    WidgetTester tester,
  ) async {
    tester.view
      ..physicalSize = const Size(900, 1400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    target = retarget(contentLanguage: 'zh-Hans', originalLanguage: 'ja');
    await pumpSheet(
      tester,
      buildService(
        audioTracks: const <AudioTrackFacts>[
          AudioTrackFacts(index: 1, language: 'jpn'),
        ],
      ),
      _FakePrefs(),
    );
    expect(selectedLanguage(tester), VideoSubtitleLanguage.mandarin);
    expect(probedAudio, isEmpty);
    expect(languageHint(tester), t.video_subtitle_ai_language_from_content);
  });

  testWidgets('音轨没标语言：按刮削原语言 zh 选中文；手动改后提示消失', (WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(900, 1400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    target = retarget(originalLanguage: 'zh');
    await pumpSheet(
      tester,
      buildService(
        audioTracks: const <AudioTrackFacts>[AudioTrackFacts(index: 1)],
      ),
      _FakePrefs(),
    );
    expect(selectedLanguage(tester), VideoSubtitleLanguage.mandarin);
    expect(probedAudio, hasLength(1));
    expect(languageHint(tester), t.video_subtitle_ai_language_from_metadata);

    final Finder ja = find.byKey(
      const ValueKey<String>('video-subtitle-ai-language-ja'),
    );
    await tester.ensureVisible(ja);
    await tester.tap(ja);
    await tester.pumpAndSettle();
    expect(selectedLanguage(tester), VideoSubtitleLanguage.japanese);
    expect(languageHint(tester), isNull);
  });

  testWidgets('什么语言信息都没有：日语，提示是默认', (WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(900, 1400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpSheet(tester, buildService(), _FakePrefs());
    expect(selectedLanguage(tester), VideoSubtitleLanguage.japanese);
    expect(languageHint(tester), t.video_subtitle_ai_language_from_default);
  });
}
