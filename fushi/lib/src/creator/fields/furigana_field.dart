import 'package:flutter/material.dart';
import 'package:fushi/creator.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';

/// Returns the formatted furigana HTML of a [DictionaryEntry].
class FuriganaField extends Field {
  /// Initialise this field with the predetermined and hardset values.
  FuriganaField._privateConstructor()
      : super(
          uniqueKey: key,
          label: 'Furigana',
          description: 'Pre-fills text to export for Furigana.',
          icon: Icons.data_array_outlined,
        );

  /// Get the singleton instance of this field.
  static FuriganaField get instance => _instance;

  static final FuriganaField _instance = FuriganaField._privateConstructor();

  /// The unique key for this field.
  static const String key = 'furigana';

  @override
  String getLocalisedLabel(AppModel appModel) => t.creator_field_furigana;
}
