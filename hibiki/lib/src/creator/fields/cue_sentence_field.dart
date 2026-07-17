import 'package:flutter/material.dart';
import 'package:hibiki/creator.dart';
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
}
