import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/creator.dart';
import 'package:hibiki/dictionary.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';

/// Highlighted text in a sentence.
class ClozeInsideField extends Field {
  /// Initialise this field with the predetermined and hardset values.
  ClozeInsideField._privateConstructor()
      : super(
          uniqueKey: key,
          label: 'Cloze Inside',
          description: 'Highlighted text in a sentence.',
          icon: Icons.dehaze,
        );

  /// Get the singleton instance of this field.
  static ClozeInsideField get instance => _instance;

  static final ClozeInsideField _instance =
      ClozeInsideField._privateConstructor();

  /// The unique key for this field.
  static const String key = 'cloze_inside';

  @override
  String getLocalisedLabel(AppModel appModel) => t.creator_field_cloze_inside;

  @override
  String? onCreatorOpenAction({
    required WidgetRef ref,
    required AppModel appModel,
    required CreatorModel creatorModel,
    required DictionaryEntry entry,
    required bool creatorJustLaunched,
    required String? dictionaryName,
  }) {
    if (creatorJustLaunched) {
      return appModel.getCurrentSentence().textInside;
    } else {
      return null;
    }
  }
}
