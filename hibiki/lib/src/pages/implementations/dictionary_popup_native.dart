import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/dictionary.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';
import 'package:hibiki/utils.dart';

class _GroupedEntry {

  _GroupedEntry({
    required this.expression,
    required this.reading,
    required this.matched,
    required this.deinflectionTrace,
    required this.glossaries,
  });
  final String expression;
  final String reading;
  final String matched;
  final List<Map<String, String>> deinflectionTrace;
  final List<_GlossaryItem> glossaries;
}

class _GlossaryItem {

  _GlossaryItem({
    required this.dictionary,
    required this.content,
    required this.definitionTags,
  });
  final String dictionary;
  final String content;
  final String definitionTags;
}

class DictionaryPopupNative extends ConsumerStatefulWidget {
  const DictionaryPopupNative({
    required this.result, super.key,
    this.onTextSelected,
    this.onMineEntry,
  });

  final DictionarySearchResult result;
  final void Function(String text)? onTextSelected;
  final void Function(Map<String, String> fields)? onMineEntry;

  @override
  ConsumerState<DictionaryPopupNative> createState() =>
      _DictionaryPopupNativeState();
}

class _DictionaryPopupNativeState
    extends ConsumerState<DictionaryPopupNative> {
  List<_GroupedEntry> _grouped = [];

  @override
  void initState() {
    super.initState();
    _grouped = _groupEntries(widget.result);
  }

  @override
  void didUpdateWidget(DictionaryPopupNative oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.result != widget.result) {
      _grouped = _groupEntries(widget.result);
    }
  }

  static List<_GroupedEntry> _groupEntries(DictionarySearchResult result) {
    final Map<String, _GroupedEntry> grouped = {};

    for (final entry in result.entries) {
      final key = '${entry.word}\n${entry.reading}';
      if (!grouped.containsKey(key)) {
        Map<String, dynamic>? extraData;
        if (entry.extra.isNotEmpty) {
          try {
            extraData = jsonDecode(entry.extra) as Map<String, dynamic>;
          } catch (e, stack) {
            ErrorLogService.instance.log('DictPopupNative.extraData', e, stack);
          }
        }

        final trace = <Map<String, String>>[];
        if (extraData != null && extraData.containsKey('deinflected')) {
          final matched = extraData['matched'] as String? ?? '';
          final deinflected = extraData['deinflected'] as String? ?? '';
          if (matched != deinflected && deinflected.isNotEmpty) {
            trace.add({'name': '$matched → $deinflected'});
          }
        }

        grouped[key] = _GroupedEntry(
          expression: entry.word,
          reading: entry.reading,
          matched: extraData?['matched'] as String? ?? entry.word,
          deinflectionTrace: trace,
          glossaries: [],
        );
      }

      String contentText;
      try {
        final parsed = jsonDecode(entry.meaning);
        contentText = _structuredContentToText(parsed);
      } catch (e, stack) {
        ErrorLogService.instance.log('DictPopupNative.meaning', e, stack);
        contentText = entry.meaning;
      }

      String defTags = '';
      if (entry.extra.isNotEmpty) {
        try {
          final data = jsonDecode(entry.extra) as Map<String, dynamic>;
          defTags = data['definitionTags']?.toString() ?? '';
        } catch (e, stack) {
          ErrorLogService.instance.log('DictPopupNative.definitionTags', e, stack);
        }
      }

      grouped[key]!.glossaries.add(_GlossaryItem(
        dictionary: entry.dictionaryName,
        content: contentText,
        definitionTags: defTags,
      ));
    }

    return grouped.values.toList();
  }

  static String _structuredContentToText(dynamic content) {
    if (content is String) return content;
    if (content is List) {
      return content.map(_structuredContentToText).join();
    }
    if (content is Map) {
      final tag = content['tag'];
      final inner = content['content'];
      final childText = inner != null ? _structuredContentToText(inner) : '';
      if (tag == 'br') return '\n';
      if (tag == 'li') return '• $childText\n';
      if (tag == 'img') return content['description'] ?? '';
      return childText;
    }
    return content?.toString() ?? '';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black;
    final subColor = isDark ? Colors.white70 : Colors.black54;
    final tagBg = isDark ? Colors.white12 : Colors.black.withValues(alpha: 0.08);

    if (_grouped.isEmpty) {
      return const SizedBox.shrink();
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      itemCount: _grouped.length,
      separatorBuilder: (_, __) => Divider(
        height: 1,
        color: isDark ? Colors.white24 : Colors.black12,
      ),
      itemBuilder: (context, idx) {
        final entry = _grouped[idx];
        return _buildEntry(entry, idx, textColor, subColor, tagBg);
      },
    );
  }

  Widget _buildEntry(
    _GroupedEntry entry,
    int idx,
    Color textColor,
    Color subColor,
    Color tagBg,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(entry, idx, textColor, subColor),
          if (entry.deinflectionTrace.isNotEmpty)
            _buildDeinflection(entry, tagBg, subColor),
          const SizedBox(height: 2),
          ..._buildGlossaries(entry, textColor, subColor, tagBg),
        ],
      ),
    );
  }

  Widget _buildHeader(
    _GroupedEntry entry,
    int idx,
    Color textColor,
    Color subColor,
  ) {
    return Row(
      children: [
        Expanded(
          child: _buildExpressionWithReading(entry, textColor, subColor),
        ),
        _buildMineButton(entry, idx, subColor),
      ],
    );
  }

  Widget _buildExpressionWithReading(
    _GroupedEntry entry,
    Color textColor,
    Color subColor,
  ) {
    if (entry.reading.isNotEmpty && entry.reading != entry.expression) {
      return _FuriganaText(
        expression: entry.expression,
        reading: entry.reading,
        expressionStyle: TextStyle(fontSize: 26, color: textColor),
        readingStyle: TextStyle(fontSize: 12, color: subColor),
      );
    }
    return Text(
      entry.expression,
      style: TextStyle(fontSize: 26, color: textColor),
    );
  }

  Widget _buildMineButton(_GroupedEntry entry, int idx, Color subColor) {
    return GestureDetector(
      onTap: () {
        if (widget.onMineEntry != null) {
          widget.onMineEntry!({
            'expression': entry.expression,
            'reading': entry.reading,
          });
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Text('+', style: TextStyle(fontSize: 18, color: subColor)),
      ),
    );
  }

  Widget _buildDeinflection(
    _GroupedEntry entry,
    Color tagBg,
    Color subColor,
  ) {
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Wrap(
        spacing: 2,
        children: entry.deinflectionTrace.map((trace) {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            decoration: BoxDecoration(
              color: tagBg,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              trace['name'] ?? '',
              style: TextStyle(fontSize: 11, color: subColor),
            ),
          );
        }).toList(),
      ),
    );
  }

  List<Widget> _buildGlossaries(
    _GroupedEntry entry,
    Color textColor,
    Color subColor,
    Color tagBg,
  ) {
    final Map<String, List<_GlossaryItem>> byDict = {};
    for (final g in entry.glossaries) {
      (byDict[g.dictionary] ??= []).add(g);
    }

    return byDict.entries.map((e) {
      final dictName = e.key;
      final items = e.value;

      return Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              dictName,
              style: TextStyle(fontSize: 10, color: subColor),
            ),
            const SizedBox(height: 2),
            ...items.asMap().entries.map((itemEntry) {
              final item = itemEntry.value;
              final num = items.length > 1 ? '${itemEntry.key + 1}. ' : '';
              return Padding(
                padding: const EdgeInsets.only(left: 8, bottom: 2),
                child: GestureDetector(
                  onTap: () => _onGlossaryTap(item.content),
                  child: Text(
                    '$num${item.content}',
                    style: TextStyle(
                      fontSize: 14,
                      color: textColor,
                      height: 1.4,
                    ),
                  ),
                ),
              );
            }),
          ],
        ),
      );
    }).toList();
  }

  void _onGlossaryTap(String text) {
    // no-op for now; recursive lookup on tap is WebView-only
  }
}

class _FuriganaText extends StatelessWidget {
  const _FuriganaText({
    required this.expression,
    required this.reading,
    required this.expressionStyle,
    required this.readingStyle,
  });

  final String expression;
  final String reading;
  final TextStyle expressionStyle;
  final TextStyle readingStyle;

  @override
  Widget build(BuildContext context) {
    final segments = _buildFuriganaSegments(expression, reading);
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.end,
      children: segments,
    );
  }

  List<Widget> _buildFuriganaSegments(String expr, String read) {
    final kanjiPattern = RegExp('[一-鿿㐀-䶿豈-﫿々]+');
    final matches = kanjiPattern.allMatches(expr).toList();

    if (matches.isEmpty) {
      return [
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(read, style: readingStyle),
            Text(expr, style: expressionStyle),
          ],
        ),
      ];
    }

    final segments = <Widget>[];
    int exprIdx = 0;
    int readIdx = 0;

    for (final match in matches) {
      if (match.start > exprIdx) {
        final kana = expr.substring(exprIdx, match.start);
        final kanaLen = kana.length;
        if (readIdx + kanaLen <= read.length) {
          readIdx += kanaLen;
        }
        segments.add(
          Padding(
            padding: EdgeInsets.only(top: readingStyle.fontSize! + 2),
            child: Text(kana, style: expressionStyle),
          ),
        );
      }

      final kanji = match.group(0)!;
      final nextKanaInExpr = match.end < expr.length ? expr[match.end] : null;
      int readEnd = readIdx;
      if (nextKanaInExpr != null) {
        final nextPos = read.indexOf(nextKanaInExpr, readIdx + 1);
        if (nextPos > readIdx) {
          readEnd = nextPos;
        } else {
          readEnd = read.length;
        }
      } else {
        readEnd = read.length;
      }

      final furigana =
          readEnd <= read.length ? read.substring(readIdx, readEnd) : '';
      readIdx = readEnd;

      segments.add(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(furigana, style: readingStyle, textAlign: TextAlign.center),
            Text(kanji, style: expressionStyle),
          ],
        ),
      );

      exprIdx = match.end;
    }

    if (exprIdx < expr.length) {
      final trailing = expr.substring(exprIdx);
      segments.add(
        Padding(
          padding: EdgeInsets.only(top: readingStyle.fontSize! + 2),
          child: Text(trailing, style: expressionStyle),
        ),
      );
    }

    return segments;
  }
}
