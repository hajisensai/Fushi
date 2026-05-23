import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/creator.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/utils.dart';

/// An enhancement used to pop the latest element of the Stash onto a field.
class PopFromStashEnhancement extends Enhancement {
  /// Initialise this enhancement with the hardset parameters.
  PopFromStashEnhancement({required super.field})
      : super(
          uniqueKey: key,
          label: 'Pop From Stash',
          description: 'Quickly pop the latest item in the Stash.',
          icon: Icons.bookmark_remove_outlined,
        );

  /// Used to identify this enhancement and to allow a constant value for the
  /// default mappings value of [AnkiMapping].
  static const String key = 'pop_from_stash';

  @override
  String getLocalisedLabel(AppModel appModel) =>
      t.creator_enhancement_pop_from_stash;

  @override
  Future<void> enhanceCreatorParams({
    required BuildContext context,
    required WidgetRef ref,
    required AppModel appModel,
    required CreatorModel creatorModel,
    required EnhancementTriggerCause cause,
  }) async {
    List<String> stashContents = appModel.getStash();
    if (stashContents.isEmpty) {
      HibikiToast.show(
        msg: t.stash_nothing_to_pop,
        toastLength: Toast.LENGTH_SHORT,
        gravity: ToastGravity.BOTTOM,
      );
    } else {
      String lastStashItem = stashContents.last;

      appModel.removeFromStash(term: lastStashItem);
      creatorModel.getFieldController(field).text = lastStashItem;
    }
  }
}
