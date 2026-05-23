import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/creator.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';

/// Used to track the current sentence context from the current playing media
/// in the application.
class SentenceField extends Field {
  /// Initialise this field with the predetermined and hardset values.
  SentenceField._privateConstructor()
      : super(
          uniqueKey: key,
          label: 'Sentence',
          description:
              'Subtitles, book excerpts and other contextual information.',
          icon: Icons.format_align_center_outlined,
        );

  /// Get the singleton instance of this field.
  static SentenceField get instance => _instance;

  static final SentenceField _instance = SentenceField._privateConstructor();

  /// The unique key for this field.
  static const String key = 'sentence';

  @override
  String getLocalisedLabel(AppModel appModel) => t.creator_field_sentence;

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
      return appModel.getCurrentSentence().text.trim();
    } else {
      return null;
    }
  }
}
