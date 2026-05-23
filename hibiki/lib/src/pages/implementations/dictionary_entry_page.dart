import 'package:expandable/expandable.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spaces/spaces.dart';
import 'package:hibiki/creator.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/utils.dart';

/// Returns the widget for a [DictionaryEntry] making up a collection of
/// meanings.
class DictionaryEntryPage extends ConsumerStatefulWidget {
  /// Create the widget for a dictionary entry.
  const DictionaryEntryPage({
    required this.entry,
    required this.onSearch,
    required this.onStash,
    required this.onShare,
    required this.expandableController,
    super.key,
  });

  /// The entry particular to this
  final DictionaryEntry entry;

  /// Action to be done upon selecting the search option.
  final Function(String) onSearch;

  /// Action to be done upon selecting the stash option.
  final Function(String) onStash;

  /// Action to be done upon selecting the stash option.
  final Function(String) onShare;

  /// Controller specific to a dictionary name.
  final ExpandableController expandableController;

  @override
  ConsumerState<ConsumerStatefulWidget> createState() =>
      _DictionaryEntryPageState();
}

class _DictionaryEntryPageState extends ConsumerState<DictionaryEntryPage> {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        top: Spacing.of(context).spaces.extraSmall,
        bottom: Spacing.of(context).spaces.normal,
      ),
      child: ExpandablePanel(
        theme: ExpandableThemeData(
          iconPadding: EdgeInsets.zero,
          iconSize: Theme.of(context).textTheme.titleLarge?.fontSize,
          iconRotationAngle: 0,
          expandIcon: Icons.arrow_drop_down,
          collapseIcon: Icons.arrow_drop_down,
          iconColor: Theme.of(context).colorScheme.onSurfaceVariant,
          headerAlignment: ExpandablePanelHeaderAlignment.center,
        ),
        controller: widget.expandableController,
        header: _DictionaryEntryHeaderWrap(entry: widget.entry),
        collapsed: const SizedBox.shrink(),
        expanded: Padding(
          padding: EdgeInsets.only(
            top: Spacing.of(context).spaces.small,
            left: Spacing.of(context).spaces.normal,
          ),
          child: DictionaryHtmlWidget(
            entry: widget.entry,
            onSearch: widget.onSearch,
            onStash: widget.onStash,
            onShare: widget.onShare,
          ),
        ),
      ),
    );
  }
}

class _DictionaryEntryHeaderWrap extends ConsumerWidget {
  const _DictionaryEntryHeaderWrap({
    required this.entry,
  });

  final DictionaryEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    String dictionaryName = entry.dictionaryName;
    List<Widget> children = [
      HibikiTag(
        text: dictionaryName,
        backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
      ),
    ];

    Widget last = children.removeLast();

    children.add(
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(child: last),
          SizedBox(
            height: 22,
            width: 22,
            child: PopupMenuButton<VoidCallback>(
              iconSize: 16,
              padding: EdgeInsets.zero,
              icon: Icon(
                Icons.more_vert,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              color: Theme.of(context).popupMenuTheme.color,
              tooltip: t.show_options,
              onSelected: (value) => value(),
              itemBuilder: (context) => getMenuItems(
                context: context,
                dictionaryName: dictionaryName,
                ref: ref,
                entry: entry,
              ),
            ),
          )
        ],
      ),
    );

    return Wrap(
      children: children,
    );
  }

  List<PopupMenuEntry<VoidCallback>> getMenuItems({
    required BuildContext context,
    required String dictionaryName,
    required WidgetRef ref,
    required DictionaryEntry entry,
  }) {
    AppModel appModel = ref.read(appProvider);
    CreatorModel creatorModel = ref.read(creatorProvider);

    List<QuickAction> filteredActions = appModel.quickActions.values
        .where((e) => e.showInSingleDictionary)
        .toList();

    return [
      ...filteredActions.map((quickAction) {
        return PopupMenuItem<VoidCallback>(
          value: () async {
            await quickAction.executeAction(
              context: context,
              ref: ref,
              appModel: appModel,
              creatorModel: creatorModel,
              entry: entry,
              dictionaryName: dictionaryName,
            );

            ref.invalidate(quickActionColorProvider(entry));
          },
          child: Row(
            children: [
              Icon(
                quickAction.icon,
                size: Theme.of(context).textTheme.bodyMedium?.fontSize,
              ),
              const Space.normal(),
              Text(
                quickAction.getLocalisedLabel(appModel),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        );
      }).toList(),
    ];
  }
}
