// 漫画朗读播放条：MD3 与 Apple 两套设计系统下都渲染全部按钮，名称进无障碍语义；
// 状态行按控制器状态 / 失败原因给出对应文案。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
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
  Future<void> show(int pageIndex, int group) async {}
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
}
