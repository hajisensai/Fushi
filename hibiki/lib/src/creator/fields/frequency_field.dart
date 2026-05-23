import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/creator.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/i18n/strings.g.dart';
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
          icon: Icons.insert_chart_outlined,
        );

  /// Get the singleton instance of this field.
  static FrequencyField get instance => _instance;

  static final FrequencyField _instance = FrequencyField._privateConstructor();

  /// The unique key for this field.
  static const String key = 'frequency';

  @override
  String getLocalisedLabel(AppModel appModel) => t.creator_field_frequency;

  /// Extra value key for the harmonic-rank frequency.
  static const String frequencyRankExtraKey = 'freqHarmonicRank';

  /// Extra value key for the full frequency HTML list.
  static const String frequenciesHtmlExtraKey = 'frequenciesHtml';

  /// Extracts frequency values returned by the popup mining JavaScript.
  static Map<String, String> extraValuesFromMineFields(
    Map<String, String> fields,
  ) {
    return {
      frequencyRankExtraKey: fields[frequencyRankExtraKey] ?? '',
      frequenciesHtmlExtraKey: fields[frequenciesHtmlExtraKey] ?? '',
    };
  }

  /// Builds frequency extra values from a dictionary entry.
  static Map<String, String> extraValuesFromEntry(DictionaryEntry entry) {
    return {
      frequencyRankExtraKey: getFrequencyRank(entry: entry),
      frequenciesHtmlExtraKey: getFrequenciesHtml(entry: entry),
    };
  }

  /// Returns the sortable harmonic-rank frequency value.
  static String getFrequency({
    required AppModel appModel,
    required DictionaryEntry entry,
  }) {
    return getFrequencyRank(entry: entry);
  }

  /// Returns the frequency rank used for sorting Anki cards.
  static String getFrequencyRank({required DictionaryEntry entry}) {
    if (entry.popularity == 0) {
      return _getFrequencyRankFromExtra(entry);
    }
    return entry.popularity.round().toString();
  }

  /// Returns the complete frequency list as HTML.
  static String getFrequenciesHtml({required DictionaryEntry entry}) {
    final frequencies = _readFrequencyGroups(entry);
    if (frequencies.isEmpty) {
      return '';
    }

    final buffer = StringBuffer('<ul style="text-align: left;">');
    for (final group in frequencies) {
      final dictName = group.dictName;
      for (final frequency in group.values) {
        final value = frequency.display.isNotEmpty
            ? frequency.display
            : frequency.value.toString();
        buffer.write('<li>$dictName: $value</li>');
      }
    }
    buffer.write('</ul>');
    return buffer.toString();
  }

  static String _getFrequencyRankFromExtra(DictionaryEntry entry) {
    final values = <int>[];
    final seenDictionaries = <String>{};
    for (final group in _readFrequencyGroups(entry)) {
      if (group.dictName.isNotEmpty && !seenDictionaries.add(group.dictName)) {
        continue;
      }
      if (group.values.isEmpty) {
        continue;
      }

      final first = group.values.first;
      final displayMatch = RegExp(r'^\d+').firstMatch(first.display);
      if (displayMatch != null) {
        final parsed = int.tryParse(displayMatch.group(0)!);
        if (parsed != null && parsed > 0) {
          values.add(parsed);
          continue;
        }
      }
      if (first.value > 0) {
        values.add(first.value);
      }
    }

    if (values.isEmpty) {
      return '';
    }

    final reciprocalSum = values.fold<double>(
      0,
      (sum, value) => sum + (1 / value),
    );
    return (values.length / reciprocalSum).floor().toString();
  }

  static List<_FrequencyGroup> _readFrequencyGroups(DictionaryEntry entry) {
    if (entry.extra.isEmpty) {
      return [];
    }

    Object? decoded;
    try {
      decoded = jsonDecode(entry.extra);
    } catch (e, stack) {
      ErrorLogService.instance.log('FrequencyField.decode', e, stack);
      return [];
    }

    if (decoded is! Map) {
      return [];
    }
    final rawGroups = decoded['frequencies'];
    if (rawGroups is! List) {
      return [];
    }

    final groups = <_FrequencyGroup>[];
    for (final rawGroup in rawGroups) {
      if (rawGroup is! Map) {
        continue;
      }
      final rawValues = rawGroup['values'];
      if (rawValues is! List) {
        continue;
      }

      final values = <_FrequencyValue>[];
      for (final rawValue in rawValues) {
        if (rawValue is! Map) {
          continue;
        }
        values.add(_FrequencyValue(
          value: (rawValue['value'] as num?)?.toInt() ?? 0,
          display: rawValue['display']?.toString() ?? '',
        ));
      }
      if (values.isNotEmpty) {
        groups.add(_FrequencyGroup(
          dictName: rawGroup['dictName']?.toString() ?? '',
          values: values,
        ));
      }
    }
    return groups;
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

class _FrequencyGroup {
  const _FrequencyGroup({
    required this.dictName,
    required this.values,
  });

  final String dictName;

  final List<_FrequencyValue> values;
}

class _FrequencyValue {
  const _FrequencyValue({
    required this.value,
    required this.display,
  });

  final int value;

  final String display;
}
