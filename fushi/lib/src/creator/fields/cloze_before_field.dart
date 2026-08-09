import 'package:flutter/material.dart';
import 'package:fushi/creator.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';

/// Text before highlighted text in a sentence
class ClozeBeforeField extends Field {
  /// Initialise this field with the predetermined and hardset values.
  ClozeBeforeField._privateConstructor()
      : super(
          uniqueKey: key,
          label: 'Cloze Before',
          description: 'Text before highlighted text in a sentence. '
              'Empty if nothing is highlighted.',
          icon: Icons.keyboard_double_arrow_left,
        );

  /// Get the singleton instance of this field.
  static ClozeBeforeField get instance => _instance;

  static final ClozeBeforeField _instance =
      ClozeBeforeField._privateConstructor();

  /// The unique key for this field.
  static const String key = 'cloze_before';

  @override
  String getLocalisedLabel(AppModel appModel) => t.creator_field_cloze_before;
}
