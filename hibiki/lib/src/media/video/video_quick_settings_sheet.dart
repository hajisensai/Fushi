import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:hibiki/src/media/video/video_quick_settings_host.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/settings/cupertino_settings_renderer.dart';
import 'package:hibiki/src/settings/master_detail_settings_sheet.dart';
import 'package:hibiki/src/settings/material_settings_renderer.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/settings/settings_renderer.dart';
import 'package:hibiki/src/settings/settings_schema.dart';
import 'package:hibiki/utils.dart';

/// 视频播放设置面板（阶段 B：schema 投影版）：所有配置行都来自
/// settings_schema_video.dart 的单一声明，按 [VideoPlacement] group/order/section
/// 经 [buildVideoGroupDestination] 投影渲染（与阅读器面板消费 [ReaderPlacement]
/// 同款）；控制器绑定行经 [VideoQuickSettingsHost] 门控只在此出现。本文件只剩
/// 外壳：宽窗「顶部横向分类 chip 行 + 下方详情」上下分栏（TODO-556；详情独占整宽
/// 并独立滚动，分类条固定在顶部），窄窗降级单列 push。书籍设置面板仍保持左右
/// master-detail，互不影响。
///
/// 配色用标准浅色 MD3（与阅读器一致），由 `HibikiModalSheetFrame` 提供 sheet 外壳，
/// 桌面经 `HibikiDialogFrame(maxWidth: 900)` 进入分栏、移动端走 bottom sheet。
class VideoQuickSettingsSheet extends StatefulWidget {
  const VideoQuickSettingsSheet({
    required this.appModel,
    required this.ref,
    required this.host,
    this.initialCategory,
    super.key,
  });

  final AppModel appModel;

  /// Riverpod ref from the video page, forwarded to the schema-projected
  /// settings so [SettingsContext] always has a real [WidgetRef].
  final WidgetRef ref;

  /// 播放页能力槽：schema 投影项经它读页面权威值 / 回调持久化 + 实时应用。
  final VideoQuickSettingsHost host;

  /// TODO-1351：打开面板时直接定位到某个分类（`audio` / `subtitle` / ...）。null =
  /// 用默认（宽窗 `playback`，窄窗主页导航列表）。由「音频轨」「字幕轨」按钮驱动，把
  /// 原来「外面浮的轨切换器」收进本面板对应 tab。
  final String? initialCategory;

  @override
  State<VideoQuickSettingsSheet> createState() =>
      _VideoQuickSettingsSheetState();
}

class _VideoQuickSettingsSheetState extends State<VideoQuickSettingsSheet>
    with SettingsContextHost<VideoQuickSettingsSheet> {
  /// 窄窗 push 选中的子页 id；null = 主页。宽窗下恒有选中（默认 playback）。
  /// TODO-1351：初值取 [VideoQuickSettingsSheet.initialCategory]，让「音频轨/字幕轨」
  /// 按钮直接把面板开在对应分类。
  late String? _subPage = widget.initialCategory;

  /// 最近一次 LayoutBuilder 是否判定为宽窗（供 PopScope.canPop 读取）。
  /// 按窗口宽高确定性判定（>= 共享常量阈值），与书籍设置同条件。
  bool _isWide = false;

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

  /// 切换分类子页（顶栏 chip / 窄窗导航行共用）；进入「字幕」分类时触发字幕源加载回调
  /// （TODO-1350），统一两个入口，避免「切到字幕分类却没加载字幕轨」的入口遗漏。
  void _selectSubPage(String id) {
    final bool enteringSubtitle = id == 'subtitle' && _subPage != 'subtitle';
    setState(() => _subPage = id);
    if (enteringSubtitle) {
      widget.host.onSubtitleCategoryShown?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return HibikiMasterDetailSettingsSheet(
      // 宽窗 master-detail 选中态恒有值（默认 playback），返回键应直接关面板；
      // 窄窗 push 时保留「先回主页」语义。
      subPageActive: _subPage != null,
      onPopToParent: () => setState(() => _subPage = null),
      isWide: _isWide,
      onWideChanged: (bool wide) => _isWide = wide,
      // 视频窄窗外层滚动视图不带 key（与阅读器不同：阅读器带 _subPage key）。
      narrowKey: () => null,
      // TODO-344：四边按 MD3 spacing 放宽，消除「上下左右贴死」。水平用
      // page + gap（24），垂直顶部用 card（16）让内容离 sheet header / 分栏
      // divider 留出呼吸位，底部叠 card + gap + 键盘 inset（共享公式
      // [HibikiMasterDetailSettingsSheet.paneInsets]）。全部走 token，无裸值。
      narrowPadding: (BuildContext context, BoxConstraints constraints) {
        return HibikiMasterDetailSettingsSheet.paneInsets(
          context,
          horizontal: tokens.spacing.page + tokens.spacing.gap,
          top: tokens.spacing.card,
        );
      },
      narrowChild: (BuildContext context, BoxConstraints constraints) {
        return _subPage != null ? _buildSubPage(theme) : _buildMainPage(theme);
      },
      // 宽窗顶部横向分类条 + 下方详情上下分栏（TODO-556）——阅读器走左右
      // master-detail，两边发散，故 Column / _buildTopCategoryBar 等留在此回调里。
      wideBuilder: (BuildContext context, BoxConstraints constraints) {
        final double horizontalInset = tokens.spacing.page + tokens.spacing.gap;
        final double topInset = tokens.spacing.card;
        final String selectedId = _subPage ?? 'playback';
        final Color dividerColor = isCupertinoPlatform(context)
            ? CupertinoColors.separator.resolveFrom(context)
            : tokens.surfaces.outline;
        // 顶部分类条 padding：水平 + 顶部按 token 留白，底部留 gap/2 与下方
        // 分隔线呼吸（不吃底部键盘 inset，那份留给详情区）。
        final EdgeInsets wideCategoryPadding = EdgeInsets.fromLTRB(
          horizontalInset,
          topInset,
          horizontalInset,
          tokens.spacing.gap / 2,
        );
        // 详情区四边走共享公式（底部 = card + gap + 键盘 inset）。
        final EdgeInsets widePrimaryPadding =
            HibikiMasterDetailSettingsSheet.paneInsets(
          context,
          horizontal: horizontalInset,
          top: topInset,
        );
        // TODO-556：大分类「顶部横向分类 chip 行（固定）+ 下方全宽详情（独立滚动）」。
        // 顶部 chip 行钉在 sheet 顶部、随详情滚动不动；详情独占整宽、单独纵向滚动。
        // 书籍设置仍保持左右 master-detail。
        return SizedBox(
          height: constraints.maxHeight,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: wideCategoryPadding,
                child: _buildTopCategoryBar(selectedId),
              ),
              Divider(height: 1, thickness: 1, color: dividerColor),
              Expanded(
                child: KeyedSubtree(
                  key: ValueKey<String>(selectedId),
                  child: SingleChildScrollView(
                    padding: widePrimaryPadding,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        // TODO-640：顶栏改纯图标后，详情顶部用大标题标出当前分类。
                        _buildWideDetailTitle(selectedId),
                        SizedBox(height: topInset),
                        _subPageContent(selectedId),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 分类项（宽窗顶部 chip 行 + 窄窗导航行共用；id 与 [VideoGroup] 枚举名一一对应，
  /// 亦是 [_subPageContent] 的投影入参）。
  List<({String id, IconData icon, String label})> _categories() {
    return <({String id, IconData icon, String label})>[
      // TODO-1351：顶栏前三项即参考「检查器」的 视频 / 音频 / 字幕 tab——轨切换收进对应
      // 分类（音频轨在「音频」、字幕轨在「字幕」顶部），删掉外面浮的轨切换器。
      (
        id: 'playback',
        icon: Icons.play_circle_outline,
        label: t.video_settings_cat_playback,
      ),
      (
        id: 'audio',
        icon: Icons.audiotrack_outlined,
        label: t.video_settings_cat_audio,
      ),
      (
        id: 'subtitle',
        icon: Icons.subtitles_outlined,
        label: t.video_settings_cat_subtitle,
      ),
      (
        id: 'shaders',
        icon: Icons.auto_fix_high_outlined,
        label: t.video_settings_cat_shaders,
      ),
      (id: 'mpv', icon: Icons.tune, label: t.video_settings_cat_mpv),
      (
        id: 'danmaku',
        icon: Icons.forum_outlined,
        label: t.video_settings_cat_danmaku,
      ),
      (
        id: 'controls',
        icon: Icons.dashboard_customize_outlined,
        label: t.video_settings_cat_controls,
      ),
    ];
  }

  /// 宽窗顶部分类条（TODO-556 / TODO-1351 / BUG：末位分类被裁）：大分类用 chip 行，固定
  /// 在 sheet 顶部、不随下方详情滚动；选中 chip 高亮，点击切下方详情。
  ///
  /// **放不下时换行堆叠**（[Wrap]）而非横向滚动裁断（用户报「弹幕 / 控制 分类被截在视口
  /// 外、看不全」）。所有 chip 恒可见：一行放不下就自动折到第二行，宽度越窄行数越多，
  /// 永不裁断（[spacing] 行内间距、[runSpacing] 行间距均走 token，无裸值）。
  ///
  /// TODO-1351（用户复诉）：分类 tab 是「图标 + 完整文字」（参考「检查器」式 tab），不得
  /// 截成省略号、也不得压成纯图标 + tooltip。标签经
  /// [HibikiSelectableChip.allowLabelOverflow] 按固有宽度完整渲染（无 ellipsis）；换行由
  /// [Wrap] 承载，单个标签永不截断。
  Widget _buildTopCategoryBar(String selectedId) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Wrap(
      // 大分类 chip 行整体居中（用户诉求）：一行放不下换行时每行也居中，视觉更聚焦，
      // 不再左对齐贴边。
      alignment: WrapAlignment.center,
      runAlignment: WrapAlignment.center,
      spacing: tokens.spacing.gap,
      runSpacing: tokens.spacing.gap / 2,
      children: <Widget>[
        for (final ({String id, IconData icon, String label}) cat
            in _categories())
          HibikiSelectableChip(
            // 稳定 key：测试 / 焦点驱动靠 id key 命中分类（不依赖标签文案）。
            key: ValueKey<String>('video-settings-cat-${cat.id}'),
            label: cat.label,
            leadingIcon: cat.icon,
            selected: cat.id == selectedId,
            // TODO-1351：标签完整渲染、不省略；空间不够由 Wrap 换行兜底（不裁断）。
            allowLabelOverflow: true,
            onSelected: (_) => _selectSubPage(cat.id),
          ),
      ],
    );
  }

  /// 宽窗详情区顶部的当前分类标题（TODO-640 引入，TODO-1351 顶栏恢复完整文字标签后
  /// 保留作详情区页头）。与窄窗 push 子页头 [HibikiSettingsSubPageHeader] /
  /// 侧栏面板标题语义一致，但无返回箭头（宽窗顶栏不走 push）。
  Widget _buildWideDetailTitle(String selectedId) {
    final ThemeData theme = Theme.of(context);
    return Text(
      _subPageTitle(selectedId),
      style: theme.textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w600,
      ),
    );
  }

  /// 窄窗主页：分类导航行（push 子页）。面板顶部 [VideoTranslucentSidePanel] 已有
  /// 「视频设置」统一标题，主页内部不再重复一个 [SettingsSectionHeader]（TODO-427）。
  Widget _buildMainPage(ThemeData theme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        AdaptiveSettingsSection(
          titlePlacement: SettingsSectionTitlePlacement.inside,
          children: <Widget>[
            for (final ({String id, IconData icon, String label}) cat
                in _categories())
              AdaptiveSettingsNavigationRow(
                title: cat.label,
                icon: cat.icon,
                onTap: () => _selectSubPage(cat.id),
              ),
          ],
        ),
      ],
    );
  }

  /// 窄窗子页：返回页头 + 详情。
  Widget _buildSubPage(ThemeData theme) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final String page = _subPage!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        HibikiSettingsSubPageHeader(
          title: _subPageTitle(page),
          onBack: () => setState(() => _subPage = null),
        ),
        SizedBox(height: tokens.spacing.gap + tokens.spacing.gap / 2),
        _subPageContent(page),
      ],
    );
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
  /// `_buildReaderGroupContent` 同款）。窄窗 push 子页与宽窗下方详情共用。
  Widget _subPageContent(String page) {
    final VideoGroup? group = _groupFor(page);
    if (group == null) return const SizedBox.shrink();
    final SettingsContext settingsContext = _settingsContext();
    final SettingsDestination destination = buildVideoGroupDestination(
      settingsContext,
      group,
      _subPageTitle(page),
    );
    final bool cupertino = isCupertinoPlatform(context);
    final SettingsRenderer renderer = cupertino
        ? const CupertinoSettingsRenderer()
        : const MaterialSettingsRenderer();
    return renderer.buildDetailContent(
      settingsContext: settingsContext,
      destination: destination,
      shrinkWrap: true,
      // 本面板已在外层滚动视图提供横向 padding（widePrimaryPadding / narrowPadding）；
      // 让渲染器别再自带横向缩进，否则投影子页会双重缩进（与阅读器面板同约定）。
      insetHorizontally: false,
    );
  }

  VideoGroup? _groupFor(String page) {
    for (final VideoGroup group in VideoGroup.values) {
      if (group.name == page) return group;
    }
    return null;
  }

  String _subPageTitle(String page) {
    switch (page) {
      case 'playback':
        return t.video_settings_cat_playback;
      case 'audio':
        return t.video_settings_cat_audio;
      case 'shaders':
        return t.video_settings_cat_shaders;
      case 'mpv':
        return t.video_settings_cat_mpv;
      case 'subtitle':
        return t.video_settings_cat_subtitle;
      case 'danmaku':
        return t.video_settings_cat_danmaku;
      case 'controls':
        return t.video_settings_cat_controls;
      default:
        return '';
    }
  }
}
