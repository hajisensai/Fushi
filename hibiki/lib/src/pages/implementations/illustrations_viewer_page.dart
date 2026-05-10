import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:hibiki/src/epub/epub_storage.dart';
import 'package:hibiki/utils.dart';

class IllustrationsViewerPage extends StatefulWidget {
  const IllustrationsViewerPage({
    required this.bookTitle,
    required this.bookId,
    super.key,
  });

  final String bookTitle;
  final int bookId;

  @override
  State<IllustrationsViewerPage> createState() =>
      _IllustrationsViewerPageState();
}

class _IllustrationsViewerPageState extends State<IllustrationsViewerPage> {
  final List<Uint8List> _images = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _extractImages();
  }

  static const Set<String> _imageExtensions = {
    '.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.svg',
  };

  Future<void> _extractImages() async {
    try {
      final String extractDir =
          await EpubStorage.bookDirectory(widget.bookId);
      final Directory dir = Directory(extractDir);
      if (!dir.existsSync()) {
        if (mounted) {
          setState(() {
            _error = 'Book directory not found';
            _loading = false;
          });
        }
        return;
      }

      final List<File> imageFiles = dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) {
            final String ext = p.extension(f.path).toLowerCase();
            return _imageExtensions.contains(ext);
          })
          .toList();

      for (final File file in imageFiles) {
        if (!mounted) {
          return;
        }
        try {
          final Uint8List bytes = await file.readAsBytes();
          if (bytes.isNotEmpty) {
            setState(() => _images.add(bytes));
          }
        } catch (e) {
          debugPrint('[Hibiki] illustration read failed: $e');
        }
      }
    } catch (e) {
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
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.bookTitle),
      ),
      body: _buildBody(theme),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_loading && _images.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(t.loading_illustrations),
          ],
        ),
      );
    }

    if (_error != null && _images.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
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
        child: JidoujishoPlaceholderMessage(
          icon: Icons.image_not_supported_outlined,
          message: t.no_illustrations_found,
        ),
      );
    }

    return Column(
      children: [
        if (_loading)
          const LinearProgressIndicator(),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(8),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 200,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
            ),
            itemCount: _images.length,
            itemBuilder: (context, index) {
              return GestureDetector(
                onTap: () => _openFullScreen(index),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.memory(
                    _images[index],
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      color: Theme.of(context).colorScheme.surfaceContainerLow,
                      child: const Icon(Icons.broken_image_outlined),
                    ),
                  ),
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
      MaterialPageRoute(
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

  final List<Uint8List> images;
  final int initialIndex;

  @override
  State<_FullScreenGallery> createState() => _FullScreenGalleryState();
}

class _FullScreenGalleryState extends State<_FullScreenGallery> {
  late PageController _pageController;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text('${_currentIndex + 1} / ${widget.images.length}'),
      ),
      body: PageView.builder(
        controller: _pageController,
        itemCount: widget.images.length,
        onPageChanged: (index) => setState(() => _currentIndex = index),
        itemBuilder: (context, index) {
          return InteractiveViewer(
            minScale: 0.5,
            maxScale: 4.0,
            child: Center(
              child: Image.memory(
                widget.images[index],
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => Icon(
                  Icons.broken_image_outlined,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                  size: 64,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
