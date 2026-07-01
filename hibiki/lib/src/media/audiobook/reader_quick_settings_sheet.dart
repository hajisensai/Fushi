import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:hibiki/src/epub/epub_book.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/media/audiobook/audiobook_bridge.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/book_css_editor_page.dart';
import 'package:hibiki/src/settings/cupertino_settings_renderer.dart';
import 'package:hibiki/src/settings/master_detail_settings_sheet.dart';
import 'package:hibiki/src/settings/material_settings_renderer.dart';
import 'package:hibiki/src/settings/settings_actions.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/settings/settings_renderer.dart';
import 'package:hibiki/src/settings/settings_schema.dart';
import 'package:hibiki/utils.dart';

class ReaderQuickSettingsSheet extends StatefulWidget {
  const ReaderQuickSettingsSheet({
    required this.controller,
    required this.toc,
    required this.readerProgress,
    required this.onJumpSection,
    required this.onBookmark,
    required this.onExitReader,
    required this.webViewController,
    required this.appModel,
    required this.ref,
    this.pageProgress,
    this.onThemeChanged,
    this.bookmarks = const [],
    this.onJumpToBookmark,
    this.onDeleteBookmark,
    this.favoriteSentences = const [],
    this.onDeleteFavorite,
    this.onJumpToFavorite,
    this.onPlayFavorite,
    this.showMediaNotification = true,
    this.onToggleMediaNotification,
    this.showFloatingLyric = false,
    this.onToggleFloatingLyric,
    this.floatingLyricFontSize = 20,
    this.onFloatingLyricFontSizeChanged,
    this.floatingLyricClickLookup = true,
    this.onFloatingLyricClickLookupChanged,
    this.onSearchJump,
    this.onJumpToCharOffset,
    this.charProgress,
    this.onPageMarginChanged,
    this.isHibikiReader = false,
    this.epubBook,
    this.chapterLabel,
    this.onStyleChanged,
    this.lyricsMode = false,
    this.onToggleLyricsMode,
    this.extractDir,
    this.onReloadChapter,
    this.onLyricsReload,
    this.onAudioImport,
    super.key,
  });

  final AudiobookPlayerController? controller;
  final List<TtuTocEntry> toc;

  /// 0-indexed section index and total chapter count.
  final (int section, int total)? readerProgress;
  final (int current, int total)? pageProgress;
  final Future<void> Function(int sectionIndex) onJumpSection;
  final Future<void> Function() onBookmark;
  final VoidCallback onExitReader;
  final InAppWebViewController webViewController;
  final AppModel appModel;

  /// Riverpod ref from the reader page, forwarded to the schema-projected
  /// settings so [SettingsContext] always has a real [WidgetRef].
  final WidgetRef ref;
  final Future<void> Function()? onThemeChanged;
  final List<Bookmark> bookmarks;
  final Future<void> Function(Bookmark bookmark)? onJumpToBookmark;
  final Future<void> Function(Bookmark bookmark)? onDeleteBookmark;
  final List<FavoriteSentence> favoriteSentences;
  final Future<void> Function(FavoriteSentence fav)? onDeleteFavorite;
  final Future<void> Function(FavoriteSentence fav)? onJumpToFavorite;
  final Future<void> Function(FavoriteSentence fav)? onPlayFavorite;
  final bool showMediaNotification;
  final VoidCallback? onToggleMediaNotification;
  final bool showFloatingLyric;
  final Future<bool> Function()? onToggleFloatingLyric;
  final double floatingLyricFontSize;
  final ValueChanged<double>? onFloatingLyricFontSizeChanged;
  final bool floatingLyricClickLookup;
  final ValueChanged<bool>? onFloatingLyricClickLookupChanged;
  final Future<void> Function(BookSearchResult result, String query)?
      onSearchJump;
  final Future<void> Function(int globalCharOffset)? onJumpToCharOffset;
  final (int current, int total)? charProgress;
  final VoidCallback? onPageMarginChanged;

  /// Called after any display/style setting changes so the reader can
  /// live-update CSS without a full page reload.
  final Future<void> Function()? onStyleChanged;

  final bool lyricsMode;
  final VoidCallback? onToggleLyricsMode;

  /// When true, skip AudiobookBridge JS calls and disable ttu-only features.
  final bool isHibikiReader;

  final EpubBook? epubBook;

  /// 当前章节名（由阅读器页面经 TOC 反查得到），用于阅读进度区块展示。
  final String? chapterLabel;

  final String? extractDir;
  final Future<void> Function()? onReloadChapter;

  /// TODO-907: 歌词模式整页重建（切竖排/横排）。歌词页是 WebView 整页 HTML，
  /// writing-mode 改了只能重建文档（[_loadLyricsPage]），不能 live 改样式。
  final Future<void> Function()? onLyricsReload;
  final VoidCallback? onAudioImport;

  @override
  State<ReaderQuickSettingsSheet> createState() =>
      _ReaderQuickSettingsSheetState();
}

class _ReaderQuickSettingsSheetState extends State<ReaderQuickSettingsSheet> {
  ReaderHibikiSource get _src => ReaderHibikiSource.instance;

  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _charJumpController = TextEditingController();
  List<BookSearchResult> _searchResults = const [];
  String _searchResultsQuery = '';
  int _searchGeneration = 0;
  bool _isSearching = false;
  bool _layoutReloading = false;

  String? _subPage;

  /// 最近一次 LayoutBuilder 是否判定为宽窗。供 PopScope.canPop 读取：宽窗
  /// master-detail 下选中态非 null 也允许直接关闭（不会卡在「返回上一级」）。
  /// 纯按窗口宽高确定性判定（>= 共享常量阈值），与视频设置同条件。
  bool _isWide = false;

  late List<Bookmark> _bookmarks = List<Bookmark>.of(widget.bookmarks);
  late List<FavoriteSentence> _favorites =
      List<FavoriteSentence>.of(widget.favoriteSentences);

  // Local mirror of the audiobook overlay toggles. These are NOT schema items:
  // flipping them needs reader-page side effects (overlay show/hide, permission
  // request, live floating-lyric style) that a preference-only schema item
  // cannot perform, so the rows stay bespoke and call back into the page.
  late bool _localShowFloatingLyric = widget.showFloatingLyric;
  late bool _localShowMediaNotification = widget.showMediaNotification;
  late bool _localFloatingLyricClickLookup = widget.floatingLyricClickLookup;
  late double _localFloatingLyricFontSize = widget.floatingLyricFontSize;

  @override
  void dispose() {
    _searchController.dispose();
    _charJumpController.dispose();
    super.dispose();
  }

  Future<void> _updateSetting(String key, Object value) async {
    if (!widget.isHibikiReader) {
      await AudiobookBridge.setReaderSetting(
        widget.webViewController,
        key: key,
        value: value,
      );
    }
    final ReaderHibikiSource src = ReaderHibikiSource.instance;
    switch (key) {
      case 'fontSize':
        await src.setTtuFontSize((value as num).toDouble());
      case 'lineHeight':
        await src.setTtuLineHeight((value as num).toDouble());
      case 'writingMode':
        await src.setTtuWritingMode(value as String);
        widget.onPageMarginChanged?.call();
      case 'viewMode':
        await src.setTtuViewMode(value as String);
      case 'theme':
        await src.setTtuTheme(value as String);
      case 'hideFurigana':
        await src.setTtuFuriganaMode((value as bool) ? 'hide' : 'toggle');
      case 'textIndentation':
        await src.setTtuTextIndentation((value as num).toDouble());
      case 'marginTop':
        await src.setTtuMarginTop((value as num).toDouble());
        widget.onPageMarginChanged?.call();
      case 'marginBottom':
        await src.setTtuMarginBottom((value as num).toDouble());
        widget.onPageMarginChanged?.call();
      case 'marginLeft':
        await src.setTtuMarginLeft((value as num).toDouble());
        widget.onPageMarginChanged?.call();
      case 'marginRight':
        await src.setTtuMarginRight((value as num).toDouble());
        widget.onPageMarginChanged?.call();
      case 'pageColumns':
        await src.setTtuPageColumns((value as num).toInt());
      case 'spreadMode':
        await src.setTtuSpreadMode(value as String);
      case 'spreadDirection':
        await src.setTtuSpreadDirection(value as String);
      case 'enableVerticalFontKerning':
        await src.setTtuEnableVerticalFontKerning(value as bool);
      case 'enableFontVPAL':
        await src.setTtuEnableFontVPAL(value as bool);
      case 'verticalTextOrientation':
        await src.setTtuVerticalTextOrientation(value as String);
      case 'enableTextJustification':
        await src.setTtuEnableTextJustification(value as bool);
      case 'prioritizeReaderStyles':
        await src.setTtuPrioritizeReaderStyles(value as bool);
    }
    if (widget.isHibikiReader) {
      const layoutKeys = {
        'writingMode',
        'viewMode',
        'pageColumns',
        'spreadMode',
        'spreadDirection',
        'prioritizeReaderStyles'
      };
      if (layoutKeys.contains(key)) {
        await _reloadLayoutLive();
      } else {
        await widget.onStyleChanged?.call();
      }
    }
  }

  Future<void> _reloadLayoutLive() async {
    final Future<void> Function()? reload = widget.onReloadChapter;
    if (reload == null || _layoutReloading) return;
    _layoutReloading = true;
    try {
      await reload();
    } finally {
      _layoutReloading = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return HibikiMasterDetailSettingsSheet(
      // 宽窗 master-detail：选中态始终有值（默认 appearance），返回键应直接关
      // 弹窗而非退回「未选中」；窄窗 push 时保留原「先回主页」语义。
      subPageActive: _subPage != null,
      onPopToParent: () => setState(() => _subPage = null),
      isWide: _isWide,
      onWideChanged: (bool wide) => _isWide = wide,
      narrowKey: () => ValueKey<String>(_subPage ?? 'main'),
      // 窄窗 padding：水平 page + gap/2，底部叠 card + gap + 键盘 inset（与视频不同，
      // 视频用 page + gap，不可统一）。
      narrowPadding: (BuildContext context, BoxConstraints constraints) {
        final double viewInsetsBottom =
            MediaQuery.of(context).viewInsets.bottom;
        return EdgeInsets.fromLTRB(
          tokens.spacing.page + tokens.spacing.gap / 2,
          tokens.spacing.gap / 2,
          tokens.spacing.page + tokens.spacing.gap / 2,
          tokens.spacing.card + tokens.spacing.gap + viewInsetsBottom,
        );
      },
      // 窄窗（含全部手机 bottom sheet）：维持现有 push 行为，外观仍内联。
      narrowChild: (BuildContext context, BoxConstraints constraints) {
        return _subPage != null
            ? _buildSubPage(context, theme)
            : _buildMainPage(context, theme);
      },
      // 宽窗左右 master-detail（左父菜单 + 右详情）——视频走顶部分类条，两边发散，
      // 故 MaterialSupportingPaneLayout / SupportingPaneSide 等符号留在此回调里。
      wideBuilder: (BuildContext context, BoxConstraints constraints) {
        final double viewInsetsBottom =
            MediaQuery.of(context).viewInsets.bottom;
        // TODO-725：导航置首后宽窗默认选中改 'location'（不再默认 appearance）。
        final String selectedId = _subPage ?? 'location';
        final Color dividerColor = isCupertinoPlatform(context)
            ? CupertinoColors.separator.resolveFrom(context)
            : HibikiDesignTokens.of(context).surfaces.outline;
        final double wideHorizontalInset =
            tokens.spacing.page + tokens.spacing.gap / 2;
        final EdgeInsets wideSupportingPadding = EdgeInsets.fromLTRB(
          wideHorizontalInset,
          tokens.spacing.gap / 2,
          wideHorizontalInset,
          tokens.spacing.card + tokens.spacing.gap + viewInsetsBottom,
        );
        final EdgeInsets widePrimaryPadding = EdgeInsets.fromLTRB(
          wideHorizontalInset,
          tokens.spacing.gap / 2,
          wideHorizontalInset,
          tokens.spacing.card + tokens.spacing.gap + viewInsetsBottom,
        );
        // 用可用的有界高度撑满整张 master-detail（等价于主页设置把
        // MaterialSupportingPaneLayout 放进 Expanded）：Row(stretch) 才能给
        // 两个 pane 紧约束 → 各自的 SingleChildScrollView 独立滚动、左父菜
        // 单固定不跟随右详情滚动。maxHeightFactor 保证 maxHeight 有界。
        return SizedBox(
          height: constraints.maxHeight,
          child: MaterialSupportingPaneLayout(
            minSplitWidth: kHibikiSettingsWideThreshold,
            supportingWidth: kHibikiSettingsSupportingPaneWidth,
            supportingSide: SupportingPaneSide.start,
            dividerColor: dividerColor,
            // 左父菜单项不多时垂直居中（progress/分类/动作整体居中），
            // 不再让「阅读进度」死贴顶端；内容超过 pane 高度时
            // ConstrainedBox 的 minHeight 被内容满足，照常滚动。
            supporting: LayoutBuilder(
              builder: (
                BuildContext context,
                BoxConstraints paneConstraints,
              ) {
                final double minContentHeight = paneConstraints.maxHeight >
                        wideSupportingPadding.vertical
                    ? paneConstraints.maxHeight - wideSupportingPadding.vertical
                    : 0;
                return SingleChildScrollView(
                  padding: wideSupportingPadding,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: minContentHeight,
                    ),
                    child: _buildWidePane(context, theme, selectedId),
                  ),
                );
              },
            ),
            // KeyedSubtree：按选中 id 编码，切换时整棵右 pane 子树作废重
            // 建，避免 Flutter 复用上一详情同位置 Element 触发 Switch 圆点
            // / Segmented 滑动等复用副作用（同 settings_home_page）。
            primary: KeyedSubtree(
              key: ValueKey<String>(selectedId),
              child: SingleChildScrollView(
                padding: widePrimaryPadding,
                child: _buildWidePrimary(context, theme, selectedId),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildWidePane(
    BuildContext context,
    ThemeData theme,
    String selectedId,
  ) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final double sectionGap = tokens.spacing.gap + tokens.spacing.gap / 2;
    // 左父菜单只留「分类导航 + 动作」，做矮以让更多窗口进宽窗（阅读进度已移到右侧
    // 外观详情顶部，见 [_buildWidePrimary]）。项少时整体垂直居中、不贴顶。
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final cat in _wideCategories())
          HibikiListItem(
            selected: cat.id == selectedId,
            selectedShape: HibikiListItemSelectedShape.pill,
            leading: Icon(cat.icon),
            title: Text(cat.label),
            onTap: () => setState(() => _subPage = cat.id),
          ),
        SizedBox(height: sectionGap),
        _buildActionRow(context),
      ],
    );
  }

  /// 宽窗右详情：默认分类（导航置首后为 'location'）顶部并入阅读进度（左父菜单不
  /// 再单列进度，借此把左栏做矮、更多窗口能进宽窗）。其余分类只渲染各自详情。
  Widget _buildWidePrimary(
    BuildContext context,
    ThemeData theme,
    String selectedId,
  ) {
    if (selectedId != 'location') {
      return _subPageContent(selectedId);
    }
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final double sectionGap = tokens.spacing.gap + tokens.spacing.gap / 2;
    final Widget progress = _buildProgressSection(theme);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (progress is! SizedBox) ...[
          progress,
          SizedBox(height: sectionGap),
        ],
        _subPageContent(selectedId),
      ],
    );
  }

  /// 宽窗 master-detail 左 pane 的分类项（id 与 [_subPageContent] 的 case 对齐）。
  /// audiobook 仅在有 controller 时出现。
  List<({String id, IconData icon, String label})> _wideCategories() {
    // TODO-725 / TODO-802：导航置首（location → layout → behavior → lookup →
    // [audiobook]）。「外观」组已删，主题选择器并入 layout（见 _buildLayoutDetail）。
    // 与窄窗主页 navigationRows 顺序保持一致。
    return <({String id, IconData icon, String label})>[
      (
        id: 'location',
        icon: Icons.menu_book_outlined,
        label: t.section_navigation,
      ),
      (
        id: 'layout',
        icon: Icons.auto_stories_outlined,
        label: t.section_layout
      ),
      (
        id: 'behavior',
        icon: Icons.touch_app_outlined,
        label: t.settings_destination_reading_controls,
      ),
      (
        id: 'lookup',
        icon: Icons.manage_search_outlined,
        label: t.settings_destination_lookup,
      ),
      if (widget.controller != null)
        (
          id: 'audiobook',
          icon: Icons.headphones_outlined,
          label: t.section_audiobook,
        ),
    ];
  }

  Widget _buildMainPage(BuildContext context, ThemeData theme) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final double sectionGap = tokens.spacing.gap + tokens.spacing.gap / 2;
    // TODO-725（手机/窄窗折叠）/ TODO-802：主页只剩「阅读进度 + 分类导航行 + 动作
    // 行」。「外观」组已删，主题选择器并入 layout 子页顶部（见 _buildLayoutDetail）。
    // 导航置首：location → layout → behavior → lookup → [audiobook]，与宽窗
    // _wideCategories 顺序一致。
    final List<Widget> navigationRows = [
      _categoryTile(
        icon: Icons.menu_book_outlined,
        label: t.section_navigation,
        page: 'location',
      ),
      _categoryTile(
        icon: Icons.auto_stories_outlined,
        label: t.section_layout,
        page: 'layout',
      ),
      _categoryTile(
        icon: Icons.touch_app_outlined,
        label: t.settings_destination_reading_controls,
        page: 'behavior',
      ),
      _categoryTile(
        icon: Icons.manage_search_outlined,
        label: t.settings_destination_lookup,
        page: 'lookup',
      ),
      if (widget.controller != null)
        _categoryTile(
          icon: Icons.headphones_outlined,
          label: t.section_audiobook,
          page: 'audiobook',
        ),
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildProgressSection(theme),
        SizedBox(height: sectionGap),
        AdaptiveSettingsSection(children: navigationRows),
        SizedBox(height: sectionGap),
        _buildActionRow(context),
      ],
    );
  }

  Widget _buildSubPage(BuildContext context, ThemeData theme) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final String page = _subPage!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HibikiSettingsSubPageHeader(
          title: _subPageTitle(page),
          onBack: () => setState(() => _subPage = null),
        ),
        SizedBox(height: tokens.spacing.gap + tokens.spacing.gap / 2),
        _subPageContent(page),
      ],
    );
  }

  /// 某分类的详情内容（不含返回页头）。窄窗 push 子页与宽窗右 pane 共用。
  Widget _subPageContent(String page) {
    switch (page) {
      case 'layout':
        // Lyrics mode keeps its bespoke font/margin controls — those are not
        // schema items (they write lyrics-only `setLyrics*` setters) — but still
        // exposes the theme selector + book-CSS row via _buildLyricsDisplaySection
        // so the theme/CSS stay reachable after the appearance group was dropped
        // (TODO-802 reachability).
        return widget.lyricsMode
            ? _buildLyricsDisplaySection()
            : _buildLayoutDetail();
      case 'behavior':
        return _buildReaderGroupContent(
          ReaderGroup.behavior,
          t.settings_destination_reading_controls,
        );
      case 'lookup':
        return _buildReaderGroupContent(
          ReaderGroup.lookup,
          t.settings_destination_lookup,
        );
      case 'location':
        return _buildLocationSection(Theme.of(context));
      case 'audiobook':
        return _buildAudiobookSettingsSection(Theme.of(context));
      default:
        return const SizedBox.shrink();
    }
  }

  String _subPageTitle(String page) {
    switch (page) {
      case 'layout':
        return t.section_layout;
      case 'behavior':
        return t.settings_destination_reading_controls;
      case 'lookup':
        return t.settings_destination_lookup;
      case 'location':
        return t.section_navigation;
      case 'audiobook':
        return t.section_audiobook;
      default:
        return '';
    }
  }

  /// 把某个 [ReaderGroup] 投影成 schema 渲染内容。写路径走 schema item 的
  /// `setTtu*` + notify helper，与本面板的 `_updateSetting` 落同一存储。
  ///
  /// 实时更新由 notify helper 经 `ReaderHibikiSource` 的回调驱动，且是按 key
  /// 精确的：CSS-only key 走 `notifyReaderSettingsChanged`（=
  /// `onSettingsChangedLive`，CSS 注入），结构性布局 key（view mode / writing
  /// mode / columns / spread / prioritize reader styles）走
  /// `notifyReaderLayoutChanged`（= `onLayoutReloadLive`，整章重排）。schema
  /// 投影项实时从 `ReaderHibikiSource.instance` 读写，本 refresh 回调只需
  /// setState 重读 live 值即可。
  SettingsContext _settingsContext() {
    return SettingsContext(
      context: context,
      appModel: widget.appModel,
      ref: widget.ref,
      readerSource: ReaderHibikiSource.instance,
      refresh: () {
        if (!mounted) return;
        setState(() {});
      },
    );
  }

  Widget _buildReaderGroupContent(ReaderGroup group, String title) {
    final SettingsContext settingsContext = _settingsContext();
    return _buildSettingsDestinationContent(
      settingsContext,
      buildReaderGroupDestination(settingsContext, group, title),
    );
  }

  Widget _buildSettingsDestinationContent(
    SettingsContext settingsContext,
    SettingsDestination destination,
  ) {
    final bool cupertino = isCupertinoPlatform(context);
    final SettingsRenderer renderer = cupertino
        ? const CupertinoSettingsRenderer()
        : const MaterialSettingsRenderer();
    return renderer.buildDetailContent(
      settingsContext: settingsContext,
      destination: destination,
      shrinkWrap: true,
    );
  }

  /// 主题行专用 [SettingsContext]：换肤后除 setState 外还要 `_syncThemeSelection`
  /// （把 appThemeKey 落 reader 设置 + 触发 `onThemeChanged` 的词典/歌词联动）。
  /// 与 appearance 其它行的普通 `_settingsContext()` 区分，故单列一个工厂。
  SettingsContext _themeSettingsContext() {
    return SettingsContext(
      context: context,
      appModel: widget.appModel,
      ref: widget.ref,
      readerSource: ReaderHibikiSource.instance,
      refresh: () {
        if (!mounted) return;
        unawaited(_syncThemeSelection());
        setState(() {});
      },
    );
  }

  Future<void> _syncThemeSelection() async {
    await _updateSetting('theme', widget.appModel.appThemeKey);
    await widget.onThemeChanged?.call();
  }

  /// 主题选择器卡。TODO-802：「外观」组删除后，主题（阅读纸张配色，改的也是阅读
  /// 显示）并入「布局与显示」子页顶部；普通布局子页与歌词模式子页共用此卡，保证
  /// 删外观组后主题仍可达。主题行用专门的 [_themeSettingsContext]（换肤后还要
  /// `_syncThemeSelection` 落 reader 设置 + 触发词典/歌词联动）。
  Widget _buildThemeSelectorSection() {
    return AdaptiveSettingsSection(
      children: <Widget>[buildThemeSelector(_themeSettingsContext())],
    );
  }

  /// 「编辑书籍 CSS」入口行。归类语义对齐：CSS 改的是排版（字号/行高/边距等同
  /// 一维度），属「布局与显示」组而非「外观」，故随 layout 子页渲染（窄窗 push
  /// 子页 + 宽窗右 pane 共用）。仅当书籍解压目录可用（`extractDir != null`）时
  /// 出现；点击打开 [BookCssEditorPage]，返回后整章重排以应用新 CSS。
  Widget _buildBookCssEditorRow() {
    return AdaptiveSettingsNavigationRow(
      title: t.book_css_editor_edit_css,
      icon: Icons.code_outlined,
      onTap: () async {
        await Navigator.push(
          context,
          adaptivePageRoute(
            builder: (_) => BookCssEditorPage(extractDir: widget.extractDir!),
          ),
        );
        await _reloadLayoutLive();
      },
    );
  }

  /// 「布局与显示」子页详情：主题选择器（TODO-802 并入）→ layout schema 行 →
  /// 可选「编辑书籍 CSS」行。窄窗 push 子页与宽窗右 pane 共用（经
  /// [_subPageContent] 的 'layout' 分支）。
  Widget _buildLayoutDetail() {
    final Widget layoutContent =
        _buildReaderGroupContent(ReaderGroup.layout, t.section_layout);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _buildThemeSelectorSection(),
        layoutContent,
        if (widget.extractDir != null)
          AdaptiveSettingsSection(
            children: <Widget>[_buildBookCssEditorRow()],
          ),
      ],
    );
  }

  Widget _buildLocationSection(ThemeData theme) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final double sectionGap = tokens.spacing.gap + tokens.spacing.gap / 2;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.epubBook != null && widget.onSearchJump != null)
          _buildSearchSection(theme),
        if (widget.onJumpToCharOffset != null) ...[
          SizedBox(height: sectionGap),
          _buildCharJumpSection(theme),
        ],
        if (widget.toc.isNotEmpty) ...[
          SizedBox(height: sectionGap),
          _buildTocSection(context, theme),
        ],
        if (_bookmarks.isNotEmpty) ...[
          SizedBox(height: sectionGap),
          _buildBookmarkSection(context, theme),
        ],
        if (_favorites.isNotEmpty) ...[
          SizedBox(height: sectionGap),
          _buildFavoritesSection(context, theme),
        ],
      ],
    );
  }

  Widget _categoryTile({
    required IconData icon,
    required String label,
    required String page,
  }) {
    return AdaptiveSettingsNavigationRow(
      title: label,
      icon: icon,
      onTap: () => setState(() => _subPage = page),
    );
  }

  Widget _buildProgressSection(ThemeData theme) {
    final List<String> lines = [];

    final (int, int)? rp = widget.readerProgress;
    if (rp != null && rp.$2 > 0) {
      final int displayIdx = rp.$1 + 1;
      final double pct = (displayIdx / rp.$2) * 100;
      lines.add(t.chapter_progress(
        idx: displayIdx,
        total: rp.$2,
        suffix: '',
        pct: pct.toStringAsFixed(1),
      ));
    }

    final (int, int)? pp = widget.pageProgress;
    if (pp != null && pp.$2 > 0) {
      lines.add(t.page_progress(current: pp.$1, total: pp.$2));
    }

    final AudiobookPlayerController? ctrl = widget.controller;
    final String? rawTitle = widget.epubBook?.title.trim();
    final String? rawChapter = widget.chapterLabel?.trim();
    final bool hasTitle = rawTitle != null && rawTitle.isNotEmpty;
    final bool hasChapter = rawChapter != null && rawChapter.isNotEmpty;
    if (lines.isEmpty && ctrl == null && !hasTitle && !hasChapter) {
      return const SizedBox.shrink();
    }
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsSectionHeader(
          t.reading_progress,
          padding: EdgeInsets.only(bottom: tokens.spacing.gap),
        ),
        if (hasTitle)
          Text(
            rawTitle,
            style: theme.textTheme.titleSmall,
          ),
        if (hasChapter)
          Text(
            rawChapter,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        for (final String line in lines)
          Text(line, style: theme.textTheme.bodyMedium),
        if (ctrl != null) _buildAudioProgressLine(theme, ctrl),
      ],
    );
  }

  /// 音频播放进度行（position / duration），跟随控制器 notifyListeners 刷新
  /// （cue 切换 / 播放暂停时触发，与 `_buildSpeedSection` 同一订阅模式）。
  Widget _buildAudioProgressLine(
    ThemeData theme,
    AudiobookPlayerController ctrl,
  ) {
    return ListenableBuilder(
      listenable: ctrl,
      builder: (BuildContext context, _) {
        final Duration pos = ctrl.globalPosition;
        final Duration dur = ctrl.totalDuration;
        final double fraction = dur.inMilliseconds > 0
            ? (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0)
            : 0.0;
        final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
        return Padding(
          padding: EdgeInsets.only(top: tokens.spacing.gap / 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${_formatDuration(pos)} / ${_formatDuration(dur)}',
                style: theme.textTheme.bodyMedium,
              ),
              SizedBox(height: tokens.spacing.gap / 2),
              ClipRRect(
                borderRadius: tokens.radii.chipRadius,
                child: LinearProgressIndicator(
                  value: fraction,
                  minHeight: 3,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  static String _formatDuration(Duration d) {
    final int totalSeconds = d.inSeconds;
    final int hours = totalSeconds ~/ 3600;
    final int minutes = (totalSeconds % 3600) ~/ 60;
    final int seconds = totalSeconds % 60;
    final String ss = seconds.toString().padLeft(2, '0');
    final String mm = minutes.toString().padLeft(2, '0');
    if (hours > 0) {
      return '$hours:$mm:$ss';
    }
    return '$mm:$ss';
  }

  Future<void> _doSearch() async {
    final String query = _searchController.text.trim();
    if (query.isEmpty) return;
    final int gen = ++_searchGeneration;
    setState(() => _isSearching = true);
    try {
      final List<BookSearchResult> results = widget.epubBook != null
          ? await AudiobookBridge.searchBook(widget.epubBook!, query)
          : const <BookSearchResult>[];
      if (!mounted || gen != _searchGeneration) return;
      setState(() {
        _searchResults = results;
        _searchResultsQuery = query;
        _isSearching = false;
      });
    } catch (e, stack) {
      ErrorLogService.instance.log('AudiobookPlayBar.search', e, stack);
      debugPrint('[hibiki-search] error: $e');
      if (!mounted || gen != _searchGeneration) return;
      setState(() {
        _searchResults = const [];
        _searchResultsQuery = '';
        _isSearching = false;
      });
    }
  }

  Widget _buildSearchSection(ThemeData theme) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsSectionHeader(
          t.book_search,
          padding: EdgeInsets.only(bottom: tokens.spacing.gap),
        ),
        Row(
          children: [
            Expanded(
              child: HibikiTextField(
                controller: _searchController,
                hintText: t.book_search_hint,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: tokens.spacing.rowHorizontal,
                  vertical: tokens.spacing.rowVertical,
                ),
                style: theme.textTheme.bodyMedium,
                onSubmitted: (_) => _doSearch(),
              ),
            ),
            SizedBox(width: tokens.spacing.gap),
            SizedBox.square(
              dimension: 40,
              child: Center(
                child: _isSearching
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child:
                            adaptiveIndicator(context: context, strokeWidth: 2),
                      )
                    : HibikiIconButton(
                        icon: Icons.search,
                        size: 20,
                        backgroundColor: theme.colorScheme.secondaryContainer,
                        enabledColor: theme.colorScheme.onSecondaryContainer,
                        padding: EdgeInsets.all(tokens.spacing.gap),
                        tooltip: t.search,
                        onTap: _doSearch,
                      ),
              ),
            ),
          ],
        ),
        if (_searchResults.isNotEmpty) ...[
          SizedBox(height: tokens.spacing.gap),
          Text(
            t.book_search_results(n: _searchResults.length),
            style: theme.textTheme.bodySmall,
          ),
          SizedBox(height: tokens.spacing.gap / 2),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 280),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _searchResults.length,
              itemBuilder: (_, i) {
                final BookSearchResult r = _searchResults[i];
                final String query = _searchResultsQuery;
                final int rawIdx = r.sectionIndex;
                final List<TtuTocEntry> toc = widget.toc;
                final TtuTocEntry? tocEntry =
                    toc.cast<TtuTocEntry?>().firstWhere(
                          (e) => e!.index == rawIdx,
                          orElse: () => null,
                        );
                final String chapterLabel =
                    tocEntry?.label ?? t.go_to_chapter(n: rawIdx + 1);

                final String before = r.context.substring(0, r.matchStart);
                final int matchEnd =
                    (r.matchStart + query.length).clamp(0, r.context.length);
                final String match =
                    r.context.substring(r.matchStart, matchEnd);
                final String after = r.context.substring(matchEnd);

                return _InBookSearchResultRow(
                  chapterLabel: chapterLabel,
                  before: before,
                  match: match,
                  after: after,
                  onTap: () async {
                    final String q = _searchResultsQuery;
                    Navigator.pop(context);
                    await widget.onSearchJump?.call(r, q);
                  },
                );
              },
            ),
          ),
        ] else if (!_isSearching &&
            _searchController.text.trim().isNotEmpty) ...[
          SizedBox(height: tokens.spacing.gap),
          Text(
            t.book_search_no_results,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ],
    );
  }

  Widget _buildCharJumpSection(ThemeData theme) {
    final int? current = widget.charProgress?.$1;
    final int? total = widget.charProgress?.$2;
    final bool hasProgress = current != null && total != null && total > 0;
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsSectionHeader(
          t.jump_to_char,
          padding: EdgeInsets.only(bottom: tokens.spacing.gap),
        ),
        if (hasProgress)
          Padding(
            padding: EdgeInsets.only(bottom: tokens.spacing.gap),
            child: Text(
              t.jump_to_char_current(current: current, total: total),
              style: theme.textTheme.bodySmall,
            ),
          ),
        Row(
          children: [
            Expanded(
              child: HibikiTextField(
                controller: _charJumpController,
                keyboardType: TextInputType.number,
                hintText: t.jump_to_char_hint,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: tokens.spacing.rowHorizontal,
                  vertical: tokens.spacing.rowVertical,
                ),
                style: theme.textTheme.bodyMedium,
                onSubmitted: (_) => _doCharJump(context),
              ),
            ),
            SizedBox(width: tokens.spacing.gap),
            SizedBox.square(
              dimension: 40,
              child: Center(
                child: HibikiIconButton(
                  icon: Icons.arrow_forward,
                  size: 20,
                  backgroundColor: theme.colorScheme.secondaryContainer,
                  enabledColor: theme.colorScheme.onSecondaryContainer,
                  padding: EdgeInsets.all(tokens.spacing.gap),
                  tooltip: t.jump_to_char,
                  onTap: () => _doCharJump(context),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  void _doCharJump(BuildContext context) {
    final String text = _charJumpController.text.trim();
    if (text.isEmpty) return;
    final int? target = int.tryParse(text);
    if (target == null || target < 0) return;
    Navigator.pop(context);
    widget.onJumpToCharOffset?.call(target);
  }

  Widget _buildTocSection(BuildContext context, ThemeData theme) {
    final int? currentIdx = widget.readerProgress?.$1;
    return AdaptiveSettingsSection(
      title: t.toc_section(n: widget.toc.length),
      children: [
        for (final TtuTocEntry entry in widget.toc)
          _InBookTocRow(
            entry: entry,
            selected: !entry.isHeader && currentIdx == entry.index,
            onTap: entry.isHeader
                ? null
                : () async {
                    Navigator.of(context).pop();
                    await widget.onJumpSection(entry.index);
                  },
          ),
      ],
    );
  }

  Widget _buildBookmarkSection(BuildContext context, ThemeData theme) {
    final DateFormat fmt = DateFormat('MM/dd HH:mm');
    return AdaptiveSettingsSection(
      title: '${t.action_bookmark} (${_bookmarks.length})',
      children: [
        for (final Bookmark bookmark in _bookmarks)
          _InBookBookmarkRow(
            bookmark: bookmark,
            dateLabel: fmt.format(bookmark.createdAt),
            onTap: () async {
              Navigator.of(context).pop();
              await widget.onJumpToBookmark?.call(bookmark);
            },
            onDelete: () async {
              await widget.onDeleteBookmark?.call(bookmark);
              if (mounted) {
                setState(() {
                  _bookmarks = List<Bookmark>.of(_bookmarks)..remove(bookmark);
                });
              }
            },
          ),
      ],
    );
  }

  Widget _buildVolumeSection(AudiobookPlayerController ctrl) {
    return AudiobookVolumeRow(
      volume: ctrl.volume,
      onChanged: (double v) {
        ctrl.setVolume(v);
        setState(() {});
      },
    );
  }

  Widget _buildSpeedSection(AudiobookPlayerController ctrl) {
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) {
        final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
        final double current = ctrl.speed;
        return AdaptiveSettingsRow(
          title: '${t.playback_speed} (${current.toStringAsFixed(2)}x)',
          icon: Icons.speed_outlined,
          controlBelow: true,
          trailing: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              gamepadSeekableSlider(
                value: current.clamp(0.25, 3.0),
                min: 0.25,
                max: 3,
                divisions: 55,
                onChanged: (v) {
                  final double rounded = (v * 20).roundToDouble() / 20;
                  ctrl.setSpeed(rounded);
                },
              ),
              Align(
                alignment: Alignment.centerRight,
                child: HibikiIconButton(
                  icon: Icons.restart_alt_outlined,
                  size: 18,
                  enabled: (current - 1.0).abs() >= 0.001,
                  padding: EdgeInsets.all(tokens.spacing.gap / 2),
                  onTap: () => ctrl.setSpeed(1),
                  tooltip: t.av_sync_reset,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  static String _formatDelayMs(int ms) {
    final String sign = ms > 0 ? '+' : '';
    final int abs = ms.abs();
    if (abs < 1000) return '$sign${ms}ms';
    final double sec = ms / 1000;
    return '$sign${sec.toStringAsFixed(1)}s';
  }

  Widget _buildDelaySection(ThemeData theme, AudiobookPlayerController ctrl) {
    return ValueListenableBuilder<int>(
      valueListenable: ctrl.delayMs,
      builder: (ctx, ms, _) {
        return AdaptiveSettingsRow(
          title: t.av_sync,
          icon: Icons.sync_outlined,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _RepeatIconButton(
                icon: Icons.keyboard_double_arrow_left,
                tooltip: '-1000ms',
                onPressed: () => ctrl.setDelayMs(ctrl.delayMs.value - 1000),
              ),
              _RepeatIconButton(
                icon: Icons.chevron_left,
                tooltip: '-50ms',
                onPressed: () => ctrl.setDelayMs(ctrl.delayMs.value - 50),
              ),
              HibikiFocusable(
                onTap: ms == 0 ? null : () => ctrl.setDelayMs(0),
                child: SizedBox(
                  width: 72,
                  child: Text(
                    _formatDelayMs(ms),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              _RepeatIconButton(
                icon: Icons.chevron_right,
                tooltip: '+50ms',
                onPressed: () => ctrl.setDelayMs(ctrl.delayMs.value + 50),
              ),
              _RepeatIconButton(
                icon: Icons.keyboard_double_arrow_right,
                tooltip: '+1000ms',
                onPressed: () => ctrl.setDelayMs(ctrl.delayMs.value + 1000),
              ),
            ],
          ),
        );
      },
    );
  }

  static const List<int> _imagePauseOptions = [0, 5, 10, 15];

  static const List<int> _skipActionOptions = [0, 5, 10, 15, 30];

  Widget _buildSkipActionSection() {
    final int current = _src.skipActionSeconds;
    return AdaptiveSettingsPickerRow<int>(
      title: t.skip_action,
      icon: Icons.skip_next_outlined,
      options: _skipActionOptions
          .map((s) => AdaptiveSettingsPickerOption<int>(
                value: s,
                label: s == 0
                    ? t.skip_action_sentence
                    : t.skip_action_seconds(n: s),
              ))
          .toList(),
      selected: current,
      onChanged: (int value) {
        _src.setSkipActionSeconds(value);
        setState(() {});
      },
    );
  }

  Widget _buildImagePauseSection(AudiobookPlayerController ctrl) {
    return ValueListenableBuilder<int>(
      valueListenable: ctrl.imagePauseSec,
      builder: (ctx, sec, _) {
        return AdaptiveSettingsSegmentedRow<int>(
          title: t.image_pause,
          subtitle: t.image_pause_hint,
          icon: Icons.image_outlined,
          controlBelow: true,
          segments: _imagePauseOptions
              .map((s) => ButtonSegment<int>(
                    value: s,
                    label: Text(s == 0 ? t.image_pause_off : '${s}s'),
                    tooltip: s == 0 ? t.image_pause_off : '${s}s',
                  ))
              .toList(),
          selected: sec,
          onChanged: ctrl.setImagePauseSec,
        );
      },
    );
  }

  /// Bespoke audiobook overlay toggles. Not schema items: each toggle drives a
  /// reader-page side effect (media-notification publish/clear, floating-lyric
  /// overlay show/hide + permission request, live floating-lyric restyle) that
  /// a preference-only schema item cannot perform. The global Listening page
  /// keeps the plain preference toggles for the no-reader-open case.
  Widget _buildPlayBarToggle() {
    return AdaptiveSettingsSection(
      children: [
        AdaptiveSettingsSwitchRow(
          title: t.show_media_notification,
          value: _localShowMediaNotification,
          onChanged: (_) {
            widget.onToggleMediaNotification?.call();
            setState(() {
              _localShowMediaNotification = !_localShowMediaNotification;
            });
          },
        ),
        AdaptiveSettingsSwitchRow(
          title: t.show_floating_lyric,
          subtitle: t.floating_lyric_hint,
          value: _localShowFloatingLyric,
          onChanged: (_) async {
            final bool ok = await widget.onToggleFloatingLyric?.call() ?? false;
            if (ok && mounted) {
              setState(() {
                _localShowFloatingLyric = !_localShowFloatingLyric;
              });
            }
          },
        ),
        AdaptiveSettingsStepperRow(
          title: t.floating_lyric_font_size,
          value: _localFloatingLyricFontSize,
          step: 1,
          min: 8,
          max: 64,
          format: (double value) => '${value.round()}',
          onChanged: (double value) {
            widget.onFloatingLyricFontSizeChanged?.call(value);
            setState(() => _localFloatingLyricFontSize = value);
          },
        ),
        AdaptiveSettingsSwitchRow(
          title: t.floating_lyric_click_lookup,
          subtitle: t.floating_lyric_click_lookup_hint,
          value: _localFloatingLyricClickLookup,
          onChanged: (_) {
            final bool value = !_localFloatingLyricClickLookup;
            widget.onFloatingLyricClickLookupChanged?.call(value);
            setState(() => _localFloatingLyricClickLookup = value);
          },
        ),
      ],
    );
  }

  Widget _buildAudiobookSettingsSection(ThemeData theme) {
    // The audiobook overlay toggles persist via AppModel but need reader-page
    // side effects, so they are rendered bespoke (not via the schema). With no
    // audiobook loaded, the toggles are the entire sub-page.
    if (widget.controller == null) {
      return _buildPlayBarToggle();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Runtime transport controls — read live state off `widget.controller`,
        // not preferences, so they stay bespoke (not schema items).
        AdaptiveSettingsSection(
          children: [
            _buildVolumeSection(widget.controller!),
            _buildSpeedSection(widget.controller!),
            _buildDelaySection(theme, widget.controller!),
            _buildImagePauseSection(widget.controller!),
            _buildSkipActionSection(),
          ],
        ),
        _buildPlayBarToggle(),
        if (widget.onAudioImport != null)
          AdaptiveSettingsSection(
            children: [
              // Action row, not navigation: a leading icon + state-layer ripple
              // signals tappability (MD3 list-item convention, same as the
              // other rows in this sheet); the tap closes the sheet and runs the
              // audio-import callback rather than opening a subpage, so there is
              // no trailing chevron (plain AdaptiveSettingsRow, not
              // NavigationRow which would force a chevron_right).
              AdaptiveSettingsRow(
                title: t.srt_book_replace_audio,
                icon: Icons.swap_horiz_outlined,
                showIcon: true,
                onTap: () {
                  Navigator.pop(context);
                  widget.onAudioImport!();
                },
              ),
            ],
          ),
      ],
    );
  }

  /// 歌词模式的「布局与显示」子页详情。TODO-802 可达性修复：删「外观」组后，歌词
  /// 模式以前经外观组才够得到的主题选择器 + 编辑书籍 CSS 行，现随歌词布局子页一并
  /// 露出（主题在最前，其次歌词字号/边距等专属控件，最后 extractDir 可用时的 CSS
  /// 行），否则歌词模式将完全够不到主题/CSS。歌词字号/边距是歌词专属设置（写
  /// 歌词-only `setLyrics*` setter），非 schema 项，故保持 bespoke。
  Widget _buildLyricsDisplaySection() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _buildThemeSelectorSection(),
        _buildLyricsMarginSection(),
        if (widget.extractDir != null)
          AdaptiveSettingsSection(
            children: <Widget>[_buildBookCssEditorRow()],
          ),
      ],
    );
  }

  /// 歌词专属字号 / 文字色 / 四边距控件（歌词-only `setLyrics*` setter，非 schema）。
  Widget _buildLyricsMarginSection() {
    return AdaptiveSettingsSection(
      children: [
        AdaptiveSettingsRow(
          title: t.lyrics_font_size_hint,
        ),
        // TODO-907: 歌词竖排开关（独立于正文 writing-mode）。切换走整页重建。
        AdaptiveSettingsSwitchRow(
          title: t.lyrics_vertical_writing,
          subtitle: t.lyrics_vertical_writing_hint,
          value: _src.lyricsVerticalWriting,
          onChanged: (bool enabled) async {
            await _src.setLyricsVerticalWriting(enabled);
            if (!mounted) return;
            setState(() {});
            await widget.onLyricsReload?.call();
          },
        ),
        // TODO-908: 歌词听力沉浸模糊开关（独立 key）。模糊是 live 维度，走
        // onStyleChanged（_updateLyricsStyleLive → __lyricsSetBlur），不重建整页。
        AdaptiveSettingsSwitchRow(
          title: t.lyrics_blur,
          subtitle: t.lyrics_blur_hint,
          value: _src.lyricsBlur,
          onChanged: (bool enabled) async {
            await _src.setLyricsBlur(enabled);
            if (!mounted) return;
            setState(() {});
            widget.onStyleChanged?.call();
          },
        ),
        _numberStepper(
          label: t.lyrics_font_size,
          value: _src.lyricsFontSize,
          step: 1,
          min: 8,
          max: 64,
          format: (double v) => '${v.round()}',
          onChanged: (double v) {
            _src.setLyricsFontSize(v);
            setState(() {});
            widget.onStyleChanged?.call();
          },
        ),
        _buildLyricsTextColorRow(context),
        _numberStepper(
          label: t.margin_top,
          value: _src.lyricsMarginTop,
          step: 1,
          min: 0,
          max: 30,
          format: (double v) => '${v.round()}',
          onChanged: (double v) {
            _src.setLyricsMarginTop(v);
            setState(() {});
            widget.onStyleChanged?.call();
          },
        ),
        _numberStepper(
          label: t.margin_bottom,
          value: _src.lyricsMarginBottom,
          step: 1,
          min: 0,
          max: 30,
          format: (double v) => '${v.round()}',
          onChanged: (double v) {
            _src.setLyricsMarginBottom(v);
            setState(() {});
            widget.onStyleChanged?.call();
          },
        ),
        _numberStepper(
          label: t.margin_left,
          value: _src.lyricsMarginLeft,
          step: 1,
          min: 0,
          max: 30,
          format: (double v) => '${v.round()}',
          onChanged: (double v) {
            _src.setLyricsMarginLeft(v);
            setState(() {});
            widget.onStyleChanged?.call();
          },
        ),
        _numberStepper(
          label: t.margin_right,
          value: _src.lyricsMarginRight,
          step: 1,
          min: 0,
          max: 30,
          format: (double v) => '${v.round()}',
          onChanged: (double v) {
            _src.setLyricsMarginRight(v);
            setState(() {});
            widget.onStyleChanged?.call();
          },
        ),
      ],
    );
  }

  /// TODO-368: 歌词字幕文字色独立色选。开关 = 是否用自定义色（关 = 跟随主题，与历史
  /// 行为一致，哨兵 0）；开时下方展开内联取色器。改色即写穿 source + 触发 live 重绘。
  Widget _buildLyricsTextColorRow(BuildContext context) {
    final int stored = _src.lyricsTextColor;
    final bool custom = stored != 0;
    final Color themeFallback = Theme.of(context).colorScheme.onSurface;
    final Color current = custom ? Color(stored) : themeFallback;
    return AdaptiveSettingsSwitchActionRow(
      title: t.lyrics_text_color,
      subtitle: t.lyrics_text_color_hint,
      value: custom,
      onChanged: (bool enabled) {
        if (enabled) {
          // 开启自定义：种一个不透明的初始色（用当前主题文字色），避免落哨兵 0。
          final Color seed =
              Color(0xFF000000 | (themeFallback.value & 0xFFFFFF));
          _src.setLyricsTextColor(seed.value);
        } else {
          _src.clearLyricsTextColor();
        }
        setState(() {});
        widget.onStyleChanged?.call();
      },
      body: Row(
        children: [
          HibikiColorSwatch(
            color: current,
            size: 20,
            shape: HibikiColorSwatchShape.dot,
            borderColor: Theme.of(context).dividerColor,
          ),
        ],
      ),
      panel: custom
          ? LayoutBuilder(
              builder:
                  (BuildContext layoutContext, BoxConstraints constraints) {
                final double pickerWidth = constraints.maxWidth.clamp(
                  0.0,
                  MediaQuery.of(layoutContext).size.width - 64,
                );
                return ColorPicker(
                  pickerColor: current,
                  onColorChanged: (Color c) {
                    // 强制不透明（文字色透明无意义；也保证非哨兵 0）。
                    final Color opaque =
                        Color(0xFF000000 | (c.value & 0xFFFFFF));
                    _src.setLyricsTextColor(opaque.value);
                    setState(() {});
                    widget.onStyleChanged?.call();
                  },
                  portraitOnly: true,
                  colorPickerWidth: pickerWidth,
                  pickerAreaHeightPercent: 0.5,
                  enableAlpha: false,
                  displayThumbColor: true,
                  hexInputBar: true,
                  labelTypes: const <ColorLabelType>[],
                );
              },
            )
          : null,
    );
  }

  Widget _numberStepper({
    required String label,
    required double value,
    required double step,
    required double min,
    required double max,
    required String Function(double) format,
    required ValueChanged<double> onChanged,
  }) {
    return AdaptiveSettingsStepperRow(
      title: label,
      value: value,
      step: step,
      min: min,
      max: max,
      format: format,
      onChanged: onChanged,
    );
  }

  Widget _buildFavoritesSection(BuildContext context, ThemeData theme) {
    final DateFormat fmt = DateFormat('MM/dd HH:mm');
    return AdaptiveSettingsSection(
      title: t.favorites(n: _favorites.length),
      children: [
        for (final FavoriteSentence favorite in _favorites)
          _InBookFavoriteRow(
            favorite: favorite,
            metaLabel:
                '${favorite.bookTitle}${favorite.chapterLabel != null ? ' - ${favorite.chapterLabel}' : ''} - ${fmt.format(favorite.createdAt)}',
            color: _highlightColor(favorite.color),
            onPlay: widget.onPlayFavorite == null
                ? null
                : () async => widget.onPlayFavorite?.call(favorite),
            onJump:
                favorite.sectionIndex == null || widget.onJumpToFavorite == null
                    ? null
                    : () async {
                        Navigator.of(context).pop();
                        await widget.onJumpToFavorite?.call(favorite);
                      },
            onCopy: () {
              Clipboard.setData(ClipboardData(text: favorite.text));
              HibikiToast.show(msg: t.copy);
            },
            onDelete: () async {
              await widget.onDeleteFavorite?.call(favorite);
              if (mounted) {
                setState(() {
                  _favorites = List<FavoriteSentence>.of(_favorites)
                    ..remove(favorite);
                });
              }
            },
          ),
      ],
    );
  }

  static Color _highlightColor(String? color) {
    switch (color) {
      case 'green':
        return const Color(0xFF00C853);
      case 'blue':
        return const Color(0xFF448AFF);
      case 'pink':
        return const Color(0xFFFF4081);
      case 'purple':
        return const Color(0xFFAA00FF);
      default:
        return HibikiColor.defaultHighlightYellow;
    }
  }

  Widget _buildActionRow(BuildContext context) {
    // 每个按钮包进 Expanded：行宽被均分，单个槽位宽度由可用宽度决定，
    // 不再受标签固有宽度 + 固定内边距之和驱动。这样任何语言/任意长标签
    // 都不会让 Row 溢出（spaceAround 只会分配正余白、负余白照样溢出）。
    return Row(
      children: [
        if (widget.onToggleLyricsMode != null)
          Expanded(
            child: _actionBtn(
              context,
              icon: widget.lyricsMode
                  ? Icons.auto_stories_outlined
                  : Icons.lyrics_outlined,
              label: widget.lyricsMode ? t.book_mode : t.lyrics_mode,
              onTap: () {
                Navigator.of(context).pop();
                widget.onToggleLyricsMode!();
              },
            ),
          ),
        Expanded(
          child: _actionBtn(
            context,
            icon: Icons.bookmark_add_outlined,
            label: t.action_bookmark,
            onTap: () async {
              Navigator.of(context).pop();
              await widget.onBookmark();
            },
          ),
        ),
        Expanded(
          child: _actionBtn(
            context,
            icon: Icons.exit_to_app_outlined,
            label: t.action_exit,
            onTap: () {
              Navigator.of(context).pop();
              widget.onExitReader();
            },
          ),
        ),
      ],
    );
  }

  Widget _actionBtn(
    BuildContext context, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    final ThemeData theme = Theme.of(context);
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Widget button = InkWell(
      onTap: onTap,
      // Under HibikiFocusRoot the registered HibikiActivatableFocusTarget below
      // is the single focus stop; keep the InkWell ripple for mouse/touch but
      // stop it grabbing a competing, unregistered focus node.
      canRequestFocus: HibikiFocusRoot.maybeControllerOf(context) == null,
      borderRadius: tokens.radii.controlRadius,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: tokens.spacing.gap + tokens.spacing.gap / 2,
          vertical: tokens.spacing.gap * 0.75,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: theme.colorScheme.onSurface),
            SizedBox(height: tokens.spacing.gap / 2),
            Text(
              label,
              style: theme.textTheme.labelSmall,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
    // A bare InkWell is invisible to the directional focus controller (it walks
    // only registered targets), so the whole action strip was skipped. Register
    // each button as a single focus stop that A/Enter activates.
    if (HibikiFocusRoot.maybeControllerOf(context) == null) return button;
    return HibikiActivatableFocusTarget(
      focusIdPrefix: 'reader-action',
      onTap: onTap,
      child: button,
    );
  }
}

class _InBookTocRow extends StatelessWidget {
  const _InBookTocRow({
    required this.entry,
    required this.selected,
    this.onTap,
  });

  final TtuTocEntry entry;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final bool cupertino = isCupertinoPlatform(context);
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final String title = entry.label.isEmpty ? t.untitled_chapter : entry.label;
    final double indent = entry.depth * tokens.spacing.card;

    if (entry.isHeader) {
      final ThemeData theme = Theme.of(context);
      return Padding(
        padding: EdgeInsetsDirectional.only(
          start: (cupertino
                  ? tokens.spacing.rowHorizontal
                  : tokens.spacing.gap + tokens.spacing.gap / 2) +
              indent,
          top: tokens.spacing.gap + tokens.spacing.gap / 2,
          bottom: tokens.spacing.gap / 2,
        ),
        child: Text(
          title,
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
      );
    }

    final Color selectedColor = cupertino
        ? CupertinoTheme.of(context).primaryColor
        : Theme.of(context).colorScheme.primary;

    return Padding(
      padding: EdgeInsetsDirectional.only(start: indent),
      child: AdaptiveSettingsRow(
        title: title,
        // TOC chapter names can be long; on a narrow phone the default 2-line
        // clamp clips them. Allow a few wrapped lines (still finite so pathological
        // titles can't blow up the row) before ellipsizing (TODO-1055).
        titleMaxLines: 4,
        icon: entry.depth > 0
            ? (cupertino ? CupertinoIcons.text_alignleft : Icons.notes_outlined)
            : (cupertino ? CupertinoIcons.book : Icons.menu_book_outlined),
        showIcon: true,
        onTap: onTap,
        trailing: selected
            ? Icon(
                cupertino ? CupertinoIcons.check_mark : Icons.check,
                size: 18,
                color: selectedColor,
              )
            : null,
      ),
    );
  }
}

class _InBookSearchResultRow extends StatelessWidget {
  const _InBookSearchResultRow({
    required this.chapterLabel,
    required this.before,
    required this.match,
    required this.after,
    required this.onTap,
  });

  final String chapterLabel;
  final String before;
  final String match;
  final String after;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bool cupertino = isCupertinoPlatform(context);
    final ThemeData theme = Theme.of(context);
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Color primary = cupertino
        ? CupertinoTheme.of(context).primaryColor
        : theme.colorScheme.primary;
    final Color highlight = cupertino
        ? primary.withValues(alpha: 0.14)
        : theme.colorScheme.primaryContainer;
    final Widget child = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.gap + tokens.spacing.gap / 2,
        vertical: tokens.spacing.gap + tokens.spacing.gap / 8,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            cupertino ? CupertinoIcons.search : Icons.search,
            size: 18,
            color: primary,
          ),
          SizedBox(width: tokens.spacing.gap + tokens.spacing.gap / 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  chapterLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: primary),
                ),
                SizedBox(height: tokens.spacing.gap / 4),
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: before),
                      TextSpan(
                        text: match,
                        style: TextStyle(
                          backgroundColor: highlight,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      TextSpan(text: after),
                    ],
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );

    if (cupertino) {
      return CupertinoButton(
        padding: EdgeInsets.zero,
        onPressed: onTap,
        child: Align(alignment: Alignment.centerLeft, child: child),
      );
    }

    return InkWell(
      borderRadius: tokens.radii.controlRadius,
      onTap: onTap,
      child: child,
    );
  }
}

class _InBookBookmarkRow extends StatelessWidget {
  const _InBookBookmarkRow({
    required this.bookmark,
    required this.dateLabel,
    required this.onTap,
    required this.onDelete,
  });

  final Bookmark bookmark;
  final String dateLabel;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final String pageInfo =
        bookmark.pageInChapter != null && bookmark.totalPagesInChapter != null
            ? ' - ${bookmark.pageInChapter}/${bookmark.totalPagesInChapter}'
            : '';

    return AdaptiveSettingsRow(
      title: '${bookmark.label}$pageInfo',
      subtitle: dateLabel,
      icon: isCupertinoPlatform(context)
          ? CupertinoIcons.bookmark
          : Icons.bookmark_outline,
      onTap: onTap,
      trailing: _InBookIconButton(
        materialIcon: Icons.delete_outline,
        cupertinoIcon: CupertinoIcons.delete,
        tooltip: t.options_delete,
        destructive: true,
        onPressed: onDelete,
      ),
    );
  }
}

class _InBookFavoriteRow extends StatelessWidget {
  const _InBookFavoriteRow({
    required this.favorite,
    required this.metaLabel,
    required this.color,
    required this.onCopy,
    required this.onDelete,
    this.onPlay,
    this.onJump,
  });

  final FavoriteSentence favorite;
  final String metaLabel;
  final Color color;
  final VoidCallback? onPlay;
  final VoidCallback? onJump;
  final VoidCallback onCopy;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return AdaptiveSettingsRow(
      title: favorite.text,
      subtitle: metaLabel,
      icon: isCupertinoPlatform(context)
          ? CupertinoIcons.quote_bubble
          : Icons.format_quote_outlined,
      onTap: onJump,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildColorRail(context, color),
          SizedBox(width: tokens.spacing.gap * 0.75),
          // 跳转按钮已移除：整行点击 (onTap) 已经跳转到该收藏句子，
          // 单独的跳转图标与之重复，反而把按钮挤在一起。
          if (onPlay != null) ...[
            _InBookIconButton(
              materialIcon: Icons.volume_up_outlined,
              cupertinoIcon: CupertinoIcons.speaker_2,
              tooltip: t.play,
              onPressed: onPlay!,
            ),
            SizedBox(width: tokens.spacing.gap / 2),
          ],
          _InBookIconButton(
            materialIcon: Icons.copy_outlined,
            cupertinoIcon: CupertinoIcons.doc_on_doc,
            tooltip: t.copy,
            onPressed: onCopy,
          ),
          SizedBox(width: tokens.spacing.gap / 2),
          _InBookIconButton(
            materialIcon: Icons.delete_outline,
            cupertinoIcon: CupertinoIcons.delete,
            tooltip: t.options_delete,
            destructive: true,
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }

  Widget _buildColorRail(BuildContext context, Color railColor) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Container(
      width: 4,
      height: 32,
      decoration: BoxDecoration(
        color: railColor,
        borderRadius: tokens.radii.chipRadius,
      ),
    );
  }
}

class _InBookIconButton extends StatelessWidget {
  const _InBookIconButton({
    required this.materialIcon,
    required this.cupertinoIcon,
    required this.tooltip,
    required this.onPressed,
    this.destructive = false,
  });

  final IconData materialIcon;
  final IconData cupertinoIcon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final bool cupertino = isCupertinoPlatform(context);
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Color color = destructive
        ? (cupertino
            ? CupertinoColors.destructiveRed.resolveFrom(context)
            : Theme.of(context).colorScheme.error)
        : (cupertino
            ? CupertinoTheme.of(context).primaryColor
            : Theme.of(context).colorScheme.onSurfaceVariant);

    if (cupertino) {
      return CupertinoButton(
        padding: EdgeInsets.zero,
        minSize: 32,
        onPressed: onPressed,
        child: Semantics(
          button: true,
          label: tooltip,
          child: Icon(cupertinoIcon, size: 18, color: color),
        ),
      );
    }

    return HibikiIconButton(
      icon: materialIcon,
      size: 18,
      enabledColor: color,
      tooltip: tooltip,
      constraints: BoxConstraints(
        minWidth: tokens.spacing.gap * 4,
        minHeight: tokens.spacing.gap * 4,
      ),
      padding: EdgeInsets.zero,
      onTap: onPressed,
    );
  }
}

class _RepeatIconButton extends StatefulWidget {
  const _RepeatIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  static const Duration _initialDelay = Duration(milliseconds: 500);
  static const Duration _repeatInterval = Duration(milliseconds: 100);

  @override
  State<_RepeatIconButton> createState() => _RepeatIconButtonState();
}

class _RepeatIconButtonState extends State<_RepeatIconButton> {
  Timer? _timer;

  void _start() {
    widget.onPressed();
    _timer = Timer(_RepeatIconButton._initialDelay, () {
      _timer = Timer.periodic(_RepeatIconButton._repeatInterval, (_) {
        widget.onPressed();
      });
    });
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPressStart: (_) => _start(),
      onLongPressEnd: (_) => _stop(),
      child: HibikiIconButton(
        icon: widget.icon,
        size: 18,
        tooltip: widget.tooltip,
        constraints: const BoxConstraints.tightFor(width: 32, height: 32),
        padding: EdgeInsets.zero,
        onTap: widget.onPressed,
      ),
    );
  }
}

/// 有声书音量行：拖动按 1% 一档吸附，键盘 / 手柄左右键单按 5% 一步。
///
/// 粒度拆成两个常量：拖动要「细」（1% 档位足够精修不同书的响度差异），但
/// 方向键 / D-pad 若也按 1% 走，0–200% 全程要按 200 下，单按步进就退化成
/// 不可用 —— 所以按键步进固定 5%（仍比旧的 10% 细一倍），经
/// [AdaptiveSettingsSliderRow.step] 与拖动档位解耦。200 档刻度点过密时
/// Material Slider 自动不画（SDK 阈值 trackWidth/divisions >= 3*tickWidth），
/// 轨道保持干净；Cupertino 滑条本就不画刻度。
///
/// 独立成公开 widget（而非 sheet 私有方法）是为了让行为测试不实例化
/// [AudiobookPlayerController]（其构造即持有 just_audio 平台播放器，
/// headless 测试不可用）就能直接 pump 验证步进 / 档位 / 读数。
class AudiobookVolumeRow extends StatelessWidget {
  const AudiobookVolumeRow({
    required this.volume,
    required this.onChanged,
    super.key,
  });

  /// 音量上限（200%，与 [AudiobookPlayerController.setVolume] 的 clamp 一致）。
  static const double maxVolume = 2.0;

  /// 拖动吸附档数：0–200% 共 200 档 = 1% 一档。
  static const int sliderDivisions = 200;

  /// 键盘 / 手柄左右键单按步进：5%。
  static const double keyStep = 0.05;

  /// 当前音量（0.0–2.0，1.0 = 100%）。
  final double volume;

  /// 音量变化回调（已按档位吸附 / 步进对齐的值）。
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final double value = volume.clamp(0.0, maxVolume);
    final String percentLabel = '${(value * 100).round()}%';
    return AdaptiveSettingsSliderRow(
      // 与速度行同款的标题实时读数：1%/5% 的细步进没有可见读数等于白调。
      title: '${t.audio_volume} ($percentLabel)',
      icon: Icons.volume_up_outlined,
      value: value,
      max: maxVolume,
      divisions: sliderDivisions,
      label: percentLabel,
      step: keyStep,
      onChanged: onChanged,
    );
  }
}
