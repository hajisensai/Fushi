/// 插图画廊页（ッツ / Hoshi Reader Gallery 形态），从 reader_fushi/chrome.part.dart
/// 抽出成独立组件：页面只负责提供图片列表 / 文件解析 / 跳章回调。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:fushi/src/epub/epub_book.dart' show EpubImageRef;
import 'package:fushi/utils.dart';

class ReaderGalleryPage extends StatefulWidget {
  const ReaderGalleryPage({
    super.key,
    required this.images,
    required this.currentChapter,
    required this.fileForRef,
    required this.onOpenImage,
    required this.onJumpTo,
  });

  final List<EpubImageRef> images;
  final int currentChapter;
  final File? Function(EpubImageRef ref) fileForRef;
  final void Function(EpubImageRef ref) onOpenImage;
  final void Function(EpubImageRef ref) onJumpTo;

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

  bool get _hasImages => widget.images.isNotEmpty;
  EpubImageRef? get _current => _hasImages ? widget.images[_index] : null;

  void _select(int index) {
    if (!_hasImages) return;
    final int next = index.clamp(0, widget.images.length - 1);
    if (next == _index) return;
    setState(() => _index = next);
    _scrollThumbsTo(next, animate: true);
    _precacheNeighbours(next);
  }

  /// 预解码相邻两张（前 / 后），箭头 / 滚轮连续切图时舞台不闪白。
  void _precacheNeighbours(int index) {
    for (final int i in <int>[index - 1, index + 1]) {
      if (i < 0 || i >= widget.images.length) continue;
      final File? file = widget.fileForRef(widget.images[i]);
      if (file == null) continue;
      unawaited(
        precacheImage(FileImage(file), context).catchError((Object _) {}),
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
      _select(widget.images.length - 1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      final EpubImageRef? current = _current;
      if (current != null) widget.onOpenImage(current);
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
            Expanded(
              child: _hasImages
                  ? _buildStage(theme)
                  : Center(
                      child: Text(
                        t.reader_gallery_empty,
                        style: theme.textTheme.bodyLarge,
                      ),
                    ),
            ),
            if (_hasImages) _buildThumbStrip(theme),
          ],
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
              '${_index + 1} / ${widget.images.length}',
              style: theme.textTheme.labelMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            if (current.chapterIndex == widget.currentChapter) ...<Widget>[
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
              onPressed: () => widget.onJumpTo(current),
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
    final File? file = widget.fileForRef(current);
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
          );
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: Listener(
            onPointerSignal: _onPointerSignal,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 72, vertical: 8),
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
              enabled: _index < widget.images.length - 1,
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
        child: ListView.separated(
          controller: _thumbController,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.all(_kStripPadding),
          itemCount: widget.images.length,
          separatorBuilder: (_, __) => const SizedBox(width: _kThumbGap),
          itemBuilder: (BuildContext context, int index) =>
              _buildThumb(theme, index),
        ),
      ),
    );
  }

  Widget _buildThumb(ThemeData theme, int index) {
    final EpubImageRef ref = widget.images[index];
    final bool selected = index == _index;
    final File? file = widget.fileForRef(ref);
    final Widget thumbnail = file == null
        ? ColoredBox(
            color: theme.colorScheme.surfaceContainerHighest,
            child: Center(
              child: Icon(
                Icons.broken_image_outlined,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          )
        : Image.file(file, fit: BoxFit.cover);
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
            child: thumbnail,
          ),
        ),
      ),
    );
  }
}
