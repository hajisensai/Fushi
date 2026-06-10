import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/src/pages/implementations/dictionary_webview_media.dart';
import 'package:hibiki/src/reader/dictionary_font_css.dart';
import 'package:hibiki/src/reader/reader_settings.dart';
import 'package:hibiki/utils.dart';
import 'package:url_launcher/url_launcher.dart';

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
        if (ext == '.otf' ||
            ext == '.ttf' ||
            ext == '.woff' ||
            ext == '.woff2') {
          final fontName = path.basenameWithoutExtension(f.path);
          final format = ext == '.otf'
              ? 'opentype'
              : ext == '.ttf'
                  ? 'truetype'
                  : ext == '.woff2'
                      ? 'woff2'
                      : 'woff';
          fontFaces.writeln(
              '@font-face { font-family: "$fontName"; src: url("${Uri.file(f.path)}") format("$format"); }');
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
/// Uses the same rendering engine (definition.js + popup.css) as the popup.
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
  bool _ready = false;

  /// Brightness last rendered into the WebView. Used to re-render when the app
  /// theme is toggled while this widget is on screen — see
  /// [didChangeDependencies].
  bool? _lastPushedIsDark;

  void _pushContent() {
    if (_controller == null || !_ready) return;

    final isDark = Theme.of(context).brightness == Brightness.dark;
    _lastPushedIsDark = isDark;
    final dictionaryFontSize = ref.read(appProvider).dictionaryFontSize;
    final dictCss =
        ref.read(dictionaryCssProvider(widget.entry.dictionaryName));
    final dictName = widget.entry.dictionaryName;

    final contentJson = jsonEncode(widget.entry.meaning);
    final dictCssJson = jsonEncode(dictCss);
    final dictNameJson = jsonEncode(dictName);

    _controller!.evaluateJavascript(source: '''
      window.renderDefinition(
        $contentJson,
        $dictNameJson,
        $dictCssJson,
        $dictionaryFontSize,
        $isDark
      );
    ''');
    // TODO-049: 注入独立的词典字体目标（与正文/系统 UI 分开）。
    final String fontStyleJs = _dictionaryFontStyleJs();
    if (fontStyleJs.isNotEmpty) {
      _controller!.evaluateJavascript(source: fontStyleJs);
    }
  }

  @override
  void didUpdateWidget(DictionaryHtmlWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry != widget.entry) {
      _pushContent();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Re-render when the app theme is toggled while this definition is on
    // screen (the inherited Theme rebuild fires didChangeDependencies).
    // renderDefinition is keyed on isDark, so only a brightness flip needs a
    // re-push; the guard skips unrelated dependency changes.
    if (!_ready || _controller == null) return;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (isDark == _lastPushedIsDark) return;
    _pushContent();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _contentHeight,
      child: InAppWebView(
        initialUrlRequest: URLRequest(
          url: WebUri(webViewAssetUrl('assets/popup/definition.html')),
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
          resourceCustomSchemes: dictionaryMediaCustomSchemes,
        ),
        shouldInterceptRequest: (controller, request) async {
          return dictionaryMediaWebResourceResponse(request.url);
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
          controller.addJavaScriptHandler(
            handlerName: 'openLink',
            callback: (args) async {
              if (args.isNotEmpty) {
                await _openExternalLink(args[0].toString());
              }
            },
          );
          controller.addJavaScriptHandler(
            handlerName: 'contentHeight',
            callback: (args) {
              if (args.isNotEmpty && mounted) {
                final h = (args[0] is num)
                    ? (args[0] as num).toDouble()
                    : double.tryParse(args[0].toString()) ?? _contentHeight;
                if (h > 0 && h != _contentHeight) {
                  setState(() {
                    _contentHeight = h;
                  });
                }
              }
            },
          );
        },
        onLoadStop: (controller, url) {
          _ready = true;
          _pushContent();
        },
        onLoadResourceWithCustomScheme: (controller, request) async {
          return dictionaryMediaCustomSchemeResponse(request.url);
        },
      ),
    );
  }

  /// TODO-049: builds the dictionary-font `<style>` injection JS (same approach
  /// as the popup WebView): system family names + inlined `data:` URL
  /// `@font-face` for imported files, placed before the popup.css default.
  String _dictionaryFontStyleJs() {
    final ReaderSettings? settings = ReaderHibikiSource.readerSettings;
    if (settings == null) return '';
    final appModel = ref.read(appProvider);
    final ({String fontFamily, String fontFaces}) css = DictionaryFontCss.build(
      settings.dictionaryFonts,
      allowedDirectories: <String>[
        path.join(appModel.appDirectory.path, 'custom_fonts'),
      ],
    );
    if (css.fontFamily.isEmpty) return '';
    final String styleCss = '${css.fontFaces}\n'
        'html, body { font-family: ${css.fontFamily}, '
        '"Hiragino Sans", "Hiragino Kaku Gothic ProN", sans-serif !important; }';
    final String styleJson = jsonEncode(styleCss);
    return '''
      (function(){
        var el = document.getElementById('hoshi-dict-font');
        if (!el) {
          el = document.createElement('style');
          el.id = 'hoshi-dict-font';
          document.head.appendChild(el);
        }
        el.textContent = $styleJson;
      })();''';
  }

  static Future<void> _openExternalLink(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) {
      return;
    }
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

/// Special delegate for text selection from a dictionary search result.
class DictionarySelectionDelegate
    extends MultiSelectableSelectionContainerDelegate {
  /// Initialise this widget.
  DictionarySelectionDelegate({
    required this.onTextSelectionGuessLength,
  });

  /// Callback with a [HibikiTextSelection] which contains the text of all
  /// selectables as well as a [TextRange] representing the substring to use
  /// for dictionary search. Returns the guess length of the text selection.
  final HibikiTextSelection Function(HibikiTextSelection)
      onTextSelectionGuessLength;

  // This method is called when newly added selectable is in the current
  // selected range.
  @override
  void ensureChildUpdated(Selectable selectable) {}

  /// Handles a [HibikiTextSelection].
  SelectionResult handleTextSelection(
      SelectWordSelectionEvent event, HibikiTextSelection selection) {
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

  SelectionEvent? _lastEvent;
  HibikiTextSelection? _guessSelection;
  HibikiTextSelection? _searchSelection;

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

    final eventSelection = HibikiTextSelection(
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
