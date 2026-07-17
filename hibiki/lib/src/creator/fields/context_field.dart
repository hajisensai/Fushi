import 'package:flutter/material.dart';
import 'package:hibiki/creator.dart';
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
          icon: Icons.perm_media_outlined,
        );

  /// Get the singleton instance of this field.
  static ContextField get instance => _instance;

  static final ContextField _instance = ContextField._privateConstructor();

  /// The unique key for this field.
  static const String key = 'context';

  @override
  String getLocalisedLabel(AppModel appModel) => t.creator_field_context;
}
