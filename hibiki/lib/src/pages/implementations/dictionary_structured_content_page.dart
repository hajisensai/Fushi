import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:html/dom.dart' as dom;
import 'package:path/path.dart' as path;
import 'package:hibiki/dictionary.dart';
import 'package:hibiki/src/dictionary/hoshidicts.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/utils.dart';

/// Provides and caches the processed HTML of a [DictionaryEntry] to improve
/// performance.
final dictionaryEntryHtmlProvider =
    Provider.family<String, DictionaryEntry>((ref, entry) {
  final meaning = entry.meaning;
  try {
    final decoded = jsonDecode(meaning);
    final node = StructuredContent.processContent(decoded)?.toNode();
    if (node == null) {
      return meaning.replaceAll('\n', '<br>');
    }
    final document = dom.Document.html('');
    document.body?.append(node);
    return document.body?.innerHtml ?? '';
  } catch (_) {
    return meaning.replaceAll('\n', '<br>');
  }
});

final dictionaryCssProvider =
    Provider.family<String, String>((ref, dictionaryName) {
  final appModel = ref.read(appProvider);
  final dir = Directory(path.join(
    appModel.dictionaryResourceDirectory.path,
    dictionaryName,
  ));
  if (!dir.existsSync()) return '';

  final allEntities = dir.listSync();
  final cssFiles = allEntities
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.css'));

  final fontFaces = StringBuffer();
  for (final entity in allEntities) {
    if (entity is Directory) {
      for (final f in entity.listSync().whereType<File>()) {
        final ext = path.extension(f.path).toLowerCase();
        if (ext == '.otf' || ext == '.ttf' || ext == '.woff' || ext == '.woff2') {
          final fontName = path.basenameWithoutExtension(f.path);
          final format = ext == '.otf'
              ? 'opentype'
              : ext == '.ttf'
                  ? 'truetype'
                  : ext == '.woff2'
                      ? 'woff2'
                      : 'woff';
          fontFaces.writeln(
              '@font-face { font-family: "$fontName"; src: url("file://${f.path.replaceAll('\\', '/')}") format("$format"); }');
        }
      }
    }
  }

  final cssParts = cssFiles.map((f) => f.readAsStringSync()).toList();
  if (fontFaces.isNotEmpty) cssParts.insert(0, fontFaces.toString());
  if (cssParts.isEmpty) return '';
  return cssParts.join('\n');
});

/// Get the [Directory] used as a resource directory for a certain dictionary
/// name.
final dictionaryResourceDirectoryProvider =
    Provider.family<Directory, String>((ref, dictionaryName) {
  final appModel = ref.watch(appProvider);

  return Directory(
      path.join(appModel.dictionaryResourceDirectory.path, dictionaryName));
});

/// WebView-based HTML renderer for dictionary definitions.
/// Uses InAppWebView for full CSS support (including pseudo-classes).
class DictionaryHtmlWidget extends ConsumerStatefulWidget {
  const DictionaryHtmlWidget({
    required this.entry,
    required this.onSearch,
    this.onStash,
    this.onShare,
    super.key,
  });

  final DictionaryEntry entry;
  final Function(String) onSearch;
  final Function(String)? onStash;
  final Function(String)? onShare;

  @override
  ConsumerState<DictionaryHtmlWidget> createState() =>
      _DictionaryHtmlWidgetState();
}

class _DictionaryHtmlWidgetState extends ConsumerState<DictionaryHtmlWidget> {
  InAppWebViewController? _controller;
  double _contentHeight = 1;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColorHex = isDark ? '#ffffff' : '#000000';
    final linkColorHex = _colorToHex(Theme.of(context).colorScheme.error);
    final dictionaryFontSize = ref.read(appProvider).dictionaryFontSize;

    final css = ref.watch(dictionaryCssProvider(widget.entry.dictionaryName));
    final html = ref.watch(dictionaryEntryHtmlProvider(widget.entry));

    final directory = ref.read(
        dictionaryResourceDirectoryProvider(widget.entry.dictionaryName));
    final baseUrl = 'file:///${directory.path.replaceAll('\\', '/')}/';
    final processedHtml = html;

    final fullHtml = '<!DOCTYPE html>'
        '<html><head>'
        '<meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">'
        '<style>'
        '* { color: $textColorHex; font-size: ${dictionaryFontSize}px; }'
        'body { margin: 0; padding: 4px; background: transparent; word-wrap: break-word; }'
        'a { color: $linkColorHex; }'
        'table { border-collapse: collapse; }'
        'td, th { border: 0.3px solid $textColorHex; padding: 0.25em; vertical-align: top; }'
        'ul, li { padding: 0; }'
        'img { max-width: 100%; }'
        '$css'
        '</style></head>'
        '<body>$processedHtml</body>'
        '<script>'
        'document.addEventListener("click", function(e) {'
        '  var a = e.target.closest("a");'
        '  if (a) {'
        '    e.preventDefault();'
        '    var href = a.getAttribute("href") || "";'
        '    var query = "";'
        '    if (href.indexOf("?") >= 0) {'
        '      var params = new URLSearchParams(href.substring(href.indexOf("?")));'
        '      query = params.get("query") || a.textContent || "";'
        '    } else {'
        '      query = a.textContent || "";'
        '    }'
        '    window.flutter_inappwebview.callHandler("onLinkClick", query);'
        '  }'
        '});'
        '</script></html>';

    return SizedBox(
      height: _contentHeight,
      child: InAppWebView(
        initialData: InAppWebViewInitialData(
          data: fullHtml,
          baseUrl: WebUri(baseUrl),
          encoding: 'utf-8',
          mimeType: 'text/html',
        ),
        initialSettings: InAppWebViewSettings(
          transparentBackground: true,
          allowFileAccessFromFileURLs: true,
          allowUniversalAccessFromFileURLs: true,
          supportZoom: false,
          verticalScrollBarEnabled: false,
          horizontalScrollBarEnabled: false,
          disableVerticalScroll: true,
          disableHorizontalScroll: true,
          useShouldInterceptRequest: true,
        ),
        shouldInterceptRequest: (controller, request) async {
          final url = request.url;
          if (url.scheme == 'hibiki' && HoshiDicts.isInitialized) {
            final mediaPath = url.toString().substring('hibiki://'.length);
            if (mediaPath.isNotEmpty) {
              final data = HoshiDicts.instance
                  .getMediaFile(widget.entry.dictionaryName, mediaPath);
              if (data != null) {
                return WebResourceResponse(
                  contentType: _mimeTypeForPath(mediaPath),
                  data: data,
                );
              }
            }
          }
          return null;
        },
        contextMenu: ContextMenu(
          settings: ContextMenuSettings(
            hideDefaultSystemContextMenuItems: false,
          ),
          menuItems: [
            ContextMenuItem(
              id: 1,
              title: t.search,
              action: () async {
                final text = await _controller?.getSelectedText();
                if (text != null && text.isNotEmpty) {
                  widget.onSearch(text);
                }
              },
            ),
            if (widget.onStash != null)
              ContextMenuItem(
                id: 2,
                title: t.stash,
                action: () async {
                  final text = await _controller?.getSelectedText();
                  if (text != null && text.isNotEmpty) {
                    widget.onStash!(text);
                  }
                },
              ),
            if (widget.onShare != null)
              ContextMenuItem(
                id: 3,
                title: t.share,
                action: () async {
                  final text = await _controller?.getSelectedText();
                  if (text != null && text.isNotEmpty) {
                    widget.onShare!(text);
                  }
                },
              ),
          ],
        ),
        onWebViewCreated: (controller) {
          _controller = controller;
          controller.addJavaScriptHandler(
            handlerName: 'onLinkClick',
            callback: (args) {
              if (args.isNotEmpty) {
                widget.onSearch(args[0].toString());
              }
            },
          );
        },
        onLoadStop: (controller, url) async {
          await Future.delayed(const Duration(milliseconds: 100));
          final height = await controller.evaluateJavascript(
            source: 'document.body.scrollHeight',
          );
          if (height != null && mounted) {
            final h = (height is num)
                ? height.toDouble()
                : double.tryParse(height.toString()) ?? _contentHeight;
            if (h > 0 && h != _contentHeight) {
              setState(() {
                _contentHeight = h;
              });
            }
          }
        },
      ),
    );
  }

  static String _mimeTypeForPath(String path) {
    final ext = path.split('.').last.toLowerCase();
    switch (ext) {
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'svg':
        return 'image/svg+xml';
      default:
        return 'application/octet-stream';
    }
  }

  String _colorToHex(Color color) {
    final r = color.r, g = color.g, b = color.b;
    String c(double v) => (v * 255).round().toRadixString(16).padLeft(2, '0');
    return '#${c(r)}${c(g)}${c(b)}';
  }
}

/// Special delegate for text selection from a dictionary search result.
class DictionarySelectionDelegate
    extends MultiSelectableSelectionContainerDelegate {
  /// Initialise this widget.
  DictionarySelectionDelegate({
    required this.onTextSelectionGuessLength,
  });

  /// Callback with a [JidoujishoTextSelection] which contains the text of all
  /// selectables as well as a [TextRange] representing the substring to use
  /// for dictionary search. Returns the guess length of the text selection.
  final JidoujishoTextSelection Function(JidoujishoTextSelection)
      onTextSelectionGuessLength;

  // This method is called when newly added selectable is in the current
  // selected range.
  @override
  void ensureChildUpdated(Selectable selectable) {}

  /// Handles a [JidoujishoTextSelection].
  SelectionResult handleTextSelection(
      SelectWordSelectionEvent event, JidoujishoTextSelection selection) {
    handleClearSelection(const ClearSelectionEvent());

    super.handleSelectWord(event);
    while ((getSelectedContent()?.plainText ?? '').length > 1) {
      super.handleGranularlyExtendSelection(
        const GranularlyExtendSelectionEvent(
            forward: false,
            isEnd: true,
            granularity: TextGranularity.character),
      );
    }

    final highlightLength = selection.textInside.length;

    SelectionResult? result;
    for (int i = 0; i < highlightLength - 1; i++) {
      result = super.handleGranularlyExtendSelection(
        const GranularlyExtendSelectionEvent(
          forward: true,
          isEnd: true,
          granularity: TextGranularity.character,
        ),
      );
    }

    return result ?? super.handleSelectWord(event);
  }

  @override
  SelectionResult dispatchSelectionEvent(SelectionEvent event) {
    return super.dispatchSelectionEvent(event);
  }

  SelectionEvent? _lastEvent;
  JidoujishoTextSelection? _guessSelection;
  JidoujishoTextSelection? _searchSelection;

  @override
  SelectionResult handleSelectWord(SelectWordSelectionEvent event) {
    if (_searchSelection != null && _lastEvent == event) {
      final selection = _searchSelection;
      _searchSelection = null;

      final startDiff = selection!.range.start - _guessSelection!.range.start;
      final endDiff = selection.range.end - _guessSelection!.range.end;

      SelectionResult? result;
      for (int i = 0; i < startDiff.abs(); i++) {
        result = super.handleGranularlyExtendSelection(
          GranularlyExtendSelectionEvent(
            forward: !startDiff.isNegative,
            isEnd: true,
            granularity: TextGranularity.character,
          ),
        );
      }

      for (int i = 0; i < endDiff.abs(); i++) {
        result = super.handleGranularlyExtendSelection(
          GranularlyExtendSelectionEvent(
            forward: !endDiff.isNegative,
            isEnd: true,
            granularity: TextGranularity.character,
          ),
        );
      }

      return result!;
    }

    super.handleSelectWord(event);
    _lastEvent = event;

    if (!(currentSelectionEndIndex < selectables.length &&
        currentSelectionEndIndex >= 0)) {
      return handleClearSelection(const ClearSelectionEvent());
    }

    handleGranularlyExtendSelection(
      const GranularlyExtendSelectionEvent(
        forward: false,
        isEnd: true,
        granularity: TextGranularity.document,
      ),
    );

    handleClearSelection(const ClearSelectionEvent());

    final textBefore = getSelectedContent()?.plainText ?? '';

    super.handleSelectWord(event);
    handleGranularlyExtendSelection(
      const GranularlyExtendSelectionEvent(
        forward: true,
        isEnd: true,
        granularity: TextGranularity.document,
      ),
    );

    final textAfter = getSelectedContent()?.plainText ?? '';

    final text = '$textBefore$textAfter';

    final eventSelection = JidoujishoTextSelection(
      text: text,
      range: TextRange(
        start: textBefore.length,
        end: text.length,
      ),
    );

    late SelectionResult result;
    final guessSelection = onTextSelectionGuessLength(eventSelection);
    result = handleTextSelection(event, guessSelection);

    return result;
  }
}
