import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/creator/enhancement.dart';
import 'package:fushi/src/creator/fields/tags_field.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/creator_model.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

/// An enhancement used to save the Tags field's last value.
class SaveTagsEnhancement extends Enhancement {
  /// Initialise this enhancement with the hardset parameters.
  SaveTagsEnhancement()
    : super(
        uniqueKey: key,
        label: 'Save Tags',
        description: 'Persist the current text in the Tags field.',
        icon: Icons.save_outlined,
        field: TagsField.instance,
      );

  /// Used to identify this enhancement and to allow a constant value for the
  /// default mappings value of [AnkiMapping].
  static const String key = 'save_tags';

  @override
  String getLocalisedLabel(AppModel appModel) =>
      t.creator_enhancement_save_tags;

  @override
  Future<void> enhanceCreatorParams({
    required BuildContext context,
    required WidgetRef ref,
    required AppModel appModel,
    required CreatorModel creatorModel,
    required EnhancementTriggerCause cause,
  }) async {
    String tags = creatorModel
        .getFieldController(TagsField.instance)
        .text
        .trim();
    appModel.setSavedTags(tags);

    FushiToast.show(
      msg: t.saved_tags,
      toastLength: Toast.LENGTH_SHORT,
      gravity: ToastGravity.BOTTOM,
      severity: ToastSeverity.success,
    );
  }
}
