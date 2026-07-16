import 'package:flutter/material.dart';
import 'package:hibiki/creator.dart';
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
}
