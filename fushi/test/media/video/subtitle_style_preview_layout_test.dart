import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/subtitle_style_preview.dart';
import 'package:fushi/src/media/video/video_subtitle_style.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/video_quick_settings_harness.dart';

/// BUG-3080：字幕样式预览在竖屏手机宽度下把字号调大后，主字幕换行长过副字幕，
/// 两行画在同一处（串行），主字幕第一行还跑到副字幕上面。
///
/// 钉住：任意字号下两层字幕的绘制矩形互不相交、副字幕（默认锚顶）恒在主字幕
/// （默认锚底）之上，且都落在预览框内。
const String _kSample = '今日はいい天気ですね';

void main() {
  late VideoSheetHarness harness;

  setUp(() async {
    harness = await VideoSheetHarness.create();
  });

  tearDown(() async {
    videoSubtitleStyleDraft.value = null;
    await harness.dispose();
  });

  Future<void> pumpPreview(
    WidgetTester tester,
    double fontSize, {
    SubtitleLayerVAnchor mainAnchor = SubtitleLayerVAnchor.bottom,
    SubtitleLayerVAnchor? secondaryAnchor,
    bool showSecondary = true,
    double? bottomPadding,
  }) async {
    // 用户截图：竖屏手机约 392 逻辑 px 宽。
    tester.view.devicePixelRatio = 2.75;
    tester.view.physicalSize = const Size(392 * 2.75, 850 * 2.75);
    addTearDown(tester.view.reset);
    videoSubtitleStyleDraft.value = VideoSubtitleStyle.defaults.copyWith(
      fontSize: fontSize,
      mainAnchor: mainAnchor,
      secondaryAnchor: secondaryAnchor,
      bottomPadding: bottomPadding ?? VideoSubtitleStyle.defaults.bottomPadding,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: Align(
              alignment: Alignment.topCenter,
              child: SubtitleStylePreview(
                appModel: harness.appModel,
                uiScale: 1,
                showSecondary: showSecondary,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  for (final double fontSize in <double>[23, 36, 60, 96]) {
    testWidgets('字号 $fontSize：主副字幕不相交、副上主下、都在预览框内', (
      WidgetTester tester,
    ) async {
      await pumpPreview(tester, fontSize);

      final Finder main = find.text(_kSample);
      final Finder secondary = find.text(t.video_subtitle_preview_translation);
      expect(main, findsOneWidget);
      expect(secondary, findsOneWidget);

      final Rect mainRect = tester.getRect(main);
      final Rect secondaryRect = tester.getRect(secondary);
      expect(
        mainRect.overlaps(secondaryRect),
        isFalse,
        reason: 'main=$mainRect secondary=$secondaryRect',
      );
      expect(
        secondaryRect.bottom,
        lessThanOrEqualTo(mainRect.top),
        reason: '副字幕锚顶、主字幕锚底：与播放页同序',
      );

      // 模拟画面（圆角裁切的那块 16:9 区域），超出部分会被裁掉看不见。
      final Rect frame = tester.getRect(
        find.descendant(
          of: find.byType(SubtitleStylePreview),
          matching: find.byType(ClipRRect),
        ),
      );
      for (final Rect r in <Rect>[mainRect, secondaryRect]) {
        expect(frame.contains(r.topLeft), isTrue, reason: '$r 出了 $frame');
        expect(frame.contains(r.bottomRight), isTrue, reason: '$r 出了 $frame');
      }

      if (fontSize >= 36) {
        // 确认这一档真的触发了换行（否则测不到用户报的场景）。
        final RenderParagraph paragraph = tester.renderObject(main);
        final double lineHeight =
            paragraph.text.style!.fontSize! * kVideoSubtitleLineHeight;
        expect(paragraph.size.height, greaterThan(lineHeight * 1.5));
      }
    });
  }

  for (final SubtitleLayerVAnchor mainAnchor in SubtitleLayerVAnchor.values) {
    for (final SubtitleLayerVAnchor secondaryAnchor
        in SubtitleLayerVAnchor.values) {
      testWidgets('字号36，主$mainAnchor / 副$secondaryAnchor：按锚边顺序排列', (
        WidgetTester tester,
      ) async {
        await pumpPreview(
          tester,
          36,
          mainAnchor: mainAnchor,
          secondaryAnchor: secondaryAnchor,
        );
        final Rect main = tester.getRect(find.text(_kSample));
        final Rect secondary = tester.getRect(
          find.text(t.video_subtitle_preview_translation),
        );
        final bool mainAbove = mainAnchor == SubtitleLayerVAnchor.top;
        expect(main.overlaps(secondary), isFalse);
        expect(
          mainAbove ? main.bottom : secondary.bottom,
          lessThanOrEqualTo(mainAbove ? secondary.top : main.top),
        );
        expect(tester.takeException(), isNull);
      });
    }
    testWidgets('单层$mainAnchor，最大字号与离边距离仍在框内', (WidgetTester tester) async {
      await pumpPreview(
        tester,
        96,
        mainAnchor: mainAnchor,
        showSecondary: false,
        bottomPadding: kVideoSubtitleMaxPadding,
      );
      final Rect frame = tester.getRect(
        find.descendant(
          of: find.byType(SubtitleStylePreview),
          matching: find.byType(ClipRRect),
        ),
      );
      final Rect main = tester.getRect(find.text(_kSample));
      expect(frame.contains(main.topLeft), isTrue);
      expect(frame.contains(main.bottomRight), isTrue);
      expect(find.text(t.video_subtitle_preview_translation), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('放得下时与旧版同位：主字幕离画面底边 = bottomPadding', (
    WidgetTester tester,
  ) async {
    // 宽屏桌面窗口：16:9 显示区足够高，不应触发等比缩小。
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 720);
    addTearDown(tester.view.reset);
    videoSubtitleStyleDraft.value = VideoSubtitleStyle.defaults;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SubtitleStylePreview(
              appModel: harness.appModel,
              uiScale: 1,
              height: 360,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final RenderBox canvas = tester.renderObject(find.byType(FittedBox));
    // 虚拟画布高度 == 16:9 显示区高（1280×720 窗口 → 720），没有被撑高。
    final RenderBox virtualCanvas = (canvas as RenderFittedBox).child!;
    expect(virtualCanvas.size.height, 720);
    final Rect screen = tester.getRect(
      find.descendant(
        of: find.byType(SubtitleStylePreview),
        matching: find.byType(ClipRRect),
      ),
    );
    final Finder mainBox = find
        .ancestor(of: find.text(_kSample), matching: find.byType(DecoratedBox))
        .first;
    final Rect mainRect = tester.getRect(mainBox);
    expect(
      screen.bottom - mainRect.bottom,
      closeTo(
        VideoSubtitleStyle.defaults.bottomPadding * screen.height / 720,
        0.01,
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
