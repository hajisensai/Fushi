// 「设置 › AI › 联网搜索」的生效测试：设置项（ai.web_search.kind 后端分段 + SearXNG
// 地址 / Brave key）写进偏好后，下一次字幕生成给管线装的歌词查词后端里就有网页搜索
// （WebSearchSubtitleLyricsFinder，用的就是设置里那份配置）；没配全 / 关掉只剩 LRCLIB；
// 没开 AI 不装歌词补齐。schema 覆盖守卫的 kCoveredElsewhere['ai/Search backend'] 指向这里。
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/subtitle/app_video_subtitle_service.dart';
import 'package:fushi/src/media/video/video_playback_remote.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/ai_web_search_section.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/web_knowledge.dart';
import 'package:fushi_engine/ai/web_search.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_song_lyrics.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_recognizer_factory.dart';
import 'package:path/path.dart' as p;

import '../../../helpers/fake_ai_text_completer.dart';
import '../../../helpers/fake_video_subtitle.dart';

/// 提供商固定（测试替身），联网搜索现读真实偏好仓（生产的 [PrefsVideoSubtitleSettings]）。
class _PrefsBackedSettings implements AppVideoSubtitleSettings {
  _PrefsBackedSettings(this.prefs);

  final PreferencesRepository prefs;

  @override
  AiProviderConfig? get proofreadProvider => testProvider();

  @override
  List<WebKnowledgeSite> get webKnowledgeSites => const <WebKnowledgeSite>[];

  @override
  WebSearchConfig? get webSearch => PrefsVideoSubtitleSettings(prefs).webSearch;
}

void main() {
  late FushiDatabase db;
  late PreferencesRepository prefs;
  late Directory tmp;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    tmp = Directory.systemTemp.createTempSync('vsub_websearch_');
  });
  tearDown(() async {
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  /// 跑一次字幕生成，返回管线拿到的歌词查词后端（没装 = built 为假）。
  Future<({bool built, SubtitleLyricsFinder? finder})> runOnce({
    required bool proofread,
  }) async {
    final File video = File(p.join(tmp.path, 'videos', 'ep01.mkv'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(List<int>.filled(16, 1));
    await db.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: const Value<String>('a'),
        title: const Value<String>('a'),
        videoPath: Value<String>(video.path),
      ),
    );
    bool built = false;
    SubtitleLyricsFinder? finder;
    final AppVideoSubtitleService service = AppVideoSubtitleService(
      database: db,
      settings: _PrefsBackedSettings(prefs),
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
          (completer: FakeAiCompleter(answerAll), close: () {}),
      // 生产装配原样调用，只把结果记下来（识别稿里没有歌，查词后端不会被调用）。
      lyricsFinder: ({WebSearchClient? webSearch}) {
        built = true;
        return finder = buildSubtitleLyricsFinder(webSearch: webSearch);
      },
    );
    final AppVideoSubtitleJob job = service.start(
      await service.resolveBook('a'),
      AppVideoSubtitleOptions(proofread: proofread),
    );
    await job.done;
    expect(job.status, AppVideoSubtitleJobStatus.succeeded);
    return (built: built, finder: finder);
  }

  List<SubtitleLyricsFinder> backends(SubtitleLyricsFinder? finder) =>
      (finder! as CompositeSubtitleLyricsFinder).finders;

  test('选 SearXNG 并填地址 → 字幕生成装上网页搜索，用的是设置里的地址', () async {
    await setAiWebSearchKind(prefs, 'searxng');
    await setAiWebSearchEndpoint(prefs, 'https://searx.example.org');

    final List<SubtitleLyricsFinder> used = backends(
      (await runOnce(proofread: true)).finder,
    );
    expect(used.whereType<LrclibSubtitleLyricsFinder>(), hasLength(1));
    final WebSearchSubtitleLyricsFinder web = used
        .whereType<WebSearchSubtitleLyricsFinder>()
        .single;
    expect(web.search.config.kind, WebSearchKind.searxng);
    expect(web.search.config.endpoint, 'https://searx.example.org');
  });

  test('切到 Brave：没填 key 只剩 LRCLIB；填了 key 换成 Brave', () async {
    await setAiWebSearchKind(prefs, 'brave');
    expect(
      backends(
        (await runOnce(proofread: true)).finder,
      ).whereType<WebSearchSubtitleLyricsFinder>(),
      isEmpty,
    );

    await setAiWebSearchApiKey(prefs, 'tok');
    final WebSearchSubtitleLyricsFinder web = backends(
      (await runOnce(proofread: true)).finder,
    ).whereType<WebSearchSubtitleLyricsFinder>().single;
    expect(web.search.config.kind, WebSearchKind.brave);
    expect(web.search.config.apiKey, 'tok');
  });

  test('关闭（默认）→ 只有 LRCLIB；没开 AI → 不装歌词补齐', () async {
    await setAiWebSearchKind(prefs, 'searxng');
    await setAiWebSearchEndpoint(prefs, 'https://searx.example.org');
    await setAiWebSearchKind(prefs, kAiWebSearchOff);
    final List<SubtitleLyricsFinder> used = backends(
      (await runOnce(proofread: true)).finder,
    );
    expect(used, hasLength(1));
    expect(used.single, isA<LrclibSubtitleLyricsFinder>());

    await setAiWebSearchKind(prefs, 'searxng');
    await setAiWebSearchEndpoint(prefs, 'https://searx.example.org');
    expect((await runOnce(proofread: false)).built, isFalse);
  });
}
