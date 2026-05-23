import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ruby_text/ruby_text.dart';
import 'package:hibiki/creator.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';

/// Returns the formatted furigana HTML of a [DictionaryEntry].
class FuriganaField extends Field {
  /// Initialise this field with the predetermined and hardset values.
  FuriganaField._privateConstructor()
      : super(
          uniqueKey: key,
          label: 'Furigana',
          description: 'Pre-fills text to export for Furigana.',
          icon: Icons.data_array_outlined,
        );

  /// Get the singleton instance of this field.
  static FuriganaField get instance => _instance;

  static final FuriganaField _instance = FuriganaField._privateConstructor();

  /// The unique key for this field.
  static const String key = 'furigana';

  @override
  String getLocalisedLabel(AppModel appModel) => t.creator_field_furigana;

  @override
  String? onCreatorOpenAction({
    required WidgetRef ref,
    required AppModel appModel,
    required CreatorModel creatorModel,
    required DictionaryEntry entry,
    required bool creatorJustLaunched,
    required String? dictionaryName,
  }) {
    if (appModel.targetLanguage is! JapaneseLanguage) {
      return null;
    }

    List<RubyTextData>? rubyDatas = JapaneseLanguage.instance.fetchFurigana(
      entry: entry,
    );

    if (rubyDatas == null) {
      return '';
    }

    StringBuffer buffer = StringBuffer();
    for (RubyTextData rubyData in rubyDatas) {
      if (rubyData.ruby != null && rubyData.ruby!.trim().isNotEmpty) {
        buffer.write(' ${rubyData.text}[${rubyData.ruby}]');
      } else {
        buffer.write(rubyData.text);
      }
    }

    return buffer.toString();
  }
}
