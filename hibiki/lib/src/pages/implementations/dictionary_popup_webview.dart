import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/dictionary.dart';
import 'package:hibiki/src/dictionary/hoshidicts.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/utils.dart';
import 'package:url_launcher/url_launcher.dart';

class DictionaryPopupWebView extends ConsumerStatefulWidget {
  const DictionaryPopupWebView({
    required this.result, super.key,
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

    final entriesJson = buildLookupEntriesJson(widget.result);
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
    final collapsedNames = appModel.dictionaries
        .where((d) => d.isCollapsed(appModel.targetLanguage))
        .map((d) => d.name)
        .toList();
    final collapsedNamesJson = jsonEncode(collapsedNames);
    final audioSourcesJson = jsonEncode(appModel.enabledAudioSources);

    final Color onSurface = theme.colorScheme.onSurface;
    final int tr = (onSurface.r * 255.0).round().clamp(0, 255);
    final int tg = (onSurface.g * 255.0).round().clamp(0, 255);
    final int tb = (onSurface.b * 255.0).round().clamp(0, 255);
    final double ta = onSurface.a;
    final String textRgba = 'rgba($tr, $tg, $tb, ${ta.toStringAsFixed(2)})';

    final Color? bgOverride = appModel.overrideDictionaryColor;
    String bgCssOverride = '';
    if (bgOverride != null) {
      final int br = (bgOverride.r * 255.0).round().clamp(0, 255);
      final int bg = (bgOverride.g * 255.0).round().clamp(0, 255);
      final int bb = (bgOverride.b * 255.0).round().clamp(0, 255);
      bgCssOverride = "document.documentElement.style.setProperty('--background-color', 'rgb($br, $bg, $bb)');";
    }

    final bool needsScrollCheck = widget.onScrolledToBottom != null;
    _controller!.evaluateJavascript(source: '''
      document.documentElement.setAttribute('data-theme', '${isDark ? 'dark' : 'light'}');
      document.documentElement.style.setProperty('--hoshi-primary-highlight', '$primaryRgba');
      document.documentElement.style.setProperty('--text-color', '$textRgba');
      $bgCssOverride
      window.audioSources = $audioSourcesJson;
      window.needsAudio = true;
      window.deduplicatePitchAccents = $deduplicatePitch;
      window.harmonicFrequency = $harmonicFreq;
      window.collapseDictionaries = $collapseDict;
      window.collapsedDictionaryNames = $collapsedNamesJson;
      window.lookupEntries = $entriesJson;
      window.dictionaryStyles = $stylesJson;
      window.globalDictCSS = ${jsonEncode(appModel.globalDictCSS)};
      window.customDictCSS = ${jsonEncode(appModel.customDictCSS)};
      window.renderPopup();
      ${needsScrollCheck ? _scrollCheckJs : ""}
    ''');
  }

  @override
  Widget build(BuildContext context) {
    return InAppWebView(
      gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
        Factory<LongPressGestureRecognizer>(() => LongPressGestureRecognizer()),
        Factory<VerticalDragGestureRecognizer>(
            () => VerticalDragGestureRecognizer()),
      },
      initialUrlRequest: URLRequest(
        url: WebUri(
            'file:///android_asset/flutter_assets/assets/popup/popup.html'),
      ),
      initialSettings: InAppWebViewSettings(
        transparentBackground: true,
        supportZoom: false,
        horizontalScrollBarEnabled: false,
        allowFileAccessFromFileURLs: true,
        allowUniversalAccessFromFileURLs: true,
        useShouldInterceptRequest: true,
      ),
      shouldInterceptRequest: (controller, request) async {
        final url = request.url;
        if (url.scheme == 'image' && HoshiDicts.isInitialized) {
          final dictName = url.queryParameters['dictionary'] ?? '';
          final mediaPath = url.queryParameters['path'] ?? '';
          debugPrint('[PopupWebView] image request: dict=$dictName path=$mediaPath');
          if (dictName.isNotEmpty && mediaPath.isNotEmpty) {
            try {
              final data = HoshiDicts.instance.getMediaFile(dictName, mediaPath);
              debugPrint('[PopupWebView] image response: ${data != null ? "${data.length} bytes" : "NULL"}');
              if (data != null) {
                final mime = _mimeTypeForPath(mediaPath);
                return WebResourceResponse(
                  contentType: mime,
                  contentEncoding: mime.startsWith('text/') ? 'utf-8' : null,
                  statusCode: 200,
                  reasonPhrase: 'OK',
                  data: data,
                );
              }
            } catch (e) {
              debugPrint('[PopupWebView] image error: $e');
            }
          }
          return WebResourceResponse(
            contentType: 'text/plain',
            statusCode: 404,
            reasonPhrase: 'Not Found',
            data: Uint8List(0),
          );
        }
        if (url.scheme == 'dictmedia' && HoshiDicts.isInitialized) {
          final dictName = url.queryParameters['dictionary'] ?? '';
          final mediaPath = Uri.decodeComponent(url.host);
          if (dictName.isNotEmpty && mediaPath.isNotEmpty) {
            final data = HoshiDicts.instance.getMediaFile(dictName, mediaPath);
            if (data != null) {
              return WebResourceResponse(
                contentType: 'text/css',
                statusCode: 200,
                reasonPhrase: 'OK',
                data: data,
              );
            }
          }
        }
        return null;
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
          callback: (args) {},
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
          handlerName: 'copyText',
          callback: (args) async {
            if (args.isEmpty) {
              return false;
            }
            final text = args[0].toString();
            if (text.isEmpty) {
              return false;
            }
            await Clipboard.setData(ClipboardData(text: text));
            return true;
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
            final path = await TtsChannel.instance
                .extractLocalAudio(
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
              final filePath = url.replaceFirst('file://', '');
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
        if (msg.startsWith('[IMG')) {
          ErrorLogService.instance.log('PopupImage', msg);
        } else if (msg.startsWith('[LONGPRESS]')) {
          ErrorLogService.instance.log('PopupLongPress', msg);
        } else if (msg.startsWith('[RENDER_CONTENT]') || msg.startsWith('[RICHTEXT]') || msg.startsWith('[GLOSS_SECTION]') || msg.startsWith('[RICHTEXT_HTML]')) {
          ErrorLogService.instance.log('PopupDebug', msg);
        }
      },
      onLoadResourceWithCustomScheme: (controller, request) async {
        final url = request.url;
        debugPrint('[PopupWebView] customScheme: ${url.scheme} ${url.toString().substring(0, url.toString().length.clamp(0, 120))}');
        return null;
      },
    );
  }

  static String buildLookupEntriesJson(DictionarySearchResult result) {
    final Map<String, Map<String, dynamic>> grouped = {};

    for (final entry in result.entries) {
      final key = '${entry.word}\n${entry.reading}';
      if (!grouped.containsKey(key)) {
        Map<String, dynamic>? extraData;
        if (entry.extra.isNotEmpty) {
          try {
            extraData = jsonDecode(entry.extra) as Map<String, dynamic>;
          } catch (e, stack) {
            ErrorLogService.instance.log('DictPopupWebview.extraData', e, stack);
          }
        }

        grouped[key] = {
          'expression': entry.word,
          'reading': entry.reading,
          'matched': extraData?['matched'] ?? entry.word,
          'rules': <String>[],
          'deinflectionTrace': <Map<String, String>>[],
          'glossaries': <Map<String, dynamic>>[],
          'frequencies': _convertFrequencies(extraData),
          'pitches': _convertPitches(extraData),
        };

        if (extraData != null && extraData.containsKey('deinflected')) {
          final matched = extraData['matched'] as String? ?? '';
          final deinflected = extraData['deinflected'] as String? ?? '';
          if (matched != deinflected && deinflected.isNotEmpty) {
            grouped[key]!['deinflectionTrace'] = [
              {'name': '$matched → $deinflected', 'description': ''}
            ];
          }
        }
      }

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
        'definitionTags': _getExtraField(entry, 'definitionTags'),
        'termTags': _getExtraField(entry, 'termTags'),
      });
    }

    return jsonEncode(grouped.values.toList());
  }

  static String _getExtraField(DictionaryEntry entry, String field) {
    if (entry.extra.isEmpty) return '';
    try {
      final data = jsonDecode(entry.extra) as Map<String, dynamic>;
      return data[field]?.toString() ?? '';
    } catch (e, stack) {
      ErrorLogService.instance.log('DictPopupWebview.getExtraField', e, stack);
      return '';
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

  static Future<void> _openExternalLink(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) {
      return;
    }
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}
