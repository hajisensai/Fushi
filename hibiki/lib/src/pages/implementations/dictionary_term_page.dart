import 'package:expandable/expandable.dart';
import 'package:float_column/float_column.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sliver_tools/sliver_tools.dart';
import 'package:spaces/spaces.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/models/creator_model.dart';
import 'package:hibiki/utils.dart';

/// Returns the widget for a list of [DictionaryEntry] making up a term.
class DictionaryTermPage extends ConsumerWidget {
  /// Create the widget for a dictionary word.
  const DictionaryTermPage({
    required this.entries,
    required this.onSearch,
    required this.onStash,
    required this.onShare,
    required this.expandableControllers,
    required this.dictionaryNamesByHidden,
    required this.dictionaryNamesByOrder,
    this.cardColor,
    this.opacity = 1,
    this.footerWidget,
    super.key,
  });

  /// The entries for this term grouping.
  final List<DictionaryEntry> entries;

  /// Action to be done upon selecting the search option.
  final Function(String) onSearch;

  /// Action to be done upon selecting the stash option.
  final Function(String) onStash;

  /// Action to be done upon selecting the share option.
  final Function(String) onShare;

  /// Controls expandables by dictionary name.
  final Map<String, ExpandableController> expandableControllers;

  /// Lists whether a dictionary is hidden.
  final Map<String, bool> dictionaryNamesByHidden;

  /// Lists the order of dictionaries.
  final Map<String, int> dictionaryNamesByOrder;

  /// Optional footer widget shown below the term entries.
  final Widget? footerWidget;

  /// Override color for card background color.
  final Color? cardColor;

  /// Opacity for entries.
  final double opacity;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    List<DictionaryEntry> visibleEntries = entries
        .where((entry) =>
            !(dictionaryNamesByHidden[entry.dictionaryName] ?? false))
        .toList();

    visibleEntries.sort((a, b) =>
        (dictionaryNamesByOrder[a.dictionaryName] ?? 0)
            .compareTo(dictionaryNamesByOrder[b.dictionaryName] ?? 0));

    if (visibleEntries.isEmpty) {
      return const SliverPadding(padding: EdgeInsets.zero);
    }

    /// Use the first entry for the top row display.
    final DictionaryEntry primaryEntry = visibleEntries.first;

    final ColorScheme scheme = Theme.of(context).colorScheme;
    return SliverStack(
      children: [
        SliverPositioned.fill(
          child: Card(
            color: cardColor?.withOpacity(opacity) ??
                scheme.surfaceContainerHigh.withOpacity(opacity),
            elevation: 0,
            shape: const RoundedRectangleBorder(),
          ),
        ),
        SliverPadding(
          padding: EdgeInsets.only(
            left: Spacing.of(context).spaces.semiBig,
            top: Spacing.of(context).spaces.normal,
            right: Spacing.of(context).spaces.normal,
            bottom: Spacing.of(context).spaces.normal,
          ),
          sliver: MultiSliver(
            children: [
              SliverList(
                delegate: SliverChildListDelegate(
                  [
                    _DictionaryTermTopRow(
                      entry: primaryEntry,
                      onSearch: onSearch,
                    ),
                    const Space.normal(),
                  ],
                ),
              ),
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  childCount: footerWidget != null
                      ? visibleEntries.length + 1
                      : visibleEntries.length,
                  (context, index) {
                    if (index == visibleEntries.length &&
                        footerWidget != null) {
                      return footerWidget;
                    }

                    DictionaryEntry entry = visibleEntries[index];

                    return DictionaryEntryPage(
                      entry: entry,
                      onSearch: onSearch,
                      onStash: onStash,
                      onShare: onShare,
                      expandableController:
                          expandableControllers[entry.dictionaryName]!,
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DictionaryTermActionsRow extends ConsumerStatefulWidget {
  const _DictionaryTermActionsRow({
    required this.entry,
  });

  /// The primary entry for this term.
  final DictionaryEntry entry;

  @override
  ConsumerState<ConsumerStatefulWidget> createState() =>
      _DictionaryTermActionsRowState();
}

class _DictionaryTermActionsRowState
    extends ConsumerState<_DictionaryTermActionsRow> {
  VisibilityInfo? visibilityInfo;

  @override
  Widget build(BuildContext context) {
    AppModel appModel = ref.read(appProvider);
    CreatorModel creatorModel = ref.read(creatorProvider);
    bool visibleOnce = ref.watch(visibleOnceProvider(widget.entry));

    Map<String, Color?> defaultColors = Map<String, Color?>.fromEntries(
        appModel.quickActions.values.map((e) => MapEntry(e.uniqueKey, null)));

    if (!visibleOnce) {
      return VisibilityDetector(
        key: UniqueKey(),
        onVisibilityChanged: (info) {
          visibilityInfo = info;
          if (info.visibleFraction > 0) {
            ref.watch(visibleOnceProvider(widget.entry).notifier).state = true;
          }
        },
        child: buildRow(
          context: context,
          appModel: appModel,
          creatorModel: creatorModel,
          ref: ref,
          colors: defaultColors,
        ),
      );
    }

    AsyncValue<Map<String, Color?>> colors =
        ref.watch(quickActionColorProvider(widget.entry));

    return colors.when(
      data: (colors) {
        return buildRow(
          context: context,
          appModel: appModel,
          creatorModel: creatorModel,
          ref: ref,
          colors: colors,
        );
      },
      loading: () => buildRow(
        context: context,
        appModel: appModel,
        creatorModel: creatorModel,
        ref: ref,
        colors: defaultColors,
      ),
      error: (_, __) => buildRow(
        context: context,
        appModel: appModel,
        creatorModel: creatorModel,
        ref: ref,
        colors: defaultColors,
      ),
    );
  }

  Widget buildRow({
    required BuildContext context,
    required AppModel appModel,
    required CreatorModel creatorModel,
    required WidgetRef ref,
    required Map<String, Color?> colors,
  }) {
    List<Widget> buttons = [];
    final allActions = appModel.quickActions.values.toList();
    for (final quickAction in allActions) {
      final ColorScheme scheme = Theme.of(context).colorScheme;
      final Color enabledColor =
          colors[quickAction.uniqueKey] ?? scheme.onSurface;
      final Widget button = Padding(
        padding: Spacing.of(context).insets.onlyLeft.semiSmall,
        child: HibikiIconButton(
          busy: true,
          enabledColor: enabledColor,
          disabledColor: enabledColor.withOpacity(0.5),
          shapeBorder: const RoundedRectangleBorder(),
          backgroundColor: scheme.surfaceContainerHighest,
          size: Spacing.of(context).spaces.semiBig,
          tooltip: quickAction.getLocalisedLabel(appModel),
          icon: quickAction.icon,
          onTap: () async {
            await quickAction.executeAction(
              context: context,
              ref: ref,
              appModel: appModel,
              creatorModel: creatorModel,
              entry: widget.entry,
              dictionaryName: null,
            );

            ref.invalidate(quickActionColorProvider(widget.entry));
          },
        ),
      );

      buttons.add(button);
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: buttons.reversed.toList(),
    );
  }
}

class _DictionaryTermTopRow extends ConsumerWidget {
  const _DictionaryTermTopRow({
    required this.entry,
    required this.onSearch,
  });

  /// The primary entry for display.
  final DictionaryEntry entry;

  /// Action to be done upon selecting the search option.
  final Function(String) onSearch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FloatColumn(
      children: [
        Floatable(
          float: FCFloat.end,
          padding: EdgeInsets.only(
            top: Spacing.of(context).spaces.small,
            right: Spacing.of(context).spaces.small,
            bottom: Spacing.of(context).spaces.small,
          ),
          child: _DictionaryTermActionsRow(
            entry: entry,
          ),
        ),
        Floatable(
          float: FCFloat.start,
          child: GestureDetector(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.word,
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge!
                      .copyWith(fontWeight: FontWeight.bold),
                ),
                if (entry.reading.isNotEmpty)
                  Text(
                    entry.reading,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
