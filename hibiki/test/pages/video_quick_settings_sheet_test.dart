import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/src/media/video/video_quick_settings_sheet.dart';
import 'package:hibiki/src/media/video/video_subtitle_style.dart';
import 'package:hibiki/utils.dart';

VideoQuickSettingsSheet _sheet({
  void Function(int)? onSetDelay,
  void Function(double)? onSetSpeed,
}) {
  return VideoQuickSettingsSheet(
    initialDelayMs: 0,
    initialSpeed: 1.0,
    initialSubtitleBlur: false,
    initialSubtitleStyle: VideoSubtitleStyle.defaults,
    onSetDelay: (int v) async => onSetDelay?.call(v),
    onSetSpeed: (double v) async => onSetSpeed?.call(v),
    onToggleSubtitleBlur: () async {},
    onSubtitleStylePreview: (_) {},
    onSubtitleStyleCommit: (_) async {},
    onOpenShaders: () {},
    onOpenMpvConfig: () {},
  );
}

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: Scaffold(body: child),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('video settings shows master-detail on wide windows',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pump(tester, _sheet());

    // 左 pane 四个分类都在；默认选中 playback → 右 pane 显示音画延迟 + 倍速。
    expect(find.text(t.video_settings_cat_playback), findsWidgets);
    expect(find.text(t.video_settings_cat_shaders), findsOneWidget);
    expect(find.text(t.video_settings_cat_mpv), findsOneWidget);
    expect(find.text(t.video_settings_cat_subtitle), findsOneWidget);
    expect(find.text(t.video_setting_av_delay), findsOneWidget);
    expect(find.text(t.video_setting_speed), findsOneWidget);
    // master-detail 无 push：无返回箭头。
    expect(find.byIcon(Icons.arrow_back), findsNothing);

    final Finder layout = find.byType(MaterialSupportingPaneLayout);
    final Finder divider = find.descendant(
      of: layout,
      matching: find.byType(VerticalDivider),
    );
    expect(
      tester.getTopLeft(divider).dx - tester.getTopLeft(layout).dx,
      248,
    );

    final List<SingleChildScrollView> paneScrollViews = tester
        .widgetList<SingleChildScrollView>(
          find.descendant(
            of: layout,
            matching: find.byType(SingleChildScrollView),
          ),
        )
        .take(2)
        .toList();
    expect(paneScrollViews, hasLength(2));
    final EdgeInsets supportingPadding =
        paneScrollViews.first.padding! as EdgeInsets;
    final EdgeInsets primaryPadding =
        paneScrollViews.last.padding! as EdgeInsets;
    expect(supportingPadding.left, supportingPadding.right);
    expect(primaryPadding.left, primaryPadding.right);
    expect(supportingPadding.left, primaryPadding.left);

    // 选「字幕」→ 右 pane 切到字幕详情，仍无返回箭头。
    await tester.tap(find.text(t.video_settings_cat_subtitle));
    await tester.pumpAndSettle();
    expect(find.text(t.video_setting_subtitle_blur), findsOneWidget);
    expect(find.text(t.video_setting_subtitle_font_size), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back), findsNothing);
  });

  testWidgets(
      'wide video settings keeps the left pane fixed while the right scrolls',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 380));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pump(tester, _sheet());

    // 字幕详情行多（开关 + 三滑条 + 重置）→ 必然超过 380 高、可独立滚动。
    await tester.tap(find.text(t.video_settings_cat_subtitle));
    await tester.pumpAndSettle();

    final Finder leftAnchor = find.text(t.video_settings_cat_playback);
    expect(leftAnchor, findsWidgets);
    final Offset before = tester.getTopLeft(leftAnchor.first);

    // 在右 pane 区域向上拖：只滚右详情，左父菜单必须纹丝不动（同 BUG-096）。
    await tester.dragFrom(const Offset(850, 250), const Offset(0, -160));
    await tester.pump();

    final Offset after = tester.getTopLeft(leftAnchor.first);
    expect(after, before, reason: '左父菜单必须固定，不能跟随右详情滚动');
  });

  testWidgets('narrow video settings pushes detail sub-pages', (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pump(tester, _sheet());

    // 窄窗主页：只列分类导航行，详情未展开（音画延迟未显示）。
    expect(find.text(t.video_settings_cat_playback), findsOneWidget);
    expect(find.text(t.video_setting_av_delay), findsNothing);
    expect(find.byIcon(Icons.arrow_back), findsNothing);

    // push 进「播放」→ 详情 + 返回箭头；返回回主页。
    await tester.tap(find.text(t.video_settings_cat_playback));
    await tester.pumpAndSettle();
    expect(find.text(t.video_setting_av_delay), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(find.text(t.video_setting_av_delay), findsNothing);
  });

  testWidgets('delay +50ms button drives the onSetDelay callback',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    int? delay;
    await _pump(tester, _sheet(onSetDelay: (int v) => delay = v));

    // 播放详情只有延迟行 + 倍速行，chevron_right 仅出现在「+50ms」按钮
    // （导航行的 chevron 在别的分类，playback 无导航行）。
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pump();
    expect(delay, 50);
  });
}
