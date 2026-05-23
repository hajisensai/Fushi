import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/creator.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';

/// An enhancement used to view and manage the Stash.
class OpenStashEnhancement extends Enhancement {
  /// Initialise this enhancement with the hardset parameters.
  OpenStashEnhancement({required super.field})
      : super(
          uniqueKey: key,
          label: 'Open Stash',
          description: 'View and manage previously stashed text.',
          icon: Icons.collections_bookmark_outlined,
        );

  /// Used to identify this enhancement and to allow a constant value for the
  /// default mappings value of [AnkiMapping].
  static const String key = 'open_stash';

  @override
  String getLocalisedLabel(AppModel appModel) =>
      t.creator_enhancement_open_stash;

  @override
  Future<void> enhanceCreatorParams({
    required BuildContext context,
    required WidgetRef ref,
    required AppModel appModel,
    required CreatorModel creatorModel,
    required EnhancementTriggerCause cause,
  }) async {
    appModel.openStash(
      onSelect: (selection) {
        creatorModel.getFieldController(field).text = selection;
      },
      onSearch: (selection) {
        appModel.openPopupDictionaryLookup(searchTerm: selection);
      },
    );
  }
}
