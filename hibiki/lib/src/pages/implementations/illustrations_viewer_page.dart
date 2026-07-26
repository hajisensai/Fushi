import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:hibiki_core/hibiki_core.dart' show HibikiDatabase;
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import 'package:hibiki/src/utils/misc/hibiki_share.dart';
import 'package:hibiki/src/epub/epub_book.dart' show fallbackMimeType;
import 'package:hibiki/src/media/media_extensions.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart'
    show ReaderHibikiSource;
import 'package:hibiki/src/reader/image_reveal_key.dart';
import 'package:hibiki/src/shortcuts/gamepad_service.dart'
    show GamepadButtonIntent;
import 'package:hibiki/src/shortcuts/input_binding.dart' show GamepadButton;
import 'package:hibiki/src/utils/misc/channel_constants.dart';
import 'package:hibiki/utils.dart';

/// 一张插画：解码用的字节 + 源磁盘文件（复制/分享需要真实文件路径）+ reveal key。
class _Illustration {
  const _Illustration({
    required this.bytes,
    required this.file,
    required this.revealKey,
  });

  final Uint8List bytes;
  final File file;

  /// BUG-898：extractDir 相对归一 key，与阅读器 WebView / Drift `revealed_images`
  /// 共享同一标识；`null` = 无法归一（不参与防剧透遮罩，始终原图）。
  final String? revealKey;
}

class IllustrationsViewerPage extends StatefulWidget {
  const IllustrationsViewerPage({
    required this.bookTitle,
    required this.extractDir,
    required this.bookKey,
    required this.database,
    super.key,
  });

  final String bookTitle;

  /// The book's on-disk extracted directory (`EpubBooks.extractDir`).
  final String extractDir;

  /// 书稳定身份（= EpubBooks.bookKey）；图片 reveal 状态按它键控持久化。
  final String bookKey;

  /// 图片 reveal 状态真相源（与阅读器 WebView 共享，实现书内↔图片库双向同步）。
  final HibikiDatabase database;

  @override
  State<IllustrationsViewerPage> createState() =>
      _IllustrationsViewerPageState();
}

class _IllustrationsViewerPageState extends State<IllustrationsViewerPage> {
  final List<_Illustration> _images = [];
  bool _loading = true;
  String? _error;

  /// BUG-898：本书已揭开的图片 key（与阅读器共享 Drift 真相源）。开页时一次性加载，
  /// 与阅读器不同时活跃（图片库仅从书架进入），故各自打开 get 即达成双向同步，无需
  /// live watch（避开 drift keyed watch 的 widget teardown 隐患）。
  final Set<String> _revealed = <String>{};

  /// 防剧透遮罩总开关：与阅读器同一偏好（`ttu_blur_images`）。关闭时图片库始终原图。
  bool get _blurEnabled =>
      ReaderHibikiSource.readerSettings?.blurImages ?? false;

  @override
  void initState() {
    super.initState();
    _loadRevealedThenImages();
  }

  Future<void> _loadRevealedThenImages() async {
    try {
      final Set<String> keys =
          await widget.database.getRevealedImageKeys(widget.bookKey);
      if (!mounted) return;
      _revealed.addAll(keys);
    } catch (e, stack) {
      ErrorLogService.instance
          .log('IllustrationsViewer.loadRevealed', e, stack);
    }
    await _extractImages();
  }

  /// 某图当前是否应遮罩（共用判据，缩略图 / 全屏一致）。
  bool _isBlurred(_Illustration im) => ImageRevealKey.shouldBlur(
        blurEnabled: _blurEnabled,
        revealKey: im.revealKey,
        revealed: _revealed,
      );

  /// 揭开一张图（幂等）：登记内存集 + 持久化到 Drift（阅读器下次开书据此不遮罩）。
  Future<void> _revealImage(_Illustration im) async {
    final String? key = im.revealKey;
    if (key == null || !_revealed.add(key)) return;
    setState(() {});
    try {
      await widget.database.markImageRevealed(
          widget.bookKey, key, DateTime.now().millisecondsSinceEpoch);
    } catch (e, stack) {
      ErrorLogService.instance.log('IllustrationsViewer.reveal', e, stack);
    }
  }

  /// 插图抽取白名单＝图片扩展名基集 ＋ `.svg`（EPUB 插画可为矢量图，
  /// 沿既有白名单保留，按字节交给查看器处理）。
  static final Set<String> _imageExtensions = <String>{
    ...kImageExtensionsBase,
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
            final _Illustration illust = _Illustration(
              bytes: bytes,
              file: file,
              revealKey: ImageRevealKey.fromFile(file.path, widget.extractDir),
            );
            setState(() => _images.add(illust));
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
              final _Illustration im = _images[index];
              final bool blurred = _isBlurred(im);
              return HibikiCard(
                padding: EdgeInsets.zero,
                // 未揭开：点击先揭开（防剧透）；已揭开：点击进全屏。
                onTap: blurred
                    ? () => _revealImage(im)
                    : () => _openFullScreen(index),
                child: _thumb(im, blurred),
              );
            },
          ),
        ),
      ],
    );
  }

  /// 缩略图：未遮罩直接原图；遮罩则模糊 + 蒙层 + 图标。
  Widget _thumb(_Illustration im, bool blurred) {
    final Widget img = Image.memory(
      im.bytes,
      fit: BoxFit.contain,
      errorBuilder: (_, __, ___) =>
          const Center(child: Icon(Icons.broken_image_outlined)),
    );
    return blurred ? _blurCover(img) : img;
  }

  /// 防剧透遮罩视觉：模糊图 + 半透明蒙层 + 「点击查看」图标。点击揭开由外层 onTap 处理。
  Widget _blurCover(Widget img) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        ClipRect(
          child: ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: img,
          ),
        ),
        const ColoredBox(color: Color(0x33000000)),
        const Center(
          child: Icon(Icons.visibility_off_outlined,
              color: Colors.white70, size: 36),
        ),
      ],
    );
  }

  void _openFullScreen(int initialIndex) {
    Navigator.push(
      context,
      adaptivePageRoute(
        context: context,
        builder: (_) => _FullScreenGallery(
          images: _images,
          initialIndex: initialIndex,
          revealed: _revealed,
          blurEnabled: _blurEnabled,
          onReveal: _revealImage,
        ),
      ),
    ).then((_) {
      // 全屏页可能揭开新图（写入共享 _revealed 集 + DB）；返回刷新网格遮罩。
      if (mounted) setState(() {});
    });
  }
}

class _FullScreenGallery extends StatefulWidget {
  const _FullScreenGallery({
    required this.images,
    required this.initialIndex,
    required this.revealed,
    required this.blurEnabled,
    required this.onReveal,
  });

  final List<_Illustration> images;
  final int initialIndex;

  /// 与网格页共享的已揭开集（同一 Set 引用，揭开双向可见，BUG-898）。
  final Set<String> revealed;
  final bool blurEnabled;

  /// 揭开一张图（写共享集 + 持久化）；全屏点击遮罩时调。
  final Future<void> Function(_Illustration) onReveal;

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

  /// 该图当前是否遮罩（与网格页同判据，读共享集）。
  bool _isBlurred(_Illustration im) => ImageRevealKey.shouldBlur(
        blurEnabled: widget.blurEnabled,
        revealKey: im.revealKey,
        revealed: widget.revealed,
      );

  /// 全屏点击遮罩 → 揭开（写共享集 + DB）后本地刷新为原图。
  Future<void> _revealCurrent(_Illustration im) async {
    await widget.onReveal(im);
    if (mounted) setState(() {});
  }

  /// 移动端：长按 / 顶栏分享按钮 → 系统分享面板（复用 TODO-023 范式）。
  Future<void> _shareCurrentImage() async {
    final File file = _currentFile();
    if (!file.existsSync()) {
      HibikiToast.show(msg: t.reader_image_file_unavailable);
      return;
    }
    try {
      await HibikiShare.shareFiles(
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
    // BUG-781（与 BUG-129/261/381 同族）：[globalPosition] 是 onSecondaryTapDown
    // 报的真实视口坐标，而 showMenu 的 RelativeRect 落在根 Navigator 的 Overlay
    // 坐标系，该 Overlay 位于全局 [HibikiAppUiScale] 的缩放画布内。直接把真实视口
    // 坐标当 Overlay 本地坐标喂进去，界面大小≠100% 时菜单会偏离点击点 factor≈scale。
    // 用 Overlay.globalToLocal 沿真实渲染变换链换算——FittedBox 缩放被自动吸收，
    // 对任意 scale 自洽；scale=1 时为单位阵，逐像素等价（零行为变化）。
    final Offset anchor = overlay.globalToLocal(globalPosition);
    final String? action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(anchor.dx, anchor.dy, 1, 1),
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
                final _Illustration im = widget.images[index];
                final Widget image = Image.memory(
                  im.bytes,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => Icon(
                    Icons.broken_image_outlined,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                    size: 64,
                  ),
                );
                if (_isBlurred(im)) {
                  // 遮罩态：模糊全屏 + 图标，点击揭开（揭开前不许缩放/复制/分享，防剧透）。
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _revealCurrent(im),
                    child: Stack(
                      fit: StackFit.expand,
                      children: <Widget>[
                        ClipRect(
                          child: ImageFiltered(
                            imageFilter:
                                ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                            child: Center(child: image),
                          ),
                        ),
                        const ColoredBox(color: Color(0x66000000)),
                        const Center(
                          child: Icon(Icons.visibility_off_outlined,
                              color: Colors.white70, size: 48),
                        ),
                      ],
                    ),
                  );
                }
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
