import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/creator.dart';
import 'package:hibiki/dictionary.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';
import 'package:collection/collection.dart';

/// Used to return a formatted text from multiple dictionary entries.
class MeaningField extends Field {
  /// Initialise this field with the predetermined and hardset values.
  MeaningField._privateConstructor()
      : super(
          uniqueKey: key,
          label: 'Meaning',
          description: 'All dictionary definitions of a term.',
          icon: Icons.translate_rounded,
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

  @override
  String? onCreatorOpenAction({
    required WidgetRef ref,
    required AppModel appModel,
    required CreatorModel creatorModel,
    required DictionaryEntry entry,
    required bool creatorJustLaunched,
    required String? dictionaryName,
  }) {
    return flattenMeanings(
      appModel: appModel,
      entries: [entry],
      prependDictionaryNames:
          false,
    );
  }
}
