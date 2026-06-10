import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/src/media/video/video_asbplayer_config.dart';
import 'package:hibiki/src/media/video/video_mpv_config.dart';
import 'package:hibiki/src/media/video/video_shader_tier.dart';
import 'package:hibiki/src/media/video/video_quick_settings_sheet.dart';
import 'package:hibiki/src/media/video/video_subtitle_style.dart';
import 'package:hibiki/utils.dart';

VideoQuickSettingsSheet _sheet({
  void Function(int)? onSetDelay,
  void Function(double)? onSetSpeed,
  void Function(VideoMpvConfig)? onMpvConfigChanged,
  void Function(VideoShaderTier tier, bool highQuality)? onSelectShaderTier,
  double uiScale = 1.0,
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
    initialAsbConfig: VideoAsbplayerConfig.defaults,
    onAsbConfigChanged: (_) async {},
    onSubtitleOffsetChanged: (_) async {},
    initialShadersEnabled: const <String>[],
    onApplyShaders: (_) async {},
    onSelectShaderTier: (VideoShaderTier tier, bool hq, List<String> _) async {
      onSelectShaderTier?.call(tier, hq);
    },
    initialMpvConfig: VideoMpvConfig.defaults,
    onMpvConfigChanged: (VideoMpvConfig c) async => onMpvConfigChanged?.call(c),
    initialLockWindowAspectRatio: true,
    onLockWindowAspectRatioChanged: (_) async {},
    uiScale: uiScale,
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
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();
  late Directory shaderTempDir;

  setUp(() {
    shaderTempDir =
        Directory.systemTemp.createTempSync('hibiki_video_shader_settings');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => shaderTempDir.path,
    );
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (shaderTempDir.existsSync()) {
      shaderTempDir.deleteSync(recursive: true);
    }
  });

  test('quality tier labels are the plain 无/低/中/高/极高 selector', () {
    expect(t.video_settings_cat_shaders, 'Image enhancement');
    expect(t.video_shader_quality_tier, 'Quality enhancement');
    // 五档面向用户的标签是朴素词，不暴露陌生着色器名。
    expect(t.video_shader_tier_off, 'Off');
    expect(t.video_shader_tier_low, 'Low');
    expect(t.video_shader_tier_medium, 'Medium');
    expect(t.video_shader_tier_high, 'High');
    expect(t.video_shader_tier_ultra, 'Ultra');
    // 档位说明告诉用户取舍（含具体技术名供参考），但选择本身只是五档单选。
    expect(t.video_shader_tier_low_hint.toLowerCase(),
        contains('ewa_lanczossharp'));
    expect(t.video_shader_tier_medium_hint, contains('Anime4K'));
    expect(t.video_shader_tier_high_hint, contains('Anime4K'));
    expect(t.video_shader_tier_ultra_hint, contains('ArtCNN'));
    // 进阶（手动着色器）仍保留经典推荐入口，但不再单列 Anime4K 下载项。
    expect(t.video_shader_section_advanced, contains('Advanced'));
    expect(t.video_shader_recommended, 'Recommended image enhancements');
    expect(t.video_shader_first_use_body, contains('Anime4K'));
    expect(t.video_shader_first_use_download, contains('Download'));
  });

  testWidgets(
      'shader settings shows 5-tier selector on top and removes standalone Anime4K download entry',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pump(tester, _sheet());

    await tester.tap(find.text(t.video_settings_cat_shaders));
    await tester.pumpAndSettle();

    // 顶部是五档单选器（无/低/中/高/极高）。
    expect(find.text(t.video_shader_quality_tier), findsOneWidget);
    expect(find.byType(SegmentedButton<VideoShaderTier>), findsOneWidget);
    expect(find.text(t.video_shader_tier_off), findsOneWidget);
    expect(find.text(t.video_shader_tier_low), findsOneWidget);
    expect(find.text(t.video_shader_tier_medium), findsOneWidget);
    expect(find.text(t.video_shader_tier_high), findsOneWidget);
    expect(find.text(t.video_shader_tier_ultra), findsOneWidget);

    // 诉求 2：不再单列「下载 Anime4K 推荐着色器」入口。
    expect(find.text(t.video_shader_download_anime4k), findsNothing);

    // 进阶 section 仍保留经典推荐 + 手动下载链接（给懂的人），位于档位选择器下方。
    expect(find.text(t.video_shader_section_advanced), findsOneWidget);
    expect(find.text(t.video_shader_classic_recommended), findsOneWidget);
    expect(find.text(t.video_shader_download_url), findsOneWidget);

    final double tierY =
        tester.getTopLeft(find.text(t.video_shader_quality_tier)).dy;
    final double advancedY =
        tester.getTopLeft(find.text(t.video_shader_section_advanced)).dy;
    expect(tierY, lessThan(advancedY), reason: '五档选择器在最上，进阶项在其下');
  });

  testWidgets('selecting a no-download tier (低/无) switches via onSelectTier',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    VideoShaderTier? selectedTier;
    bool? selectedHq;
    await _pump(
      tester,
      _sheet(onSelectShaderTier: (VideoShaderTier tier, bool hq) {
        selectedTier = tier;
        selectedHq = hq;
      }),
    );

    await tester.tap(find.text(t.video_settings_cat_shaders));
    await tester.pumpAndSettle();

    // 初始默认（highQuality=true + 空启用集）已高亮「低」档；先点「无」（值变化触发回调）：
    // 「无」档零下载——关闭内置缩放 + 空启用集，直接经回调切档、不弹下载框。
    await tester.tap(find.text(t.video_shader_tier_off));
    await tester.pumpAndSettle();
    expect(selectedTier, VideoShaderTier.off);
    expect(selectedHq, isFalse);

    // 再点「低」（零下载，仅 mpv 内置 scale）：又一次值变化，经回调切回低档。
    await tester.tap(find.text(t.video_shader_tier_low));
    await tester.pumpAndSettle();
    expect(selectedTier, VideoShaderTier.low);
    expect(selectedHq, isTrue);
  });

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
    expect(find.text(t.video_setting_subtitle_font_weight), findsOneWidget);
    expect(find.text(t.video_setting_subtitle_shadow), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back), findsNothing);
  });

  testWidgets('subtitle default weight and shadow preview use app UI scale',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pump(tester, _sheet(uiScale: 2.0));

    await tester.tap(find.text(t.video_settings_cat_subtitle));
    await tester.pumpAndSettle();

    final AdaptiveSettingsStepperRow fontWeightRow =
        tester.widget<AdaptiveSettingsStepperRow>(
      find.widgetWithText(
        AdaptiveSettingsStepperRow,
        t.video_setting_subtitle_font_weight,
      ),
    );
    expect(fontWeightRow.value, 900);

    final Iterable<AdaptiveSettingsSliderRow> sliders =
        tester.widgetList<AdaptiveSettingsSliderRow>(
      find.byType(AdaptiveSettingsSliderRow),
    );
    final AdaptiveSettingsSliderRow shadowRow = sliders.singleWhere(
      (AdaptiveSettingsSliderRow row) =>
          row.title == t.video_setting_subtitle_shadow,
    );
    expect(shadowRow.value, 6);
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
    expect(find.text(t.video_setting_mpv_deband), findsOneWidget);
    expect(find.text(t.video_setting_mpv_brightness), findsOneWidget);
    expect(find.text(t.video_setting_mpv_reset), findsOneWidget);
    // master-detail 内嵌：无返回箭头（不走 push 子页）。
    expect(find.byIcon(Icons.arrow_back), findsNothing);
  });

  testWidgets('mpv deband switch drives onMpvConfigChanged live',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    VideoMpvConfig? committed;
    await _pump(tester, _sheet(onMpvConfigChanged: (c) => committed = c));

    await tester.tap(find.text(t.video_settings_cat_mpv));
    await tester.pumpAndSettle();

    // 切「去色带」开关 → 即改即生效回调（无保存按钮）。
    await tester.tap(find.byType(Switch).first);
    await tester.pump();
    expect(committed, isNotNull);
    expect(committed!.deband, isTrue);
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

  // ── TODO-039：倍速改为 MD3 全长滑条（与其它设置滑条同源） ────────────────

  testWidgets('speed row is the shared MD3 slider row (full length)',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pump(tester, _sheet());

    // 倍速行用与其它 MD3 滑条同源的 AdaptiveSettingsSliderRow，范围/步长与旧
    // 分段档位一致（0.5–2.0，0.1 步 = 15 档）。
    final AdaptiveSettingsSliderRow speedRow =
        tester.widget<AdaptiveSettingsSliderRow>(
      find.widgetWithText(AdaptiveSettingsSliderRow, t.video_setting_speed),
    );
    expect(speedRow.min, 0.5);
    expect(speedRow.max, 2.0);
    expect(speedRow.divisions, 15);

    // playback 详情里唯一的 Slider 就是倍速滑条；量它的实际宽度。
    final double speedSliderWidth = tester.getSize(find.byType(Slider)).width;

    // 切到「字幕」分类：字号滑条是 app 现有 MD3 滑条的基准。两者必须同宽
    // （同一全长滑条规范），防止倍速又缩回窄条/分段条。
    await tester.tap(find.text(t.video_settings_cat_subtitle));
    await tester.pumpAndSettle();
    final Finder fontSizeRow = find.widgetWithText(
      AdaptiveSettingsSliderRow,
      t.video_setting_subtitle_font_size,
    );
    final double fontSliderWidth = tester
        .getSize(
          find.descendant(of: fontSizeRow, matching: find.byType(Slider)),
        )
        .width;
    expect(speedSliderWidth, fontSliderWidth,
        reason: '倍速滑条必须与其它 MD3 设置滑条同宽（全长）');
  });

  testWidgets('dragging the speed slider commits a snapped speed',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    double? committed;
    await _pump(tester, _sheet(onSetSpeed: (double v) => committed = v));

    // 从中心拖到最右 → 松手提交 2.0（onChangeEnd 路径，0.1 档吸附后无浮点尾差）。
    await tester.drag(find.byType(Slider), const Offset(500, 0));
    await tester.pumpAndSettle();
    expect(committed, 2.0);
  });

  test('speed row no longer uses the segmented strip (TODO-039 防回潮)', () {
    final String src =
        File('lib/src/media/video/video_quick_settings_sheet.dart')
            .readAsStringSync();
    expect(src, isNot(contains('AdaptiveSettingsSegmentedRow<double>')),
        reason: '倍速不得回退到 16 段 segmented 条');
    expect(src, isNot(contains('_speedPresets')));
    expect(src, contains('_speedDivisions = 15'), reason: '滑条档位须与旧 0.1 步档位等价');
  });
}
