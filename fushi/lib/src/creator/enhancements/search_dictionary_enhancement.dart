import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/creator/enhancement.dart';
import 'package:fushi/src/creator/field.dart';
import 'package:fushi/src/creator/fields/sentence_field.dart';
import 'package:fushi/src/creator/fields/term_field.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/creator_model.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

/// An enhancement used effectively as a shortcut for performing a dictionary
/// search.
class SearchDictionaryEnhancement extends Enhancement {
  /// Initialise this enhancement with the hardset parameters.
  SearchDictionaryEnhancement()
    : super(
        uniqueKey: key,
        label: 'Search Dictionary',
        description: 'Search the dictionary with the content of a field.',
        icon: Icons.search,
        field: TermField.instance,
      );

  /// Used to identify this enhancement and to allow a constant value for the
  /// default mappings value of [AnkiMapping].
  static const String key = 'search_dictionary';

  @override
  String getLocalisedLabel(AppModel appModel) =>
      t.creator_enhancement_search_dictionary;

  @override
  Future<void> enhanceCreatorParams({
    required BuildContext context,
    required WidgetRef ref,
    required AppModel appModel,
    required CreatorModel creatorModel,
    required EnhancementTriggerCause cause,
  }) async {
    String searchTerm = creatorModel.getFieldController(field).text.trim();

    if (searchTerm.isEmpty) {
      Field fallbackField = SentenceField.instance;
      searchTerm = creatorModel.getFieldController(fallbackField).text.trim();
      if (searchTerm.isEmpty) {
        FushiToast.show(
          msg: t.no_text_to_search,
          toastLength: Toast.LENGTH_SHORT,
          gravity: ToastGravity.BOTTOM,
          severity: ToastSeverity.error,
        );
        return;
      } else {
        FushiToast.show(
          msg: t.field_fallback_used(
            field: field.getLocalisedLabel(appModel),
            secondField: fallbackField.getLocalisedLabel(appModel),
          ),
          toastLength: Toast.LENGTH_SHORT,
          gravity: ToastGravity.BOTTOM,
          severity: ToastSeverity.warning,
        );
      }
    }

    appModel.openPopupDictionaryLookup(searchTerm: searchTerm);
  }
}
