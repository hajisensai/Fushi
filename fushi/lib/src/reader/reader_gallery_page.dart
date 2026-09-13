/// 插图画廊页（ッツ / Hoshi Reader Gallery 形态），从 reader_fushi/chrome.part.dart
/// 抽出成独立组件：页面只负责提供图片列表 / 文件解析 / 跳章回调。
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:fushi_engine/epub/epub_book.dart' show EpubImageRef;
import 'package:fushi/src/reader/image_reveal_key.dart';
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
    required this.fileForRef,
    required this.onOpenImage,
    required this.onJumpTo,
    this.blurImages = false,
    this.revealedImageKeys = const <String>{},
    this.onRevealImage,
    this.volumeSwitch,
  });

  final List<EpubImageRef> images;
  final int currentChapter;
  final File? Function(EpubImageRef ref) fileForRef;
  final void Function(EpubImageRef ref) onOpenImage;
  final void Function(EpubImageRef ref) onJumpTo;
  final bool blurImages;
  final Set<String> revealedImageKeys;
  final void Function(String key)? onRevealImage;

  /// 同合集卷切换；null = 单卷，头部不出卷 chip。
  final ReaderGalleryVolumeSwitch? volumeSwitch;

  @override
  State<ReaderGalleryPage> createState() => _ReaderGalleryPageState();
}

/// 插图画廊（ッツ / Hoshi Reader Gallery 形态）：顶栏「Gallery + 关闭」，中央一张大图，
/// 左右圆形箭头切图，底部一条横向缩略图带（选中项描边）。左右方向键切图、Esc 关闭；
/// 点大图进既有的缩放查看器（[onOpenImage]），顶栏「跳到此插图」回正文对应章
/// （[onJumpTo]）。初始定位到当前章的第一张插图。
class _ReaderGalleryPageState extends State<ReaderGalleryPage> {
  static const double _kThumbWidth = 56;
  static const double _kThumbHeight = 72;
  static const double _kThumbGap = 8;
  static const double _kStripPadding = 12;

  final ScrollController _thumbController = ScrollController();
  final FocusNode _focusNode = FocusNode(debugLabel: 'reader-gallery');
  late int _index = _initialIndex();
  final Set<String> _revealedHere = <String>{};

  /// 当前查看的卷（初值 = 当前卷）。看兄弟卷时 [_sibling] 持有该卷的插图表；
  /// 装载中 / 失败为 null（舞台显示占位）。
  late int _viewedVolume = widget.volumeSwitch?.currentIndex ?? 0;
  ReaderGalleryVolumeImages? _sibling;
  Object? _siblingError;
  int _volumeLoadSeq = 0;

  bool get _peekingSibling =>
      widget.volumeSwitch != null &&
      _viewedVolume != widget.volumeSwitch!.currentIndex;

  /// 舞台 / 缩略图带当前展示的插图表：当前卷走 widget，兄弟卷走已装载的表。
  List<EpubImageRef> get _images => _peekingSibling
      ? (_sibling?.images ?? const <EpubImageRef>[])
      : widget.images;

  File? _fileFor(EpubImageRef ref) =>
      _peekingSibling ? _sibling?.fileForRef(ref) : widget.fileForRef(ref);

  /// 兄弟卷的揭示只记在本页（键加卷前缀防同名 src 串卷），不写当前书的 DB。
  String _revealKey(EpubImageRef ref) {
    final String key = ImageRevealKey.normalize(ref.src)!;
    return _peekingSibling ? 'v$_viewedVolume|$key' : key;
  }

  bool _isBlurred(EpubImageRef ref) => ImageRevealKey.shouldBlur(
        blurEnabled: widget.blurImages,
        revealKey: _revealKey(ref),
        revealed: <String>{
          if (!_peekingSibling) ...widget.revealedImageKeys,
          ..._revealedHere,
        },
      );

  void _activateImage(EpubImageRef ref) {
    if (_isBlurred(ref)) {
      final String key = _revealKey(ref);
      setState(() => _revealedHere.add(key));
      if (!_peekingSibling) widget.onRevealImage?.call(key);
      return;
    }
    if (_peekingSibling) {
      final File? file = _fileFor(ref);
      if (file != null) {
        widget.volumeSwitch!.onOpenImage(_viewedVolume, ref, file);
      }
      return;
    }
    widget.onOpenImage(ref);
  }

  void _jumpTo(EpubImageRef ref) {
    if (_peekingSibling) {
      widget.volumeSwitch!.onJumpTo(_viewedVolume, ref);
      return;
    }
    widget.onJumpTo(ref);
  }

  /// 切换查看的卷：当前卷直接回到 widget 数据；兄弟卷起一次装载（按 seq 丢弃
  /// 过期结果），装载完把舞台定位到第一张。
  void _selectVolume(int volume) {
    final ReaderGalleryVolumeSwitch? volumes = widget.volumeSwitch;
    if (volumes == null || volume == _viewedVolume) return;
    final int seq = ++_volumeLoadSeq;
    setState(() {
      _viewedVolume = volume;
      _sibling = null;
      _siblingError = null;
      _index = volume == volumes.currentIndex ? _initialIndex() : 0;
    });
    if (volume == volumes.currentIndex) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollThumbsTo(_index, animate: false);
      });
      return;
    }
    unawaited(
      volumes.imagesOf(volume).then<void>(
        (ReaderGalleryVolumeImages data) {
          if (!mounted || seq != _volumeLoadSeq) return;
          setState(() {
            _sibling = data;
            _index = 0;
          });
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _scrollThumbsTo(0, animate: false);
            if (_hasImages) _precacheNeighbours(0);
          });
        },
        onError: (Object error) {
          if (!mounted || seq != _volumeLoadSeq) return;
          setState(() => _siblingError = error);
        },
      ),
    );
  }

  Widget _blurImage(Widget image, {required bool stage}) => ClipRect(
        child: Stack(
          alignment: Alignment.center,
          children: <Widget>[
            ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
              child: image,
            ),
            Icon(Icons.visibility_off_outlined, size: stage ? 40 : 18),
          ],
        ),
      );

  int _initialIndex() {
    final int first = widget.images.indexWhere(
        (EpubImageRef r) => r.chapterIndex == widget.currentChapter);
    return first < 0 ? 0 : first;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollThumbsTo(_index, animate: false);
      if (_hasImages) _precacheNeighbours(_index);
    });
  }

  @override
  void dispose() {
    _thumbController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  bool get _hasImages => _images.isNotEmpty;
  EpubImageRef? get _current => _hasImages ? _images[_index] : null;

  void _select(int index) {
    if (!_hasImages) return;
    final int next = index.clamp(0, _images.length - 1);
    if (next == _index) return;
    setState(() => _index = next);
    _scrollThumbsTo(next, animate: true);
    _precacheNeighbours(next);
  }

  /// 预解码相邻两张（前 / 后），箭头 / 滚轮连续切图时舞台不闪白。
  void _precacheNeighbours(int index) {
    for (final int i in <int>[index - 1, index + 1]) {
      if (i < 0 || i >= _images.length) continue;
      final File? file = _fileFor(_images[i]);
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

  /// 把选中缩略图滚到缩略图带正中（两端夹到滚动范围内）。
  void _scrollThumbsTo(int index, {required bool animate}) {
    if (!_thumbController.hasClients) return;
    final double viewport = _thumbController.position.viewportDimension;
    final double target = (_kStripPadding +
            index * (_kThumbWidth + _kThumbGap) -
            (viewport - _kThumbWidth) / 2)
        .clamp(0.0, _thumbController.position.maxScrollExtent);
    if (animate) {
      _thumbController.animateTo(
        target,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
      );
    } else {
      _thumbController.jumpTo(target);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _select(_index - 1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _select(_index + 1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.home) {
      _select(0);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.end) {
      _select(_images.length - 1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      final EpubImageRef? current = _current;
      if (current != null) _activateImage(current);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 鼠标滚轮：向下 / 向右 = 下一张。
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final double delta =
        event.scrollDelta.dy != 0 ? event.scrollDelta.dy : event.scrollDelta.dx;
    if (delta == 0) return;
    _select(_index + (delta > 0 ? 1 : -1));
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Column(
          children: <Widget>[
            _buildHeader(theme),
            if (widget.volumeSwitch != null) _buildVolumeChips(theme),
            Expanded(
              child: _hasImages ? _buildStage(theme) : _buildEmpty(theme),
            ),
            if (_hasImages) _buildThumbStrip(theme),
          ],
        ),
      ),
    );
  }

  /// 空舞台：兄弟卷装载中转圈、失败提示、真无图沿用原文案。
  Widget _buildEmpty(ThemeData theme) {
    if (_peekingSibling && _siblingError != null) {
      return Center(
        child: Text(
          t.reader_volume_peek_failed,
          style: theme.textTheme.bodyLarge
              ?.copyWith(color: theme.colorScheme.error),
        ),
      );
    }
    if (_peekingSibling && _sibling == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Center(
      child: Text(t.reader_gallery_empty, style: theme.textTheme.bodyLarge),
    );
  }

  /// 卷 chip 行（BUG-2521）：当前卷带书图标；点别的卷只换舞台内容，不切书。
  Widget _buildVolumeChips(ThemeData theme) {
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

  Widget _buildHeader(ThemeData theme) {
    final EpubImageRef? current = _current;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 8, 4),
      child: Row(
        children: <Widget>[
          Text(
            t.reader_gallery,
            style: theme.textTheme.titleMedium,
          ),
          if (current != null) ...<Widget>[
            const SizedBox(width: 12),
            Text(
              '${_index + 1} / ${_images.length}',
              style: theme.textTheme.labelMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            if (!_peekingSibling &&
                current.chapterIndex == widget.currentChapter) ...<Widget>[
              const SizedBox(width: 12),
              Text(
                t.reader_gallery_current,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.primary),
              ),
            ],
          ],
          const Spacer(),
          if (current != null)
            IconButton(
              key: const ValueKey<String>('fushi_gallery_jump'),
              tooltip: t.reader_gallery_jump,
              icon: const Icon(Icons.my_location_outlined),
              onPressed: () => _jumpTo(current),
            ),
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

  Widget _buildStage(ThemeData theme) {
    final EpubImageRef current = _current!;
    final File? file = _fileFor(current);
    final Widget image = file == null
        ? Icon(
            Icons.broken_image_outlined,
            size: 64,
            color: theme.colorScheme.onSurfaceVariant,
          )
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
              return Icon(
                Icons.broken_image_outlined,
                size: 64,
                color: theme.colorScheme.onSurfaceVariant,
              );
            },
          );
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: Listener(
            onPointerSignal: _onPointerSignal,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 72, vertical: 8),
              child: GestureDetector(
                onTap: () => _activateImage(current),
                child: Center(
                  child: _isBlurred(current)
                      ? _blurImage(image, stage: true)
                      : image,
                ),
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
              theme,
              icon: Icons.chevron_left,
              enabled: _index > 0,
              onPressed: () => _select(_index - 1),
            ),
          ),
        ),
        Positioned(
          right: 16,
          top: 0,
          bottom: 0,
          child: Center(
            child: _arrowButton(
              theme,
              icon: Icons.chevron_right,
              enabled: _index < _images.length - 1,
              onPressed: () => _select(_index + 1),
            ),
          ),
        ),
      ],
    );
  }

  Widget _arrowButton(
    ThemeData theme, {
    required IconData icon,
    required bool enabled,
    required VoidCallback onPressed,
  }) {
    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.8),
      shape: const CircleBorder(),
      child: IconButton(
        icon: Icon(icon),
        iconSize: 24,
        color: theme.colorScheme.onSurface,
        onPressed: enabled ? onPressed : null,
      ),
    );
  }

  Widget _buildThumbStrip(ThemeData theme) {
    return SizedBox(
      height: _kThumbHeight + _kStripPadding * 2,
      child: Scrollbar(
        controller: _thumbController,
        thumbVisibility: true,
        // 桌面端默认 dragDevices 不含 mouse：不包这一层，鼠标左键横拖缩略图条
        // 毫无反应（缩略图只有 onTap，没有竞争性横拖手势，所以不存在豁免理由）。
        // 与 collection_shelf_row 的横向卡片行同构。
        child: HorizontalDragScrollable(
          child: ListView.separated(
            controller: _thumbController,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(_kStripPadding),
            itemCount: _images.length,
            separatorBuilder: (_, __) => const SizedBox(width: _kThumbGap),
            itemBuilder: (BuildContext context, int index) =>
                _buildThumb(theme, index),
          ),
        ),
      ),
    );
  }

  Widget _buildThumb(ThemeData theme, int index) {
    final EpubImageRef ref = _images[index];
    final bool selected = index == _index;
    final File? file = _fileFor(ref);
    final Widget missing = ColoredBox(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.broken_image_outlined,
          size: 18,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
    final Widget thumbnail = file == null
        ? missing
        : Image.file(
            file,
            fit: BoxFit.cover,
            // BUG-2496：坏图解码失败与「文件缺失」同一占位，不再当致命 FlutterError。
            errorBuilder: (_, Object error, __) {
              ErrorLogService.instance.logDiagnostic(
                'ReaderGalleryPage.thumb.coverDecode',
                '${file.path}: $error',
              );
              return missing;
            },
          );
    return GestureDetector(
      onTap: () => _select(index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: _kThumbWidth,
        height: _kThumbHeight,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: selected
                ? theme.colorScheme.primary
                : theme.colorScheme.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: Opacity(
            opacity: selected ? 1 : 0.7,
            child: _isBlurred(ref)
                ? _blurImage(thumbnail, stage: false)
                : thumbnail,
          ),
        ),
      ),
    );
  }
}
