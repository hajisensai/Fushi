import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/dictionary.dart';
import 'package:hibiki/src/dictionary/hoshidicts.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/utils.dart';

class DictionaryPopupWebView extends ConsumerStatefulWidget {
  const DictionaryPopupWebView({
    super.key,
    required this.result,
    this.onTextSelected,
    this.onMineEntry,
  });

  final DictionarySearchResult result;
  final void Function(String text)? onTextSelected;
  final void Function(Map<String, String> fields)? onMineEntry;

  @override
  ConsumerState<DictionaryPopupWebView> createState() => DictionaryPopupWebViewState();
}

class DictionaryPopupWebViewState extends ConsumerState<DictionaryPopupWebView> {
  InAppWebViewController? _controller;
  bool _ready = false;

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
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final appModel = ref.read(appProvider);
    final deduplicatePitch = appModel.deduplicatePitchAccents;
    final harmonicFreq = appModel.harmonicFrequency;
    final audioSourcesJson = jsonEncode(appModel.audioSources);
    final localAudioEnabled = appModel.localAudioEnabled;

    _controller!.evaluateJavascript(source: '''
      document.documentElement.setAttribute('data-theme', '${isDark ? 'dark' : 'light'}');
      window.audioSources = $audioSourcesJson;
      window.deduplicatePitchAccents = $deduplicatePitch;
      window.harmonicFrequency = $harmonicFreq;
      window.localAudioEnabled = $localAudioEnabled;
      window.lookupEntries = $entriesJson;
      window.dictionaryStyles = $stylesJson;
      window.renderPopup();
    ''');
  }

  @override
  Widget build(BuildContext context) {
    return InAppWebView(
      initialUrlRequest: URLRequest(
        url: WebUri(
            'file:///android_asset/flutter_assets/assets/popup/popup.html'),
      ),
      initialSettings: InAppWebViewSettings(
        transparentBackground: true,
        supportZoom: false,
        verticalScrollBarEnabled: true,
        horizontalScrollBarEnabled: false,
        allowFileAccessFromFileURLs: true,
        allowUniversalAccessFromFileURLs: true,
        useHybridComposition: true,
        useShouldInterceptRequest: true,
      ),
      shouldInterceptRequest: (controller, request) async {
        final url = request.url;
        if (url.scheme == 'image' && HoshiDicts.isInitialized) {
          final dictName = url.queryParameters['dictionary'] ?? '';
          final mediaPath = url.queryParameters['path'] ?? '';
          if (dictName.isNotEmpty && mediaPath.isNotEmpty) {
            final data =
                HoshiDicts.instance.getMediaFile(dictName, mediaPath);
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
      onWebViewCreated: (controller) {
        _controller = controller;

        controller.addJavaScriptHandler(
          handlerName: 'tapOutside',
          callback: (_) {},
        );

        controller.addJavaScriptHandler(
          handlerName: 'popupRendered',
          callback: (args) {},
        );

        controller.addJavaScriptHandler(
          handlerName: 'mineEntry',
          callback: (args) async {
            if (args.isNotEmpty && args[0] is Map && widget.onMineEntry != null) {
              final fields = Map<String, String>.from(
                (args[0] as Map)
                    .map((k, v) => MapEntry(k.toString(), v.toString())),
              );
              widget.onMineEntry!(fields);
            }
            return false;
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'duplicateCheck',
          callback: (args) async => false,
        );

        controller.addJavaScriptHandler(
          handlerName: 'textSelected',
          callback: (args) {
            if (args.isNotEmpty && args[0] is String) {
              final text = args[0] as String;
              if (text.isNotEmpty) {
                widget.onTextSelected?.call(text);
              }
            }
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'openLink',
          callback: (args) {},
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
            final path = await TtsChannel.instance.queryLocalAudio(expression, reading);
            return path;
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
              TtsChannel.instance.playFile(filePath);
              return;
            }
            if (url.isNotEmpty && url.startsWith('/')) {
              TtsChannel.instance.playFile(url);
              return;
            }
            if (url.isNotEmpty && url.startsWith('http')) {
              TtsChannel.instance.playUrl(url);
              return;
            }
            final result = widget.result;
            if (result.entries.isNotEmpty) {
              final entry = result.entries.first;
              final word = entry.reading.isNotEmpty ? entry.reading : entry.word;
              if (word.isNotEmpty) {
                TtsChannel.instance.speak(word);
              }
            }
          },
        );
      },
      onLoadStop: (controller, url) {
        _ready = true;
        _pushResults();
      },
    );
  }

  static String buildLookupEntriesJson(DictionarySearchResult result) {
    final Map<String, Map<String, dynamic>> grouped = {};

    for (final entry in result.entries) {
      final key = '${entry.word}\n${entry.reading}';
      if (!grouped.containsKey(key)) {
        Map<String, dynamic>? extraData;
        if (entry.extra != null && entry.extra!.isNotEmpty) {
          try {
            extraData = jsonDecode(entry.extra!) as Map<String, dynamic>;
          } catch (_) {}
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
      } catch (_) {
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
    if (entry.extra == null || entry.extra!.isEmpty) return '';
    try {
      final data = jsonDecode(entry.extra!) as Map<String, dynamic>;
      return data[field]?.toString() ?? '';
    } catch (_) {
      return '';
    }
  }

  static List<Map<String, dynamic>> _convertFrequencies(
      Map<String, dynamic>? extraData) {
    if (extraData == null || !extraData.containsKey('frequencies')) return [];
    final freqs = extraData['frequencies'] as List<dynamic>? ?? [];
    return freqs.map((f) {
      final values = (f['values'] as List<dynamic>? ?? []);
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
}
