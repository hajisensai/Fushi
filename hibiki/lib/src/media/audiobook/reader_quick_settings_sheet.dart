import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:intl/intl.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:hibiki/src/epub/epub_book.dart';
import 'package:hibiki/src/media/audiobook/audiobook_bridge.dart';
import 'package:hibiki/src/media/audiobook/audiobook_play_bar.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/book_css_editor_page.dart';
import 'package:hibiki/src/pages/implementations/custom_theme_page.dart';
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
    this.onSearchJump,
    this.onJumpToCharOffset,
    this.charProgress,
    this.onPageMarginChanged,
    this.isHibikiReader = false,
    this.epubBook,
    this.onStyleChanged,
    this.lyricsMode = false,
    this.onToggleLyricsMode,
    this.extractDir,
    this.onReloadChapter,
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

  final String? extractDir;
  final Future<void> Function()? onReloadChapter;
  final VoidCallback? onAudioImport;

  @override
  State<ReaderQuickSettingsSheet> createState() =>
      _ReaderQuickSettingsSheetState();
}

class _ReaderQuickSettingsSheetState extends State<ReaderQuickSettingsSheet> {
  ReaderHibikiSource get _src => ReaderHibikiSource.instance;

  TtuReaderSettings? _settings;

  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _charJumpController = TextEditingController();
  List<BookSearchResult> _searchResults = const [];
  String _searchResultsQuery = '';
  int _searchGeneration = 0;
  bool _isSearching = false;
  bool _layoutReloading = false;

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
    if (widget.isHibikiReader) {
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

  Future<void> _applyFuriganaMode(String mode) async {
    if (widget.isHibikiReader) {
      await _src.setTtuFuriganaMode(mode);
      await widget.onStyleChanged?.call();
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
      onPopInvokedWithResult: (didPop, _) {
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
    final List<Widget> navigationRows = [
      _categoryTile(
        icon: Icons.palette_outlined,
        label: t.settings_destination_appearance,
        page: 'appearance',
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
        icon: Icons.menu_book_outlined,
        label: t.section_navigation,
        page: 'location',
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
        const SizedBox(height: 12),
        AdaptiveSettingsSection(children: navigationRows),
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
      case 'appearance':
        title = t.settings_destination_appearance;
        content = _buildAppearanceSettingsSection(theme);
      case 'layout':
        title = t.section_layout;
        content = _buildLayoutSettingsSection(theme);
      case 'behavior':
        title = t.settings_destination_reading_controls;
        content = _buildBehaviorSettingsSection();
      case 'location':
        title = t.section_navigation;
        content = _buildLocationSection(theme);
      case 'audiobook':
        title = t.section_audiobook;
        content = _buildAudiobookSettingsSection(theme);
      default:
        title = '';
        content = const SizedBox.shrink();
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _InBookSettingsHeader(
          title: title,
          onBack: () => setState(() => _subPage = null),
        ),
        const SizedBox(height: 12),
        content,
      ],
    );
  }

  Widget _buildLocationSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.epubBook != null && widget.onSearchJump != null)
          _buildSearchSection(theme),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(t.book_search, style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: HibikiTextField(
                controller: _searchController,
                hintText: t.book_search_hint,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                style: theme.textTheme.bodyMedium,
                onSubmitted: (_) => _doSearch(),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 40,
              child: FilledButton.tonal(
                onPressed: _isSearching ? null : _doSearch,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  visualDensity: VisualDensity.compact,
                ),
                child: _isSearching
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child:
                            adaptiveIndicator(context: context, strokeWidth: 2),
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
          const SizedBox(height: 8),
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
              child: HibikiTextField(
                controller: _charJumpController,
                keyboardType: TextInputType.number,
                hintText: t.jump_to_char_hint,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
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
    return AdaptiveSettingsSliderRow(
      title: t.audio_volume,
      icon: Icons.volume_up_outlined,
      value: ctrl.volume,
      max: 2,
      onChanged: (v) {
        ctrl.setVolume(v);
        setState(() {});
      },
    );
  }

  Widget _buildSpeedSection(AudiobookPlayerController ctrl) {
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) {
        final double current = ctrl.speed;
        return AdaptiveSettingsRow(
          title: '${t.playback_speed} (${current.toStringAsFixed(2)}x)',
          icon: Icons.speed_outlined,
          controlBelow: true,
          trailing: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              adaptiveSlider(
                context: context,
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
                child: IconButton(
                  icon: const Icon(Icons.restart_alt_outlined, size: 18),
                  onPressed: (current - 1.0).abs() < 0.001
                      ? null
                      : () => ctrl.setSpeed(1),
                  visualDensity: VisualDensity.compact,
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
          ),
        );
      },
    );
  }

  static const List<int> _imagePauseOptions = [0, 5, 10, 15];

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

  Widget _buildBehaviorSettingsSection() {
    return AdaptiveSettingsSection(
      children: _buildReaderSwitches(),
    );
  }

  List<Widget> _buildReaderSwitches() {
    Widget sw(String label, bool value, VoidCallback toggle) {
      return AdaptiveSettingsSwitchRow(
        title: label,
        value: value,
        onChanged: (_) {
          toggle();
          setState(() {});
        },
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
      sw(t.volume_key_sentence_nav, _src.volumeKeySentenceNavEnabled,
          _src.toggleVolumeKeySentenceNavEnabled),
      sw(t.invert_swipe_direction, _src.invertSwipeDirection,
          _src.toggleInvertSwipeDirection),
      sw(t.keep_screen_awake, _src.keepScreenAwake, () async {
        _src.toggleKeepScreenAwake();
        try {
          if (_src.keepScreenAwake) {
            await WakelockPlus.enable();
          } else {
            await WakelockPlus.disable();
          }
        } catch (e) {
          debugPrint('[Hibiki] wakelock toggle failed: $e');
        }
      }),
      sw(t.auto_read_on_lookup, _src.autoReadOnLookup,
          _src.toggleAutoReadOnLookup),
      sw(t.pause_on_lookup, _src.pauseOnLookup, () async {
        await _src.setPauseOnLookup(value: !_src.pauseOnLookup);
        setState(() {});
      }),
      AdaptiveSettingsSliderRow(
        title: t.dismiss_swipe_sensitivity,
        value: _src.dismissSwipeSensitivity,
        min: 0.1,
        divisions: 9,
        label: _src.dismissSwipeSensitivity.toStringAsFixed(1),
        onChanged: (v) {
          _src.setDismissSwipeSensitivity(v);
          setState(() {});
        },
      ),
      AdaptiveSettingsSliderRow(
        title: t.volume_button_turning_speed,
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
    ];
  }

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
      ],
    );
  }

  Widget _buildSettingsLoading() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: SizedBox(
          width: 20,
          height: 20,
          child: adaptiveIndicator(context: context, strokeWidth: 2),
        ),
      ),
    );
  }

  Widget _buildAudiobookSettingsSection(ThemeData theme) {
    if (widget.controller == null) {
      return _buildPlayBarToggle();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AdaptiveSettingsSection(
          children: [
            _buildVolumeSection(widget.controller!),
            _buildSpeedSection(widget.controller!),
            _buildDelaySection(theme, widget.controller!),
            _buildImagePauseSection(widget.controller!),
          ],
        ),
        _buildPlayBarToggle(),
        if (widget.onAudioImport != null)
          AdaptiveSettingsSection(
            children: [
              AdaptiveSettingsNavigationRow(
                title: t.srt_book_replace_audio,
                icon: Icons.swap_horiz_outlined,
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

  Widget _buildAppearanceSettingsSection(ThemeData theme) {
    final TtuReaderSettings? s = _settings;
    if (s == null) {
      return _buildSettingsLoading();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AdaptiveSettingsSection(
          children: [
            AdaptiveSettingsRow(
              title: t.ttu_theme,
              controlBelow: true,
              trailing: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  ...TtuReaderSettings.availableThemes.map((themeKey) {
                    final bool selected = s.theme == themeKey;
                    return buildReaderThemeChip(
                      context: context,
                      label:
                          TtuReaderSettings.themeLabels[themeKey] ?? themeKey,
                      selected: selected,
                      onSelected: (bool on) async {
                        if (!on) return;
                        s.theme = themeKey;
                        setState(() {});
                        await widget.appModel.setAppThemeKey(themeKey);
                        await _updateSetting('theme', themeKey);
                        await widget.onThemeChanged?.call();
                      },
                    );
                  }),
                  buildReaderThemeChip(
                    avatar: Icon(
                      Icons.palette_outlined,
                      size: 18,
                      color: s.theme == 'custom-theme'
                          ? theme.colorScheme.onPrimaryContainer
                          : null,
                    ),
                    context: context,
                    label: t.custom_theme,
                    selected: s.theme == 'custom-theme',
                    onSelected: (_) {
                      Navigator.push(
                        context,
                        adaptivePageRoute(
                          builder: (_) => const CustomThemePage(),
                        ),
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
            ),
          ],
        ),
        AdaptiveSettingsSection(
          children: [
            AdaptiveSettingsStepperRow(
              title: t.ttu_font_size,
              value: s.fontSize,
              step: 1,
              min: 8,
              max: 64,
              format: (double value) => '${value.round()}',
              onChanged: (double value) {
                s.fontSize = value;
                setState(() {});
                _updateSetting('fontSize', value);
              },
            ),
            AdaptiveSettingsStepperRow(
              title: t.ttu_line_height,
              value: s.lineHeight,
              step: 0.1,
              min: 1,
              max: 3,
              format: (double value) => value.toStringAsFixed(2),
              onChanged: (double value) {
                s.lineHeight = (value * 100).roundToDouble() / 100;
                setState(() {});
                _updateSetting('lineHeight', s.lineHeight);
              },
            ),
            _numberStepper(
              label: t.ttu_text_indentation,
              value: _src.ttuTextIndentation,
              step: 1,
              min: 0,
              max: 10,
              format: (double v) => '${v.round()}',
              onChanged: (double v) {
                _src.setTtuTextIndentation(v);
                setState(() {});
                _updateSetting('textIndentation', v);
              },
            ),
            if (widget.extractDir != null)
              AdaptiveSettingsNavigationRow(
                title: t.book_css_editor_edit_css,
                icon: Icons.code_outlined,
                onTap: () async {
                  await Navigator.push(
                    context,
                    adaptivePageRoute(
                      builder: (_) =>
                          BookCssEditorPage(extractDir: widget.extractDir!),
                    ),
                  );
                  await _reloadLayoutLive();
                },
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildLayoutSettingsSection(ThemeData theme) {
    final TtuReaderSettings? s = _settings;
    if (s == null) {
      return _buildSettingsLoading();
    }
    if (widget.lyricsMode) return _buildLyricsDisplaySection();
    final bool isVertical = s.writingMode.startsWith('vertical');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AdaptiveSettingsSection(
          children: [
            AdaptiveSettingsSegmentedRow<String>(
              title: t.spread_mode,
              segments: <ButtonSegment<String>>[
                ButtonSegment<String>(
                  value: 'off',
                  label: Text(t.spread_off),
                  tooltip: t.spread_off,
                ),
                ButtonSegment<String>(
                  value: 'on',
                  label: Text(t.spread_on),
                  tooltip: t.spread_on,
                ),
                ButtonSegment<String>(
                  value: 'auto',
                  label: Text(t.spread_auto),
                  tooltip: t.spread_auto,
                ),
              ],
              selected: _src.ttuSpreadMode,
              onChanged: (String value) {
                _src.setTtuSpreadMode(value);
                setState(() {});
                _updateSetting('spreadMode', value);
              },
            ),
            if (_src.ttuSpreadMode != 'off')
              AdaptiveSettingsSegmentedRow<String>(
                title: t.spread_direction,
                segments: const <ButtonSegment<String>>[
                  ButtonSegment<String>(
                    value: 'rtl',
                    label: Text('RTL'),
                    tooltip: 'Right to Left',
                  ),
                  ButtonSegment<String>(
                    value: 'ltr',
                    label: Text('LTR'),
                    tooltip: 'Left to Right',
                  ),
                ],
                selected: _src.ttuSpreadDirection,
                onChanged: (String value) {
                  _src.setTtuSpreadDirection(value);
                  setState(() {});
                  _updateSetting('spreadDirection', value);
                },
              ),
            AdaptiveSettingsSegmentedRow<String>(
              title: t.ttu_writing_direction,
              segments: <ButtonSegment<String>>[
                ButtonSegment<String>(
                  value: 'horizontal-tb',
                  label: Text(t.ttu_horizontal),
                  tooltip: t.ttu_horizontal,
                ),
                ButtonSegment<String>(
                  value: 'vertical-rl',
                  label: Text(t.ttu_vertical),
                  tooltip: t.ttu_vertical,
                ),
              ],
              selected: s.writingMode,
              onChanged: (String value) {
                s.writingMode = value;
                setState(() {});
                _updateSetting('writingMode', value);
              },
            ),
            AdaptiveSettingsSegmentedRow<String>(
              title: t.ttu_view_mode_label,
              segments: <ButtonSegment<String>>[
                ButtonSegment<String>(
                  value: 'paginated',
                  label: Text(t.ttu_paginated),
                  tooltip: t.ttu_paginated,
                ),
                ButtonSegment<String>(
                  value: 'continuous',
                  label: Text(t.ttu_scroll),
                  tooltip: t.ttu_scroll,
                ),
              ],
              selected: s.viewMode,
              onChanged: (String value) {
                s.viewMode = value;
                setState(() {});
                _updateSetting('viewMode', value);
              },
            ),
            if (isVertical)
              AdaptiveSettingsSegmentedRow<String>(
                title: t.ttu_vert_text_orient,
                subtitle: t.ttu_vert_text_orient_hint,
                segments: <ButtonSegment<String>>[
                  ButtonSegment<String>(
                    value: 'mixed',
                    label: Text(t.ttu_orient_mixed),
                    tooltip: t.ttu_orient_mixed,
                  ),
                  ButtonSegment<String>(
                    value: 'upright',
                    label: Text(t.ttu_orient_upright),
                    tooltip: t.ttu_orient_upright,
                  ),
                ],
                selected: _src.ttuVerticalTextOrientation,
                onChanged: (String value) {
                  _src.setTtuVerticalTextOrientation(value);
                  setState(() {});
                  _updateSetting('verticalTextOrientation', value);
                },
              ),
            AdaptiveSettingsSegmentedRow<String>(
              title: t.ttu_furigana_mode,
              subtitle: t.ttu_furigana_mode_hint,
              controlBelow: true,
              segments: <ButtonSegment<String>>[
                ButtonSegment<String>(
                  value: 'show',
                  label: Text(t.ttu_furigana_show),
                  tooltip: t.ttu_furigana_show,
                ),
                ButtonSegment<String>(
                  value: 'hide',
                  label: Text(t.ttu_furigana_hide),
                  tooltip: t.ttu_furigana_hide,
                ),
                ButtonSegment<String>(
                  value: 'partial',
                  label: Text(t.ttu_furigana_partial),
                  tooltip: t.ttu_furigana_partial,
                ),
                ButtonSegment<String>(
                  value: 'toggle',
                  label: Text(t.ttu_furigana_toggle),
                  tooltip: t.ttu_furigana_toggle,
                ),
              ],
              selected: _src.ttuFuriganaMode,
              onChanged: (String mode) {
                setState(() {});
                _applyFuriganaMode(mode);
              },
            ),
          ],
        ),
        AdaptiveSettingsSection(
          children: [
            _numberStepper(
              label: t.margin_top,
              value: _src.ttuMarginTop,
              step: 1,
              min: -5,
              max: 30,
              format: (double v) => '${v.round()}',
              onChanged: (double v) {
                _src.setTtuMarginTop(v);
                setState(() {});
                _updateSetting('marginTop', v);
              },
            ),
            _numberStepper(
              label: t.margin_bottom,
              value: _src.ttuMarginBottom,
              step: 1,
              min: -5,
              max: 30,
              format: (double v) => '${v.round()}',
              onChanged: (double v) {
                _src.setTtuMarginBottom(v);
                setState(() {});
                _updateSetting('marginBottom', v);
              },
            ),
            _numberStepper(
              label: t.margin_left,
              value: _src.ttuMarginLeft,
              step: 1,
              min: -5,
              max: 30,
              format: (double v) => '${v.round()}',
              onChanged: (double v) {
                _src.setTtuMarginLeft(v);
                setState(() {});
                _updateSetting('marginLeft', v);
              },
            ),
            _numberStepper(
              label: t.margin_right,
              value: _src.ttuMarginRight,
              step: 1,
              min: -5,
              max: 30,
              format: (double v) => '${v.round()}',
              onChanged: (double v) {
                _src.setTtuMarginRight(v);
                setState(() {});
                _updateSetting('marginRight', v);
              },
            ),
            _numberStepper(
              label: t.columns_per_page,
              value: _src.ttuPageColumns.toDouble(),
              step: 1,
              min: 0,
              max: 4,
              format: (double v) =>
                  v.round() == 0 ? t.ttu_page_columns_auto : '${v.round()}',
              onChanged: (double v) {
                _src.setTtuPageColumns(v.round());
                setState(() {});
                _updateSetting('pageColumns', v.round());
              },
            ),
          ],
        ),
        AdaptiveSettingsSection(
          children: [
            AdaptiveSettingsSwitchRow(
              title: t.ttu_text_justify,
              subtitle: t.ttu_text_justify_hint,
              value: _src.ttuEnableTextJustification,
              onChanged: (bool value) {
                _src.setTtuEnableTextJustification(value);
                setState(() {});
                _updateSetting('enableTextJustification', value);
              },
            ),
            if (isVertical)
              AdaptiveSettingsSwitchRow(
                title: t.ttu_vert_kerning,
                subtitle: t.ttu_vert_kerning_hint,
                value: _src.ttuEnableVerticalFontKerning,
                onChanged: (bool value) {
                  _src.setTtuEnableVerticalFontKerning(value);
                  setState(() {});
                  _updateSetting('enableVerticalFontKerning', value);
                },
              ),
            if (isVertical)
              AdaptiveSettingsSwitchRow(
                title: t.ttu_font_vpal,
                subtitle: t.ttu_font_vpal_hint,
                value: _src.ttuEnableFontVPAL,
                onChanged: (bool value) {
                  _src.setTtuEnableFontVPAL(value);
                  setState(() {});
                  _updateSetting('enableFontVPAL', value);
                },
              ),
            AdaptiveSettingsSwitchRow(
              title: t.ttu_reader_styles,
              subtitle: t.ttu_reader_styles_hint,
              value: _src.ttuPrioritizeReaderStyles,
              onChanged: (bool value) {
                _src.setTtuPrioritizeReaderStyles(value);
                setState(() {});
                _updateSetting('prioritizeReaderStyles', value);
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildLyricsDisplaySection() {
    return AdaptiveSettingsSection(
      children: [
        AdaptiveSettingsRow(
          title: t.lyrics_font_size_hint,
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
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [
        if (widget.onToggleLyricsMode != null)
          _actionBtn(
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
          icon: Icons.exit_to_app_outlined,
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
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: tokens.radii.controlRadius,
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

class _InBookSettingsHeader extends StatelessWidget {
  const _InBookSettingsHeader({
    required this.title,
    required this.onBack,
  });

  final String title;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final bool cupertino = isCupertinoPlatform(context);
    final TextStyle? titleStyle = cupertino
        ? CupertinoTheme.of(context)
            .textTheme
            .navTitleTextStyle
            .copyWith(fontSize: 17)
        : Theme.of(context).textTheme.titleMedium;
    final IconData icon =
        cupertino ? CupertinoIcons.chevron_back : Icons.arrow_back;

    return Row(
      children: [
        if (cupertino)
          CupertinoButton(
            padding: EdgeInsets.zero,
            minSize: 36,
            onPressed: onBack,
            child: Icon(icon, size: 22),
          )
        else
          IconButton(
            icon: Icon(icon),
            onPressed: onBack,
            visualDensity: VisualDensity.compact,
          ),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: titleStyle,
          ),
        ),
      ],
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
    final String title = entry.label.isEmpty ? t.untitled_chapter : entry.label;
    final double indent = entry.depth * 16.0;

    if (entry.isHeader) {
      final ThemeData theme = Theme.of(context);
      return Padding(
        padding: EdgeInsetsDirectional.only(
          start: (cupertino ? 16 : 12) + indent,
          top: 12,
          bottom: 4,
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
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            cupertino ? CupertinoIcons.search : Icons.search,
            size: 18,
            color: primary,
          ),
          const SizedBox(width: 10),
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
                const SizedBox(height: 2),
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
          SizedBox(
            width: 4,
            height: 32,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(width: 6),
          if (onPlay != null)
            _InBookIconButton(
              materialIcon: Icons.volume_up_outlined,
              cupertinoIcon: CupertinoIcons.speaker_2,
              tooltip: t.play,
              onPressed: onPlay!,
            ),
          if (onJump != null)
            _InBookIconButton(
              materialIcon: Icons.open_in_new_outlined,
              cupertinoIcon: CupertinoIcons.arrow_up_right_square,
              tooltip: t.jump_to_cue,
              onPressed: onJump!,
            ),
          _InBookIconButton(
            materialIcon: Icons.copy_outlined,
            cupertinoIcon: CupertinoIcons.doc_on_doc,
            tooltip: t.copy,
            onPressed: onCopy,
          ),
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
        minSize: 32,
        onPressed: onPressed,
        child: Semantics(
          button: true,
          label: tooltip,
          child: Icon(cupertinoIcon, size: 18, color: color),
        ),
      );
    }

    return IconButton(
      icon: Icon(materialIcon, size: 18, color: color),
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      padding: EdgeInsets.zero,
      onPressed: onPressed,
    );
  }
}

class _RepeatIconButton extends StatefulWidget {
  const _RepeatIconButton({
    required this.icon,
    required this.onPressed,
    this.initialDelay = const Duration(milliseconds: 500),
    this.repeatInterval = const Duration(milliseconds: 100),
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
