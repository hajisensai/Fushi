import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import 'package:hibiki/src/epub/epub_book.dart' show fallbackMimeType;
import 'package:hibiki/src/shortcuts/gamepad_service.dart'
    show GamepadButtonIntent;
import 'package:hibiki/src/shortcuts/input_binding.dart' show GamepadButton;
import 'package:hibiki/src/utils/misc/channel_constants.dart';
import 'package:hibiki/utils.dart';

/// 一张插画：解码用的字节 + 源磁盘文件（复制/分享需要真实文件路径）。
class _Illustration {
  const _Illustration({required this.bytes, required this.file});

  final Uint8List bytes;
  final File file;
}

class IllustrationsViewerPage extends StatefulWidget {
  const IllustrationsViewerPage({
    required this.bookTitle,
    required this.extractDir,
    super.key,
  });

  final String bookTitle;

  /// The book's on-disk extracted directory (`EpubBooks.extractDir`).
  final String extractDir;

  @override
  State<IllustrationsViewerPage> createState() =>
      _IllustrationsViewerPageState();
}

class _IllustrationsViewerPageState extends State<IllustrationsViewerPage> {
  final List<_Illustration> _images = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _extractImages();
  }

  static const Set<String> _imageExtensions = {
    '.jpg',
    '.jpeg',
    '.png',
    '.gif',
    '.webp',
    '.bmp',
    '.svg',
  };

  Future<void> _extractImages() async {
    try {
      final String extractDir = widget.extractDir;
      final Directory dir = Directory(extractDir);
      if (!dir.existsSync()) {
        if (mounted) {
          setState(() {
            _error = t.book_directory_not_found;
            _loading = false;
          });
        }
        return;
      }

      final List<File> imageFiles =
          dir.listSync(recursive: true).whereType<File>().where((f) {
        final String ext = p.extension(f.path).toLowerCase();
        return _imageExtensions.contains(ext);
      }).toList();

      for (final File file in imageFiles) {
        if (!mounted) {
          return;
        }
        try {
          final Uint8List bytes = await file.readAsBytes();
          if (bytes.isNotEmpty) {
            setState(
              () => _images.add(_Illustration(bytes: bytes, file: file)),
            );
          }
        } catch (e, stack) {
          ErrorLogService.instance
              .log('IllustrationsViewer.readImage', e, stack);
          debugPrint('[Hibiki] illustration read failed: $e');
        }
      }
    } catch (e, stack) {
      ErrorLogService.instance.log('IllustrationsViewer.loadImages', e, stack);
      if (mounted) {
        setState(() => _error = e.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return HibikiPageScaffold(
      title: widget.bookTitle,
      body: _buildBody(theme, tokens),
    );
  }

  Widget _buildBody(ThemeData theme, HibikiDesignTokens tokens) {
    if (_loading && _images.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            adaptiveIndicator(context: context),
            SizedBox(height: tokens.spacing.card),
            Text(t.loading_illustrations),
          ],
        ),
      );
    }

    if (_error != null && _images.isEmpty) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(tokens.spacing.page + tokens.spacing.card),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ),
      );
    }

    if (_images.isEmpty) {
      return Center(
        child: HibikiPlaceholderMessage(
          icon: Icons.image_not_supported_outlined,
          message: t.no_illustrations_found,
        ),
      );
    }

    return Column(
      children: [
        if (_loading) const LinearProgressIndicator(),
        Expanded(
          child: GridView.builder(
            padding: EdgeInsets.all(tokens.spacing.gap),
            gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 200,
              mainAxisSpacing: tokens.spacing.gap,
              crossAxisSpacing: tokens.spacing.gap,
            ),
            itemCount: _images.length,
            itemBuilder: (context, index) {
              return HibikiCard(
                padding: EdgeInsets.zero,
                onTap: () => _openFullScreen(index),
                child: Image.memory(
                  _images[index].bytes,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) =>
                      const Center(child: Icon(Icons.broken_image_outlined)),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  void _openFullScreen(int initialIndex) {
    Navigator.push(
      context,
      adaptivePageRoute(
        builder: (_) => _FullScreenGallery(
          images: _images,
          initialIndex: initialIndex,
        ),
      ),
    );
  }
}

class _FullScreenGallery extends StatefulWidget {
  const _FullScreenGallery({
    required this.images,
    required this.initialIndex,
  });

  final List<_Illustration> images;
  final int initialIndex;

  @override
  State<_FullScreenGallery> createState() => _FullScreenGalleryState();
}

class _FullScreenGalleryState extends State<_FullScreenGallery> {
  late PageController _pageController;
  late TransformationController _transformationController;
  late int _currentIndex;
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
    _transformationController = TransformationController();
  }

  @override
  void dispose() {
    _transformationController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  bool _handleGamepad(GamepadButton button) {
    switch (button) {
      case GamepadButton.rb:
        _pageBy(1);
        return true;
      case GamepadButton.lb:
        _pageBy(-1);
        return true;
      case GamepadButton.thumbRight:
        _toggleZoom();
        return true;
      default:
        return false;
    }
  }

  void _pageBy(int delta) {
    final int target =
        (_currentIndex + delta).clamp(0, widget.images.length - 1);
    if (target == _currentIndex) return;
    _pageController.animateToPage(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  void _toggleZoom() {
    setState(() {
      _zoomed = !_zoomed;
      _transformationController.value =
          _zoomed ? (Matrix4.identity()..scale(2.0)) : Matrix4.identity();
    });
  }

  void _setCurrentIndex(int index) {
    setState(() {
      _currentIndex = index;
      _zoomed = false;
      _transformationController.value = Matrix4.identity();
    });
  }

  File _currentFile() => widget.images[_currentIndex].file;

  /// 移动端：长按 / 顶栏分享按钮 → 系统分享面板（复用 TODO-023 范式）。
  Future<void> _shareCurrentImage() async {
    final File file = _currentFile();
    if (!file.existsSync()) {
      HibikiToast.show(msg: t.reader_image_file_unavailable);
      return;
    }
    try {
      await Share.shareXFiles(
        <XFile>[XFile(file.path, mimeType: fallbackMimeType(file.path))],
        subject: p.basename(file.path),
      );
    } catch (e) {
      HibikiToast.show(msg: t.reader_image_share_failed(error: e));
    }
  }

  /// Windows：右键菜单 / 顶栏复制按钮 → 原生剪贴板（复用 TODO-023 channel）。
  Future<void> _copyCurrentImageToClipboard() async {
    final File file = _currentFile();
    if (!file.existsSync()) {
      HibikiToast.show(msg: t.reader_image_file_unavailable);
      return;
    }
    try {
      await HibikiChannels.clipboardImage.invokeMethod<void>(
        'copyImageFile',
        <String, String>{'path': file.path},
      );
      HibikiToast.show(msg: t.copied_to_clipboard);
    } catch (e) {
      HibikiToast.show(msg: t.reader_image_copy_failed(error: e));
    }
  }

  /// Windows 右键弹出复制菜单（镜像阅读器内联图片的 `_showReaderImageContextMenu`）。
  Future<void> _showImageContextMenu(Offset globalPosition) async {
    if (!mounted) return;
    final RenderBox overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final String? action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 1, 1),
        Offset.zero & overlay.size,
      ),
      items: <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          value: 'copy',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.copy_outlined, size: 18),
              const SizedBox(width: 12),
              Text(t.reader_copy_image),
            ],
          ),
        ),
      ],
    );
    if (action == 'copy') {
      await _copyCurrentImageToClipboard();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 键盘处理由查看器自己持有（BUG-404）：ESC 退出不依赖全局
    // `_handleGlobalEscape`（整页 PageRoute 下其 primaryFocus 解析不稳定，
    // 实验导航关闭时退不出），左右方向键复用现成 `_pageBy`（已 clamp +
    // 驱动 PageView + 同步计数）。包在 `Focus(autofocus:true)` 外层，覆盖
    // 整页焦点子树，避免被内部 focusable 抢先。
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.maybePop(context),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _pageBy(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _pageBy(1),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          GamepadButtonIntent: CallbackAction<GamepadButtonIntent>(
            onInvoke: (GamepadButtonIntent intent) =>
                _handleGamepad(intent.button),
          ),
        },
        child: Focus(
          autofocus: true,
          child: HibikiToolScaffold(
            title: t.image_page_counter(
              current: _currentIndex + 1,
              total: widget.images.length,
            ),
            actions: <Widget>[
              if (isWindowsPlatform)
                IconButton(
                  icon: const Icon(Icons.copy_outlined),
                  tooltip: t.reader_copy_image,
                  onPressed: _copyCurrentImageToClipboard,
                )
              else
                IconButton(
                  icon: const Icon(Icons.share_outlined),
                  tooltip: t.share,
                  onPressed: _shareCurrentImage,
                ),
            ],
            body: PageView.builder(
              controller: _pageController,
              itemCount: widget.images.length,
              onPageChanged: _setCurrentIndex,
              itemBuilder: (context, index) {
                final Widget image = Image.memory(
                  widget.images[index].bytes,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => Icon(
                    Icons.broken_image_outlined,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                    size: 64,
                  ),
                );
                final Widget viewer = InteractiveViewer(
                  transformationController: _transformationController,
                  minScale: 0.5,
                  maxScale: 4,
                  child: Center(child: image),
                );
                // Windows 右键复制 / 移动端长按分享：仅当前页可操作。
                return GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onSecondaryTapDown: isWindowsPlatform
                      ? (TapDownDetails details) =>
                          _showImageContextMenu(details.globalPosition)
                      : null,
                  onLongPress: isWindowsPlatform ? null : _shareCurrentImage,
                  child: viewer,
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
