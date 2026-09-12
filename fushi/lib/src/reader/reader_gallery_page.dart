/// 插图册页：按章节分组的网格，从 reader_fushi/chrome.part.dart 抽出成独立组件。
/// 页面只负责提供图片列表 / 文件解析 / 揭开写回 / 跳章回调。
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:fushi_engine/epub/epub_book.dart' show EpubImageRef;
import 'package:fushi/src/reader/image_reveal_key.dart';
import 'package:fushi/utils.dart';

class ReaderGalleryPage extends StatefulWidget {
  const ReaderGalleryPage({
    super.key,
    required this.images,
    required this.currentChapter,
    required this.fileForRef,
    required this.onOpenImage,
    required this.onJumpTo,
    this.blurImages = false,
    this.revealedImageKeys = const <String>{},
    this.onRevealImage,
    this.chapterLabelFor,
  });

  final List<EpubImageRef> images;
  final int currentChapter;
  final File? Function(EpubImageRef ref) fileForRef;
  final void Function(EpubImageRef ref) onOpenImage;
  final void Function(EpubImageRef ref) onJumpTo;
  final bool blurImages;
  final Set<String> revealedImageKeys;
  final void Function(String key)? onRevealImage;

  /// 章节节头文案（spine 章号 → 章名，通常来自 TOC）。缺省用「第 N 章」。
  final String Function(int chapterIndex)? chapterLabelFor;

  @override
  State<ReaderGalleryPage> createState() => _ReaderGalleryPageState();
}

/// 一节 = 同一章的（当前过滤视图下）可见插图。
class _GallerySection {
  const _GallerySection({
    required this.chapterIndex,
    required this.images,
    required this.offset,
  });

  final int chapterIndex;
  final List<EpubImageRef> images;

  /// 节头在滚动轴上的起点（逻辑像素）。
  final double offset;
}

/// 解析式布局模型：sliver 网格是惰性构建的，未进视口的卡片没有 RenderObject，
/// 框架的 `ensureVisible` 对它们无效。「打开时定位到当前章」「回到最近已看」
/// 「键盘焦点跟随」三处都要滚到还没构建的位置，所以列数 / 行高 / 每节偏移全由
/// 宽度推出来，网格本身也用同一份列数（`SliverGridDelegateWithFixedCrossAxisCount`），
/// 两边不会漂。
class _GalleryLayout {
  _GalleryLayout({
    required double gridWidth,
    required List<_ChapterGroup> groups,
    required int currentChapter,
  }) : columns = _columnsFor(gridWidth) {
    cellWidth = (gridWidth - (columns - 1) * _kGridSpacing) / columns;
    cellHeight = cellWidth / _kCardAspectRatio;
    // 当前章自己有插图 → 标记画在它的节头上；没有 → 独立标记条插在
    // 第一个「晚于当前章」的节之前（全都早于当前章就压在末尾）。
    final bool needsMarker = groups.isNotEmpty &&
        !groups.any((_ChapterGroup g) => g.chapterIndex == currentChapter);
    double cursor = _kTopPadding;
    int? markerBefore;
    final List<_GallerySection> built = <_GallerySection>[];
    for (final _ChapterGroup group in groups) {
      if (needsMarker &&
          markerBefore == null &&
          group.chapterIndex > currentChapter) {
        markerBefore = built.length;
        markerOffset = cursor;
        cursor += _kMarkerHeight;
      }
      built.add(
        _GallerySection(
          chapterIndex: group.chapterIndex,
          images: group.images,
          offset: cursor,
        ),
      );
      cursor += _kSectionHeaderHeight +
          rowsExtent(group.images.length) +
          _kSectionGap;
    }
    if (needsMarker && markerBefore == null) {
      markerBefore = built.length;
      markerOffset = cursor;
    }
    sections = List<_GallerySection>.unmodifiable(built);
    markerSectionIndex = markerBefore;
  }

  static int _columnsFor(double gridWidth) =>
      math.max(1, (gridWidth / (_kCardMaxExtent + _kGridSpacing)).ceil());

  final int columns;
  late final double cellWidth;
  late final double cellHeight;
  late final List<_GallerySection> sections;

  /// 「当前阅读位置」独立标记条插在第几节之前（当前章没有插图时才有）。
  late final int? markerSectionIndex;
  double? markerOffset;

  double rowsExtent(int count) {
    if (count <= 0) return 0;
    final int rows = (count + columns - 1) ~/ columns;
    return rows * cellHeight + (rows - 1) * _kGridSpacing;
  }

  /// 某节第 [indexInSection] 张卡所在行的顶部偏移。
  double rowOffset(_GallerySection section, int indexInSection) =>
      section.offset +
      _kSectionHeaderHeight +
      (indexInSection ~/ columns) * (cellHeight + _kGridSpacing);
}

class _ChapterGroup {
  const _ChapterGroup(this.chapterIndex, this.images);
  final int chapterIndex;
  final List<EpubImageRef> images;
}

enum _LockedAction { backToLastSeen, revealAnyway }

const double _kCardMaxExtent = 160;
const double _kCardAspectRatio = 0.72;
const double _kGridSpacing = 12;
const double _kPagePadding = 16;
const double _kTopPadding = 8;
const double _kSectionHeaderHeight = 44;
const double _kSectionGap = 16;
const double _kMarkerHeight = 32;

/// 插图册：顶栏「插图册 · 已解锁 n / N · [已解锁 | 全部] · 定位 · ×」；主体按章分组
/// 的网格。卡片两态——已解锁显示缩略图，未解锁是纸质占位卡（尚未读到 / 读到第 X 章
/// 后自动解锁），点占位卡弹出「回到最近已看 / 仍要查看」。解锁判据与阅读器正文、
/// 书架端插图库同源：[ImageRevealKey.shouldBlur]（已揭开 ∪ 已读到 = 解锁）。
/// 点已解锁卡进页内全屏单图查看器（←/→ 切图、滚轮、Esc 关；点图交给 [onOpenImage]
/// 的既有缩放查看器，不造第二条缩放路径）。打开时自动滚到当前阅读章那一节。
class _ReaderGalleryPageState extends State<ReaderGalleryPage> {
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode(debugLabel: 'reader-gallery');
  final Set<String> _revealedHere = <String>{};

  bool _unlockedOnly = false;

  /// 键盘焦点落在哪张卡（按 src 记，过滤切换后下标会变、src 不变）。
  String? _focusedSrc;

  /// 全屏单图查看器当前在解锁列表里的下标；null = 查看器关着。
  int? _viewerIndex;

  _GalleryLayout? _layout;

  // ── 判据 ─────────────────────────────────────────────────────────────

  bool _unreadAhead(EpubImageRef ref) =>
      ref.chapterIndex > widget.currentChapter;

  bool _isLocked(EpubImageRef ref) => ImageRevealKey.shouldBlur(
        blurEnabled: widget.blurImages,
        revealKey: ImageRevealKey.normalize(ref.src),
        revealed: <String>{...widget.revealedImageKeys, ..._revealedHere},
        unreadAhead: _unreadAhead(ref),
      );

  List<EpubImageRef> get _unlocked => widget.images
      .where((EpubImageRef r) => !_isLocked(r))
      .toList(growable: false);

  List<EpubImageRef> get _visible => _unlockedOnly ? _unlocked : widget.images;

  List<_ChapterGroup> _groupsOf(List<EpubImageRef> refs) {
    final List<_ChapterGroup> groups = <_ChapterGroup>[];
    for (final EpubImageRef ref in refs) {
      if (groups.isNotEmpty && groups.last.chapterIndex == ref.chapterIndex) {
        groups.last.images.add(ref);
      } else {
        groups.add(_ChapterGroup(ref.chapterIndex, <EpubImageRef>[ref]));
      }
    }
    return groups;
  }

  String _chapterLabel(int chapterIndex) =>
      widget.chapterLabelFor?.call(chapterIndex) ??
      t.auto_chapter(n: chapterIndex + 1);

  // ── 生命周期 ─────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _scrollToCurrentPosition(animate: false);
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // ── 滚动 ─────────────────────────────────────────────────────────────

  void _scrollTo(double offset, {required bool animate}) {
    if (!_scrollController.hasClients) return;
    final double target = offset.clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );
    if (animate) {
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    } else {
      _scrollController.jumpTo(target);
    }
  }

  /// 当前阅读位置在滚动轴上的偏移：当前章那一节的节头；当前章没插图就是标记条。
  double? _currentPositionOffset() {
    final _GalleryLayout? layout = _layout;
    if (layout == null) return null;
    for (final _GallerySection section in layout.sections) {
      if (section.chapterIndex == widget.currentChapter) return section.offset;
    }
    return layout.markerOffset;
  }

  void _scrollToCurrentPosition({required bool animate}) {
    final double? offset = _currentPositionOffset();
    if (offset == null) return;
    _scrollTo(offset, animate: animate);
  }

  /// 卡片的行不在视口里时滚到让它可见（上下各留一格间距）。
  void _ensureCardVisible(EpubImageRef ref) {
    final _GalleryLayout? layout = _layout;
    if (layout == null || !_scrollController.hasClients) return;
    for (final _GallerySection section in layout.sections) {
      final int i = section.images.indexOf(ref);
      if (i < 0) continue;
      final double top = layout.rowOffset(section, i);
      final double bottom = top + layout.cellHeight;
      final ScrollPosition position = _scrollController.position;
      final double viewTop = position.pixels;
      final double viewBottom = viewTop + position.viewportDimension;
      if (top - _kGridSpacing < viewTop) {
        _scrollTo(top - _kGridSpacing, animate: true);
      } else if (bottom + _kGridSpacing > viewBottom) {
        _scrollTo(
          bottom + _kGridSpacing - position.viewportDimension,
          animate: true,
        );
      }
      return;
    }
  }

  /// 「回到最近已看」：聚焦并滚到阅读顺序上最后一张已解锁的图；一张都没有就回顶部。
  void _backToLastSeen() {
    final List<EpubImageRef> unlocked = _unlocked;
    if (unlocked.isEmpty) {
      _scrollTo(0, animate: true);
      return;
    }
    final EpubImageRef last = unlocked.last;
    setState(() => _focusedSrc = last.src);
    _ensureCardVisible(last);
  }

  // ── 动作 ─────────────────────────────────────────────────────────────

  void _reveal(EpubImageRef ref) {
    final String? key = ImageRevealKey.normalize(ref.src);
    if (key == null) return;
    setState(() => _revealedHere.add(key));
    widget.onRevealImage?.call(key);
  }

  void _activate(EpubImageRef ref) {
    setState(() => _focusedSrc = ref.src);
    if (_isLocked(ref)) {
      unawaited(_showLockedDialog(ref));
      return;
    }
    _openViewer(ref);
  }

  Future<void> _showLockedDialog(EpubImageRef ref) async {
    final _LockedAction? action = await showDialog<_LockedAction>(
      context: context,
      builder: (BuildContext dialogContext) =>
          _LockedIllustrationDialog(hint: _lockedHint(ref)),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _LockedAction.backToLastSeen:
        _backToLastSeen();
      case _LockedAction.revealAnyway:
        _reveal(ref);
    }
  }

  String _lockedHint(EpubImageRef ref) => _unreadAhead(ref)
      ? t.reader_gallery_locked_unlock_hint(
          chapter: _chapterLabel(ref.chapterIndex),
        )
      : t.reader_gallery_locked_blur_hint;

  void _openViewer(EpubImageRef ref) {
    final int index = _unlocked.indexOf(ref);
    if (index < 0) return;
    setState(() => _viewerIndex = index);
    _precacheNeighbours(index);
  }

  void _closeViewer() => setState(() => _viewerIndex = null);

  void _viewerStep(int delta) {
    final int? current = _viewerIndex;
    if (current == null) return;
    final List<EpubImageRef> unlocked = _unlocked;
    final int next = (current + delta).clamp(0, unlocked.length - 1);
    if (next == current) return;
    setState(() {
      _viewerIndex = next;
      _focusedSrc = unlocked[next].src;
    });
    _precacheNeighbours(next);
  }

  /// 预解码相邻两张（前 / 后），箭头 / 滚轮连续切图时不闪白。
  void _precacheNeighbours(int index) {
    final List<EpubImageRef> unlocked = _unlocked;
    for (final int i in <int>[index - 1, index + 1]) {
      if (i < 0 || i >= unlocked.length) continue;
      final File? file = widget.fileForRef(unlocked[i]);
      if (file == null) continue;
      unawaited(
        precacheImage(FileImage(file), context).catchError((Object _) {}),
      );
    }
  }

  // ── 键盘 / 滚轮 ─────────────────────────────────────────────────────

  /// 网格内移动焦点：←/→ 沿阅读顺序 ±1；↑/↓ 同节内 ±列数，越过节边界时落到
  /// 相邻节同一列（末行不满时夹到最后一张）。
  void _moveFocus(int dx, int dy) {
    final _GalleryLayout? layout = _layout;
    final List<EpubImageRef> visible = _visible;
    if (layout == null || visible.isEmpty) return;
    final int current = visible.indexWhere(
      (EpubImageRef r) => r.src == _focusedSrc,
    );
    int next;
    if (current < 0) {
      next = 0;
    } else if (dx != 0) {
      next = (current + dx).clamp(0, visible.length - 1);
    } else {
      next = _verticalNeighbour(layout, current, dy);
    }
    final EpubImageRef target = visible[next];
    setState(() => _focusedSrc = target.src);
    _ensureCardVisible(target);
  }

  int _verticalNeighbour(_GalleryLayout layout, int flatIndex, int dy) {
    final List<_GallerySection> sections = layout.sections;
    int base = 0;
    for (int s = 0; s < sections.length; s++) {
      final int len = sections[s].images.length;
      if (flatIndex >= base + len) {
        base += len;
        continue;
      }
      final int j = flatIndex - base;
      final int cols = layout.columns;
      final int inSection = j + dy * cols;
      if (inSection >= 0 && inSection < len) return base + inSection;
      if (dy < 0) {
        if (s == 0) return flatIndex;
        final int prevLen = sections[s - 1].images.length;
        final int lastRowStart = ((prevLen - 1) ~/ cols) * cols;
        return base - prevLen + math.min(prevLen - 1, lastRowStart + j % cols);
      }
      if (s == sections.length - 1) return flatIndex;
      final int nextLen = sections[s + 1].images.length;
      return base + len + math.min(nextLen - 1, j % cols);
    }
    return flatIndex;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final LogicalKeyboardKey key = event.logicalKey;
    if (_viewerIndex != null) return _onViewerKey(key);
    if (key == LogicalKeyboardKey.arrowLeft) {
      _moveFocus(-1, 0);
    } else if (key == LogicalKeyboardKey.arrowRight) {
      _moveFocus(1, 0);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      _moveFocus(0, -1);
    } else if (key == LogicalKeyboardKey.arrowDown) {
      _moveFocus(0, 1);
    } else if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      final EpubImageRef? focused = _focusedRef();
      if (focused != null) _activate(focused);
    } else if (key == LogicalKeyboardKey.escape) {
      Navigator.of(context).maybePop();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  KeyEventResult _onViewerKey(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.arrowLeft) {
      _viewerStep(-1);
    } else if (key == LogicalKeyboardKey.arrowRight) {
      _viewerStep(1);
    } else if (key == LogicalKeyboardKey.home) {
      _viewerStep(-_unlocked.length);
    } else if (key == LogicalKeyboardKey.end) {
      _viewerStep(_unlocked.length);
    } else if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      final EpubImageRef? current = _viewerRef();
      if (current != null) widget.onOpenImage(current);
    } else if (key == LogicalKeyboardKey.escape) {
      _closeViewer();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  EpubImageRef? _focusedRef() {
    for (final EpubImageRef ref in _visible) {
      if (ref.src == _focusedSrc) return ref;
    }
    return null;
  }

  EpubImageRef? _viewerRef() {
    final int? index = _viewerIndex;
    if (index == null) return null;
    final List<EpubImageRef> unlocked = _unlocked;
    if (index < 0 || index >= unlocked.length) return null;
    return unlocked[index];
  }

  /// 查看器里鼠标滚轮：向下 / 向右 = 下一张。
  void _onViewerPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final double delta =
        event.scrollDelta.dy != 0 ? event.scrollDelta.dy : event.scrollDelta.dx;
    if (delta == 0) return;
    _viewerStep(delta > 0 ? 1 : -1);
  }

  // ── 构建 ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<EpubImageRef> unlocked = _unlocked;
    final EpubImageRef? viewerRef = _viewerRef();
    return Scaffold(
      backgroundColor: tokens.surfaces.page,
      body: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Stack(
          children: <Widget>[
            Column(
              children: <Widget>[
                _buildHeader(tokens, unlocked.length),
                Expanded(child: _buildBody(tokens)),
              ],
            ),
            if (viewerRef != null)
              Positioned.fill(
                child: _buildViewer(tokens, viewerRef, unlocked.length),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(FushiDesignTokens tokens, int unlockedCount) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 8, 4),
      child: Row(
        children: <Widget>[
          // 标题 + 计数让位给右侧控件：窄窗先截计数，不让整行溢出。
          Expanded(
            child: Row(
              children: <Widget>[
                Text(
                  t.reader_gallery_title,
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    t.reader_gallery_unlocked_count(
                      unlocked: unlockedCount,
                      total: widget.images.length,
                    ),
                    key: const ValueKey<String>('fushi_gallery_count'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tokens.type.metadata,
                  ),
                ),
              ],
            ),
          ),
          if (widget.images.isNotEmpty) ...<Widget>[
            SegmentedButton<bool>(
              key: const ValueKey<String>('fushi_gallery_filter'),
              showSelectedIcon: false,
              segments: <ButtonSegment<bool>>[
                ButtonSegment<bool>(
                  value: true,
                  label: Text(t.reader_gallery_filter_unlocked),
                ),
                ButtonSegment<bool>(
                  value: false,
                  label: Text(t.reader_gallery_filter_all),
                ),
              ],
              selected: <bool>{_unlockedOnly},
              onSelectionChanged: (Set<bool> selection) {
                setState(() => _unlockedOnly = selection.single);
              },
            ),
            const SizedBox(width: 8),
            IconButton(
              key: const ValueKey<String>('fushi_gallery_position'),
              tooltip: t.reader_gallery_position_jump,
              icon: const Icon(Icons.my_location_outlined),
              onPressed: () => _scrollToCurrentPosition(animate: true),
            ),
          ],
          Semantics(
            identifier: 'hibiki.reader.gallery.close',
            child: IconButton(
              key: const ValueKey<String>('fushi_gallery_close'),
              tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(FushiDesignTokens tokens) {
    final ThemeData theme = Theme.of(context);
    if (widget.images.isEmpty) {
      _layout = null;
      return Center(
        child: Text(t.reader_gallery_empty, style: theme.textTheme.bodyLarge),
      );
    }
    final List<EpubImageRef> visible = _visible;
    if (visible.isEmpty) {
      _layout = null;
      return Center(
        child: Text(
          t.reader_gallery_unlocked_empty,
          style: theme.textTheme.bodyLarge,
        ),
      );
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final _GalleryLayout layout = _GalleryLayout(
          gridWidth: math.max(1, constraints.maxWidth - _kPagePadding * 2),
          groups: _groupsOf(visible),
          currentChapter: widget.currentChapter,
        );
        _layout = layout;
        return Scrollbar(
          controller: _scrollController,
          child: CustomScrollView(
            controller: _scrollController,
            slivers: <Widget>[
              const SliverToBoxAdapter(child: SizedBox(height: _kTopPadding)),
              for (int s = 0; s < layout.sections.length; s++) ...<Widget>[
                if (layout.markerSectionIndex == s)
                  _buildPositionMarker(tokens),
                _buildSectionHeader(tokens, layout.sections[s]),
                _buildSectionGrid(tokens, layout, layout.sections[s]),
                const SliverToBoxAdapter(child: SizedBox(height: _kSectionGap)),
              ],
              if (layout.markerSectionIndex == layout.sections.length)
                _buildPositionMarker(tokens),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPositionMarker(FushiDesignTokens tokens) {
    return SliverToBoxAdapter(
      child: SizedBox(
        height: _kMarkerHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: _kPagePadding),
          child: Row(
            children: <Widget>[
              _PositionBadge(tokens: tokens),
              const SizedBox(width: 8),
              Expanded(
                child: Divider(color: tokens.surfaces.primary, thickness: 1),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(
    FushiDesignTokens tokens,
    _GallerySection section,
  ) {
    final ThemeData theme = Theme.of(context);
    final bool current = section.chapterIndex == widget.currentChapter;
    return SliverToBoxAdapter(
      key: ValueKey<String>('fushi_gallery_section_${section.chapterIndex}'),
      child: SizedBox(
        height: _kSectionHeaderHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: _kPagePadding),
          child: Row(
            children: <Widget>[
              Flexible(
                child: Text(
                  _chapterLabel(section.chapterIndex).toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    letterSpacing: 1.2,
                    color: current
                        ? tokens.surfaces.primary
                        : tokens.surfaces.onVariant,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Divider(
                  color: current
                      ? tokens.surfaces.primary
                      : tokens.surfaces.outline,
                  thickness: 1,
                ),
              ),
              if (current) ...<Widget>[
                const SizedBox(width: 8),
                _PositionBadge(tokens: tokens),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionGrid(
    FushiDesignTokens tokens,
    _GalleryLayout layout,
    _GallerySection section,
  ) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: _kPagePadding),
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: layout.columns,
          mainAxisSpacing: _kGridSpacing,
          crossAxisSpacing: _kGridSpacing,
          childAspectRatio: _kCardAspectRatio,
        ),
        delegate: SliverChildBuilderDelegate(
          (BuildContext context, int index) =>
              _buildCard(tokens, section.images[index]),
          childCount: section.images.length,
        ),
      ),
    );
  }

  Widget _buildCard(FushiDesignTokens tokens, EpubImageRef ref) {
    final bool locked = _isLocked(ref);
    final bool focused = ref.src == _focusedSrc;
    final Widget content = locked
        ? _LockedCardBody(hint: _lockedHint(ref), tokens: tokens)
        : _thumbnail(tokens, ref);
    return _GalleryCard(
      key: ValueKey<String>('fushi_gallery_card_${ref.src}'),
      tokens: tokens,
      focused: focused,
      paper: locked,
      onTap: () => _activate(ref),
      child: content,
    );
  }

  Widget _thumbnail(FushiDesignTokens tokens, EpubImageRef ref) {
    final File? file = widget.fileForRef(ref);
    if (file == null) {
      return Center(
        child: Icon(
          Icons.broken_image_outlined,
          size: 24,
          color: tokens.surfaces.onVariant,
        ),
      );
    }
    return Image.file(file, fit: BoxFit.cover, gaplessPlayback: true);
  }

  Widget _buildViewer(
    FushiDesignTokens tokens,
    EpubImageRef current,
    int unlockedCount,
  ) {
    final ThemeData theme = Theme.of(context);
    final int index = _viewerIndex ?? 0;
    final File? file = widget.fileForRef(current);
    final Widget image = file == null
        ? Icon(
            Icons.broken_image_outlined,
            size: 64,
            color: tokens.surfaces.onVariant,
          )
        : Image.file(
            file,
            key: ValueKey<String>('fushi_gallery_stage_${current.src}'),
            fit: BoxFit.contain,
            gaplessPlayback: true,
          );
    return ColoredBox(
      key: const ValueKey<String>('fushi_gallery_viewer'),
      color: tokens.surfaces.page,
      child: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 8, 4),
            child: Row(
              children: <Widget>[
                Text(
                  '${index + 1} / $unlockedCount',
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    _chapterLabel(current.chapterIndex),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tokens.type.metadata,
                  ),
                ),
                const Spacer(),
                IconButton(
                  key: const ValueKey<String>('fushi_gallery_jump'),
                  tooltip: t.reader_gallery_jump,
                  icon: const Icon(Icons.my_location_outlined),
                  onPressed: () => widget.onJumpTo(current),
                ),
                IconButton(
                  key: const ValueKey<String>('fushi_gallery_viewer_close'),
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  icon: const Icon(Icons.close),
                  onPressed: _closeViewer,
                ),
              ],
            ),
          ),
          Expanded(
            child: Stack(
              children: <Widget>[
                Positioned.fill(
                  child: Listener(
                    onPointerSignal: _onViewerPointerSignal,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 72,
                        vertical: 8,
                      ),
                      child: GestureDetector(
                        onTap: () => widget.onOpenImage(current),
                        child: Center(child: image),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 16,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: _arrowButton(
                      tokens,
                      icon: Icons.chevron_left,
                      enabled: index > 0,
                      onPressed: () => _viewerStep(-1),
                    ),
                  ),
                ),
                Positioned(
                  right: 16,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: _arrowButton(
                      tokens,
                      icon: Icons.chevron_right,
                      enabled: index < unlockedCount - 1,
                      onPressed: () => _viewerStep(1),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _arrowButton(
    FushiDesignTokens tokens, {
    required IconData icon,
    required bool enabled,
    required VoidCallback onPressed,
  }) {
    return Material(
      color: tokens.surfaces.overlay.withValues(alpha: 0.8),
      shape: const CircleBorder(),
      child: IconButton(
        icon: Icon(icon),
        iconSize: 24,
        color: tokens.surfaces.onSurface,
        onPressed: enabled ? onPressed : null,
      ),
    );
  }
}

/// 「当前阅读位置」徽标：竖线 + 小号标签。节头里当前章带它；当前章没插图时
/// 它独占一条标记行插在前后章之间。
class _PositionBadge extends StatelessWidget {
  const _PositionBadge({required this.tokens});

  final FushiDesignTokens tokens;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 2,
          height: 14,
          decoration: ShapeDecoration(
            color: tokens.surfaces.primary,
            shape: const StadiumBorder(),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          t.reader_gallery_position_current,
          style: theme.textTheme.labelSmall?.copyWith(
            color: tokens.surfaces.primary,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

/// 网格卡片外壳：圆角 + 细边框，键盘焦点用 2px 主色描边。[paper] 是占位卡的
/// 纸质底（低一档的分组色），缩略图卡用卡片色。
class _GalleryCard extends StatelessWidget {
  const _GalleryCard({
    super.key,
    required this.tokens,
    required this.focused,
    required this.paper,
    required this.onTap,
    required this.child,
  });

  final FushiDesignTokens tokens;
  final bool focused;
  final bool paper;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final BorderRadius radius = tokens.radii.cardRadius;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      decoration: ShapeDecoration(
        color: paper ? tokens.surfaces.group : tokens.surfaces.card,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(
            color: focused ? tokens.surfaces.primary : tokens.surfaces.outline,
            width: focused ? 2 : 1,
          ),
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        shape: RoundedRectangleBorder(borderRadius: radius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(onTap: onTap, child: child),
      ),
    );
  }
}

/// 占位卡正文：书本图标 + 「尚未读到」+ 解锁提示。
class _LockedCardBody extends StatelessWidget {
  const _LockedCardBody({required this.hint, required this.tokens});

  final String hint;
  final FushiDesignTokens tokens;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(
            Icons.auto_stories_outlined,
            size: 28,
            color: tokens.surfaces.onVariant,
          ),
          const SizedBox(height: 10),
          Text(
            t.reader_gallery_locked_title,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelMedium?.copyWith(
              color: tokens.surfaces.onSurface,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            hint,
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: tokens.surfaces.onVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 点占位卡弹出的两个动作：「回到最近已看」/「仍要查看」。
class _LockedIllustrationDialog extends StatelessWidget {
  const _LockedIllustrationDialog({required this.hint});

  final String hint;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiDialogFrame(
      maxWidth: 360,
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.auto_stories_outlined,
            size: 40,
            color: tokens.surfaces.onVariant,
          ),
          const SizedBox(height: 16),
          Text(
            t.reader_gallery_locked_title,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            hint,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: tokens.surfaces.onVariant,
            ),
          ),
          const SizedBox(height: 24),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              TextButton(
                key: const ValueKey<String>('fushi_gallery_locked_reveal'),
                onPressed: () =>
                    Navigator.of(context).pop(_LockedAction.revealAnyway),
                child: Text(t.reader_gallery_locked_reveal),
              ),
              FilledButton.tonal(
                key: const ValueKey<String>('fushi_gallery_locked_back'),
                onPressed: () =>
                    Navigator.of(context).pop(_LockedAction.backToLastSeen),
                child: Text(t.reader_gallery_locked_back),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
