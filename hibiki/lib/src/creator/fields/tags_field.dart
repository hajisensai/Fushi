import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/creator.dart';
import 'package:hibiki/dictionary.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';

/// Organise notes in a deck with space-delimited labels.
class TagsField extends Field {
  /// Initialise this field with the predetermined and hardset values.
  TagsField._privateConstructor()
      : super(
          uniqueKey: key,
          label: 'Tags',
          description: 'Organise notes in a deck with space-delimited labels.',
          icon: Icons.sell,
        );

  /// Get the singleton instance of this field.
  static TagsField get instance => _instance;

  static final TagsField _instance = TagsField._privateConstructor();

  /// The unique key for this field.
  static const String key = 'tags';

  @override
  String getLocalisedLabel(AppModel appModel) => t.creator_field_tags;

  @override
  String? onCreatorOpenAction({
    required WidgetRef ref,
    required AppModel appModel,
    required CreatorModel creatorModel,
    required DictionaryEntry entry,
    required bool creatorJustLaunched,
    required String? dictionaryName,
  }) {
    String base = appModel.savedTags;

    // Auto-add the current book title as a tag if enabled and a book is open.
    if (appModel.autoAddBookNameToTags && appModel.isMediaOpen) {
      final item = appModel.getCurrentMediaItem();
      if (item != null) {
        // Sanitise: Anki tags are space-delimited, so replace spaces with
        // underscores to keep the title as a single tag.
        final bookTag = item.title
            .replaceAll(' ', '_')
            .replaceAll('\t', '_');
        if (bookTag.isNotEmpty) {
          if (base.isEmpty) {
            base = bookTag;
          } else if (!base.split(' ').contains(bookTag)) {
            base = '$base $bookTag';
          }
        }
      }
    }

    return base;
  }
}
