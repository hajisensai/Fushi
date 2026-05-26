import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/creator.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';

/// An enhancement used as a shortcut for adding text items to the Stash.
class AddToStashAction extends QuickAction {
  /// Initialise this enhancement with the hardset parameters.
  AddToStashAction()
      : super(
          uniqueKey: key,
          label: 'Add To Stash',
          description:
              'Quickly save the headword of a dictionary entry to the Stash.',
          icon: Icons.bookmark_add_outlined,
        );

  /// Used to identify this enhancement and to allow a constant value for the
  /// default mappings value of [AnkiMapping].
  static const String key = 'add_to_stash';

  @override
  String getLocalisedLabel(AppModel appModel) => t.creator_action_add_to_stash;

  @override
  Future<Color?> getIconColor({
    required AppModel appModel,
    required DictionaryEntry entry,
  }) async {
    if (appModel.isTermInStash(entry.word)) {
      final cs = appModel.isDarkMode
          ? appModel.darkTheme.colorScheme
          : appModel.theme.colorScheme;
      return cs.error;
    } else {
      return null;
    }
  }

  @override
  Future<void> executeAction({
    required BuildContext context,
    required WidgetRef ref,
    required AppModel appModel,
    required CreatorModel creatorModel,
    required DictionaryEntry entry,
    required String? dictionaryName,
  }) async {
    if (!appModel.isTermInStash(entry.word)) {
      appModel.addToStash(terms: [entry.word]);
    } else {
      appModel.removeFromStash(term: entry.word);
    }
  }
}
