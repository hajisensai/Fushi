import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/creator.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/utils.dart';

/// An enhancement used to pick an appropriate term from a text field easily.
class TextSegmentationEnhancement extends Enhancement {
  /// Initialise this enhancement with the hardset parameters.
  TextSegmentationEnhancement({required super.field})
      : super(
          uniqueKey: key,
          label: 'Text Segmentation',
          description: 'Search or select a new term from segmented text.',
          icon: Icons.account_tree_outlined,
        );

  /// Used to identify this enhancement and to allow a constant value for the
  /// default mappings value of [AnkiMapping].
  static const String key = 'text_segmentation';

  @override
  String getLocalisedLabel(AppModel appModel) =>
      t.creator_enhancement_text_segmentation;

  @override
  Future<void> enhanceCreatorParams({
    required BuildContext context,
    required WidgetRef ref,
    required AppModel appModel,
    required CreatorModel creatorModel,
    required EnhancementTriggerCause cause,
  }) async {
    String sourceText = creatorModel.getFieldController(field).text;

    if (sourceText.trim().isEmpty) {
      HibikiToast.show(
        msg: t.no_text,
        toastLength: Toast.LENGTH_SHORT,
        gravity: ToastGravity.BOTTOM,
      );
      return;
    }

    await appModel.openTextSegmentationDialog(
      sourceText: sourceText,
      onSearch: (selection) {
        if (field is SentenceField) {
          creatorModel.setSentenceAndCloze(selection);
        }
        appModel.openPopupDictionaryLookup(searchTerm: selection.textInside);
      },
      onSelect: (selection) {
        if (field is SentenceField) {
          creatorModel.setSentenceAndCloze(selection);
        }
        creatorModel.getFieldController(TermField.instance).text =
            selection.textInside;
        Navigator.pop(context);
      },
    );
  }
}
