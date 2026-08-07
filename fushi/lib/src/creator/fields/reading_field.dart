import 'package:flutter/material.dart';
import 'package:fushi/creator.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';

/// Used to track the current sentence context from the current playing media
/// in the application.
class ReadingField extends Field {
  /// Initialise this field with the predetermined and hardset values.
  ReadingField._privateConstructor()
      : super(
          uniqueKey: key,
          label: 'Reading',
          description: 'Pronunciation or speech pattern.',
          icon: Icons.surround_sound_outlined,
        );

  /// Get the singleton instance of this field.
  static ReadingField get instance => _instance;

  static final ReadingField _instance = ReadingField._privateConstructor();

  /// The unique key for this field.
  static const String key = 'reading';

  @override
  String getLocalisedLabel(AppModel appModel) => t.creator_field_reading;
}
