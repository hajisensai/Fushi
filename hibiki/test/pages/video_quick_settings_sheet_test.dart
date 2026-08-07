import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fushi/src/media/video/video_asbplayer_config.dart';
import 'package:fushi/src/media/video/video_control_customization.dart';
import 'package:fushi/src/media/video/video_immersive_mode.dart';
import 'package:fushi/src/media/video/video_mpv_config.dart';
import 'package:fushi/src/media/video/video_shader_tier.dart';
import 'package:fushi/src/media/video/video_side_panel.dart';
import 'package:fushi/src/media/video/video_subtitle_style.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/video_shader_dialog.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_video.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_audio/fushi_audio.dart';

import '../helpers/video_quick_settings_harness.dart';

// 阶段 B：VideoQuickSettingsSheet 改消费 settings schema 投影（唯一真相源
// settings_schema_video.dart + VideoQuickSettingsHost 能力槽），旧 ~60 个构造参数
// 全部收敛进 host / prefs。本文件的行为断言（分类外壳、行控件类型、回调写穿、
// 键位/几何）保持不变；构造改走共享 harness（内存 DB AppModel + 可变状态 host，
// 见 video_quick_settings_harness.dart）。旧 `initial*` 参数按数据归属拆两路：
// pref 背书的行先写 appModel（面板从 prefs 读初值），页面权威值（延迟/字幕样式/
// 控件布局）进 TestVideoHostState。
Future<VideoSheetHarness> _pumpSheet(
  WidgetTester tester, {
  void Function(int)? onSetDelay,
  void Function(double)? onPreviewSpeed,
  void Function(double)? onSetSpeed,
  void Function(VideoAsbplayerConfig)? onAsbConfigChanged,
  void Function(VideoMpvConfig)? onMpvConfigChanged,
  void Function(VideoShaderTier tier, bool highQuality)? onSelectShaderTier,
  void Function(VideoFitMode mode)? onVideoFitModeChanged,
  void Function(VideoImmersiveMode mode)? onImmersiveModeChanged,
  void Function(VideoControlLayout layout)? onControlLayoutChanged,
  VideoControlLayout? initialControlLayout,
  bool isTouchControls = false,
  VideoFitMode initialVideoFitMode = VideoFitMode.cover,
  VideoImmersiveMode initialImmersiveMode = VideoImmersiveMode.lookupOnly,
  double uiScale = 1.0,
  double? wrapScale,
  int initialDelayMs = 0,
  VideoSubtitleStyle? initialSubtitleStyle,
  void Function(VideoSubtitleStyle)? onSubtitleStylePreview,
  void Function(VideoSubtitleStyle)? onSubtitleStyleCommit,
  Future<int?> Function()? onAutoAlign,
  List<AudioCue> subtitleWaveformCues = const <AudioCue>[],
  Future<List<double>> Function()? loadSubtitleWaveform,
  String? initialCategory,
  Widget? audioTrackSection,
  Widget? subtitleTrackSection,
  VoidCallback? onSubtitleCategoryShown,
  VoidCallback? onSwitchToSkiaRenderer,
  Widget Function(Widget sheet)? wrap,
}) async {
  final VideoSheetHarness harness = await VideoSheetHarness.create();
  addTearDown(harness.dispose);
  // 旧 _sheet 默认 initialVideoFitMode=cover / initialImmersiveMode=lookupOnly；
  // schema 行现在从 prefs 读初值（prefs 默认 contain / fallback=shortcutAndLookup），
  // 先写穿 appModel 复现旧初值。
  await harness.appModel.setVideoFitMode(initialVideoFitMode);
  await harness.appModel.setVideoImmersiveMode(initialImmersiveMode);
  final Widget sheet = buildVideoSheetUnderTest(
    harness: harness,
    host: buildTestVideoHost(
      state: TestVideoHostState(
        delayMs: initialDelayMs,
        subtitleStyle: initialSubtitleStyle,
        controlLayout: initialControlLayout,
      ),
      uiScale: uiScale,
      isTouchControls: isTouchControls,
      onSetDelay: onSetDelay,
      onAutoAlign: onAutoAlign,
      subtitleWaveformCues: subtitleWaveformCues,
      loadSubtitleWaveform: loadSubtitleWaveform,
      onPreviewSpeed: onPreviewSpeed,
      onSetSpeed: onSetSpeed,
      onSubtitleStylePreview: onSubtitleStylePreview,
      onSubtitleStyleCommit: onSubtitleStyleCommit,
      onAsbConfigChanged: onAsbConfigChanged,
      onMpvConfigChanged: onMpvConfigChanged,
      onSelectShaderTier: onSelectShaderTier,
      onVideoFitModeChanged: onVideoFitModeChanged,
      onImmersiveModeChanged: onImmersiveModeChanged,
      onControlLayoutChanged: onControlLayoutChanged,
      onSwitchToSkiaRenderer: onSwitchToSkiaRenderer,
      audioTrackSection: audioTrackSection,
      subtitleTrackSection: subtitleTrackSection,
      onSubtitleCategoryShown: onSubtitleCategoryShown,
    ),
    initialCategory: initialCategory,
  );
  Widget body = wrap != null ? wrap(sheet) : sheet;
  if (wrapScale != null) {
    body = FushiAppUiScale(scale: wrapScale, child: body);
  }
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: Scaffold(body: body),
    ),
  );
  await tester.pump();
  return harness;
}

void _expectNoFlutterErrors(WidgetTester tester) {
  final List<Object> exceptions = <Object>[];
  Object? exception;
  while ((exception = tester.takeException()) != null) {
    exceptions.add(exception!);
  }
  expect(exceptions, isEmpty);
}

/// 宽窗顶栏分类 chip 的稳定 key（与 video_quick_settings_sheet.dart 同步）：测试 /
/// 焦点驱动统一靠 id key 命中，不依赖标签文案（TODO-1351 起 chip 为「图标 + 完整文字」）。
Finder _categoryChip(String id) =>
    find.byKey(ValueKey<String>('video-settings-cat-$id'));

/// 切换到某分类：宽窗点顶栏 chip（按 id key），窄窗点带文字的分类导航行（按 label）。
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

/// 阶段 B：schema dropdown 行经 SettingsSchemaItem 的 `_segmented<Object>` 派发，
/// 运行时泛型是 `AdaptiveSettingsPickerRow<Object>`（不再是旧手写面板的具体枚举
/// 泛型实参），故按 title 谓词定位、以 Object 泛型读字段——值本身仍是真实枚举，
/// selected / options / onChanged 的行为断言不变。
Finder _pickerRowFinder(String title) => find.byWidgetPredicate(
      (Widget w) => w is AdaptiveSettingsPickerRow && w.title == title,
    );

AdaptiveSettingsPickerRow<Object> _pickerRow(
  WidgetTester tester,
  String title,
) {
  return tester.widget(_pickerRowFinder(title))
      as AdaptiveSettingsPickerRow<Object>;
}

/// 数据模型守卫用：从视频 schema 唯一真相源里按 id 取条目声明。
SettingsItem _findSchemaItem(String id) {
  for (final SettingsSection section in buildVideoDestination().sections) {
    for (final SettingsItem item in section.items) {
      if (item.id == id) return item;
    }
  }
  fail('settings_schema_video.dart 里找不到 id 为 $id 的条目');
}

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();
  late Directory shaderTempDir;

  setUp(() {
    // TODO-935 E1：桌面下 AppPaths._resolveDataRoot 会读 SharedPreferences
    // 的 data_root（Linux/Windows 测试宿主 isDesktopPlatform=true）。未 mock 时
    // getInstance() 在本绑定下挂起（着色器面板的 listShaderFiles 永不返回 →
    // 旋转进度条让 pumpAndSettle 超时）。给个空初值让其即时返回、回退默认根。
    SharedPreferences.setMockInitialValues(<String, Object>{});
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
    // 「无着色器」档语义是 None（zh 无 / ja なし），非开关 Off——与其余档并列为档位名。
    expect(t.video_shader_tier_off, 'None');
    expect(t.video_shader_tier_low, 'Low');
    expect(t.video_shader_tier_medium, 'Medium');
    expect(t.video_shader_tier_high, 'High');
    expect(t.video_shader_tier_ultra, 'Ultra');
    // 档位说明告诉用户取舍（含具体技术名供参考），但选择本身只是五档单选。
    expect(t.video_shader_tier_low_hint.toLowerCase(),
        contains('ewa_lanczossharp'));
    expect(t.video_shader_tier_medium_hint, contains('Anime4K'));
    expect(t.video_shader_tier_high_hint, contains('Anime4K'));
    expect(t.video_shader_tier_ultra_hint, contains('Anime4K'));
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
    await _pumpSheet(tester);

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
    // 阶段 B 适配：着色器视图的当前档位高亮改由 pref（videoMpvConfig.highQuality +
    // 启用集）派生，切档回调后面板 refresh 重建即重读 pref。真实视频页在
    // onSelectShaderTier 里持久化 highQuality；测试探针须同样写穿（prefsRepo 的
    // 内存缓存同步更新），否则第一次切档后高亮弹回、第二次点击成 no-op。
    late final VideoSheetHarness h;
    h = await _pumpSheet(
      tester,
      onSelectShaderTier: (VideoShaderTier tier, bool hq) {
        selectedTier = tier;
        selectedHq = hq;
        final VideoMpvConfig next =
            VideoMpvConfig.decode(h.appModel.videoMpvConfig)
                .copyWith(highQuality: hq);
        unawaited(h.appModel.setVideoMpvConfig(VideoMpvConfig.encode(next)));
      },
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
    await _pumpSheet(tester);

    // 顶栏 chip 按 id key 命中（TODO-1351 起「图标 + 完整文字」）；默认选中
    // playback → 下方详情顶部用大标题标出当前分类 + 显示倍速（字幕调轴已按语义
    // 移到「字幕」分类，playback 不再显示）。
    for (final String id in <String>[
      'playback',
      'shaders',
      'mpv',
      'subtitle',
      'danmaku',
      'controls',
    ]) {
      expect(_categoryChip(id), findsOneWidget, reason: '$id 必须是顶栏分类 chip');
    }
    // 选中分类（playback）标签出现两处：顶栏 chip 完整文字（TODO-1351）+ 详情区大标题。
    expect(find.text(t.video_settings_cat_playback), findsNWidgets(2));
    expect(find.text(t.video_setting_speed), findsOneWidget);
    expect(find.text(t.video_setting_av_delay), findsNothing,
        reason: '字幕调轴已移到「字幕」分类，播放分类不再显示');
    // 上下分栏无 push：无返回箭头。
    expect(find.byIcon(Icons.arrow_back), findsNothing);

    // TODO-556：大分类从左栏 master-detail 改成顶部横滑 chip 行（入口置顶）。
    // 不再有左右 master-detail（无 MaterialSupportingPaneLayout / 左栏 FushiListItem）。
    expect(find.byType(MaterialSupportingPaneLayout), findsNothing);
    expect(find.byType(FushiListItem), findsNothing);
    // 每个分类一个 FushiSelectableChip（六分类 → 至少 6 个）。
    expect(find.byType(FushiSelectableChip), findsAtLeastNWidgets(6));

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
        return s.scrollDirection == Axis.vertical && p != null && p.left == 28;
      },
    );
    final EdgeInsets primaryPadding = detailScroll.padding! as EdgeInsets;
    expect(primaryPadding.left, 28);
    expect(primaryPadding.right, 28);

    // 选「字幕」→ 下方详情切到字幕详情，仍无返回箭头。
    await _tapCategory(tester, 'subtitle', t.video_settings_cat_subtitle);
    expect(find.text(t.video_setting_subtitle_obscure), findsOneWidget);
    expect(find.text(t.video_setting_subtitle_font_size), findsOneWidget);
    expect(find.text(t.video_setting_subtitle_font_weight), findsOneWidget);
    expect(find.text(t.video_setting_subtitle_shadow), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back), findsNothing);
  });

  testWidgets(
      'wide category bar renders full inline labels without truncation even '
      'at UI scale 2.0 (TODO-1351)', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1320, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpSheet(
      tester,
      uiScale: 2.0,
      wrapScale: 2.0,
      initialVideoFitMode: VideoFitMode.contain,
    );

    // TODO-1351（用户复诉）：分类 tab 必须「图标 + 完整文字」显示（参考「检查器」式
    // tab），标签按固有宽度完整渲染、不得省略号截断；顶栏空间不够时整条横滑兜底
    // （TODO-640 的纯图标 + tooltip 方案被用户否决）。
    expect(find.byType(MaterialSupportingPaneLayout), findsNothing);
    for (final ({String id, IconData icon, String label}) cat
        in <({String id, IconData icon, String label})>[
      (
        id: 'playback',
        icon: Icons.play_circle_outline,
        label: t.video_settings_cat_playback
      ),
      (
        id: 'audio',
        icon: Icons.audiotrack_outlined,
        label: t.video_settings_cat_audio
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
      // 全文标签把顶栏撑宽，末位分类可能在横滑视口外，先滑入视口再断言几何。
      await tester.ensureVisible(chip);
      await tester.pumpAndSettle();
      expect(chip, findsOneWidget, reason: '${cat.id} 必须是顶栏分类 chip');
      // chip 内有该分类图标（图标 + 文字并列，观感对齐「检查器」tab）。
      expect(find.descendant(of: chip, matching: find.byIcon(cat.icon)),
          findsOneWidget,
          reason: '${cat.id} chip 须渲染分类图标');
      // chip 内联渲染完整文字标签（TODO-1351 用户复诉：不许只剩图标 / tooltip）。
      final Finder labelText =
          find.descendant(of: chip, matching: find.text(cat.label));
      expect(labelText, findsOneWidget,
          reason: '${cat.id} chip 必须内联渲染完整文字标签（TODO-1351）');
      // 标签不得省略号截断：Text 配置为 visible（allowLabelOverflow）……
      final Text labelWidget = tester.widget<Text>(labelText);
      expect(labelWidget.overflow, TextOverflow.visible,
          reason: '${cat.id} 标签不得用 ellipsis 截断（TODO-1351）');
      // ……且实际布局宽度容纳全部文字（按固有宽度完整铺开，无视觉裁切）。
      final RenderParagraph paragraph =
          tester.renderObject<RenderParagraph>(labelText);
      expect(
        paragraph.size.width,
        greaterThanOrEqualTo(
            paragraph.getMaxIntrinsicWidth(double.infinity) - 0.5),
        reason: '${cat.id} 标签必须按固有宽度完整渲染，不得被压缩截断（TODO-1351）',
      );
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
      await _pumpSheet(
        tester,
        uiScale: sizeCase.scale,
        wrapScale: sizeCase.scale,
        initialVideoFitMode: VideoFitMode.contain,
      );

      // 分类入口可达：窄窗是带文字的导航行，宽窗是顶栏 chip（按 id key）。
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
    await _pumpSheet(tester, uiScale: 2.0);

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
    // 默认阴影 PR#23/BUG-323 改回 Niratan 柔和投影模糊半径 3px；UI scale 2.0 下预览 = 3 * 2 = 6。
    expect(shadowRow.value, 6);
  });

  // ── BUG-672：字幕轨切换不即时加载（要重开才行）+ 副字幕跳到另一个窗口 ─────────
  // 根因①：字幕源列表 _subtitleMenuSources 之前只由「字幕轨」控制按钮预填，用户经齿轮
  // 进面板再点「字幕」分类时不加载。修复：面板进入「字幕」分类即回调 onSubtitleCategoryShown，
  // 由视频页 _ensureSubtitleMenuSourcesLoaded 枚举字幕源。这里锁死「进入字幕分类必触发回调」。
  testWidgets('BUG-672: 打开面板直达「字幕」分类即触发字幕源加载回调（宽窗）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    int shown = 0;
    await _pumpSheet(
      tester,
      initialCategory: 'subtitle',
      subtitleTrackSection: const Text('SUBTITLE-TRACK-SECTION'),
      onSubtitleCategoryShown: () => shown++,
    );
    // onSubtitleCategoryShown 延后到帧后触发（避免 initState 内同步 setState 父页）。
    await tester.pump();
    expect(shown, greaterThanOrEqualTo(1),
        reason: '打开面板直达字幕分类，必须触发字幕源加载回调（否则字幕轨列表不即时加载）');
    // 字幕轨切换区内联渲染在「字幕」分类里（副字幕也在其中，不再跳独立窗口）。
    expect(find.text('SUBTITLE-TRACK-SECTION'), findsOneWidget,
        reason: '注入的字幕轨切换区必须内联渲染在字幕分类详情里');
  });

  testWidgets('BUG-672: 从别的分类点「字幕」chip 触发字幕源加载回调（宽窗）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    int shown = 0;
    await _pumpSheet(tester, onSubtitleCategoryShown: () => shown++);
    // 默认在 playback，尚未进入字幕分类 → 回调未触发。
    expect(shown, 0);
    // 点「字幕」分类 chip → 进入字幕分类 → 触发一次加载回调。
    await _tapCategory(tester, 'subtitle', t.video_settings_cat_subtitle);
    expect(shown, greaterThanOrEqualTo(1),
        reason: '点字幕分类 chip 进入字幕分类，必须触发字幕源加载回调（字幕轨即时加载）');
  });

  testWidgets('BUG-672: 窄窗导航进「字幕」分类触发字幕源加载回调', (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    int shown = 0;
    await _pumpSheet(tester, onSubtitleCategoryShown: () => shown++);
    expect(shown, 0);
    await _tapCategory(tester, 'subtitle', t.video_settings_cat_subtitle);
    expect(shown, greaterThanOrEqualTo(1),
        reason: '窄窗点字幕导航行进入字幕分类，同样必须触发字幕源加载回调');
  });

  testWidgets(
      'subtitle no-background shortcut previews commits and updates slider',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final List<VideoSubtitleStyle> previews = <VideoSubtitleStyle>[];
    final List<VideoSubtitleStyle> commits = <VideoSubtitleStyle>[];
    await _pumpSheet(
      tester,
      initialSubtitleStyle: VideoSubtitleStyle.defaults.copyWith(
        backgroundOpacity: 0.75,
      ),
      onSubtitleStylePreview: previews.add,
      onSubtitleStyleCommit: commits.add,
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
      reason: '快捷项必须同步页面权威样式，避免背景不透明度滑条显示滞后',
    );
  });

  testWidgets(
      'wide video settings keeps the top category bar fixed while the detail '
      'scrolls (TODO-556)', (tester) async {
    // 高度取 500（>= kHibikiSettingsWideMinHeight=440 → 进宽窗），下方详情行多仍可滚。
    await tester.binding.setSurfaceSize(const Size(1000, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpSheet(tester);

    // 字幕详情行多（开关 + 三滑条 + 重置）→ 必然超过详情高、可独立滚动。
    await _tapCategory(tester, 'subtitle', t.video_settings_cat_subtitle);

    // 顶部分类条里的「播放」chip 是固定锚点（chip 行钉在顶部、随详情滚动不动）。
    // chip 按 id key 命中（不依赖标签文案）。
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
    await _pumpSheet(tester);
    await tester.pumpAndSettle();

    // 回退 push 主页：默认 playback 详情（倍速）不再随分栏展开。
    expect(find.text(t.video_setting_speed), findsNothing,
        reason: '高度低于阈值时应回退 push，而非保持 master-detail 显示右详情');
    // push 主页仍列出分类导航行。
    expect(find.text(t.video_settings_cat_playback), findsOneWidget);

    // 点分类 → push 子页 + 返回箭头（证明走的是窄窗 push 语义）。
    await _tapCategory(tester, 'playback', t.video_settings_cat_playback);
    expect(find.text(t.video_setting_speed), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
  });

  testWidgets('narrow video settings pushes detail sub-pages', (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpSheet(tester);

    // 窄窗主页：只列分类导航行，详情未展开（倍速未显示）。
    expect(find.text(t.video_settings_cat_playback), findsOneWidget);
    expect(find.text(t.video_setting_speed), findsNothing);
    expect(find.byIcon(Icons.arrow_back), findsNothing);

    // push 进「播放」→ 详情 + 返回箭头；返回回主页。
    await _tapCategory(tester, 'playback', t.video_settings_cat_playback);
    expect(find.text(t.video_setting_speed), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(find.text(t.video_setting_speed), findsNothing);
  });

  testWidgets('scaled settings side panel stays inside a narrow viewport',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(720, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpSheet(
      tester,
      uiScale: 2.0,
      wrapScale: 2.0,
      wrap: (Widget sheet) => VideoTranslucentSidePanel(
        title: t.video_settings_title,
        width: 560,
        child: sheet,
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text(t.video_settings_cat_playback), findsOneWidget);

    await _tapCategory(tester, 'playback', t.video_settings_cat_playback);

    expect(tester.takeException(), isNull);
    expect(find.text(t.video_setting_speed), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
  });

  // ── TODO-561：mpv 高级「额外 mpv 选项」标题文本显示不全 ─────────────────
  // 原来标题挂在 InputDecoration.labelText（Material 浮动 label 恒单行 + ellipsis），
  // 在窄右 pane / 高 UI scale 下被截断。修复后标题是 TextField 上方独立、可换行、
  // 完整显示的 Text；输入框不再走单行浮动 label。
  Future<void> openMpvAdvanced(WidgetTester tester) async {
    await _tapCategory(tester, 'mpv', t.video_settings_cat_mpv);
    // mpv 详情是 shrinkWrap 的投影列表，会一次性 build 全部分组（含底部「高级」段），
    // 离屏 widget 仍完成 layout，故无需滚动即可命中并测量标题。
  }

  testWidgets(
      'mpv extra-options title is an independent text, not a single-line '
      'floating label', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpSheet(tester);
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
      await _pumpSheet(
        tester,
        uiScale: sizeCase.scale,
        wrapScale: sizeCase.scale,
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
    // 阶段 B：mpv 原始 conf 输入框移入 video_settings_actions.dart
    // （_VideoMpvRawConfField），守卫改扫该文件。
    final String src = File('lib/src/media/video/video_settings_actions.dart')
        .readAsStringSync();
    expect(src, isNot(contains('labelText: t.video_setting_mpv_raw')),
        reason: '「额外 mpv 选项」标题不能再走 InputDecoration.labelText（浮动 label 恒单行 '
            '+ ellipsis，窄 pane 截断）；须是输入框上方独立可换行 Text');
  });

  testWidgets('mpv category renders the config inline (no sub-dialog)',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpSheet(tester);

    await _tapCategory(tester, 'mpv', t.video_settings_cat_mpv);

    // 解码/画质/色彩/重置都内嵌在详情 pane（不是导航行 → pop → 二级对话框）。
    // hwdec 是 picker 行：下拉可能为测宽离屏复刻一份标题，故 findsWidgets。
    expect(find.text(t.video_setting_mpv_hwdec), findsWidgets);
    expect(find.text(t.video_setting_mpv_deband), findsOneWidget);
    expect(find.text(t.video_setting_mpv_brightness), findsOneWidget);
    expect(find.text(t.video_setting_mpv_reset), findsOneWidget);
    // 上下分栏内嵌：无返回箭头（不走 push 子页）。
    expect(find.byIcon(Icons.arrow_back), findsNothing);
  });

  testWidgets('mpv deband switch drives onMpvConfigChanged live',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    VideoMpvConfig? committed;
    await _pumpSheet(tester, onMpvConfigChanged: (c) => committed = c);

    await _tapCategory(tester, 'mpv', t.video_settings_cat_mpv);

    // 切「去色带」开关 → 即改即生效回调（无保存按钮）。mpv 分类按 order 排序后
    // 首个 Switch 仍是 deband（hwdec 是 picker 不是 Switch）。
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
    await _pumpSheet(tester, onSetDelay: (int v) => delay = v);
    // 字幕调轴已归到「字幕」分类。
    await _tapCategory(tester, 'subtitle', t.video_settings_cat_subtitle);

    // 字幕详情里 chevron_right 仅出现在字幕调轴的「+50ms」按钮（picker 行用下拉箭头、
    // 非 chevron_right）。顶栏分类条在窄宽窗（如 1000px；desktop 面板 maxWidth 900 更窄）
    // 会换行成两行、把详情下推，故先 ensureVisible 把按钮滚进可点区域再点，不依赖顶栏
    // 恰好单行的脆弱位置假设。
    await tester.ensureVisible(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pump();
    expect(delay, 50);
  });

  // ── TODO-1232 / BUG-597：视频黑屏（有声无画）降级行 ─────────────────────────
  // Android 默认已保持 Impeller；受影响机型（Impeller 合成不了 media_kit 外部纹理，见
  // BUG-597）经「播放」分类的一键「切 Skia 并重启」行显式降级。该行仅在页面判定本次跑
  // Impeller + 渲染 channel 已接线（Android）时接线 onSwitchToSkiaRenderer；此处锁死
  // 「有回调 → 行在 playback 详情渲染且可点触发」「无回调 → 不渲染该行」。
  testWidgets('TODO-1232：提供 onSwitchToSkiaRenderer 时渲染「切 Skia」降级行并可触发',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    int switched = 0;
    await _pumpSheet(tester, onSwitchToSkiaRenderer: () => switched++);

    // 宽窗默认选中 playback 分类，降级行随之渲染。
    final Finder row = find.widgetWithText(
      ListTile,
      t.video_render_skia_fix_title,
    );
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    expect(row, findsOneWidget,
        reason: 'onSwitchToSkiaRenderer 非空时「切 Skia」降级行须在 playback 详情渲染');
    await tester.tap(row);
    await tester.pump();
    expect(switched, 1, reason: '点降级行须触发 onSwitchToSkiaRenderer 回调');
  });

  testWidgets('TODO-1232：onSwitchToSkiaRenderer 为 null 时不渲染「切 Skia」降级行',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpSheet(tester);

    // 默认 playback 详情里倍速行在（证明确在 playback 分类），但降级行不渲染。
    expect(find.text(t.video_setting_speed), findsOneWidget);
    expect(find.text(t.video_render_skia_fix_title), findsNothing,
        reason: '无 onSwitchToSkiaRenderer 回调时不应渲染「切 Skia」降级行');
  });

  // ── TODO-060：字幕调轴（正名 + 滑条 + 数值输入） ───────────────────────────

  test('字幕调轴行用「字幕调轴」名（让用户找得到），不再叫旧的音画延迟', () {
    expect(t.video_setting_av_delay, 'Subtitle sync');
    // hint 明确说明可拖滑条 / 按 ± / 直接输入。
    expect(t.video_setting_av_delay_hint.toLowerCase(), contains('slider'));
    expect(t.video_setting_subtitle_sync_input, 'Offset (ms)');
  });

  testWidgets('字幕调轴提供可拉滑条 + 数值输入框（字幕分类）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpSheet(tester, initialDelayMs: 1200);
    // 字幕调轴已归到「字幕」分类。
    await _tapCategory(tester, 'subtitle', t.video_settings_cat_subtitle);

    // 标题正名为「字幕调轴」。
    expect(find.text(t.video_setting_av_delay), findsOneWidget);

    // 字幕详情里有一条可拉滑条（字幕调轴），把手按当前值定位。
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
    await _pumpSheet(tester, onSetDelay: (int v) => delay = v);
    await _tapCategory(tester, 'subtitle', t.video_settings_cat_subtitle);

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
    await _pumpSheet(tester, onSetDelay: (int v) => delay = v);
    await _tapCategory(tester, 'subtitle', t.video_settings_cat_subtitle);

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

  // ── TODO-413：翻开「自动对轴」按钮（TODO-742 曾临时隐藏，算法管线已就绪）；
  //    手动对轴控件与数字气泡方向（TODO-742②）保持不变 ─────────────

  testWidgets(
    'TODO-413：提供 onAutoAlign 回调时「自动对轴」按钮渲染并可触发回调',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      bool autoAlignCalled = false;
      await _pumpSheet(
        tester,
        onAutoAlign: () async {
          autoAlignCalled = true;
          return null;
        },
      );
      await _tapCategory(tester, 'subtitle', t.video_settings_cat_subtitle);

      // 字幕调轴行存在（手动对轴照常可用）。
      expect(find.text(t.video_setting_av_delay), findsOneWidget);
      final Finder delayRow = find.widgetWithText(
        AdaptiveSettingsRow,
        t.video_setting_av_delay,
      );
      // 手动对轴控件齐全：±50/±1000ms 步进 + 滑条 + 数值输入框都在（不被自动对轴挤掉）。
      expect(
        find.descendant(
            of: delayRow, matching: find.byIcon(Icons.chevron_right)),
        findsOneWidget,
        reason: '+50ms 手动对轴按钮应照常渲染',
      );
      expect(
        find.descendant(of: delayRow, matching: find.byType(Slider)),
        findsOneWidget,
        reason: '手动对轴滑条应照常渲染',
      );
      expect(
        find.descendant(of: delayRow, matching: find.byType(TextField)),
        findsOneWidget,
        reason: '手动对轴数值输入框应照常渲染',
      );

      // 「自动对轴」按钮（auto_fix_high 图标 + 对应 tooltip）现在必须渲染。
      final Finder autoAlignBtn = find.descendant(
        of: delayRow,
        matching: find.byIcon(Icons.auto_fix_high),
      );
      expect(
        autoAlignBtn,
        findsOneWidget,
        reason: 'TODO-413：自动对轴按钮应随 onAutoAlign 回调渲染',
      );

      // 点击触发回调（防重入状态机在 _runAutoAlign 内，回调真被调一次即可）。
      await tester.ensureVisible(autoAlignBtn);
      await tester.tap(autoAlignBtn);
      await tester.pumpAndSettle();
      expect(autoAlignCalled, isTrue,
          reason: 'TODO-413：点击自动对轴按钮应触发 onAutoAlign 回调');
    },
  );

  testWidgets(
    'TODO-1206：自动对轴返回 offset 时同步刷新延迟（滑条/数值/onSetDelay）',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      int? committedDelay;
      await _pumpSheet(
        tester,
        initialDelayMs: 0,
        onSetDelay: (int v) => committedDelay = v,
        // 回调返回算出的整体平移（如互相关求得 +750ms）。
        onAutoAlign: () async => 750,
      );
      await _tapCategory(tester, 'subtitle', t.video_settings_cat_subtitle);

      final Finder delayRow = find.widgetWithText(
        AdaptiveSettingsRow,
        t.video_setting_av_delay,
      );
      final Finder autoAlignBtn = find.descendant(
        of: delayRow,
        matching: find.byIcon(Icons.auto_fix_high),
      );
      await tester.ensureVisible(autoAlignBtn);
      await tester.tap(autoAlignBtn);
      await tester.pumpAndSettle();

      // 回传非 null offset => 经 _commitDelay 写穿 onSetDelay + 同步本地权威值。
      expect(committedDelay, 750,
          reason: 'TODO-1206：自动对轴返回值应经 _commitDelay 写穿 onSetDelay');
      // 数值输入框文本同步到新延迟。
      expect(
        find.descendant(
          of: delayRow,
          matching: find.widgetWithText(TextField, '750'),
        ),
        findsOneWidget,
        reason: 'TODO-1206：数值输入框应同步刷新到自动算出的延迟',
      );
      // 归零标签同步显示 +750 ms（滑条把手 clamp 到端点，标签为权威值）。
      expect(
        find.descendant(of: delayRow, matching: find.text('+750 ms')),
        findsOneWidget,
        reason: 'TODO-1206：延迟标签应刷新到自动算出的延迟',
      );
    },
  );

  testWidgets(
    'TODO-1206：自动对轴返回 null（低置信）时不改延迟',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      int? committedDelay;
      await _pumpSheet(
        tester,
        initialDelayMs: 0,
        onSetDelay: (int v) => committedDelay = v,
        onAutoAlign: () async => null,
      );
      await _tapCategory(tester, 'subtitle', t.video_settings_cat_subtitle);

      final Finder delayRow = find.widgetWithText(
        AdaptiveSettingsRow,
        t.video_setting_av_delay,
      );
      final Finder autoAlignBtn = find.descendant(
        of: delayRow,
        matching: find.byIcon(Icons.auto_fix_high),
      );
      await tester.ensureVisible(autoAlignBtn);
      await tester.tap(autoAlignBtn);
      await tester.pumpAndSettle();

      // 低置信 / noData 回 null => 不调 onSetDelay、延迟保持 0。
      expect(committedDelay, isNull, reason: 'TODO-1206：返回 null 时不应写穿延迟');
      expect(
        find.descendant(of: delayRow, matching: find.text('+0 ms')),
        findsOneWidget,
        reason: 'TODO-1206：返回 null 时延迟标签保持 0',
      );
    },
  );

  testWidgets(
    'TODO-413：onAutoAlign 为 null 时不渲染「自动对轴」按钮（无入口）',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _pumpSheet(tester);
      await _tapCategory(tester, 'subtitle', t.video_settings_cat_subtitle);

      expect(find.text(t.video_setting_av_delay), findsOneWidget);
      expect(
        find.byIcon(Icons.auto_fix_high),
        findsNothing,
        reason: '无 onAutoAlign 回调时不应渲染自动对轴按钮',
      );
    },
  );

  // 稳定 cue helper（波形入口只需非空 cue 列表）。
  AudioCue makeCue(int startMs, int endMs) => AudioCue()
    ..bookKey = ''
    ..chapterHref = ''
    ..sentenceIndex = 0
    ..textFragmentId = ''
    ..text = ''
    ..startMs = startMs
    ..endMs = endMs
    ..audioFileIndex = 0;
  final List<AudioCue> waveCues = <AudioCue>[
    makeCue(1000, 2000),
    makeCue(3000, 4000)
  ];
  const Key waveEntryKey = ValueKey<String>('subtitle-waveform-open-button');

  // TODO-1315 回归守卫（BUG-623）：字幕调轴的「波形对轴」入口在 sheet 集成层
  // 必须可达——有字幕 cue + 可抽波形（本地视频路径 => loadSubtitleWaveform 非空）时，进
  // 「字幕」分类详情就能看到并点到入口按钮。历史上入口曾因挂载时预探测、探测为空即收起
  // 而「进不去」（用户报「字幕调轴入口也没了」）；这里锁死「入口在字幕详情常驻可达」，
  // 且**挂载不预探测**（懒抽保留）。
  testWidgets(
    'TODO-1315 guard: 波形对轴入口在字幕详情可达且挂载不预探测',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      int probes = 0;
      await _pumpSheet(
        tester,
        subtitleWaveformCues: waveCues,
        loadSubtitleWaveform: () async {
          probes++;
          return <double>[-60, -20, -40, -10, -30, -5];
        },
      );

      // 切到「字幕」分类：字幕调轴行 + 波形对轴入口都在，且入口可命中。
      await _tapCategory(tester, 'subtitle', t.video_settings_cat_subtitle);
      expect(find.text(t.video_setting_av_delay), findsOneWidget);
      final Finder entry = find.byKey(waveEntryKey);
      await tester.ensureVisible(entry);
      await tester.pumpAndSettle();
      expect(entry, findsOneWidget, reason: 'TODO-1315：波形对轴入口必须在字幕详情可达');
      // 懒抽保留：挂载 + 单纯可见不得触发 ffmpeg 探测。
      expect(probes, 0, reason: 'TODO-1315：入口挂载/可见不得预探测波形（点击才抽）');
    },
  );

  // TODO-1315 回归守卫：窄窗（移动端）导航路径同样可达——主页点「字幕」分类 push 详情，
  // 详情里能滚到并点到波形对轴入口（移动端正是「进不去」的报障平台）。
  testWidgets(
    'TODO-1315 guard: 窄窗导航到字幕分类后波形对轴入口可达',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _pumpSheet(
        tester,
        subtitleWaveformCues: waveCues,
        loadSubtitleWaveform: () async => <double>[-60, -20, -40, -10, -30, -5],
      );

      // 主页分类导航行 → push 字幕详情。
      await _tapCategory(tester, 'subtitle', t.video_settings_cat_subtitle);
      expect(find.text(t.video_setting_av_delay), findsOneWidget);
      final Finder entry = find.byKey(waveEntryKey);
      await tester.ensureVisible(entry);
      await tester.pumpAndSettle();
      expect(entry, findsOneWidget, reason: 'TODO-1315：窄窗字幕详情里波形对轴入口必须可达');
    },
  );

  test(
    'TODO-742②源码守卫：字幕调轴滑条走 adaptiveSlider（修值指示器气泡方向相反）',
    () {
      // 根因：本面板经 showModalBottomSheet 推入根 Overlay，处在全局 FushiAppUiScale 的
      // Transform.scale 子树。裸 [Slider] 的值指示器水平钳制（getHorizontalShift）把
      // localToGlobal（含 ×scale 的 GLOBAL/view 坐标）与被缩成 view/scale 的
      // MediaQuery.size 比较，两空间差 s²，算出巨大负 shift，把数字气泡甩到拇指**左侧**
      // （用户报「往右调、气泡往左走」方向相反）。[adaptiveSlider] 把 Slider 看到的
      // screenSize 还原回 GLOBAL/view 空间，钳制归零、气泡跟随拇指——其根因修复的运行时
      // 契约由 slider_value_indicator_scale_test.dart 直测。阶段 B：字幕调轴行移入
      // video_subtitle_sync_row.dart，守卫改扫该文件 + 面板相关源文件，防回潮。
      final String syncRow =
          File('lib/src/media/video/video_subtitle_sync_row.dart')
              .readAsStringSync();
      expect(
        syncRow,
        contains('adaptiveSlider('),
        reason: '字幕调轴滑条必须走 adaptiveSlider（UI scale 下值指示器气泡钳制才正确）',
      );
      for (final String path in <String>[
        'lib/src/media/video/video_subtitle_sync_row.dart',
        'lib/src/media/video/video_settings_actions.dart',
        'lib/src/media/video/video_control_layout_editor.dart',
        'lib/src/media/video/video_quick_settings_sheet.dart',
      ]) {
        final String src = File(path).readAsStringSync();
        expect(
          RegExp(r'(?<!adaptive)Slider\(').hasMatch(src),
          isFalse,
          reason: '$path 不得出现裸 Slider(——会让 UI scale 下值指示器气泡甩飞方向相反；'
              '所有滑条须走 adaptiveSlider 或 AdaptiveSettings*Row',
        );
      }
    },
  );

  testWidgets('subtitle sync controls wrap at narrow width and large UI scale',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    int? delay;
    await _pumpSheet(
      tester,
      uiScale: 2.0,
      wrapScale: 2.0,
      onSetDelay: (int v) => delay = v,
    );
    await _tapCategory(tester, 'subtitle', t.video_settings_cat_subtitle);

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
    await _pumpSheet(tester);

    await _tapCategory(tester, 'mpv', t.video_settings_cat_mpv);

    // 音频分组仍在（变速保持音高 / 声道 / 归一化），但不再有音频延迟行。分组标题
    // 限定在设置分区内命中：顶栏「音频」分类 chip 的全文标签（TODO-1351）与 mpv
    // 音频分组同名（英文都是 Audio），不加限定会多命中顶栏 chip。
    expect(
      find.descendant(
        of: find.byType(AdaptiveSettingsSection),
        matching: find.text(t.video_setting_mpv_group_audio),
      ),
      findsOneWidget,
    );
    expect(find.text(t.video_setting_mpv_pitch), findsOneWidget);
  });

  test('源码守卫：mpv 详情不再调音频延迟、字幕调轴提供输入框（TODO-060 防回潮）', () {
    // 阶段 B：mpv 行声明在 settings_schema_video.dart、写穿在
    // video_settings_actions.dart，字幕调轴行在 video_subtitle_sync_row.dart，
    // 守卫按新归属分别扫描。
    final String schema =
        File('lib/src/settings/settings_schema_video.dart').readAsStringSync();
    final String actions =
        File('lib/src/media/video/video_settings_actions.dart')
            .readAsStringSync();
    final String syncRow =
        File('lib/src/media/video/video_subtitle_sync_row.dart')
            .readAsStringSync();
    // mpv 不再有音频延迟入口。
    for (final String src in <String>[schema, actions]) {
      expect(src, isNot(contains('video_setting_mpv_audio_delay')),
          reason: 'mpv「音频延迟」入口必须删除（与字幕调轴对用户重复混淆）');
      expect(src, isNot(contains('copyWith(audioDelayMs:')),
          reason: 'mpv 配置不应再有 audioDelayMs 的 UI 提交路径');
    }
    // 字幕调轴提供滑条 + 数值输入框。
    expect(syncRow, contains('video_setting_subtitle_sync_input'),
        reason: '字幕调轴须有数值输入框');
    expect(syncRow, contains('_commitDelay'), reason: '滑条/按钮/输入框须经统一权威提交');
  });

  // ── TODO-039：倍速改为 MD3 全长滑条（与其它设置滑条同源） ────────────────

  testWidgets('speed row is the shared MD3 slider row (full length)',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpSheet(tester);

    // 倍速行用与其它 MD3 滑条同源的 AdaptiveSettingsSliderRow，范围/步长与旧
    // 分段档位一致（0.5–2.0，0.1 步 = 15 档）。
    final AdaptiveSettingsSliderRow speedRow =
        tester.widget<AdaptiveSettingsSliderRow>(
      find.widgetWithText(AdaptiveSettingsSliderRow, t.video_setting_speed),
    );
    expect(speedRow.min, 0.5);
    expect(speedRow.max, 2.0);
    expect(speedRow.divisions, 15);

    // playback 详情有多条滑条（倍速 + 长按倍速）；定位倍速行内的滑条量宽。
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
    await _pumpSheet(tester, onSetSpeed: (double v) => committed = v);

    // 从中心拖倍速滑条到最右 → 松手提交 2.0（onChangeEnd 路径，0.1 档吸附后无浮点尾差）。
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
    await _pumpSheet(
      tester,
      onPreviewSpeed: previewed.add,
      onSetSpeed: (double v) => committed = v,
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
    // 阶段 B：倍速行声明移入 settings_schema_video.dart（SettingsSliderItem），
    // 守卫改扫 schema 源 + 直接断言数据模型（0.5–2.0、15 档与旧 0.1 步等价）。
    final String src =
        File('lib/src/settings/settings_schema_video.dart').readAsStringSync();
    expect(src, isNot(contains('AdaptiveSettingsSegmentedRow<double>')),
        reason: '倍速不得回退到 16 段 segmented 条');
    expect(src, isNot(contains('_speedPresets')));
    final SettingsSliderItem speed =
        _findSchemaItem('video.player.speed') as SettingsSliderItem;
    expect(speed.min, 0.5);
    expect(speed.max, 2.0);
    expect(speed.divisions, 15, reason: '滑条档位须与旧 0.1 步档位等价');
  });

  test('BUG-963 防回潮：长按倍速滑条声明松手落盘（commitOnRelease）', () {
    // 该值仅在下次长按手势时消费，拖动中写穿无实时收益，反而逐 0.1x 档触发
    // 播放页全页 rebuild 掉帧——数据模型上锁死松手提交语义。
    final SettingsSliderItem item =
        _findSchemaItem('video.playback.long_press_speed')
            as SettingsSliderItem;
    expect(item.commitOnRelease, isTrue, reason: '长按倍速滑条必须拖动本地预览、松手一次性提交');
    expect(item.onChangeEnd, isNull,
        reason: 'commitOnRelease 滑条松手统一走 onChanged，不得另挂 onChangeEnd');
  });

  testWidgets('BUG-963 回归：拖长按倍速滑条不逐 tick 写穿，松手才提交一次', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final List<VideoAsbplayerConfig> commits = <VideoAsbplayerConfig>[];
    await _pumpSheet(tester, onAsbConfigChanged: commits.add);

    final Finder row = find.widgetWithText(
      AdaptiveSettingsSliderRow,
      t.video_setting_long_press_speed,
    );
    final Finder slider =
        find.descendant(of: row, matching: find.byType(Slider));
    await tester.ensureVisible(slider);
    await tester.pumpAndSettle();

    final double before = tester.widget<Slider>(slider).value;
    final TestGesture gesture =
        await tester.startGesture(tester.getCenter(slider));
    // 分多段移动模拟真实拖动的多个 tick。
    for (int i = 0; i < 5; i++) {
      await gesture.moveBy(const Offset(100, 0));
      await tester.pump();
    }

    expect(commits, isEmpty,
        reason: '拖动 tick 不得写穿 asb 配置（BUG-963：逐档写穿致全页 rebuild）');
    expect(tester.widget<Slider>(slider).value, greaterThan(before),
        reason: '拖动中滑块须本地跟手（临时值在渲染层 State，而非落盘回读）');

    await gesture.up();
    await tester.pumpAndSettle();

    expect(commits, hasLength(1), reason: '松手恰好提交一次');
    expect(commits.single.longPressSpeed, 4.0, reason: '拖到最右并 0.1 档吸附后提交 4.0');
  });

  // ── TODO-152 子B：画面缩放/比例设置（窗口 + 全屏 Video fit 同源偏好） ──────

  testWidgets('playback detail shows the picture-fit picker (TODO-152 子B)',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpSheet(tester);

    // 默认进 playback 详情：画面缩放行常驻（三选：占满/适应/拉伸）。
    // picker 行可能为测宽离屏复刻一份标题文本 → findsWidgets。
    expect(find.text(t.video_setting_picture_fit), findsWidgets);
    final AdaptiveSettingsPickerRow<Object> row =
        _pickerRow(tester, t.video_setting_picture_fit);
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
    await _pumpSheet(
      tester,
      onVideoFitModeChanged: (VideoFitMode mode) => picked = mode,
    );

    // 选「适应（加黑边）」= contain → 即时落回调（无保存按钮）。
    final AdaptiveSettingsPickerRow<Object> row =
        _pickerRow(tester, t.video_setting_picture_fit);
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
    await _pumpSheet(tester);

    // 默认进 playback 详情：沉浸模式行常驻，且是下拉单选 picker（与画面缩放同款），
    // 不再是等宽不换行的 4 段 SegmentedButton（窄面板会裁掉尾段，TODO-209）。
    expect(find.text(t.video_setting_immersive_mode), findsWidgets);
    final AdaptiveSettingsPickerRow<Object> row =
        _pickerRow(tester, t.video_setting_immersive_mode);
    // 默认选中「仅查词」（与旧 _sheet 初值一致，经 _pumpSheet 写穿 pref）。
    expect(row.selected, VideoImmersiveMode.lookupOnly);
    // 4 个模式按 enum 顺序全量呈现，一个不少（窄面板曾裁掉尾段的根因已消除）。
    expect(row.options.map((o) => o.value).toList(), VideoImmersiveMode.values);
    // 沉浸模式行不再走 segmented 条（防回潮）。
    expect(
      find.byWidgetPredicate((Widget w) =>
          w is AdaptiveSettingsSegmentedRow &&
          w.title == t.video_setting_immersive_mode),
      findsNothing,
      reason: '沉浸模式不得用会裁长标签的 4 段 SegmentedButton',
    );
  });

  testWidgets('picking an immersive mode drives onImmersiveModeChanged',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    VideoImmersiveMode? picked;
    await _pumpSheet(
      tester,
      onImmersiveModeChanged: (VideoImmersiveMode mode) => picked = mode,
    );

    // 选「全部功能」= full → 即时落回调（无保存按钮）。
    final AdaptiveSettingsPickerRow<Object> row =
        _pickerRow(tester, t.video_setting_immersive_mode);
    row.onChanged(VideoImmersiveMode.full);
    await tester.pump();
    expect(picked, VideoImmersiveMode.full);
  });

  // ── TODO-423：右详情（子设置）pane 不得再叠加不透明背景（用户嫌丑，已删除）──
  // 父/子层级区分改靠分隔线 + 分类选中高亮，详情 pane 不包 ColoredBox 叠加层。

  testWidgets(
      'wide video settings detail pane has no opaque tint overlay '
      '(TODO-423)', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpSheet(tester);

    // 详情 pane 的 KeyedSubtree 不再被任何 0<alpha<1 的半透明 ColoredBox 包裹
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
          reason: '详情 pane 不应被半透明叠加色 ColoredBox 包裹（TODO-423）');
    }
  });

  // ── TODO-344：四边 padding 按 MD3 spacing 放宽，消除「贴死」 ──────────────

  testWidgets(
      'wide video settings uses roomy MD3 padding on all four edges '
      '(TODO-344 / TODO-556)', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpSheet(tester);

    // 顶部分类 chip 条外层 Padding：水平 inset = page+gap=28，顶部 card=20（不再贴死），
    // 底部留 gap/2=4 与下方分隔线呼吸。chip 条本身是横向 scroll（无 padding 属性），
    // 故 padding 落在它外层那个 Padding widget 上，按值精确定位。
    final Finder firstCategoryChip = find.byType(FushiSelectableChip).first;
    final Iterable<Padding> categoryPads = tester.widgetList<Padding>(
      find.ancestor(
        of: firstCategoryChip,
        matching: find.byType(Padding),
      ),
    );
    final Padding categoryOuterPad = categoryPads.firstWhere((Padding p) {
      final EdgeInsets? e = p.padding as EdgeInsets?;
      return e != null && e.left == 28 && e.top == 20 && e.bottom == 4;
    });
    final EdgeInsets categoryPadding = categoryOuterPad.padding as EdgeInsets;
    expect(categoryPadding.left, 28);
    expect(categoryPadding.right, 28);
    expect(categoryPadding.top, 20);
    expect(categoryPadding.bottom, 4);

    // 下方详情（纵向 SingleChildScrollView，KeyedSubtree 内）：水平 inset 同 28、独占整宽。
    // picker 离屏 dropdown 测量树里也有无 padding 的 scroll，按「padding.left==28 的纵向
    // scroll」精确定位详情那一个。
    final SingleChildScrollView detailScroll = tester
        .widgetList<SingleChildScrollView>(
      find.byType(SingleChildScrollView),
    )
        .lastWhere((SingleChildScrollView s) {
      final EdgeInsets? p = s.padding as EdgeInsets?;
      return s.scrollDirection == Axis.vertical && p != null && p.left == 28;
    });
    final EdgeInsets primaryPadding = detailScroll.padding! as EdgeInsets;
    expect(primaryPadding.left, 28);
    expect(primaryPadding.right, 28);
    expect(primaryPadding.top, 20);
  });

  testWidgets('narrow video settings uses roomy MD3 padding (TODO-344)',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpSheet(tester);

    // 窄窗主页同样用放宽后的 padding（顶部 >= 20，不再贴死）。窄窗 body 的最外层
    // SingleChildScrollView 承载本功能的 padding（内部组件可能另有自己的 scroll，故取 first）。
    final SingleChildScrollView scroll = tester.widget<SingleChildScrollView>(
        find.byType(SingleChildScrollView).first);
    final EdgeInsets padding = scroll.padding! as EdgeInsets;
    expect(padding.left, 28);
    expect(padding.right, 28);
    expect(padding.top, 20);
  });

  // ── TODO-470：设置页内控制按钮编辑器使用播放器方位预览舞台 ─
  group('control button editor stage (TODO-470)', () {
    // 进入控制分类详情（宽窗上下分栏顶部 chip 行）。「控制」是末位分类，在窄宽窗下
    // 横向 chip 行里可能排到视口外（TODO-427-③），先横滑入视口再点（模拟真实用户横滑）。
    Future<void> openControls(WidgetTester tester) async {
      // 分类 chip 经 id key 命中（_tapCategory 自动处理宽窗顶栏 chip / 窄窗 push
      // 导航行两端）。
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
      await _pumpSheet(tester);
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
      await _pumpSheet(tester);
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
      await _pumpSheet(tester);
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
        await _pumpSheet(
          tester,
          uiScale: sizeCase.scale,
          wrapScale: sizeCase.scale,
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
      await _pumpSheet(
        tester,
        uiScale: 2.0,
        wrapScale: 2.0,
        onControlLayoutChanged: (VideoControlLayout layout) {
          latest = layout;
        },
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
      await _pumpSheet(
        tester,
        onControlLayoutChanged: (VideoControlLayout layout) {
          latest = layout;
        },
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
      await _pumpSheet(
        tester,
        onControlLayoutChanged: (VideoControlLayout layout) {
          latest = layout;
        },
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
      await _pumpSheet(
        tester,
        isTouchControls: true,
        onControlLayoutChanged: (VideoControlLayout layout) {
          latest = layout;
        },
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
      await _pumpSheet(
        tester,
        onControlLayoutChanged: (VideoControlLayout layout) {
          latest = layout;
        },
      );
      await openControls(tester);

      // TODO-1098：bottomCenter 默认布局插入了 frameBackward（index 1）+ frameForward，
      // 令 playPause 从 index 2 后移到 index 3（顺序：seekBackward, frameBackward,
      // previousCue, playPause, nextCue, frameForward, seekForward）。
      await dragChipTo(
        tester,
        dragChipFinder(
            VideoControlItem.playPause, VideoControlSlot.bottomCenter, 3),
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
      await _pumpSheet(
        tester,
        onControlLayoutChanged: (VideoControlLayout layout) {
          latest = layout;
        },
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
      await _pumpSheet(
        tester,
        onControlLayoutChanged: (VideoControlLayout layout) {
          latest = layout;
        },
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
      await _pumpSheet(
        tester,
        onControlLayoutChanged: (VideoControlLayout layout) {
          latest = layout;
        },
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
      // 阶段 B：控制编辑器移入 video_control_layout_editor.dart
      // （VideoControlLayoutEditor），守卫改扫该文件。
      final String src =
          File('lib/src/media/video/video_control_layout_editor.dart')
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
      await _pumpSheet(tester);

      // 大分类一律渲染成顶栏 chip（无左右 master-detail、无左栏列表项），按 id
      // key 命中（不依赖标签文案）。
      expect(find.byType(MaterialSupportingPaneLayout), findsNothing);
      expect(find.byType(FushiListItem), findsNothing);
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

      // 选「mpv」分类（顶栏 chip）→ 下方详情切到 mpv 详情，无 push 返回箭头。
      // TODO-1351 全文标签把顶栏撑宽，末位分类可能在视口外，先横滑入视口再点。
      await tester.ensureVisible(_categoryChip('mpv'));
      await tester.pumpAndSettle();
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
          reason: '宽窗分类须经顶栏 chip 构建器渲染');
      expect(src, isNot(contains('MaterialSupportingPaneLayout(')),
          reason: '视频设置宽窗不得再回退到左右 master-detail（书籍设置才用它）');
      expect(src, isNot(contains('_buildWidePane(')),
          reason: '旧左栏构建器 _buildWidePane 必须删除');
      // TODO-1351（用户复诉）：顶栏 chip 恢复「图标 + 完整文字」标签，按固有宽度完整
      // 渲染（allowLabelOverflow，无 ellipsis），放不下由横滑条兜底；TODO-640 的
      // 纯图标 + tooltip 方案废弃，不得回退。
      expect(src, contains('allowLabelOverflow: true'),
          reason: '顶栏分类 chip 标签须完整渲染不省略（TODO-1351）');
      expect(src, isNot(contains('iconOnly: true')),
          reason: '顶栏分类 chip 不得退回仅图标模式（TODO-1351 用户复诉）');
      expect(src, contains('_buildWideDetailTitle('),
          reason: '宽窗详情顶部须渲染当前分类标题（详情区页头）');
      // BUG（末位分类被裁）：顶栏须用 Wrap 换行堆叠，不得回退横向 SingleChildScrollView
      // 裁断（旧实现把「弹幕 / 控制」推到视口外，用户看不全也点不到）。
      final String barSrc = src.substring(
        src.indexOf('Widget _buildTopCategoryBar('),
        src.indexOf('Widget _buildWideDetailTitle('),
      );
      expect(barSrc, contains('Wrap('),
          reason: '顶栏分类条须用 Wrap 换行堆叠（放不下自动折行，不裁断）');
      expect(barSrc, isNot(contains('scrollDirection: Axis.horizontal')),
          reason: '顶栏分类条不得回退横向滚动（会把末位分类裁到视口外）');
    });

    testWidgets('BUG（顶栏末位分类被裁）：窄宽窗顶栏 chip 换行堆叠，7 个分类全部可见不被右裁', (tester) async {
      // 宽窗阈值 560×440；取 620 宽——进宽窗分支，但 7 个「图标 + 完整文字」chip 一行
      // 装不下。旧横向滚动实现会把末位「弹幕 / 控制」推到视口右侧外裁掉；Wrap 换行后全可见。
      await tester.binding.setSurfaceSize(const Size(620, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _pumpSheet(tester);

      const List<String> ids = <String>[
        'playback',
        'audio',
        'subtitle',
        'shaders',
        'mpv',
        'danmaku',
        'controls',
      ];
      for (final String id in ids) {
        expect(_categoryChip(id), findsOneWidget, reason: '$id chip 必须在顶栏渲染');
      }

      // 末位分类「控制」的右缘不得超出面板宽度（不被横向裁到视口外）。
      final Rect controls = tester.getRect(_categoryChip('controls'));
      expect(controls.right, lessThanOrEqualTo(620.0),
          reason: '末位分类 chip 不得被裁到视口右侧外（须换行，而非横向滚动裁断）');

      // 一行放不下 → 换行：末位「控制」应落到比首位「播放」更低的行（dy 更大）。
      final double playbackTop =
          tester.getTopLeft(_categoryChip('playback')).dy;
      final double controlsTop =
          tester.getTopLeft(_categoryChip('controls')).dy;
      expect(controlsTop, greaterThan(playbackTop),
          reason: '装不下时顶栏必须换行堆叠（Wrap），末位分类落到下一行');

      _expectNoFlutterErrors(tester);
    });
  });

  // ── TODO-1350 / TODO-1351：检查器式整合（视频/音频/字幕 tab + 轨切换收进面板 +
  //    字幕颜色/背景可调；视频主题行已按用户诉求移除） ─────────────────────────
  group('TODO-1350/1351 inspector consolidation', () {
    testWidgets('TODO-1351：顶栏含 视频/音频/字幕（playback/audio/subtitle）tab chips',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _pumpSheet(tester);
      // 参考「检查器」的 视频 / 音频 / 字幕 tab 都在顶栏（按 id key 命中 chip）。
      expect(_categoryChip('playback'), findsOneWidget);
      expect(_categoryChip('audio'), findsOneWidget, reason: '音频 tab 必须存在');
      expect(_categoryChip('subtitle'), findsOneWidget);
    });

    testWidgets('TODO-1351：音频分类展示传入的音轨切换区（取代外面浮的音轨侧栏）', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _pumpSheet(
        tester,
        audioTrackSection: const Text('AUDIO_TRACK_SECTION_MARKER'),
      );
      await _tapCategory(tester, 'audio', t.video_settings_cat_audio);
      expect(find.text('AUDIO_TRACK_SECTION_MARKER'), findsOneWidget,
          reason: '音频分类须渲染页面传入的音轨切换区');
    });

    testWidgets('TODO-1351：无音轨切换区时音频分类显示占位', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _pumpSheet(tester);
      await _tapCategory(tester, 'audio', t.video_settings_cat_audio);
      expect(find.text(t.video_audio_track_empty), findsOneWidget);
    });

    testWidgets('TODO-1351：字幕分类顶部展示字幕轨切换区，位于外观设置之上（外挂字幕→打开字幕）', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _pumpSheet(
        tester,
        subtitleTrackSection: const Text('SUBTITLE_TRACK_SECTION_MARKER'),
      );
      await _tapCategory(tester, 'subtitle', t.video_settings_cat_subtitle);
      final Finder marker = find.text('SUBTITLE_TRACK_SECTION_MARKER');
      expect(marker, findsOneWidget, reason: '字幕分类须渲染页面传入的字幕轨切换区');
      // 字幕轨切换区在字幕外观（字号）之上（参考「检查器」字幕 tab 结构）。
      final double trackY = tester.getTopLeft(marker).dy;
      final double fontSizeY =
          tester.getTopLeft(find.text(t.video_setting_subtitle_font_size)).dy;
      expect(trackY, lessThan(fontSizeY), reason: '字幕轨切换区须在字幕外观设置之上');
    });

    testWidgets('TODO-1351：initialCategory 直接把面板开在目标分类（窄窗 push 音频）',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _pumpSheet(tester, initialCategory: 'audio');
      // 窄窗直接 push 到「音频」子页：子页标题 + 返回箭头 + 占位（无 section 时）。
      expect(find.text(t.video_settings_cat_audio), findsWidgets);
      expect(find.byIcon(Icons.arrow_back), findsOneWidget);
      expect(find.text(t.video_audio_track_empty), findsOneWidget);
    });

    // 主题切换行已从视频设置移除（用户诉求「哪有单独的一个主题的说法」）：主题属于全局
    // 「外观」设置，视频画面自动继承 app 主题（含自定义主题），不在视频面板重复暴露一套。
    testWidgets('视频设置不再单列主题切换行（主题归全局「外观」）', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _pumpSheet(tester);
      // 播放分类默认选中；遍历所有分类都不应出现「视频主题」行。
      for (final ({String id, String label}) cat
          in <({String id, String label})>[
        (id: 'playback', label: t.video_settings_cat_playback),
        (id: 'subtitle', label: t.video_settings_cat_subtitle),
      ]) {
        await _tapCategory(tester, cat.id, cat.label);
        expect(find.text(t.video_setting_theme), findsNothing,
            reason: '${cat.id} 分类不应出现视频主题切换行（主题归全局外观）');
      }
    });

    testWidgets('TODO-1350：字幕文字颜色 + 背景颜色在字幕设置里可调', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final List<VideoSubtitleStyle> commits = <VideoSubtitleStyle>[];
      await _pumpSheet(tester, onSubtitleStyleCommit: commits.add);
      await _tapCategory(tester, 'subtitle', t.video_settings_cat_subtitle);
      // 字幕文字颜色（TODO-1326）+ 背景颜色（TODO-1059）选择行都在字幕外观里。
      expect(find.text(t.video_setting_subtitle_text_color), findsWidgets,
          reason: '字幕文字颜色须可调');
      expect(find.text(t.video_setting_subtitle_bg_color), findsWidgets,
          reason: '字幕背景颜色须可调');
    });

    test('源码守卫：设置面板含音频分类 + 轨接线 + 主题行已移除（TODO-1351）', () {
      // 阶段 B retarget：分类外壳在 sheet，轨切换区声明在 schema（item id）+
      // 写穿/builder 在 actions；主题行既不得回潮进 schema 也不得回潮进 sheet。
      final String sheet =
          File('lib/src/media/video/video_quick_settings_sheet.dart')
              .readAsStringSync();
      final String schema = File('lib/src/settings/settings_schema_video.dart')
          .readAsStringSync();
      final String actions =
          File('lib/src/media/video/video_settings_actions.dart')
              .readAsStringSync();
      // 视频/音频/字幕 tab：音频分类（sheet 外壳，审查 Finding 9 后分类由
      // VideoGroup 枚举驱动，源码影子是 exhaustive switch 分支）+ 轨切换区 schema 条目。
      expect(sheet, contains('case VideoGroup.audio:'),
          reason: '顶栏须含「音频」分类（收音频轨切换）');
      expect(schema, contains("id: 'video.player.audio_track'"),
          reason: '音频轨切换区须以 schema 条目声明在「音频」分类');
      expect(schema, contains("id: 'video.player.subtitle_track'"),
          reason: '字幕轨切换区须以 schema 条目声明在「字幕」分类');
      // 轨切换区接线（builder 经 host 读页面构建的 section）。
      expect(actions, contains('host.audioTrackSection'),
          reason: '音频分类须渲染页面传入的音轨切换区');
      expect(actions, contains('subtitleTrackSection'),
          reason: '字幕分类须渲染页面传入的字幕轨切换区');
      // 主题切换行已移除：主题归全局「外观」设置，视频画面继承 app 主题，不在此重复暴露。
      for (final String src in <String>[sheet, schema, actions]) {
        expect(src, isNot(contains('video_setting_theme')),
            reason: '视频设置不应再有独立主题切换行（主题归全局外观）');
        expect(src, isNot(contains('onSelectThemeKey')),
            reason: '主题切换回调应随主题行一并移除');
        expect(src, isNot(contains('VideoThemeOption')),
            reason: '视频主题选项模型应随主题行一并移除');
      }
      // 字幕颜色/背景（TODO-1350）可调（builder 在 actions）。
      expect(actions, contains('video_setting_subtitle_text_color'),
          reason: '字幕文字颜色须可调');
      expect(actions, contains('video_setting_subtitle_bg_color'),
          reason: '字幕背景颜色须可调');
    });

    // 字幕调轴 + 句尾自动暂停已按语义归到「字幕」分类（用户诉求）：两者都是字幕驱动的
    // 行为，之前误挂在「播放」。阶段 B：分组不再是手写 _build*Detail 方法，而是 schema
    // 声明的 VideoPlacement.group——直接在数据模型上守住归位不回潮。
    test('数据模型守卫：字幕调轴 + 句尾自动暂停在字幕分类，倍速在播放分类', () {
      expect(
        _findSchemaItem('video.player.subtitle_sync').video!.group,
        VideoGroup.subtitle,
        reason: '字幕调轴须归到字幕分类',
      );
      expect(
        _findSchemaItem('video.playback.pause_at_subtitle_end').video!.group,
        VideoGroup.subtitle,
        reason: '句尾自动暂停须归到字幕分类',
      );
      expect(
        _findSchemaItem('video.player.speed').video!.group,
        VideoGroup.playback,
        reason: '倍速仍属播放分类',
      );
    });

    test('源码守卫：外面浮的音轨/字幕轨侧栏已删，按钮改开设置面板对应 tab（TODO-1351）', () {
      final String sidePanel = File(
        'lib/src/pages/implementations/video_hibiki/side_panel.part.dart',
      ).readAsStringSync();
      final String audioTrack = File(
        'lib/src/pages/implementations/video_hibiki/audio_track.part.dart',
      ).readAsStringSync();
      final String subtitle = File(
        'lib/src/pages/implementations/video_hibiki/subtitle.part.dart',
      ).readAsStringSync();
      // 浮动轨切换器（audioTracks / subtitleSources 两个 side-panel kind + builder）已删。
      expect(sidePanel, isNot(contains('_VideoSidePanelKind.audioTracks')),
          reason: '浮动音轨侧栏 kind 必须删除（音频轨收进设置面板「音频」分类）');
      expect(sidePanel, isNot(contains('_VideoSidePanelKind.subtitleSources')),
          reason: '浮动字幕轨侧栏 kind 必须删除（字幕轨收进设置面板「字幕」分类）');
      expect(audioTrack, isNot(contains('_buildAudioTracksSidePanel')),
          reason: '浮动音轨侧栏构建器必须删除');
      expect(subtitle, isNot(contains('_buildSubtitleSourcesSidePanel')),
          reason: '浮动字幕轨侧栏构建器必须删除');
      // 音频轨/字幕轨按钮改为把设置面板开在对应 tab（功能收进不丢）。
      expect(audioTrack, contains("initialCategory: 'audio'"),
          reason: '音频轨按钮须打开设置面板「音频」分类');
      expect(subtitle, contains("initialCategory: 'subtitle'"),
          reason: '字幕轨按钮须打开设置面板「字幕」分类');
      // 轨切换区仍由页面构建（功能不丢）。
      expect(audioTrack, contains('_buildAudioTrackSettingsSection('),
          reason: '音轨切换区须仍由页面构建（收进面板不丢功能）');
      expect(subtitle, contains('_buildSubtitleTrackSettingsSection('),
          reason: '字幕轨切换区须仍由页面构建（收进面板不丢功能）');
    });

    test('BUG-672 源码守卫：副字幕改内联可展开区，不再跳独立浮层窗口', () {
      final String sidePanel = File(
        'lib/src/pages/implementations/video_hibiki/side_panel.part.dart',
      ).readAsStringSync();
      final String subtitle = File(
        'lib/src/pages/implementations/video_hibiki/subtitle.part.dart',
      ).readAsStringSync();
      final String page = File(
        'lib/src/pages/implementations/video_hibiki_page.dart',
      ).readAsStringSync();
      // 副字幕浮层 kind 已删（连同 title/width/child 三个 switch 分支）。
      expect(page, isNot(contains('  secondarySubtitleSources,')),
          reason: '副字幕浮层 _VideoSidePanelKind.secondarySubtitleSources 必须删除');
      expect(sidePanel,
          isNot(contains('_VideoSidePanelKind.secondarySubtitleSources')),
          reason: '副字幕浮层 side-panel 分支必须删除（副字幕改内联）');
      // 副字幕不再经 _showVideoSidePanel 跳独立窗口；旧的导航式菜单方法删除。
      expect(subtitle, isNot(contains('_showSecondarySubtitleSourceMenu')),
          reason: '副字幕跳浮层的 _showSecondarySubtitleSourceMenu 必须删除');
      expect(
          subtitle, isNot(contains('_buildSecondarySubtitleSourcesSidePanel')),
          reason: '副字幕浮层侧栏构建器必须删除（改内联行构建器）');
      // 副字幕源改为在「字幕」分类里内联可展开（ExpansionTile + 行构建器）。
      expect(subtitle, contains('ExpansionTile('),
          reason: '副字幕入口须是内联可展开区（ExpansionTile），就地切换不跳窗口');
      expect(subtitle, contains('_buildSecondarySubtitleRows('),
          reason: '副字幕源行改由内联行构建器 _buildSecondarySubtitleRows 渲染');
    });

    test('BUG-672 源码守卫：字幕分类被打开时驱动字幕源枚举（字幕轨即时加载）', () {
      final String subtitle = File(
        'lib/src/pages/implementations/video_hibiki/subtitle.part.dart',
      ).readAsStringSync();
      final String page = File(
        'lib/src/pages/implementations/video_hibiki_page.dart',
      ).readAsStringSync();
      final String sheet = File(
        'lib/src/media/video/video_quick_settings_sheet.dart',
      ).readAsStringSync();
      // 阶段 B：onSubtitleCategoryShown 回调声明移入类型化能力槽
      // VideoQuickSettingsHost（video_quick_settings_host.dart）。
      final String host = File(
        'lib/src/media/video/video_quick_settings_host.dart',
      ).readAsStringSync();
      // 视频页把「进入字幕分类」回调接到字幕源枚举 helper。
      expect(page,
          contains('onSubtitleCategoryShown: _ensureSubtitleMenuSourcesLoaded'),
          reason:
              '视频页须把 onSubtitleCategoryShown 接到 _ensureSubtitleMenuSourcesLoaded');
      expect(
          subtitle, contains('Future<void> _ensureSubtitleMenuSourcesLoaded()'),
          reason: '须有按「进入字幕分类」事件驱动的字幕源枚举 helper');
      expect(subtitle, contains('_subtitleSourcesForMenu('),
          reason: '字幕源枚举 helper 须走 _subtitleSourcesForMenu 枚举内嵌轨 + 外挂');
      // 面板进入字幕分类（chip / 导航行 / initialCategory）统一触发回调。
      expect(host, contains('final VoidCallback? onSubtitleCategoryShown;'),
          reason: '能力槽须暴露 onSubtitleCategoryShown 回调');
      expect(sheet, contains('void _selectSubPage(String id)'),
          reason: '分类切换须集中到 _selectSubPage，进入字幕分类时触发回调');
      expect(sheet, contains('_notifySubtitleCategoryShownAfterFrame()'),
          reason: 'initialCategory==subtitle 直达时须帧后触发回调');
    });
  });
}
