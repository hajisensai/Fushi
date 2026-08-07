import 'package:flutter/material.dart';
import 'package:fushi/creator.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:collection/collection.dart';

/// Used to return a formatted text from multiple dictionary entries.
class MeaningField extends Field {
  /// Initialise this field with the predetermined and hardset values.
  MeaningField._privateConstructor()
      : super(
          uniqueKey: key,
          label: 'Meaning',
          description: 'All dictionary definitions of a term.',
          icon: Icons.translate,
        );

  /// Get the singleton instance of this field.
  static MeaningField get instance => _instance;

  static final MeaningField _instance = MeaningField._privateConstructor();

  /// The unique key for this field.
  static const String key = 'meaning';

  @override
  String getLocalisedLabel(AppModel appModel) => t.creator_field_meaning;

  /// Get a single combined text for all meanings in a list of entries.
  static String flattenMeanings({
    required AppModel appModel,
    required List<DictionaryEntry> entries,
    required bool prependDictionaryNames,
  }) {
    StringBuffer meaningBuffer = StringBuffer();

    Map<String, List<DictionaryEntry>> entriesByDictionaryName =
        groupBy<DictionaryEntry, String>(
      entries,
      (entry) => entry.dictionaryName,
    );

    entriesByDictionaryName.forEach((dictionaryName, singleDictionaryEntries) {
      if (prependDictionaryNames) {
        meaningBuffer.writeln('【$dictionaryName】');
      }

      for (DictionaryEntry entry in singleDictionaryEntries) {
        String meaning = entry.meaning.trim();
        meaningBuffer.write(meaning);
        meaningBuffer.write('\n');
      }

      meaningBuffer.write('\n');
    });

    return meaningBuffer.toString().trim();
  }
}
