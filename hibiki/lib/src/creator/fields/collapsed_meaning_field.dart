import 'package:flutter/material.dart';
import 'package:hibiki/creator.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';

/// Used to return a formatted text from hidden dictionary entries from
/// collapsed dictionaries only.
class CollapsedMeaningField extends Field {
  /// Initialise this field with the predetermined and hardset values.
  CollapsedMeaningField._privateConstructor()
      : super(
          uniqueKey: key,
          label: 'Collapsed Meaning',
          description: 'Dictionary definitions only from collapsed'
              ' dictionaries.',
          icon: Icons.close_fullscreen_outlined,
        );

  /// Get the singleton instance of this field.
  static CollapsedMeaningField get instance => _instance;

  static final CollapsedMeaningField _instance =
      CollapsedMeaningField._privateConstructor();

  /// The unique key for this field.
  static const String key = 'collapsed_meaning';

  @override
  String getLocalisedLabel(AppModel appModel) =>
      t.creator_field_collapsed_meaning;
}
