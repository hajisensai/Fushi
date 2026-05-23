import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/creator.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/utils.dart';

/// An enhancement used to pick a sentence from text.
class SentencePickerEnhancement extends Enhancement {
  /// Initialise this enhancement with the hardset parameters.
  SentencePickerEnhancement({required super.field})
      : super(
          uniqueKey: key,
          label: 'Sentence Picker',
          description: 'Pick sentences delimited by punctuation and spacing.',
          icon: Icons.colorize_outlined,
        );

  /// Used to identify this enhancement and to allow a constant value for the
  /// default mappings value of [AnkiMapping].
  static const String key = 'sentence_picker';

  @override
  String getLocalisedLabel(AppModel appModel) =>
      t.creator_enhancement_sentence_picker;

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

    appModel.openExampleSentenceDialog(
      exampleSentences: appModel.targetLanguage
          .getSentences(sourceText)
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList(),
      onSelect: (selection) {
        creatorModel.setSentenceAndCloze(
          HibikiTextSelection(
            text: selection
                .join(appModel.targetLanguage.isSpaceDelimited ? ' ' : '')
                .trim(),
          ),
        );
      },
    );
  }
}
