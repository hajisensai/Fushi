import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/creator.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';

class CueSentenceField extends Field {
  CueSentenceField._privateConstructor()
      : super(
          uniqueKey: key,
          label: 'Cue Sentence',
          description:
              'Full subtitle cue text without punctuation segmentation.',
          icon: Icons.subtitles_outlined,
        );

  static CueSentenceField get instance => _instance;

  static final CueSentenceField _instance =
      CueSentenceField._privateConstructor();

  static const String key = 'cue_sentence';

  @override
  String getLocalisedLabel(AppModel appModel) => t.creator_field_cue_sentence;

  @override
  String? onCreatorOpenAction({
    required WidgetRef ref,
    required AppModel appModel,
    required CreatorModel creatorModel,
    required DictionaryEntry entry,
    required bool creatorJustLaunched,
    required String? dictionaryName,
  }) {
    if (creatorJustLaunched) {
      final String cue = appModel.getCurrentCueSentence().text.trim();
      if (cue.isNotEmpty) return cue;
      return appModel.getCurrentSentence().text.trim();
    } else {
      return null;
    }
  }
}
