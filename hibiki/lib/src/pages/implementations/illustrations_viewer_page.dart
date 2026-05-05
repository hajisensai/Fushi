import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:hibiki/utils.dart';

class IllustrationsViewerPage extends StatefulWidget {
  const IllustrationsViewerPage({
    required this.bookTitle,
    required this.ttuBookId,
    required this.port,
    super.key,
  });

  final String bookTitle;
  final int ttuBookId;
  final int port;

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

  Future<void> _extractImages() async {
    bool jsInjected = false;
    final completer = Completer<void>();
    int expectedCount = -1;

    final HeadlessInAppWebView webView = HeadlessInAppWebView(
      initialSettings: InAppWebViewSettings(
        databaseEnabled: true,
        domStorageEnabled: true,
      ),
      initialUrlRequest: URLRequest(
        url: WebUri('http://localhost:${widget.port}/_hibiki_idb.html'),
      ),
      onLoadStop: (controller, url) async {
        if (!jsInjected) {
          jsInjected = true;
          await controller.evaluateJavascript(source: _extractImagesJs);
        }
      },
      onReceivedError: (controller, request, error) {
        if (!completer.isCompleted) {
          completer.completeError(error.description);
        }
      },
      onConsoleMessage: (controller, message) {
        try {
          final Map<String, dynamic> json = jsonDecode(message.message);
          final String? msgType = json['messageType'] as String?;

          if (msgType == 'illustrations_count') {
            expectedCount = json['count'] as int;
            if (expectedCount == 0 && !completer.isCompleted) {
              completer.complete();
            }
          } else if (msgType == 'illustration') {
            final String base64Data = json['data'] as String;
            final int commaIdx = base64Data.indexOf(',');
            final String raw =
                commaIdx >= 0 ? base64Data.substring(commaIdx + 1) : base64Data;
            try {
              final bytes = base64Decode(raw);
              if (mounted) {
                setState(() => _images.add(bytes));
              }
              if (_images.length >= expectedCount &&
                  !completer.isCompleted) {
                completer.complete();
              }
            } catch (e) {
              debugPrint('[Hibiki] illustration decode failed: $e');
            }
          } else if (msgType == 'illustrations_error') {
            if (!completer.isCompleted) {
              completer.completeError(
                  json['error'] ?? 'Failed to extract images');
            }
          }
        } on FormatException catch (_) {}
      },
    );

    try {
      await webView.run();
      await completer.future.timeout(const Duration(seconds: 30));
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString());
      }
    } finally {
      await webView.dispose();
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  String get _extractImagesJs => '''
(async function() {
  try {
    var bookId = ${widget.ttuBookId};

    function getFromIDB(storeName, key) {
      return new Promise(function(resolve, reject) {
        var req = indexedDB.open("books");
        req.onupgradeneeded = function(e) {
          e.target.transaction.abort();
          reject(Error("DB not initialized"));
        };
        req.onerror = function() { reject(Error("Cannot open IDB")); };
        req.onsuccess = function(e) {
          var db = e.target.result;
          try {
            var tx = db.transaction([storeName], 'readonly');
            var store = tx.objectStore(storeName);
            var getReq = store.get(key);
            getReq.onsuccess = function() { resolve(getReq.result); };
            getReq.onerror = function() { reject(Error("Get failed")); };
          } catch(ex) { reject(ex); }
        };
      });
    }

    function blobToBase64(blob) {
      return new Promise(function(resolve, reject) {
        var reader = new FileReader();
        reader.onload = function() { resolve(reader.result); };
        reader.onerror = function() { reject(Error("FileReader error")); };
        reader.readAsDataURL(blob);
      });
    }

    var bookData = await getFromIDB('data', bookId);
    if (!bookData) {
      console.log(JSON.stringify({messageType: 'illustrations_error', error: 'Book not found in IDB'}));
      return;
    }

    var images = [];
    var sections = bookData.sections || bookData.htmlContent || [];

    for (var i = 0; i < sections.length; i++) {
      var html = '';
      if (typeof sections[i] === 'string') {
        html = sections[i];
      } else if (sections[i] && sections[i].innerHTML) {
        html = sections[i].innerHTML;
      } else if (sections[i] && sections[i].htmlContent) {
        html = sections[i].htmlContent;
      } else {
        continue;
      }

      var parser = new DOMParser();
      var doc = parser.parseFromString(html, 'text/html');
      var imgs = doc.querySelectorAll('img, image');
      for (var j = 0; j < imgs.length; j++) {
        var src = imgs[j].getAttribute('src') || imgs[j].getAttribute('href') || imgs[j].getAttribute('xlink:href') || '';
        if (src) images.push(src);
      }
    }

    if (bookData.blobs) {
      var imgExtensions = ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.svg'];

      // Build ordered list: match each src from sections to a blob key
      var orderedBlobs = [];
      var usedKeys = {};
      for (var si = 0; si < images.length; si++) {
        var src = images[si];
        var srcFile = src.split('/').pop().split('?')[0].split('#')[0];
        var blobKeys = Object.keys(bookData.blobs);
        for (var ki = 0; ki < blobKeys.length; ki++) {
          var bk = blobKeys[ki];
          if (usedKeys[bk]) continue;
          var bkFile = bk.split('/').pop();
          if (src.indexOf(bk) >= 0 || bk.indexOf(src) >= 0 ||
              srcFile === bkFile || bk.endsWith(srcFile)) {
            orderedBlobs.push(bk);
            usedKeys[bk] = true;
            break;
          }
        }
      }

      // Append any remaining image blobs not referenced in sections
      var allBlobKeys = Object.keys(bookData.blobs);
      for (var ai = 0; ai < allBlobKeys.length; ai++) {
        var key = allBlobKeys[ai];
        if (usedKeys[key]) continue;
        var lower = key.toLowerCase();
        if (imgExtensions.some(function(ext) { return lower.endsWith(ext); })) {
          orderedBlobs.push(key);
        }
      }

      console.log(JSON.stringify({messageType: 'illustrations_count', count: orderedBlobs.length}));

      for (var ri = 0; ri < orderedBlobs.length; ri++) {
        try {
          var blob = bookData.blobs[orderedBlobs[ri]];
          if (blob instanceof Blob) {
            var b64 = await blobToBase64(blob);
            console.log(JSON.stringify({messageType: 'illustration', data: b64}));
          }
        } catch(e) {}
      }
    } else {
      console.log(JSON.stringify({messageType: 'illustrations_count', count: 0}));
    }

  } catch(e) {
    console.log(JSON.stringify({messageType: 'illustrations_error', error: e.message || String(e)}));
  }
})();
''';

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
