/// 插图册页：按章节分组的网格，从 reader_fushi/chrome.part.dart 抽出成独立组件。
/// 页面只负责提供图片列表 / 文件解析 / 揭开写回 / 跳章回调。
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'package:fushi_engine/epub/epub_book.dart'
    show EpubImageRef, kEpubCoverChapterIndex;
import 'package:fushi/src/focus/fushi_focus_controller.dart' show FushiFocusId;
import 'package:fushi/src/reader/illustration_aspect_probe.dart';
import 'package:fushi/src/reader/illustration_grid_columns.dart';
import 'package:fushi/src/reader/image_reveal_key.dart';
import 'package:fushi/src/reader/masked_illustration_cover.dart';
import 'package:fushi/src/shortcuts/context_menu_trigger.dart';
import 'package:fushi/utils.dart';

/// 某一卷的插图表 + 文件解析（兄弟卷由页面层在 isolate 解析后提供）。
class ReaderGalleryVolumeImages {
  const ReaderGalleryVolumeImages({
    required this.images,
    required this.fileForRef,
  });

  final List<EpubImageRef> images;
  final File? Function(EpubImageRef ref) fileForRef;
}

/// 画廊的同合集卷切换接线（BUG-2521）。看兄弟卷的插图不离开画廊（[imagesOf] 在
/// isolate 解析、按卷缓存）；[onJumpTo] / [onOpenImage] 带卷号：跳转 = 切书 + 跳章，
/// 看大图 = 用该卷文件开查看器。当前卷仍走 [ReaderGalleryPage] 自己的回调。
class ReaderGalleryVolumeSwitch {
  const ReaderGalleryVolumeSwitch({
    required this.labels,
    required this.currentIndex,
    required this.imagesOf,
    required this.onJumpTo,
    required this.onOpenImage,
  });

  final List<String> labels;
  final int currentIndex;
  final Future<ReaderGalleryVolumeImages> Function(int volume) imagesOf;
  final void Function(int volume, EpubImageRef ref) onJumpTo;
  final void Function(int volume, EpubImageRef ref, File file) onOpenImage;
}

class ReaderGalleryPage extends StatefulWidget {
  const ReaderGalleryPage({
    super.key,
    required this.images,
    required this.currentChapter,
    this.currentNormCharOffset = 0,
    required this.fileForRef,
    required this.onOpenImage,
    required this.onJumpTo,
    this.blurImages = false,
    this.revealedImageKeys = const <String>{},
    this.onRevealImage,
    this.onUnrevealImage,
    this.chapterLabelFor,
    this.volumeSwitch,
  });

  final List<EpubImageRef> images;

  /// 当前阅读到的 spine 章号。null = 这本书没有阅读位置（书架端打开一本从没
  /// 读过的书）：不出「当前阅读位置」标记与定位按钮，也不按进度遮「还没读到」
  /// ——退化成 (0, 0) 会把开篇之后每一张都判成未读、整个画廊糊成一片，而用户
  /// 没有任何开关能关掉它。总开关 [blurImages] 照常生效。
  final int? currentChapter;

  /// 当前阅读位置在 [currentChapter] 内的归一偏移（0~10000，与落库的
  /// `ReaderPosition.normCharOffset` 同基准）。与 [currentChapter] 一起构成
  /// 「读到哪了」，见 `_unreadAhead`。
  final int currentNormCharOffset;
  final File? Function(EpubImageRef ref) fileForRef;
  final void Function(EpubImageRef ref) onOpenImage;
  final void Function(EpubImageRef ref) onJumpTo;
  final bool blurImages;
  final Set<String> revealedImageKeys;
  final void Function(String key)? onRevealImage;

  /// 撤销揭开（长按卡片「恢复遮罩」）。宿主据此从会话集 / Drift 删掉这张图的揭开
  /// 记录，并让阅读器正文重新遮上——与 [onRevealImage] 是同一条状态的两个方向。
  final void Function(String key)? onUnrevealImage;

  /// 章节节头文案（spine 章号 → 章名，通常来自 TOC）。缺省用「第 N 章」。
  final String Function(int chapterIndex)? chapterLabelFor;

  /// 同合集卷切换；null = 单卷，头部不出卷 chip。
  final ReaderGalleryVolumeSwitch? volumeSwitch;

  @override
  State<ReaderGalleryPage> createState() => _ReaderGalleryPageState();
}

/// 一节 = 同一章的（当前过滤视图下）可见插图。
class _GallerySection {
  const _GallerySection({
    required this.chapterIndex,
    required this.images,
    required this.offset,
    required this.slots,
    required this.rows,
    required this.rowStarts,
  });

  final int chapterIndex;
  final List<EpubImageRef> images;

  /// 节头在滚动轴上的起点（逻辑像素）。
  final double offset;

  /// 每张图在本节网格里的槽位（与 [images] 同下标）。
  final List<_CardSlot> slots;

  /// 本节网格的行数。
  final int rows;

  /// 每行第一张图在 [images] 里的下标（长度 = [rows]）。
  final List<int> rowStarts;

  /// [row] 行里离 [column] 列最近的那张图的下标（同距取先出现的）。行由装填
  /// 保证非空。
  int nearestInRow(int row, int column) {
    int best = rowStarts[row];
    int bestDistance = (slots[best].column - column).abs();
    final int end = row + 1 < rows ? rowStarts[row + 1] : slots.length;
    for (int i = rowStarts[row] + 1; i < end; i++) {
      final int distance = (slots[i].column - column).abs();
      if (distance < bestDistance) {
        best = i;
        bestDistance = distance;
      }
    }
    return best;
  }
}

/// 网格里一张卡的槽位：第几行、起始列、占几列（横版图占两列）。
class _CardSlot {
  const _CardSlot({
    required this.row,
    required this.column,
    required this.span,
  });

  final int row;
  final int column;
  final int span;
}

/// 解析式布局模型：sliver 网格是惰性构建的，未进视口的卡片没有 RenderObject，
/// 框架的 `ensureVisible` 对它们无效。「打开时定位到当前章」「回到最近已看」
/// 「键盘焦点跟随」三处都要滚到还没构建的位置，所以列数 / 行高 / 每节偏移全由
/// 宽度推出来，网格本身也用同一份槽位表（[_SlotGridDelegate]），两边不会漂。
///
/// 横版图（宽 > 高，BUG-2589）占两列：竖版卡片比例塞不下双页插图，只能裁掉
/// 两侧。装填按阅读顺序走，一行剩一列放不下横版图就另起一行（上一行末尾留空，
/// 不拿后面的竖版图倒填——顺序比填满重要）。列数只有 1 时横版图退回占一列。
class _GalleryLayout {
  _GalleryLayout({
    required double gridWidth,
    required List<_ChapterGroup> groups,
    required int? currentChapter,
    required int Function(EpubImageRef ref) spanOf,
  }) : columns = _columnsFor(gridWidth) {
    cellWidth = (gridWidth - (columns - 1) * _kGridSpacing) / columns;
    cellHeight = cellWidth / _kCardAspectRatio;
    // 当前章自己有插图 → 标记画在它的节头上；没有 → 独立标记条插在
    // 第一个「晚于当前章」的节之前（全都早于当前章就压在末尾）。
    // [currentChapter] 为 null（看兄弟卷）时没有「当前阅读位置」可标，不出标记。
    final bool needsMarker =
        currentChapter != null &&
        groups.isNotEmpty &&
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
      final _GallerySection section = _packSection(
        group,
        offset: cursor,
        columns: columns,
        spanOf: spanOf,
      );
      built.add(section);
      cursor += _kSectionHeaderHeight + rowsExtent(section) + _kSectionGap;
    }
    if (needsMarker && markerBefore == null) {
      markerBefore = built.length;
      markerOffset = cursor;
    }
    sections = List<_GallerySection>.unmodifiable(built);
    markerSectionIndex = markerBefore;
  }

  /// 列数与书架端插图库同一规则（卡片随窗口变宽而放大，见
  /// [illustrationGridColumnsForWidth]）。
  static int _columnsFor(double gridWidth) =>
      illustrationGridColumnsForWidth(gridWidth, spacing: _kGridSpacing);

  /// 按阅读顺序把一章的图装进 [columns] 列的网格。
  static _GallerySection _packSection(
    _ChapterGroup group, {
    required double offset,
    required int columns,
    required int Function(EpubImageRef ref) spanOf,
  }) {
    final List<_CardSlot> slots = <_CardSlot>[];
    final List<int> rowStarts = <int>[];
    int row = 0;
    int column = 0;
    for (int i = 0; i < group.images.length; i++) {
      final int span = spanOf(group.images[i]).clamp(1, columns);
      if (column + span > columns) {
        row++;
        column = 0;
      }
      if (column == 0) rowStarts.add(i);
      slots.add(_CardSlot(row: row, column: column, span: span));
      column += span;
      if (column >= columns) {
        row++;
        column = 0;
      }
    }
    return _GallerySection(
      chapterIndex: group.chapterIndex,
      images: group.images,
      offset: offset,
      slots: slots,
      rows: rowStarts.length,
      rowStarts: rowStarts,
    );
  }

  final int columns;
  late final double cellWidth;
  late final double cellHeight;
  late final List<_GallerySection> sections;

  /// 「当前阅读位置」独立标记条插在第几节之前（当前章没有插图时才有）。
  late final int? markerSectionIndex;
  double? markerOffset;

  double get rowStride => cellHeight + _kGridSpacing;

  double rowsExtent(_GallerySection section) {
    final int rows = section.rows;
    if (rows <= 0) return 0;
    return rows * cellHeight + (rows - 1) * _kGridSpacing;
  }

  /// 某节第 [indexInSection] 张卡所在行的顶部偏移。
  double rowOffset(_GallerySection section, int indexInSection) =>
      section.offset +
      _kSectionHeaderHeight +
      section.slots[indexInSection].row * rowStride;
}

/// 把 [_GalleryLayout] 算好的槽位表交给 sliver 网格：每张卡的几何全部预先
/// 确定，网格与滚动定位读的是同一份数据。
class _SlotGridDelegate extends SliverGridDelegate {
  const _SlotGridDelegate({required this.layout, required this.section});

  final _GalleryLayout layout;
  final _GallerySection section;

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) =>
      _SlotGridLayout(layout: layout, section: section);

  @override
  bool shouldRelayout(_SlotGridDelegate oldDelegate) =>
      !identical(oldDelegate.section, section) ||
      oldDelegate.layout.cellWidth != layout.cellWidth ||
      oldDelegate.layout.cellHeight != layout.cellHeight;
}

class _SlotGridLayout extends SliverGridLayout {
  const _SlotGridLayout({required this.layout, required this.section});

  final _GalleryLayout layout;
  final _GallerySection section;

  @override
  SliverGridGeometry getGeometryForChildIndex(int index) {
    if (index >= section.slots.length) {
      // RenderSliverGrid 在 addInitialChild 之前就会拿 firstIndex 的几何；
      // 整节滚过时 firstIndex 越界（见 getMinChildIndexForScrollOffset），
      // 给一个落在本节末尾之后的空槽几何即可，与标准算术布局同形。
      return SliverGridGeometry(
        scrollOffset: section.rows * layout.rowStride,
        crossAxisOffset: 0,
        mainAxisExtent: layout.cellHeight,
        crossAxisExtent: layout.cellWidth,
      );
    }
    final _CardSlot slot = section.slots[index];
    return SliverGridGeometry(
      scrollOffset: slot.row * layout.rowStride,
      crossAxisOffset: slot.column * (layout.cellWidth + _kGridSpacing),
      mainAxisExtent: layout.cellHeight,
      crossAxisExtent:
          slot.span * layout.cellWidth + (slot.span - 1) * _kGridSpacing,
    );
  }

  @override
  int getMinChildIndexForScrollOffset(double scrollOffset) {
    if (section.rows == 0) return 0;
    final int row = (scrollOffset / layout.rowStride).floor();
    if (row < 0) return 0;
    // 整节已滚过视口（含 cacheExtent）：返回越界下标让 RenderSliverGrid 走
    // 「past the end」不挂任何子节点。clamp 到末行会让每个滚过的章永远挂着
    // 末行缩略图，几十章的书拉到底 = 几十行常驻内存。
    if (row >= section.rows) return section.slots.length;
    return section.rowStarts[row];
  }

  @override
  int getMaxChildIndexForScrollOffset(double scrollOffset) {
    if (section.rows == 0) return 0;
    // 与 SliverGridRegularTileLayout 同口径：滚动偏移落在第 k 行顶边之前时，
    // 最后一张可见卡属于第 k-1 行。
    final int row = (scrollOffset / layout.rowStride).ceil() - 1;
    if (row < 0) return 0;
    if (row + 1 >= section.rows) return section.slots.length - 1;
    return section.rowStarts[row + 1] - 1;
  }

  @override
  double computeMaxScrollOffset(int childCount) => layout.rowsExtent(section);
}

class _ChapterGroup {
  const _ChapterGroup(this.chapterIndex, this.images);
  final int chapterIndex;
  final List<EpubImageRef> images;
}

enum _LockedAction { backToLastSeen, revealAnyway }

const double _kCardAspectRatio = 0.72;
const double _kGridSpacing = 12;
const double _kPagePadding = 16;
const double _kTopPadding = 8;
const double _kSectionHeaderHeight = 44;
const double _kSectionGap = 16;
const double _kMarkerHeight = 32;

/// 插图册：顶栏「插图册 · 已解锁 n / N · [已解锁 | 全部] · 定位 · ×」；主体按章分组
/// 的网格。卡片两态——已解锁显示缩略图，未解锁盖这张图自己的高斯模糊层
/// （[maskedIllustrationCover]，墨水屏换实心遮板），点它弹出「回到最近已看 / 仍要
/// 查看」并带上解锁条件。解锁判据与阅读器正文、书架端插图库同源：
/// [ImageRevealKey.shouldBlur]（已揭开 ∪ 已读到 = 解锁）。
/// 点已解锁卡进页内全屏单图查看器（←/→ 切图、滚轮、Esc 关；点图交给 [onOpenImage]
/// 的既有缩放查看器，不造第二条缩放路径）。打开时自动滚到当前阅读章那一节。
/// 长按（桌面右键）任意卡片出菜单：跳到正文对应位置、揭开 / 恢复遮罩。
///
/// 同合集卷切换（BUG-2521）：头部卷 chip 行只换网格数据源，不切书；兄弟卷没有
/// 「当前阅读位置」，也不参与解锁判据（全视为已解锁），跳转 / 看大图带卷号走
/// [ReaderGalleryVolumeSwitch] 的回调。
class _ReaderGalleryPageState extends State<ReaderGalleryPage> {
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode(debugLabel: 'reader-gallery');
  final Set<String> _revealedHere = <String>{};

  /// 本页内被「恢复遮罩」的 key。宿主传进来的 [ReaderGalleryPage.revealedImageKeys]
  /// 是阅读器的会话集，本页只能读；撤销要生效就得在判据里把它们减掉，否则卡片得等
  /// 整页重建才变回遮罩态。
  final Set<String> _relockedHere = <String>{};

  bool _unlockedOnly = false;

  /// 键盘焦点落在哪张卡（按 src 记，过滤切换后下标会变、src 不变）。
  String? _focusedSrc;

  /// 全屏单图查看器当前在解锁列表里的下标；null = 查看器关着。
  int? _viewerIndex;

  _GalleryLayout? _layout;

  /// 当前查看那一卷里每张图的宽高比（按 `src` 记），开页 / 切卷后在 isolate 里
  /// 读文件头填上（[_probeAspects]）。没探到的按竖版处理。
  Map<String, double> _aspects = const <String, double>{};
  int _aspectProbeSeq = 0;

  /// 打开时自动定位落在的滚动偏移。宽高比探测完成会改行数，若用户此前没动过
  /// 滚动条（偏移还停在这个值），就按新布局重新定位一次，否则「定位到当前章」
  /// 会随行数变化漂到别的地方。
  double? _autoScrolledTo;

  /// 当前查看的卷（初值 = 当前卷）。看兄弟卷时 [_sibling] 持有该卷的插图表；
  /// 装载中 / 失败为 null（主体显示占位）。
  late int _viewedVolume = widget.volumeSwitch?.currentIndex ?? 0;
  ReaderGalleryVolumeImages? _sibling;
  Object? _siblingError;
  int _volumeLoadSeq = 0;

  bool get _peekingSibling =>
      widget.volumeSwitch != null &&
      _viewedVolume != widget.volumeSwitch!.currentIndex;

  /// 网格 / 查看器当前展示的插图表：当前卷走 widget，兄弟卷走已装载的表。
  List<EpubImageRef> get _images => _peekingSibling
      ? (_sibling?.images ?? const <EpubImageRef>[])
      : widget.images;

  File? _fileFor(EpubImageRef ref) =>
      _peekingSibling ? _sibling?.fileForRef(ref) : widget.fileForRef(ref);

  // ── 判据 ─────────────────────────────────────────────────────────────

  /// 这张图是否还没读到。判据与书架端插图库同一把尺：spine 章号 **加章内归一
  /// 偏移**（`EpubImageRef.normCharOffset`，与落库的阅读位置同 0~10000 基准）。
  /// 只比章号曾是 BUG-2559 的一半——当前章里读到一半，章内靠后的插图在这里算
  /// 「已读到」不遮，书架那边按偏移算「还没读到」照遮，同一本书两处糊的图不一样。
  bool _unreadAhead(EpubImageRef ref) {
    final int? currentChapter = widget.currentChapter;
    if (currentChapter == null) return false;
    if (ref.chapterIndex != currentChapter) {
      return ref.chapterIndex > currentChapter;
    }
    return ref.normCharOffset > widget.currentNormCharOffset;
  }

  /// 有没有「当前阅读位置」可标 / 可定位：当前卷且宿主给了章号。
  bool get _hasReadingPosition =>
      !_peekingSibling && widget.currentChapter != null;

  /// 当前有效的已揭开集：宿主会话集 ∪ 本页揭开的 − 本页恢复遮罩的。
  Set<String> get _revealedNow =>
      <String>{...widget.revealedImageKeys, ..._revealedHere}
        ..removeAll(_relockedHere);

  /// 兄弟卷没有阅读进度也不写本书的揭开表，一律视为已解锁；当前卷与阅读器正文 /
  /// 书架端插图库同一判据。
  bool _isLocked(EpubImageRef ref) =>
      !_peekingSibling &&
      ImageRevealKey.shouldBlur(
        blurEnabled: widget.blurImages,
        revealKey: ref.revealKey,
        revealed: _revealedNow,
        unreadAhead: _unreadAhead(ref),
      );

  List<EpubImageRef> get _unlocked =>
      _images.where((EpubImageRef r) => !_isLocked(r)).toList(growable: false);

  List<EpubImageRef> get _visible => _unlockedOnly ? _unlocked : _images;

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

  String _chapterLabel(int chapterIndex) {
    // 正文没引用的 OPF 封面挂在 kEpubCoverChapterIndex（-1）上：它不是 spine 里的
    // 第 0 章，按「第 N 章」算会写成「第 0 章」。
    if (chapterIndex == kEpubCoverChapterIndex) return t.reader_gallery_cover;
    return widget.chapterLabelFor?.call(chapterIndex) ??
        t.auto_chapter(n: chapterIndex + 1);
  }

  // ── 生命周期 ─────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _probeAspects();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _autoScrolledTo = _scrollToCurrentPosition(animate: false);
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // ── 宽高比探测（BUG-2589） ──────────────────────────────────────────

  /// 横版 = 宽 > 高，占两列；没探到 / 竖版占一列。
  int _spanOf(EpubImageRef ref) => (_aspects[ref.src] ?? 0) > 1 ? 2 : 1;

  /// 在 isolate 里读当前查看那一卷全部插图的文件头，拿到宽高比后重排网格。
  /// 按 seq 丢弃切卷后才回来的旧结果。
  void _probeAspects() {
    final int seq = ++_aspectProbeSeq;
    final Map<String, String> pathBySrc = <String, String>{};
    for (final EpubImageRef ref in _images) {
      final File? file = _fileFor(ref);
      if (file != null) pathBySrc[ref.src] = file.path;
    }
    if (pathBySrc.isEmpty) return;
    unawaited(
      compute(
        probeIllustrationAspectRatios,
        pathBySrc.values.toList(growable: false),
      ).then<void>(
        (Map<String, double> byPath) {
          if (!mounted || seq != _aspectProbeSeq) return;
          final Map<String, double> bySrc = <String, double>{
            for (final MapEntry<String, String> e in pathBySrc.entries)
              if (byPath[e.value] != null) e.key: byPath[e.value]!,
          };
          if (bySrc.isEmpty) return;
          final bool reanchor =
              _autoScrolledTo != null &&
              _scrollController.hasClients &&
              (_scrollController.offset - _autoScrolledTo!).abs() < 0.5;
          setState(() => _aspects = bySrc);
          if (!reanchor) return;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _autoScrolledTo = _scrollToCurrentPosition(animate: false);
          });
        },
        onError: (Object error, StackTrace stack) {
          ErrorLogService.instance.log(
            'ReaderGalleryPage.probeAspects',
            error,
            stack,
          );
        },
      ),
    );
  }

  // ── 滚动 ─────────────────────────────────────────────────────────────

  /// 滚到 [offset]（夹在可滚范围内），返回实际落点；没挂上滚动视图返回 null。
  double? _scrollTo(double offset, {required bool animate}) {
    if (!_scrollController.hasClients) return null;
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
    return target;
  }

  /// 当前阅读位置在滚动轴上的偏移：当前章那一节的节头；当前章没插图就是标记条。
  /// 没有阅读位置（看兄弟卷 / 书架端没读过的书）时 null（布局也不出标记）。
  double? _currentPositionOffset() {
    final _GalleryLayout? layout = _layout;
    if (layout == null || !_hasReadingPosition) return null;
    for (final _GallerySection section in layout.sections) {
      if (section.chapterIndex == widget.currentChapter) return section.offset;
    }
    return layout.markerOffset;
  }

  /// 返回实际落点（见 [_scrollTo]）。
  double? _scrollToCurrentPosition({required bool animate}) {
    final double? offset = _currentPositionOffset();
    if (offset == null) return null;
    return _scrollTo(offset, animate: animate);
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

  // ── 卷切换（BUG-2521） ───────────────────────────────────────────────

  /// 切换查看的卷：当前卷直接回到 widget 数据并重新定位到当前章；兄弟卷起一次
  /// 装载（按 seq 丢弃过期结果），装载完把网格滚到顶部。焦点 / 查看器随卷清空，
  /// 否则按 src 记的焦点会串到另一卷的同名文件上。
  void _selectVolume(int volume) {
    final ReaderGalleryVolumeSwitch? volumes = widget.volumeSwitch;
    if (volumes == null || volume == _viewedVolume) return;
    final int seq = ++_volumeLoadSeq;
    // 宽高比按卷探：旧表清掉，旧探测结果按 seq 作废（同名文件在另一卷可能
    // 是另一张图）。
    _aspectProbeSeq++;
    _autoScrolledTo = null;
    setState(() {
      _viewedVolume = volume;
      _sibling = null;
      _siblingError = null;
      _focusedSrc = null;
      _viewerIndex = null;
      _aspects = const <String, double>{};
    });
    if (volume == volumes.currentIndex) {
      _probeAspects();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _autoScrolledTo = _scrollToCurrentPosition(animate: false);
        }
      });
      return;
    }
    unawaited(
      volumes
          .imagesOf(volume)
          .then<void>(
            (ReaderGalleryVolumeImages data) {
              if (!mounted || seq != _volumeLoadSeq) return;
              setState(() => _sibling = data);
              _probeAspects();
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _scrollTo(0, animate: false);
              });
            },
            onError: (Object error) {
              if (!mounted || seq != _volumeLoadSeq) return;
              setState(() => _siblingError = error);
            },
          ),
    );
  }

  // ── 动作 ─────────────────────────────────────────────────────────────

  void _reveal(EpubImageRef ref) {
    final String key = ref.revealKey;
    setState(() {
      _relockedHere.remove(key);
      _revealedHere.add(key);
    });
    widget.onRevealImage?.call(key);
  }

  /// 「恢复遮罩」：撤销这张图的揭开状态，卡片重新盖回模糊层。
  void _relock(EpubImageRef ref) {
    final String key = ref.revealKey;
    setState(() {
      _revealedHere.remove(key);
      _relockedHere.add(key);
    });
    widget.onUnrevealImage?.call(key);
    // 正在看的就是这张、或过滤在「已解锁」时，撤销后它不再属于已解锁列表，
    // 查看器的下标会指向另一张图。直接关掉，不让它悄悄跳到隔壁那张。
    if (_viewerIndex != null) _closeViewer();
  }

  /// 这张图能否「恢复遮罩」：撤销揭开后确实会重新遮住才给这个动作。总开关关着
  /// 又已经读到的图，撤销只是删一条不起作用的记录，菜单里放一个点了没有任何可见
  /// 效果的项比不放更糟。
  bool _canRelock(EpubImageRef ref) =>
      !_peekingSibling &&
      (widget.blurImages || _unreadAhead(ref)) &&
      !_isLocked(ref);

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
    _restoreGridFocus();
    if (!mounted || action == null) return;
    switch (action) {
      case _LockedAction.backToLastSeen:
        _backToLastSeen();
      case _LockedAction.revealAnyway:
        _reveal(ref);
    }
  }

  /// 长按（桌面右键）卡片的动作菜单：跳到正文对应位置，外加这张图当前那一个方向的
  /// 遮罩动作——锁着给「仍要查看」，已揭开且撤销后会重新遮住的给「恢复遮罩」。
  ///
  /// 网格里点一下的语义是「看这张图」，跳转与遮罩开关都不该抢那一下；反过来，跳转
  /// 此前只在全屏查看器的顶栏有，锁着的图根本进不去查看器，于是那些图没有任何跳转
  /// 入口——菜单挂在卡片上正是为了补上这一半。
  Future<void> _showCardMenu(EpubImageRef ref) async {
    setState(() => _focusedSrc = ref.src);
    final bool locked = _isLocked(ref);
    final bool canRelock = _canRelock(ref);
    await adaptiveModalSheet<void>(
      context: context,
      builder: (BuildContext sheetContext) => FushiModalSheetFrame(
        title: _chapterLabel(ref.chapterIndex),
        subtitle: locked ? _lockedHint(ref) : null,
        leadingIcon: Icons.image_outlined,
        body: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            FushiListItem(
              key: const ValueKey<String>('fushi_gallery_menu_jump'),
              focusId: const FushiFocusId('fushi_gallery_menu_jump'),
              autofocus: true,
              leading: const Icon(Icons.my_location_outlined),
              title: Text(t.reader_gallery_jump),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _jumpTo(ref);
              },
            ),
            if (locked)
              FushiListItem(
                key: const ValueKey<String>('fushi_gallery_menu_reveal'),
                focusId: const FushiFocusId('fushi_gallery_menu_reveal'),
                leading: const Icon(Icons.visibility_outlined),
                title: Text(t.reader_gallery_locked_reveal),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _reveal(ref);
                },
              ),
            if (canRelock)
              FushiListItem(
                key: const ValueKey<String>('fushi_gallery_menu_relock'),
                focusId: const FushiFocusId('fushi_gallery_menu_relock'),
                leading: const Icon(Icons.visibility_off_outlined),
                title: Text(t.reader_gallery_relock),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _relock(ref);
                },
              ),
          ],
        ),
      ),
    );
    // 菜单 / 弹窗吃掉焦点后必须还回来：不还，用键盘或手柄选完一项，网格的方向键
    // 就再也不响应了（焦点停在已经销毁的 sheet 子树上），表现是「菜单用一次，
    // 键盘导航就废了」。指针用户看不见这个坑，正因为如此它更容易漏。
    _restoreGridFocus();
  }

  /// 把焦点还给网格（菜单 / 弹窗关闭后调）。
  void _restoreGridFocus() {
    if (!mounted) return;
    _focusNode.requestFocus();
  }

  String _lockedHint(EpubImageRef ref) => _unreadAhead(ref)
      ? t.reader_gallery_locked_unlock_hint(
          chapter: _chapterLabel(ref.chapterIndex),
        )
      : t.reader_gallery_locked_blur_hint;

  /// 「跳到此插图」：兄弟卷 = 切书 + 跳章（带卷号），当前卷走页面自己的回调。
  void _jumpTo(EpubImageRef ref) {
    if (_peekingSibling) {
      widget.volumeSwitch!.onJumpTo(_viewedVolume, ref);
      return;
    }
    widget.onJumpTo(ref);
  }

  /// 交给既有缩放查看器：兄弟卷要带该卷的文件（页面层用它开查看器），文件解析
  /// 不到就没有可看的东西。
  void _openImage(EpubImageRef ref) {
    if (_peekingSibling) {
      final File? file = _fileFor(ref);
      if (file != null) {
        widget.volumeSwitch!.onOpenImage(_viewedVolume, ref, file);
      }
      return;
    }
    widget.onOpenImage(ref);
  }

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
      final File? file = _fileFor(unlocked[i]);
      if (file == null) continue;
      // BUG-2496：precacheImage 不传 onError 时解码失败会自己
      // FlutterError.reportError（silent）——前后两张相邻图同帧预热正是错误日志里
      // 「两条同毫秒 Invalid image data」的形状。这里接住只留诊断痕迹。
      unawaited(
        precacheImage(
          FileImage(file),
          context,
          onError: (Object error, StackTrace? _) {
            ErrorLogService.instance.logDiagnostic(
              'ReaderGalleryPage.precache.coverDecode',
              '${file.path}: $error',
            );
          },
        ),
      );
    }
  }

  // ── 键盘 / 滚轮 ─────────────────────────────────────────────────────

  /// 网格内移动焦点：←/→ 沿阅读顺序 ±1；↑/↓ 落到相邻行里离当前列最近的那张
  /// （横版图占两列、行末可能留空，按槽位几何找而不是 ±列数），越过节边界时
  /// 落到相邻节的末行 / 首行。
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
      final _GallerySection section = sections[s];
      final _CardSlot slot = section.slots[flatIndex - base];
      final int targetRow = slot.row + dy;
      if (targetRow >= 0 && targetRow < section.rows) {
        return base + section.nearestInRow(targetRow, slot.column);
      }
      if (dy < 0) {
        if (s == 0) return flatIndex;
        final _GallerySection prev = sections[s - 1];
        return base -
            prev.images.length +
            prev.nearestInRow(prev.rows - 1, slot.column);
      }
      if (s == sections.length - 1) return flatIndex;
      return base + len + sections[s + 1].nearestInRow(0, slot.column);
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
    } else if (_isContextMenuKey(event)) {
      // 卡片菜单的键盘入口。指针那侧是长按 / 右键，键盘与手柄用户此前够不着菜单里
      // 的跳转与恢复遮罩——而插图册整页本来就是方向键 + Enter 驱动的，只有这一处
      // 动作没有键位，等于对不用指针的人不存在。菜单键 / Shift+F10 是两个平台通行
      // 的「唤出上下文菜单」键位，不与页内既有键冲突。
      final EpubImageRef? focused = _focusedRef();
      if (focused != null) unawaited(_showCardMenu(focused));
    } else if (key == LogicalKeyboardKey.escape) {
      Navigator.of(context).maybePop();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  /// 「唤出上下文菜单」的键位：菜单键，或 Windows 通行的 Shift+F10。
  static bool _isContextMenuKey(KeyEvent event) {
    if (event.logicalKey == LogicalKeyboardKey.contextMenu) return true;
    return event.logicalKey == LogicalKeyboardKey.f10 &&
        HardwareKeyboard.instance.isShiftPressed;
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
      if (current != null) _openImage(current);
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
    final double delta = event.scrollDelta.dy != 0
        ? event.scrollDelta.dy
        : event.scrollDelta.dx;
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
            // 画廊是从阅读器 push 出去的全页路由，没有 AppBar 也没有
            // FushiPageScaffold —— 裸 Scaffold 的 body 不会自己让开系统 inset，
            // 于是 iOS 上顶栏（过滤 / 定位 / 关闭）整条压在状态栏与灵动岛底下，
            // 点不到。顶 / 左 / 右交给 SafeArea，底部沿用页面通行的
            // [withBottomSafeInset]（网格自己补），不在这里吃掉一整条。
            SafeArea(
              bottom: false,
              child: Column(
                children: <Widget>[
                  _buildHeader(tokens, unlocked.length),
                  if (widget.volumeSwitch != null) _buildVolumeChips(),
                  Expanded(child: _buildBody(tokens)),
                ],
              ),
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
                      total: _images.length,
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
          // 兄弟卷全视为已解锁、也没有当前阅读位置：过滤与定位两个控件对它无意义。
          if (_images.isNotEmpty && !_peekingSibling) ...<Widget>[
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
            // 没有阅读位置（书架端打开没读过的书）就没有可定位的地方。
            if (_hasReadingPosition)
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

  /// 卷 chip 行（BUG-2521）：当前卷带书图标；点别的卷只换网格内容，不切书。
  Widget _buildVolumeChips() {
    final ReaderGalleryVolumeSwitch volumes = widget.volumeSwitch!;
    return SizedBox(
      height: 44,
      child: HorizontalDragScrollable(
        child: ListView.separated(
          key: const ValueKey<String>('reader-gallery-volume-chips'),
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(20, 2, 20, 6),
          itemCount: volumes.labels.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (BuildContext context, int i) => ChoiceChip(
            key: ValueKey<String>('reader-gallery-volume-chip-$i'),
            label: Text(
              volumes.labels[i],
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            avatar: i == volumes.currentIndex
                ? const Icon(Icons.menu_book_outlined, size: 16)
                : null,
            selected: i == _viewedVolume,
            onSelected: (bool _) => _selectVolume(i),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(FushiDesignTokens tokens) {
    final ThemeData theme = Theme.of(context);
    // 兄弟卷装载中转圈、失败提示；真无图沿用原文案。
    if (_peekingSibling && _siblingError != null) {
      _layout = null;
      return Center(
        child: Text(
          t.reader_volume_peek_failed,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
      );
    }
    if (_peekingSibling && _sibling == null) {
      _layout = null;
      return const Center(child: CircularProgressIndicator());
    }
    if (_images.isEmpty) {
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
          currentChapter: _hasReadingPosition ? widget.currentChapter : null,
          spanOf: _spanOf,
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
              // 末行卡片自己让开 home indicator / 手势条（与书架端插图库
              // BUG-2440 同一口径：viewport 不扣安全区，内容 padding 补）。
              SliverToBoxAdapter(
                child: SizedBox(height: bottomSafeInsetOf(context)),
              ),
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
    final bool current =
        !_peekingSibling && section.chapterIndex == widget.currentChapter;
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
        // 横版图占两列（BUG-2589）：槽位由 _GalleryLayout 装填，网格照着画。
        gridDelegate: _SlotGridDelegate(layout: layout, section: section),
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
    final Widget thumbnail = _thumbnail(tokens, ref);
    final Widget card = _GalleryCard(
      key: ValueKey<String>('fushi_gallery_card_${ref.src}'),
      tokens: tokens,
      focused: ref.src == _focusedSrc,
      onTap: () => _activate(ref),
      onLongPress: () => unawaited(_showCardMenu(ref)),
      // 锁着的卡是这张图本身的高斯模糊，不是一张写着「尚未读到」的纸：糊图既遮住了
      // 内容，又让人一眼看出这一格确实有张画、大致是什么色调，属于「还没读到」的
      // 正确观感。解锁条件那句话挪进点击后的弹窗与本菜单里，信息一点没少。
      child: locked
          ? maskedIllustrationCover(context, thumbnail, iconSize: 32)
          : thumbnail,
    );
    return ContextMenuTrigger(
      onInvoke: contextMenuInvoker(() => unawaited(_showCardMenu(ref))),
      child: card,
    );
  }

  Widget _thumbnail(FushiDesignTokens tokens, EpubImageRef ref) {
    final File? file = _fileFor(ref);
    final Widget missing = Center(
      child: Icon(
        Icons.broken_image_outlined,
        size: 24,
        color: tokens.surfaces.onVariant,
      ),
    );
    if (file == null) return missing;
    return Image.file(
      file,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      // BUG-2496：坏图解码失败与「文件缺失」同一占位，不再当致命 FlutterError。
      errorBuilder: (_, Object error, __) {
        ErrorLogService.instance.logDiagnostic(
          'ReaderGalleryPage.thumb.coverDecode',
          '${file.path}: $error',
        );
        return missing;
      },
    );
  }

  Widget _buildViewer(
    FushiDesignTokens tokens,
    EpubImageRef current,
    int unlockedCount,
  ) {
    final ThemeData theme = Theme.of(context);
    final int index = _viewerIndex ?? 0;
    final File? file = _fileFor(current);
    final Widget missing = Icon(
      Icons.broken_image_outlined,
      size: 64,
      color: tokens.surfaces.onVariant,
    );
    final Widget image = file == null
        ? missing
        : Image.file(
            file,
            key: ValueKey<String>('fushi_gallery_stage_${current.src}'),
            fit: BoxFit.contain,
            gaplessPlayback: true,
            // BUG-2496：坏图解码失败退回占位图标，不再当致命 FlutterError。
            errorBuilder: (_, Object error, __) {
              ErrorLogService.instance.logDiagnostic(
                'ReaderGalleryPage.stage.coverDecode',
                '${file.path}: $error',
              );
              return missing;
            },
          );
    return ColoredBox(
      key: const ValueKey<String>('fushi_gallery_viewer'),
      color: tokens.surfaces.page,
      // 查看器是 Positioned.fill 盖在网格之上的第二层整页 UI，外层那个 SafeArea
      // 管不到它；不自己让开的话「跳转 / 关闭」两个按钮在 iOS 上同样点不到。
      child: SafeArea(
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
                    onPressed: () => _jumpTo(current),
                  ),
                  IconButton(
                    key: const ValueKey<String>('fushi_gallery_viewer_close'),
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
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
                          onTap: () => _openImage(current),
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

/// 网格卡片外壳：圆角 + 细边框，键盘焦点用 2px 主色描边。
class _GalleryCard extends StatelessWidget {
  const _GalleryCard({
    super.key,
    required this.tokens,
    required this.focused,
    required this.onTap,
    required this.onLongPress,
    required this.child,
  });

  final FushiDesignTokens tokens;
  final bool focused;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final BorderRadius radius = tokens.radii.cardRadius;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      decoration: ShapeDecoration(
        color: tokens.surfaces.card,
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
        child: InkWell(onTap: onTap, onLongPress: onLongPress, child: child),
      ),
    );
  }
}

/// 点锁着的卡弹出的两个动作：「回到最近已看」/「仍要查看」。
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
