import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/dictionary_webview_media.dart';
import 'package:hibiki/utils.dart';
import 'package:url_launcher/url_launcher.dart';

class DictionaryPopupWebView extends ConsumerStatefulWidget {
  const DictionaryPopupWebView({
    required this.result,
    super.key,
    this.onTextSelected,
    this.onLinkClick,
    this.onTapOutside,
    this.onMineEntry,
    this.onDuplicateCheck,
    this.onScrolledToBottom,
  });

  final DictionarySearchResult result;
  final void Function(String text, Rect localRect)? onTextSelected;
  final void Function(String query, Rect localRect)? onLinkClick;
  final VoidCallback? onTapOutside;
  final Future<bool> Function(Map<String, String> fields)? onMineEntry;
  final Future<bool> Function(String expression, String reading)?
      onDuplicateCheck;
  final VoidCallback? onScrolledToBottom;

  @override
  ConsumerState<DictionaryPopupWebView> createState() =>
      DictionaryPopupWebViewState();
}

class DictionaryPopupWebViewState
    extends ConsumerState<DictionaryPopupWebView> {
  InAppWebViewController? _controller;
  bool _ready = false;
  String? _lastSearchTerm;
  int _lastEntryCount = 0;

  static const String _scrollCheckJs = '''
(function(){
  if(!window.__hoshiScrollInstalled){
    window.__hoshiScrollInstalled=true;
    var t=0;
    function check(force){
      var now=Date.now();
      if(!force&&now-t<500) return;
      var sh=document.documentElement.scrollHeight;
      var st=window.scrollY||document.documentElement.scrollTop;
      var ch=window.innerHeight;
      if(sh>0&&sh-st-ch<200){
        t=now;
        window.flutter_inappwebview.callHandler('scrolledToBottom');
      }
    }
    window.__hoshiScrollCheck=check;
    window.addEventListener('scroll',function(){check(false);},true);
  }
  setTimeout(function(){window.__hoshiScrollCheck(true);},0);
  setTimeout(function(){window.__hoshiScrollCheck(true);},150);
})();
''';

  void highlightSelection(int charCount) {
    _controller?.evaluateJavascript(
      source: 'window.hoshiSelection.highlightSelection($charCount)',
    );
  }

  void clearSelection() {
    _controller?.evaluateJavascript(
      source: 'window.hoshiSelection.clearSelection()',
    );
  }

  Future<String?> _resolveWordAudio(String expression, String reading) async {
    final appModel = ref.read(appProvider);
    final WordAudioResolver resolver = WordAudioResolver(
      queryLocalAudio: (expression, reading) async {
        if (!appModel.localAudioEnabled) return null;
        try {
          return await TtsChannel.instance
              .queryLocalAudio(expression, reading)
              .timeout(const Duration(milliseconds: 500));
        } on TimeoutException {
          return null;
        }
      },
      extractLocalAudio: TtsChannel.instance.extractLocalAudio,
    );
    return resolver.resolve(
      expression: expression,
      reading: reading,
      sources: appModel.enabledAudioSources,
    );
  }

  @override
  void didUpdateWidget(DictionaryPopupWebView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.result != widget.result) {
      _pushResults();
    }
  }

  void _pushResults() {
    if (_controller == null || !_ready) return;
    if (widget.result.entries.isEmpty) return;

    final bool isLoadMore =
        _lastSearchTerm == widget.result.searchTerm &&
        widget.result.entries.length > _lastEntryCount;
    _lastSearchTerm = widget.result.searchTerm;
    _lastEntryCount = widget.result.entries.length;

    final swJson = Stopwatch()..start();
    final entriesJson = buildLookupEntriesJson(widget.result);
    swJson.stop();
    debugPrint(
        '[dict-perf] buildLookupEntriesJson: ${swJson.elapsedMilliseconds}ms len=${entriesJson.length} loadMore=$isLoadMore');

    final stylesJson = jsonEncode(HoshiDicts.dictionaryStyles);
    final ThemeData theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final Color primary = theme.colorScheme.primary;
    final int pr = (primary.r * 255.0).round().clamp(0, 255);
    final int pg = (primary.g * 255.0).round().clamp(0, 255);
    final int pb = (primary.b * 255.0).round().clamp(0, 255);
    final String primaryRgba = 'rgba($pr, $pg, $pb, 0.35)';

    final appModel = ref.read(appProvider);
    final deduplicatePitch = appModel.deduplicatePitchAccents;
    final harmonicFreq = appModel.harmonicFrequency;
    final collapseDict = appModel.collapseDictionaries;
    final showExprTags = appModel.showExpressionTags;
    final audioSourcesJson = jsonEncode(appModel.enabledAudioSources);

    final Color onSurface = theme.colorScheme.onSurface;
    final int tr = (onSurface.r * 255.0).round().clamp(0, 255);
    final int tg = (onSurface.g * 255.0).round().clamp(0, 255);
    final int tb = (onSurface.b * 255.0).round().clamp(0, 255);
    final String textRgba = 'rgb($tr, $tg, $tb)';

    final Color bgColor =
        appModel.overrideDictionaryColor ?? theme.colorScheme.surface;
    final int br = (bgColor.r * 255.0).round().clamp(0, 255);
    final int bg = (bgColor.g * 255.0).round().clamp(0, 255);
    final int bb = (bgColor.b * 255.0).round().clamp(0, 255);
    final String bgRgb = 'rgb($br, $bg, $bb)';

    final bool needsScrollCheck = widget.onScrolledToBottom != null;
    final String renderCall =
        isLoadMore ? 'window.renderPopup(true);' : 'window.renderPopup();';
    final swInject = Stopwatch()..start();
    _controller!.evaluateJavascript(source: '''
      document.documentElement.setAttribute('data-theme', '${isDark ? 'dark' : 'light'}');
      document.documentElement.style.setProperty('--hoshi-primary-highlight', '$primaryRgba');
      document.documentElement.style.setProperty('--text-color', '$textRgba');
      document.documentElement.style.setProperty('--background-color', '$bgRgb');
      window.audioSources = $audioSourcesJson;
      window.needsAudio = true;
      window.deduplicatePitchAccents = $deduplicatePitch;
      window.harmonicFrequency = $harmonicFreq;
      window.showExpressionTags = $showExprTags;
      window.collapseDictionaries = $collapseDict;
      window.collapsedDictionaryNames = ${jsonEncode(appModel.dictionaries.where((d) => d.isCollapsed(appModel.targetLanguage)).map((d) => d.name).toList())};
      window.lookupEntries = $entriesJson;
      window.dictionaryStyles = $stylesJson;
      window.globalDictCSS = ${jsonEncode(appModel.globalDictCSS)};
      window.customDictCSS = ${jsonEncode(appModel.customDictCSS)};
      $renderCall
      ${needsScrollCheck ? _scrollCheckJs : ""}
    ''').then((_) {
      swInject.stop();
      debugPrint(
          '[dict-perf] evaluateJavascript: ${swInject.elapsedMilliseconds}ms');
    });
  }

  static String _colorToHex(Color c) {
    final int r = (c.r * 255).round().clamp(0, 255);
    final int g = (c.g * 255).round().clamp(0, 255);
    final int b = (c.b * 255).round().clamp(0, 255);
    return '#${r.toRadixString(16).padLeft(2, '0')}'
        '${g.toRadixString(16).padLeft(2, '0')}'
        '${b.toRadixString(16).padLeft(2, '0')}';
  }

  // NavigateToString() uses about:blank origin — relative URLs can't resolve.
  // Read popup assets from disk once, embed inline in the HTML string.
  static String? _winCss;
  static String? _winDictMediaJs;
  static String? _winSelectionJs;
  static String? _winPopupJs;
  static bool _winAssetsLoadFailed = false;

  static void _ensureWindowsAssetsLoaded() {
    if (_winCss != null || _winAssetsLoadFailed) return;
    try {
      _winCss = _readPopupAsset('popup.css');
      _winDictMediaJs = _readPopupAsset('dict-media.js');
      _winSelectionJs = _readPopupAsset('selection.js');
      _winPopupJs = _readPopupAsset('popup.js');
    } catch (e, stack) {
      _winAssetsLoadFailed = true;
      ErrorLogService.instance
          .log('PopupWebView._ensureWindowsAssetsLoaded', e, stack);
    }
  }

  static String _readPopupAsset(String name) {
    final content = File(
      Uri.parse(webViewAssetUrl('assets/popup/$name')).toFilePath(),
    ).readAsStringSync();
    return content.replaceAll('</script', r'<\/script');
  }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final appModel = ref.read(appProvider);
    final Color bgColor = appModel.overrideDictionaryColor ??
        Theme.of(context).colorScheme.surface;
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final String bgHex = _colorToHex(bgColor);
    final String themeAttr = isDark ? 'dark' : 'light';

    InAppWebViewInitialData? winData;
    if (Platform.isWindows) {
      _ensureWindowsAssetsLoaded();
      if (_winCss != null) {
        winData = InAppWebViewInitialData(
          data: '<!DOCTYPE html>'
              '<html data-theme="$themeAttr" style="--background-color:$bgHex">'
              '<head>'
              '<meta name="viewport" content="width=device-width,initial-scale=1.0,maximum-scale=1.0,user-scalable=no">'
              '<style>${_winCss!.replaceAll('</style', r'<\/style')}</style>'
              '<script>$_winDictMediaJs</script>'
              '<script>$_winSelectionJs</script>'
              '<script>$_winPopupJs</script>'
              '</head>'
              '<body>'
              '<div id="entries-container"></div>'
              '<div class="overlay">'
              '<div class="overlay-close" onclick="closeOverlay()">×</div>'
              '<div class="overlay-content"></div>'
              '</div>'
              '</body></html>',
          mimeType: 'text/html',
          encoding: 'utf-8',
        );
      }
    }

    return InAppWebView(
      initialData: winData,
      initialUrlRequest: winData != null
          ? null
          : URLRequest(
              url: WebUri(webViewAssetUrl('assets/popup/popup.html')),
            ),
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
                widget.onTextSelected?.call(text, Rect.zero);
              }
            },
          ),
        ],
      ),
      gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
        Factory<LongPressGestureRecognizer>(() => LongPressGestureRecognizer()),
        Factory<VerticalDragGestureRecognizer>(
            () => VerticalDragGestureRecognizer()),
      },
      initialSettings: InAppWebViewSettings(
        transparentBackground: true,
        supportZoom: false,
        horizontalScrollBarEnabled: false,
        allowFileAccessFromFileURLs: true,
        allowUniversalAccessFromFileURLs: true,
        useShouldInterceptRequest: true,
        resourceCustomSchemes: dictionaryMediaCustomSchemes,
      ),
      shouldInterceptRequest: (controller, request) async {
        return dictionaryMediaWebResourceResponse(request.url);
      },
      onWebViewCreated: (controller) {
        _controller = controller;

        controller.addJavaScriptHandler(
          handlerName: 'tapOutside',
          callback: (_) {
            widget.onTapOutside?.call();
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'scrolledToBottom',
          callback: (_) {
            widget.onScrolledToBottom?.call();
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'popupRendered',
          callback: (_) {},
        );

        controller.addJavaScriptHandler(
          handlerName: 'mineEntry',
          callback: (args) async {
            if (args.isNotEmpty &&
                args[0] is Map &&
                widget.onMineEntry != null) {
              final fields = Map<String, String>.from(
                (args[0] as Map)
                    .map((k, v) => MapEntry(k.toString(), v.toString())),
              );
              return widget.onMineEntry!(fields);
            }
            return false;
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'duplicateCheck',
          callback: (args) async {
            if (args.isNotEmpty &&
                args[0] is Map &&
                widget.onDuplicateCheck != null) {
              final data = args[0] as Map;
              final expression = data['expression']?.toString() ?? '';
              final reading = data['reading']?.toString() ?? '';
              if (expression.isEmpty) return false;
              return widget.onDuplicateCheck!(expression, reading);
            }
            return false;
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'textSelected',
          callback: (args) async {
            if (args.isNotEmpty && args[0] is String) {
              final text = args[0] as String;
              if (text.isNotEmpty) {
                Rect localRect = Rect.zero;
                if (args.length > 1 && args[1] is Map) {
                  final r = args[1] as Map;
                  localRect = Rect.fromLTWH(
                    (r['x'] as num?)?.toDouble() ?? 0,
                    (r['y'] as num?)?.toDouble() ?? 0,
                    (r['width'] as num?)?.toDouble() ?? 1,
                    (r['height'] as num?)?.toDouble() ?? 1,
                  );
                }
                widget.onTextSelected?.call(text, localRect);
              }
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
          handlerName: 'onLinkClick',
          callback: (args) {
            if (args.isNotEmpty) {
              final text = args[0].toString();
              if (text.isNotEmpty) {
                Rect localRect = Rect.zero;
                if (args.length > 1 && args[1] is Map) {
                  final r = args[1] as Map;
                  localRect = Rect.fromLTWH(
                    (r['x'] as num?)?.toDouble() ?? 0,
                    (r['y'] as num?)?.toDouble() ?? 0,
                    (r['width'] as num?)?.toDouble() ?? 1,
                    (r['height'] as num?)?.toDouble() ?? 1,
                  );
                }
                widget.onLinkClick?.call(text, localRect);
              }
            }
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'queryLocalAudio',
          callback: (args) async {
            if (args.isEmpty || args[0] is! Map) return null;
            final data = args[0] as Map;
            final expression = data['expression']?.toString() ?? '';
            final reading = data['reading']?.toString() ?? '';
            if (expression.isEmpty) return null;
            final appModel = ref.read(appProvider);
            if (!appModel.localAudioEnabled) return null;
            final info =
                await TtsChannel.instance.queryLocalAudio(expression, reading);
            if (info == null) return null;
            final int dbIndex = (info['dbIndex'] as int?) ?? 0;
            final path = await TtsChannel.instance.extractLocalAudio(
              info['file']! as String,
              info['source']! as String,
              dbIndex: dbIndex,
            );
            return path;
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'resolveWordAudio',
          callback: (args) async {
            if (args.isEmpty || args[0] is! Map) return null;
            final data = args[0] as Map;
            final expression = data['expression']?.toString() ?? '';
            final reading = data['reading']?.toString() ?? '';
            if (expression.isEmpty) return null;
            return _resolveWordAudio(expression, reading);
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'playWordAudio',
          callback: (args) async {
            String url = '';
            if (args.isNotEmpty && args[0] is Map) {
              final data = args[0] as Map;
              url = data['url']?.toString() ?? '';
            }
            if (url.isNotEmpty && url.startsWith('file://')) {
              final filePath = Uri.parse(url).toFilePath();
              return TtsChannel.instance.playFile(filePath);
            }
            if (url.isNotEmpty && url.startsWith('/')) {
              return TtsChannel.instance.playFile(url);
            }
            if (url.isNotEmpty && url.startsWith('http')) {
              return TtsChannel.instance.playUrl(url);
            }
            return false;
          },
        );
      },
      onLoadStop: (controller, url) {
        _ready = true;
        _pushResults();
      },
      onConsoleMessage: (controller, consoleMessage) {
        final msg = consoleMessage.message;
        debugPrint('[PopupWebView] $msg');
        if (msg.startsWith('[LONGPRESS]')) {
          ErrorLogService.instance.log('PopupLongPress', msg);
        } else if (msg.startsWith('[RENDER_CONTENT]') ||
            msg.startsWith('[RICHTEXT]') ||
            msg.startsWith('[GLOSS_SECTION]') ||
            msg.startsWith('[RICHTEXT_HTML]')) {
          ErrorLogService.instance.log('PopupDebug', msg);
        }
      },
      onLoadResourceWithCustomScheme: (controller, request) async {
        return dictionaryMediaCustomSchemeResponse(request.url);
      },
    );
  }

  static String buildLookupEntriesJson(DictionarySearchResult result) {
    final Map<String, Map<String, dynamic>> grouped = {};
    final Map<String, Set<String>> seenFrequencies = {};
    final Map<String, Set<String>> seenPitches = {};

    for (final entry in result.entries) {
      final key = '${entry.word}\n${entry.reading}';
      final extraData = _decodeExtra(entry);
      if (!grouped.containsKey(key)) {
        grouped[key] = {
          'expression': entry.word,
          'reading': entry.reading,
          'matched': extraData?['matched'] ?? entry.word,
          'rules': <String>[],
          'deinflectionTrace': <Map<String, String>>[],
          'glossaries': <Map<String, dynamic>>[],
          'frequencies': <Map<String, dynamic>>[],
          'pitches': <Map<String, dynamic>>[],
        };
        seenFrequencies[key] = <String>{};
        seenPitches[key] = <String>{};
      }

      _mergeLookupMetadata(
        group: grouped[key]!,
        extraData: extraData,
        seenFrequencies: seenFrequencies[key]!,
        seenPitches: seenPitches[key]!,
      );

      dynamic contentValue;
      try {
        contentValue = jsonDecode(entry.meaning);
      } catch (e, stack) {
        ErrorLogService.instance.log('DictPopupWebview.meaning', e, stack);
        contentValue = entry.meaning;
      }

      grouped[key]!['glossaries'].add({
        'dictionary': entry.dictionaryName,
        'content': contentValue,
        'definitionTags': extraData?['definitionTags']?.toString() ?? '',
        'termTags': extraData?['termTags']?.toString() ?? '',
      });
    }

    return jsonEncode(grouped.values.toList());
  }

  static Map<String, dynamic>? _decodeExtra(DictionaryEntry entry) {
    if (entry.extra.isEmpty) return null;
    try {
      return jsonDecode(entry.extra) as Map<String, dynamic>;
    } catch (e, stack) {
      ErrorLogService.instance.log('DictPopupWebview.extraData', e, stack);
      return null;
    }
  }

  static void _mergeLookupMetadata({
    required Map<String, dynamic> group,
    required Map<String, dynamic>? extraData,
    required Set<String> seenFrequencies,
    required Set<String> seenPitches,
  }) {
    if (extraData == null) return;

    final matched = extraData['matched'] as String?;
    if (matched != null &&
        matched.isNotEmpty &&
        group['matched'] == group['expression']) {
      group['matched'] = matched;
    }

    final trace = group['deinflectionTrace'] as List<Map<String, String>>;
    if (trace.isEmpty && extraData.containsKey('deinflected')) {
      final traceMatched = matched ?? '';
      final deinflected = extraData['deinflected'] as String? ?? '';
      if (traceMatched != deinflected && deinflected.isNotEmpty) {
        trace.add({'name': '$traceMatched → $deinflected', 'description': ''});
      }
    }

    _appendUniqueMetadata(
      target: group['frequencies'] as List<Map<String, dynamic>>,
      values: _convertFrequencies(extraData),
      seen: seenFrequencies,
    );
    _appendUniqueMetadata(
      target: group['pitches'] as List<Map<String, dynamic>>,
      values: _convertPitches(extraData),
      seen: seenPitches,
    );
  }

  static void _appendUniqueMetadata({
    required List<Map<String, dynamic>> target,
    required List<Map<String, dynamic>> values,
    required Set<String> seen,
  }) {
    for (final value in values) {
      final key = jsonEncode(value);
      if (seen.add(key)) {
        target.add(value);
      }
    }
  }

  static List<Map<String, dynamic>> _convertFrequencies(
      Map<String, dynamic>? extraData) {
    if (extraData == null || !extraData.containsKey('frequencies')) return [];
    final freqs = extraData['frequencies'] as List<dynamic>? ?? [];
    return freqs.map((f) {
      final values = f['values'] as List<dynamic>? ?? [];
      return {
        'dictionary': f['dictName'] ?? '',
        'frequencies': values
            .map((v) => {
                  'value': v['value'] ?? 0,
                  'displayValue': v['display']?.toString() ?? '',
                })
            .toList(),
      };
    }).toList();
  }

  static List<Map<String, dynamic>> _convertPitches(
      Map<String, dynamic>? extraData) {
    if (extraData == null || !extraData.containsKey('pitches')) return [];
    final pitches = extraData['pitches'] as List<dynamic>? ?? [];
    return pitches.map((p) {
      return {
        'dictionary': p['dictName'] ?? '',
        'pitchPositions': p['positions'] ?? [],
      };
    }).toList();
  }

  static Future<void> _openExternalLink(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) {
      return;
    }
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}
