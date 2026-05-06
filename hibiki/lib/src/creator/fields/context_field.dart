import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/creator.dart';
import 'package:hibiki/dictionary.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';

/// Returns information about the current context in human-readable format
class ContextField extends Field {
  /// Initialise this field with the predetermined and hardset values.
  ContextField._privateConstructor()
      : super(
          uniqueKey: key,
          label: 'Context',
          description: 'Name of current source media.',
          icon: Icons.perm_media,
        );

  /// Get the singleton instance of this field.
  static ContextField get instance => _instance;

  static final ContextField _instance = ContextField._privateConstructor();

  /// The unique key for this field.
  static const String key = 'context';

  @override
  String getLocalisedLabel(AppModel appModel) => t.creator_field_context;

  @override
  String? onCreatorOpenAction({
    required WidgetRef ref,
    required AppModel appModel,
    required CreatorModel creatorModel,
    required DictionaryEntry entry,
    required bool creatorJustLaunched,
    required String? dictionaryName,
  }) {
    if (appModel.currentMediaItem != null) {
      return appModel.currentMediaItem!.title;
    } else {
      return '';
    }
  }
}
