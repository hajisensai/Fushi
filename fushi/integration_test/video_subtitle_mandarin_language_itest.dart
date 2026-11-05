// 真 app、真视频：AI 字幕面板的「音频语言」初值与来由提示
// （spec 2026-11-04-video-subtitle-mandarin）。
//
// 视频路径经 --dart-define 传入（真片不入库；runner 用 -DartDefine KEY=路径）：
//   FUSHI_ITEST_ZH_AUDIO      音轨标 chi 的普通话视频
//   FUSHI_ITEST_UND_AUDIO     音轨标 und 的普通话视频
//   FUSHI_ITEST_JA_EN_AUDIO   英 + 日双音轨的日本动画
// 缺哪个就跳过对应一例（打印 SKIP），全缺 = 零断言，按失败处理。
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/subtitle/app_video_subtitle_service.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_generate_sheet.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart'
    show VideoBooksCompanion, VideoMetadataWorksCompanion;
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_language.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

class _Case {
  const _Case({
    required this.name,
    required this.env,
    required this.expected,
    required this.source,
    this.contentLanguage,
    this.originalLanguage,
  });

  final String name;
  final String env;
  final VideoSubtitleLanguage expected;
  final VideoSubtitleLanguageSource source;
  final String? contentLanguage;
  final String? originalLanguage;
}

const List<_Case> _cases = <_Case>[
  _Case(
    name: 'chi-audio',
    env: 'FUSHI_ITEST_ZH_AUDIO',
    expected: VideoSubtitleLanguage.mandarin,
    source: VideoSubtitleLanguageSource.audioTrack,
  ),
  _Case(
    name: 'und-audio-content-zh',
    env: 'FUSHI_ITEST_UND_AUDIO',
    contentLanguage: 'zh-Hans',
    expected: VideoSubtitleLanguage.mandarin,
    source: VideoSubtitleLanguageSource.contentLanguage,
  ),
  _Case(
    name: 'und-audio-scraped-zh',
    env: 'FUSHI_ITEST_UND_AUDIO',
    originalLanguage: 'zh',
    expected: VideoSubtitleLanguage.mandarin,
    source: VideoSubtitleLanguageSource.metadata,
  ),
  _Case(
    name: 'und-audio-nothing',
    env: 'FUSHI_ITEST_UND_AUDIO',
    expected: VideoSubtitleLanguage.japanese,
    source: VideoSubtitleLanguageSource.fallback,
  ),
  _Case(
    name: 'en-ja-audio',
    env: 'FUSHI_ITEST_JA_EN_AUDIO',
    expected: VideoSubtitleLanguage.japanese,
    source: VideoSubtitleLanguageSource.audioTrack,
  ),
];

/// dart-define 只能按常量键读。
const Map<String, String> _paths = <String, String>{
  'FUSHI_ITEST_ZH_AUDIO': String.fromEnvironment('FUSHI_ITEST_ZH_AUDIO'),
  'FUSHI_ITEST_UND_AUDIO': String.fromEnvironment('FUSHI_ITEST_UND_AUDIO'),
  'FUSHI_ITEST_JA_EN_AUDIO': String.fromEnvironment('FUSHI_ITEST_JA_EN_AUDIO'),
};

String _hintFor(VideoSubtitleLanguageSource source) => switch (source) {
  VideoSubtitleLanguageSource.contentLanguage =>
    t.video_subtitle_ai_language_from_content,
  VideoSubtitleLanguageSource.audioTrack => t.video_subtitle_ai_language_hint,
  VideoSubtitleLanguageSource.metadata =>
    t.video_subtitle_ai_language_from_metadata,
  VideoSubtitleLanguageSource.fallback =>
    t.video_subtitle_ai_language_from_default,
};

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('真视频：语言初值按内容语言 → 音轨 → 刮削原语言 → 日语，并提示来由', (
    WidgetTester tester,
  ) async {
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
    await tester.pump(const Duration(seconds: 2));
    final AppModel appModel = await readyAppModel(tester);
    final VideoBookRepository repo = VideoBookRepository(appModel.database);
    final AppVideoSubtitleService service = appVideoSubtitleService(appModel);

    int checked = 0;
    final List<String> failures = <String>[];
    for (final _Case c in _cases) {
      final String path = _paths[c.env] ?? '';
      if (path.isEmpty || !File(path).existsSync()) {
        debugPrint('[mandarin-itest] SKIP ${c.name}: ${c.env} not set');
        continue;
      }
      final String bookUid = 'video/itest-${c.name}';
      await repo.saveVideoBook(
        VideoBooksCompanion(
          bookUid: Value<String>(bookUid),
          title: Value<String>('itest ${c.name}'),
          videoPath: Value<String>(path),
          language: Value<String?>(c.contentLanguage),
        ),
      );
      if (c.originalLanguage != null) {
        await appModel.database
            .into(appModel.database.videoMetadataWorks)
            .insert(
              VideoMetadataWorksCompanion.insert(
                bookUid: Value<String?>(bookUid),
                mediaType: 'tv',
                title: 'itest ${c.name}',
                originalLanguage: Value<String?>(c.originalLanguage),
                updatedAt: 1,
              ),
            );
      }
      final AppVideoSubtitleTarget target = await service.resolveBook(bookUid);
      final VideoSubtitleLanguageGuess direct = await service.guessLanguage(
        target,
      );
      debugPrint(
        '[mandarin-itest] ${c.name}: episodes content='
        '${target.episodes.map((AppVideoSubtitleEpisode e) => e.contentLanguage).toList()} '
        'original=${target.work.originalLanguage} '
        'service=${direct.language.tag}/${direct.source.name}',
      );
      final BuildContext context = tester.element(find.byType(Scaffold).first);
      final Future<void> closed = showVideoSubtitleGenerateSheet(
        context: context,
        service: service,
        target: target,
        prefs: PrefsRepoVideoSubtitleGeneratePrefs(appModel.prefsRepo),
        openAiSettings: (BuildContext _) async {},
      );
      final Finder hint = find.byKey(
        const ValueKey<String>('video-subtitle-ai-language-source'),
      );
      final Finder sheet = find.byType(VideoSubtitleGenerateSheet);
      for (int i = 0; i < 40 && sheet.evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      for (int i = 0; i < 120 && hint.evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      await tester.pump(const Duration(seconds: 1));

      final SegmentedButton<VideoSubtitleLanguage> segmented = tester
          .widget<SegmentedButton<VideoSubtitleLanguage>>(
            find.descendant(
              of: find.byKey(
                const ValueKey<String>('video-subtitle-ai-language'),
              ),
              matching: find.byWidgetPredicate(
                (Widget w) => w is SegmentedButton<VideoSubtitleLanguage>,
              ),
            ),
          );
      final VideoSubtitleLanguage selected = segmented.selected.single;
      final String? hintText = hint.evaluate().isEmpty
          ? null
          : tester.widget<Text>(hint).data;
      debugPrint(
        '[mandarin-itest] ${c.name}: selected=${selected.tag} '
        'hint="$hintText"',
      );
      await captureFlutterFrame(tester, 'mandarin-${c.name}');
      if (selected != c.expected || hintText != _hintFor(c.source)) {
        failures.add(
          '${c.name}: got ${selected.tag} / "$hintText", want '
          '${c.expected.tag} / "${_hintFor(c.source)}"',
        );
      }
      checked++;

      Navigator.of(context, rootNavigator: true).pop();
      await closed;
      // 等关闭动画走完、旧面板离开树，下一例的查找才不会撞上它。
      for (int i = 0; i < 40 && sheet.evaluate().isNotEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
    }
    debugPrint(
      '[mandarin-itest] checked $checked/${_cases.length} cases, '
      'failures=${failures.length}',
    );
    for (final String f in failures) {
      debugPrint('[mandarin-itest] FAIL $f');
    }
    expect(checked, greaterThan(0), reason: '一例都没跑 = 空转');
    expect(failures, isEmpty);
  });
}
