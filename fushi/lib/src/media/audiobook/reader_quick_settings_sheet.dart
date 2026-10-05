import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/media/audiobook/audiobook_controller.dart';
import 'package:fushi/src/media/audiobook/audiobook_speed_slider.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:intl/intl.dart';
import 'package:fushi_engine/epub/epub_book.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/media/audiobook/audiobook_bridge.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/pages/implementations/book_css_editor_page.dart';
import 'package:fushi/src/reader/reader_audiobook_panel.dart';
import 'package:fushi/src/reader/reader_navigation_widgets.dart';
import 'package:fushi/src/reader/reader_panel_kit.dart';
import 'package:fushi/src/reader/reader_settings_ia.dart';
import 'package:fushi/src/reader/reader_settings_preview.dart';
import 'package:fushi/src/reader/reader_settings_side_dialog.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/reader/reader_desktop_chrome.dart'
    show ReaderSideSheet;
import 'package:fushi/src/reader/ttu_toc_flatten.dart'
    show resolveCurrentTocEntry;
import 'package:fushi/src/settings/glass_settings_renderer.dart';
import 'package:fushi/src/settings/master_detail_settings_sheet.dart';
import 'package:fushi/src/settings/settings_actions.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_renderer.dart';
import 'package:fushi/src/settings/settings_schema.dart';
import 'package:fushi/utils.dart';

/// 面板的呈现形态。
enum ReaderQuickSettingsPresentation {
  /// 居中对话框（桌面）/ 底部 modal sheet（移动端）：主页 + 分类子页 / 宽窗 master-detail。
  sheet,

  /// 桌面端右侧抽屉「导航」：阅读进度 + 书内搜索 + 按字数跳转 + 章节列表 + 收藏。
  sideSheetNavigation,

  /// 桌面端右侧抽屉「设置」：布局显示 / 阅读操作 / 查词 三个标签页，布局页末尾
  /// 是歌词模式切换。有声书不在这里（见 [audiobookPanel]）。
  sideSheetAppearance,

  /// 桌面端居中「有声书」面板（Niratan Sasayaki 形态）：封面 + 书名 + 进度条 +
  /// 播放控制，下接「资源 / 章节 / 设置」分段。
  audiobookPanel,
}

/// 章节列表的同合集卷切换接线（BUG-2521）。[labels] 是各卷标题（与
/// [currentIndex] 同序）；[tocOf] 取某卷目录（兄弟卷在 isolate 解析、按卷缓存，
/// 不可查看的卷返回空表）；[onJump] 切到某卷（[chapterIndex] null = 按该卷保存
/// 位置打开）——切书本身由阅读器页面走完整退出链后 pushReplacement。
class ReaderTocVolumeSwitch {
  const ReaderTocVolumeSwitch({
    required this.labels,
    required this.currentIndex,
    required this.tocOf,
    required this.onJump,
  });

  final List<String> labels;
  final int currentIndex;
  final Future<List<TtuTocEntry>> Function(int volume) tocOf;
  final Future<void> Function(int volume, int? chapterIndex) onJump;
}

class ReaderQuickSettingsSheet extends StatefulWidget {
  const ReaderQuickSettingsSheet({
    required this.controller,
    required this.toc,
    required this.readerProgress,
    required this.onJumpSection,
    required this.onExitReader,
    this.readerCharOffset,
    required this.webViewController,
    required this.appModel,
    required this.ref,
    this.pageProgress,
    this.onThemeChanged,
    this.favoriteSentences = const [],
    this.favoritePositionLabel,
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
    this.isFushiReader = false,
    this.epubBook,
    this.chapterLabel,
    this.onStyleChanged,
    this.lyricsMode = false,
    this.onToggleLyricsMode,
    this.extractDir,
    this.onReloadChapter,
    this.onLyricsReload,
    this.onAudioImport,
    this.onPickAlignment,
    this.onTranscribe,
    this.onOpenStatistics,
    this.autofocusSearch = false,
    this.initialSideSheetTab = '',
    this.onSideSheetTabChanged,
    this.expandedTocParents,
    this.volumeSwitch,
    this.initialSubPage,
    this.presentation = ReaderQuickSettingsPresentation.sheet,
    this.onClose,
    this.coverPath,
    this.readerPaperColors,
    super.key,
  });

  final AudiobookPlayerController? controller;
  final List<TtuTocEntry> toc;

  /// 0-indexed section index and total chapter count.
  final (int section, int total)? readerProgress;

  /// 当前章内的字符偏移（`countStudyChars` 口径，与 [TtuTocEntry.anchorCharOffset]
  /// 同尺），未知为 null。同一 spine 章下靠锚点分节的多条目录项只有它能分清
  /// 读到哪一条。
  final int? readerCharOffset;
  final (int current, int total)? pageProgress;

  /// 跳到目录条目。[fragment] 是该条目的章内锚（[TtuTocEntry.fragment]），
  /// 同一 spine 章下的多个目录项只有它能区分，为 null 时就是跳到章首。
  final Future<void> Function(int sectionIndex, String? fragment) onJumpSection;
  final VoidCallback onExitReader;
  final InAppWebViewController webViewController;
  final AppModel appModel;

  /// Riverpod ref from the reader page, forwarded to the schema-projected
  /// settings so [SettingsContext] always has a real [WidgetRef].
  final WidgetRef ref;
  final Future<void> Function()? onThemeChanged;
  final List<FavoriteSentence> favoriteSentences;

  /// 收藏行「阅读位置」标签（如 `78.6%`）解析器，由阅读器页面用每章字符账本折算全书
  /// 进度。返回 null 时该行不显示位置（账本未就绪 / 无 sectionIndex）。
  final String? Function(FavoriteSentence fav)? favoritePositionLabel;
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
  final bool isFushiReader;

  final EpubBook? epubBook;

  /// 当前章节名（由阅读器页面经 TOC 反查得到），用于阅读进度区块展示。
  final String? chapterLabel;

  final String? extractDir;
  final Future<void> Function()? onReloadChapter;

  /// TODO-907: 歌词模式整页重建（切竖排/横排）。歌词页是 WebView 整页 HTML，
  /// writing-mode 改了只能重建文档（[_loadLyricsPage]），不能 live 改样式。
  final Future<void> Function()? onLyricsReload;
  final VoidCallback? onAudioImport;

  /// 有声书面板「资源」页：选择 / 更换对齐文件（打开预填当前音频的导入对话框）。
  final VoidCallback? onPickAlignment;

  /// 有声书面板「资源」页：对当前音频做设备端转录生成字幕。null = 本机不支持。
  final VoidCallback? onTranscribe;

  /// 导航抽屉打开即把焦点放进书内搜索框（Ctrl+F 的语义就是要搜）。
  final bool autofocusSearch;

  /// 移动端 / 窄窗主页的「阅读统计」行（打开阅读器内统计浮层）；null 不显示。
  final VoidCallback? onOpenStatistics;

  /// 设置侧板初始分页（页面记忆上次打开的 tab id；空串 / 未知 id 按
  /// [readerSettingsInitialTab] 落默认页）。
  final String initialSideSheetTab;
  final ValueChanged<String>? onSideSheetTabChanged;

  /// 目录折叠状态的会话记忆（页面持有的可变集合；null 则本面板自持）。
  final Set<String>? expandedTocParents;

  /// 同合集卷切换（BUG-2521）：目录区顶部出卷 chip，看别的卷的目录不离开面板、
  /// 点别的卷的章才真正切书。null = 不在多卷合集里，目录区与从前一样。
  final ReaderTocVolumeSwitch? volumeSwitch;

  /// TODO-1309①：打开面板时直达的子页 id（如 'location' 导航子页）。null =
  /// 默认落主菜单（窄窗）/ 默认分类（宽窗）。仅用于初始化 [_subPage]，
  /// 之后由用户导航自行覆盖。
  final String? initialSubPage;

  /// 呈现形态（桌面端右侧抽屉 vs 既有 sheet），见 [ReaderQuickSettingsPresentation]。
  final ReaderQuickSettingsPresentation presentation;

  /// 抽屉形态的关闭回调（标题行 ×）。sheet 形态不用（由外壳路由自行关闭）。
  final VoidCallback? onClose;

  /// 书籍封面文件路径（有声书面板左侧显示；null 不显示）。
  final String? coverPath;

  /// 阅读器当前主题解析出的纸色 / 正文色（设置侧板「实时预览」卡用；面板的
  /// Theme 是 app 主题，读不到 ecru 之类的阅读纸色）。每次 build 现取，换主题后
  /// 预览随之变色。null = 退回 app 主题的 surface / onSurface。
  final ({Color bg, Color fg}) Function()? readerPaperColors;

  @override
  State<ReaderQuickSettingsSheet> createState() =>
      _ReaderQuickSettingsSheetState();
}

class _ReaderQuickSettingsSheetState extends State<ReaderQuickSettingsSheet>
    with
        SettingsContextHost<ReaderQuickSettingsSheet>,
        TickerProviderStateMixin {
  ReaderFushiSource get _src => ReaderFushiSource.instance;

  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _charJumpController = TextEditingController();
  List<BookSearchResult> _searchResults = const [];
  String _searchResultsQuery = '';
  int _searchGeneration = 0;
  bool _isSearching = false;

  /// 2026-10 体验优化：上一次书内搜索是否抛错。出错不能显示成「无结果」
  /// （用户会以为书里真没有），要给出失败提示 + 重试。
  bool _searchFailed = false;
  bool _layoutReloading = false;
  bool _exitScheduled = false;

  late String? _subPage = widget.initialSubPage;

  /// 「听书」模块是否可见。关掉时本面板不再渲染「有声书」分类（设置抽屉标签栏 +
  /// 窄窗导航行两处），即便宿主还持有一个控制器也一样——模块关掉 = 入口消失。
  bool get _listeningEnabled =>
      widget.appModel.moduleVisibility.isEnabled(ModuleId.listening);

  /// 桌面端右侧「设置」抽屉当前展开的分组 id（初值来自页面记忆）。
  late String _sideSheetTab = widget.initialSideSheetTab;

  /// 「设置」抽屉标签栏的控制器，仅 [ReaderQuickSettingsPresentation.sideSheetAppearance]
  /// 形态首次 build 时创建（其余形态没有标签栏）。
  TabController? _sideSheetTabController;

  /// 导航抽屉里当前章那一行的 key：打开时滚到它。
  final GlobalKey _currentTocRowKey = GlobalKey();

  /// 目录里手动展开的父节（按父节 label）；子节默认折叠，当前章所在的父节自动
  /// 展开（层级见 [readerTocHierarchy]）。
  late final Set<String> _expandedTocParents =
      widget.expandedTocParents ?? <String>{};

  /// 用户手动收起的「当前章所在父项」（它们默认自动展开）。本面板会话内有效。
  final Set<String> _collapsedTocParents = <String>{};

  /// 目录区当前查看的卷（初值 = 当前卷）。只影响列表内容，不影响阅读器。
  late int _viewedVolume = widget.volumeSwitch?.currentIndex ?? 0;

  /// 最近一次 LayoutBuilder 是否判定为宽窗。供 PopScope.canPop 读取：宽窗
  /// master-detail 下选中态非 null 也允许直接关闭（不会卡在「返回上一级」）。
  /// 纯按窗口宽高确定性判定（>= 共享常量阈值），与视频设置同条件。
  bool _isWide = false;

  late List<FavoriteSentence> _favorites =
      List<FavoriteSentence>.of(widget.favoriteSentences);

  /// 2026-10 体验优化：收藏句删除改为「先标记 + 撤销窗口」，窗口到期（或面板
  /// 关闭）才真正调 [ReaderQuickSettingsSheet.onDeleteFavorite] 落库；此前
  /// 一点即删、无确认无撤销，与相邻的复制键只隔 4dp，误触即丢数据。
  final Map<FavoriteSentence, Timer> _pendingFavoriteDeletes =
      <FavoriteSentence, Timer>{};

  static const Duration _favoriteUndoWindow = Duration(seconds: 5);

  void _markFavoriteDeleted(FavoriteSentence fav) {
    if (_pendingFavoriteDeletes.containsKey(fav)) return;
    setState(() {
      _pendingFavoriteDeletes[fav] = Timer(
        _favoriteUndoWindow,
        () => unawaited(_commitFavoriteDelete(fav)),
      );
    });
  }

  void _undoFavoriteDelete(FavoriteSentence fav) {
    final Timer? timer = _pendingFavoriteDeletes.remove(fav);
    if (timer == null) return;
    timer.cancel();
    setState(() {});
  }

  Future<void> _commitFavoriteDelete(FavoriteSentence fav) async {
    final Timer? timer = _pendingFavoriteDeletes.remove(fav);
    if (timer == null) return;
    timer.cancel();
    if (mounted) {
      setState(() {
        _favorites = List<FavoriteSentence>.of(_favorites)..remove(fav);
      });
    }
    await widget.onDeleteFavorite?.call(fav);
  }

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
    // 面板关闭时仍在撤销窗口里的删除照常落库（用户没点撤销 = 确认删除）。
    for (final FavoriteSentence fav
        in List<FavoriteSentence>.of(_pendingFavoriteDeletes.keys)) {
      unawaited(_commitFavoriteDelete(fav));
    }
    _sideSheetTabController?.dispose();
    _navTabController?.dispose();
    _searchController.dispose();
    _charJumpController.dispose();
    super.dispose();
  }

  Future<void> _updateSetting(String key, Object value) async {
    if (!widget.isFushiReader) {
      await AudiobookBridge.setReaderSetting(
        widget.webViewController,
        key: key,
        value: value,
      );
    }
    final ReaderFushiSource src = ReaderFushiSource.instance;
    switch (key) {
      case 'fontSize':
        await src.setReaderFontSize((value as num).toDouble());
      case 'lineHeight':
        await src.setReaderLineHeight((value as num).toDouble());
      case 'writingMode':
        await src.setReaderWritingMode(value as String);
        widget.onPageMarginChanged?.call();
      case 'viewMode':
        await src.setReaderViewMode(value as String);
      case 'theme':
        await src.setReaderTheme(value as String);
      case 'hideFurigana':
        // 布尔开关只能表达两态：开 = hidden，关 = off（旧实现关掉落到 toggle，
        // 永远回不到显示态）。
        await src.setReaderFuriganaMode((value as bool) ? 'hidden' : 'off');
      case 'textIndentation':
        await src.setReaderTextIndentation((value as num).toDouble());
      case 'marginTop':
        await src.setReaderMarginTop((value as num).toDouble());
        widget.onPageMarginChanged?.call();
      case 'marginBottom':
        await src.setReaderMarginBottom((value as num).toDouble());
        widget.onPageMarginChanged?.call();
      case 'marginLeft':
        await src.setReaderMarginLeft((value as num).toDouble());
        widget.onPageMarginChanged?.call();
      case 'marginRight':
        await src.setReaderMarginRight((value as num).toDouble());
        widget.onPageMarginChanged?.call();
      case 'pageColumns':
        await src.setReaderPageColumns((value as num).toInt());
      case 'spreadMode':
        await src.setReaderSpreadMode(value as String);
      case 'spreadDirection':
        await src.setReaderSpreadDirection(value as String);
      case 'enableVerticalFontKerning':
        await src.setReaderEnableVerticalFontKerning(value as bool);
      case 'enableFontVPAL':
        await src.setReaderEnableFontVPAL(value as bool);
      case 'verticalTextOrientation':
        await src.setReaderVerticalTextOrientation(value as String);
      case 'enableTextJustification':
        await src.setReaderEnableTextJustification(value as bool);
      case 'prioritizeReaderStyles':
        await src.setReaderPrioritizeReaderStyles(value as bool);
    }
    if (widget.isFushiReader) {
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
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);

    switch (widget.presentation) {
      case ReaderQuickSettingsPresentation.sideSheetNavigation:
        return _buildNavigationSideSheet(context, theme);
      case ReaderQuickSettingsPresentation.sideSheetAppearance:
        return _buildAppearanceSideSheet(context, theme);
      case ReaderQuickSettingsPresentation.audiobookPanel:
        return _buildAudiobookPanel(context, theme);
      case ReaderQuickSettingsPresentation.sheet:
        break;
    }

    return FushiMasterDetailSettingsSheet(
      // 宽窗 master-detail：选中态始终有值（默认 appearance），返回键应直接关
      // 弹窗而非退回「未选中」；窄窗 push 时保留原「先回主页」语义。
      subPageActive: _subPage != null,
      onPopToParent: () => setState(() => _subPage = null),
      isWide: _isWide,
      onWideChanged: (bool wide) => _isWide = wide,
      narrowKey: () => ValueKey<String>(_subPage ?? 'main'),
      // 窄窗 padding：水平 page + gap/2，底部叠 card + gap + 键盘 inset（与视频不同，
      // 视频用 page + gap，不可统一；底部走共享公式
      // [FushiMasterDetailSettingsSheet.paneInsets]）。
      narrowPadding: (BuildContext context, BoxConstraints constraints) {
        return FushiMasterDetailSettingsSheet.paneInsets(
          context,
          horizontal: tokens.spacing.page + tokens.spacing.gap / 2,
          top: tokens.spacing.gap / 2,
        );
      },
      // 窄窗（含全部手机 bottom sheet）：维持现有 push 行为，外观仍内联。
      narrowChild: (BuildContext context, BoxConstraints constraints) {
        return _subPage != null
            ? _buildSubPage(context, theme)
            : _buildMainPage(context, theme);
      },
      // 宽窗不再有 master-detail：平板宽窗在到达本面板之前就被路由到左右抽屉
      // （readerUsesSideSheets），这里只保留外壳要求的回调，兜底铺同一份窄窗内容。
      wideBuilder: (BuildContext context, BoxConstraints constraints) {
        return SingleChildScrollView(
          key: ValueKey<String>(_subPage ?? 'main'),
          padding: FushiMasterDetailSettingsSheet.paneInsets(
            context,
            horizontal: tokens.spacing.page + tokens.spacing.gap / 2,
            top: tokens.spacing.gap / 2,
          ),
          child: _subPage != null
              ? _buildSubPage(context, theme)
              : _buildMainPage(context, theme),
        );
      },
    );
  }

  VoidCallback _sideSheetClose(BuildContext context) =>
      widget.onClose ?? () => Navigator.of(context).maybePop();

  /// 导航侧板此次出现的分页：目录（有目录 / 多卷时）/ 收藏（恒在，空时给空态）/
  /// 搜索（书内搜索或按字数跳转可用时；歌词模式两者都不传，整页不出现）。
  late final List<_ReaderNavTab> _navTabs = <_ReaderNavTab>[
    if (widget.toc.isNotEmpty || widget.volumeSwitch != null)
      _ReaderNavTab.contents,
    _ReaderNavTab.favorites,
    if ((widget.epubBook != null && widget.onSearchJump != null) ||
        widget.onJumpToCharOffset != null)
      _ReaderNavTab.search,
  ];

  TabController? _navTabController;

  /// 导航侧板「打开即滚到当前章」只做一次（之后由用户自己滚）。
  bool _scrolledToCurrentTocRow = false;

  TabController _ensureNavTabController() {
    final TabController? existing = _navTabController;
    if (existing != null) return existing;
    // Ctrl+F（autofocusSearch）直达搜索页；其余落目录（没有目录时落第一页）。
    final int initial = widget.autofocusSearch
        ? _navTabs.indexOf(_ReaderNavTab.search)
        : 0;
    return _navTabController = TabController(
      length: _navTabs.length,
      initialIndex: initial < 0 ? 0 : initial,
      animationDuration: fushiMotionDuration(context, FushiMotion.medium),
      vsync: this,
    );
  }

  String _navTabLabel(_ReaderNavTab tab) => switch (tab) {
        _ReaderNavTab.contents => t.reader_nav_tab_contents,
        _ReaderNavTab.favorites => _favorites.isEmpty
            ? t.reader_nav_tab_favorites
            : '${t.reader_nav_tab_favorites} ${_favorites.length}',
        _ReaderNavTab.search => t.reader_nav_tab_search,
      };

  /// 「导航」侧板（宽窗贴左 / 窄窗底部 sheet）：页头下固定「阅读进度」卡 + 分页
  /// 标签（目录 / 收藏 / 搜索），每页各自滚动。目录打开即滚到当前章那一行；当前章
  /// 整行高亮（[_InBookTocRow]）；搜索结果带命中前后文（[_InBookSearchResultRow]）。
  Widget _buildNavigationSideSheet(BuildContext context, ThemeData theme) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final TabController controller = _ensureNavTabController();
    // 打开即滚到当前章那一行（只在首次 build 后做一次；行不存在 / 目录页不在场
    // 时 no-op）。只滚**最近**的那层纵向滚动视图：Scrollable.ensureVisible 会连带
    // 把外层横向的 TabBarView 也按 alignment 对齐，页面被拽离整页位置后又被
    // 吸附回去，来回打架永不落定。
    if (!_scrolledToCurrentTocRow) {
      _scrolledToCurrentTocRow = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final BuildContext? rowContext = _currentTocRowKey.currentContext;
        if (rowContext == null || !mounted) return;
        final ScrollableState? scrollable = Scrollable.maybeOf(rowContext);
        final RenderObject? row = rowContext.findRenderObject();
        if (scrollable == null || row == null) return;
        scrollable.position.ensureVisible(
          row,
          alignment: 0.3,
          duration: fushiMotionDuration(context, FushiMotion.short),
          curve: FushiMotion.standard,
        );
      });
    }
    final EdgeInsets pagePadding = ReaderSideSheet.defaultPadding.copyWith(
      top: tokens.spacing.gap + tokens.spacing.gap / 2,
      left: tokens.spacing.page - tokens.spacing.gap / 2,
      right: tokens.spacing.page - tokens.spacing.gap / 2,
    );
    Widget page(_ReaderNavTab tab, Widget child) => SingleChildScrollView(
          key: PageStorageKey<String>('fushi_nav_tab_${tab.name}'),
          padding: pagePadding,
          child: FushiEntranceScope(
            child: FushiStaggeredEntrance(index: 0, child: child),
          ),
        );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 矮面板（底部 sheet 半屏档 / 横屏手机）：进度 hero 收成单行，把高度
        // 让给列表。sheet 拖到另一档时外壳按新高度重新布局，这里随之换档。
        final bool compact = constraints.maxHeight.isFinite &&
            constraints.maxHeight < kReaderNavCompactHeroBelow;
        return ReaderSideSheet(
          title: t.section_navigation,
          icon: Icons.menu_book_outlined,
          subtitle: widget.epubBook?.title,
          onClose: _sideSheetClose(context),
          scrollable: false,
          bottom: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: EdgeInsets.fromLTRB(
                  tokens.spacing.page,
                  tokens.spacing.gap / 2,
                  tokens.spacing.page,
                  tokens.spacing.gap + tokens.spacing.gap / 2,
                ),
                child: AnimatedSize(
                  duration: fushiMotionDuration(context, FushiMotion.medium),
                  curve: FushiMotion.release,
                  alignment: Alignment.topCenter,
                  child: _buildNavProgressCard(context, theme, compact: compact),
                ),
              ),
              if (_navTabs.length > 1)
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    tokens.spacing.page,
                    0,
                    tokens.spacing.page,
                    tokens.spacing.gap / 2,
                  ),
                  child: ReaderPanelTabs(
                    key: const ValueKey<String>('fushi_nav_tabs'),
                    controller: controller,
                    tabs: <ReaderPanelTab>[
                      for (final _ReaderNavTab tab in _navTabs)
                        ReaderPanelTab(
                          key: ValueKey<String>('reader-nav-tab-${tab.name}'),
                          label: _navTabLabel(tab),
                          icon: switch (tab) {
                            _ReaderNavTab.contents => Icons.toc_rounded,
                            _ReaderNavTab.favorites => Icons.star_rounded,
                            _ReaderNavTab.search => Icons.search_rounded,
                          },
                        ),
                    ],
                  ),
                ),
            ],
          ),
          child: TabBarView(
            controller: controller,
            children: <Widget>[
              for (final _ReaderNavTab tab in _navTabs)
                switch (tab) {
                  _ReaderNavTab.contents =>
                    page(tab, _buildTocSection(context, theme)),
                  _ReaderNavTab.favorites => page(
                      tab,
                      _favorites.isEmpty
                          ? _buildNavEmptyState(
                              theme,
                              icon: Icons.star_outline_rounded,
                              message: t.reader_nav_favorites_empty,
                            )
                          : _buildFavoritesSection(context, theme),
                    ),
                  _ReaderNavTab.search => page(tab, _buildNavSearchPage(theme)),
                },
            ],
          ),
        );
      },
    );
  }

  /// 搜索页：书内搜索（结果带上下文）+ 按字数跳转；还没搜过时给一句用法提示。
  Widget _buildNavSearchPage(ThemeData theme) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool canSearch = widget.epubBook != null && widget.onSearchJump != null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (canSearch) _buildSearchSection(theme),
        if (canSearch &&
            !_isSearching &&
            _searchResults.isEmpty &&
            !_searchFailed &&
            _searchController.text.trim().isEmpty)
          ReaderPanelEmpty(
            icon: Icons.manage_search_rounded,
            message: t.reader_nav_search_empty_hint,
          ),
        if (widget.onJumpToCharOffset != null) ...<Widget>[
          SizedBox(height: tokens.spacing.gap * 2),
          _buildCharJumpSection(theme),
        ],
      ],
    );
  }

  /// 分页空态：形状底大图标 + 一句说明（[ReaderPanelEmpty]）。
  Widget _buildNavEmptyState(
    ThemeData theme, {
    required IconData icon,
    required String message,
  }) {
    return ReaderPanelEmpty(icon: icon, message: message);
  }

  /// 导航页头下的「阅读进度」hero（[ReaderNavProgressHero]）：当前章名 + 全书
  /// 百分比 + 波浪全书进度条 + 章 / 页 / 字数读数（有声书在场时加一行音频进度）。
  /// [compact] = 矮面板单行档。
  Widget _buildNavProgressCard(
    BuildContext context,
    ThemeData theme, {
    bool compact = false,
  }) {
    final (int, int)? rp = widget.readerProgress;
    final (int, int)? cp = widget.charProgress;
    final (int, int)? pp = widget.pageProgress;
    final double? fraction = cp != null && cp.$2 > 0
        ? (cp.$1 / cp.$2).clamp(0.0, 1.0)
        : rp != null && rp.$2 > 0
            ? ((rp.$1 + 1) / rp.$2).clamp(0.0, 1.0)
            : null;
    final String? chapter = widget.chapterLabel?.trim();
    final NumberFormat count = NumberFormat.decimalPattern();
    // 百分比只出现一个（hero 大数字）；读数行只报位置，不再重复百分比。
    final List<String> readouts = <String>[
      if (rp != null && rp.$2 > 0)
        t.reader_nav_progress_chapter(current: rp.$1 + 1, total: rp.$2),
      if (pp != null && pp.$2 > 0) t.page_progress(current: pp.$1, total: pp.$2),
      if (cp != null && cp.$2 > 0)
        t.reader_nav_progress_chars(
          current: count.format(cp.$1),
          total: count.format(cp.$2),
        ),
    ];
    final AudiobookPlayerController? ctrl = widget.controller;
    if (fraction == null &&
        (chapter == null || chapter.isEmpty) &&
        readouts.isEmpty &&
        ctrl == null) {
      return const SizedBox.shrink();
    }
    return ReaderNavProgressHero(
      fraction: fraction,
      chapter: chapter,
      fallbackTitle: t.reading_progress,
      caption: t.reader_nav_progress_book,
      readouts: readouts,
      coverPath: widget.coverPath,
      compact: compact,
      footer: ctrl == null ? null : _buildAudioProgressLine(theme, ctrl),
    );
  }

  /// 本次打开设置侧板出现的标签页（打开时定型：切歌词 / 书籍模式会关掉面板重开）。
  /// 信息架构（按任务分组、常用置顶、高级折叠）见 reader_settings_ia.dart。
  late final List<ReaderSettingsTab> _settingsTabs = readerSettingsTabs(
    lyricsMode: widget.lyricsMode,
    listeningEnabled: _listeningEnabled,
    lyricsAvailable: widget.onToggleLyricsMode != null &&
        (widget.controller != null || widget.lyricsMode),
  );

  TabController _ensureSideSheetTabController() {
    final TabController? existing = _sideSheetTabController;
    if (existing != null) return existing;
    final List<ReaderSettingsTab> tabs = _settingsTabs;
    final ReaderSettingsTab initial = readerSettingsInitialTab(
      tabs,
      remembered: _sideSheetTab,
      lyricsMode: widget.lyricsMode,
    );
    final TabController controller = TabController(
      length: tabs.length,
      initialIndex: tabs.indexOf(initial),
      animationDuration: fushiMotionDuration(context, FushiMotion.medium),
      vsync: this,
    );
    controller.addListener(() {
      // 点标签时动画开始、结束各通知一次，只认落定后那次；滑动切页只通知落定。
      if (controller.indexIsChanging) return;
      final String id = tabs[controller.index].id;
      if (id == _sideSheetTab) return;
      // 换页由 TabBarView 自己完成，这里只记账、交给页面记忆，不必重建整个面板。
      _sideSheetTab = id;
      widget.onSideSheetTabChanged?.call(id);
    });
    return _sideSheetTabController = controller;
  }

  /// 「阅读设置」侧板（宽窗贴边 / 窄窗底部 sheet，外壳见 [showReaderSideSheet]）：
  /// 标题下固定一条标签栏——主题与字体 / 排版 / 翻页与手势 / 有声书 / 查词 /
  /// 歌词模式（按任务分组，[readerSettingsTabs]）。每页各自滚动、切走再切回保留
  /// 滚动位置；页内常用小节展开置顶、高级小节默认折叠（[kReaderSettingsSections]）。
  /// 有声书的播放控制不在这里——它有自己的面板
  /// （[ReaderQuickSettingsPresentation.audiobookPanel]）。
  Widget _buildAppearanceSideSheet(BuildContext context, ThemeData theme) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<ReaderSettingsTab> tabs = _settingsTabs;
    final TabController controller = _ensureSideSheetTabController();
    return ReaderSideSheet(
      title: t.reader_settings_section,
      icon: Icons.tune_outlined,
      subtitle: widget.lyricsMode ? t.lyrics_mode : widget.epubBook?.title,
      headerActions: const <Widget>[ReaderSettingsSideButton()],
      onClose: _sideSheetClose(context),
      scrollable: false,
      // 与库页 / 下载页同一个分区导航组件：整排是单个焦点停靠点（方向键 / 手柄
      // 左右切页），按文案取宽、放不下横向滚动（桌面可鼠标拖），并与下方
      // TabBarView 共用同一个 controller，横滑时指示器跟手。
      bottom: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            // 首个页签文字与标题左缘对齐（标题左留白 20 = 4 + tab 自带的 16）。
            padding: EdgeInsetsDirectional.only(
              start: tokens.spacing.gap / 2,
              end: tokens.spacing.gap / 2,
            ),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: LibrarySectionTabs<String>.controlled(
                key: const ValueKey<String>('fushi_side_sheet_tabs'),
                tabs: <LibrarySectionTab<String>>[
                  for (final ReaderSettingsTab tab in tabs)
                    LibrarySectionTab<String>(value: tab.id, label: tab.label),
                ],
                controller: controller,
                focusIdPrefix: 'reader-settings-tab',
              ),
            ),
          ),
          const FushiDividerControl(height: 1),
        ],
      ),
      child: TabBarView(
        controller: controller,
        children: <Widget>[
          // 每页一个独立滚动视图（PageStorageKey 记住各自的滚动位置）；页面离屏即
          // 卸载，切换时整棵内容子树重建，不会复用上一页同位置 Element 的
          // Switch / Segmented 动画副作用。
          for (final ReaderSettingsTab tab in tabs)
            SingleChildScrollView(
              key: PageStorageKey<String>('fushi_side_sheet_tab_${tab.id}'),
              padding: ReaderSideSheet.defaultPadding.copyWith(
                top: tokens.spacing.gap + tokens.spacing.gap / 2,
              ),
              // 内容自成重绘边界：SingleChildScrollView 的子树不是边界，滚动每帧
              // 都要把整页设置重录一遍；隔开后滚动只平移已录好的层。Android 上
              // 面板压在 Hybrid Composition 的正文 WebView 之上，每帧 UI 线程省下
              // 的这段直接决定滚动跟不跟手。
              child: RepaintBoundary(
                child: _buildSettingsTabContent(context, tab),
              ),
            ),
        ],
      ),
    );
  }

  /// 一个设置标签页的内容：面板自绘块（预览 / 主题 / 歌词专属控件）+ 该页的
  /// schema 小节（[buildReaderSettingsSections]）。各块错峰进场
  /// （[FushiEntranceScope]，墨水屏 / 减弱动态效果下瞬时出现）。
  Widget _buildSettingsTabContent(BuildContext context, ReaderSettingsTab tab) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<Widget> blocks = switch (tab) {
      ReaderSettingsTab.lyrics => _buildLyricsTabBlocks(context),
      _ => <Widget>[
          if (tab == ReaderSettingsTab.appearance) ...<Widget>[
            if (!widget.lyricsMode)
              Padding(
                padding: EdgeInsets.only(bottom: tokens.spacing.gap * 2),
                child: _buildReaderPreview(),
              ),
            _buildThemeSelectorSection(),
          ],
          _buildReaderTabSchema(tab),
          if (tab == ReaderSettingsTab.appearance && widget.extractDir != null)
            _buildBookCssEditorSection(),
        ],
    };
    return FushiEntranceScope(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final (int i, Widget block) in blocks.indexed)
            FushiStaggeredEntrance(index: i, child: block),
        ],
      ),
    );
  }

  /// 某标签页的 schema 小节（常用展开 / 高级折叠），按设计系统选渲染器。
  Widget _buildReaderTabSchema(ReaderSettingsTab tab) {
    final SettingsContext settingsContext = _settingsContext();
    return _buildSettingsDestinationContent(
      settingsContext,
      SettingsDestination(
        id: SettingsDestinationId.readerQuickSettings,
        title: tab.label,
        icon: Icons.tune_outlined,
        sections: buildReaderSettingsSections(
          collectReaderItems(settingsContext),
          tab,
          listeningTab: _settingsTabs.contains(ReaderSettingsTab.listening),
        ),
      ),
    );
  }

  /// 「主题与字体」页顶的实时预览卡：阅读纸色 + 正文色画一段样文，字号 / 字重 /
  /// 行高 / 横竖排随设置即时变化（schema 行改值经 SettingsContext.refresh 重建本
  /// 面板，预览随之重读 [ReaderFushiSource] 的现值）。
  Widget _buildReaderPreview() {
    final ({Color bg, Color fg})? paper = widget.readerPaperColors?.call();
    final ColorScheme cs = Theme.of(context).colorScheme;
    return ReaderSettingsPreviewCard(
      sample: t.reader_panel_preview_sample,
      label: t.reader_panel_preview_title,
      background: paper?.bg ?? cs.surface,
      foreground: paper?.fg ?? cs.onSurface,
      readerFontSize: _src.readerFontSize,
      lineHeight: _src.readerLineHeight,
      fontWeight: _src.readerFontWeight,
      vertical: _src.readerWritingMode.startsWith('vertical'),
    );
  }

  /// 「歌词模式」页：模式切换置顶，其后是歌词页专属控件按任务分三组——
  /// 文字与颜色（字号 / 文字色 / 当前行高亮色）、版式与边距（竖排 / 四边距，
  /// 默认折叠）、听力（模糊）。这些都不是 schema 项：它们写歌词专属的
  /// `setLyrics*`，并经 onStyleChanged / onLyricsReload 实时作用到歌词页。
  List<Widget> _buildLyricsTabBlocks(BuildContext context) {
    return <Widget>[
      if (widget.onToggleLyricsMode != null)
        AdaptiveSettingsSection(
          children: <Widget>[
            AdaptiveSettingsNavigationRow(
              key: const ValueKey<String>('fushi_lyrics_mode_toggle'),
              title: widget.lyricsMode ? t.book_mode : t.lyrics_mode,
              subtitle: widget.lyricsMode
                  ? t.reader_panel_lyrics_exit_hint
                  : t.reader_panel_lyrics_switch_hint,
              icon: widget.lyricsMode
                  ? Icons.auto_stories_outlined
                  : Icons.lyrics_outlined,
              showIcon: true,
              onTap: () {
                Navigator.of(context).pop();
                widget.onToggleLyricsMode!();
              },
            ),
          ],
        ),
      AdaptiveSettingsSection(
        key: const ValueKey<String>('reader_panel_lyrics_text'),
        title: t.reader_panel_lyrics_section_text,
        children: <Widget>[
          _lyricsFontSizeRow(),
          _buildLyricsTextColorRow(context),
          _buildLyricsHighlightColorRow(context),
        ],
      ),
      AdaptiveSettingsSection(
        key: const ValueKey<String>('reader_panel_lyrics_layout'),
        title: t.reader_panel_lyrics_section_layout,
        titlePlacement: SettingsSectionTitlePlacement.inside,
        collapsible: true,
        initiallyExpanded: false,
        children: <Widget>[
          _lyricsVerticalRow(),
          ..._lyricsMarginRows(),
        ],
      ),
      AdaptiveSettingsSection(
        key: const ValueKey<String>('reader_panel_lyrics_listening'),
        title: t.reader_panel_lyrics_section_listening,
        children: <Widget>[_lyricsBlurRow()],
      ),
    ];
  }

  /// 桌面端居中「有声书」面板：外壳与三个 tab 在 [ReaderAudiobookPanel]；「设置」
  /// tab 的内容仍由本 sheet 提供（音量 / 速度 / 延迟等行的写路径在这里）。
  Widget _buildAudiobookPanel(BuildContext context, ThemeData theme) {
    return ReaderSideSheet(
      title: t.section_audiobook,
      subtitle: widget.chapterLabel,
      icon: Icons.headphones_rounded,
      scrollable: false,
      onClose: _sideSheetClose(context),
      child: _buildAudiobookPanelBody(context),
    );
  }

  Widget _buildAudiobookPanelBody(BuildContext context) {
    return ReaderAudiobookPanel(
      controller: widget.controller,
      toc: widget.toc,
      currentSection: widget.readerProgress?.$1,
      currentCharOffset: widget.readerCharOffset,
      onJumpSection: widget.onJumpSection,
      title: widget.epubBook?.title ?? '',
      chapterLabel: widget.chapterLabel,
      coverPath: widget.coverPath,
      onAudioImport: widget.onAudioImport,
      onPickAlignment: widget.onPickAlignment,
      onTranscribe: widget.onTranscribe,
      settingsBuilder: (BuildContext ctx) =>
          _buildAudiobookSettingsSection(Theme.of(ctx)),
    );
  }

  Widget _buildMainPage(BuildContext context, ThemeData theme) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double sectionGap = tokens.spacing.gap + tokens.spacing.gap / 2;
    // TODO-725（手机/窄窗折叠）/ TODO-802：主页只剩「阅读进度 + 分类导航行 + 动作
    // 行」。「外观」组已删，主题选择器并入 layout 子页顶部（见 _buildLayoutDetail）。
    // 导航置首：location → layout → behavior → lookup → [audiobook]。
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
      if (widget.controller != null && _listeningEnabled)
        _categoryTile(
          icon: Icons.headphones_outlined,
          label: t.section_audiobook,
          page: 'audiobook',
        ),
    ];

    if (widget.onOpenStatistics != null) {
      // 移动端 / 窄窗也能到阅读器内统计浮层（桌面端在顶部工具栏）。
      navigationRows.add(
        AdaptiveSettingsNavigationRow(
          key: const ValueKey<String>('fushi_sheet_statistics_row'),
          title: t.reading_statistics,
          icon: Icons.insights_outlined,
          onTap: () {
            Navigator.of(context).pop();
            widget.onOpenStatistics!();
          },
        ),
      );
    }

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
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final String page = _subPage!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FushiSettingsSubPageHeader(
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
  /// `setReaderPref*` + notify helper，与本面板的 `_updateSetting` 落同一存储。
  ///
  /// 实时更新由 notify helper 经 `ReaderFushiSource` 的回调驱动，且是按 key
  /// 精确的：CSS-only key 走 `notifyReaderSettingsChanged`（=
  /// `onSettingsChangedLive`，CSS 注入），结构性布局 key（view mode / writing
  /// mode / columns / spread / prioritize reader styles）走
  /// `notifyReaderLayoutChanged`（= `onLayoutReloadLive`，整章重排）。schema
  /// 投影项实时从 `ReaderFushiSource.instance` 读写，本 refresh 回调只需
  /// setState 重读 live 值即可。
  SettingsContext _settingsContext() {
    return createSettingsContext(appModel: widget.appModel, ref: widget.ref);
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
    // 按设计系统选渲染器（Apple → GlassSettingsRenderer、MD3 →
    // MaterialSettingsRenderer、Cupertino 照旧），与设置主页 / 视频面板同一判据。
    final SettingsRenderer renderer = resolveSettingsRenderer(context);
    return renderer.buildDetailContent(
      settingsContext: settingsContext,
      destination: destination,
      shrinkWrap: true,
      // 本面板已在外层 SingleChildScrollView 提供横向 padding（widePanePadding /
      // narrowPadding）；让渲染器别再自带横向缩进，否则 schema 投影子页（布局 / 阅读
      // 控制 / 查词）会双重缩进、比 bespoke 的「导航 / 有声书」子页更窄（TODO-1321）。
      insetHorizontally: false,
    );
  }

  /// 主题行专用 [SettingsContext]：换肤后除 setState 外还要 `_syncThemeSelection`
  /// （把 appThemeKey 落 reader 设置 + 触发 `onThemeChanged` 的词典/歌词联动）。
  /// 与 appearance 其它行的普通 `_settingsContext()` 区分，故单列一个工厂。
  SettingsContext _themeSettingsContext() {
    return createSettingsContext(
      appModel: widget.appModel,
      ref: widget.ref,
      beforeRefresh: () => unawaited(_syncThemeSelection()),
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
    // 主题卡与下方 layout schema section 并列同一 Column（见 _buildLayoutDetail）。
    // schema section 现走 buildDetailContent(insetHorizontally:false)，横向留白全部
    // 由本面板外层 padding 统一提供，schema 正文不再自带横向缩进；主题卡也裸放（无额
    // 外 Padding）即可与配置行、以及同面板 bespoke 的「导航 / 有声书」子页左右等宽、
    // 同为宽版（BUG-545/546 的等宽仍成立，只是统一到更宽的外层 padding 宽度，TODO-1321）。
    return AdaptiveSettingsSection(
      children: <Widget>[
        buildThemeSelector(_themeSettingsContext()),
        buildBrightnessSelector(_themeSettingsContext()),
      ],
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
            context: context,
            builder: (_) => BookCssEditorPage(extractDir: widget.extractDir!),
          ),
        );
        await _reloadLayoutLive();
      },
    );
  }

  /// 「编辑书籍 CSS」入口行的外层 section。与主题卡（`_buildThemeSelectorSection`）
  /// 同构：普通布局子页与歌词模式子页里，它与走 `buildDetailContent` 的 schema
  /// section（layout 配置项组）并列同一 Column。schema 正文现走
  /// `insetHorizontally:false`、不再自带横向缩进，横向留白由本面板外层 padding 统一
  /// 提供，故 CSS 入口条裸放 section 即与配置行等宽（BUG-573），且与 bespoke 的
  /// 「导航 / 有声书」子页同为宽版（TODO-1321）。
  Widget _buildBookCssEditorSection() {
    // 与 _buildThemeSelectorSection 同理：CSS 入口条裸放即可与上方 layout 配置行、
    // 以及 bespoke 的「导航 / 有声书」子页左右等宽、同为宽版。横向留白由本面板外层
    // padding 统一提供，schema 正文经 insetHorizontally:false 不再自带横向缩进
    // （BUG-573 的等宽仍成立，统一到更宽的外层 padding 宽度，TODO-1321）。
    return AdaptiveSettingsSection(
      children: <Widget>[_buildBookCssEditorRow()],
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
        if (widget.extractDir != null) _buildBookCssEditorSection(),
      ],
    );
  }

  Widget _buildLocationSection(ThemeData theme) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
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
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
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
        final FushiDesignTokens tokens = FushiDesignTokens.of(context);
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
                child: FushiLinearProgressIndicator(
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

  static String _formatDuration(Duration d) => FushiTimeFormat.clockPadded(d);

  Future<void> _doSearch() async {
    final String query = _searchController.text.trim();
    if (query.isEmpty) return;
    final int gen = ++_searchGeneration;
    setState(() {
      _isSearching = true;
      _searchFailed = false;
    });
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
      debugPrint('[fushi-search] error: $e');
      if (!mounted || gen != _searchGeneration) return;
      setState(() {
        _searchResults = const [];
        _searchResultsQuery = '';
        _isSearching = false;
        _searchFailed = true;
      });
    }
  }

  Widget _buildSearchSection(ThemeData theme) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool navPanel = widget.presentation ==
        ReaderQuickSettingsPresentation.sideSheetNavigation;
    final bool glass = isGlassDesign(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 导航侧板的页签已经写着「搜索」，只在设置 sheet 的定位子页补小节标题。
        if (!navPanel)
          SettingsSectionHeader(
            t.book_search,
            padding: EdgeInsets.only(bottom: tokens.spacing.gap),
          ),
        Row(
          children: [
            Expanded(
              child: FushiTextField(
                controller: _searchController,
                autofocus: widget.autofocusSearch,
                hintText: t.book_search_hint,
                prefixIcon: navPanel
                    ? FushiIcon(
                        Icons.search_rounded,
                        size: 20,
                        color: fushiNeutralSecondaryForeground(context),
                      )
                    : null,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: tokens.spacing.rowHorizontal,
                  vertical: tokens.spacing.rowVertical,
                ),
                style: theme.textTheme.bodyLarge,
                onSubmitted: (_) => _doSearch(),
              ),
            ),
            SizedBox(width: tokens.spacing.gap),
            SizedBox.square(
              dimension: 48,
              child: Center(
                child: _isSearching
                    ? SizedBox(
                        width: 22,
                        height: 22,
                        child:
                            adaptiveIndicator(context: context, strokeWidth: 2),
                      )
                    : FushiIconButton(
                        icon: Icons.arrow_forward_rounded,
                        size: 22,
                        // M3E：主操作用强调色实心圆角方块（形状对比于胶囊输入框）；
                        // Apple：强调色实心圆。
                        backgroundColor: glass
                            ? appleColorsOf(context).accent
                            : theme.colorScheme.primary,
                        enabledColor: glass
                            ? appleColorsOf(context).onAccent
                            : theme.colorScheme.onPrimary,
                        shapeBorder: glass
                            ? const CircleBorder()
                            : const RoundedRectangleBorder(
                                borderRadius: BorderRadius.all(
                                  Radius.circular(16),
                                ),
                              ),
                        padding: EdgeInsets.all(tokens.spacing.gap + 4),
                        tooltip: t.search,
                        onTap: _doSearch,
                      ),
              ),
            ),
          ],
        ),
        if (_searchResults.isNotEmpty) ...[
          SizedBox(height: tokens.spacing.gap * 2),
          ReaderPanelSectionLabel(
            t.book_search_results(n: _searchResults.length),
            trailing: '「$_searchResultsQuery」',
          ),
          ConstrainedBox(
            // 导航侧板的「搜索」是独立分页，结果直接随页滚动；窄窗 sheet 里搜索与
            // 目录同列，结果框限高自滚。
            constraints: BoxConstraints(
              maxHeight: navPanel ? double.infinity : 280,
            ),
            child: ListView.separated(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              physics: navPanel ? const NeverScrollableScrollPhysics() : null,
              itemCount: _searchResults.length,
              separatorBuilder: (_, __) => SizedBox(height: tokens.spacing.gap),
              itemBuilder: (_, i) {
                final BookSearchResult r = _searchResults[i];
                final String query = _searchResultsQuery;
                final int rawIdx = r.sectionIndex;
                final List<TtuTocEntry> toc = widget.toc;
                // 目录是 spine 的稀疏映射：结果所在章用 floor 口径反查章名
                // （与当前章判据同一函数），落在目录未直接指向的 spine 位置上
                // 也能报出所属章。
                final int? tocRow = resolveCurrentTocEntry(toc, rawIdx, null);
                final String chapterLabel = tocRow != null
                    ? toc[tocRow].label
                    : t.go_to_chapter(n: rawIdx + 1);
                final int matchEnd =
                    (r.matchStart + query.length).clamp(0, r.context.length);
                return FushiStaggeredEntrance(
                  index: i,
                  child: _InBookSearchResultRow(
                    chapterLabel: chapterLabel,
                    text: r.context,
                    matchStart: r.matchStart,
                    matchEnd: matchEnd,
                    onTap: () async {
                      final String q = _searchResultsQuery;
                      Navigator.pop(context);
                      await widget.onSearchJump?.call(r, q);
                    },
                  ),
                );
              },
            ),
          ),
        ] else if (!_isSearching && _searchFailed) ...[
          SizedBox(height: tokens.spacing.gap),
          Row(
            key: const ValueKey<String>('book_search_failed'),
            children: <Widget>[
              Expanded(
                child: Text(
                  t.book_search_failed,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
              TextButton(
                onPressed: _doSearch,
                child: Text(t.retry),
              ),
            ],
          ),
        ] else if (!_isSearching &&
            _searchController.text.trim().isNotEmpty &&
            _searchResultsQuery.isNotEmpty) ...[
          ReaderPanelEmpty(
            icon: Icons.search_off_rounded,
            message: t.book_search_no_results,
          ),
        ],
      ],
    );
  }

  Widget _buildCharJumpSection(ThemeData theme) {
    final int? current = widget.charProgress?.$1;
    final int? total = widget.charProgress?.$2;
    final bool hasProgress = current != null && total != null && total > 0;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool navPanel = widget.presentation ==
        ReaderQuickSettingsPresentation.sideSheetNavigation;
    final NumberFormat count = NumberFormat.decimalPattern();

    final Widget body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (navPanel)
          ReaderPanelSectionLabel(
            t.jump_to_char,
            trailing: hasProgress
                ? t.reader_nav_progress_chars(
                    current: count.format(current),
                    total: count.format(total),
                  )
                : null,
          )
        else ...[
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
        ],
        Row(
          children: [
            Expanded(
              child: FushiTextField(
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
              dimension: 48,
              child: Center(
                child: FushiIconButton(
                  icon: Icons.arrow_forward_rounded,
                  size: 22,
                  backgroundColor: theme.colorScheme.secondaryContainer,
                  enabledColor: theme.colorScheme.onSecondaryContainer,
                  shapeBorder: isGlassDesign(context)
                      ? const CircleBorder()
                      : const RoundedRectangleBorder(
                          borderRadius: BorderRadius.all(Radius.circular(16)),
                        ),
                  padding: EdgeInsets.all(tokens.spacing.gap + 4),
                  tooltip: t.jump_to_char,
                  onTap: () => _doCharJump(context),
                ),
              ),
            ),
          ],
        ),
      ],
    );
    if (!navPanel) return body;
    // 导航侧板：按字数跳转收进一张内卡，和上面的搜索结果分开。
    return ReaderPanelCard(
      key: const ValueKey<String>('reader_nav_char_jump_card'),
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.gap + 4,
        tokens.spacing.gap + 4,
        tokens.spacing.gap,
        tokens.spacing.gap + 4,
      ),
      child: body,
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
    final ReaderTocVolumeSwitch? volumes = widget.volumeSwitch;
    if (volumes == null) return _buildCurrentTocSection(context, theme);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool peekingSibling = _viewedVolume != volumes.currentIndex;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _buildVolumeChips(theme, volumes),
        SizedBox(height: tokens.spacing.gap),
        if (!peekingSibling)
          _buildCurrentTocSection(context, theme)
        else
          _buildSiblingTocSection(context, theme, volumes, _viewedVolume),
      ],
    );
  }

  /// 卷 chip 行：当前卷带勾；点别的卷只换下方列表（无感查看），不切书。
  Widget _buildVolumeChips(ThemeData theme, ReaderTocVolumeSwitch volumes) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return SizedBox(
      height: 40,
      child: HorizontalDragScrollable(
        child: ListView.separated(
          key: const ValueKey<String>('reader-toc-volume-chips'),
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.symmetric(horizontal: tokens.spacing.gap / 2),
          itemCount: volumes.labels.length,
          separatorBuilder: (_, __) => SizedBox(width: tokens.spacing.gap),
          itemBuilder: (BuildContext context, int i) => FushiChoiceChip(
            key: ValueKey<String>('reader-toc-volume-chip-$i'),
            label: Text(
              volumes.labels[i],
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            avatar: i == volumes.currentIndex
                ? const FushiIcon(Icons.menu_book_outlined, size: 16)
                : null,
            selected: i == _viewedVolume,
            onSelected: (bool _) {
              if (i == _viewedVolume) return;
              setState(() => _viewedVolume = i);
            },
          ),
        ),
      ),
    );
  }

  /// 兄弟卷的目录：isolate 解析（按卷缓存）→ 列表；首行「打开本卷」按保存位置整卷
  /// 切过去；点某章 = 切书并落到该章。不可查看的卷（PDF / 漫画）只有首行。
  Widget _buildSiblingTocSection(
    BuildContext context,
    ThemeData theme,
    ReaderTocVolumeSwitch volumes,
    int volume,
  ) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    Future<void> jump(int? chapterIndex) async {
      Navigator.of(context).pop();
      await volumes.onJump(volume, chapterIndex);
    }

    final Widget openRow = _InBookTocRow(
      key: ValueKey<String>('reader-toc-volume-open-$volume'),
      // index 只用来区分 header（<0 = 标题行不可点）；本行是可点动作行，回调
      // 自带卷号，不读 index。
      entry: TtuTocEntry(index: 0, label: t.reader_volume_open),
      onTap: () => unawaited(jump(null)),
    );
    return FutureBuilder<List<TtuTocEntry>>(
      key: ValueKey<String>('reader-toc-volume-toc-$volume'),
      future: volumes.tocOf(volume),
      builder: (BuildContext context, AsyncSnapshot<List<TtuTocEntry>> snap) {
        final List<Widget> rows = <Widget>[openRow];
        if (snap.hasError) {
          rows.add(
            Padding(
              padding: EdgeInsets.all(tokens.spacing.rowHorizontal),
              child: Text(
                t.reader_volume_peek_failed,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ),
          );
        } else if (!snap.hasData) {
          rows.add(
            Padding(
              padding: EdgeInsets.all(tokens.spacing.rowHorizontal),
              child: const Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: FushiCircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          );
        } else {
          final List<TtuTocEntry> toc = snap.data!;
          final List<int> levels = readerTocHierarchy(toc).levels;
          for (int i = 0; i < toc.length; i++) {
            if (levels[i] > 0) continue; // 兄弟卷只列顶层章，够定位即可。
            rows.add(
              _InBookTocRow(
                entry: toc[i],
                onTap:
                    toc[i].isHeader ? null : () => unawaited(jump(toc[i].index)),
              ),
            );
          }
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            ReaderPanelSectionLabel(volumes.labels[volume]),
            ...rows,
          ],
        );
      },
    );
  }

  Widget _buildCurrentTocSection(BuildContext context, ThemeData theme) {
    final List<TtuTocEntry> toc = widget.toc;
    // BUG-2545：目录是 spine 的**稀疏**映射（同一章横跨多个 xhtml 只有头一个进
    // 目录，章间插图页根本不在目录里），所以「当前章」不能拿当前 spine 章号去和
    // 目录项 index 精确相等——那样一来读在任何没被目录直接指向的 spine 位置上
    // （实测一本 35 项 spine 的书里占 23 个位置）整个列表一行都不标、
    // `_currentTocRowKey` 也挂不上，「打开即滚到当前章」跟着静默失效。判据统一成
    // floor（最后一个不晚于当前位置的目录项），与页脚章名
    // `_currentChapterLabelFor` 和有声书面板「章节」tab 同一口径。
    //
    // 同一 spine 章下靠 `#anchor` 分节的多条目录项（一个 xhtml 装整卷）章号全
    // 相同，再按章内字符偏移比一次（[resolveCurrentTocEntry]），当前只落在
    // **一条**上——旧判据只比章号，那一章下的每一条都被标成当前（四个勾）。
    final int? currentRow = resolveCurrentTocEntry(
      toc,
      widget.readerProgress?.$1,
      widget.readerCharOffset,
    );
    // 层级与折叠（[readerTocHierarchy]）：旧口径 depth >= 2 与真实 EPUB 压平后
    // 只剩的 `parent` 链两套来源取其一；子项挂在父项下，任一祖先未展开则不画。
    // 当前章所在的祖先链自动展开。
    final ({List<int> levels, List<int> parents}) tree =
        readerTocHierarchy(toc);
    final Set<int> autoExpanded = <int>{};
    if (currentRow != null) {
      for (int p = tree.parents[currentRow]; p >= 0; p = tree.parents[p]) {
        autoExpanded.add(p);
      }
    }
    bool hasFoldableChildren(int i) =>
        i + 1 < toc.length && tree.parents[i + 1] == i;
    bool isExpanded(int i) =>
        _expandedTocParents.contains(toc[i].label) ||
        (autoExpanded.contains(i) &&
            !_collapsedTocParents.contains(toc[i].label));
    bool isVisible(int i) {
      for (int p = tree.parents[i]; p >= 0; p = tree.parents[p]) {
        if (!isExpanded(p)) return false;
      }
      return true;
    }

    // 「当前章那一行」只能有**一行**：`_currentTocRowKey` 是 GlobalKey，同一个
    // key 挂到两个在场 widget 上，debug 直接抛 `Multiple widgets used the same
    // GlobalKey`，release 则由 `Element._retakeInactiveElement` 把 element 从前
    // 一行手里抢走——那一行被摘出渲染树，**目录里真的少一行**。
    // [resolveCurrentTocEntry] 返回的就是唯一一条的下标。
    final List<Widget> rows = <Widget>[
      for (int i = 0; i < toc.length; i++)
        if (isVisible(i))
          _InBookTocRow(
            key: i == currentRow ? _currentTocRowKey : null,
            entry: toc[i],
            level: tree.levels[i],
            state: currentRow == null
                ? ReaderTocRowState.unread
                : i == currentRow
                    ? ReaderTocRowState.current
                    : i < currentRow
                        ? ReaderTocRowState.read
                        : ReaderTocRowState.unread,
            foldable: hasFoldableChildren(i),
            expanded: hasFoldableChildren(i) && isExpanded(i),
            onToggleExpanded: hasFoldableChildren(i)
                ? () => setState(() {
                      final String label = toc[i].label;
                      // 当前章所在的父项默认展开；收起它记进 _collapsedTocParents，
                      // 否则下次 build 又被自动展开。
                      if (isExpanded(i)) {
                        _expandedTocParents.remove(label);
                        _collapsedTocParents.add(label);
                      } else {
                        _expandedTocParents.add(label);
                        _collapsedTocParents.remove(label);
                      }
                    })
                : null,
            onTap: toc[i].isHeader
                ? null
                : () async {
                    Navigator.of(context).pop();
                    await widget.onJumpSection(
                      toc[i].index,
                      toc[i].fragment,
                    );
                  },
          ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 导航侧板的页签已经写着「目录」，只在别处（设置 sheet 的定位子页）
        // 才补小节标题。
        if (widget.presentation !=
            ReaderQuickSettingsPresentation.sideSheetNavigation)
          ReaderPanelSectionLabel(t.toc_section(n: toc.length)),
        AnimatedSize(
          duration: fushiMotionDuration(context, FushiMotion.medium),
          curve: FushiMotion.enter,
          alignment: Alignment.topCenter,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: rows,
          ),
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
        final FushiDesignTokens tokens = FushiDesignTokens.of(context);
        final double current = ctrl.speed;
        final String readout = AudiobookSpeedSlider.format(current);
        return AdaptiveSettingsRow(
          title: '${t.playback_speed} ($readout)',
          icon: Icons.speed_outlined,
          controlBelow: true,
          trailing: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 与歌词模式倍速面板同一个组件（范围 / 吸附 / 步进只写一处）。
              AudiobookSpeedSlider(speed: current, onChanged: ctrl.setSpeed),
              Align(
                alignment: Alignment.centerRight,
                child: FushiIconButton(
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
        // 2026-10 体验优化：声明 trailing 固有宽度（4 颗 48 按钮 + 72 读数），
        // 窄屏按真实需求换行而不是把标题削成一个字。
        return AdaptiveSettingsRow(
          title: t.av_sync,
          icon: Icons.sync_outlined,
          trailingWidth: 4 * kMinInteractiveDimension + 72,
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
              // 2026-10 体验优化：「点数字归零」此前没有任何可见提示。非零时
              // 读数改用主色 + 下划线（可点的观感），并挂 Tooltip「归零」。
              Tooltip(
                message: ms == 0 ? '' : t.av_sync_reset,
                child: FushiFocusable(
                  onTap: ms == 0 ? null : () => ctrl.setDelayMs(0),
                  child: SizedBox(
                    width: 72,
                    height: kMinInteractiveDimension,
                    child: Center(
                      child: Text(
                        _formatDelayMs(ms),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: ms == 0 ? null : theme.colorScheme.primary,
                          decoration: ms == 0
                              ? TextDecoration.none
                              : TextDecoration.underline,
                        ),
                      ),
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
                // 这一行现在换的是音频**与**字幕两半（[SrtBookReimportDialog]），
                // 不再只是「替换音频文件」。
                title: t.srt_book_reimport,
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
        if (widget.extractDir != null) _buildBookCssEditorSection(),
      ],
    );
  }

  /// 歌词专属字号 / 文字色 / 高亮色 / 四边距控件（歌词-only `setLyrics*` setter，
  /// 非 schema）。窄窗 sheet 形态的歌词布局子页用它；设置侧板的「歌词模式」页把
  /// 同一批行按任务拆成三组（[_buildLyricsTabBlocks]）。
  Widget _buildLyricsMarginSection() {
    return AdaptiveSettingsSection(
      children: [
        AdaptiveSettingsRow(
          title: t.lyrics_font_size_hint,
        ),
        _lyricsVerticalRow(),
        _lyricsBlurRow(),
        _lyricsFontSizeRow(),
        _buildLyricsTextColorRow(context),
        _buildLyricsHighlightColorRow(context),
        ..._lyricsMarginRows(),
      ],
    );
  }

  /// TODO-907: 歌词竖排开关（独立于正文 writing-mode）。切换走整页重建。
  Widget _lyricsVerticalRow() {
    return AdaptiveSettingsSwitchRow(
      title: t.lyrics_vertical_writing,
      subtitle: t.lyrics_vertical_writing_hint,
      value: _src.lyricsVerticalWriting,
      onChanged: (bool enabled) async {
        await _src.setLyricsVerticalWriting(enabled);
        if (!mounted) return;
        setState(() {});
        await widget.onLyricsReload?.call();
      },
    );
  }

  /// TODO-908: 歌词听力沉浸模糊开关（独立 key）。模糊是 live 维度，走
  /// onStyleChanged（_updateLyricsStyleLive → __lyricsSetBlur），不重建整页。
  Widget _lyricsBlurRow() {
    return AdaptiveSettingsSwitchRow(
      title: t.lyrics_blur,
      subtitle: t.lyrics_blur_hint,
      value: _src.lyricsBlur,
      onChanged: (bool enabled) async {
        await _src.setLyricsBlur(enabled);
        if (!mounted) return;
        setState(() {});
        widget.onStyleChanged?.call();
      },
    );
  }

  Widget _lyricsFontSizeRow() {
    return _numberStepper(
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
    );
  }

  List<Widget> _lyricsMarginRows() {
    Widget margin(
      String label,
      double value,
      Future<void> Function(double) write,
    ) {
      return _numberStepper(
        label: label,
        value: value,
        step: 1,
        min: 0,
        max: 30,
        format: (double v) => '${v.round()}',
        onChanged: (double v) {
          write(v);
          setState(() {});
          widget.onStyleChanged?.call();
        },
      );
    }

    return <Widget>[
      margin(t.margin_top, _src.lyricsMarginTop, _src.setLyricsMarginTop),
      margin(
        t.margin_bottom,
        _src.lyricsMarginBottom,
        _src.setLyricsMarginBottom,
      ),
      margin(t.margin_left, _src.lyricsMarginLeft, _src.setLyricsMarginLeft),
      margin(
        t.margin_right,
        _src.lyricsMarginRight,
        _src.setLyricsMarginRight,
      ),
    ];
  }

  /// 歌词「当前行高亮色」（BUG：歌词模式高亮颜色无法修改）。开关 = 是否用自定义色
  /// （关 = 跟随播放器主题：MD3 封面取色 primary / Apple 白，哨兵 0）；开时下方展开
  /// 内联取色器。改色写穿 source 并触发 live 重绘（歌词页的 `--ly-current`）。
  Widget _buildLyricsHighlightColorRow(BuildContext context) {
    final int stored = _src.lyricsHighlightColor;
    final bool custom = stored != 0;
    final Color themeFallback = Theme.of(context).colorScheme.primary;
    final Color current = custom ? Color(stored) : themeFallback;
    return AdaptiveSettingsSwitchActionRow(
      key: const ValueKey<String>('reader_lyrics_highlight_color'),
      title: t.lyrics_highlight_color,
      subtitle: t.lyrics_highlight_color_hint,
      value: custom,
      onChanged: (bool enabled) async {
        if (enabled) {
          // 种一个不透明的初始色（当前主题强调色），避免落哨兵 0。
          await _src.setLyricsHighlightColor(
            0xFF000000 | (themeFallback.toARGB32() & 0xFFFFFF),
          );
        } else {
          await _src.clearLyricsHighlightColor();
        }
        if (!mounted) return;
        setState(() {});
        widget.onStyleChanged?.call();
      },
      body: Row(
        children: [
          FushiColorSwatch(
            color: current,
            size: 20,
            shape: FushiColorSwatchShape.dot,
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
                    // 强制不透明（也保证非哨兵 0）。
                    _src.setLyricsHighlightColor(
                      0xFF000000 | (c.toARGB32() & 0xFFFFFF),
                    );
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
          FushiColorSwatch(
            color: current,
            size: 20,
            shape: FushiColorSwatchShape.dot,
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

  /// 收藏行副标题：`书名 - 章节 - 时间`，末尾追加阅读位置百分比（解析成功时）。
  String _favoriteMetaLabel(FavoriteSentence favorite, DateFormat fmt) {
    // 面板就在这本书里：不再重复书名，只报 章名 · 时间 · 位置。
    final String? position = widget.favoritePositionLabel?.call(favorite);
    return <String>[
      if (favorite.chapterLabel != null && favorite.chapterLabel!.isNotEmpty)
        favorite.chapterLabel!,
      fmt.format(favorite.createdAt),
      if (position != null) position,
    ].join(' · ');
  }

  Widget _buildFavoritesSection(BuildContext context, ThemeData theme) {
    final DateFormat fmt = DateFormat('MM/dd HH:mm');
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<FavoriteSentence> favorites = _favorites;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ReaderPanelSectionLabel(t.favorites(n: favorites.length)),
        for (int i = 0; i < favorites.length; i++)
          Padding(
            padding: EdgeInsets.only(bottom: tokens.spacing.gap),
            child: FushiStaggeredEntrance(
              index: i,
              child: AnimatedSwitcher(
                duration: fushiMotionDuration(context, FushiMotion.short),
                switchInCurve: FushiMotion.enter,
                switchOutCurve: FushiMotion.exit,
                child: _pendingFavoriteDeletes.containsKey(favorites[i])
                    ? _InBookFavoriteUndoRow(
                        favorite: favorites[i],
                        onUndo: () => _undoFavoriteDelete(favorites[i]),
                      )
                    : _buildFavoriteRow(context, favorites[i], fmt),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildFavoriteRow(
    BuildContext context,
    FavoriteSentence favorite,
    DateFormat fmt,
  ) {
    return _InBookFavoriteRow(
      favorite: favorite,
      // BUG-875 附带（用户反馈）：收藏行加「阅读位置」百分比（如 78.6%），
      // 让用户不放音频 / 不复制文本也能一眼看出这条收藏在书里的位置。位置解析
      // 失败（章字符账本未就绪）时不追加、只显示原元信息。
      metaLabel: _favoriteMetaLabel(favorite, fmt),
      color: _highlightColor(favorite.color),
      onPlay: widget.onPlayFavorite == null
          ? null
          : () async => widget.onPlayFavorite?.call(favorite),
      onJump: favorite.sectionIndex == null || widget.onJumpToFavorite == null
          ? null
          : () async {
              Navigator.of(context).pop();
              await widget.onJumpToFavorite?.call(favorite);
            },
      onCopy: () {
        Clipboard.setData(ClipboardData(text: favorite.text));
        // 2026-10 体验优化：提示文案是「已复制」而不是动作名「复制」。
        FushiToast.show(
          msg: t.copied_to_clipboard,
          severity: ToastSeverity.success,
        );
      },
      onDelete: () => _markFavoriteDeleted(favorite),
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
        return FushiColor.defaultHighlightYellow;
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
            child: Semantics(
              identifier: 'hibiki.reader.quick_settings.lyrics_toggle',
              child: _actionBtn(
                context,
                key: const ValueKey<String>('fushi_lyrics_mode_toggle'),
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
          ),
        Expanded(
          child: _actionBtn(
            context,
            icon: Icons.exit_to_app_outlined,
            label: t.action_exit,
            onTap: () {
              if (_exitScheduled) {
                return;
              }
              _exitScheduled = true;
              final VoidCallback exitReader = widget.onExitReader;
              Navigator.of(context).pop();
              WidgetsBinding.instance.addPostFrameCallback((_) {
                exitReader();
              });
            },
          ),
        ),
      ],
    );
  }

  Widget _actionBtn(
    BuildContext context, {
    Key? key,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    final ThemeData theme = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Widget button = InkWell(
      key: key,
      onTap: onTap,
      // Under FushiFocusRoot the registered FushiActivatableFocusTarget below
      // is the single focus stop; keep the InkWell ripple for mouse/touch but
      // stop it grabbing a competing, unregistered focus node.
      canRequestFocus: FushiFocusRoot.maybeControllerOf(context) == null,
      borderRadius: tokens.radii.controlRadius,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: tokens.spacing.gap + tokens.spacing.gap / 2,
          vertical: tokens.spacing.gap * 0.75,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FushiIcon(icon, size: 20, color: theme.colorScheme.onSurface),
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
    if (FushiFocusRoot.maybeControllerOf(context) == null) return button;
    return FushiActivatableFocusTarget(
      focusIdPrefix: 'reader-action',
      onTap: onTap,
      child: button,
    );
  }
}

class _InBookTocRow extends StatelessWidget {
  const _InBookTocRow({
    super.key,
    required this.entry,
    this.level = 0,
    this.state = ReaderTocRowState.unread,
    this.onTap,
    this.foldable = false,
    this.expanded = false,
    this.onToggleExpanded,
  });

  final TtuTocEntry entry;

  /// 层级（0 = 顶层），见 [readerTocHierarchy]。
  final int level;
  final ReaderTocRowState state;
  final VoidCallback? onTap;

  /// 有子节可折叠时，行尾给一个展开 / 收起箭头（旋转动画）。
  final bool foldable;
  final bool expanded;
  final VoidCallback? onToggleExpanded;

  @override
  Widget build(BuildContext context) {
    // 视觉见 [ReaderTocRow]：层级缩进 + 引导线、当前章色块 + M3E 形状图标、
    // 已读淡化；章节名最多 [ReaderTocRow.titleMaxLines] 行（TODO-1055）。
    return ReaderTocRow(
      title: entry.label.isEmpty ? t.untitled_chapter : entry.label,
      level: level,
      header: entry.isHeader,
      state: state,
      foldable: foldable,
      expanded: expanded,
      onToggleExpanded: onToggleExpanded,
      foldKey: ValueKey<String>('fushi_toc_fold_${entry.label}'),
      onTap: onTap,
    );
  }
}

class _InBookSearchResultRow extends StatelessWidget {
  const _InBookSearchResultRow({
    required this.chapterLabel,
    required this.text,
    required this.matchStart,
    required this.matchEnd,
    required this.onTap,
  });

  final String chapterLabel;

  /// 命中前后文与命中区间（[matchStart], [matchEnd]）。
  final String text;
  final int matchStart;
  final int matchEnd;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // 引文卡：上标章名、正文命中词高亮（[readerHighlightSpans]），整卡可点、
    // 焦点可遍历（登记为 reader-search-result 可激活目标）。
    return ReaderQuoteCard(
      overline: chapterLabel,
      quote: Text.rich(
        readerHighlightSpans(
          context,
          text: text,
          start: matchStart,
          end: matchEnd,
        ),
        key: const ValueKey<String>('reader_search_result_text'),
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: onTap,
      focusIdPrefix: 'reader-search-result',
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
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    // 引文卡：左侧细色条 = 收藏高亮色；整卡点击跳到该句（单独的跳转图标与之
    // 重复，已移除）；右下 播放 / 复制 / 删除。
    return ReaderQuoteCard(
      key: ValueKey<String>('in_book_favorite_${favorite.id}'),
      accent: color,
      quote: Text(favorite.text, maxLines: 6, overflow: TextOverflow.ellipsis),
      meta: metaLabel,
      onTap: onJump,
      focusIdPrefix: 'reader-favorite',
      actions: <Widget>[
        if (onPlay != null) ...[
          _InBookIconButton(
            materialIcon: Icons.volume_up_outlined,
            cupertinoIcon: CupertinoIcons.speaker_2,
            tooltip: t.play,
            onPressed: onPlay!,
          ),
          // 2026-10 体验优化：按钮间距 ≥ 8，避免复制 / 删除误触。
          SizedBox(width: tokens.spacing.gap),
        ],
        _InBookIconButton(
          materialIcon: Icons.copy_outlined,
          cupertinoIcon: CupertinoIcons.doc_on_doc,
          tooltip: t.copy,
          onPressed: onCopy,
        ),
        SizedBox(width: tokens.spacing.gap),
        _InBookIconButton(
          materialIcon: Icons.delete_outline,
          cupertinoIcon: CupertinoIcons.delete,
          tooltip: t.options_delete,
          destructive: true,
          onPressed: onDelete,
        ),
      ],
    );
  }
}

/// 2026-10 体验优化：收藏句删除后的撤销窗口行——原文划线 + 「撤销」按钮。
class _InBookFavoriteUndoRow extends StatelessWidget {
  const _InBookFavoriteUndoRow({
    required this.favorite,
    required this.onUndo,
  });

  final FavoriteSentence favorite;
  final VoidCallback onUndo;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      key: ValueKey<String>('in_book_favorite_undo_${favorite.id}'),
      padding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.rowHorizontal,
        vertical: tokens.spacing.gap / 2,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              favorite.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                decoration: TextDecoration.lineThrough,
              ),
            ),
          ),
          SizedBox(width: tokens.spacing.gap),
          TextButton(
            onPressed: onUndo,
            child: Text(t.undo),
          ),
        ],
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
        minSize: kMinInteractiveDimension,
        onPressed: onPressed,
        child: Semantics(
          button: true,
          label: tooltip,
          child: FushiIcon(cupertinoIcon, size: 18, color: color),
        ),
      );
    }

    return FushiIconButton(
      icon: materialIcon,
      size: 18,
      enabledColor: color,
      tooltip: tooltip,
      // 2026-10 体验优化：命中区 32 → 48（标准触控目标）。
      constraints: const BoxConstraints(
        minWidth: kMinInteractiveDimension,
        minHeight: kMinInteractiveDimension,
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
      // BUG-912 #3：手势被取消（指针滑出 / 识别器被上层夺走）而非正常 End 时，
      // onLongPressEnd 不必然回调；不补 cancel 的话 _timer 会持续每 100ms 连触
      // widget.onPressed()（数值狂涨 / 狂降）直到 dispose。与 video_fushi_page.dart
      // 的 _VideoRepeatGestureButton 对齐。
      onLongPressCancel: () => _stop(),
      child: FushiIconButton(
        icon: widget.icon,
        size: 18,
        tooltip: widget.tooltip,
        // 2026-10 体验优化：32×32 → 48×48 标准触控目标。
        constraints: const BoxConstraints.tightFor(
          width: kMinInteractiveDimension,
          height: kMinInteractiveDimension,
        ),
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

/// 导航侧板的分页（目录 / 收藏 / 搜索）。
enum _ReaderNavTab { contents, favorites, search }
