import 'package:collection/collection.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

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
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);

    return FushiDialogFrame(
      maxWidth: 720,
      maxHeightFactor: 0.82,
      scrollable: false,
      child: FushiModalSheetFrame(
        title: t.creator_enhancement_sentence_picker,
        leadingIcon: FushiIcons.quote,
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
    return FushiPlaceholderMessage(
      icon: FushiIcons.searchOff,
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
    // 例句卡错峰进场（spring 上浮 + 淡入），墨水屏 / 减弱动态效果下静止。
    return FushiEntranceScope(child: _buildSentenceGrid());
  }

  Widget _buildSentenceGrid() {
    return MasonryGridView.builder(
      controller: _scrollController,
      gridDelegate: SliverSimpleGridDelegateWithFixedCrossAxisCount(
          crossAxisCount:
              MediaQuery.of(context).orientation == Orientation.portrait
                  ? 1
                  : 3),
      mainAxisSpacing: FushiDesignTokens.of(context).spacing.gap,
      crossAxisSpacing: FushiDesignTokens.of(context).spacing.gap,
      itemCount: widget.exampleSentences.length,
      itemBuilder: (context, index) {
        String sentence = widget.exampleSentences[index];

        // MasonryGridView 只收非空 IndexedWidgetBuilder，这里直接包
        // FushiStaggeredEntrance（与 fushiStaggeredItemBuilder 同一实现）。
        return FushiStaggeredEntrance(
          index: index,
          child: ValueListenableBuilder<bool>(
            valueListenable: _valuesSelected[index]!,
            builder: (context, value, child) {
              return _SentenceCard(
                sentence: sentence,
                selected: value,
                onTap: () {
                  _valuesSelected[index]!.value =
                      !_valuesSelected[index]!.value;
                },
              );
            },
          ),
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
      isDefaultAction: true,
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
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final FushiSpringSpec spring = context.fushiMotion.spatialFast;
    final FushiCardTone tone =
        selected ? FushiCardTone.secondary : FushiCardTone.neutral;
    // listTitle 自带页面 onSurface，会盖掉卡片写下的配对前景；
    // 中性卡为 null，保持原色。
    final Color? onCard = fushiCardToneColors(context, tone)?.onContainer;

    // M3E：选中态 = secondaryContainer 饱和色块（FushiCard tone，卡内文字随之
    // 取 onSecondaryContainer）+ 右上角对勾弹簧弹入；不再是中性底 + 主色描边。
    return Semantics(
      selected: selected,
      child: FushiCard(
        onTap: onTap,
        tone: tone,
        padding: EdgeInsets.all(tokens.spacing.card),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Text(
                sentence,
                style: tokens.type.listTitle.copyWith(
                  color: onCard,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ),
            AnimatedScale(
              scale: selected ? 1 : 0,
              duration: spring.duration,
              curve: spring.curve,
              child: Padding(
                padding: EdgeInsetsDirectional.only(start: tokens.spacing.gap),
                child: const FushiIcon(FushiIcons.success, size: 20),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
