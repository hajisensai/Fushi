import 'package:flutter/material.dart';
import 'package:fushi/creator.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';

/// Organise notes in a deck with space-delimited labels.
class TagsField extends Field {
  /// Initialise this field with the predetermined and hardset values.
  TagsField._privateConstructor()
      : super(
          uniqueKey: key,
          label: 'Tags',
          description: 'Organise notes in a deck with space-delimited labels.',
          icon: Icons.sell_outlined,
        );

  /// Get the singleton instance of this field.
  static TagsField get instance => _instance;

  static final TagsField _instance = TagsField._privateConstructor();

  /// The unique key for this field.
  static const String key = 'tags';

  @override
  String getLocalisedLabel(AppModel appModel) => t.creator_field_tags;
}
