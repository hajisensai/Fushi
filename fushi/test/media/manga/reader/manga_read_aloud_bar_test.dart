// 漫画朗读播放条：MD3 与 Apple 两套设计系统下都渲染全部按钮，名称进无障碍语义；
// 状态行按控制器状态 / 失败原因给出对应文案。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_playback_driver.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_playback_plan.dart';
import 'package:fushi_engine/tts/cast/cast_line_kind.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_render.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/reader/manga_read_aloud_bar.dart';
import 'package:fushi/src/media/manga/reader/manga_read_aloud_controller.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi_engine/tts/tts_pronunciation.dart';
import 'package:fushi_engine/tts/tts_synthesis_scheduler.dart';
import 'package:material_ui/material_ui.dart';

/// 页文字永远在识别中：控制器停在 preparingText。
class _PendingHost implements MangaReadAloudHost {
  final Completer<MangaPageTextResult> text = Completer<MangaPageTextResult>();

  @override
  int get pageCount => 3;
  @override
  bool get rightToLeft => true;
  @override
  int get visiblePage => 0;
  @override
  bool isSameSpread(int a, int b) => a == b;
  @override
  Future<MangaPageTextResult> ensurePageText(int pageIndex) => text.future;
  @override
  Future<void> show(int pageIndex, List<int> blocks) async {}
  @override
  Future<void> clearHighlight() async {}
  @override
  void markStudyActivity() {}
}

class _NoRig implements MangaReadAloudVoiceRig {
  @override
  int get maxInputLength => 100;
  @override
  TtsSynthesisScheduler createScheduler(List<String> texts) =>
      throw UnimplementedError();
  @override
  Future<void> dispose() async {}
}

MangaReadAloudController _controller(_PendingHost host) =>
    MangaReadAloudController(
      host: host,
      rig: _NoRig(),
      pronunciation: const <TtsPronunciationRule>[],
      playToEnd: (String path, double speed) async => true,
      stopPlayback: () async {},
      readSpeed: () => 1.0,
      writeSpeed: (double _) async {},
    );

Widget _app(Widget child, {required bool apple}) => TranslationProvider(
  child: MaterialApp(
    theme: ThemeData(
      extensions: <ThemeExtension<dynamic>>[
        FushiGlassTheme(FushiGlassMaterial.off, glassDesign: apple),
      ],
    ),
    themeAnimationDuration: Duration.zero,
    home: Scaffold(body: Center(child: child)),
  ),
);

/// 成品音频播放条用的假播放器。
class _AudioPlayer extends ChangeNotifier implements MangaAudioPlayerPort {
  int pos = 0;
  bool playing = false;
  @override
  int get positionMs => pos;
  @override
  bool get isPlaying => playing;
  @override
  double get speed => 1.0;
  @override
  Future<void> play() async {
    playing = true;
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    playing = false;
    notifyListeners();
  }

  @override
  Future<void> seekMs(int ms) async {
    pos = ms;
    notifyListeners();
  }

  @override
  Future<void> setSpeed(double speed) async {}
}

MangaAudioPlaybackDriver _audioDriver(_AudioPlayer player) =>
    MangaAudioPlaybackDriver(
      bookKey: 'vol',
      plan: MangaAudioPlaybackPlan.build(
        MangaRenderManifest(
          pageCount: 2,
          lines: <MangaRenderedLine>[
            const MangaRenderedLine(
              lineId: 'p0b0',
              page: 0,
              blocks: <int>[0, 1],
              speaker: 'A',
              kind: CastLineKind.spoken,
              beatMs: 0,
              file: 'p0b0.wav',
              durationMs: 1000,
              text: 'hello',
            ),
            const MangaRenderedLine(
              lineId: 'p1b0',
              page: 1,
              blocks: <int>[0],
              speaker: 'A',
              kind: CastLineKind.spoken,
              beatMs: 0,
              file: 'p1b0.wav',
              durationMs: 900,
              text: 'later',
              placeholder: true,
            ),
          ],
        ),
      ),
      player: player,
    );

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  for (final bool apple in <bool>[false, true]) {
    testWidgets('${apple ? 'Apple' : 'MD3'}：按钮齐全、语义带名称，暂停键真的暂停', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      final _PendingHost host = _PendingHost();
      final MangaReadAloudController c = _controller(host);
      c.start(fromPage: 0);
      await tester.pumpWidget(
        _app(
          MangaReadAloudBar(controller: c, onVoice: () {}),
          apple: apple,
        ),
      );
      await tester.pump();

      expect(c.state, MangaReadAloudState.preparingText);
      expect(find.text(t.manga_read_aloud_waiting_ocr), findsOneWidget);
      for (final String key in <String>[
        'manga_read_aloud_previous',
        'manga_read_aloud_pause',
        'manga_read_aloud_next',
        'manga_read_aloud_speed',
        'manga_read_aloud_voice',
        'manga_read_aloud_stop',
      ]) {
        expect(find.byKey(ValueKey<String>(key)), findsOneWidget, reason: key);
      }
      for (final String label in <String>[
        t.manga_read_aloud_previous,
        t.pause,
        t.manga_read_aloud_next,
        t.playback_speed,
        t.audiobook_tts_voices_section,
        t.manga_read_aloud_stop,
      ]) {
        // Apple 下按钮的合并语义标签不只等于名称（名称在前），按「以名称开头」判。
        expect(
          find.bySemanticsLabel(RegExp('^${RegExp.escape(label)}')),
          findsWidgets,
          reason:
              '$label; previous button semantics: '
              '${tester.getSemantics(find.byKey(const ValueKey<String>('manga_read_aloud_previous'))).label}',
        );
      }

      await tester.tap(
        find.byKey(const ValueKey<String>('manga_read_aloud_pause')),
      );
      await tester.pump();
      expect(c.state, MangaReadAloudState.paused);
      expect(
        find.byKey(const ValueKey<String>('manga_read_aloud_resume')),
        findsOneWidget,
      );

      c.dispose();
      semantics.dispose();
    });
  }

  test('拿不到文字的每种原因都对应到现有文案', () {
    LocaleSettings.setLocale(AppLocale.en);
    expect(
      mangaReadAloudTextProblemText(MangaPageTextUnavailableReason.noEngine),
      t.manga_reader_ocr_unavailable,
    );
    expect(
      mangaReadAloudTextProblemText(
        MangaPageTextUnavailableReason.chapterOcrDisabled,
      ),
      t.manga_chapter_not_downloaded,
    );
    for (final MangaPageTextUnavailableReason reason
        in <MangaPageTextUnavailableReason>[
          MangaPageTextUnavailableReason.lensDeclined,
          MangaPageTextUnavailableReason.cancelled,
          MangaPageTextUnavailableReason.failed,
        ]) {
      expect(
        mangaReadAloudTextProblemText(reason),
        t.manga_read_aloud_ocr_unavailable,
      );
    }
  });

  for (final bool apple in <bool>[false, true]) {
    testWidgets('${apple ? 'Apple' : 'MD3'}：成品音频播放条有进度与跟随翻页、没有声音键', (
      WidgetTester tester,
    ) async {
      final _AudioPlayer player = _AudioPlayer();
      final MangaAudioPlaybackDriver d = _audioDriver(player);
      bool stopped = false;
      await tester.pumpWidget(
        _app(
          MangaAudioPlaybackBar(driver: d, onStop: () => stopped = true),
          apple: apple,
        ),
      );
      player.pos = d.plan.lineStartMs(0) + 10;
      player.notifyListeners();
      await tester.pump();
      for (final String key in <String>[
        'manga_audio_previous',
        'manga_audio_play',
        'manga_audio_next',
        'manga_audio_follow_page',
        'manga_audio_speed',
        'manga_audio_stop',
        'manga_audio_progress',
      ]) {
        expect(find.byKey(ValueKey<String>(key)), findsOneWidget, reason: key);
      }
      expect(
        find.byKey(const ValueKey<String>('manga_read_aloud_voice')),
        findsNothing,
      );
      expect(find.text('hello'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey<String>('manga_audio_play')));
      await tester.pump();
      expect(player.playing, isTrue);
      expect(
        find.byKey(const ValueKey<String>('manga_audio_pause')),
        findsOneWidget,
      );

      expect(d.followPage, isTrue);
      await tester.tap(
        find.byKey(const ValueKey<String>('manga_audio_follow_page')),
      );
      await tester.pump();
      expect(d.followPage, isFalse);

      // 占位句：状态行标「未配音」。
      player.pos = d.plan.lineStartMs(1) + 10;
      player.notifyListeners();
      await tester.pump();
      expect(find.text('${t.manga_audio_unvoiced} · later'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey<String>('manga_audio_stop')));
      expect(stopped, isTrue);
      player.playing = false;
      await tester.pumpWidget(const SizedBox());
      d.dispose();
    });
  }
}
