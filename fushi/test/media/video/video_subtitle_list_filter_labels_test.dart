import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_jump_panel.dart';

/// BUG-4249（反馈 RMq4uXplRf）：横屏手机（792x363）上 M3E 字幕列表侧栏取最窄
/// 240px，旧的分段行把「全部 / 收藏」分段与右侧计数按 flex 1:1 对半分，分段只拿
/// 半行，每段扣掉内边距放不下两个汉字，标签被省略成空胶囊。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));
  tearDown(() => LocaleSettings.setLocale(AppLocale.en));

  Future<void> pumpPanel(
    WidgetTester tester, {
    required VideoSubtitleListFilter initialFilter,
  }) async {
    tester.view.physicalSize = const Size(792, 363);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final VideoPlayerController controller = VideoPlayerController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: Row(
            children: <Widget>[
              const Expanded(child: SizedBox()),
              // 与视频页同口径：792 宽时 autoWidth = 792 × 0.28 → clamp 到最小 240。
              SizedBox(
                width: 240,
                child: VideoSubtitleJumpPanel(
                  layout: VideoSubtitleListLayout.m3e,
                  controller: controller,
                  onTapCue: (_) {},
                  onClose: () {},
                  onCopyCue: (_) => true,
                  onFavoriteCue: (_) async {},
                  isCueFavorited: (_) => false,
                  onExportFavorites: (_) async {},
                  initialFilter: initialFilter,
                  colorScheme: const ColorScheme.dark(),
                  title: 'Subtitle list',
                  emptyHint: 'empty',
                  width: 240,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  void expectLabelFullyShown(WidgetTester tester, String label) {
    final Finder text = find.text(label);
    expect(text, findsOneWidget, reason: label);
    final RenderParagraph paragraph = tester.renderObject<RenderParagraph>(
      text,
    );
    expect(
      paragraph.didExceedMaxLines,
      isFalse,
      reason: '「$label」被省略：段宽 ${paragraph.size.width}',
    );
    final Rect segment = tester.getRect(
      find.ancestor(of: text, matching: find.byType(TextButton)).first,
    );
    final Rect textRect = tester.getRect(text);
    expect(
      segment.contains(textRect.topLeft) &&
          segment.contains(textRect.bottomRight - const Offset(0.5, 0.5)),
      isTrue,
      reason: '「$label」$textRect 没画在段 $segment 里',
    );
  }

  for (final VideoSubtitleListFilter filter in VideoSubtitleListFilter.values) {
    testWidgets('M3E 240px 侧栏的分段标签完整显示（$filter 档）', (
      WidgetTester tester,
    ) async {
      await pumpPanel(tester, initialFilter: filter);
      expect(tester.takeException(), isNull);
      expectLabelFullyShown(tester, t.video_subtitle_filter_all);
      expectLabelFullyShown(tester, t.video_subtitle_filter_favorites);
    });
  }
}
