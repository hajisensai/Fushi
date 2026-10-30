import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/src/media/video/subtitle_style_preview.dart';
import 'package:fushi/src/media/video/video_quick_settings_host.dart';
import 'package:fushi/src/media/video/video_settings_actions.dart'
    show videoQuickSettingsHostOf;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/settings/glass_settings_renderer.dart';
import 'package:fushi/src/settings/master_detail_settings_sheet.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_renderer.dart';
import 'package:fushi/src/settings/settings_schema.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/utils.dart';

/// 视频设置面板是否走手机紧凑档（窗口最短边 < 600：手机竖屏与横屏）。紧凑档左右
/// 留白收到 16、整块面板收一档密度与字号（[videoQuickSettingsCompactTheme]）。
bool videoQuickSettingsCompact(Size window) => window.shortestSide < 600;

/// 紧凑档主题：字阶整体缩到 0.92（反馈 nGxUGtYot9：手机上「文字小
/// 一点」）。只在面板子树内生效，按比例缩、不写死字号，用户的系统字号缩放照常叠加。
ThemeData videoQuickSettingsCompactTheme(ThemeData base) {
  TextStyle? shrink(TextStyle? style) {
    final double? size = style?.fontSize;
    if (style == null || size == null) return style;
    return style.copyWith(fontSize: size * 0.92);
  }

  final TextTheme tt = base.textTheme;
  return base.copyWith(
    textTheme: tt.copyWith(
      displayLarge: shrink(tt.displayLarge),
      displayMedium: shrink(tt.displayMedium),
      displaySmall: shrink(tt.displaySmall),
      headlineLarge: shrink(tt.headlineLarge),
      headlineMedium: shrink(tt.headlineMedium),
      headlineSmall: shrink(tt.headlineSmall),
      titleLarge: shrink(tt.titleLarge),
      titleMedium: shrink(tt.titleMedium),
      titleSmall: shrink(tt.titleSmall),
      bodyLarge: shrink(tt.bodyLarge),
      bodyMedium: shrink(tt.bodyMedium),
      bodySmall: shrink(tt.bodySmall),
      labelLarge: shrink(tt.labelLarge),
      labelMedium: shrink(tt.labelMedium),
      labelSmall: shrink(tt.labelSmall),
    ),
  );
}

/// 视频播放设置面板（阶段 B：schema 投影版）：所有配置行都来自
/// settings_schema_video.dart 的单一声明，按 [VideoPlacement] group/order/section
/// 经 [buildVideoGroupDestination] 投影渲染（与阅读器面板消费 [ReaderPlacement]
/// 同款）；控制器绑定行经 [VideoQuickSettingsHost] 门控只在此出现。
///
/// 外壳（2026-10 重设计，对齐阅读器「阅读设置」面板）：顶部一排分类页签
/// （[LibrarySectionTabs]，与阅读器 / 库页同一个分区导航组件）+ 下方当前分类内容，
/// 手机与桌面同一结构——不再有窄窗「分类列表 → push 子页」两级，也不再有带徽标的
/// 大标题页头。手机（[videoQuickSettingsCompact]）收紧留白与字号；面板外壳在手机
/// 竖屏是贴底面板、其余是侧板（[VideoTranslucentSidePanel]）。
///
/// 外壳是播放器的浮动侧板（[VideoTranslucentSidePanel]）：M3 Expressive 下面板是
/// 无色相中性深色表面，内部控件读面板中性主题（灰阶分组卡、白字、开关 / 选中态
/// 仍是 app 主色，见 video_m3e_panel_theme.dart）；Apple 是液态玻璃厚档。
class VideoQuickSettingsSheet extends StatefulWidget {
  const VideoQuickSettingsSheet({
    required this.appModel,
    required this.ref,
    required this.host,
    this.initialCategory,
    this.groups = VideoQuickSettingsSheet.settingsGroups,
    super.key,
  });

  /// 「设置」面板的分类：字幕 / 音频已拆成独立面板（面板切换条上与章节、画质
  /// 并列），不在这里重复。
  static const List<VideoGroup> settingsGroups = <VideoGroup>[
    VideoGroup.playback,
    VideoGroup.shaders,
    VideoGroup.mpv,
    VideoGroup.danmaku,
    VideoGroup.controls,
  ];

  /// 本面板展示的分组；只有一个时不画顶部页签（字幕 / 音频面板）。
  final List<VideoGroup> groups;

  final AppModel appModel;

  /// Riverpod ref from the video page, forwarded to the schema-projected
  /// settings so [SettingsContext] always has a real [WidgetRef].
  final WidgetRef ref;

  /// 播放页能力槽：schema 投影项经它读页面权威值 / 回调持久化 + 实时应用。
  final VideoQuickSettingsHost host;

  /// TODO-1351：打开面板时直接定位到某个分类（`audio` / `subtitle` / ...）。null =
  /// 用默认 `playback`。由「音频轨」「字幕轨」按钮驱动，把
  /// 原来「外面浮的轨切换器」收进本面板对应 tab。
  final String? initialCategory;

  @override
  State<VideoQuickSettingsSheet> createState() =>
      _VideoQuickSettingsSheetState();
}

class _VideoQuickSettingsSheetState extends State<VideoQuickSettingsSheet>
    with
        SettingsContextHost<VideoQuickSettingsSheet>,
        TickerProviderStateMixin<VideoQuickSettingsSheet> {
  /// 当前分类 id；null = 默认（playback）。TODO-1351：初值取 [VideoQuickSettingsSheet.initialCategory]，让「音频轨/字幕轨」
  /// 按钮直接把面板开在对应分类。
  late String? _subPage = widget.initialCategory;

  /// 用户在面板内切过分类：此后切换时内容错峰进场（首次打开不放）。
  bool _categorySwitched = false;

  /// 页签与下方分页共用的 controller（与阅读器「阅读设置」侧板同一形态）：点页签
  /// 与左右横滑切页走同一条路，横滑时指示条跟手。分组不止一个时才有。
  TabController? _tabController;

  /// 当前分类在 [VideoQuickSettingsSheet.groups] 里的下标（未知 id 退回首个）。
  int _indexOf(String? id) {
    final int i = widget.groups.indexWhere((VideoGroup g) => g.name == id);
    return i < 0 ? 0 : i;
  }

  TabController? _ensureTabController() {
    if (widget.groups.length <= 1) return null;
    final TabController? existing = _tabController;
    if (existing != null && existing.length == widget.groups.length) {
      return existing;
    }
    existing?.dispose();
    final TabController controller = TabController(
      length: widget.groups.length,
      initialIndex: _indexOf(_subPage),
      animationDuration: fushiMotionDuration(context, FushiMotion.medium),
      vsync: this,
    );
    controller.addListener(() {
      // 点页签时动画开始、结束各通知一次，只认落定后那次；横滑切页只通知落定。
      if (controller.indexIsChanging) return;
      final String id = widget.groups[controller.index].name;
      if (id != _subPage) _selectSubPage(id);
    });
    return _tabController = controller;
  }

  @override
  void dispose() {
    _tabController?.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // TODO-1350：直接开在「字幕」分类（如「字幕轨」按钮驱动 initialCategory=='subtitle'）时，
    // 挂载即触发一次字幕源加载回调（延后到帧后，避免在 initState 阶段同步触发父页 setState）。
    if (widget.initialCategory == 'subtitle') {
      _notifySubtitleCategoryShownAfterFrame();
    }
  }

  @override
  void didUpdateWidget(VideoQuickSettingsSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    // TODO-1351：面板已开着时用户又点了「音频轨/字幕轨」按钮 → initialCategory 变化，
    // 跳到目标分类。只在收到「新的、非空」目标时强跳，避免覆盖用户在面板内的手动导航
    // （同值 rebuild 不触发，保留用户当前所在分类）。
    if (widget.initialCategory != null &&
        widget.initialCategory != oldWidget.initialCategory) {
      _subPage = widget.initialCategory;
      final TabController? controller = _tabController;
      final int target = _indexOf(_subPage);
      if (controller != null &&
          controller.length == widget.groups.length &&
          controller.index != target) {
        controller.index = target;
      }
      // TODO-1350：面板已开着时用户又点「字幕轨」按钮（initialCategory 变成 'subtitle'）→
      // 触发字幕源加载回调（延后到帧后）。
      if (widget.initialCategory == 'subtitle') {
        _notifySubtitleCategoryShownAfterFrame();
      }
    }
  }

  /// TODO-1350：触发「进入字幕分类」回调，让视频页枚举字幕源填字幕轨切换区。延后到当前
  /// 帧结束再调，避免在 build / initState / didUpdateWidget 期间同步触发父页面 setState。
  void _notifySubtitleCategoryShownAfterFrame() {
    final VoidCallback? cb = widget.host.onSubtitleCategoryShown;
    if (cb == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) cb();
    });
  }

  /// 切换分类子页（页签点击 / 左右横滑共用，都经 [_tabController] 落到这里）；进入「字幕」分类时触发字幕源加载回调
  /// （TODO-1350），统一两个入口，避免「切到字幕分类却没加载字幕轨」的入口遗漏。
  void _selectSubPage(String id) {
    final bool enteringSubtitle = id == 'subtitle' && _subPage != 'subtitle';
    setState(() {
      _subPage = id;
      _categorySwitched = true;
    });
    if (enteringSubtitle) {
      widget.host.onSubtitleCategoryShown?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<VideoGroup> groups = widget.groups;
    final String selectedId = groups.any((VideoGroup g) => g.name == _subPage)
        ? _subPage!
        : groups.first.name;
    final TabController? tabController = _ensureTabController();
    final bool compact = videoQuickSettingsCompact(MediaQuery.sizeOf(context));
    // 手机（最短边 < 600）：左右收到 page - gap/2（16，与阅读器导航页同档），
    // 桌面保留 page + gap（28）。
    final double horizontal = compact
        ? tokens.spacing.page - tokens.spacing.gap / 2
        : tokens.spacing.page + tokens.spacing.gap;
    // 页签轨道（M3E 分段胶囊）与下方设置分组卡同一左右缘。
    final double tabsInset = horizontal;
    final Widget body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 顶部分类页签：与阅读器「阅读设置」面板、库页同一个分区导航组件
        // （[LibrarySectionTabs]）——整排是单个焦点停靠点（方向键 / 手柄左右切页），
        // 按文案取宽、放不下横向滚动（选中段自动滚入可见区）；与下方 TabBarView
        // 共用同一个 controller，左右横滑内容区切页、指示条跟手。
        if (tabController != null)
          Padding(
            padding: EdgeInsetsDirectional.only(
              start: tabsInset,
              end: tabsInset,
              top: compact ? 0 : tokens.spacing.gap,
            ),
            child: LibrarySectionTabs<String>.controlled(
              key: const ValueKey<String>('video-settings-tabs'),
              tabs: <LibrarySectionTab<String>>[
                for (final ({String id, String label}) cat in _categories())
                  LibrarySectionTab<String>(
                    value: cat.id,
                    label: cat.label,
                    // 稳定 key：测试 / 焦点驱动靠 id 命中分类（不依赖标签文案）。
                    labelKey: ValueKey<String>('video-settings-cat-${cat.id}'),
                  ),
              ],
              controller: tabController,
              focusIdPrefix: 'video-settings-tab',
              // 摆得下时铺满面板宽度、各段等分（2026-10-30 用户「顶部栏改为全宽」）；
              // 放不下时退回横向滚动（选中段自动滚入可见区），不收进「更多」菜单：
              // 七个分类都是一级入口，横滑一下就能看到。
              fill: true,
              overflowMenu: false,
            ),
          ),
        if (isEinkTheme(context))
          FushiDividerControl(
            height: 1,
            thickness: 1,
            color: isCupertinoPlatform(context)
                ? CupertinoColors.separator.resolveFrom(context)
                : tokens.surfaces.outline,
          ),
        // 分类内容：每页一个独立滚动视图（PageStorageKey 记住各自滚动位置），
        // 左右横滑切页（与阅读器设置面板同款 TabBarView）；单分组面板（字幕 /
        // 音频）没有页签，直接就是那一页。
        Expanded(
          child: tabController == null
              ? _buildCategoryPage(selectedId, compact, horizontal)
              : TabBarView(
                  controller: tabController,
                  children: <Widget>[
                    for (final VideoGroup group in groups)
                      _buildCategoryPage(group.name, compact, horizontal),
                  ],
                ),
        ),
      ],
    );
    // 手机：整块面板收一档密度与字号（反馈 nGxUGtYot9「文字小一点」），只作用于
    // 面板内部，不改全局主题。
    if (!compact) return body;
    // 紧凑档：字阶收一档 + 设置行收紧（单行说明、溢出进 ⓘ、下拉与标题同行）。
    return Theme(
      data: videoQuickSettingsCompactTheme(theme),
      child: SettingsCompactRowsScope(child: body),
    );
  }

  /// 一个分类页：独立滚动视图 + 页顶说明 + 投影出的设置项。切分类后内容错峰
  /// 进场（[FushiEntranceScope]；首次打开由面板外壳的滑入承担动效，墨水屏 /
  /// 减弱动态效果下瞬时出现）。
  Widget _buildCategoryPage(String id, bool compact, double horizontal) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    // 每页按分类 id KeyedSubtree：页面之间不复用 Element，避免上一页同位置
    // Switch / Segmented 的动画副作用带到新页。
    return KeyedSubtree(
      key: ValueKey<String>(id),
      child: SingleChildScrollView(
        key: PageStorageKey<String>('video-settings-page-$id'),
        padding: FushiMasterDetailSettingsSheet.paneInsets(
          context,
          horizontal: horizontal,
          top: compact ? tokens.spacing.gap : tokens.spacing.card,
        ),
        // 内容自成重绘边界：滚动只平移已录好的层（与阅读器设置面板同理）。
        child: RepaintBoundary(
          // 行首图标着色（M3E 色调色块，随分组错开），与面板着色方案一起
          // 让设置页不再是一片灰。
          child: SettingsTonalIconsScope(
            child: FushiEntranceScope(
              enabled: _categorySwitched,
              replayKey: id,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  // 一行小字说明这一页管什么（尤其「画质增强」与「画面」两页
                  // 名字相近）；手机紧凑档不放：首屏留给设置项本身。
                  if (!compact)
                    FushiStaggeredEntrance(index: 0, child: _buildPageHint(id)),
                  FushiStaggeredEntrance(index: 1, child: _subPageContent(id)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 页顶一行小字说明（[_groupHint]）：单行、次要色，放不下省略。
  Widget _buildPageHint(String selectedId) {
    final VideoGroup? group = _groupFor(selectedId);
    if (group == null) return const SizedBox.shrink();
    final ThemeData theme = Theme.of(context);
    final TextStyle? style = isGlassDesign(context)
        ? FushiAppleMetrics.of(context).footnoteStyle(context)
        : theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        _groupHint(group),
        key: ValueKey<String>('video-settings-hint-$selectedId'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      ),
    );
  }

  /// 分类项（顶部页签；id == [VideoGroup] 枚举名，亦是 [_subPageContent] 的投影
  /// 入参）。直接由 [VideoGroup.values] 驱动而非手写平行列表：新增分组时
  /// [_groupTitle] 的 exhaustive switch 编译期报错，面板不可能静默漏掉分组。顺序 =
  /// 枚举声明序。TODO-1351：前三项即参考「检查器」的 视频 / 音频 / 字幕 tab——轨切换
  /// 收进对应分类（音频轨在「音频」、字幕轨在「字幕」顶部）。
  List<({String id, String label})> _categories() {
    return <({String id, String label})>[
      for (final VideoGroup group in widget.groups)
        (id: group.name, label: _groupTitle(group)),
    ];
  }

  String _groupTitle(VideoGroup group) {
    switch (group) {
      case VideoGroup.playback:
        return t.video_settings_cat_playback;
      case VideoGroup.audio:
        return t.video_settings_cat_audio;
      case VideoGroup.subtitle:
        return t.video_settings_cat_subtitle;
      case VideoGroup.shaders:
        return t.video_settings_cat_shaders;
      case VideoGroup.mpv:
        // 分组 id 仍是 `mpv`（键与测试不变），面向用户的名字是「画面」：这里装的
        // 是解码 / 画质 / HDR / 几何 / 色彩，「mpv」是实现细节不是用户语言。
        return t.video_settings_cat_picture;
      case VideoGroup.danmaku:
        return t.video_settings_cat_danmaku;
      case VideoGroup.controls:
        return t.video_settings_cat_controls;
    }
  }

  /// 分类的一行说明（详情页头下方）：告诉用户这一页管什么——尤其「画质增强」
  /// 与「画面」两页，名字相近、职责不同（着色器 vs. 解码 / 缩放 / 色彩）。
  String _groupHint(VideoGroup group) {
    switch (group) {
      case VideoGroup.playback:
        return t.video_settings_cat_playback_hint;
      case VideoGroup.audio:
        return t.video_settings_cat_audio_hint;
      case VideoGroup.subtitle:
        return t.video_settings_cat_subtitle_hint;
      case VideoGroup.shaders:
        return t.video_settings_cat_shaders_hint;
      case VideoGroup.mpv:
        return t.video_settings_cat_picture_hint;
      case VideoGroup.danmaku:
        return t.video_settings_cat_danmaku_hint;
      case VideoGroup.controls:
        return t.video_settings_cat_controls_hint;
    }
  }

  /// 面板项的 [SettingsContext]：挂上视频能力槽（host），schema 投影项据此走
  /// 页面回调实时应用；refresh 恒为本面板 setState（值 getter 重读 host/pref）。
  SettingsContext _settingsContext() {
    return createSettingsContext(
      appModel: widget.appModel,
      ref: widget.ref,
      video: widget.host,
    );
  }

  /// 某分类的详情内容（不含返回页头）：把分类 id 映射到 [VideoGroup]，经
  /// [buildVideoGroupDestination] 投影 schema、共享渲染器渲染（与阅读器面板的
  /// `_buildReaderGroupContent` 同款）。
  Widget _subPageContent(String page) {
    final VideoGroup? group = _groupFor(page);
    if (group == null) return const SizedBox.shrink();
    final SettingsContext settingsContext = _settingsContext();
    final SettingsDestination destination = _panelDestination(
      settingsContext,
      group,
      _subPageTitle(page),
    );
    // 按设计系统选渲染器：Apple → GlassSettingsRenderer（macOS / iOS 26 分组
    // 卡 + 液态玻璃控件），MD3 → MaterialSettingsRenderer（Android 16 分段分组），
    // Cupertino（隐藏内部能力）照旧。与设置主页同一个判据，面板与全局设置一致。
    final SettingsRenderer renderer = resolveSettingsRenderer(context);
    return renderer.buildDetailContent(
      settingsContext: settingsContext,
      destination: destination,
      shrinkWrap: true,
      // 本面板已在外层滚动视图提供横向 padding；
      // 让渲染器别再自带横向缩进，否则投影子页会双重缩进（与阅读器面板同约定）。
      insetHorizontally: false,
    );
  }

  /// 面板某分类的 destination：[buildVideoGroupDestination] 的 schema 投影，再按
  /// 面板的信息架构做两处整理（只动「放在哪页」，不动条目本身与持久化）：
  ///
  /// - mpv 配置里的「音频」小节（保持音高 / 声道 / 响度归一）挪到「音频」页、
  ///   「播放」小节（单文件循环）挪到「播放」页——用户找音频处理会去音频页，
  ///   而不是一个叫「画面」的页；「画面」页只留解码 / 画质 / HDR / 几何 / 色彩 /
  ///   高级。
  /// - 「字幕」页的「字幕外观」小节顶上插一块实时样式预览。
  SettingsDestination _panelDestination(
    SettingsContext settingsContext,
    VideoGroup group,
    String title,
  ) {
    final SettingsDestination base = buildVideoGroupDestination(
      settingsContext,
      group,
      title,
    );
    final String mpvAudio = t.video_setting_mpv_group_audio;
    final String mpvPlayback = t.video_setting_mpv_group_playback;
    List<SettingsSection> mpvSections(String sectionTitle) {
      return buildVideoGroupDestination(settingsContext, VideoGroup.mpv, '')
          .sections
          .where((SettingsSection s) => s.title == sectionTitle)
          .toList(growable: false);
    }

    final List<SettingsSection> sections;
    SettingsItemBuilder? shaderBody;
    switch (group) {
      case VideoGroup.mpv:
        sections = base.sections
            .where(
              (SettingsSection s) =>
                  s.title != mpvAudio && s.title != mpvPlayback,
            )
            .toList(growable: false);
      case VideoGroup.audio:
        sections = <SettingsSection>[
          ...base.sections.where((SettingsSection s) => s.items.isNotEmpty),
          ...mpvSections(mpvAudio),
        ];
      case VideoGroup.playback:
        sections = <SettingsSection>[
          ...base.sections.where((SettingsSection s) => s.items.isNotEmpty),
          // 「播放」页里再挂一个「播放」小标题是重复，挪过来时去掉标题。
          for (final SettingsSection s in mpvSections(mpvPlayback))
            SettingsSection(items: s.items),
        ];
      case VideoGroup.subtitle:
        final String appearance = t.video_setting_subtitle_appearance;
        sections = <SettingsSection>[
          for (final SettingsSection s in base.sections)
            // schema 若已自带预览行（全局设置 › 视频那边加了 VideoPlacement），
            // 就不再插第二块。
            if (s.title == appearance &&
                !s.items.any(
                  (SettingsItem item) =>
                      item.id.contains('subtitle_style_preview'),
                ))
              SettingsSection(
                id: s.id,
                title: s.title,
                footer: s.footer,
                visible: s.visible,
                presentation: s.presentation,
                summaryBuilder: s.summaryBuilder,
                items: <SettingsItem>[_subtitlePreviewItem, ...s.items],
              )
            else
              s,
        ];
      case VideoGroup.shaders:
        // 着色器管理视图自带三个分组（画质档位 / 进阶 / 已安装着色器），各是一个
        // 标题在卡片外的 [AdaptiveSettingsSection]。若当成 schema 行渲染，整个视图
        // 会被再套进一张行卡片、分组标题落进卡内（反馈 FxUMLvIqM1）；改走整页正文
        // 逃生口，与其它分类页的分组同一形态。
        for (final SettingsSection s in base.sections) {
          for (final SettingsItem item in s.items) {
            // 从 schema 行里取出来后不再经 section 的 visibleCopy 过滤，
            // 可见谓词在这里照样生效。
            if (item is SettingsCustomItem &&
                item.id == _shaderManagerItemId &&
                item.isVisible(settingsContext)) {
              shaderBody = item.builder;
            }
          }
        }
        sections = <SettingsSection>[
          for (final SettingsSection s in base.sections)
            if (s.items.any((SettingsItem i) => i.id != _shaderManagerItemId))
              SettingsSection(
                id: s.id,
                title: s.title,
                footer: s.footer,
                visible: s.visible,
                presentation: s.presentation,
                summaryBuilder: s.summaryBuilder,
                liveListenable: s.liveListenable,
                items: <SettingsItem>[
                  for (final SettingsItem i in s.items)
                    if (i.id != _shaderManagerItemId) i,
                ],
              ),
        ];
      case VideoGroup.danmaku:
      case VideoGroup.controls:
        sections = base.sections;
    }
    return SettingsDestination(
      id: base.id,
      title: base.title,
      icon: base.icon,
      sections: sections.isEmpty
          ? <SettingsSection>[const SettingsSection(items: <SettingsItem>[])]
          : sections,
      body: shaderBody,
      bodyBeforeSections: true,
    );
  }

  /// 「画质增强」页的着色器管理视图条目 id（settings_schema_video.dart）。
  static const String _shaderManagerItemId = 'video.player.shaders';

  /// 「字幕外观」小节顶部的实时样式预览行：16:9 模拟画面上按当前样式渲染一行
  /// 日文示例字幕（共享组件，与全局设置 › 视频同一份，样式函数与播放页同源）。
  static final SettingsItem _subtitlePreviewItem = SettingsCustomItem(
    id: 'video.player.subtitle_style_preview',
    builder: _buildSubtitlePreview,
  );

  static Widget _buildSubtitlePreview(SettingsContext settingsContext) {
    // 面板里限宽 400（≈ 225 高）：够看清字号 / 描边 / 背景，又不把下面的滑条
    // 挤出首屏。预览自带外框（卡片同色）与 12 圆角模拟画面，这里只留行内边距。
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: SubtitleStylePreview(
            appModel: settingsContext.appModel,
            uiScale: videoQuickSettingsHostOf(settingsContext)?.uiScale,
          ),
        ),
      ),
    );
  }

  VideoGroup? _groupFor(String page) {
    for (final VideoGroup group in VideoGroup.values) {
      if (group.name == page) return group;
    }
    return null;
  }

  String _subPageTitle(String page) {
    final VideoGroup? group = _groupFor(page);
    return group == null ? '' : _groupTitle(group);
  }
}
