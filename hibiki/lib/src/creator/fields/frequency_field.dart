import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/creator.dart';
import 'package:hibiki/dictionary.dart';
import 'package:hibiki/models.dart';

/// Returns the frequency of a [DictionaryEntry].
class FrequencyField extends Field {
  /// Initialise this field with the predetermined and hardset values.
  FrequencyField._privateConstructor()
      : super(
          uniqueKey: key,
          label: 'Frequency',
          description: 'Adds frequency of headword for sorting purposes,'
              ' calculated using the harmonic mean.',
          icon: Icons.insert_chart,
        );

  /// Get the singleton instance of this field.
  static FrequencyField get instance => _instance;

  static final FrequencyField _instance = FrequencyField._privateConstructor();

  /// The unique key for this field.
  static const String key = 'frequency';

  /// Returns the frequency from the entry's popularity field.
  /// Frequencies are no longer stored as separate DictionaryFrequency objects;
  /// use the popularity field on DictionaryEntry instead.
  static String getFrequency({
    required AppModel appModel,
    required DictionaryEntry entry,
  }) {
    if (entry.popularity == 0) {
      return '';
    }
    return entry.popularity.round().toString();
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
    return getFrequency(
      appModel: appModel,
      entry: entry,
    );
  }
}

/// The method by which the frequency value is calculated.
enum SortingMethod {
  /// DEFAULT: The harmonic mean of frequencies.
  harmonic,

  /// The smallest frequency value
  min,

  /// The average frequency value
  avg
}
