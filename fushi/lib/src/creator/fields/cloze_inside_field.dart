import 'package:flutter/material.dart';
import 'package:fushi/creator.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';

/// Highlighted text in a sentence.
class ClozeInsideField extends Field {
  /// Initialise this field with the predetermined and hardset values.
  ClozeInsideField._privateConstructor()
      : super(
          uniqueKey: key,
          label: 'Cloze Inside',
          description: 'Highlighted text in a sentence.',
          icon: Icons.dehaze_outlined,
        );

  /// Get the singleton instance of this field.
  static ClozeInsideField get instance => _instance;

  static final ClozeInsideField _instance =
      ClozeInsideField._privateConstructor();

  /// The unique key for this field.
  static const String key = 'cloze_inside';

  @override
  String getLocalisedLabel(AppModel appModel) => t.creator_field_cloze_inside;
}
