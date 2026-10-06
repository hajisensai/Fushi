import 'package:fushi/src/media/tags/tag_picker_sheet.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:fushi/models.dart';
import 'package:fushi/src/media/collections/add_to_collection_dialog.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/mining/galgame_repository.dart';
import 'package:fushi/src/mining/galgame_scrape_controller.dart';
import 'package:fushi/src/mining/galgame_scrape_dialog.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_draft.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_merge.dart';
import 'package:fushi_engine/mining/metadata/galgame_metadata_source.dart';
import 'package:fushi/src/pages/implementations/game_shared.dart'
    show galHookAudioBackendLabel, galHookSessionPhaseLabel;
import 'package:fushi/src/pages/implementations/games_library_page.dart'
    show formatGalgameDate, galgamePlayStatusLabel;
import 'package:fushi/src/pages/implementations/tag_filter_sheet.dart'
    show allTagsProvider, filteredGameIdsProvider, gameTagMapProvider;
import 'package:fushi/src/pages/implementations/stat_charts.dart';
import 'package:fushi/src/pages/implementations/stat_shared.dart'
    show formatStatSessionRange, formatStatTime;
import 'package:fushi/src/pages/fushi_page_placeholders.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// galgame 详情页（契约 §4.2）：头部常驻 + 统计 / 简介 / 编辑三个 tab。
///
/// 由游戏库页长按/右键菜单 push 进来（卡片点击仍是启动游戏）。数据全部走
/// [GalgameRepository]：条目本身读缓存，会话流水与每日聚合按需查 DB。
/// 启动按钮不自带启动逻辑——[onLaunch] 由库页传入，复用那边带再入守卫的
/// `_launchGame`，避免两处各写一套 helper 确认 / 注入流程。
class GalgameDetailPage extends ConsumerStatefulWidget {
  const GalgameDetailPage({
    required this.gameId,
    super.key,
    this.initialTab = 0,
    this.onLaunch,
  });

  /// `galgames.id`。
  final String gameId;

  /// 初始 tab（0=统计 / 1=简介 / 2=编辑）。库页「刮削元数据」直接落编辑 tab。
  final int initialTab;

  /// 启动游戏（null = 不显示启动按钮，如非 Windows 或独立打开）。
  final VoidCallback? onLaunch;

  @override
  ConsumerState<GalgameDetailPage> createState() => _GalgameDetailPageState();
}

class _GalgameDetailPageState extends ConsumerState<GalgameDetailPage>
    with
        SingleTickerProviderStateMixin,
        FushiPagePlaceholders<GalgameDetailPage> {
  late final AppModel _appModel = ref.read(appProvider);
  late final GalgameRepository _repo = _appModel.galgameRepo;
  late final TabController _tabs = TabController(
    length: 3,
    vsync: this,
    initialIndex: widget.initialTab.clamp(0, 2),
  );

  GalgameEntry? _game;
  List<GalgameSessionRow> _sessions = const <GalgameSessionRow>[];
  List<GalgameSourceRow> _sources = const <GalgameSourceRow>[];

  /// 折线图时间窗口天数（含当天）。7D / 30D 两档（契约 §4）。
  int _rangeDays = 7;

  /// 当前时间窗口的每日秒数（dateKey → 秒）。
  Map<String, int> _dailyRange = const <String, int>{};

  /// 今日秒数（与 [_rangeDays] 无关，单独查一天）。
  int _todaySeconds = 0;

  /// 头部标签区本地选中集合（选中态 filled primary，对齐 ReinaManager）。
  final Set<String> _selectedTags = <String>{};

  /// 头部标签区是否展开（超过 [_kTagLimit] 时折叠，展开显示全部）。
  bool _tagsExpanded = false;

  /// 折叠前展示的标签上限（契约 §2）。
  static const int _kTagLimit = 40;

  /// 本游戏挂的共享用户标签，与 bgm/vndb 元数据标签分开。
  List<BookTagRow> _userTags = const <BookTagRow>[];

  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final GalgameEntry? game = _repo.byId(widget.gameId) ??
        (await _repo.load())
            .where((GalgameEntry g) => g.id == widget.gameId)
            .firstOrNull;
    if (game == null) {
      if (!mounted) return;
      setState(() {
        _game = null;
        _loading = false;
      });
      return;
    }
    final List<GalgameSessionRow> sessions = await _repo.sessions(game.id);
    final List<GalgameSourceRow> sources = await _repo.sourcesOf(game.id);
    final List<BookTagRow> userTags =
        await _appModel.database.getTagsForGame(game.id);
    final Map<String, int> daily = await _loadRange(game.id, _rangeDays);
    final String todayKey = formatGalgameDate(DateTime.now());
    final Map<String, int> today = await _repo.dailySeconds(
      game.id,
      fromDateKey: todayKey,
      toDateKey: todayKey,
    );
    if (!mounted) return;
    setState(() {
      _game = game;
      _sessions = sessions;
      _sources = sources;
      _userTags = userTags;
      _dailyRange = daily;
      _todaySeconds = today[todayKey] ?? 0;
      _loading = false;
    });
  }

  /// 查最近 [days] 天（含当天）的每日秒数。
  Future<Map<String, int>> _loadRange(String gameId, int days) {
    final DateTime today = DateTime.now();
    final DateTime start = DateTime(today.year, today.month, today.day)
        .subtract(Duration(days: days - 1));
    return _repo.dailySeconds(
      gameId,
      fromDateKey: formatGalgameDate(start),
      toDateKey: formatGalgameDate(today),
    );
  }

  /// 切换折线图时间窗口（7D / 30D）。
  Future<void> _setRange(int days) async {
    final GalgameEntry? game = _game;
    if (game == null || days == _rangeDays) return;
    final Map<String, int> daily = await _loadRange(game.id, days);
    if (!mounted) return;
    setState(() {
      _rangeDays = days;
      _dailyRange = daily;
    });
  }

  /// 头部标签点击：本地选中态切换（对齐 ReinaManager 的可选标签）。
  void _toggleTag(String tag) {
    setState(() {
      if (!_selectedTags.remove(tag)) _selectedTags.add(tag);
    });
  }

  /// 删除单条游玩会话。
  ///
  /// 2026-10 体验优化：原先垃圾桶一点即删、不可撤销，会话又直接参与总时长 /
  /// 每日折线统计，误触就丢数据——先确认（标出是哪一次），删完给 Toast。
  Future<void> _deleteSession(GalgameSessionRow row) async {
    final bool confirmed = await showFushiConfirmDialog(
      context: context,
      title: t.game_stat_delete_session,
      message:
          '${formatGalgameSessionRange(row)}'
          ' · ${formatStatTime(row.durationSeconds * 1000)}',
      icon: FushiIcons.delete,
      confirmLabel: t.dialog_delete,
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await _repo.deleteSession(row.id);
    await _load();
    if (!mounted) return;
    FushiToast.show(msg: t.storage_entry_delete_done);
  }

  /// 「加入合集」：mediaType=[MediaKind.game]、entryKey=`galgames.id`（本机局域
  /// 身份），与库页卡片菜单同一 DAO 路径。
  Future<void> _addToCollection(GalgameEntry game) async {
    await showAddToCollectionDialog(
      context: context,
      database: _appModel.database,
      mediaType: MediaKind.game,
      entryKey: game.id,
      defaultNewName: game.displayName,
    );
  }

  @override
  Widget build(BuildContext context) {
    final GalgameEntry? game = _game;
    if (_loading) {
      return Scaffold(
        appBar: FushiAppBar(),
        body: buildLoading(),
      );
    }
    if (game == null) {
      return Scaffold(
        appBar: FushiAppBar(),
        body: Center(
          child: FushiPlaceholderMessage(
            icon: FushiIcons.games,
            message: t.game_detail_missing,
          ),
        ),
      );
    }
    // 背景铺到窗口顶端：hero 的模糊 key art / 色晕从 y = 0 画起，浮动顶栏只是
    // 几颗胶囊。曾经正文从顶栏下沿开始，hero 背景（左上角散开的色晕）在栏
    // 下沿被齐刷刷切出一块发白的矩形色区（2026-10-06 用户截图）。hero 自己按
    // MediaQuery 顶部 padding 让开顶栏；页签与正文不再让。
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: FushiAppBar(
        title: Text(
          game.displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: <Widget>[
          // 「加入合集」：与库页卡片菜单同一入口语义（mediaType='game'，entryKey=
          // galgames.id），落库同走 addToCollection DAO；库页返回后 _reload 刷新分组。
          FushiIconButtonControl(
            tooltip: t.add_to_collection,
            icon: const FushiIcon(FushiIcons.collection),
            onPressed: () => unawaited(_addToCollection(game)),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          _buildHero(context, game),
          // 页签轨道与正文同一条页边（trackInset: 0，轨道不再自己多缩 12）。
          // 顶栏让位已由 hero 吃掉，下面不再让。
          Expanded(
            child: MediaQuery.removePadding(
              context: context,
              removeTop: true,
              child: Column(
                children: <Widget>[
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: FushiDesignTokens.of(context).spacing.page,
            ),
            child: FushiTabBar(
              controller: _tabs,
              trackInset: 0,
              tabs: <Widget>[
                Tab(text: t.game_detail_tab_stats),
                Tab(text: t.game_detail_tab_summary),
                Tab(text: t.game_detail_tab_edit),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: <Widget>[
                _buildStatsTab(context, game),
                _buildSummaryTab(context, game),
                _GalgameEditTab(
                  game: game,
                  repo: _repo,
                  onSaved: _load,
                ),
              ],
            ),
          ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Hero 头（2026-10 游戏模块重设计，10-06 M3E）：同一张封面放大模糊做 key
  /// art 背景（进页淡入），MD3 再叠一层 primaryContainer 饱和色晕（M3E 的「色块
  /// 即层次」），自上而下渐变融进页面底；前景左侧大封面（封面卡同一套
  /// [ShelfCoverFrame]，进页弹簧放大入场），右侧 headline Emphasized 标题 / 开发商 /
  /// 状态·发行日·评分胶囊，下方 M3E 按钮组：大号主按钮「启动游戏」+ tonal 次按钮
  /// （管理标签）+ 更多。窄屏（<560）封面缩小、按钮行换到整行宽。墨水屏不画背景
  /// （模糊 = 抖动灰）。
  Widget _buildHero(BuildContext context, GalgameEntry game) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool narrow = constraints.maxWidth < 560;
        final double coverWidth = narrow ? 112 : 168;
        final FushiMotionScheme motion = context.fushiMotion;
        return Stack(
          children: <Widget>[
            Positioned.fill(child: _heroBackdrop(context, game)),
            Padding(
              // 顶部先让开铺到背景之上的浮动顶栏（extendBodyBehindAppBar）。
              padding: EdgeInsets.fromLTRB(
                16,
                MediaQuery.paddingOf(context).top + (narrow ? 12 : 20),
                16,
                12,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      // 进页弹簧入场：封面从 0.92 弹到原大（spatial 弹簧会略过冲
                      // 回弹），墨水屏 / 减弱动态效果时长归零直接到位。
                      TweenAnimationBuilder<double>(
                        tween: Tween<double>(begin: 0.92, end: 1),
                        duration: motion.spatialSlow.duration,
                        curve: motion.spatialSlow.curve,
                        builder: (BuildContext context, double scale,
                                Widget? child) =>
                            Transform.scale(scale: scale, child: child),
                        child: SizedBox(
                          width: coverWidth,
                          child: AspectRatio(
                            aspectRatio: 3 / 4,
                            child: ShelfCoverFrame(
                              child: _buildCover(context, game),
                            ),
                          ),
                        ),
                      ),
                      SizedBox(width: narrow ? 14 : 20),
                      Expanded(child: _heroInfo(context, game, narrow: narrow)),
                    ],
                  ),
                  if (narrow) ...<Widget>[
                    const SizedBox(height: 12),
                    _heroActions(context, game),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  /// Hero 背景：模糊封面（淡入）+ 融进页面底的渐变。树结构恒定——无封面 / 墨水屏
  /// 只把不透明度压到 0，不增删层。
  Widget _heroBackdrop(BuildContext context, GalgameEntry game) {
    final Color page = Theme.of(context).scaffoldBackgroundColor;
    final String? cover = game.coverPath;
    final bool show = !isEinkTheme(context) &&
        cover != null &&
        cover.isNotEmpty &&
        File(cover).existsSync();
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    // M3E 饱和色晕：Material 设计系统在模糊 key art 上再叠一层 primaryContainer
    // 从左上角散开的径向色块（无封面时它就是 hero 的底色）；Apple / 墨水屏透明。
    // 只换颜色不增删层，树结构恒定。
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool tint = !isEinkTheme(context) && !isGlassDesign(context);
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment.topLeft,
              radius: 1.4,
              colors: <Color>[
                tint
                    ? cs.primaryContainer.withValues(alpha: dark ? 0.55 : 0.7)
                    : Colors.transparent,
                tint
                    ? cs.tertiaryContainer.withValues(alpha: 0.25)
                    : Colors.transparent,
                Colors.transparent,
              ],
              stops: const <double>[0, 0.55, 1],
            ),
          ),
        ),
        TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: show ? 1 : 0),
          duration: fushiMotionDuration(context, FushiMotion.long),
          curve: FushiMotion.enter,
          builder: (BuildContext context, double value, Widget? child) =>
              Opacity(opacity: value * (dark ? 0.6 : 0.5), child: child),
          child: ClipRect(
            child: ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: 40, sigmaY: 40),
              child: show
                  ? ShelfFileCover(
                      path: cover,
                      placeholder: const SizedBox.shrink(),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[
                page.withValues(alpha: 0.15),
                page.withValues(alpha: 0.7),
                page,
              ],
              stops: const <double>[0, 0.62, 1],
            ),
          ),
        ),
      ],
    );
  }

  /// Hero 右侧信息：标题 + 开发商 + 胶囊行（状态 / 发行日 / 站点评分 / 我的评分），
  /// 宽屏时按钮行跟在下面。
  Widget _heroInfo(
    BuildContext context,
    GalgameEntry game, {
    required bool narrow,
  }) {
    final ThemeData theme = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final String? developer = game.developer;
    final String? release = game.effectiveReleaseDate;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          game.displayName,
          style: narrow
              ? context.fushiType.headlineSmallEmphasized
              : context.fushiType.headlineMediumEmphasized,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        if (developer != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              developer,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: tokens.surfaces.onVariant,
              ),
            ),
          ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            FushiTagChip(
              label: galgamePlayStatusLabel(game.playStatus),
              selected: true,
            ),
            if (release != null) FushiTagChip(label: release),
            ..._scoreChips(game),
          ],
        ),
        if (!narrow) ...<Widget>[
          const SizedBox(height: 16),
          _heroActions(context, game),
        ],
      ],
    );
  }

  /// Hero 按钮行（M3E 按钮层级）：大号（M 56）filled 主按钮「启动游戏」（有
  /// [GalgameDetailPage.onLaunch] 时）+ tonal 次按钮「管理标签」+ 「更多」菜单
  /// （刮削元数据 / 编辑 / 加入合集）。尺寸档只影响 Material；Apple 仍是系统胶囊。
  Widget _heroActions(BuildContext context, GalgameEntry game) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        if (widget.onLaunch != null)
          FushiFilledButton.icon(
            key: const ValueKey<String>('galgame_detail_launch'),
            size: FushiButtonSize.m,
            onPressed: widget.onLaunch,
            icon: const FushiIcon(FushiIcons.play),
            label: Text(t.game_launch),
          ),
        FushiFilledButton.tonalIcon(
          onPressed: () => unawaited(_editUserTags(game)),
          icon: const FushiIcon(FushiIcons.tag),
          label: Text(t.tag_manage),
        ),
        FushiPopupMenuButton<_HeroMoreAction>(
          key: const ValueKey<String>('galgame_detail_more'),
          tooltip: t.common_more_actions,
          icon: FushiIcon(
            isGlassDesign(context) ? FushiIcons.moreHoriz : FushiIcons.more,
          ),
          onSelected: (_HeroMoreAction action) {
            switch (action) {
              case _HeroMoreAction.scrape:
                unawaited(_scrapeFromHero(game));
              case _HeroMoreAction.edit:
                _tabs.animateTo(2);
              case _HeroMoreAction.collection:
                unawaited(_addToCollection(game));
            }
          },
          itemBuilder: (BuildContext context) =>
              <PopupMenuEntry<_HeroMoreAction>>[
            _heroMenuItem(
              _HeroMoreAction.scrape,
              FushiIcons.cloudDownload,
              t.game_scrape,
            ),
            _heroMenuItem(
              _HeroMoreAction.edit,
              FushiIcons.edit,
              t.game_detail_tab_edit,
            ),
            _heroMenuItem(
              _HeroMoreAction.collection,
              FushiIcons.collection,
              t.add_to_collection,
            ),
          ],
        ),
      ],
    );
  }

  PopupMenuItem<_HeroMoreAction> _heroMenuItem(
    _HeroMoreAction value,
    IconData icon,
    String label,
  ) {
    return PopupMenuItem<_HeroMoreAction>(
      value: value,
      child: Row(
        children: <Widget>[
          FushiIcon(icon, size: 20),
          const SizedBox(width: 12),
          Expanded(child: Text(label)),
        ],
      ),
    );
  }

  /// Hero「更多 › 刮削元数据」：与编辑 tab、库页卡菜单同一个统一刮削弹窗。
  Future<void> _scrapeFromHero(GalgameEntry game) async {
    final bool applied = await showGalgameScrapeDialog(
      context: context,
      game: game,
      repo: _repo,
    );
    if (!applied || !mounted) return;
    await _load();
  }

  /// 详情页内容分组：分组标题 + 内容层卡片（[FushiCard]：MD3 surfaceContainerLow
  /// 16 圆角的 tonal 卡 / Apple secondarySystemGroupedBackground 的 inset grouped
  /// 底）。两套设计系统同一棵树。
  Widget _sectionCard(
    BuildContext context, {
    required Widget child,
    String? title,
    Widget? trailing,
    EdgeInsetsGeometry padding = const EdgeInsets.all(16),
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (title != null)
          FushiSectionTitle(
            title,
            trailing: trailing,
            padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
          ),
        FushiCard(padding: padding, child: child),
      ],
    );
  }

  Widget _userTagsCell(BuildContext context, GalgameEntry game) {
    return _metaCell(
      context,
      t.game_user_tags_title,
      Wrap(
        spacing: 6,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          for (final BookTagRow tag in _userTags)
            FushiTagChip(
              label: tag.name,
              color: Color(tag.colorValue),
              tone: FushiTagChipTone.surface,
            ),
          FushiActionChip(
            label: t.tag_manage,
            icon: FushiIcons.tag,
            onPressed: () => unawaited(_editUserTags(game)),
          ),
        ],
      ),
    );
  }

  Future<void> _editUserTags(GalgameEntry game) async {
    await showTagPicker(
      context,
      targets: TagTargets(
        media: <MediaRef>[MediaRef(kind: MediaKind.game, entryKey: game.id)],
      ),
    );
    if (!mounted) return;
    final List<BookTagRow> tags =
        await _appModel.database.getTagsForGame(game.id);
    if (!mounted) return;
    setState(() => _userTags = tags);
    ref.invalidate(allTagsProvider);
    ref.invalidate(gameTagMapProvider);
    ref.invalidate(filteredGameIdsProvider);
  }

  /// 元信息网格：每项「粗体 label + 下方 value」，flex-wrap（契约 §2）。
  Widget _metaGrid(BuildContext context, GalgameEntry game) {
    final GalgameMetadataDraft meta = game.metadata;
    final List<Widget> cells = <Widget>[
      if (_sources.isNotEmpty)
        _metaCell(context, t.game_meta_source, _sourceChips(context)),
      if (game.developer != null)
        _metaCell(
          context,
          t.game_edit_developer,
          FushiTagChip(label: game.developer!),
        ),
      if (game.effectiveReleaseDate != null)
        _metaTextCell(
            context, t.game_summary_release_date, game.effectiveReleaseDate!),
      _metaTextCell(
          context, t.game_meta_added, formatGalgameDate(game.addedAt)),
      if (meta.averageHours != null)
        _metaTextCell(context, t.game_summary_average_hours,
            '${meta.averageHours!.toStringAsFixed(1)} h'),
      if (meta.rank != null)
        _metaTextCell(context, t.game_meta_ranking, '#${meta.rank}'),
      _userTagsCell(context, game),
    ];
    return Wrap(runSpacing: 4, children: cells);
  }

  /// 一个「粗体 label + 值 widget」的网格单元。
  Widget _metaCell(BuildContext context, String label, Widget value) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 24, bottom: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: tokens.type.metadata.copyWith(
              fontWeight: FontWeight.w700,
              color: tokens.surfaces.onSurface,
            ),
          ),
          const SizedBox(height: 2),
          value,
        ],
      ),
    );
  }

  /// 文本值的网格单元。
  Widget _metaTextCell(BuildContext context, String label, String value) {
    final ThemeData theme = Theme.of(context);
    return _metaCell(
      context,
      label,
      Text(value, style: theme.textTheme.bodyMedium),
    );
  }

  /// 数据来源 chips：可点者用 [FushiActionChip] 开外链，无链回落展示 chip。
  Widget _sourceChips(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: <Widget>[
        for (final GalgameSourceRow row in _sources)
          () {
            final String label =
                GalgameMetadataSource.fromKey(row.source)?.label ?? row.source;
            final String? url = _externalUrl(row);
            if (url == null) return FushiTagChip(label: label);
            return FushiActionChip(
              label: label,
              icon: FushiIcons.openInNew,
              onPressed: () => unawaited(_openUrl(url)),
            );
          }(),
      ],
    );
  }

  /// 评分胶囊：`站点 X.X`（默认）+ `我的 X.X`（选中态），放进 Hero 胶囊行。
  List<Widget> _scoreChips(GalgameEntry game) {
    return <Widget>[
      if (game.siteScore != null)
        FushiTagChip(
          label: '${t.game_site_score} ${game.siteScore!.toStringAsFixed(1)}',
        ),
      if (game.userRating != null)
        FushiTagChip(
          label: '${t.game_user_rating} ${game.userRating!.toStringAsFixed(1)}',
          selected: true,
        ),
    ];
  }

  /// 标签区（契约 §2）：标题行（"游戏标签" + 选中计数 + 清空）+ flex-wrap 标签
  /// chips（选中态 filled primary），上限 [_kTagLimit] + 展开/折叠。
  Widget _tagsSection(BuildContext context, GalgameEntry game) {
    final List<String> tags = game.tags;
    if (tags.isEmpty) return const SizedBox.shrink();
    final ThemeData theme = Theme.of(context);
    final bool overflowing = tags.length > _kTagLimit;
    final List<String> shown =
        (overflowing && !_tagsExpanded) ? tags.sublist(0, _kTagLimit) : tags;
    return Padding(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                _selectedTags.isEmpty
                    ? t.game_tags_title
                    : '${t.game_tags_title} · ${_selectedTags.length}',
                style: theme.textTheme.titleSmall,
              ),
              const Spacer(),
              if (_selectedTags.isNotEmpty)
                FushiActionChip(
                  label: t.game_tags_clear,
                  icon: FushiIcons.close,
                  onPressed: () => setState(_selectedTags.clear),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: <Widget>[
              for (final String tag in shown)
                FushiTagChip(
                  label: tag,
                  tone: FushiTagChipTone.surface,
                  selected: _selectedTags.contains(tag),
                  onTap: () => _toggleTag(tag),
                ),
            ],
          ),
          if (overflowing)
            Align(
              alignment: Alignment.centerLeft,
              child: FushiTextButton.icon(
                onPressed: () => setState(() => _tagsExpanded = !_tagsExpanded),
                icon: FushiIcon(
                  _tagsExpanded ? FushiIcons.expandLess : FushiIcons.expandMore,
                ),
                label: Text(_tagsExpanded
                    ? t.collection_collapse
                    : '${t.collection_expand} +${tags.length - _kTagLimit}'),
              ),
            ),
        ],
      ),
    );
  }

  String? _externalUrl(GalgameSourceRow row) {
    final GalgameMetadataSource? source =
        GalgameMetadataSource.fromKey(row.source);
    final String? id = row.externalId;
    if (source == null || id == null || id.isEmpty) return null;
    return GalgameScrapeController.instance.externalUrl(source, id);
  }

  Future<void> _openUrl(String url) async {
    final Uri? uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  /// 封面：有 coverPath 且文件存在则经 [ShelfFileCover] 降采样加载（BUG-959 同类，
  /// 裸 Image.file 整帧解码包装图撑爆 ImageCache），否则共享占位件
  /// [ShelfCoverPlaceholder]（保持原 overlay 底色 + 手柄图标 40）。
  Widget _buildCover(BuildContext context, GalgameEntry game) {
    final Widget placeholder = ShelfCoverPlaceholder(
      icon: FushiIcons.games,
      iconSize: 40,
      backgroundColor: FushiDesignTokens.of(context).surfaces.overlay,
    );
    final String? cover = game.coverPath;
    if (cover != null && cover.isNotEmpty && File(cover).existsSync()) {
      return ShelfFileCover(path: cover, placeholder: placeholder);
    }
    return placeholder;
  }

  // ── 统计 tab ───────────────────────────────────────────────────────────

  /// 统计 tab：KPI 统计卡 + 每日时长折线图（分组卡）+ 会话流水（分组列表，可删
  /// 单条）。三段在进场窗口内错峰淡入（与库页网格同一套动效）。
  Widget _buildStatsTab(BuildContext context, GalgameEntry game) {
    final ThemeData theme = Theme.of(context);
    final List<Widget> sections = <Widget>[
      // 只读 Hook 状态：本游戏正在捕获会话里时才出现（不改任何 hook 逻辑）。
      if (Platform.isWindows) _GalgameHookStatusCard(game: game),
      _buildKpis(theme, game),
      _sectionCard(
        context,
        title: t.game_stat_daily,
        trailing: FushiSegmentedButton<int>(
          showSelectedIcon: false,
          // 2026-10 体验优化：原硬编码 '7D' / '30D' 不随语言变化。
          segments: <ButtonSegment<int>>[
            ButtonSegment<int>(
              value: 7,
              label: Text(t.stat_format_days(n: 7)),
            ),
            ButtonSegment<int>(
              value: 30,
              label: Text(t.stat_format_days(n: 30)),
            ),
          ],
          selected: <int>{_rangeDays},
          onSelectionChanged: (Set<int> s) => unawaited(_setRange(s.first)),
        ),
        padding: const EdgeInsets.fromLTRB(12, 16, 16, 12),
        child: _buildDailyLineChart(context, theme),
      ),
      // 会话流水：M3E 分段列表（组首尾 24 / 中间 4 圆角、行间 2px 缝，悬停 / 按下
      // 形变；Apple = inset grouped），不再是卡内 Divider 行。
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          FushiSectionTitle(
            t.game_stat_session_list,
            padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
          ),
          _buildSessionList(context, theme),
        ],
      ),
    ];
    return FushiEntranceScope(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: <Widget>[
          for (int i = 0; i < sections.length; i++)
            FushiStaggeredEntrance(index: i, child: sections[i]),
        ],
      ),
    );
  }

  /// 会话流水：M3E 分段列表（[FushiGroupedList]）。每行行首是时钟形状底图标，
  /// 标题是时间范围、副标题是时长（等宽数字），行尾删除钮。空态是一张中性卡。
  Widget _buildSessionList(BuildContext context, ThemeData theme) {
    if (_sessions.isEmpty) {
      return FushiCard(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        child: Row(
          children: <Widget>[
            FushiIcon(
              FushiIcons.history,
              size: 20,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                t.game_stat_no_sessions,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      );
    }
    return FushiGroupedList(
      // 分隔线（Apple）从文字起点开始：行内边距 16 + 图标 36 + 间距 16。
      separatorIndent: 68,
      children: <Widget>[
        for (final GalgameSessionRow session in _sessions)
          FushiListItem(
            key: ValueKey<int>(session.id),
            density: FushiListDensity.compact,
            padding: const EdgeInsetsDirectional.only(start: 16, end: 4),
            leading: const FushiListLeadingIcon(
              FushiIcons.schedule,
              size: 36,
              iconSize: 20,
            ),
            title: Text(formatGalgameSessionRange(session)),
            subtitle: Text(
              formatStatTime(session.durationSeconds * 1000),
              style: context.fushiType.bodyMedium.tabular.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            trailing: FushiIconButtonControl(
              tooltip: t.game_stat_delete_session,
              icon: const FushiIcon(FushiIcons.delete),
              onPressed: () => unawaited(_deleteSession(session)),
            ),
          ),
      ],
    );
  }

  /// 每日游玩时长折线图（契约 §4）：线色主题色、Y 轴时长、X 轴日期、双向淡网格。
  /// 复用 [StatLineChartPainter]（阅读/视频统计同款自绘），不引图表库。
  Widget _buildDailyLineChart(BuildContext context, ThemeData theme) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme colors = theme.colorScheme;
    final List<StatDayData> points =
        buildGalgameRangeChartData(DateTime.now(), _rangeDays, _dailyRange);
    final List<double> values = <double>[
      for (final StatDayData d in points) d.ms.toDouble(),
    ];
    final List<String> labels = <String>[
      for (final StatDayData d in points) statDayLabel(d),
    ];
    return SizedBox(
      height: 280,
      child: CustomPaint(
        size: Size.infinite,
        painter: StatLineChartPainter(
          series: <StatLineSeries>[
            StatLineSeries(values: values, color: colors.primary),
          ],
          xLabels: labels,
          anomalies: const <bool>[],
          anomalyColor: colors.primary,
          labelColor: colors.onSurfaceVariant,
          labelStyle: tokens.type.metadata.copyWith(
            color: colors.onSurfaceVariant,
          ),
          // 纵轴是游玩时长（ms → "Xh Ym" / "Xm"），与视频统计同款。
          labelFormatter: formatGalgameDurationAxis,
          // 7 天档标签每天都显，30 天档抽稀到每 5 天。
          labelEvery: _rangeDays <= 7 ? 1 : 5,
        ),
      ),
    );
  }

  /// 四个 KPI 统计卡（累计时长 / 游玩次数 / 今日时长 / 最后游玩）。
  ///
  /// 2026-10 游戏模块重设计：每格一张内容层卡片（[FushiCard]：MD3 tonal 统计卡 /
  /// Apple inset grouped 统计格，像「健身」「屏幕使用时间」的摘要格），图标走强调色，
  /// 大号数值。宽屏（≥480）一行四格；窄屏 2×2，值套 `FittedBox` 兜底不截断。
  Widget _buildKpis(ThemeData theme, GalgameEntry game) {
    final List<Widget> cells = <Widget>[
      // M3E：首格（累计时长）是饱和 primary 色块 hero 格，其余中性。
      _kpi(theme, FushiIcons.timer, t.game_stat_total_time,
          formatStatTime(game.totalPlaySeconds * 1000),
          tone: FushiCardTone.primary),
      _kpi(theme, FushiIcons.replay, t.game_stat_sessions,
          '${game.sessionCount}'),
      _kpi(theme, FushiIcons.calendar, t.game_stat_today,
          formatStatTime(_todaySeconds * 1000)),
      _kpi(
        theme,
        FushiIcons.history,
        t.game_stat_last_played,
        game.lastPlayedMs <= 0
            ? t.game_never_played
            : formatGalgameDate(
                DateTime.fromMillisecondsSinceEpoch(game.lastPlayedMs)),
      ),
    ];
    const double gap = 12;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (constraints.maxWidth >= 480) {
          return Row(
            children: <Widget>[
              for (int i = 0; i < cells.length; i++) ...<Widget>[
                if (i > 0) const SizedBox(width: gap),
                Expanded(child: cells[i]),
              ],
            ],
          );
        }
        return Column(
          key: const ValueKey<String>('galgame_detail_kpi_grid'),
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(child: cells[0]),
                const SizedBox(width: gap),
                Expanded(child: cells[1]),
              ],
            ),
            const SizedBox(height: gap),
            Row(
              children: <Widget>[
                Expanded(child: cells[2]),
                const SizedBox(width: gap),
                Expanded(child: cells[3]),
              ],
            ),
          ],
        );
      },
    );
  }

  /// 一格 KPI：标签行 + Display 大数字（M3E displaySmall Emphasized、等宽数字，
  /// 窄格 `FittedBox` 缩放兜底不截断）。[tone] 非 neutral 时整格是饱和 container
  /// 色块，图标 / 文字取 onContainer。
  Widget _kpi(
    ThemeData theme,
    IconData icon,
    String label,
    String value, {
    FushiCardTone tone = FushiCardTone.neutral,
  }) {
    final Color? onTone = fushiCardToneColors(context, tone)?.onContainer;
    return FushiCard(
      tone: tone,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              FushiIcon(
                icon,
                size: 18,
                color: onTone ?? theme.colorScheme.primary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  style: context.fushiType.labelLarge.copyWith(
                    color: onTone ?? theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: Text(
              value,
              style: context.fushiType.displaySmallEmphasized.tabular
                  .copyWith(color: onTone),
              maxLines: 1,
            ),
          ),
        ],
      ),
    );
  }

  // ── 简介 tab ───────────────────────────────────────────────────────────

  /// 简介 tab：简介正文卡 + 别名 / 全部标题 / 我的评价卡 + 资料卡（数据来源 /
  /// 开发商 / 发行日 / 添加时间 / 通关时长 / 排行 / 用户标签）+ 元数据标签卡。资料与
  /// 标签原先常驻在头部，Hero 收窄后移到这里（功能不变）。
  Widget _buildSummaryTab(BuildContext context, GalgameEntry game) {
    final ThemeData theme = Theme.of(context);
    final GalgameMetadataDraft meta = game.metadata;
    final String? summary = meta.summary;
    final List<Widget> details = <Widget>[
      if (meta.aliases.isNotEmpty)
        _summarySection(theme, t.game_summary_aliases, meta.aliases.join('、')),
      if (meta.allTitles.isNotEmpty)
        _summarySection(
            theme, t.game_summary_all_titles, meta.allTitles.join('\n')),
      if (game.effectiveReleaseDate != null)
        _summarySection(
            theme, t.game_summary_release_date, game.effectiveReleaseDate!),
      if (meta.averageHours != null)
        _summarySection(theme, t.game_summary_average_hours,
            '${meta.averageHours!.toStringAsFixed(1)} h'),
      if (game.customData.userReview != null)
        _summarySection(
            theme, t.game_edit_user_review, game.customData.userReview!),
    ];
    final List<Widget> sections = <Widget>[
      _sectionCard(
        context,
        child: Text(
          summary ?? t.game_summary_none,
          style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
        ),
      ),
      if (details.isNotEmpty)
        _sectionCard(
          context,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: details,
          ),
        ),
      _sectionCard(
        context,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: _metaGrid(context, game),
      ),
      if (game.tags.isNotEmpty)
        _sectionCard(context, child: _tagsSection(context, game)),
    ];
    return FushiEntranceScope(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: <Widget>[
          for (int i = 0; i < sections.length; i++)
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : 12),
              child: FushiStaggeredEntrance(index: i, child: sections[i]),
            ),
        ],
      ),
    );
  }

  Widget _summarySection(ThemeData theme, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: theme.textTheme.labelLarge
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          Text(value, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}

/// Hero「更多」菜单项。
enum _HeroMoreAction { scrape, edit, collection }

/// 详情页统计 tab 顶部的**只读** Hook 会话状态卡（M3E 饱和色块）。
///
/// 只在 app 级捕获会话正在跑**这个游戏**（会话的启动 exe 与本条目 exe 同路径）时
/// 出现：阶段 / 音频来源 / 是否已收到台词三枚 chip。纯展示——读
/// [GalHookSessionController.state]、监听其通知，不调用任何会话方法、不改 hook /
/// 注入 / 窗口逻辑。色块档：运行中 primary、降级 tertiary、其余（解析 / 启动 /
/// 注入 / 等信号 / 停止中）secondary。出现 / 消失走弹簧尺寸动画。
class _GalgameHookStatusCard extends StatelessWidget {
  const _GalgameHookStatusCard({required this.game});

  final GalgameEntry game;

  static String _normPath(String path) =>
      path.replaceAll(r'\', '/').toLowerCase();

  bool _isThisGame(GalHookSessionState state) {
    final String? exe = state.launchExe;
    if (!state.isActive || exe == null || exe.isEmpty) return false;
    return _normPath(exe) == _normPath(game.exePath);
  }

  @override
  Widget build(BuildContext context) {
    final GalHookSessionController session = GalHookSessionController.instance;
    final FushiMotionScheme motion = context.fushiMotion;
    return ListenableBuilder(
      listenable: session,
      builder: (BuildContext context, Widget? _) {
        final GalHookSessionState state = session.state;
        final bool show = _isThisGame(state);
        return AnimatedSize(
          duration: motion.spatialDefault.duration,
          curve: motion.spatialDefault.curve,
          alignment: Alignment.topCenter,
          child: show
              ? Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _buildCard(context, state),
                )
              : const SizedBox(width: double.infinity),
        );
      },
    );
  }

  Widget _buildCard(BuildContext context, GalHookSessionState state) {
    final FushiCardTone tone = switch (state.phase) {
      GalHookSessionPhase.running => FushiCardTone.primary,
      GalHookSessionPhase.degraded => FushiCardTone.tertiary,
      _ => FushiCardTone.secondary,
    };
    final Color? onTone = fushiCardToneColors(context, tone)?.onContainer;
    return FushiCard(
      key: const ValueKey<String>('galgame_detail_hook_status'),
      tone: tone,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Row(
        children: <Widget>[
          FushiListLeadingIcon(
            FushiIcons.hub,
            shape: FushiLeadingShape.cookie,
            tone: tone == FushiCardTone.primary
                ? FushiCardTone.secondary
                : FushiCardTone.primary,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  t.game_capture_running,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.fushiType.titleMediumEmphasized.copyWith(
                    color: onTone,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: <Widget>[
                    FushiTagChip(
                      label: galHookSessionPhaseLabel(state.phase),
                      selected: true,
                    ),
                    FushiTagChip(
                      label: '${t.game_health_audio} · '
                          '${galHookAudioBackendLabel(state.audioBackend)}',
                      tone: FushiTagChipTone.surface,
                    ),
                    if (state.hasText)
                      FushiTagChip(
                        label: t.game_health_text,
                        tone: FushiTagChipTone.surface,
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 纯函数：把最近 [days] 天（以 [end] 当天为最后一天，含当天）的每日秒数铺成折线
/// 图数据点（缺省天为 0，保证整段区间都有点位）。值落 [StatDayData.ms]（秒 ×
/// 1000），与视频统计同款走时长纵轴。返回顺序按日期升序（旧 → 新）。
List<StatDayData> buildGalgameRangeChartData(
  DateTime end,
  int days,
  Map<String, int> secondsByDay,
) {
  final DateTime endDay = DateTime(end.year, end.month, end.day);
  return <StatDayData>[
    for (int i = days - 1; i >= 0; i--)
      () {
        final String key =
            formatGalgameDate(endDay.subtract(Duration(days: i)));
        return StatDayData(dateKey: key)..ms = (secondsByDay[key] ?? 0) * 1000;
      }(),
  ];
}

/// 把折线图纵轴的时长值（毫秒，double）格式化为标签（"Xh Ym" / "Xm" / "Xs"）。
/// 顶层 tear-off 而非闭包，保 [StatLineChartPainter.shouldRepaint] 的函数相等稳定。
String formatGalgameDurationAxis(double ms) =>
    formatStatDurationAxis(ms.round());

/// 一条会话的时间范围文案：`2026-07-24 21:03 → 22:41`（与统计页会话流同一口径，
/// [formatStatSessionRange]）。
String formatGalgameSessionRange(GalgameSessionRow row) =>
    formatStatSessionRange(row.startMs, row.endMs);

/// 编辑 tab：改显示名 / 简介 / 标签 / 开发商 / 日期 / NSFW / 我的评分 / 我的评价，
/// 改 exe 路径与工作目录，以及「刮削元数据」入口。
///
/// 全部用户输入落 `customDataJson`（覆盖层，契约 §1.3）；exe / workdir / 发行日
/// 是 `galgames` 自己的列。保存是一次整行 upsert。
class _GalgameEditTab extends StatefulWidget {
  const _GalgameEditTab({
    required this.game,
    required this.repo,
    required this.onSaved,
  });

  final GalgameEntry game;
  final GalgameRepository repo;
  final Future<void> Function() onSaved;

  @override
  State<_GalgameEditTab> createState() => _GalgameEditTabState();
}

class _GalgameEditTabState extends State<_GalgameEditTab> {
  late final TextEditingController _name =
      TextEditingController(text: widget.game.customData.name ?? '');
  late final TextEditingController _summary =
      TextEditingController(text: widget.game.customData.summary ?? '');
  late final TextEditingController _tags =
      TextEditingController(text: widget.game.customData.tags.join(', '));
  late final TextEditingController _developer =
      TextEditingController(text: widget.game.customData.developer ?? '');
  late final TextEditingController _releaseDate =
      TextEditingController(text: widget.game.releaseDate ?? '');
  late final TextEditingController _rating = TextEditingController(
      text: widget.game.customData.userRating?.toString() ?? '');
  late final TextEditingController _review =
      TextEditingController(text: widget.game.customData.userReview ?? '');
  late final TextEditingController _exePath =
      TextEditingController(text: widget.game.exePath);
  late final TextEditingController _workdir =
      TextEditingController(text: widget.game.workdir);
  late final TextEditingController _launchArgs =
      TextEditingController(text: widget.game.launchArgs);
  late bool _nsfw = widget.game.customData.nsfw ?? false;

  @override
  void dispose() {
    for (final TextEditingController c in <TextEditingController>[
      _name,
      _summary,
      _tags,
      _developer,
      _releaseDate,
      _rating,
      _review,
      _exePath,
      _workdir,
      _launchArgs,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  /// 保存：组装覆盖层 + 整行 upsert。日期格式不合法直接拒绝（该列要拿去排序）。
  Future<void> _save() async {
    final String rawDate = _releaseDate.text.trim();
    final String? date = rawDate.isEmpty ? null : draftDate(rawDate);
    if (rawDate.isNotEmpty && date == null) {
      FushiToast.show(
        msg: t.game_edit_invalid_date,
        severity: ToastSeverity.error,
      );
      return;
    }
    final GalgameEntry game = widget.game;
    final GalgameCustomData custom = GalgameCustomData(
      name: _trimmedOrNull(_name.text),
      coverSource: game.customData.coverSource,
      aliases: game.customData.aliases,
      summary: _trimmedOrNull(_summary.text),
      tags: parseGalgameTagInput(_tags.text),
      developer: _trimmedOrNull(_developer.text),
      nsfw: _nsfw ? true : null,
      userRating: parseGalgameRating(_rating.text),
      userReview: _trimmedOrNull(_review.text),
    );
    final GalgameEntry next = GalgameEntry(
      id: game.id,
      name: game.name,
      exePath: _exePath.text.trim(),
      workdir: _workdir.text.trim(),
      // 这里是**逐字段重建**而非 copyWith：新增列必须在本列表里显式带上，漏一个就会
      // 每次保存静默清空该字段。改 GalgameEntry 字段时务必同步这里（有回归测试守着）。
      launchArgs: _launchArgs.text.trim(),
      // 编辑 Tab 不提供超分档位输入框（它在库页/详情页别处设），但这里必须原样透传：
      // 逐字段重建漏掉它 = 用户每次在编辑页保存都静默把超分设置清回默认。
      upscalingMode: game.upscalingMode,
      // 同上：日语区域档位也不在编辑 Tab 里设（在库页右键菜单），必须原样透传。
      japaneseLocaleMode: game.japaneseLocaleMode,
      coverPath: game.coverPath,
      addedAt: game.addedAt,
      playStatus: game.playStatus,
      primarySource: game.primarySource,
      releaseDate: date,
      customData: custom,
      metadata: game.metadata,
      sortOrder: game.sortOrder,
    );
    await widget.repo.updateEntry(next);
    await widget.onSaved();
    if (!mounted) return;
    FushiToast.show(msg: t.game_edit_saved, severity: ToastSeverity.success);
  }

  /// 刮削：打开统一刮削弹窗（与库页卡菜单「刮削元数据」同一个入口，
  /// [showGalgameScrapeDialog]）。搜索/候选/落库/封面全部在弹窗内闭环；
  /// 预填词取编辑框里的名字（用户可能刚改过），空则退回当前显示名。
  Future<void> _scrape() async {
    final bool applied = await showGalgameScrapeDialog(
      context: context,
      game: widget.game,
      repo: widget.repo,
      initialQuery: _name.text.trim().isEmpty
          ? widget.game.displayName
          : _name.text.trim(),
    );
    if (!applied || !mounted) return;
    await widget.onSaved();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: FushiFilledButton.tonalIcon(
                // 再入守卫在统一弹窗内（每行「使用」行内转圈），按钮无需禁用态。
                onPressed: () => unawaited(_scrape()),
                icon: const FushiIcon(FushiIcons.cloudDownload),
                label: Text(t.game_scrape),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FushiFilledButton.icon(
                onPressed: () => unawaited(_save()),
                icon: const FushiIcon(FushiIcons.save),
                label: Text(t.game_edit_save),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _field('name', _name, t.game_edit_display_name),
        _field('summary', _summary, t.game_edit_summary, maxLines: 4),
        _field('tags', _tags, t.game_edit_tags),
        _field('developer', _developer, t.game_edit_developer),
        _field('releaseDate', _releaseDate, t.game_edit_release_date),
        _field('rating', _rating, t.game_edit_user_rating),
        _field('review', _review, t.game_edit_user_review, maxLines: 3),
        AdaptiveSettingsSwitchRow(
          title: t.game_edit_nsfw,
          value: _nsfw,
          onChanged: (bool v) => setState(() => _nsfw = v),
        ),
        _field('exePath', _exePath, t.game_edit_exe_path),
        _field('workdir', _workdir, t.game_edit_workdir),
        _field(
          'launchArgs',
          _launchArgs,
          t.game_edit_launch_args,
          helperText: t.game_edit_launch_args_hint,
        ),
      ],
    );
  }

  /// 一个带稳定 key 的编辑字段。key 形如 `galgame-edit-exePath`，供集成/widget
  /// 测试定位——按标签文案定位会随 17 语言翻译漂移。
  Widget _field(
    String fieldKey,
    TextEditingController controller,
    String label, {
    int maxLines = 1,
    String? helperText,
  }) {
    return Padding(
      key: ValueKey<String>('galgame-edit-$fieldKey'),
      padding: const EdgeInsets.only(top: 12),
      child: FushiTextFieldControl(
        controller: controller,
        maxLines: maxLines,
        decoration: InputDecoration(
          labelText: label,
          helperText: helperText,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
  }
}

String? _trimmedOrNull(String raw) {
  final String trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// 纯函数：把「逗号分隔标签」输入框解析成去重保序的标签表（半角/全角逗号都认）。
List<String> parseGalgameTagInput(String raw) {
  final List<String> out = <String>[];
  final Set<String> seen = <String>{};
  for (final String part in raw.split(RegExp(r'[,，、]'))) {
    final String tag = part.trim();
    if (tag.isNotEmpty && seen.add(tag)) {
      out.add(tag);
    }
  }
  return out;
}

/// 纯函数：解析「我的评分」输入。空 / 非数字 → null；越界 clamp 到 0-10。
double? parseGalgameRating(String raw) {
  final String trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  final double? value = double.tryParse(trimmed);
  if (value == null || !value.isFinite) return null;
  return value.clamp(0, 10).toDouble();
}

// （旧 `_ScrapeQueryDialog` / `_SourcePickerDialog` 已被统一刮削弹窗
// `showGalgameScrapeDialog` 取代：单弹窗内搜索 + 带缩略图候选 + 行内应用。）
