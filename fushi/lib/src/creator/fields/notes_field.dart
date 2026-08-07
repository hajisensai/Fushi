import 'package:flutter/material.dart';
import 'package:fushi/creator.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';

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
}
