import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/utils.dart';

/// The content of the dialog used for selecting segmented units of a source
/// text.
class TextSegmentationDialogPage extends BasePage {
  /// Create an instance of this page.
  const TextSegmentationDialogPage({
    required this.sourceText,
    required this.segmentedText,
    this.onSelect,
    this.onSearch,
    super.key,
  });

  /// The original text before segmentation. This could be a sentence or a
  /// dictionary definition.
  final String sourceText;

  /// The text after segmentation.
  final List<String> segmentedText;

  /// The callback to be called for a selection to extract from the text.
  final Function(HibikiTextSelection)? onSelect;

  /// The callback to be called for a selection to perform a search on.
  final Function(HibikiTextSelection)? onSearch;

  @override
  BasePageState createState() => _TextSegmentationDialogPage();
}

class _TextSegmentationDialogPage
    extends BasePageState<TextSegmentationDialogPage> {
  final ScrollController _scrollController = ScrollController();

  final Map<int, ValueNotifier<bool>> _valuesSelected = {};

  @override
  void initState() {
    super.initState();

    widget.segmentedText.forEachIndexed((index, element) {
      _valuesSelected[index] = ValueNotifier<bool>(false);
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    for (final notifier in _valuesSelected.values) {
      notifier.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return HibikiDialogFrame(
      maxWidth: 560,
      maxHeightFactor: 0.82,
      scrollable: false,
      child: HibikiModalSheetFrame(
        title: t.text_segmentation,
        leadingIcon: Icons.text_fields_outlined,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: buildContent(),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: actions,
        ),
      ),
    );
  }

  Widget buildContent() {
    return SizedBox(
      width: double.maxFinite,
      child: RawScrollbar(
        thickness: 3,
        thumbVisibility: true,
        controller: _scrollController,
        child: SingleChildScrollView(
          controller: _scrollController,
          child: Wrap(children: getTextWidgets()),
        ),
      ),
    );
  }

  List<Widget> getTextWidgets() {
    List<Widget> widgets = [];

    widget.segmentedText.forEachIndexed((index, segment) {
      Widget widget = ValueListenableBuilder<bool>(
        valueListenable: _valuesSelected[index]!,
        builder: (context, value, child) {
          return HibikiSelectableChip(
            label: segment.trim(),
            selected: value,
            onSelected: (_) => _toggleSegment(index),
          );
        },
      );

      widgets.add(widget);
    });

    return widgets;
  }

  void _toggleSegment(int index) {
    final bool newValue = !_valuesSelected[index]!.value;
    _valuesSelected[index]!.value = newValue;

    bool rightDeselectFlag = false;
    for (int i = index; i < _valuesSelected.length; i++) {
      if (rightDeselectFlag) {
        if (_valuesSelected[i]!.value) {
          _valuesSelected[i]!.value = false;
        }
        continue;
      }
      if (!_valuesSelected[i]!.value) {
        rightDeselectFlag = true;
      }
    }

    bool leftDeselectFlag = false;
    for (int i = index; i >= 0; i--) {
      if (leftDeselectFlag) {
        if (_valuesSelected[i]!.value) {
          _valuesSelected[i]!.value = false;
        }
        continue;
      }
      if (!_valuesSelected[i]!.value) {
        leftDeselectFlag = true;
      }
    }
  }

  Widget buildStashButton() {
    return adaptiveDialogAction(
      context: context,
      onPressed: executeStash,
      child: Text(t.dialog_stash),
    );
  }

  List<Widget> get actions => [
        buildStashButton(),
        if (widget.onSearch != null) buildSearchButton(),
        if (widget.onSelect != null) buildSelectButton(),
      ];

  Widget buildSearchButton() {
    return adaptiveDialogAction(
      context: context,
      onPressed: executeSearch,
      child: Text(t.dialog_search),
    );
  }

  Widget buildSelectButton() {
    return adaptiveDialogAction(
      context: context,
      onPressed: executeSelect,
      child: Text(t.dialog_select),
    );
  }

  HibikiTextSelection get selection {
    StringBuffer buffer = StringBuffer();
    int? start;
    int? end;

    for (int i = 0; i < _valuesSelected.length; i++) {
      if (_valuesSelected[i]!.value) {
        start ??= buffer.length;
        end = buffer.length + widget.segmentedText[i].length;
      }
      buffer.write(widget.segmentedText[i]);
    }

    TextRange range = TextRange.empty;
    if (start != null && end != null) {
      range = TextRange(start: start, end: end);
    }

    return HibikiTextSelection(
      text: widget.sourceText,
      range: range,
    );
  }

  void executeStash() {
    List<String> terms = [];
    widget.segmentedText.forEachIndexed((index, segment) {
      if (_valuesSelected[index]!.value) {
        terms.add(segment);
      }
    });

    appModel.addToStash(terms: terms);
  }

  void executeSearch() {
    if (selection.range == TextRange.empty) {
      return;
    }

    widget.onSearch?.call(selection);
  }

  void executeSelect() {
    if (selection.range == TextRange.empty) {
      return;
    }

    widget.onSelect?.call(selection);
  }
}
