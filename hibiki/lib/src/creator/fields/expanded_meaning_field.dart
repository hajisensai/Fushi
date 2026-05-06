import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/creator.dart';
import 'package:hibiki/dictionary.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';

/// Used to return a formatted text from multiple dictionary entries from
/// expanded dictionaries only.
class ExpandedMeaningField extends Field {
  /// Initialise this field with the predetermined and hardset values.
  ExpandedMeaningField._privateConstructor()
      : super(
            uniqueKey: key,
            label: 'Expanded Meaning',
            description: 'Dictionary definitions only from expanded'
                ' dictionaries.',
            icon: Icons.open_in_full);

  /// Get the singleton instance of this field.
  static ExpandedMeaningField get instance => _instance;

  static final ExpandedMeaningField _instance =
      ExpandedMeaningField._privateConstructor();

  /// The unique key for this field.
  static const String key = 'expanded_meaning';

  @override
  String getLocalisedLabel(AppModel appModel) => t.creator_field_expanded_meaning;

  @override
  String? onCreatorOpenAction({
    required WidgetRef ref,
    required AppModel appModel,
    required CreatorModel creatorModel,
    required DictionaryEntry entry,
    required bool creatorJustLaunched,
    required String? dictionaryName,
  }) {
    return MeaningField.flattenMeanings(
        appModel: appModel,
        entries: [entry],
        prependDictionaryNames:
            false);
  }
}
