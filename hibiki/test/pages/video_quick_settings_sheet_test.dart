import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/src/media/video/video_mpv_config.dart';
import 'package:hibiki/src/media/video/video_quick_settings_sheet.dart';
import 'package:hibiki/src/media/video/video_subtitle_style.dart';
import 'package:hibiki/utils.dart';

VideoQuickSettingsSheet _sheet({
  void Function(int)? onSetDelay,
  void Function(double)? onSetSpeed,
  void Function(VideoMpvConfig)? onMpvConfigChanged,
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
    initialShadersEnabled: const <String>[],
    onApplyShaders: (_) async {},
    initialMpvConfig: VideoMpvConfig.defaults,
    onMpvConfigChanged: (VideoMpvConfig c) async => onMpvConfigChanged?.call(c),
    initialLockWindowAspectRatio: true,
    onLockWindowAspectRatioChanged: (_) async {},
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
    // 左父菜单收窄到共享常量（旧硬编码 248）。
    expect(
      tester.getTopLeft(divider).dx - tester.getTopLeft(layout).dx,
      kHibikiSettingsSupportingPaneWidth,
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
    // 高度取 500（>= kHibikiSettingsWideMinHeight=440 → 进宽窗），右详情行多仍可滚。
    await tester.binding.setSurfaceSize(const Size(1000, 500));
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

  testWidgets(
      'wide-but-short video settings falls back to push below the min height',
      (tester) async {
    // 宽度够分栏（>= kHibikiSettingsWideThreshold=560），但可用高度低于
    // kHibikiSettingsWideMinHeight=440：确定性几何判据应回退窄窗 push（与书籍
    // 设置同条件，不出滚动条）。
    await tester.binding.setSurfaceSize(const Size(1000, 150));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pump(tester, _sheet());
    await tester.pumpAndSettle();

    // 回退 push 主页：默认 playback 详情（音画延迟）不再随分栏展开。
    expect(find.text(t.video_setting_av_delay), findsNothing,
        reason: '高度低于阈值时应回退 push，而非保持 master-detail 显示右详情');
    // push 主页仍列出分类导航行。
    expect(find.text(t.video_settings_cat_playback), findsOneWidget);

    // 点分类 → push 子页 + 返回箭头（证明走的是窄窗 push 语义）。
    await tester.tap(find.text(t.video_settings_cat_playback));
    await tester.pumpAndSettle();
    expect(find.text(t.video_setting_av_delay), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
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

  testWidgets('mpv category renders the config inline (no sub-dialog)',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pump(tester, _sheet());

    await tester.tap(find.text(t.video_settings_cat_mpv));
    await tester.pumpAndSettle();

    // 解码/画质/色彩/重置都内嵌在右 pane（不是导航行 → pop → 二级对话框）。
    // hwdec 是 picker 行：DropdownButton 会为测宽离屏复刻一份标题，故 findsWidgets。
    expect(find.text(t.video_setting_mpv_hwdec), findsWidgets);
    expect(find.text(t.video_setting_mpv_high_quality), findsOneWidget);
    expect(find.text(t.video_setting_mpv_brightness), findsOneWidget);
    expect(find.text(t.video_setting_mpv_reset), findsOneWidget);
    // master-detail 内嵌：无返回箭头（不走 push 子页）。
    expect(find.byIcon(Icons.arrow_back), findsNothing);
  });

  testWidgets('mpv high-quality switch drives onMpvConfigChanged live',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    VideoMpvConfig? committed;
    await _pump(tester, _sheet(onMpvConfigChanged: (c) => committed = c));

    await tester.tap(find.text(t.video_settings_cat_mpv));
    await tester.pumpAndSettle();

    // 切「高画质」开关 → 即改即生效回调（无保存按钮）。
    await tester.tap(find.byType(Switch).first);
    await tester.pump();
    expect(committed, isNotNull);
    expect(committed!.highQuality, isTrue);
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
