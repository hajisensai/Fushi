import 'package:flutter/material.dart';
import 'package:hibiki/creator.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/utils.dart';

/// Returns audio information from context.
class AudioSentenceField extends BaseAudioField {
  /// Initialise this field with the predetermined and hardset values.
  AudioSentenceField._privateConstructor()
      : super(
          uniqueKey: key,
          label: 'Sentence Audio',
          description:
              'Audio pertaining to the sentence. Text field can be used'
              ' to enter search terms for audio sources.',
          icon: Icons.queue_music_outlined,
        );

  /// Get the singleton instance of this field.
  static AudioSentenceField get instance => _instance;

  static final AudioSentenceField _instance =
      AudioSentenceField._privateConstructor();

  /// The unique key for this field.
  static const String key = 'audio_sentence';

  @override
  String getLocalisedLabel(AppModel appModel) => t.creator_field_audio_sentence;
}
