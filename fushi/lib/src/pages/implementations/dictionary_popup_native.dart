import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi/utils.dart';

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
  final List<DeinflectionTag> deinflectionTrace;
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
    required this.result,
    super.key,
    this.onTextSelected,
    this.onMineEntry,
    this.dictionaryDisplayNames = const <String, String>{},
  });

  final DictionarySearchResult result;

  /// 词典改名（v95）：真名 -> 显示名，只含改过名的。**由调用方传入**，而不是
  /// 在这里 `ref.read(appProvider)` 去捞——本 widget 虽是 ConsumerStatefulWidget，
  /// 但在此之前从没真正用过 ref，于是它的测试一直不套 ProviderScope。渲染路径
  /// 里读全局容器会当场 `Bad state: No ProviderScope found`，而且那是把一个
  /// 隐式的全局依赖塞进纯展示组件。数据从外面单向流进来，测试也不用陪着改。
  ///
  /// 空表 = 没人改过名 = 全部显示真名（与 v95 前逐字节一致）。
  final Map<String, String> dictionaryDisplayNames;
  final void Function(String text)? onTextSelected;
  final void Function(Map<String, String> fields)? onMineEntry;

  @override
  ConsumerState<DictionaryPopupNative> createState() =>
      _DictionaryPopupNativeState();
}

class _DictionaryPopupNativeState extends ConsumerState<DictionaryPopupNative> {
  List<_GroupedEntry> _grouped = [];

  /// 词典改名（v95）：把查词结果里的**真名**翻成用户起的显示名，只用于渲染。
  /// 分组 key（[_GroupedEntry] / `byDict`）一律仍是真名——它对齐 CSS 作用域、
  /// 隐藏/折叠集合与 Anki token，翻译了就全错位。
  ///
  /// 查不到就原样返回真名（没改过名 / 调用方没传表），不崩。
  String _dictDisplayName(String rawName) =>
      widget.dictionaryDisplayNames[rawName] ?? rawName;

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
      Map<String, dynamic>? extraData;
      if (entry.extra.isNotEmpty) {
        try {
          extraData = jsonDecode(entry.extra) as Map<String, dynamic>;
        } catch (e, stack) {
          ErrorLogService.instance.log('DictPopupNative.extraData', e, stack);
        }
      }

      final key = '${entry.word}\n${entry.reading}';
      if (!grouped.containsKey(key)) {
        // 变形标签（含语法说明）由 buildDeinflectionTags 统一生成、随 extra 送达。
        final List<DeinflectionTag> trace = extraData == null
            ? const <DeinflectionTag>[]
            : deinflectionTagsFromExtra(extraData);

        grouped[key] = _GroupedEntry(
          expression: entry.word,
          reading: entry.reading,
          matched: extraData?['matched'] as String? ?? entry.word,
          deinflectionTrace: trace,
          glossaries: [],
        );
      }

      final String contentText =
          DictionaryEntry.meaningToPlainText(entry.meaning);

      grouped[key]!.glossaries.add(_GlossaryItem(
            dictionary: entry.dictionaryName,
            content: contentText,
            definitionTags: extraData?['definitionTags']?.toString() ?? '',
          ));
    }

    return grouped.values.toList();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tokens = FushiDesignTokens.of(context);
    final textColor = cs.onSurface;
    final subColor = cs.onSurfaceVariant;
    final tagBg = cs.surfaceContainerHighest;

    if (_grouped.isEmpty) {
      return const SizedBox.shrink();
    }

    return ListView.separated(
      padding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.rowHorizontal,
        vertical: tokens.spacing.gap / 2,
      ),
      itemCount: _grouped.length,
      separatorBuilder: (_, __) => Divider(
        height: 1,
        color: tokens.surfaces.outline,
      ),
      itemBuilder: (context, idx) {
        final entry = _grouped[idx];
        return _buildEntry(entry, textColor, subColor, tagBg, tokens);
      },
    );
  }

  Widget _buildEntry(
    _GroupedEntry entry,
    Color textColor,
    Color subColor,
    Color tagBg,
    FushiDesignTokens tokens,
  ) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap / 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(entry, textColor, subColor, tokens),
          if (entry.deinflectionTrace.isNotEmpty)
            _buildDeinflection(entry, tagBg, tokens),
          SizedBox(height: tokens.spacing.gap / 4),
          ..._buildGlossaries(entry, textColor, subColor, tagBg, tokens),
        ],
      ),
    );
  }

  Widget _buildHeader(
    _GroupedEntry entry,
    Color textColor,
    Color subColor,
    FushiDesignTokens tokens,
  ) {
    return Row(
      children: [
        Expanded(
          child: _buildExpressionWithReading(
            entry,
            textColor,
            subColor,
            tokens,
          ),
        ),
        _buildMineButton(entry, subColor, tokens),
      ],
    );
  }

  Widget _buildExpressionWithReading(
    _GroupedEntry entry,
    Color textColor,
    Color subColor,
    FushiDesignTokens tokens,
  ) {
    final TextStyle expressionStyle = tokens.type.pageTitle.copyWith(
      color: textColor,
    );
    final TextStyle readingStyle = tokens.type.metadata.copyWith(
      color: subColor,
    );
    if (entry.reading.isNotEmpty && entry.reading != entry.expression) {
      return _FuriganaText(
        expression: entry.expression,
        reading: entry.reading,
        expressionStyle: expressionStyle,
        readingStyle: readingStyle,
      );
    }
    return Text(
      entry.expression,
      style: expressionStyle,
    );
  }

  Widget _buildMineButton(
    _GroupedEntry entry,
    Color subColor,
    FushiDesignTokens tokens,
  ) {
    return SizedBox(
      width: tokens.spacing.card * 2,
      height: tokens.spacing.card * 2,
      child: Center(
        child: FushiIconButton(
          icon: Icons.add_circle_outline,
          tooltip: t.creator_export_card,
          size: tokens.spacing.card + tokens.spacing.gap / 2,
          enabled: widget.onMineEntry != null,
          enabledColor: subColor,
          disabledColor: subColor.withValues(alpha: 0.38),
          padding: EdgeInsets.all(tokens.spacing.gap / 2),
          onTap: widget.onMineEntry == null
              ? null
              : () {
                  widget.onMineEntry!({
                    'expression': entry.expression,
                    'reading': entry.reading,
                  });
                },
        ),
      ),
    );
  }

  Widget _buildDeinflection(
    _GroupedEntry entry,
    Color tagBg,
    FushiDesignTokens tokens,
  ) {
    final ThemeData theme = Theme.of(context);
    final List<Widget> children = <Widget>[];
    for (int i = 0; i < entry.deinflectionTrace.length; i++) {
      final DeinflectionTag tag = entry.deinflectionTrace[i];
      // 「«」读作「来自」：右边那一层变形是接在左边这一层之上的。与 Yomitan 和
      // WebView 弹窗（popup.css 的 .deinflection-tag:not(:first-child)::before）
      // 保持同一种读法。
      if (i > 0) {
        children.add(Text(
          '«',
          style: theme.textTheme.labelSmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ));
      }
      children.add(FushiTagChip(
        label: tag.name,
        color: tagBg,
        // 没有语法说明的标签（文本变体归一的回落条目）不可点，免得点开一个空框。
        onTap:
            tag.description.isEmpty ? null : () => _showGrammarDescription(tag),
      ));
    }
    return Padding(
      padding: EdgeInsets.only(top: tokens.spacing.gap / 4),
      child: Wrap(
        spacing: tokens.spacing.gap / 4,
        runSpacing: tokens.spacing.gap / 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: children,
      ),
    );
  }

  /// 展示某一层词形变化的语法说明（来自 `assets/transforms/<lang>.json`）。
  Future<void> _showGrammarDescription(DeinflectionTag tag) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => FushiDialogFrame(
        padding: EdgeInsets.all(tokens.spacing.card),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              tag.name,
              style: Theme.of(dialogContext).textTheme.titleMedium,
            ),
            Text(
              t.dict_category_grammar,
              style: Theme.of(dialogContext).textTheme.labelSmall?.copyWith(
                    color: Theme.of(dialogContext).colorScheme.onSurfaceVariant,
                  ),
            ),
            SizedBox(height: tokens.spacing.gap),
            SelectableText(tag.description),
            SizedBox(height: tokens.spacing.gap),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: Text(t.dialog_close),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildGlossaries(
    _GroupedEntry entry,
    Color textColor,
    Color subColor,
    Color tagBg,
    FushiDesignTokens tokens,
  ) {
    final Map<String, List<_GlossaryItem>> byDict = {};
    for (final g in entry.glossaries) {
      (byDict[g.dictionary] ??= []).add(g);
    }

    return byDict.entries.map((e) {
      final dictName = e.key;
      final items = e.value;

      return Padding(
        padding: EdgeInsets.only(top: tokens.spacing.gap / 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _dictDisplayName(dictName),
              style: tokens.type.metadata.copyWith(color: subColor),
            ),
            SizedBox(height: tokens.spacing.gap / 4),
            ...items.asMap().entries.map((itemEntry) {
              final item = itemEntry.value;
              final num = items.length > 1 ? '${itemEntry.key + 1}. ' : '';
              // Glossary lines are not interactive in the native popup
              // (recursive lookup on tap is WebView-only), so there is no tap
              // target to make focusable — plain Text, no dead GestureDetector.
              return Padding(
                padding: EdgeInsetsDirectional.only(
                  start: tokens.spacing.gap,
                  bottom: tokens.spacing.gap / 4,
                ),
                child: Text(
                  '$num${item.content}',
                  style: tokens.type.listTitle.copyWith(
                    color: textColor,
                    height: 1.4,
                  ),
                ),
              );
            }),
          ],
        ),
      );
    }).toList();
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
    final double readingFontSize = readingStyle.fontSize ??
        DefaultTextStyle.of(context).style.fontSize ??
        12;
    final double readingGap = readingFontSize + 2;
    final segments = _buildFuriganaSegments(expression, reading, readingGap);
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.end,
      children: segments,
    );
  }

  List<Widget> _buildFuriganaSegments(
    String expr,
    String read,
    double readingGap,
  ) {
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
            padding: EdgeInsets.only(top: readingGap),
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
          padding: EdgeInsets.only(top: readingGap),
          child: Text(trailing, style: expressionStyle),
        ),
      );
    }

    return segments;
  }
}
