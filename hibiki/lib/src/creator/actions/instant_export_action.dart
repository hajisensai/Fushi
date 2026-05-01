import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/creator.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/dictionary.dart';

/// An enhancement used effectively as a shortcut for exporting a card.
class InstantExportAction extends QuickAction {
  /// Initialise this enhancement with the hardset parameters.
  InstantExportAction()
      : super(
          uniqueKey: key,
          label: 'Instant Export',
          description:
              'Export a card with the selected dictionary entry parameters.',
          icon: Icons.send,
          showInSingleDictionary: true,
        );

  /// Used to identify this enhancement and to allow a constant value for the
  /// default mappings value of [AnkiMapping].
  static const String key = 'instant_export';

  @override
  Future<void> executeAction({
    required BuildContext context,
    required WidgetRef ref,
    required AppModel appModel,
    required CreatorModel creatorModel,
    required DictionaryEntry entry,
    required String? dictionaryName,
  }) async {
    await appModel.getModelList();
    CreatorModel creatorModel = ref.read(instantExportProvider);

    Map<Field, String> newTextFields = {};
    for (Field field in appModel.activeFields) {
      String? newTextField = field.onCreatorOpenAction(
        ref: ref,
        appModel: appModel,
        creatorModel: creatorModel,
        entry: entry,
        creatorJustLaunched: true,
        dictionaryName: dictionaryName,
      );

      if (newTextField != null) {
        newTextFields[field] = newTextField;
      }
    }

    creatorModel.copyContext(
      CreatorFieldValues(
        textValues: newTextFields,
        extraValues: {
          ...FrequencyField.extraValuesFromEntry(entry),
          ...PitchAccentField.extraValuesFromEntry(
            appModel: appModel,
            entry: entry,
          ),
        },
      ),
    );

    for (Field field in appModel.activeFields) {
      /// If a media source has a generate images or audio function, then use that
      /// over any set auto enhancement.
      if (appModel.isMediaOpen && appModel.getCurrentMediaItem() != null) {
        MediaSource mediaSource =
            appModel.getCurrentMediaItem()!.getMediaSource(appModel: appModel);
        if (field is ImageField && mediaSource.overridesAutoImage) {
          await field.setImages(
            appModel: appModel,
            creatorModel: creatorModel,
            searchTerm: '',
            newAutoCannotOverride: true,
            cause: EnhancementTriggerCause.manual,
            generateImages: () async {
              return mediaSource.generateImages(
                appModel: appModel,
                item: appModel.getCurrentMediaItem()!,
                data: mediaSource.currentExtraData,
              );
            },
          );
          continue;
        }
        if (field is AudioSentenceField && mediaSource.overridesAutoAudio) {
          await field.setAudio(
            appModel: appModel,
            creatorModel: creatorModel,
            searchTerm: '',
            newAutoCannotOverride: true,
            cause: EnhancementTriggerCause.manual,
            generateAudio: () async {
              return mediaSource.generateAudio(
                appModel: appModel,
                item: appModel.getCurrentMediaItem()!,
              );
            },
          );
          continue;
        }
      }

      Enhancement? enhancement = appModel.lastSelectedMapping
          .getAutoFieldEnhancement(appModel: appModel, field: field);

      if (enhancement != null && context.mounted) {
        await enhancement.enhanceCreatorParams(
          context: context,
          ref: ref,
          appModel: appModel,
          creatorModel: creatorModel,
          cause: EnhancementTriggerCause.auto,
        );
      }
    }

    await appModel.addNote(
      creatorFieldValues: creatorModel.getExportDetails(ref),
      mapping: appModel.lastSelectedMapping,
      deck: appModel.lastSelectedDeckName,
      onSuccess: () {
        creatorModel.clearAll(
          overrideLocks: true,
          savedTags: appModel.savedTags,
        );

        /// Need to clear media as these conflict.
        CreatorModel cardCreatorModel = ref.read(creatorProvider);
        cardCreatorModel.clearField(
          ImageField.instance,
          savedTags: appModel.savedTags,
        );
        cardCreatorModel.clearField(
          AudioField.instance,
          savedTags: appModel.savedTags,
        );
        cardCreatorModel.clearField(
          SentenceField.instance,
          savedTags: appModel.savedTags,
        );
      },
    );
  }

  @override
  Future<Color?> getIconColor({
    required AppModel appModel,
    required DictionaryEntry entry,
  }) async {
    bool hasDuplicates = await appModel.checkForDuplicates(entry.word);
    if (hasDuplicates) {
      return Colors.red;
    } else {
      return null;
    }
  }
}
