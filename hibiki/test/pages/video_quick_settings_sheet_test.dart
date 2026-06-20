import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/src/media/video/video_asbplayer_config.dart';
import 'package:hibiki/src/media/video/video_control_customization.dart';
import 'package:hibiki/src/media/video/video_immersive_mode.dart';
import 'package:hibiki/src/media/video/video_mpv_config.dart';
import 'package:hibiki/src/media/video/video_shader_tier.dart';
import 'package:hibiki/src/media/video/video_quick_settings_sheet.dart';
import 'package:hibiki/src/media/video/video_side_panel.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/pages/implementations/video_shader_dialog.dart';
import 'package:hibiki/src/media/video/video_subtitle_style.dart';
import 'package:hibiki/utils.dart';

VideoQuickSettingsSheet _sheet({
  void Function(int)? onSetDelay,
  void Function(double)? onPreviewSpeed,
  void Function(double)? onSetSpeed,
  void Function(VideoMpvConfig)? onMpvConfigChanged,
  void Function(VideoShaderTier tier, bool highQuality)? onSelectShaderTier,
  void Function(VideoFitMode mode)? onVideoFitModeChanged,
  void Function(VideoImmersiveMode mode)? onImmersiveModeChanged,
  void Function(VideoControlLayout layout)? onControlLayoutChanged,
  VoidCallback? onEditControlsOnscreen,
  VideoControlLayout? initialControlLayout,
  bool isTouchControls = false,
  VideoFitMode initialVideoFitMode = VideoFitMode.cover,
  double uiScale = 1.0,
  int initialDelayMs = 0,
  VideoSubtitleStyle? initialSubtitleStyle,
  void Function(VideoSubtitleStyle)? onSubtitleStylePreview,
  void Function(VideoSubtitleStyle)? onSubtitleStyleCommit,
}) {
  return VideoQuickSettingsSheet(
    initialDelayMs: initialDelayMs,
    initialSpeed: 1.0,
    initialSubtitleBlur: false,
    initialSubtitleStyle: initialSubtitleStyle ?? VideoSubtitleStyle.defaults,
    onSetDelay: (int v) async => onSetDelay?.call(v),
    onPreviewSpeed: (double v) async => onPreviewSpeed?.call(v),
    onSetSpeed: (double v) async => onSetSpeed?.call(v),
    onToggleSubtitleBlur: () async {},
    onSubtitleStylePreview: (VideoSubtitleStyle style) =>
        onSubtitleStylePreview?.call(style),
    onSubtitleStyleCommit: (VideoSubtitleStyle style) async =>
        onSubtitleStyleCommit?.call(style),
    initialAsbConfig: VideoAsbplayerConfig.defaults,
    onAsbConfigChanged: (_) async {},
    initialShadersEnabled: const <String>[],
    onApplyShaders: (_) async {},
    onSelectShaderTier: (VideoShaderTier tier, bool hq, List<String> _) async {
      onSelectShaderTier?.call(tier, hq);
    },
    initialMpvConfig: VideoMpvConfig.defaults,
    onMpvConfigChanged: (VideoMpvConfig c) async => onMpvConfigChanged?.call(c),
    initialLockWindowAspectRatio: true,
    onLockWindowAspectRatioChanged: (_) async {},
    initialVideoFitMode: initialVideoFitMode,
    onVideoFitModeChanged: (VideoFitMode mode) async =>
        onVideoFitModeChanged?.call(mode),
    initialImmersiveMode: VideoImmersiveMode.lookupOnly,
    onImmersiveModeChanged: (VideoImmersiveMode mode) async =>
        onImmersiveModeChanged?.call(mode),
    initialControlLayout: initialControlLayout,
    onControlLayoutChanged: (VideoControlLayout layout) async =>
        onControlLayoutChanged?.call(layout),
    onEditControlsOnscreen: onEditControlsOnscreen,
    isTouchControls: isTouchControls,
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

Future<void> _pumpScaled(
  WidgetTester tester,
  Widget child, {
  required double scale,
}) {
  return _pump(
    tester,
    HibikiAppUiScale(
      scale: scale,
      child: child,
    ),
  );
}

void _expectNoFlutterErrors(WidgetTester tester) {
  final List<Object> exceptions = <Object>[];
  Object? exception;
  while ((exception = tester.takeException()) != null) {
    exceptions.add(exception!);
  }
  expect(exceptions, isEmpty);
}

/// 宽窗顶栏分类 chip 的稳定 key（与 video_quick_settings_sheet.dart 同步，TODO-640
/// 起 chip 改纯图标无文字，测试 / 焦点驱动只能靠 id key 命中）。
Finder _categoryChip(String id) =>
    find.byKey(ValueKey<String>('video-settings-cat-$id'));

/// 切换到某分类：宽窗点纯图标 chip（按 id key），窄窗点带文字的分类导航行（按 label）。
/// 两端语义统一，调用方不必关心当前是宽 / 窄窗。
Future<void> _tapCategory(
  WidgetTester tester,
  String id,
  String label,
) async {
  final Finder chip = _categoryChip(id);
  final Finder target = chip.evaluate().isNotEmpty ? chip : find.text(label);
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
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
    // TODO-054: 每档（无除外）标注代表性显卡示例（N卡 + A卡），让用户自识别该选哪档。
    // NVIDIA 示例（沿用 TODO-041 既有锚点，保证向后不破坏）。
    expect(t.video_shader_tier_low_hint, contains('GTX'));
    expect(t.video_shader_tier_medium_hint, contains('GTX 1660'));
    expect(t.video_shader_tier_high_hint, contains('RTX 4060'));
    expect(t.video_shader_tier_ultra_hint, contains('RTX 5090'));
    // AMD（A卡）示例：每档都给出对应代表型号，用户两套显卡都能对号入座。
    expect(t.video_shader_tier_low_hint, contains('RX 560'));
    expect(t.video_shader_tier_medium_hint, contains('RX 6600'));
    expect(t.video_shader_tier_high_hint, contains('RX 7700 XT'));
    expect(t.video_shader_tier_ultra_hint, contains('RX 7900 XTX'));
    // TODO-125：进阶仅保留手动导入/粘贴链接/从 mpv 导入（逃生口），删经典推荐入口。
    expect(t.video_shader_section_advanced, contains('Advanced'));
    expect(t.video_shader_import, contains('Import shader'));
    expect(t.video_shader_download_url, contains('link'));
    expect(t.video_shader_import_from_mpv, contains('mpv'));
    expect(t.video_shader_first_use_body, contains('Anime4K'));
    expect(t.video_shader_first_use_download, contains('Download'));
  });

  testWidgets(
      'shader settings shows 5-tier selector on top and removes standalone Anime4K download entry',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pump(tester, _sheet());

    await _tapCategory(tester, 'shaders', t.video_settings_cat_shaders);

    // 顶部是五档单选器（无/低/中/高/极高）。
    expect(find.text(t.video_shader_quality_tier), findsOneWidget);
    expect(find.byType(SegmentedButton<VideoShaderTier>), findsOneWidget);
    // 单选器每档都有一个 ButtonSegment（五段互斥单选）。
    final SegmentedButton<VideoShaderTier> seg =
        tester.widget<SegmentedButton<VideoShaderTier>>(
      find.byType(SegmentedButton<VideoShaderTier>),
    );
    expect(seg.segments.map((s) => s.value).toSet(), <VideoShaderTier>{
      VideoShaderTier.off,
      VideoShaderTier.low,
      VideoShaderTier.medium,
      VideoShaderTier.high,
      VideoShaderTier.ultra,
    });
    // 档名在选择器分段 + 下方对照表各出现一次（findsWidgets，对照表故意复列档名）。
    expect(find.text(t.video_shader_tier_off), findsWidgets);
    expect(find.text(t.video_shader_tier_low), findsWidgets);
    expect(find.text(t.video_shader_tier_medium), findsWidgets);
    expect(find.text(t.video_shader_tier_high), findsWidgets);
    expect(find.text(t.video_shader_tier_ultra), findsWidgets);

    // 诉求 2：不再单列「下载 Anime4K 推荐着色器」入口。
    expect(find.text(t.video_shader_download_anime4k), findsNothing);

    // TODO-125：经典推荐着色器（RAVU/NNEDI3）入口整批删除（i18n key 一并删，
    // 故不再引用其旧 key，改由进阶 section 仅含手动逃生口来证明已删除）。

    // 进阶 section 仅保留手动逃生口（导入文件 / 粘贴链接 / 从 mpv 导入），给懂的人用。
    expect(find.text(t.video_shader_section_advanced), findsOneWidget);
    expect(find.text(t.video_shader_import), findsOneWidget);
    expect(find.text(t.video_shader_download_url), findsOneWidget);
    expect(find.text(t.video_shader_import_from_mpv), findsOneWidget);

    // TODO-125 诉求 2：五档显卡要求常驻对照表——选档前就能比较每档的画质取舍与
    // GPU 门槛（型号示例），不用点选某档才看到要求。五档说明全在选择器下方常驻渲染。
    expect(find.byType(VideoShaderTierComparison), findsOneWidget);
    expect(find.text(t.video_shader_tier_off_hint), findsOneWidget);
    expect(find.text(t.video_shader_tier_low_hint), findsOneWidget);
    expect(find.text(t.video_shader_tier_medium_hint), findsOneWidget);
    expect(find.text(t.video_shader_tier_high_hint), findsOneWidget);
    expect(find.text(t.video_shader_tier_ultra_hint), findsOneWidget);
    // 对照表常驻在档位选择器下方、进阶项上方。
    final double comparisonY =
        tester.getTopLeft(find.byType(VideoShaderTierComparison)).dy;
    final double tierSelectorY =
        tester.getTopLeft(find.text(t.video_shader_quality_tier)).dy;
    final double advancedSectionY =
        tester.getTopLeft(find.text(t.video_shader_section_advanced)).dy;
    expect(tierSelectorY, lessThan(comparisonY));
    expect(comparisonY, lessThan(advancedSectionY));

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

    await _tapCategory(tester, 'shaders', t.video_settings_cat_shaders);

    // 初始默认（highQuality=true + 空启用集）已高亮「低」档；先点「无」（值变化触发回调）：
    // 「无」档零下载——关闭内置缩放 + 空启用集，直接经回调切档、不弹下载框。
    // 档名在选择器分段 + 下方对照表都出现，故须定位到选择器内的分段（对照表只展示不可点）。
    final Finder selector = find.byType(SegmentedButton<VideoShaderTier>);
    await tester.tap(find.descendant(
        of: selector, matching: find.text(t.video_shader_tier_off)));
    await tester.pumpAndSettle();
    expect(selectedTier, VideoShaderTier.off);
    expect(selectedHq, isFalse);

    // 再点「低」（零下载，仅 mpv 内置 scale）：又一次值变化，经回调切回低档。
    await tester.tap(find.descendant(
        of: selector, matching: find.text(t.video_shader_tier_low)));
    await tester.pumpAndSettle();
    expect(selectedTier, VideoShaderTier.low);
    expect(selectedHq, isTrue);
  });

  testWidgets(
      'video settings stacks top category chips over the detail on wide windows '
      '(TODO-556)', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pump(tester, _sheet());

    // TODO-640：顶栏 chip 改纯图标（无文字），六个分类按 id key 命中；默认选中
    // playback → 下方详情顶部用大标题标出当前分类 + 显示音画延迟 + 倍速。
    for (final String id in <String>[
      'playback',
      'shaders',
      'mpv',
      'subtitle',
      'danmaku',
      'controls',
    ]) {
      expect(_categoryChip(id), findsOneWidget, reason: '$id 必须是顶栏纯图标分类 chip');
    }
    // 选中分类（playback）的标题在详情区顶部呈现（纯图标 chip 无文字，靠它认当前项）。
    expect(find.text(t.video_settings_cat_playback), findsOneWidget);
    expect(find.text(t.video_setting_av_delay), findsOneWidget);
    expect(find.text(t.video_setting_speed), findsOneWidget);
    // 上下分栏无 push：无返回箭头。
    expect(find.byIcon(Icons.arrow_back), findsNothing);

    // TODO-556：大分类从左栏 master-detail 改成顶部横滑 chip 行（入口置顶）。
    // 不再有左右 master-detail（无 MaterialSupportingPaneLayout / 左栏 HibikiListItem）。
    expect(find.byType(MaterialSupportingPaneLayout), findsNothing);
    expect(find.byType(HibikiListItem), findsNothing);
    // 每个分类一个 HibikiSelectableChip（六分类 → 至少 6 个）。
    expect(find.byType(HibikiSelectableChip), findsAtLeastNWidgets(6));

    // 分类 chip 在上、详情在下（顶栏）：分类条的 dy 必须小于详情的 dy。
    final double categoryY = tester.getTopLeft(_categoryChip('subtitle')).dy;
    final double detailY =
        tester.getTopLeft(find.text(t.video_setting_speed)).dy;
    expect(categoryY, lessThan(detailY),
        reason: 'category chip bar must sit above the detail pane (top bar)');

    final Iterable<SingleChildScrollView> detailScrolls =
        tester.widgetList<SingleChildScrollView>(
      find.byType(SingleChildScrollView),
    );
    final SingleChildScrollView detailScroll = detailScrolls.lastWhere(
      (SingleChildScrollView s) {
        final EdgeInsets? p = s.padding as EdgeInsets?;
        return s.scrollDirection == Axis.vertical && p != null && p.left == 24;
      },
    );
    final EdgeInsets primaryPadding = detailScroll.padding! as EdgeInsets;
    expect(primaryPadding.left, 24);
    expect(primaryPadding.right, 24);

    // 选「字幕」→ 下方详情切到字幕详情，仍无返回箭头。
    await _tapCategory(tester, 'subtitle', t.video_settings_cat_subtitle);
    expect(find.text(t.video_setting_subtitle_blur), findsOneWidget);
    expect(find.text(t.video_setting_subtitle_font_size), findsOneWidget);
    expect(find.text(t.video_setting_subtitle_font_weight), findsOneWidget);
    expect(find.text(t.video_setting_subtitle_shadow), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back), findsNothing);
  });

  testWidgets(
      'wide category bar is icon-only with tooltips (no inline label) even at '
      'UI scale 2.0 (TODO-640)', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1320, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpScaled(
      tester,
      _sheet(
        uiScale: 2.0,
        initialVideoFitMode: VideoFitMode.contain,
      ),
      scale: 2.0,
    );

    // TODO-640：顶栏 chip 改纯图标——长英文标签（含 UI scale 2.0）不再占顶栏空间，
    // 根除「图标 + 文字」挤不下 / 显示不全。每个 chip 内无内联文字 label，只有图标。
    expect(find.byType(MaterialSupportingPaneLayout), findsNothing);
    for (final ({String id, IconData icon, String label}) cat
        in <({String id, IconData icon, String label})>[
      (
        id: 'playback',
        icon: Icons.play_circle_outline,
        label: t.video_settings_cat_playback
      ),
      (
        id: 'shaders',
        icon: Icons.auto_fix_high_outlined,
        label: t.video_settings_cat_shaders
      ),
      (id: 'mpv', icon: Icons.tune, label: t.video_settings_cat_mpv),
      (
        id: 'subtitle',
        icon: Icons.subtitles_outlined,
        label: t.video_settings_cat_subtitle
      ),
      (
        id: 'danmaku',
        icon: Icons.forum_outlined,
        label: t.video_settings_cat_danmaku
      ),
      (
        id: 'controls',
        icon: Icons.dashboard_customize_outlined,
        label: t.video_settings_cat_controls
      ),
    ]) {
      final Finder chip = _categoryChip(cat.id);
      expect(chip, findsOneWidget, reason: '${cat.id} 必须是纯图标分类 chip');
      // chip 内有该分类图标。
      expect(find.descendant(of: chip, matching: find.byIcon(cat.icon)),
          findsOneWidget,
          reason: '${cat.id} chip 须渲染分类图标');
      // chip 内无内联文字 label（文字说明改走 tooltip）——
      // 唯一例外是当前选中项的标题在详情区，不在 chip 内部。
      expect(find.descendant(of: chip, matching: find.text(cat.label)),
          findsNothing,
          reason: '${cat.id} chip 不应再内联渲染文字标签（TODO-640 仅图标）');
      // 文字说明经 tooltip 提供（hover / 长按）。
      expect(find.descendant(of: chip, matching: find.byType(Tooltip)),
          findsOneWidget,
          reason: '${cat.id} chip 须用 tooltip 给文字说明');
      final Tooltip tip = tester.widget<Tooltip>(
          find.descendant(of: chip, matching: find.byType(Tooltip)));
      expect(tip.message, cat.label,
          reason: '${cat.id} chip 的 tooltip 文案应是分类标签');
    }
    _expectNoFlutterErrors(tester);
  });

  for (final ({double width, double scale}) sizeCase
      in <({double width, double scale})>[
    (width: 320, scale: 1.5),
    (width: 320, scale: 2.0),
    (width: 360, scale: 1.5),
    (width: 360, scale: 2.0),
    (width: 420, scale: 1.5),
    (width: 420, scale: 2.0),
    (width: 560, scale: 1.5),
    (width: 560, scale: 2.0),
    (width: 720, scale: 1.5),
    (width: 720, scale: 2.0),
  ]) {
    testWidgets(
        'picture scaling long value is readable at '
        '${sizeCase.width.round()}px scale ${sizeCase.scale}', (tester) async {
      await tester.binding.setSurfaceSize(Size(sizeCase.width, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _pumpScaled(
        tester,
        _sheet(
          uiScale: sizeCase.scale,
          initialVideoFitMode: VideoFitMode.contain,
        ),
        scale: sizeCase.scale,
      );

      // 分类入口可达：窄窗是带文字的导航行，宽窗是纯图标 chip（按 id key）。
      expect(
        find.text(t.video_settings_cat_subtitle).evaluate().isNotEmpty ||
            _categoryChip('subtitle').evaluate().isNotEmpty,
        isTrue,
        reason: '字幕分类入口须可达（窄窗导航行文字 / 宽窗图标 chip）',
      );

      if (find.text(t.video_setting_picture_fit).evaluate().isEmpty) {
        await _tapCategory(tester, 'playback', t.video_settings_cat_playback);
      }

      expect(find.text(t.video_setting_picture_fit), findsWidgets);
      expect(
        find.text(t.video_setting_picture_fit_contain),
        findsWidgets,
        reason: 'selected value must not be truncated to an ellipsis',
      );
      _expectNoFlutterErrors(tester);
    });
  }

  testWidgets('subtitle default weight and shadow preview use app UI scale',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pump(tester, _sheet(uiScale: 2.0));

    await _tapCategory(tester, 'subtitle', t.video_settings_cat_subtitle);

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
    // 默认阴影粗细 TODO-051 加大到 5px；UI scale 2.0 下预览 = 5 * 2 = 10。
    expect(shadowRow.value, 10);
  });

  testWidgets(
      'subtitle no-background shortcut previews commits and updates slider',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final List<VideoSubtitleStyle> previews = <VideoSubtitleStyle>[];
    final List<VideoSubtitleStyle> commits = <VideoSubtitleStyle>[];
    await _pump(
      tester,
      _sheet(
        initialSubtitleStyle: VideoSubtitleStyle.defaults.copyWith(
          backgroundOpacity: 0.75,
        ),
        onSubtitleStylePreview: previews.add,
        onSubtitleStyleCommit: commits.add,
      ),
    );

    await _tapCategory(tester, 'subtitle', t.video_settings_cat_subtitle);

    final Finder backgroundOpacityRow = find.widgetWithText(
      AdaptiveSettingsSliderRow,
      t.video_setting_subtitle_bg_opacity,
    );
    expect(
      tester.widget<AdaptiveSettingsSliderRow>(backgroundOpacityRow).value,
      0.75,
    );

    final Finder noBackgroundRow = find.widgetWithText(
      AdaptiveSettingsRow,
      t.video_setting_subtitle_no_background,
    );
    await tester.ensureVisible(noBackgroundRow);
    await tester.pumpAndSettle();
    await tester.tap(noBackgroundRow);
    await tester.pump();

    expect(previews.map((s) => s.backgroundOpacity), <double>[0]);
    expect(commits.map((s) => s.backgroundOpacity), <double>[0]);
    expect(
      tester.widget<AdaptiveSettingsSliderRow>(backgroundOpacityRow).value,
      0,
      reason: '快捷项必须同步本地 _style，避免背景不透明度滑条显示滞后',
    );
  });

  testWidgets(
      'wide video settings keeps the top category bar fixed while the detail '
      'scrolls (TODO-556)', (tester) async {
    // 高度取 500（>= kHibikiSettingsWideMinHeight=440 → 进宽窗），下方详情行多仍可滚。
    await tester.binding.setSurfaceSize(const Size(1000, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pump(tester, _sheet());

    // 字幕详情行多（开关 + 三滑条 + 重置）→ 必然超过详情高、可独立滚动。
    await _tapCategory(tester, 'subtitle', t.video_settings_cat_subtitle);

    // 顶部分类条里的「播放」chip 是固定锚点（chip 行钉在顶部、随详情滚动不动）。
    // TODO-640：纯图标 chip 无文字，按 id key 命中。
    final Finder categoryAnchor = _categoryChip('playback');
    expect(categoryAnchor, findsOneWidget);
    final Offset before = tester.getTopLeft(categoryAnchor);

    // 在详情区域（垂直方向中下部）向上拖：只滚下方详情，顶部分类条必须纹丝不动。
    await tester.dragFrom(const Offset(500, 350), const Offset(0, -160));
    await tester.pump();

    final Offset after = tester.getTopLeft(categoryAnchor);
    expect(after, before, reason: '顶部分类条必须固定，不能跟随下方详情滚动');
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
    await _tapCategory(tester, 'playback', t.video_settings_cat_playback);
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
    await _tapCategory(tester, 'playback', t.video_settings_cat_playback);
    expect(find.text(t.video_setting_av_delay), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(find.text(t.video_setting_av_delay), findsNothing);
  });

  testWidgets('scaled settings side panel stays inside a narrow viewport',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(720, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pump(
      tester,
      HibikiAppUiScale(
        scale: 2.0,
        child: VideoTranslucentSidePanel(
          title: t.video_settings_title,
          width: 560,
          child: _sheet(uiScale: 2.0),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text(t.video_settings_cat_playback), findsOneWidget);

    await _tapCategory(tester, 'playback', t.video_settings_cat_playback);

    expect(tester.takeException(), isNull);
    expect(find.text(t.video_setting_av_delay), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
  });

  // ── TODO-561：mpv 高级「额外 mpv 选项」标题文本显示不全 ─────────────────
  // 原来标题挂在 InputDecoration.labelText（Material 浮动 label 恒单行 + ellipsis），
  // 在窄右 pane / 高 UI scale 下被截断。修复后标题是 TextField 上方独立、可换行、
  // 完整显示的 Text；输入框不再走单行浮动 label。
  Future<void> openMpvAdvanced(WidgetTester tester) async {
    await _tapCategory(tester, 'mpv', t.video_settings_cat_mpv);
    // mpv 详情右 pane 是 SingleChildScrollView，会一次性 build 全部分组（含底部
    // 「高级」段），离屏 widget 仍完成 layout，故无需滚动即可命中并测量标题。
  }

  testWidgets(
      'mpv extra-options title is an independent text, not a single-line '
      'floating label', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pump(tester, _sheet());
    await openMpvAdvanced(tester);

    final Finder title = find.text(t.video_setting_mpv_raw);
    expect(title, findsOneWidget, reason: '「额外 mpv 选项」标题必须可见');

    // 标题不能是某个 InputDecorator 内部（labelText 浮动 label）的后代——
    // 那条路径恒单行 + ellipsis，是显示不全的根因。
    expect(
      find.descendant(of: find.byType(InputDecorator), matching: title),
      findsNothing,
      reason: '标题不应作为 InputDecoration.labelText 渲染（浮动 label 单行会截断），'
          '应是输入框上方的独立完整 Text',
    );

    // 标题整段完整渲染，不被省略号截断。
    final RenderParagraph paragraph =
        tester.renderObject<RenderParagraph>(title);
    expect(paragraph.didExceedMaxLines, isFalse,
        reason: '「额外 mpv 选项」标题必须完整显示，不能被截断成省略号');
    _expectNoFlutterErrors(tester);
  });

  for (final ({double width, double scale}) sizeCase
      in <({double width, double scale})>[
    (width: 320, scale: 1.5),
    (width: 360, scale: 2.0),
    (width: 420, scale: 2.0),
  ]) {
    testWidgets(
        'mpv extra-options title is fully readable at '
        '${sizeCase.width.round()}px scale ${sizeCase.scale}', (tester) async {
      await tester.binding.setSurfaceSize(Size(sizeCase.width, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _pumpScaled(
        tester,
        _sheet(uiScale: sizeCase.scale),
        scale: sizeCase.scale,
      );
      await openMpvAdvanced(tester);

      final Finder title = find.text(t.video_setting_mpv_raw);
      expect(title, findsOneWidget, reason: '窄 pane / 高缩放下「额外 mpv 选项」标题仍须可见');
      final RenderParagraph paragraph =
          tester.renderObject<RenderParagraph>(title);
      expect(paragraph.didExceedMaxLines, isFalse,
          reason: '窄 pane / 高缩放下标题不能被截断（TODO-561）');
      _expectNoFlutterErrors(tester);
    });
  }

  test('源码守卫：mpv 高级标题不挂 labelText 浮动单行 label（TODO-561 防回潮）', () {
    final String src =
        File('lib/src/media/video/video_quick_settings_sheet.dart')
            .readAsStringSync();
    expect(src, isNot(contains('labelText: t.video_setting_mpv_raw')),
        reason: '「额外 mpv 选项」标题不能再走 InputDecoration.labelText（浮动 label 恒单行 '
            '+ ellipsis，窄 pane 截断）；须是输入框上方独立可换行 Text');
  });

  testWidgets('mpv category renders the config inline (no sub-dialog)',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pump(tester, _sheet());

    await _tapCategory(tester, 'mpv', t.video_settings_cat_mpv);

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

    await _tapCategory(tester, 'mpv', t.video_settings_cat_mpv);

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

  // ── TODO-060：字幕调轴（正名 + 滑条 + 数值输入） ───────────────────────────

  test('字幕调轴行用「字幕调轴」名（让用户找得到），不再叫旧的音画延迟', () {
    expect(t.video_setting_av_delay, 'Subtitle sync');
    // hint 明确说明可拖滑条 / 按 ± / 直接输入。
    expect(t.video_setting_av_delay_hint.toLowerCase(), contains('slider'));
    expect(t.video_setting_subtitle_sync_input, 'Offset (ms)');
  });

  testWidgets('字幕调轴提供可拉滑条 + 数值输入框（playback 详情）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pump(tester, _sheet(initialDelayMs: 1200));

    // 标题正名为「字幕调轴」。
    expect(find.text(t.video_setting_av_delay), findsOneWidget);

    // playback 详情里有一条可拉滑条（字幕调轴），把手按当前值定位。
    final Finder delayRow = find.widgetWithText(
      AdaptiveSettingsRow,
      t.video_setting_av_delay,
    );
    final Slider slider = tester.widget<Slider>(
      find.descendant(of: delayRow, matching: find.byType(Slider)),
    );
    expect(slider.value, 1200);
    expect(slider.min, -10000);
    expect(slider.max, 10000);

    // 还有一个数值输入框（可输入正负 ms），初值回显当前延迟。
    final Finder field = find.descendant(
      of: delayRow,
      matching: find.byType(TextField),
    );
    expect(field, findsOneWidget);
    final TextField tf = tester.widget<TextField>(field);
    expect(tf.controller!.text, '1200');
  });

  testWidgets('字幕调轴：在输入框键入正负值提交绝对偏移', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    int? delay;
    await _pump(tester, _sheet(onSetDelay: (int v) => delay = v));

    final Finder delayRow = find.widgetWithText(
      AdaptiveSettingsRow,
      t.video_setting_av_delay,
    );
    final Finder field = find.descendant(
      of: delayRow,
      matching: find.byType(TextField),
    );
    await tester.enterText(field, '-350');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(delay, -350, reason: '负值代表字幕提前，绝对提交而非叠加');
  });

  testWidgets('字幕调轴：拖滑条提交吸附到 50ms 档的偏移', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    int? delay;
    await _pump(tester, _sheet(onSetDelay: (int v) => delay = v));

    final Finder delayRow = find.widgetWithText(
      AdaptiveSettingsRow,
      t.video_setting_av_delay,
    );
    final Finder slider =
        find.descendant(of: delayRow, matching: find.byType(Slider));
    // 从中心向右拖到端点 → 提交一个正的、吸附到 50ms 档的偏移。
    await tester.drag(slider, const Offset(500, 0));
    await tester.pumpAndSettle();
    expect(delay, isNotNull);
    expect(delay! > 0, isTrue);
    expect(delay! % 50, 0, reason: '滑条按 50ms 一档');
  });

  testWidgets('subtitle sync controls wrap at narrow width and large UI scale',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    int? delay;
    await _pumpScaled(
      tester,
      _sheet(
        uiScale: 2.0,
        onSetDelay: (int v) => delay = v,
      ),
      scale: 2.0,
    );
    await _tapCategory(tester, 'playback', t.video_settings_cat_playback);

    final Finder delayRow = find.widgetWithText(
      AdaptiveSettingsRow,
      t.video_setting_av_delay,
    );
    expect(delayRow, findsOneWidget);
    expect(
      find.descendant(of: delayRow, matching: find.byType(Slider)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: delayRow, matching: find.byType(TextField)),
      findsOneWidget,
    );

    final Finder plusButton = find.descendant(
      of: delayRow,
      matching: find.byIcon(Icons.chevron_right),
    );
    await tester.ensureVisible(plusButton);
    await tester.pumpAndSettle();
    await tester.tap(plusButton);
    await tester.pump();
    expect(delay, 50);
    _expectNoFlutterErrors(tester);
  });

  // ── TODO-060：删 mpv「音频延迟」入口（与字幕调轴对用户重复混淆） ─────────

  testWidgets('mpv 音频区不再有「音频延迟」滑条入口', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pump(tester, _sheet());

    await _tapCategory(tester, 'mpv', t.video_settings_cat_mpv);

    // 音频分组仍在（变速保持音高 / 声道 / 归一化），但不再有音频延迟行。
    expect(find.text(t.video_setting_mpv_group_audio), findsOneWidget);
    expect(find.text(t.video_setting_mpv_pitch), findsOneWidget);
  });

  test('源码守卫：mpv 详情不再调音频延迟、字幕调轴提供输入框（TODO-060 防回潮）', () {
    final String src =
        File('lib/src/media/video/video_quick_settings_sheet.dart')
            .readAsStringSync();
    // mpv 不再有音频延迟入口。
    expect(src, isNot(contains('video_setting_mpv_audio_delay')),
        reason: 'mpv「音频延迟」入口必须删除（与字幕调轴对用户重复混淆）');
    expect(src, isNot(contains('copyWith(audioDelayMs:')),
        reason: 'mpv 配置不应再有 audioDelayMs 的 UI 提交路径');
    // 字幕调轴提供滑条 + 数值输入框。
    expect(src, contains('video_setting_subtitle_sync_input'),
        reason: '字幕调轴须有数值输入框');
    expect(src, contains('_commitDelay'), reason: '滑条/按钮/输入框须经统一权威提交');
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

    // playback 详情现有两条滑条（字幕调轴 + 倍速）；定位倍速行内的滑条量宽。
    final Finder speedSlider = find.descendant(
      of: find.widgetWithText(AdaptiveSettingsSliderRow, t.video_setting_speed),
      matching: find.byType(Slider),
    );
    final double speedSliderWidth = tester.getSize(speedSlider).width;

    // 切到「字幕」分类：字号滑条是 app 现有 MD3 滑条的基准。两者必须同宽
    // （同一全长滑条规范），防止倍速又缩回窄条/分段条。
    await _tapCategory(tester, 'subtitle', t.video_settings_cat_subtitle);
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

    // 从中心拖倍速滑条到最右 → 松手提交 2.0（onChangeEnd 路径，0.1 档吸附后无浮点尾差）。
    // playback 现有两条滑条（字幕调轴 + 倍速），按倍速行定位避免歧义。
    final Finder speedSlider = find.descendant(
      of: find.widgetWithText(AdaptiveSettingsSliderRow, t.video_setting_speed),
      matching: find.byType(Slider),
    );
    // TODO-427-③：上下分栏后详情整宽且更长，倍速行可能在详情滚动区下方；先滚入视口
    // 再拖（模拟真实用户滚到该行）。
    await tester.ensureVisible(speedSlider);
    await tester.pumpAndSettle();
    await tester.drag(speedSlider, const Offset(500, 0));
    await tester.pumpAndSettle();
    expect(committed, 2.0);
  });

  testWidgets('dragging the speed slider previews before final commit',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final List<double> previewed = <double>[];
    double? committed;
    await _pump(
      tester,
      _sheet(
        onPreviewSpeed: previewed.add,
        onSetSpeed: (double v) => committed = v,
      ),
    );

    final Finder speedSlider = find.descendant(
      of: find.widgetWithText(AdaptiveSettingsSliderRow, t.video_setting_speed),
      matching: find.byType(Slider),
    );
    await tester.ensureVisible(speedSlider);
    await tester.pumpAndSettle();

    final Offset start = tester.getCenter(speedSlider);
    final TestGesture gesture = await tester.startGesture(start);
    await gesture.moveBy(const Offset(500, 0));
    await tester.pump();

    expect(previewed, isNotEmpty,
        reason: 'drag ticks must preview real playback speed before release');
    expect(previewed.last, 2.0);
    expect(committed, isNull,
        reason: 'drag preview must not persist before onChangeEnd');

    await gesture.up();
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

  // ── TODO-152 子B：画面缩放/比例设置（窗口 + 全屏 Video fit 同源偏好） ──────

  testWidgets('playback detail shows the picture-fit picker (TODO-152 子B)',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pump(tester, _sheet());

    // 默认进 playback 详情：画面缩放行常驻（三选：占满/适应/拉伸）。
    // picker 行（与 hwdec 同款）会为测宽离屏复刻一份标题文本 → findsWidgets。
    expect(find.text(t.video_setting_picture_fit), findsWidgets);
    final AdaptiveSettingsPickerRow<VideoFitMode> row =
        tester.widget<AdaptiveSettingsPickerRow<VideoFitMode>>(
      find.byType(AdaptiveSettingsPickerRow<VideoFitMode>),
    );
    expect(row.selected, VideoFitMode.cover);
    expect(row.options.map((o) => o.value).toList(), <VideoFitMode>[
      VideoFitMode.cover,
      VideoFitMode.contain,
      VideoFitMode.fill,
    ]);
  });

  testWidgets('picking a picture-fit mode drives onVideoFitModeChanged',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    VideoFitMode? picked;
    await _pump(
      tester,
      _sheet(onVideoFitModeChanged: (VideoFitMode mode) => picked = mode),
    );

    // 选「适应（加黑边）」= contain → 即时落回调（无保存按钮）。
    final AdaptiveSettingsPickerRow<VideoFitMode> row =
        tester.widget<AdaptiveSettingsPickerRow<VideoFitMode>>(
      find.byType(AdaptiveSettingsPickerRow<VideoFitMode>),
    );
    row.onChanged(VideoFitMode.contain);
    await tester.pump();
    expect(picked, VideoFitMode.contain);
  });

  // ── TODO-209：沉浸模式 4 个长标签改下拉单选（不再用会裁段的 4 段 SegmentedButton） ──

  testWidgets(
      'immersive mode is a dropdown picker offering all four modes (TODO-209)',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pump(tester, _sheet());

    // 默认进 playback 详情：沉浸模式行常驻，且是下拉单选 picker（与画面缩放同款），
    // 不再是等宽不换行的 4 段 SegmentedButton（窄面板会裁掉尾段，TODO-209）。
    expect(find.text(t.video_setting_immersive_mode), findsWidgets);
    final AdaptiveSettingsPickerRow<VideoImmersiveMode> row =
        tester.widget<AdaptiveSettingsPickerRow<VideoImmersiveMode>>(
      find.byType(AdaptiveSettingsPickerRow<VideoImmersiveMode>),
    );
    // 默认选中「仅查词」（与 _sheet 初值一致 = VideoImmersiveMode.fallback）。
    expect(row.selected, VideoImmersiveMode.lookupOnly);
    // 4 个模式按 enum 顺序全量呈现，一个不少（窄面板曾裁掉尾段的根因已消除）。
    expect(row.options.map((o) => o.value).toList(), VideoImmersiveMode.values);
    // 沉浸模式行不再走 segmented 条（防回潮）。
    expect(
      find.byType(AdaptiveSettingsSegmentedRow<VideoImmersiveMode>),
      findsNothing,
      reason: '沉浸模式不得用会裁长标签的 4 段 SegmentedButton',
    );
  });

  testWidgets('picking an immersive mode drives onImmersiveModeChanged',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    VideoImmersiveMode? picked;
    await _pump(
      tester,
      _sheet(
          onImmersiveModeChanged: (VideoImmersiveMode mode) => picked = mode),
    );

    // 选「全部功能」= full → 即时落回调（无保存按钮）。
    final AdaptiveSettingsPickerRow<VideoImmersiveMode> row =
        tester.widget<AdaptiveSettingsPickerRow<VideoImmersiveMode>>(
      find.byType(AdaptiveSettingsPickerRow<VideoImmersiveMode>),
    );
    row.onChanged(VideoImmersiveMode.full);
    await tester.pump();
    expect(picked, VideoImmersiveMode.full);
  });

  // ── TODO-423：右详情（子设置）pane 不得再叠加不透明背景（用户嫌丑，已删除）──
  // 父/子层级区分改靠左侧分隔线 + 左侧分类选中高亮，右 pane 不包 ColoredBox 叠加层。

  testWidgets(
      'wide video settings detail pane has no opaque tint overlay '
      '(TODO-423)', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pump(tester, _sheet());

    // 右 primary pane 的 KeyedSubtree 不再被任何 0<alpha<1 的半透明 ColoredBox 包裹
    // （TODO-342 的叠加层已移除）——遍历其全部 ColoredBox 祖先，断言无半透明叠加色。
    final Finder primaryColoredBoxes = find.ancestor(
      of: find.byType(KeyedSubtree).last,
      matching: find.byType(ColoredBox),
    );
    final Iterable<ColoredBox> boxes =
        tester.widgetList<ColoredBox>(primaryColoredBoxes);
    for (final ColoredBox box in boxes) {
      final double alpha = box.color.a;
      // 不得存在半透明叠加层（既不是完全透明也不是完全不透明的那种 tint）。
      expect(alpha == 0.0 || alpha == 1.0, isTrue,
          reason: '右详情 pane 不应被半透明叠加色 ColoredBox 包裹（TODO-423）');
    }
  });

  // ── TODO-344：四边 padding 按 MD3 spacing 放宽，消除「贴死」 ──────────────

  testWidgets(
      'wide video settings uses roomy MD3 padding on all four edges '
      '(TODO-344 / TODO-556)', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pump(tester, _sheet());

    // 顶部分类 chip 条外层 Padding：水平 inset = page+gap=24，顶部 card=16（不再贴死），
    // 底部留 gap/2=4 与下方分隔线呼吸。chip 条本身是横向 scroll（无 padding 属性），
    // 故 padding 落在它外层那个 Padding widget 上，按值精确定位。
    final Finder firstCategoryChip = find.byType(HibikiSelectableChip).first;
    final Iterable<Padding> categoryPads = tester.widgetList<Padding>(
      find.ancestor(
        of: firstCategoryChip,
        matching: find.byType(Padding),
      ),
    );
    final Padding categoryOuterPad = categoryPads.firstWhere((Padding p) {
      final EdgeInsets? e = p.padding as EdgeInsets?;
      return e != null && e.left == 24 && e.top == 16 && e.bottom == 4;
    });
    final EdgeInsets categoryPadding = categoryOuterPad.padding as EdgeInsets;
    expect(categoryPadding.left, 24);
    expect(categoryPadding.right, 24);
    expect(categoryPadding.top, 16);
    expect(categoryPadding.bottom, 4);

    // 下方详情（纵向 SingleChildScrollView，KeyedSubtree 内）：水平 inset 同 24、独占整宽。
    // picker 离屏 dropdown 测量树里也有无 padding 的 scroll，按「padding.left==24 的纵向
    // scroll」精确定位详情那一个。
    final SingleChildScrollView detailScroll = tester
        .widgetList<SingleChildScrollView>(
      find.byType(SingleChildScrollView),
    )
        .lastWhere((SingleChildScrollView s) {
      final EdgeInsets? p = s.padding as EdgeInsets?;
      return s.scrollDirection == Axis.vertical && p != null && p.left == 24;
    });
    final EdgeInsets primaryPadding = detailScroll.padding! as EdgeInsets;
    expect(primaryPadding.left, 24);
    expect(primaryPadding.right, 24);
    expect(primaryPadding.top, 16);
  });

  testWidgets('narrow video settings uses roomy MD3 padding (TODO-344)',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pump(tester, _sheet());

    // 窄窗主页同样用放宽后的 padding（顶部 >= 16，不再贴死）。窄窗 body 的最外层
    // SingleChildScrollView 承载本功能的 padding（内部组件可能另有自己的 scroll，故取 first）。
    final SingleChildScrollView scroll = tester.widget<SingleChildScrollView>(
        find.byType(SingleChildScrollView).first);
    final EdgeInsets padding = scroll.padding! as EdgeInsets;
    expect(padding.left, 24);
    expect(padding.right, 24);
    expect(padding.top, 16);
  });

  // ── TODO-470：设置页内控制按钮编辑器使用播放器方位预览舞台 ─
  group('control button editor stage (TODO-470)', () {
    // 进入控制分类详情（宽窗上下分栏顶部 chip 行）。「控制」是末位分类，在窄宽窗下
    // 横向 chip 行里可能排到视口外（TODO-427-③），先横滑入视口再点（模拟真实用户横滑）。
    Future<void> openControls(WidgetTester tester) async {
      // TODO-640：纯图标分类 chip 无文字，经 id key 命中（_tapCategory 自动处理
      // 宽窗 icon chip / 窄窗 push 导航行两端）。
      await _tapCategory(tester, 'controls', t.video_settings_cat_controls);
    }

    Finder slotFinder(VideoControlSlot slot) => find.byKey(
        ValueKey<String>('video-control-edit-slot-${slot.storageValue}'));

    Finder chipFinder(
      VideoControlItem item,
      VideoControlSlot slot,
      int sourceIndex,
    ) =>
        find.byKey(ValueKey<String>(
            'video-control-chip-${item.storageValue}-${slot.storageValue}-$sourceIndex'));

    Finder dragChipFinder(
      VideoControlItem item,
      VideoControlSlot slot,
      int sourceIndex,
    ) =>
        find.byKey(ValueKey<String>(
            'video-control-drag-chip-${item.storageValue}-${slot.storageValue}-$sourceIndex'));

    Future<void> dragChipTo(
      WidgetTester tester,
      Finder chip,
      Finder target,
    ) async {
      await tester.ensureVisible(chip);
      await tester.pumpAndSettle();
      final Offset start = tester.getCenter(chip);
      final Offset end = tester.getCenter(target);
      final TestGesture gesture = await tester.startGesture(start);
      for (int step = 1; step <= 8; step++) {
        await gesture.moveTo(Offset.lerp(start, end, step / 8)!);
        await tester.pump(const Duration(milliseconds: 40));
      }
      await gesture.up();
      await tester.pumpAndSettle();
    }

    Finder paletteChipFinder(VideoControlItem item) {
      return find.byKey(ValueKey<String>(
          'video-control-drag-chip-${item.storageValue}-palette-palette'));
    }

    Draggable<VideoControlDragData> draggableFor(
      WidgetTester tester,
      Finder source,
    ) {
      final Widget direct = tester.widget(source);
      if (direct is Draggable<VideoControlDragData>) return direct;
      final Finder ancestor = find.ancestor(
        of: source,
        matching: find.byWidgetPredicate(
          (Widget w) => w is Draggable<VideoControlDragData>,
        ),
      );
      return tester.widget<Draggable<VideoControlDragData>>(ancestor.first);
    }

    bool willAcceptDrag(
      WidgetTester tester,
      Finder source,
      Finder target,
    ) {
      final Draggable<VideoControlDragData> draggable =
          draggableFor(tester, source);
      final DragTarget<VideoControlDragData> dragTarget =
          tester.widget<DragTarget<VideoControlDragData>>(target);
      return dragTarget.onWillAcceptWithDetails!(
        DragTargetDetails<VideoControlDragData>(
          data: draggable.data!,
          offset: tester.getCenter(target),
        ),
      );
    }

    Future<void> acceptDrag(
      WidgetTester tester,
      Finder source,
      Finder target,
    ) async {
      final Draggable<VideoControlDragData> draggable =
          draggableFor(tester, source);
      final DragTarget<VideoControlDragData> dragTarget =
          tester.widget<DragTarget<VideoControlDragData>>(target);
      final DragTargetDetails<VideoControlDragData> details =
          DragTargetDetails<VideoControlDragData>(
        data: draggable.data!,
        offset: tester.getCenter(target),
      );
      expect(dragTarget.onWillAcceptWithDetails!(details), isTrue);
      dragTarget.onAcceptWithDetails!(details);
      await tester.pumpAndSettle();
    }

    testWidgets(
        'chips default to icons while semantics and tooltip expose names',
        (tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();

      await tester.binding.setSurfaceSize(const Size(1000, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _pump(tester, _sheet());
      await openControls(tester);

      // TODO-631: removing favoriteSentences from screenRight shifts settings
      // from index 3 to index 2 (now [subtitleList, favoriteSentence, settings]).
      final Finder settingsChip = chipFinder(
        VideoControlItem.settings,
        VideoControlSlot.screenRight,
        2,
      );
      expect(settingsChip, findsOneWidget);
      expect(find.text(t.video_control_settings), findsNothing);
      expect(
        tester.getSemantics(settingsChip),
        matchesSemantics(label: t.video_control_settings, isButton: true),
      );

      await tester.longPress(settingsChip);
      await tester.pumpAndSettle();
      expect(find.text(t.video_control_settings), findsOneWidget);
      Tooltip.dismissAllToolTips();
      await tester.pumpAndSettle();
      semantics.dispose();
    });

    testWidgets('preview places slots at player-like positions',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 950));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _pump(tester, _sheet());
      await openControls(tester);

      final Rect preview = tester.getRect(find.byKey(
        const ValueKey<String>('video-control-editor-preview'),
      ));
      final Rect topLeft = tester.getRect(slotFinder(VideoControlSlot.topLeft));
      final Rect topRight =
          tester.getRect(slotFinder(VideoControlSlot.topRight));
      final Rect screenLeft =
          tester.getRect(slotFinder(VideoControlSlot.screenLeft));
      final Rect screenRight =
          tester.getRect(slotFinder(VideoControlSlot.screenRight));
      final Rect bottomLeft =
          tester.getRect(slotFinder(VideoControlSlot.bottomLeft));
      final Rect bottomRight =
          tester.getRect(slotFinder(VideoControlSlot.bottomRight));
      final Rect hidden = tester.getRect(slotFinder(VideoControlSlot.hidden));

      expect(topLeft.center.dx, lessThan(preview.center.dx));
      expect(topLeft.center.dy, lessThan(preview.center.dy));
      expect(topRight.center.dx, greaterThan(preview.center.dx));
      expect(topRight.center.dy, lessThan(preview.center.dy));
      expect(screenLeft.center.dx, lessThan(preview.center.dx));
      expect(screenLeft.center.dy, closeTo(preview.center.dy, 80));
      expect(screenRight.center.dx, greaterThan(preview.center.dx));
      expect(screenRight.center.dy, closeTo(preview.center.dy, 80));
      expect(bottomLeft.center.dx, lessThan(preview.center.dx));
      expect(bottomLeft.center.dy, greaterThan(preview.center.dy));
      expect(bottomRight.center.dx, greaterThan(preview.center.dx));
      expect(bottomRight.center.dy, greaterThan(preview.center.dy));
      expect(hidden.top, greaterThanOrEqualTo(preview.bottom));
    });

    testWidgets(
        'narrow preview uses a compact slot grid without horizontal tail',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 950));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _pump(tester, _sheet());
      await openControls(tester);

      final List<VideoControlSlot> compactSlots = <VideoControlSlot>[
        VideoControlSlot.topLeft,
        VideoControlSlot.topCenter,
        VideoControlSlot.topRight,
        VideoControlSlot.screenLeft,
        VideoControlSlot.screenRight,
        VideoControlSlot.bottomLeft,
        VideoControlSlot.bottomCenter,
        VideoControlSlot.bottomRight,
      ];
      for (int i = 0; i < compactSlots.length; i++) {
        for (int j = i + 1; j < compactSlots.length; j++) {
          final Rect a = tester.getRect(slotFinder(compactSlots[i]));
          final Rect b = tester.getRect(slotFinder(compactSlots[j]));
          expect(a.overlaps(b), isFalse,
              reason: '${compactSlots[i]} and ${compactSlots[j]} overlap');
        }
      }

      final Iterable<SingleChildScrollView> ancestorScrolls =
          tester.widgetList<SingleChildScrollView>(
        find.ancestor(
          of: slotFinder(VideoControlSlot.topRight),
          matching: find.byType(SingleChildScrollView),
        ),
      );
      expect(
        ancestorScrolls.where(
            (SingleChildScrollView s) => s.scrollDirection == Axis.horizontal),
        isEmpty,
        reason:
            'compact controls page should reveal slots without horizontal scroll',
      );
      _expectNoFlutterErrors(tester);
    });

    for (final ({double width, double scale}) sizeCase
        in <({double width, double scale})>[
      (width: 320, scale: 1.5),
      (width: 320, scale: 2.0),
      (width: 360, scale: 1.5),
      (width: 360, scale: 2.0),
      (width: 420, scale: 1.5),
      (width: 420, scale: 2.0),
      (width: 560, scale: 2.0),
    ]) {
      testWidgets(
          'controls page has no overflow at ${sizeCase.width.round()}px '
          'and UI scale ${sizeCase.scale}', (tester) async {
        await tester.binding.setSurfaceSize(Size(sizeCase.width, 1200));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await _pumpScaled(
          tester,
          _sheet(uiScale: sizeCase.scale),
          scale: sizeCase.scale,
        );
        await openControls(tester);

        expect(
          find.byKey(
            const ValueKey<String>('video-control-editor-preview'),
          ),
          findsOneWidget,
        );
        await tester.ensureVisible(find.text(t.video_control_palette_title));
        await tester.pumpAndSettle();
        await tester.ensureVisible(slotFinder(VideoControlSlot.hidden));
        await tester.pumpAndSettle();
        _expectNoFlutterErrors(tester);
      });
    }

    testWidgets('narrow controls accept moves after scrolling', (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      VideoControlLayout? latest;
      await _pumpScaled(
        tester,
        _sheet(
          uiScale: 2.0,
          onControlLayoutChanged: (VideoControlLayout layout) {
            latest = layout;
          },
        ),
        scale: 2.0,
      );
      await openControls(tester);

      await acceptDrag(
        tester,
        paletteChipFinder(VideoControlItem.volume),
        slotFinder(VideoControlSlot.bottomLeft),
      );
      expect(latest, isNotNull);
      expect(latest!.slotsOf(VideoControlItem.volume), <VideoControlSlot>[
        VideoControlSlot.bottomLeft,
        VideoControlSlot.bottomRight,
      ]);

      await tester.drag(
        find.byType(SingleChildScrollView).first,
        const Offset(0, -120),
      );
      await tester.pumpAndSettle();
      await acceptDrag(
        tester,
        dragChipFinder(
          VideoControlItem.speed,
          VideoControlSlot.bottomRight,
          2,
        ),
        slotFinder(VideoControlSlot.hidden),
      );
      expect(
        latest!.removedItems,
        contains(VideoControlItem.speed),
      );
      expect(latest!.itemsIn(VideoControlSlot.hidden), isEmpty);
      _expectNoFlutterErrors(tester);
    });

    testWidgets('dragging controls updates bottomLeft and removed items',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 950));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      VideoControlLayout? latest;
      await _pump(
        tester,
        _sheet(onControlLayoutChanged: (VideoControlLayout layout) {
          latest = layout;
        }),
      );
      await openControls(tester);

      await dragChipTo(
        tester,
        dragChipFinder(VideoControlItem.speed, VideoControlSlot.bottomRight, 2),
        slotFinder(VideoControlSlot.bottomLeft),
      );
      expect(latest, isNotNull);
      expect(
        latest!.itemsIn(VideoControlSlot.bottomLeft),
        contains(VideoControlItem.speed),
      );

      await dragChipTo(
        tester,
        dragChipFinder(
            VideoControlItem.subtitleList, VideoControlSlot.screenRight, 0),
        slotFinder(VideoControlSlot.hidden),
      );
      expect(
        latest!.removedItems,
        contains(VideoControlItem.subtitleList),
      );
      expect(latest!.itemsIn(VideoControlSlot.hidden), isEmpty);
    });

    testWidgets('settings can be removed from the player', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 950));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      VideoControlLayout? latest;
      await _pump(
        tester,
        _sheet(onControlLayoutChanged: (VideoControlLayout layout) {
          latest = layout;
        }),
      );
      await openControls(tester);

      await dragChipTo(
        tester,
        dragChipFinder(
            VideoControlItem.settings, VideoControlSlot.screenRight, 2),
        slotFinder(VideoControlSlot.hidden),
      );
      expect(latest, isNotNull);
      expect(latest!.isOnPlayer(VideoControlItem.settings), isFalse);
      expect(latest!.removedItems, contains(VideoControlItem.settings));
      expect(find.text('Required controls must stay on the player.'),
          findsNothing);
    });

    testWidgets(
        'TODO-554: touch controls keep settings on the player (cannot hide it)',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 950));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      VideoControlLayout? latest;
      await _pump(
        tester,
        _sheet(
          isTouchControls: true,
          onControlLayoutChanged: (VideoControlLayout layout) {
            latest = layout;
          },
        ),
      );
      await openControls(tester);

      // On touch the settings button is the sole in-player entry to this very
      // editor; hiding it would soft-lock the user out (regression dd988f477).
      await dragChipTo(
        tester,
        dragChipFinder(
            VideoControlItem.settings, VideoControlSlot.screenRight, 2),
        slotFinder(VideoControlSlot.hidden),
      );
      expect(latest, isNull,
          reason: 'touch must refuse hiding the settings entry');
      expect(find.text('Required controls must stay on the player.'),
          findsOneWidget);
    });

    testWidgets('required playPause button cannot be hidden', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 950));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      VideoControlLayout? latest;
      await _pump(
        tester,
        _sheet(onControlLayoutChanged: (VideoControlLayout layout) {
          latest = layout;
        }),
      );
      await openControls(tester);

      await dragChipTo(
        tester,
        dragChipFinder(
            VideoControlItem.playPause, VideoControlSlot.bottomCenter, 2),
        slotFinder(VideoControlSlot.hidden),
      );
      expect(latest, isNull);
      expect(find.text('Required controls must stay on the player.'),
          findsOneWidget);
    });

    testWidgets('volume chip moves only between bottom bar slots',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 950));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      VideoControlLayout? latest;
      await _pump(
        tester,
        _sheet(onControlLayoutChanged: (VideoControlLayout layout) {
          latest = layout;
        }),
      );
      await openControls(tester);

      await dragChipTo(
        tester,
        dragChipFinder(
            VideoControlItem.volume, VideoControlSlot.bottomRight, 0),
        slotFinder(VideoControlSlot.bottomLeft),
      );
      expect(latest, isNotNull);
      expect(latest!.slotsOf(VideoControlItem.volume),
          <VideoControlSlot>[VideoControlSlot.bottomLeft]);

      await dragChipTo(
        tester,
        dragChipFinder(VideoControlItem.volume, VideoControlSlot.bottomLeft, 1),
        slotFinder(VideoControlSlot.topRight),
      );
      expect(latest!.slotsOf(VideoControlItem.volume),
          <VideoControlSlot>[VideoControlSlot.bottomLeft]);
      expect(
          find.text('Volume can only sit on the bottom bar.'), findsOneWidget);
    });

    testWidgets('all-controls palette copies volume into the other bottom slot',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      VideoControlLayout? latest;
      await _pump(
        tester,
        _sheet(onControlLayoutChanged: (VideoControlLayout layout) {
          latest = layout;
        }),
      );
      await openControls(tester);

      final Finder source = paletteChipFinder(VideoControlItem.volume);
      final Finder bottomLeft = slotFinder(VideoControlSlot.bottomLeft);
      final Finder topRight = slotFinder(VideoControlSlot.topRight);
      expect(find.text(t.video_control_palette_title), findsOneWidget);
      expect(source, findsOneWidget);
      expect(willAcceptDrag(tester, source, topRight), isFalse);

      await acceptDrag(tester, source, bottomLeft);
      expect(willAcceptDrag(tester, source, bottomLeft), isFalse);

      expect(latest, isNotNull);
      expect(latest!.slotsOf(VideoControlItem.volume), <VideoControlSlot>[
        VideoControlSlot.bottomLeft,
        VideoControlSlot.bottomRight,
      ]);
      expect(
        latest!
            .itemsIn(VideoControlSlot.bottomLeft)
            .where((VideoControlItem i) => i == VideoControlItem.volume),
        hasLength(1),
      );
    });

    testWidgets('title can be removed and restored from quick settings',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      VideoControlLayout? latest;
      await _pump(
        tester,
        _sheet(onControlLayoutChanged: (VideoControlLayout layout) {
          latest = layout;
        }),
      );
      await openControls(tester);

      final Finder topCenter = slotFinder(VideoControlSlot.topCenter);
      final Finder topRight = slotFinder(VideoControlSlot.topRight);
      final Finder hidden = slotFinder(VideoControlSlot.hidden);
      expect(topCenter, findsOneWidget);
      expect(hidden, findsOneWidget);
      expect(
        willAcceptDrag(
          tester,
          paletteChipFinder(VideoControlItem.speed),
          topCenter,
        ),
        isFalse,
      );

      await acceptDrag(
        tester,
        dragChipFinder(VideoControlItem.title, VideoControlSlot.topCenter, 0),
        hidden,
      );
      expect(latest!.slotsOf(VideoControlItem.title),
          <VideoControlSlot>[VideoControlSlot.hidden]);
      expect(latest!.itemsIn(VideoControlSlot.hidden), isEmpty);

      await acceptDrag(
        tester,
        paletteChipFinder(VideoControlItem.title),
        topRight,
      );
      expect(latest!.slotsOf(VideoControlItem.title),
          <VideoControlSlot>[VideoControlSlot.topRight]);
    });

    test('removed controls wording uses out-of-player semantics', () {
      expect(t.video_control_slot_hidden, 'Removed from player');
      expect(t.video_control_remove_from_slot, 'Move out');
      expect(t.video_control_customize_hint, contains('move it out'));
    });

    test('source guard: crowded slot chips can scroll instead of clipping', () {
      final String src =
          File('lib/src/media/video/video_quick_settings_sheet.dart')
              .readAsStringSync();
      expect(src, isNot(contains('math.max(560')),
          reason: 'control editor must size from current constraints');
      expect(src, contains('Widget _buildCompactSlotGrid('),
          reason: 'narrow controls page needs a true compact slot layout');
      final int paletteStart = src.indexOf('Widget _buildControlPalette(');
      expect(paletteStart, greaterThanOrEqualTo(0));
      final int paletteEnd =
          src.indexOf('Widget _buildHiddenSlotTray', paletteStart);
      expect(paletteEnd, greaterThan(paletteStart));
      final String paletteBody = src.substring(paletteStart, paletteEnd);
      expect(paletteBody, contains('Wrap('),
          reason:
              'palette chips should wrap instead of hiding in a horizontal tail');
      final int start = src.indexOf('Widget _buildSlotRegion(');
      expect(start, greaterThanOrEqualTo(0));
      final int end = src.indexOf('Widget _buildPlacedControlChip', start);
      expect(end, greaterThan(start));
      final String body = src.substring(start, end);
      expect(body, contains('SingleChildScrollView('),
          reason:
              'slot chip Wrap must be scrollable when many buttons are present');
    });
  });

  // ── TODO-556：视频设置大分类置顶（顶部横滑 chip 行 + 下方全宽详情） ───────
  group('TODO-556 video settings categories live in a top bar', () {
    testWidgets('selecting a top-bar category switches the detail below it',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _pump(tester, _sheet());

      // 大分类一律渲染成顶栏纯图标 chip（无左右 master-detail、无左栏列表项）。
      // TODO-640：chip 无文字，按 id key 命中。
      expect(find.byType(MaterialSupportingPaneLayout), findsNothing);
      expect(find.byType(HibikiListItem), findsNothing);
      for (final String id in <String>[
        'playback',
        'shaders',
        'mpv',
        'subtitle',
        'danmaku',
        'controls',
      ]) {
        expect(_categoryChip(id), findsOneWidget,
            reason: '$id must be a top-bar category chip');
      }

      // 选「mpv」分类（顶栏纯图标 chip）→ 下方详情切到 mpv 详情，无 push 返回箭头。
      await tester.tap(_categoryChip('mpv'));
      await tester.pumpAndSettle();
      expect(find.text(t.video_setting_mpv_deband), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back), findsNothing);

      // 被选 chip 的 dy 仍在 mpv 详情之上（顶栏不动、详情在下方）。
      final double chipY = tester.getTopLeft(_categoryChip('mpv')).dy;
      final double detailY =
          tester.getTopLeft(find.text(t.video_setting_mpv_deband)).dy;
      expect(chipY, lessThan(detailY),
          reason: 'top category bar must stay above the detail pane');
    });

    test(
        'source guard: wide branch builds the top category bar, not a left '
        'master-detail pane', () {
      final String src =
          File('lib/src/media/video/video_quick_settings_sheet.dart')
              .readAsStringSync();
      // 宽窗大分类置顶：必须有顶栏构建器，且不再用左右 master-detail 容器/侧栏。
      expect(src, contains('_buildTopCategoryBar('),
          reason: '宽窗分类须经顶栏横滑 chip 构建器渲染');
      expect(src, isNot(contains('MaterialSupportingPaneLayout(')),
          reason: '视频设置宽窗不得再回退到左右 master-detail（书籍设置才用它）');
      expect(src, isNot(contains('_buildWidePane(')),
          reason: '旧左栏构建器 _buildWidePane 必须删除');
      // TODO-640：顶栏 chip 改纯图标 + tooltip（文字说明 hover / 长按），不再内联文字
      // 标签；详情顶部用大标题标出当前分类。
      expect(src, contains('iconOnly: true'),
          reason: '顶栏分类 chip 须为仅图标模式（TODO-640，文字挤不下改 tooltip）');
      expect(src, contains('tooltip: cat.label'),
          reason: '纯图标 chip 须用分类标签作 tooltip（hover / 长按显示文字说明）');
      expect(src, contains('_buildWideDetailTitle('),
          reason: '宽窗详情顶部须渲染当前分类标题（纯图标顶栏后用户靠标题认当前项）');
    });
  });
}
