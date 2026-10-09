// 图形字幕：整轨转文字进度卡、暂停自动 OCR 状态标记、模糊 / 隐藏遮蔽。
//
// 设了 `FUSHI_GRAPHIC_SUBTITLE_SHOT_DIR=<目录>` 时额外用真字体把三样东西叠在一帧
// 「视频画面」上渲染成 PNG（视觉证据；需要 Windows 字体，默认跳过）。
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/media/video/video_graphic_subtitle_obscure_layer.dart';
import 'package:fushi/src/media/video/video_graphic_subtitle_ocr_progress.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:material_ui/material_ui.dart';

final String? _shotDir =
    Platform.environment['FUSHI_GRAPHIC_SUBTITLE_SHOT_DIR'];

Widget _host(Widget child, {Brightness brightness = Brightness.dark}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildFushiThemeData(
      scheme: buildFushiColorScheme(
        seedColor: kFushiDefaultSeed,
        brightness: brightness,
      ),
      textTheme: FushiTypeScale.buildTextTheme(
        const TextStyle(
          fontFamily: 'ShotLatin',
          fontFamilyFallback: <String>['ShotCJK'],
        ),
      ),
    ),
    home: Scaffold(backgroundColor: Colors.black, body: child),
  );
}

VideoPlayerController _graphicController({required bool playing}) {
  final VideoPlayerController c = VideoPlayerController()
    ..debugVideoWidthOverride = 1920
    ..debugVideoHeightOverride = 1080;
  c.debugSetGraphicSubtitleActiveForTesting(true);
  c.debugSetIsPlayingForTesting(playing);
  return c;
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  group('GraphicSubtitleOcrJobState', () {
    test('抽轨阶段按已读媒体时间 / 片长出百分比；片长未知为不定态', () {
      const GraphicSubtitleOcrJobState s = GraphicSubtitleOcrJobState(
        phase: GraphicSubtitleOcrJobPhase.extracting,
        processed: Duration(minutes: 9),
        duration: Duration(minutes: 24),
      );
      expect(s.fraction, closeTo(0.375, 1e-9));
      expect(s.statusText(), contains('37%'));
      const GraphicSubtitleOcrJobState unknown = GraphicSubtitleOcrJobState(
        phase: GraphicSubtitleOcrJobPhase.extracting,
      );
      expect(unknown.fraction, isNull);
    });

    test('识别阶段报「已处理 / 总数」与百分比', () {
      const GraphicSubtitleOcrJobState s = GraphicSubtitleOcrJobState(
        phase: GraphicSubtitleOcrJobPhase.recognizing,
        done: 42,
        total: 168,
      );
      expect(s.fraction, 0.25);
      expect(s.statusText(), allOf(contains('42/168'), contains('25%')));
    });

    test('引擎名复用漫画 OCR 文案，本机 ONNX 带模型名', () {
      expect(
        graphicSubtitleOcrEngineLabel(
          MangaOcrEngineId.googleLens,
          localModelKey: '',
        ),
        t.manga_ocr_engine_google_lens,
      );
      expect(
        graphicSubtitleOcrPreferenceLabel(
          MangaOcrEnginePreference.auto,
          localModelKey: '',
        ),
        t.manga_ocr_engine_auto,
      );
    });
  });

  testWidgets('进度卡：阶段、引擎、AI 来源、取消', (WidgetTester tester) async {
    int cancelled = 0;
    await tester.pumpWidget(
      _host(
        Align(
          alignment: Alignment.topLeft,
          child: VideoGraphicSubtitleOcrProgressCard(
            state: const GraphicSubtitleOcrJobState(
              phase: GraphicSubtitleOcrJobPhase.recognizing,
              done: 3,
              total: 12,
              engineLabel: 'Local · PaddleOCR',
              aiLabel: 'Gemini · gemini-2.5-flash',
            ),
            onCancel: () => cancelled++,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('3/12'), findsOneWidget);
    expect(find.textContaining('Local · PaddleOCR'), findsOneWidget);
    expect(find.textContaining('gemini-2.5-flash'), findsOneWidget);
    await tester.tap(find.byTooltip(t.dialog_cancel));
    expect(cancelled, 1);
  });

  testWidgets('进度卡：引擎还没解析出来时不显示引擎行', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(
        VideoGraphicSubtitleOcrProgressCard(
          state: const GraphicSubtitleOcrJobState(
            phase: GraphicSubtitleOcrJobPhase.preparing,
          ),
          onCancel: () {},
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text(t.video_subtitle_graphic_ocr_job_preparing), findsWidgets);
    expect(find.textContaining('Engine:'), findsNothing);
  });

  testWidgets('暂停 OCR 状态标记：识别中 / 已识别 / 空闲', (WidgetTester tester) async {
    Future<void> show(GraphicSubtitlePauseOcrStatus status) async {
      await tester.pumpWidget(
        _host(Center(child: VideoGraphicSubtitleOcrStatusPill(status: status))),
      );
      await tester.pump(const Duration(milliseconds: 500));
    }

    await show(GraphicSubtitlePauseOcrStatus.recognizing);
    expect(
      find.text(t.video_subtitle_graphic_ocr_status_recognizing),
      findsOneWidget,
    );
    await show(GraphicSubtitlePauseOcrStatus.ready);
    expect(
      find.text(t.video_subtitle_graphic_ocr_status_ready),
      findsOneWidget,
    );
    await show(GraphicSubtitlePauseOcrStatus.idle);
    expect(
      find.byKey(const ValueKey<String>('graphic_subtitle_ocr_status_pill')),
      findsNothing,
    );
  });

  group('图形字幕遮蔽门（与文本字幕同一条）', () {
    bool active({
      GraphicSubtitleObscure obscure = GraphicSubtitleObscure.blur,
      bool graphic = true,
      bool hover = false,
      bool reveal = true,
      bool playing = true,
      bool popup = false,
    }) => graphicSubtitleObscureActive(
      obscure: obscure,
      graphicActive: graphic,
      hoverRevealed: hover,
      revealOnInteraction: reveal,
      isPlaying: playing,
      lookupPopupVisible: popup,
    );

    test('播放中遮蔽；暂停 / 查词浮层 / 悬停显形', () {
      expect(active(), isTrue);
      expect(active(obscure: GraphicSubtitleObscure.hide), isTrue);
      expect(active(playing: false), isFalse);
      expect(active(popup: true), isFalse);
      expect(active(hover: true), isFalse);
    });

    test('总闸关掉：遮蔽恒定生效（暂停、悬停都不揭开）', () {
      expect(active(reveal: false, playing: false), isTrue);
      expect(active(reveal: false, hover: true), isTrue);
    });

    test('没开遮蔽 / 不是图形字幕：不遮', () {
      expect(active(obscure: GraphicSubtitleObscure.none), isFalse);
      expect(active(graphic: false), isFalse);
    });
  });

  testWidgets('模糊态：播放中字幕带上叠背景模糊，暂停后撤掉', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(960, 540);
    addTearDown(tester.view.reset);
    final VideoPlayerController c = _graphicController(playing: true);
    addTearDown(c.dispose);
    Widget layer() => _host(
      VideoGraphicSubtitleObscureLayer(
        controller: c,
        fit: BoxFit.contain,
        obscure: GraphicSubtitleObscure.blur,
        revealOnInteraction: true,
        lookupPopupVisible: false,
      ),
    );
    await tester.pumpWidget(layer());
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      find.byKey(const ValueKey<String>('graphic_subtitle_obscure_blur')),
      findsOneWidget,
    );
    final Rect band = tester.getRect(
      find.byKey(const ValueKey<String>('graphic_subtitle_obscure_band')),
    );
    // 帧底 30%：540 高的 16:9 视图里正好是 y ∈ [378, 540]。
    expect(band.top, closeTo(378, 0.5));
    expect(band.bottom, closeTo(540, 0.5));

    c.debugSetIsPlayingForTesting(false);
    await tester.pumpWidget(layer());
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      find.byKey(const ValueKey<String>('graphic_subtitle_obscure_blur')),
      findsNothing,
      reason: '暂停 = 用户在看，遮蔽让位（与文本字幕一致）',
    );
  });

  testWidgets('隐藏态：不画模糊层（交给 libmpv sub-visibility）', (
    WidgetTester tester,
  ) async {
    final VideoPlayerController c = _graphicController(playing: true);
    addTearDown(c.dispose);
    await tester.pumpWidget(
      _host(
        VideoGraphicSubtitleObscureLayer(
          controller: c,
          fit: BoxFit.contain,
          obscure: GraphicSubtitleObscure.hide,
          revealOnInteraction: true,
          lookupPopupVisible: false,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      find.byKey(const ValueKey<String>('graphic_subtitle_obscure_blur')),
      findsNothing,
    );
  });

  group('视觉证据（真字体 PNG）', () {
    setUpAll(() async {
      if (_shotDir == null) return;
      final FontLoader latin = FontLoader('ShotLatin');
      final FontLoader cjk = FontLoader('ShotCJK');
      final FontLoader icons = FontLoader('MaterialIcons');
      final String root =
          Platform.environment['FLUTTER_ROOT'] ??
          'D:/flutter_sdk/flutter_3.47.6';
      latin.addFont(
        Future<ByteData>.value(
          ByteData.sublistView(
            File(
              '$root/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf',
            ).readAsBytesSync(),
          ),
        ),
      );
      cjk.addFont(
        Future<ByteData>.value(
          ByteData.sublistView(
            File(r'C:\Windows\Fonts\Deng.ttf').readAsBytesSync(),
          ),
        ),
      );
      icons.addFont(
        Future<ByteData>.value(
          ByteData.sublistView(
            File(
              '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
            ).readAsBytesSync(),
          ),
        ),
      );
      await latin.load();
      await cjk.load();
      await icons.load();
    });

    Future<void> shoot(
      WidgetTester tester,
      String name,
      Widget Function(VideoPlayerController c) overlay, {
      bool playing = true,
    }) async {
      LocaleSettings.setLocale(AppLocale.zhCn);
      addTearDown(() => LocaleSettings.setLocale(AppLocale.en));
      const double dpr = 1.5;
      tester.view.devicePixelRatio = dpr;
      tester.view.physicalSize = const Size(960, 540) * dpr;
      addTearDown(tester.view.reset);
      final VideoPlayerController c = _graphicController(playing: playing);
      addTearDown(c.dispose);
      const Key boundary = ValueKey<String>('shot');
      await tester.pumpWidget(
        _host(
          RepaintBoundary(
            key: boundary,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[const _FakeVideoFrame(), overlay(c)],
            ),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      final RenderRepaintBoundary rb = tester
          .renderObject<RenderRepaintBoundary>(find.byKey(boundary));
      final ui.Image image = (await tester.runAsync(
        () => rb.toImage(pixelRatio: dpr),
      ))!;
      final ByteData? png = await tester.runAsync<ByteData?>(
        () => image.toByteData(format: ui.ImageByteFormat.png),
      );
      final File out = File('$_shotDir/$name.png')
        ..parent.createSync(recursive: true);
      out.writeAsBytesSync(png!.buffer.asUint8List());
    }

    testWidgets('进度卡：读取字幕轨', (WidgetTester tester) async {
      await shoot(
        tester,
        'graphic_ocr_progress_extracting',
        (_) => Padding(
          padding: const EdgeInsets.all(16),
          child: Align(
            alignment: Alignment.topLeft,
            child: VideoGraphicSubtitleOcrProgressCard(
              state: const GraphicSubtitleOcrJobState(
                phase: GraphicSubtitleOcrJobPhase.extracting,
                processed: Duration(minutes: 9),
                duration: Duration(minutes: 24),
                engineLabel: '本地 · PaddleOCR v5',
              ),
              onCancel: () {},
            ),
          ),
        ),
      );
    }, skip: _shotDir == null);

    testWidgets('进度卡：逐条识别 + AI 重读', (WidgetTester tester) async {
      await shoot(
        tester,
        'graphic_ocr_progress_recognizing',
        (_) => Padding(
          padding: const EdgeInsets.all(16),
          child: Align(
            alignment: Alignment.topLeft,
            child: VideoGraphicSubtitleOcrProgressCard(
              state: const GraphicSubtitleOcrJobState(
                phase: GraphicSubtitleOcrJobPhase.recognizing,
                done: 57,
                total: 214,
                engineLabel: '本地 · PaddleOCR v5',
                aiLabel: 'Gemini · gemini-2.5-flash',
              ),
              onCancel: () {},
            ),
          ),
        ),
      );
    }, skip: _shotDir == null);

    testWidgets('暂停 OCR 状态标记', (WidgetTester tester) async {
      await shoot(
        tester,
        'graphic_ocr_pause_status_ready',
        (_) => const Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: EdgeInsets.only(top: 56),
            child: VideoGraphicSubtitleOcrStatusPill(
              status: GraphicSubtitlePauseOcrStatus.ready,
            ),
          ),
        ),
        playing: false,
      );
    }, skip: _shotDir == null);

    testWidgets('图形字幕模糊遮蔽', (WidgetTester tester) async {
      await shoot(
        tester,
        'graphic_subtitle_blur',
        (VideoPlayerController c) => VideoGraphicSubtitleObscureLayer(
          controller: c,
          fit: BoxFit.contain,
          obscure: GraphicSubtitleObscure.blur,
          revealOnInteraction: true,
          lookupPopupVisible: false,
        ),
      );
    }, skip: _shotDir == null);
  });
}

/// 一帧假的「视频画面」：渐变背景 + 底部一行位图字幕样式的文字。
class _FakeVideoFrame extends StatelessWidget {
  const _FakeVideoFrame();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            Color(0xFF1B3A57),
            Color(0xFF6B4E71),
            Color(0xFFC77D4F),
          ],
        ),
      ),
      child: Stack(
        children: <Widget>[
          // 画面上半部的清晰细节：用来看出模糊只落在字幕带、不糊整帧。
          const Align(
            alignment: Alignment(0, -0.2),
            child: Text(
              '第 3 話　夕焼けの駅',
              style: TextStyle(
                fontFamily: 'ShotCJK',
                fontSize: 22,
                color: Colors.white70,
              ),
            ),
          ),
          Align(
            alignment: const Alignment(0, 0.82),
            child: Text(
              'もう一度だけ、あの場所へ行こう',
              style: TextStyle(
                fontFamily: 'ShotCJK',
                fontSize: 30,
                color: Colors.white,
                shadows: <Shadow>[
                  for (final Offset o in const <Offset>[
                    Offset(2, 2),
                    Offset(-2, 2),
                    Offset(2, -2),
                    Offset(-2, -2),
                  ])
                    Shadow(color: Colors.black, offset: o),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
