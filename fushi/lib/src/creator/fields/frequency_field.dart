import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/creator/field.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';

/// Returns the frequency of a [DictionaryEntry].
class FrequencyField extends Field {
  /// Initialise this field with the predetermined and hardset values.
  FrequencyField._privateConstructor()
    : super(
        uniqueKey: key,
        label: 'Frequency',
        description:
            'Adds frequency of headword for sorting purposes,'
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

  /// Extra value key for the per-dictionary frequency numbers
  /// (Yomitan `{single-frequency-number-<dict>}`, BUG-4227).
  static const String singleFrequencyNumbersExtraKey = 'singleFrequencyNumbers';

  /// Extra value key for the per-dictionary frequency HTML lists
  /// (Yomitan `{single-frequency-<dict>}`, BUG-4227).
  static const String singleFrequenciesHtmlExtraKey = 'singleFrequenciesHtml';

  /// Builds frequency extra values from a dictionary entry.
  ///
  /// 键名与 popup.js `buildMinePayload` 同名同语义：两张逐词典表用 popup.js 一样的
  /// `JSON.stringify` 字符串形态（`AnkiMiningPayload.fromJson` 认这种形态）；表为空时给
  /// 空串，让调用方按「空值不写」丢掉。
  static Map<String, String> extraValuesFromEntry(DictionaryEntry entry) {
    final Map<String, String> numbers = getSingleFrequencyNumbers(entry: entry);
    final Map<String, String> htmls = getSingleFrequenciesHtml(entry: entry);
    return {
      frequencyRankExtraKey: getFrequencyRank(entry: entry),
      frequenciesHtmlExtraKey: getFrequenciesHtml(entry: entry),
      singleFrequencyNumbersExtraKey: numbers.isEmpty
          ? ''
          : jsonEncode(numbers),
      singleFrequenciesHtmlExtraKey: htmls.isEmpty ? '' : jsonEncode(htmls),
    };
  }

  /// 词典名 → 该词典的频率数（popup.js `constructSingleFrequencyNumbers`）。
  /// 与调和平均共用 [_collectFrequencyNumbers]；没有可用数值的词典不在表里。
  static Map<String, String> getSingleFrequencyNumbers({
    required DictionaryEntry entry,
  }) {
    final Map<String, String> result = <String, String>{};
    for (final _DictionaryFrequencyNumber n in _collectFrequencyNumbers(
      _readFrequencyGroups(entry),
    )) {
      if (n.dictName.isNotEmpty) result[n.dictName] = n.value.toString();
    }
    return result;
  }

  /// 词典名 → 只含该词典的 `{frequencies}` 列表 HTML（popup.js
  /// `constructSingleFrequenciesHtml`，由同一个 [_frequenciesHtml] 渲染）。
  static Map<String, String> getSingleFrequenciesHtml({
    required DictionaryEntry entry,
  }) {
    final List<_FrequencyGroup> groups = _readFrequencyGroups(entry);
    final Map<String, String> result = <String, String>{};
    for (final _FrequencyGroup group in groups) {
      final String dictName = group.dictName;
      if (dictName.isEmpty || result.containsKey(dictName)) continue;
      result[dictName] = _frequenciesHtml(
        groups
            .where((_FrequencyGroup g) => g.dictName == dictName)
            .toList(growable: false),
      );
    }
    return result;
  }

  /// Returns the frequency rank used for sorting Anki cards.
  static String getFrequencyRank({required DictionaryEntry entry}) {
    if (entry.popularity == 0) {
      return _getFrequencyRankFromExtra(entry);
    }
    return entry.popularity.round().toString();
  }

  /// Returns the complete frequency list as HTML.
  static String getFrequenciesHtml({required DictionaryEntry entry}) =>
      _frequenciesHtml(_readFrequencyGroups(entry));

  /// popup.js `constructFrequencyHtml` 的同款列表。
  static String _frequenciesHtml(List<_FrequencyGroup> frequencies) {
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
    final int? rank = aggregateFrequencyRanks(
      _collectFrequencyNumbers(
        _readFrequencyGroups(entry),
      ).map((_DictionaryFrequencyNumber n) => n.value).toList(growable: false),
      FrequencyAggregate.harmonic,
    );
    return rank?.toString() ?? '';
  }

  /// 逐词典取数的唯一来源（popup.js `collectFrequencyNumbers` / Yomitan
  /// `getFrequencyNumbers` 同语义）：每本词典只取第一组的第一条，display 的前导数字
  /// > 0 优先，否则 value > 0；没有可用数值的词典跳过。调和平均与
  /// `{single-frequency-number-<dict>}` 都从这里取，保证同一张卡上两者同源。
  static List<_DictionaryFrequencyNumber> _collectFrequencyNumbers(
    List<_FrequencyGroup> groups,
  ) {
    final List<_DictionaryFrequencyNumber> numbers =
        <_DictionaryFrequencyNumber>[];
    final Set<String> seenDictionaries = <String>{};
    for (final _FrequencyGroup group in groups) {
      if (group.dictName.isNotEmpty && !seenDictionaries.add(group.dictName)) {
        continue;
      }
      if (group.values.isEmpty) {
        continue;
      }
      final _FrequencyValue first = group.values.first;
      final int? rank = frequencyRankOf(first.value, first.display);
      if (rank != null) {
        numbers.add(_DictionaryFrequencyNumber(group.dictName, rank));
      }
    }
    return numbers;
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
        values.add(
          _FrequencyValue(
            value: (rawValue['value'] as num?)?.toInt() ?? 0,
            display: rawValue['display']?.toString() ?? '',
          ),
        );
      }
      if (values.isNotEmpty) {
        groups.add(
          _FrequencyGroup(
            dictName: rawGroup['dictName']?.toString() ?? '',
            values: values,
          ),
        );
      }
    }
    return groups;
  }
}

class _FrequencyGroup {
  const _FrequencyGroup({required this.dictName, required this.values});

  final String dictName;

  final List<_FrequencyValue> values;
}

class _DictionaryFrequencyNumber {
  const _DictionaryFrequencyNumber(this.dictName, this.value);

  final String dictName;

  final int value;
}

class _FrequencyValue {
  const _FrequencyValue({required this.value, required this.display});

  final int value;

  final String display;
}
