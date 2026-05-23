import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/creator.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';

/// Used to return a formatted text from hidden dictionary entries.
class HiddenMeaningField extends Field {
  /// Initialise this field with the predetermined and hardset values.
  HiddenMeaningField._privateConstructor()
      : super(
          uniqueKey: key,
          label: 'Hidden Meaning',
          description: 'Dictionary definitions only from hidden'
              ' dictionaries.',
          icon: Icons.visibility_off_outlined,
        );

  /// Get the singleton instance of this field.
  static HiddenMeaningField get instance => _instance;

  static final HiddenMeaningField _instance =
      HiddenMeaningField._privateConstructor();

  /// The unique key for this field.
  static const String key = 'hidden_meaning';

  @override
  String getLocalisedLabel(AppModel appModel) => t.creator_field_hidden_meaning;

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
        appModel: appModel, entries: [entry], prependDictionaryNames: false);
  }
}
