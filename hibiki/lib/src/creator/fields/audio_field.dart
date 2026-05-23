import 'package:flutter/material.dart';
import 'package:hibiki/creator.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/utils.dart';

/// Returns audio information from context.
class AudioField extends BaseAudioField {
  /// Initialise this field with the predetermined and hardset values.
  AudioField._privateConstructor()
      : super(
          uniqueKey: key,
          label: 'Term Audio',
          description: 'Audio pertaining to the term. Text field can be used'
              ' to enter search terms for audio sources.',
          icon: Icons.audiotrack_outlined,
        );

  /// Get the singleton instance of this field.
  static AudioField get instance => _instance;

  static final AudioField _instance = AudioField._privateConstructor();

  /// The unique key for this field.
  static const String key = 'audio';

  @override
  String getLocalisedLabel(AppModel appModel) => t.creator_field_audio;
}
