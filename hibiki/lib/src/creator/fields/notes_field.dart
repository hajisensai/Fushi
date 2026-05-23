import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/creator.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';

/// Supplies supplementary data that may be useful to include in a card.
class NotesField extends Field {
  /// Initialise this field with the predeAudioined and hardset values.
  NotesField._privateConstructor()
      : super(
          uniqueKey: key,
          label: 'Notes',
          description: 'Supplementary information or personal observations.',
          icon: Icons.description_outlined,
        );

  /// Get the singleton instance of this field.
  static NotesField get instance => _instance;

  static final NotesField _instance = NotesField._privateConstructor();

  /// The unique key for this field.
  static const String key = 'notes';

  @override
  String getLocalisedLabel(AppModel appModel) => t.creator_field_notes;

  @override
  String? onCreatorOpenAction({
    required WidgetRef ref,
    required AppModel appModel,
    required CreatorModel creatorModel,
    required DictionaryEntry entry,
    required bool creatorJustLaunched,
    required String? dictionaryName,
  }) {
    return null;
  }
}
