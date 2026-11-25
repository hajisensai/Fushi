import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/popup_dictionary_page.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_lookup_controller.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_panel_session.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart'
    show HorizontalDragScrollable;
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';

/// Builds the dictionary for [entry] (the popup dictionary page; tests pass a
/// stand-in). [generation] changes on every lookup, also of the same word.
typedef CompanionDictionaryBuilder =
    Widget Function(
      BuildContext context,
      CompanionLookupEntry entry,
      int generation,
      CompanionLookupController controller,
    );

/// The Lookup tab: the dictionary for the latest lookup (made on the main
/// screen, a history entry, or a line tapped on a module panel) with the
/// popup's own mining (Add to Anki), word audio and entry navigation, a row
/// of recent lookups, and the run's lookup history when nothing is open.
class CompanionLookupTab extends ConsumerWidget {
  const CompanionLookupTab({this.dictionaryBuilder, super.key});

  /// Defaults to [buildCompanionPopupDictionary].
  final CompanionDictionaryBuilder? dictionaryBuilder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final CompanionLookupController lookup = ref.watch(
      companionLookupControllerProvider,
    );
    final CompanionLookupEntry? current = lookup.current;
    final bool lookupsOnCompanion = ref.watch(
      companionPanelSessionProvider.select(
        (CompanionPanelSession s) => s.lookupsOnCompanion,
      ),
    );
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: current == null
            ? _HistoryView(
                controller: lookup,
                lookupsOnCompanion: lookupsOnCompanion,
              )
            : _LookupView(
                entry: current,
                controller: lookup,
                dictionaryBuilder:
                    dictionaryBuilder ?? buildCompanionPopupDictionary,
              ),
      ),
    );
  }
}

/// The real dictionary: [PopupDictionaryPage] (the same page the system
/// lookup popup runs, so mining / audio / nested lookups behave the same)
/// filling the tab, once the panel's popup AppModel is up. The tab owns the
/// insets (top safe area, bottom bar height); the embedded page applies none.
Widget buildCompanionPopupDictionary(
  BuildContext context,
  CompanionLookupEntry entry,
  int generation,
  CompanionLookupController controller,
) => _PopupDictionary(entry: entry, generation: generation, lookup: controller);

class _PopupDictionary extends ConsumerWidget {
  const _PopupDictionary({
    required this.entry,
    required this.generation,
    required this.lookup,
  });

  final CompanionLookupEntry entry;
  final int generation;
  final CompanionLookupController lookup;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(appProvider).isInitialised) {
      return Center(
        child: FushiPlaceholderMessage(
          icon: FushiIcons.lookup,
          message: t.second_screen_lookup_loading,
        ),
      );
    }
    final String text = entry.text;
    final String? sentence = entry.sentence;
    // A mining sentence longer than the source line (a subtitle line inside
    // a longer sentence): hand the page the sentence as its source block so
    // the card gets the whole sentence.
    final int offset = sentence == null ? -1 : sentence.indexOf(text);
    final bool hasBlock =
        sentence != null && sentence != text && text.isNotEmpty && offset >= 0;
    return PopupDictionaryPage(
      searchTerm: text,
      searchGeneration: generation,
      sourceCharIndex: entry.charIndex,
      sourceBlock: hasBlock ? sentence : null,
      sourceBlockOffset: hasBlock ? offset : -1,
      closeInApp: lookup.close,
      showSearchBar: false,
      embedded: true,
      onLookupStarted: lookup.countLookup,
      onHeadword: (String word) => lookup.reportHeadword(entry, word),
      onMined: (result) {
        if (result.ankiConnect || result.queued) lookup.reportMined();
      },
    );
  }
}

class _LookupView extends StatelessWidget {
  const _LookupView({
    required this.entry,
    required this.controller,
    required this.dictionaryBuilder,
  });

  final CompanionLookupEntry entry;
  final CompanionLookupController controller;
  final CompanionDictionaryBuilder dictionaryBuilder;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String? source = entry.source;
    final List<CompanionLookupEntry> recent = controller.history
        .where((CompanionLookupEntry e) => !identical(e, entry))
        .take(12)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(16, 4, 4, 0),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  source == null
                      ? t.second_screen_tab_lookup
                      : t.second_screen_lookup_from(title: source),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              FushiIconButton(
                key: const ValueKey<String>('companion-lookup-close'),
                icon: FushiIcons.close,
                tooltip: t.second_screen_lookup_close,
                onTap: controller.close,
                padTouchTarget: true,
              ),
            ],
          ),
        ),
        Expanded(
          child: KeyedSubtree(
            key: const ValueKey<String>('companion-lookup-dictionary'),
            child: dictionaryBuilder(
              context,
              entry,
              controller.generation,
              controller,
            ),
          ),
        ),
        if (recent.isNotEmpty)
          _RecentRow(entries: recent, onTap: controller.replay),
        SizedBox(height: MediaQuery.paddingOf(context).bottom),
      ],
    );
  }
}

class _RecentRow extends StatelessWidget {
  const _RecentRow({required this.entries, required this.onTap});

  final List<CompanionLookupEntry> entries;
  final void Function(CompanionLookupEntry entry) onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
          child: Text(
            t.second_screen_lookup_recent,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        SizedBox(
          height: 48,
          child: FushiEntranceScope(
            child: HorizontalDragScrollable(
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: entries.length,
                separatorBuilder: (BuildContext context, int _) =>
                    const SizedBox(width: 8),
                itemBuilder: fushiStaggeredItemBuilder(
                  (BuildContext context, int i) => Center(
                    child: FushiPressScale(
                      child: FushiActionChip(
                        key: ValueKey<String>('companion-recent-$i'),
                        icon: FushiIcons.history,
                        label: entries[i].label,
                        onPressed: () => onTap(entries[i]),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _HistoryView extends StatelessWidget {
  const _HistoryView({
    required this.controller,
    required this.lookupsOnCompanion,
  });

  final CompanionLookupController controller;

  /// False while "Lookups open on" is Top screen: main-screen lookups stay
  /// on top, only the panel's own text lookups land here.
  final bool lookupsOnCompanion;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<CompanionLookupEntry> history = controller.history;
    if (history.isEmpty) {
      return FushiEntranceScope(
        child: FushiStaggeredEntrance(
          index: 0,
          child: Center(
            child: FushiPlaceholderMessage(
              icon: FushiIcons.lookup,
              message: lookupsOnCompanion
                  ? t.second_screen_lookup_empty
                  : t.second_screen_lookup_empty_top,
            ),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 8, 4),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  t.second_screen_lookup_recent,
                  style: theme.textTheme.titleMedium,
                ),
              ),
              FushiTextButton(
                key: const ValueKey<String>('companion-lookup-clear'),
                onPressed: controller.clearHistory,
                child: Text(t.second_screen_lookup_clear_history),
              ),
            ],
          ),
        ),
        Expanded(
          child: FushiEntranceScope(
            child: ListView.builder(
              padding: EdgeInsets.fromLTRB(
                16,
                0,
                16,
                16 + MediaQuery.paddingOf(context).bottom,
              ),
              itemCount: history.length,
              itemBuilder: fushiStaggeredItemBuilder(
                (BuildContext context, int i) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: _HistoryTile(
                    key: ValueKey<String>('companion-history-$i'),
                    entry: history[i],
                    onTap: () => controller.replay(history[i]),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({required this.entry, required this.onTap, super.key});

  final CompanionLookupEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final String time =
        '${entry.at.hour.toString().padLeft(2, '0')}:'
        '${entry.at.minute.toString().padLeft(2, '0')}';
    final String sentence = entry.sentence ?? entry.text;
    return FushiListItem(
      title: Text(entry.label, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: sentence.isEmpty || sentence == entry.label
          ? null
          : Text(sentence, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Text(time),
      onTap: onTap,
    );
  }
}
