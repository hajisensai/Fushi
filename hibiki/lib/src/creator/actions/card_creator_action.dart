import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/creator.dart';
import 'package:hibiki/dictionary.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/pages.dart';

/// An enhancement used effectively as a shortcut for opening the Card Creator.
class CardCreatorAction extends QuickAction {
  /// Initialise this enhancement with the hardset parameters.
  CardCreatorAction()
      : super(
          uniqueKey: key,
          label: 'Card Creator',
          description:
              'Create a card with the selected dictionary entry parameters and'
              ' edit before export.',
          icon: Icons.note_add,
          showInSingleDictionary: true,
        );

  /// Used to identify this enhancement and to allow a constant value for the
  /// default mappings value of [AnkiMapping].
  static const String key = 'card_creator';

  /// Whether this action should open the editor before exporting.
  static bool shouldOpenCreator({required bool silentExport}) => !silentExport;

  @override
  Future<void> executeAction({
    required BuildContext context,
    required WidgetRef ref,
    required AppModel appModel,
    required CreatorModel creatorModel,
    required DictionaryEntry entry,
    required String? dictionaryName,
  }) async {
    if (!shouldOpenCreator(silentExport: appModel.silentExport)) {
      await InstantExportAction().executeAction(
        context: context,
        ref: ref,
        appModel: appModel,
        creatorModel: creatorModel,
        entry: entry,
        dictionaryName: dictionaryName,
      );
      return;
    }

    if (appModel.isCreatorOpen) {
      Map<Field, String> newTextFields = {};
      for (Field field in appModel.activeFields) {
        String? newTextField = field.onCreatorOpenAction(
          ref: ref,
          appModel: appModel,
          creatorModel: creatorModel,
          entry: entry,
          creatorJustLaunched: false,
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
        Enhancement? enhancement = appModel.lastSelectedMapping
            .getAutoFieldEnhancement(appModel: appModel, field: field);

        if (enhancement != null) {
          enhancement.enhanceCreatorParams(
            context: context,
            ref: ref,
            appModel: appModel,
            creatorModel: creatorModel,
            cause: EnhancementTriggerCause.auto,
          );
        }
      }

      appModel.notifyRecursiveSearch();

      Navigator.of(context).popUntil((route) {
        return route.settings.name == (CreatorPage).toString();
      });
    } else {
      if (appModel.isMediaOpen && appModel.shouldHideStatusBarWhenInMedia) {
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
        await Future.delayed(const Duration(milliseconds: 5), () {});
      }

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

      await appModel.openCreator(
        ref: ref,
        killOnPop: false,
        creatorFieldValues: CreatorFieldValues(
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

      if (appModel.isMediaOpen && appModel.shouldHideStatusBarWhenInMedia) {
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      }
    }
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
