import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/utils.dart';

/// The content of the dialog used for selecting example sentences.
class ExampleSentencesDialogPage extends BasePage {
  /// Create an instance of this page.
  const ExampleSentencesDialogPage({
    required this.exampleSentences,
    required this.onSelect,
    this.onAppend,
    super.key,
  });

  /// The example sentences to be shown in the dialog.
  final List<String> exampleSentences;

  /// Select action callback.
  final Function(List<String>) onSelect;

  /// Append action callback.
  final Function(List<String>)? onAppend;

  @override
  BasePageState createState() => _ExampleSentencesDialogPageState();
}

class _ExampleSentencesDialogPageState
    extends BasePageState<ExampleSentencesDialogPage> {
  final ScrollController _scrollController = ScrollController();

  final Map<int, ValueNotifier<bool>> _valuesSelected = {};

  @override
  void initState() {
    super.initState();

    widget.exampleSentences.forEachIndexed((index, element) {
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
      maxWidth: 720,
      maxHeightFactor: 0.82,
      scrollable: false,
      child: HibikiModalSheetFrame(
        title: t.creator_enhancement_sentence_picker,
        leadingIcon: Icons.format_quote_outlined,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          widget.exampleSentences.isEmpty
              ? tokens.spacing.card
              : tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: buildContent(),
        footer: widget.exampleSentences.isEmpty
            ? null
            : Wrap(
                alignment: WrapAlignment.end,
                spacing: tokens.spacing.gap,
                runSpacing: tokens.spacing.gap,
                children: actions,
              ),
      ),
    );
  }

  Widget buildEmptyMessage() {
    return HibikiPlaceholderMessage(
      icon: Icons.search_off,
      message: t.no_sentences_found,
    );
  }

  Widget buildContent() {
    return SizedBox(
      width: double.maxFinite,
      child: RawScrollbar(
        thumbVisibility: true,
        thickness: 3,
        controller: _scrollController,
        child: widget.exampleSentences.isEmpty
            ? SingleChildScrollView(
                controller: _scrollController, child: buildEmptyMessage())
            : buildTextWidgets(),
      ),
    );
  }

  Widget buildTextWidgets() {
    return MasonryGridView.builder(
      controller: _scrollController,
      gridDelegate: SliverSimpleGridDelegateWithFixedCrossAxisCount(
          crossAxisCount:
              MediaQuery.of(context).orientation == Orientation.portrait
                  ? 1
                  : 3),
      mainAxisSpacing: HibikiDesignTokens.of(context).spacing.gap,
      crossAxisSpacing: HibikiDesignTokens.of(context).spacing.gap,
      itemCount: widget.exampleSentences.length,
      itemBuilder: (context, index) {
        String sentence = widget.exampleSentences[index];

        return ValueListenableBuilder<bool>(
          valueListenable: _valuesSelected[index]!,
          builder: (context, value, child) {
            return _SentenceCard(
              sentence: sentence,
              selected: value,
              onTap: () {
                _valuesSelected[index]!.value = !_valuesSelected[index]!.value;
              },
            );
          },
        );
      },
    );
  }

  List<Widget> get actions => [
        if (widget.onAppend != null) buildAppendButton(),
        buildSelectButton(),
      ];

  Widget buildAppendButton() {
    return adaptiveDialogAction(
      context: context,
      onPressed: executeAppend,
      child: Text(t.dialog_append),
    );
  }

  Widget buildSelectButton() {
    return adaptiveDialogAction(
      context: context,
      onPressed: executeSelect,
      child: Text(t.dialog_select),
    );
  }

  List<String> get selection {
    List<String> results = [];

    widget.exampleSentences.forEachIndexed((index, result) {
      if (_valuesSelected[index]!.value) {
        results.add(result);
      }
    });

    return results;
  }

  void executeAppend() {
    Navigator.pop(context);
    widget.onAppend?.call(selection);
  }

  void executeSelect() {
    Navigator.pop(context);
    widget.onSelect(selection);
  }
}

class _SentenceCard extends StatelessWidget {
  const _SentenceCard({
    required this.sentence,
    required this.selected,
    required this.onTap,
  });

  final String sentence;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;

    return HibikiCard(
      onTap: onTap,
      padding: EdgeInsets.all(tokens.spacing.card),
      color: selected ? colors.primaryContainer : null,
      borderColor: selected ? colors.primary : null,
      child: Text(
        sentence,
        style: tokens.type.listTitle.copyWith(
          color: selected ? colors.onPrimaryContainer : null,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
        ),
      ),
    );
  }
}
