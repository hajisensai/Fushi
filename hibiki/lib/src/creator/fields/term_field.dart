import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/creator.dart';
import 'package:hibiki/dictionary.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';

/// Returns the word or phrase particular to a selected headword.
class TermField extends Field {
  /// Initialise this field with the predetermined and hardset values.
  TermField._privateConstructor()
      : super(
          uniqueKey: key,
          label: 'Term',
          description: 'Dictionary headword or phrase.',
          icon: Icons.speaker_notes_outlined,
        );

  /// Get the singleton instance of this field.
  static TermField get instance => _instance;

  static final TermField _instance = TermField._privateConstructor();

  /// The unique key for this field.
  static const String key = 'term';

  @override
  String getLocalisedLabel(AppModel appModel) => t.creator_field_term;

  @override
  String? onCreatorOpenAction({
    required WidgetRef ref,
    required AppModel appModel,
    required CreatorModel creatorModel,
    required DictionaryEntry entry,
    required bool creatorJustLaunched,
    required String? dictionaryName,
  }) {
    return entry.word;
  }
}
