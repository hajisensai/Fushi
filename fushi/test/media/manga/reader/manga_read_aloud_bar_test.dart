// 漫画朗读播放条（替换底栏工具栏那一行）：MD3 与 Apple 两套设计系统下都渲染全部
// 按钮，名称进无障碍语义；状态读数按控制器状态 / 失败原因给出对应文案；成品音频条
// 显示说话人、不显示台词，停止键贴在条的最右端，倍速在条上方弹出，底边进度线可点。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_playback_driver.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_playback_plan.dart';
import 'package:fushi_engine/tts/cast/cast_line_kind.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_render.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/audiobook_volume_slider.dart';
import 'package:fushi/src/media/manga/reader/manga_read_aloud_bar.dart';
import 'package:fushi/src/media/manga/reader/manga_read_aloud_controller.dart';
import 'package:fushi/src/media/manga/reader/manga_reader_chrome.dart'
    show kMangaChromeToolbarHeight;
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart'
    show FushiTooltip;
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
  double vol = 1.0;
  @override
  double get volume => vol;
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

  /// 收到过的跳转目标（按顺序）。
  final List<int> seeks = <int>[];

  @override
  Future<void> seekMs(int ms) async {
    seeks.add(ms);
    pos = ms;
    notifyListeners();
  }

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Future<void> setVolume(double volume) async {
    vol = volume;
    notifyListeners();
  }
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
      // 现场合成的播放器没有音量口径，不出音量按钮。
      expect(
        find.byKey(const ValueKey<String>('manga_audio_volume')),
        findsNothing,
      );
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
    testWidgets('${apple ? 'Apple' : 'MD3'}：成品音频播放条有进度与跟随翻页、没有声音键、不显示台词', (
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
        'manga_audio_volume',
        'manga_audio_stop',
        'manga_audio_progress',
      ]) {
        expect(find.byKey(ValueKey<String>(key)), findsOneWidget, reason: key);
      }
      expect(
        find.byKey(const ValueKey<String>('manga_read_aloud_voice')),
        findsNothing,
      );
      // 台词不进播放条（页面上的高亮框就是当前句），只显示说话人。
      expect(find.text('hello'), findsNothing);
      expect(find.text('A'), findsOneWidget);
      // 播放条与底栏工具栏同高。
      final Rect bar = tester.getRect(
        find.byKey(const ValueKey<String>('manga_read_aloud_bar')),
      );
      expect(bar.height, kMangaChromeToolbarHeight);
      // 停止键贴在条的最右端（旧卡片有说话人时 X 被 Flexible + Spacer 平分挤到中间）。
      final Rect stop = tester.getRect(
        find.byKey(const ValueKey<String>('manga_audio_stop')),
      );
      expect(bar.right - stop.right, lessThan(16));

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

      // 占位句：说话人读数的提示里标「未配音」，台词照样不显示。
      player.pos = d.plan.lineStartMs(1) + 10;
      player.notifyListeners();
      await tester.pump();
      expect(find.text('later'), findsNothing);
      // 读数提示走 FushiTooltip（Apple 下是玻璃气泡、不是带 message 的 Tooltip），
      // 按组件的 message 断言，两套设计系统同一判据。
      expect(
        find.byWidgetPredicate(
          (Widget w) =>
              w is FushiTooltip && w.message == '${t.manga_audio_unvoiced} · A',
        ),
        findsOneWidget,
      );

      // 倍速胶囊在条上方弹出倍速条，再点收起。
      expect(
        find.byKey(const ValueKey<String>('manga_read_aloud_speed_slider')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey<String>('manga_audio_speed')));
      await tester.pump();
      final Finder slider = find.byKey(
        const ValueKey<String>('manga_read_aloud_speed_slider'),
      );
      expect(slider, findsOneWidget);
      expect(tester.getRect(slider).bottom, lessThan(bar.top));
      // 弹层按内容定高：浮层给的高度上限是整屏，Material Slider 有界就取
      // maxHeight——此前倍速面板从按钮上方一路撑到屏顶（BUG-5349）。
      expect(
        tester.getRect(slider).height,
        lessThanOrEqualTo(kMangaChromeToolbarHeight),
      );
      await tester.tap(find.byKey(const ValueKey<String>('manga_audio_speed')));
      await tester.pump();
      expect(slider, findsNothing);
      // 音量弹层共用同一个弹层按钮，同一判据。
      await tester.tap(
        find.byKey(const ValueKey<String>('manga_audio_volume')),
      );
      await tester.pump();
      final Finder volume = find.byKey(
        const ValueKey<String>('manga_audio_volume_slider'),
      );
      expect(volume, findsOneWidget);
      expect(
        tester.getRect(volume).height,
        lessThanOrEqualTo(kMangaChromeToolbarHeight),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('manga_audio_volume')),
      );
      await tester.pump();
      expect(volume, findsNothing);

      // 底边进度线：点中点 = 跳到整卷一半。
      final Rect line = tester.getRect(
        find.byKey(const ValueKey<String>('manga_audio_progress')),
      );
      final int seeksBefore = player.seeks.length;
      await tester.tapAt(line.center);
      await tester.pump();
      // 断言点按发出的第一次跳转（驱动随后会把落在句间静音里的位置再吸附到句首）。
      expect(player.seeks.length, greaterThan(seeksBefore));
      expect(
        (player.seeks[seeksBefore] - d.totalMs / 2).abs(),
        lessThan(d.totalMs * 0.02),
      );

      await tester.tap(find.byKey(const ValueKey<String>('manga_audio_stop')));
      expect(stopped, isTrue);
      player.playing = false;
      await tester.pumpWidget(const SizedBox());
      d.dispose();
    });
  }

  for (final bool apple in <bool>[false, true]) {
    testWidgets(
      '${apple ? 'Apple' : 'MD3'}：成品音频播放条的音量按钮弹出有声书同口径音量条（SDfRadAtkL）',
      (WidgetTester tester) async {
        final SemanticsHandle semantics = tester.ensureSemantics();
        final _AudioPlayer player = _AudioPlayer();
        final MangaAudioPlaybackDriver d = _audioDriver(player);
        await tester.pumpWidget(
          _app(
            MangaAudioPlaybackBar(driver: d, onStop: () {}),
            apple: apple,
          ),
        );
        await tester.pump();
        final Finder button = find.byKey(
          const ValueKey<String>('manga_audio_volume'),
        );
        expect(button, findsOneWidget);
        expect(
          find.bySemanticsLabel(RegExp('^${RegExp.escape(t.audio_volume)}')),
          findsWidgets,
        );
        final Rect bar = tester.getRect(
          find.byKey(const ValueKey<String>('manga_read_aloud_bar')),
        );
        final Finder slider = find.byKey(
          const ValueKey<String>('manga_audio_volume_slider'),
        );
        expect(slider, findsNothing);

        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(slider, findsOneWidget);
        expect(tester.getRect(slider).bottom, lessThan(bar.top));
        expect(find.text('100%'), findsOneWidget);

        // 滑条回调 → 驱动 → 播放器（生产端由 AudiobookPlayerController 按书持久化）。
        tester.widget<AudiobookVolumeSlider>(slider).onChanged(0.5);
        await tester.pump();
        expect(player.vol, 0.5);
        expect(find.text('50%'), findsOneWidget);

        // 再点按钮收起。
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(slider, findsNothing);

        await tester.pumpWidget(const SizedBox());
        d.dispose();
        semantics.dispose();
      },
    );
  }

  for (final bool apple in <bool>[false, true]) {
    testWidgets(
      '${apple ? 'Apple' : 'MD3'}：成品音频播放条的「导出片段视频」按钮导出框着的那句（pZhONQTAap）',
      (WidgetTester tester) async {
        final _AudioPlayer player = _AudioPlayer();
        final MangaAudioPlaybackDriver d = _audioDriver(player);
        int exports = 0;
        Widget bar({required bool busy}) => _app(
          MangaAudioPlaybackBar(
            driver: d,
            onStop: () {},
            onExportClip: () => exports++,
            exportingClip: busy,
          ),
          apple: apple,
        );
        await tester.pumpWidget(bar(busy: false));
        player.pos = d.plan.lineStartMs(0) + 10;
        player.notifyListeners();
        await tester.pump();
        expect(d.displayedLineIndex, 0);
        final Finder button = find.byKey(
          const ValueKey<String>('manga_audio_export_clip'),
        );
        expect(button, findsOneWidget);
        expect(
          find.byWidgetPredicate(
            (Widget w) =>
                w is FushiIconButton && w.tooltip == t.audiobook_export_clip,
          ),
          findsOneWidget,
        );
        await tester.tap(button);
        await tester.pump();
        expect(exports, 1);

        // 导出中：按钮转圈。
        await tester.pumpWidget(bar(busy: true));
        expect(tester.widget<FushiIconButton>(button).busy, isTrue);

        // 框着的是没配上音的占位句：没有可导出的声音，按钮置灰。
        await tester.pumpWidget(bar(busy: false));
        player.pos = d.plan.lineStartMs(1) + 10;
        player.notifyListeners();
        await tester.pump();
        expect(d.displayedLineIndex, 1);
        expect(tester.widget<FushiIconButton>(button).enabled, isFalse);

        // 不传回调（现场合成等）就不画这颗按钮。
        await tester.pumpWidget(
          _app(
            MangaAudioPlaybackBar(driver: d, onStop: () {}),
            apple: apple,
          ),
        );
        expect(button, findsNothing);

        await tester.pumpWidget(const SizedBox());
        d.dispose();
      },
    );
  }
}
