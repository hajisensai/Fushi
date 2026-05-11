import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wakelock/wakelock.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:intl/intl.dart';
import 'package:hibiki/src/media/audiobook/audiobook_bridge.dart';
import 'package:hibiki/src/media/audiobook/audiobook_controller.dart';
import 'package:hibiki/src/media/audiobook/bookmark_repository.dart';
import 'package:hibiki/src/media/audiobook/favorite_sentence_repository.dart';
import 'package:hibiki/src/media/sources/reader_hoshi_source.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/custom_theme_page.dart';
import 'package:hibiki/utils.dart';

/// 有声书播放控制条（紧凑型，固定于阅读器底部）。
///
/// Row 只放最常用的实时控件：⏮ ⏯ ⏭、当前 cue、Follow 磁铁、设置齿轮。
/// 倍速 / 音画同步 / 阅读进度 / 章节列表 / 添加书签 / 全屏 / 退出 放进
/// [onOpenSettings] 回调展开的底部设置面板 —— ttu 原生顶部工具栏被隐藏
/// 后这些功能的统一入口。
class AudiobookPlayBar extends StatelessWidget {
  const AudiobookPlayBar({
    required this.controller,
    required this.onOpenSettings,
    this.backgroundColor,
    super.key,
  });

  final AudiobookPlayerController controller;
  final Color? backgroundColor;

  /// 用户点 ⚙ 设置按钮后触发。由 reader 页面侧注入，因为设置面板要
  /// 访问 WebView controller 才能 probe ttu 当前章节 / TOC、触发书签。
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: backgroundColor ?? Theme.of(context).colorScheme.surface,
      child: SizedBox(
        height: 56,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.skip_previous),
                iconSize: 22,
                onPressed: controller.skipToPrevCue,
                tooltip: t.prev_sentence,
              ),
              IconButton.filledTonal(
                icon: Icon(
                  controller.isPlaying ? Icons.pause : Icons.play_arrow,
                ),
                iconSize: 24,
                onPressed: controller.togglePlayPause,
                tooltip: controller.isPlaying ? t.pause : t.play,
              ),
              IconButton(
                icon: const Icon(Icons.skip_next),
                iconSize: 22,
                onPressed: controller.skipToNextCue,
                tooltip: t.next_sentence,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  controller.currentCue?.text ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              AudiobookFollowAudioButton(controller: controller),
              IconButton(
                icon: const Icon(Icons.tune),
                iconSize: 20,
                onPressed: onOpenSettings,
                tooltip: t.audiobook_settings,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Follow audio 开关按钮（磁铁图标；PR8b）。
///
/// 独立于 [AudiobookPlayBar] 的 [ListenableBuilder] 订阅 —— 按钮只随
/// [AudiobookPlayerController.followAudio] 变化重绘，避免每次 cue 更新
/// 整条 play bar 都跟着刷新时这颗按钮也 rebuild。点击 toggle 并持久化
/// （controller 侧内部调 onCrossChapter 用户传入的 persist 回调）。
class AudiobookFollowAudioButton extends StatelessWidget {
  const AudiobookFollowAudioButton({required this.controller, super.key});

  final AudiobookPlayerController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: controller.followAudio,
      builder: (BuildContext context, bool on, _) {
        final ColorScheme colors = Theme.of(context).colorScheme;
        return IconButton(
          icon: Icon(on ? Icons.link : Icons.link_off),
          iconSize: 20,
          color: on ? colors.primary : colors.onSurfaceVariant,
          tooltip: on ? t.follow_audio_on_tooltip : t.follow_audio_off_tooltip,
          onPressed: () {
            // persist 回调在 reader 页面把 controller 和 repo 绑上；这里
            // 只翻内存状态，controller.setFollowAudio 内部会用绑好的回调
            // 落库，按钮自己不碰 Isar。
            controller.setFollowAudio(!on);
          },
        );
      },
    );
  }
}

/// Reader 设置面板 —— ttu 原生顶部工具栏被隐藏后的统一入口。
///
/// 两种召唤场景：
/// 1. 有声书模式：播放栏的 ⚙ 打开，[controller] 非空，显示全部 —— 阅读
///    进度 + TOC + 倍速 + 音画同步 + action row
/// 2. 普通 EPUB：左下角 ⚙ FAB 打开，[controller] 为 null，省略倍速 /
///    音画同步两节，只显示阅读进度 + TOC + action row
///
/// 类名保留 `Audiobook*` 前缀因为控件和 audiobook 播放栏在同一文件里；
/// 语义上它已经是 reader-level 的设置面板。
///
/// [toc] / [readerProgress] 是 reader 页面 probe 后一次性传入的快照。
/// 面板生存期内不自动刷新（TOC 在一次阅读会话里是静态的；当前章节
/// 会随 follow audio 滚动变，但打开面板的当下已经 probe 了一次）。
ChoiceChip buildReaderThemeChip({
  required BuildContext context,
  required String label,
  required bool selected,
  required ValueChanged<bool> onSelected,
  Widget? avatar,
}) {
  final ColorScheme colors = Theme.of(context).colorScheme;
  return ChoiceChip(
    avatar: avatar,
    label: Text(label),
    selected: selected,
    showCheckmark: false,
    selectedColor: colors.primaryContainer,
    labelStyle: selected ? TextStyle(color: colors.onPrimaryContainer) : null,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(8),
      side: BorderSide(
        color: selected ? colors.primaryContainer : colors.outline,
      ),
    ),
    onSelected: onSelected,
  );
}

class AudiobookSettingsSheet extends StatefulWidget {
  AudiobookSettingsSheet({
    required this.controller,
    required this.toc,
    required this.readerProgress,
    this.pageProgress,
    required this.onJumpSection,
    required this.onBookmark,
    required this.onExitReader,
    required this.webViewController,
    required this.appModel,
    this.onThemeChanged,
    this.bookmarks = const [],
    this.onJumpToBookmark,
    this.onDeleteBookmark,
    this.favoriteSentences = const [],
    this.onDeleteFavorite,
    this.onJumpToFavorite,
    this.onPlayFavorite,
    this.showPlayBar = true,
    this.onTogglePlayBar,
    this.showMediaNotification = true,
    this.onToggleMediaNotification,
    this.showFloatingLyric = false,
    this.onToggleFloatingLyric,
    this.floatingLyricFontSize = 20,
    this.onFloatingLyricFontSizeChanged,
    this.onSearchJump,
    this.onJumpToCharOffset,
    this.charProgress,
    this.onPageMarginChanged,
    this.isHoshiReader = false,
    super.key,
  });

  final AudiobookPlayerController? controller;
  final List<TtuTocEntry> toc;
  final (int section, int total)? readerProgress;
  final (int current, int total)? pageProgress;
  final Future<void> Function(int sectionIndex) onJumpSection;
  final Future<void> Function() onBookmark;
  final VoidCallback onExitReader;
  final InAppWebViewController webViewController;
  final AppModel appModel;
  final Future<void> Function()? onThemeChanged;
  final List<Bookmark> bookmarks;
  final Future<void> Function(Bookmark bookmark)? onJumpToBookmark;
  final Future<void> Function(int index)? onDeleteBookmark;
  final List<FavoriteSentence> favoriteSentences;
  final Future<void> Function(int index)? onDeleteFavorite;
  final Future<void> Function(FavoriteSentence fav)? onJumpToFavorite;
  final Future<void> Function(FavoriteSentence fav)? onPlayFavorite;
  final bool showPlayBar;
  final VoidCallback? onTogglePlayBar;
  final bool showMediaNotification;
  final VoidCallback? onToggleMediaNotification;
  final bool showFloatingLyric;
  final Future<bool> Function()? onToggleFloatingLyric;
  final double floatingLyricFontSize;
  final ValueChanged<double>? onFloatingLyricFontSizeChanged;
  final Future<void> Function(int sectionIndex, int charOffset)? onSearchJump;
  final Future<void> Function(int globalCharOffset)? onJumpToCharOffset;
  final (int current, int total)? charProgress;
  final VoidCallback? onPageMarginChanged;

  /// When true, skip AudiobookBridge JS calls and disable ttu-only features.
  final bool isHoshiReader;

  @override
  State<AudiobookSettingsSheet> createState() => _AudiobookSettingsSheetState();
}

class _AudiobookSettingsSheetState extends State<AudiobookSettingsSheet> {
  ReaderHoshiSource get _src => ReaderHoshiSource.instance;

  TtuReaderSettings? _settings;

  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _charJumpController = TextEditingController();
  List<BookSearchResult> _searchResults = const [];
  bool _isSearching = false;

  String? _subPage;

  late List<Bookmark> _bookmarks = List<Bookmark>.of(widget.bookmarks);
  late List<FavoriteSentence> _favorites =
      List<FavoriteSentence>.of(widget.favoriteSentences);

  late bool _localShowFloatingLyric = widget.showFloatingLyric;
  late bool _localShowMediaNotification = widget.showMediaNotification;
  late double _localFloatingLyricFontSize = widget.floatingLyricFontSize;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _charJumpController.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    if (widget.isHoshiReader) {
      final TtuReaderSettings s = TtuReaderSettings(
        fontSize: _src.ttuFontSize,
        lineHeight: _src.ttuLineHeight,
        writingMode: _src.ttuWritingMode,
        viewMode: _src.ttuViewMode,
        theme: _src.ttuTheme,
        hideFurigana: _src.ttuFuriganaMode == 'hide',
        fontFamilyGroupOne: 'Noto Serif JP',
        fontFamilyGroupTwo: 'Noto Sans JP',
      );
      if (mounted) setState(() => _settings = s);
      return;
    }
    final TtuReaderSettings s =
        await AudiobookBridge.getReaderSettings(widget.webViewController);
    if (mounted) setState(() => _settings = s);
  }

  Future<void> _updateSetting(String key, Object value) async {
    if (!widget.isHoshiReader) {
      await AudiobookBridge.setReaderSetting(
        widget.webViewController,
        key: key,
        value: value,
      );
    }
    final ReaderHoshiSource src = ReaderHoshiSource.instance;
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
      case 'firstDimensionMargin':
        await src.setTtuFirstDimensionMargin((value as num).toDouble());
        widget.onPageMarginChanged?.call();
      case 'secondDimensionMaxValue':
        await src.setTtuSecondDimensionMaxValue((value as num).toDouble());
      case 'pageColumns':
        await src.setTtuPageColumns((value as num).toInt());
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
  }

  Future<void> _applyFuriganaMode(String mode) async {
    if (widget.isHoshiReader) {
      _src.setTtuFuriganaMode(mode);
      return;
    }
    final hide = mode != 'show';
    final style = switch (mode) {
      'hide' => 'Hide',
      'partial' => 'partial',
      'toggle' => 'toggle',
      _ => 'partial',
    };
    await _updateSetting('hideFurigana', hide);
    await _updateSetting('furiganaStyle', style);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return PopScope(
      canPop: _subPage == null,
      onPopInvokedWithResult: (bool didPop, _) {
        if (!didPop) {
          setState(() => _subPage = null);
        }
      },
      child: SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.80,
          ),
          child: SingleChildScrollView(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                20,
                4,
                20,
                24 + MediaQuery.of(context).viewInsets.bottom,
              ),
              child: AnimatedSize(
                duration: const Duration(milliseconds: 200),
                alignment: Alignment.topCenter,
                child: _subPage != null
                    ? _buildSubPage(context, theme)
                    : _buildMainPage(context, theme),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMainPage(BuildContext context, ThemeData theme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildProgressSection(theme),
        const SizedBox(height: 12),
        _categoryTile(
          theme,
          icon: Icons.menu_book,
          label: t.section_navigation,
          page: 'navigation',
        ),
        if (widget.controller != null)
          _categoryTile(
            theme,
            icon: Icons.headphones,
            label: t.section_audiobook,
            page: 'audiobook',
          ),
        _categoryTile(
          theme,
          icon: Icons.auto_stories,
          label: t.reader_settings_section,
          page: 'reader',
        ),
        _categoryTile(
          theme,
          icon: Icons.text_fields,
          label: t.section_typography,
          page: 'typography',
        ),
        _categoryTile(
          theme,
          icon: Icons.view_quilt,
          label: t.section_layout,
          page: 'layout',
        ),
        if (widget.controller != null)
          _categoryTile(
            theme,
            icon: Icons.tune,
            label: t.section_interface,
            page: 'interface',
          ),
        const SizedBox(height: 12),
        const Divider(height: 1),
        const SizedBox(height: 12),
        _buildActionRow(context),
      ],
    );
  }

  Widget _buildSubPage(BuildContext context, ThemeData theme) {
    final String page = _subPage!;
    String title;
    Widget content;
    switch (page) {
      case 'audiobook':
        title = t.section_audiobook;
        content = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildVolumeSection(theme, widget.controller!),
            const SizedBox(height: 16),
            _buildSpeedSection(theme, widget.controller!),
            const SizedBox(height: 16),
            _buildDelaySection(theme, widget.controller!),
            const SizedBox(height: 16),
            _buildImagePauseSection(theme, widget.controller!),
          ],
        );
      case 'navigation':
        title = t.section_navigation;
        content = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!widget.isHoshiReader) _buildSearchSection(theme),
            if (widget.onJumpToCharOffset != null) ...[
              const SizedBox(height: 12),
              _buildCharJumpSection(theme),
            ],
            if (widget.toc.isNotEmpty) ...[
              const SizedBox(height: 12),
              _buildTocSection(context, theme),
            ],
            if (_bookmarks.isNotEmpty) ...[
              const SizedBox(height: 12),
              _buildBookmarkSection(context, theme),
            ],
            if (_favorites.isNotEmpty) ...[
              const SizedBox(height: 12),
              _buildFavoritesSection(context, theme),
            ],
          ],
        );
      case 'reader':
        title = t.reader_settings_section;
        content = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: _buildReaderSwitches(theme),
        );
      case 'typography':
        title = t.section_typography;
        content = _buildTypographySection(theme);
      case 'layout':
        title = t.section_layout;
        content = _buildLayoutSection(theme);
      case 'interface':
        title = t.section_interface;
        content = _buildPlayBarToggle(theme);
      default:
        title = '';
        content = const SizedBox.shrink();
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => setState(() => _subPage = null),
            ),
            const SizedBox(width: 4),
            Text(title, style: theme.textTheme.titleMedium),
          ],
        ),
        const SizedBox(height: 12),
        content,
      ],
    );
  }

  Widget _categoryTile(
    ThemeData theme, {
    required IconData icon,
    required String label,
    required String page,
  }) {
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Icon(icon, size: 22),
      title: Text(label),
      trailing: const Icon(Icons.chevron_right, size: 20),
      onTap: () => setState(() => _subPage = page),
    );
  }

  Widget _buildProgressSection(ThemeData theme) {
    final List<String> lines = [];

    final (int, int)? rp = widget.readerProgress;
    if (rp != null && rp.$2 > 0) {
      final double pct = (rp.$1 / rp.$2) * 100;
      lines.add(t.chapter_progress(
        idx: rp.$1,
        total: rp.$2,
        suffix: '',
        pct: pct.toStringAsFixed(1),
      ));
    }

    final (int, int)? pp = widget.pageProgress;
    if (pp != null && pp.$2 > 0) {
      lines.add(t.page_progress(current: pp.$1, total: pp.$2));
    }

    if (lines.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(t.reading_progress, style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        for (final String line in lines)
          Text(line, style: theme.textTheme.bodyMedium),
      ],
    );
  }

  Widget _buildSearchSection(ThemeData theme) {
    return StatefulBuilder(
      builder: (BuildContext ctx, StateSetter setLocal) {
        Future<void> doSearch() async {
          final String query = _searchController.text.trim();
          if (query.isEmpty) return;
          setLocal(() => _isSearching = true);
          try {
            final List<BookSearchResult> results =
                await AudiobookBridge.searchBook(
              widget.webViewController,
              query,
            );
            setLocal(() {
              _searchResults = results;
              _isSearching = false;
            });
          } catch (e) {
            debugPrint('[hibiki-search] error: $e');
            setLocal(() {
              _searchResults = const [];
              _isSearching = false;
            });
          }
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.book_search, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      hintText: t.book_search_hint,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      border: const OutlineInputBorder(),
                    ),
                    style: theme.textTheme.bodyMedium,
                    onSubmitted: (_) => doSearch(),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  height: 40,
                  child: FilledButton.tonal(
                    onPressed: _isSearching ? null : doSearch,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      visualDensity: VisualDensity.compact,
                    ),
                    child: _isSearching
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.search, size: 20),
                  ),
                ),
              ],
            ),
            if (_searchResults.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                t.book_search_results(n: _searchResults.length),
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 280),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _searchResults.length,
                  itemBuilder: (_, int i) {
                    final BookSearchResult r = _searchResults[i];
                    final String query = _searchController.text.trim();
                    final int rawIdx = r.sectionIndex;
                    final List<TtuTocEntry> toc = widget.toc;
                    final TtuTocEntry? tocEntry =
                        toc.cast<TtuTocEntry?>().firstWhere(
                              (TtuTocEntry? e) => e!.index == rawIdx,
                              orElse: () => null,
                            );
                    final String chapterLabel =
                        tocEntry?.label ?? t.go_to_chapter(n: rawIdx + 1);

                    final String before = r.context.substring(0, r.matchStart);
                    final int matchEnd = (r.matchStart + query.length)
                        .clamp(0, r.context.length);
                    final String match =
                        r.context.substring(r.matchStart, matchEnd);
                    final String after = r.context.substring(matchEnd);

                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        chapterLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                      ),
                      subtitle: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(text: before),
                            TextSpan(
                              text: match,
                              style: TextStyle(
                                backgroundColor:
                                    theme.colorScheme.primaryContainer,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            TextSpan(text: after),
                          ],
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                      onTap: () {
                        Navigator.pop(ctx);
                        widget.onSearchJump?.call(
                          r.sectionIndex,
                          r.charOffset,
                        );
                      },
                    );
                  },
                ),
              ),
            ] else if (!_isSearching &&
                _searchController.text.trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                t.book_search_no_results,
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _buildCharJumpSection(ThemeData theme) {
    final int? current = widget.charProgress?.$1;
    final int? total = widget.charProgress?.$2;
    final bool hasProgress = current != null && total != null && total > 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(t.jump_to_char, style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        if (hasProgress)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              t.jump_to_char_current(current: current, total: total),
              style: theme.textTheme.bodySmall,
            ),
          ),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _charJumpController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  hintText: t.jump_to_char_hint,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  border: const OutlineInputBorder(),
                ),
                style: theme.textTheme.bodyMedium,
                onSubmitted: (_) => _doCharJump(context),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 40,
              child: FilledButton.tonal(
                onPressed: () => _doCharJump(context),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  visualDensity: VisualDensity.compact,
                ),
                child: const Icon(Icons.arrow_forward, size: 20),
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
    return Theme(
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        minTileHeight: 36,
        title: Text(
          t.toc_section(n: widget.toc.length),
          style: theme.textTheme.titleMedium,
        ),
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: widget.toc.length,
              itemBuilder: (BuildContext ctx, int i) {
                final TtuTocEntry e = widget.toc[i];
                final bool isCurrent = currentIdx == i;
                final bool isChild = e.parent != null;
                return ListTile(
                  dense: true,
                  visualDensity: const VisualDensity(vertical: -3),
                  contentPadding: EdgeInsets.only(
                    left: isChild ? 24 : 0,
                    right: 8,
                  ),
                  title: Text(
                    e.label.isEmpty ? t.untitled_chapter : e.label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: isCurrent
                        ? theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          )
                        : theme.textTheme.bodyMedium,
                  ),
                  trailing: isCurrent
                      ? Icon(Icons.chevron_right,
                          color: theme.colorScheme.primary, size: 20)
                      : null,
                  onTap: () async {
                    Navigator.of(ctx).pop();
                    await widget.onJumpSection(e.index);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBookmarkSection(BuildContext context, ThemeData theme) {
    final DateFormat fmt = DateFormat('MM/dd HH:mm');
    return Theme(
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        minTileHeight: 36,
        title: Text(
          '${t.action_bookmark} (${_bookmarks.length})',
          style: theme.textTheme.titleMedium,
        ),
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _bookmarks.length,
              itemBuilder: (BuildContext ctx, int i) {
                final Bookmark bm = _bookmarks[i];
                final String pageInfo =
                    bm.pageInChapter != null && bm.totalPagesInChapter != null
                        ? ' · ${bm.pageInChapter}/${bm.totalPagesInChapter}'
                        : '';
                return ListTile(
                  dense: true,
                  visualDensity: const VisualDensity(vertical: -3),
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    '${bm.label}$pageInfo',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                  subtitle: Text(
                    fmt.format(bm.createdAt),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, size: 18),
                    onPressed: () async {
                      await widget.onDeleteBookmark?.call(i);
                      if (mounted) {
                        setState(() {
                          _bookmarks = List<Bookmark>.of(_bookmarks)
                            ..removeAt(i);
                        });
                      }
                    },
                  ),
                  onTap: () async {
                    Navigator.of(ctx).pop();
                    await widget.onJumpToBookmark?.call(bm);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVolumeSection(ThemeData theme, AudiobookPlayerController ctrl) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(t.audio_volume, style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Row(
          children: [
            const Icon(Icons.volume_down, size: 20),
            Expanded(
              child: Slider(
                value: ctrl.volume,
                min: 0.0,
                max: 2.0,
                onChanged: (double v) {
                  ctrl.setVolume(v);
                  setState(() {});
                },
              ),
            ),
            const Icon(Icons.volume_up, size: 20),
          ],
        ),
      ],
    );
  }

  Widget _buildSpeedSection(ThemeData theme, AudiobookPlayerController ctrl) {
    return ListenableBuilder(
      listenable: ctrl,
      builder: (BuildContext context, _) {
        final double current = ctrl.speed;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(t.playback_speed, style: theme.textTheme.titleMedium),
                const Spacer(),
                Text(
                  '${current.toStringAsFixed(2)}x',
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.restart_alt, size: 18),
                  onPressed: (current - 1.0).abs() < 0.001
                      ? null
                      : () => ctrl.setSpeed(1.0),
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.only(left: 4),
                  constraints: const BoxConstraints(),
                  tooltip: t.av_sync_reset,
                ),
              ],
            ),
            Row(
              children: [
                Text('0.25', style: theme.textTheme.bodySmall),
                Expanded(
                  child: Slider(
                    value: current.clamp(0.25, 4.0),
                    min: 0.25,
                    max: 4.0,
                    divisions: 75,
                    onChanged: (double v) {
                      final double rounded = (v * 20).roundToDouble() / 20;
                      ctrl.setSpeed(rounded);
                    },
                  ),
                ),
                Text('4.0', style: theme.textTheme.bodySmall),
              ],
            ),
          ],
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
      builder: (BuildContext ctx, int ms, _) {
        return Row(
          children: [
            Expanded(
              child: Text(t.av_sync, style: theme.textTheme.titleMedium),
            ),
            _RepeatIconButton(
              icon: const Icon(Icons.keyboard_double_arrow_left, size: 18),
              onPressed: () => ctrl.setDelayMs(ctrl.delayMs.value - 1000),
            ),
            _RepeatIconButton(
              icon: const Icon(Icons.chevron_left, size: 18),
              onPressed: () => ctrl.setDelayMs(ctrl.delayMs.value - 50),
            ),
            GestureDetector(
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
              icon: const Icon(Icons.chevron_right, size: 18),
              onPressed: () => ctrl.setDelayMs(ctrl.delayMs.value + 50),
            ),
            _RepeatIconButton(
              icon: const Icon(Icons.keyboard_double_arrow_right, size: 18),
              onPressed: () => ctrl.setDelayMs(ctrl.delayMs.value + 1000),
            ),
          ],
        );
      },
    );
  }

  static const List<int> _imagePauseOptions = [0, 5, 10, 15];

  Widget _buildImagePauseSection(
      ThemeData theme, AudiobookPlayerController ctrl) {
    return ValueListenableBuilder<int>(
      valueListenable: ctrl.imagePauseSec,
      builder: (BuildContext ctx, int sec, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.image_pause, style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              t.image_pause_hint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            SegmentedButton<int>(
              showSelectedIcon: false,
              segments: _imagePauseOptions
                  .map((int s) => ButtonSegment<int>(
                        value: s,
                        label: Text(s == 0 ? t.image_pause_off : '${s}s'),
                      ))
                  .toList(),
              selected: <int>{sec},
              onSelectionChanged: (Set<int> sel) {
                ctrl.setImagePauseSec(sel.first);
              },
              style: _segmentedStyle(theme),
            ),
          ],
        );
      },
    );
  }

  List<Widget> _buildReaderSwitches(ThemeData theme) {
    Widget sw(String label, bool value, VoidCallback toggle) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Expanded(child: Text(label)),
            Switch(
                value: value,
                onChanged: (_) {
                  toggle();
                  setState(() {});
                }),
          ],
        ),
      );
    }

    return [
      sw(t.highlight_on_tap, _src.highlightOnTap, _src.toggleHighlightOnTap),
      sw(t.tap_empty_hide_chrome, _src.tapEmptyToHideChrome,
          _src.toggleTapEmptyToHideChrome),
      sw(t.volume_button_page_turning, _src.volumePageTurningEnabled, () {
        _src.toggleVolumePageTurningEnabled();
        VolumeKeyChannel.instance
            .setInterceptEnabled(_src.volumePageTurningEnabled);
      }),
      sw(t.invert_volume_buttons, _src.volumePageTurningInverted,
          _src.toggleVolumePageTurningInverted),
      sw(t.invert_swipe_direction, _src.invertSwipeDirection,
          _src.toggleInvertSwipeDirection),
      sw(t.keep_screen_awake, _src.keepScreenAwake, () async {
        _src.toggleKeepScreenAwake();
        if (_src.keepScreenAwake) {
          await Wakelock.enable();
        } else {
          await Wakelock.disable();
        }
      }),
      sw(t.auto_read_on_lookup, _src.autoReadOnLookup,
          _src.toggleAutoReadOnLookup),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Expanded(child: Text(t.dismiss_swipe_sensitivity)),
            SizedBox(
              width: 140,
              child: Slider(
                value: _src.dismissSwipeSensitivity,
                min: 0.1,
                max: 1.0,
                divisions: 9,
                label: _src.dismissSwipeSensitivity.toStringAsFixed(1),
                onChanged: (v) {
                  _src.setDismissSwipeSensitivity(v);
                  setState(() {});
                },
              ),
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Expanded(child: Text(t.volume_button_turning_speed)),
            SizedBox(
              width: 140,
              child: Slider(
                value: _src.volumePageTurningSpeed.toDouble(),
                min: 10,
                max: 500,
                divisions: 49,
                label: '${_src.volumePageTurningSpeed}',
                onChanged: (v) {
                  _src.setVolumePageTurningSpeed(v.round());
                  setState(() {});
                },
              ),
            ),
          ],
        ),
      ),
    ];
  }

  Widget _buildPlayBarToggle(ThemeData theme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
                child: Text(t.show_media_notification,
                    style: theme.textTheme.bodyMedium)),
            Switch(
              value: _localShowMediaNotification,
              onChanged: (_) {
                widget.onToggleMediaNotification?.call();
                setState(() {
                  _localShowMediaNotification = !_localShowMediaNotification;
                });
              },
            ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t.show_floating_lyric,
                      style: theme.textTheme.bodyMedium),
                  Text(
                    t.floating_lyric_hint,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Switch(
              value: _localShowFloatingLyric,
              onChanged: (_) async {
                final bool ok =
                    await widget.onToggleFloatingLyric?.call() ?? false;
                if (ok && mounted) {
                  setState(() {
                    _localShowFloatingLyric = !_localShowFloatingLyric;
                  });
                }
              },
            ),
          ],
        ),
        _settingRow(
          theme,
          label: t.floating_lyric_font_size,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.remove, size: 18),
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  final double value =
                      (_localFloatingLyricFontSize - 1).clamp(8, 64);
                  widget.onFloatingLyricFontSizeChanged?.call(value);
                  setState(() => _localFloatingLyricFontSize = value);
                },
              ),
              SizedBox(
                width: 36,
                child: Text(
                  '${_localFloatingLyricFontSize.round()}',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyLarge,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add, size: 18),
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  final double value =
                      (_localFloatingLyricFontSize + 1).clamp(8, 64);
                  widget.onFloatingLyricFontSizeChanged?.call(value);
                  setState(() => _localFloatingLyricFontSize = value);
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTypographySection(ThemeData theme) {
    final TtuReaderSettings? s = _settings;
    if (s == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _settingRow(
          theme,
          label: t.ttu_font_size,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.remove, size: 18),
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  final double v = (s.fontSize - 1).clamp(8, 64);
                  s.fontSize = v;
                  setState(() {});
                  _updateSetting('fontSize', v);
                },
              ),
              SizedBox(
                width: 36,
                child: Text(
                  '${s.fontSize.round()}',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyLarge,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add, size: 18),
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  final double v = (s.fontSize + 1).clamp(8, 64);
                  s.fontSize = v;
                  setState(() {});
                  _updateSetting('fontSize', v);
                },
              ),
            ],
          ),
        ),
        _settingRow(
          theme,
          label: t.ttu_line_height,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.remove, size: 18),
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  final double v =
                      ((s.lineHeight - 0.1) * 100).roundToDouble() / 100;
                  s.lineHeight = v.clamp(1.0, 3.0);
                  setState(() {});
                  _updateSetting('lineHeight', s.lineHeight);
                },
              ),
              SizedBox(
                width: 42,
                child: Text(
                  s.lineHeight.toStringAsFixed(2),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyLarge,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add, size: 18),
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  final double v =
                      ((s.lineHeight + 0.1) * 100).roundToDouble() / 100;
                  s.lineHeight = v.clamp(1.0, 3.0);
                  setState(() {});
                  _updateSetting('lineHeight', s.lineHeight);
                },
              ),
            ],
          ),
        ),
        _numberStepper(
          theme,
          label: t.ttu_text_indentation,
          value: _src.ttuTextIndentation,
          step: 1,
          min: 0,
          max: 10,
          format: (v) => '${v.round()}',
          onChanged: (v) {
            _src.setTtuTextIndentation(v);
            setState(() {});
            _updateSetting('textIndentation', v);
          },
        ),
        _numberStepper(
          theme,
          label: t.ttu_first_dimension_margin,
          value: _src.ttuFirstDimensionMargin,
          step: 5,
          min: 0,
          max: 100,
          format: (v) => '${v.round()}',
          onChanged: (v) {
            _src.setTtuFirstDimensionMargin(v);
            setState(() {});
            _updateSetting('firstDimensionMargin', v);
          },
        ),
        _numberStepper(
          theme,
          label: t.ttu_second_dimension_max,
          value: _src.ttuSecondDimensionMaxValue,
          step: 50,
          min: 0,
          max: 2000,
          format: (v) =>
              v.round() == 0 ? t.ttu_page_columns_auto : '${v.round()}',
          onChanged: (v) {
            _src.setTtuSecondDimensionMaxValue(v);
            setState(() {});
            _updateSetting('secondDimensionMaxValue', v);
          },
        ),
        _numberStepper(
          theme,
          label: t.ttu_page_columns,
          value: _src.ttuPageColumns.toDouble(),
          step: 1,
          min: 0,
          max: 4,
          format: (v) =>
              v.round() == 0 ? t.ttu_page_columns_auto : '${v.round()}',
          onChanged: (v) {
            _src.setTtuPageColumns(v.round());
            setState(() {});
            _updateSetting('pageColumns', v.round());
          },
        ),
        _settingRow(
          theme,
          label: t.ttu_text_justify,
          hint: t.ttu_text_justify_hint,
          child: Switch(
            value: _src.ttuEnableTextJustification,
            onChanged: (bool v) {
              _src.setTtuEnableTextJustification(v);
              setState(() {});
              _updateSetting('enableTextJustification', v);
            },
          ),
        ),
        _settingRow(
          theme,
          label: t.ttu_vert_kerning,
          hint: t.ttu_vert_kerning_hint,
          child: Switch(
            value: _src.ttuEnableVerticalFontKerning,
            onChanged: (bool v) {
              _src.setTtuEnableVerticalFontKerning(v);
              setState(() {});
              _updateSetting('enableVerticalFontKerning', v);
            },
          ),
        ),
        _settingRow(
          theme,
          label: t.ttu_font_vpal,
          hint: t.ttu_font_vpal_hint,
          child: Switch(
            value: _src.ttuEnableFontVPAL,
            onChanged: (bool v) {
              _src.setTtuEnableFontVPAL(v);
              setState(() {});
              _updateSetting('enableFontVPAL', v);
            },
          ),
        ),
        _settingRow(
          theme,
          label: t.ttu_reader_styles,
          hint: t.ttu_reader_styles_hint,
          child: Switch(
            value: _src.ttuPrioritizeReaderStyles,
            onChanged: (bool v) {
              _src.setTtuPrioritizeReaderStyles(v);
              setState(() {});
              _updateSetting('prioritizeReaderStyles', v);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildLayoutSection(ThemeData theme) {
    final TtuReaderSettings? s = _settings;
    if (s == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _settingRow(
          theme,
          label: t.ttu_writing_direction,
          child: SegmentedButton<String>(
            showSelectedIcon: false,
            segments: <ButtonSegment<String>>[
              ButtonSegment<String>(
                  value: 'horizontal-tb', label: Text(t.ttu_horizontal)),
              ButtonSegment<String>(
                  value: 'vertical-rl', label: Text(t.ttu_vertical)),
            ],
            selected: <String>{s.writingMode},
            onSelectionChanged: (Set<String> sel) {
              s.writingMode = sel.first;
              setState(() {});
              _updateSetting('writingMode', sel.first);
            },
            style: _segmentedStyle(theme),
          ),
        ),
        _settingRow(
          theme,
          label: t.ttu_view_mode_label,
          child: SegmentedButton<String>(
            showSelectedIcon: false,
            segments: <ButtonSegment<String>>[
              ButtonSegment<String>(
                  value: 'paginated', label: Text(t.ttu_paginated)),
              ButtonSegment<String>(
                  value: 'continuous', label: Text(t.ttu_scroll)),
            ],
            selected: <String>{s.viewMode},
            onSelectionChanged: (Set<String> sel) {
              s.viewMode = sel.first;
              setState(() {});
              _updateSetting('viewMode', sel.first);
            },
            style: _segmentedStyle(theme),
          ),
        ),
        _settingRow(
          theme,
          label: t.ttu_vert_text_orient,
          hint: t.ttu_vert_text_orient_hint,
          child: SegmentedButton<String>(
            showSelectedIcon: false,
            segments: <ButtonSegment<String>>[
              ButtonSegment<String>(
                  value: 'mixed', label: Text(t.ttu_orient_mixed)),
              ButtonSegment<String>(
                  value: 'upright', label: Text(t.ttu_orient_upright)),
            ],
            selected: <String>{_src.ttuVerticalTextOrientation},
            onSelectionChanged: (Set<String> sel) {
              _src.setTtuVerticalTextOrientation(sel.first);
              setState(() {});
              _updateSetting('verticalTextOrientation', sel.first);
            },
            style: _segmentedStyle(theme),
          ),
        ),
        const SizedBox(height: 4),
        _settingRow(
          theme,
          label: t.ttu_furigana_mode,
          hint: t.ttu_furigana_mode_hint,
          child: SegmentedButton<String>(
            showSelectedIcon: false,
            segments: <ButtonSegment<String>>[
              ButtonSegment<String>(
                  value: 'show', label: Text(t.ttu_furigana_show)),
              ButtonSegment<String>(
                  value: 'hide', label: Text(t.ttu_furigana_hide)),
              ButtonSegment<String>(
                  value: 'partial', label: Text(t.ttu_furigana_partial)),
              ButtonSegment<String>(
                  value: 'toggle', label: Text(t.ttu_furigana_toggle)),
            ],
            selected: <String>{_src.ttuFuriganaMode},
            onSelectionChanged: (Set<String> sel) {
              if (sel.isEmpty) {
                return;
              }
              final String mode = sel.first;
              _src.setTtuFuriganaMode(mode);
              setState(() {});
              _applyFuriganaMode(mode);
            },
            style: _segmentedStyle(theme),
          ),
        ),
        const SizedBox(height: 8),
        Text(t.ttu_theme, style: theme.textTheme.bodyMedium),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            ...TtuReaderSettings.availableThemes.map((String themeKey) {
              final bool selected = s.theme == themeKey;
              return buildReaderThemeChip(
                context: context,
                label: TtuReaderSettings.themeLabels[themeKey] ?? themeKey,
                selected: selected,
                onSelected: (bool on) async {
                  if (!on) return;
                  s.theme = themeKey;
                  setState(() {});
                  await _updateSetting('theme', themeKey);
                  await widget.appModel.setAppThemeKey(themeKey);
                  await widget.onThemeChanged?.call();
                },
              );
            }),
            buildReaderThemeChip(
              avatar: Icon(
                Icons.palette,
                size: 18,
                color: s.theme == 'custom-theme'
                    ? theme.colorScheme.onPrimaryContainer
                    : null,
              ),
              context: context,
              label: t.custom_theme,
              selected: s.theme == 'custom-theme',
              onSelected: (bool _) {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const CustomThemePage()),
                ).then((_) async {
                  s.theme = widget.appModel.appThemeKey;
                  setState(() {});
                  await _updateSetting('theme', s.theme);
                  await widget.onThemeChanged?.call();
                });
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _settingRow(ThemeData theme,
      {required String label, String? hint, required Widget child}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.textTheme.bodyMedium),
                if (hint != null && hint.isNotEmpty)
                  Text(
                    hint,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          child,
        ],
      ),
    );
  }

  ButtonStyle _segmentedStyle(ThemeData theme) {
    final cs = theme.colorScheme;
    return ButtonStyle(
      visualDensity: VisualDensity.compact,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
        EdgeInsets.symmetric(horizontal: 8),
      ),
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return cs.primaryContainer;
        }
        return null;
      }),
      foregroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return cs.onPrimaryContainer;
        }
        return null;
      }),
    );
  }

  Widget _numberStepper(
    ThemeData theme, {
    required String label,
    required double value,
    required double step,
    required double min,
    required double max,
    required String Function(double) format,
    required ValueChanged<double> onChanged,
  }) {
    return _settingRow(
      theme,
      label: label,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.remove, size: 18),
            visualDensity: VisualDensity.compact,
            onPressed: () {
              final double v = (value - step).clamp(min, max);
              onChanged(v);
            },
          ),
          SizedBox(
            width: 42,
            child: Text(
              format(value),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.add, size: 18),
            visualDensity: VisualDensity.compact,
            onPressed: () {
              final double v = (value + step).clamp(min, max);
              onChanged(v);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildFavoritesSection(BuildContext context, ThemeData theme) {
    final DateFormat fmt = DateFormat('MM/dd HH:mm');
    return Theme(
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        title: Text(
          t.favorites(n: _favorites.length),
          style: theme.textTheme.titleMedium,
        ),
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 300),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _favorites.length,
              itemBuilder: (BuildContext ctx, int i) {
                final FavoriteSentence fav = _favorites[i];
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Container(
                    width: 4,
                    height: 40,
                    decoration: BoxDecoration(
                      color: _highlightColor(fav.color),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  title: Text(
                    fav.text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                  subtitle: Text(
                    '${fav.bookTitle}${fav.chapterLabel != null ? ' · ${fav.chapterLabel}' : ''} · ${fmt.format(fav.createdAt)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (widget.onPlayFavorite != null)
                        IconButton(
                          icon: const Icon(Icons.volume_up, size: 16),
                          onPressed: () async {
                            await widget.onPlayFavorite?.call(fav);
                          },
                          tooltip: t.play,
                        ),
                      if (fav.sectionIndex != null &&
                          widget.onJumpToFavorite != null)
                        IconButton(
                          icon: const Icon(Icons.open_in_new, size: 16),
                          onPressed: () async {
                            Navigator.of(ctx).pop();
                            await widget.onJumpToFavorite?.call(fav);
                          },
                          tooltip: t.jump_to_cue,
                        ),
                      IconButton(
                        icon: const Icon(Icons.copy, size: 16),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: fav.text));
                          Fluttertoast.showToast(msg: t.copy);
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 16),
                        onPressed: () async {
                          await widget.onDeleteFavorite?.call(i);
                          if (mounted) {
                            setState(() {
                              _favorites = List<FavoriteSentence>.of(_favorites)
                                ..removeAt(i);
                            });
                          }
                        },
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
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
        return const Color(0xFFFFDC00);
    }
  }

  Widget _buildActionRow(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [
        _actionBtn(
          context,
          icon: Icons.bookmark_add_outlined,
          label: t.action_bookmark,
          onTap: () async {
            Navigator.of(context).pop();
            await widget.onBookmark();
          },
        ),
        _actionBtn(
          context,
          icon: Icons.exit_to_app,
          label: t.action_exit,
          onTap: () {
            Navigator.of(context).pop();
            widget.onExitReader();
          },
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
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: theme.colorScheme.onSurface),
            const SizedBox(height: 4),
            Text(label, style: theme.textTheme.labelSmall),
          ],
        ),
      ),
    );
  }
}

class _RepeatIconButton extends StatefulWidget {
  const _RepeatIconButton({
    required this.icon,
    required this.onPressed,
    this.initialDelay = const Duration(milliseconds: 400),
    this.repeatInterval = const Duration(milliseconds: 80),
  });

  final Widget icon;
  final VoidCallback onPressed;
  final Duration initialDelay;
  final Duration repeatInterval;

  @override
  State<_RepeatIconButton> createState() => _RepeatIconButtonState();
}

class _RepeatIconButtonState extends State<_RepeatIconButton> {
  Timer? _timer;

  void _start() {
    widget.onPressed();
    _timer = Timer(widget.initialDelay, () {
      _timer = Timer.periodic(widget.repeatInterval, (_) {
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
      child: IconButton(
        icon: widget.icon,
        onPressed: widget.onPressed,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(),
        padding: EdgeInsets.zero,
      ),
    );
  }
}
