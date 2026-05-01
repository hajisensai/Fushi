import 'dart:io';

import 'package:hibiki/creator.dart';
import 'package:hibiki/src/models/app_model.dart';

/// A collection of values that can be used to mutate the current context of
/// the creator.
class CreatorFieldValues {
  /// Initialise an immutable collection of the final parameters.
  CreatorFieldValues({
    this.textValues = const {},
    this.extraValues = const {},
  });

  /// Builds creator values from the dictionary popup's mining payload.
  factory CreatorFieldValues.fromMineFields({
    required Map<String, String> fields,
    String? sentence,
    String? clozeBefore,
    String? clozeInside,
    String? clozeAfter,
    bool usePopupSelectionAsClozeInside = true,
  }) {
    final textValues = <Field, String>{
      TermField.instance: fields['expression'] ?? '',
      ReadingField.instance: fields['reading'] ?? '',
      MeaningField.instance: fields['glossary'] ?? '',
      FuriganaField.instance: fields['furiganaPlain'] ?? '',
      FrequencyField.instance:
          fields[FrequencyField.frequencyRankExtraKey] ?? '',
      PitchAccentField.instance:
          fields[PitchAccentField.pitchPositionsExtraKey] ?? '',
    };

    if (sentence != null) {
      textValues[SentenceField.instance] = sentence;
    }
    if (clozeBefore != null) {
      textValues[ClozeBeforeField.instance] = clozeBefore;
    }
    if (clozeInside != null) {
      textValues[ClozeInsideField.instance] = clozeInside;
    } else if (usePopupSelectionAsClozeInside) {
      textValues[ClozeInsideField.instance] =
          fields[popupSelectionTextExtraKey] ?? '';
    }
    if (clozeAfter != null) {
      textValues[ClozeAfterField.instance] = clozeAfter;
    }

    return CreatorFieldValues(
      textValues: textValues,
      extraValues: {
        'singleGlossaries': fields['singleGlossaries'] ?? '',
        'selectedDictionary': fields['selectedDictionary'] ?? '',
        popupSelectionTextExtraKey: fields[popupSelectionTextExtraKey] ?? '',
        ...FrequencyField.extraValuesFromMineFields(fields),
        ...PitchAccentField.extraValuesFromMineFields(fields),
      },
    );
  }

  /// Extra value key for the exact text selected inside the popup.
  static const String popupSelectionTextExtraKey = 'popupSelectionText';

  /// Creates a deep copy of this context but with the given fields replaced
  /// with the new values.
  CreatorFieldValues copyWith({
    Map<Field, String>? textValues,
    Map<String, String>? extraValues,
  }) {
    Map<Field, String>? newTextValues;
    if (textValues != null) {
      newTextValues = {};
      newTextValues.addAll(textValues);
    }

    return CreatorFieldValues(
      textValues: newTextValues ?? this.textValues,
      extraValues: extraValues ?? this.extraValues,
    );
  }

  /// A map of text values to override for certain supplied key fields.
  final Map<Field, String> textValues;

  /// Raw key-value pairs from the popup (e.g. singleGlossaries, selectedDictionary).
  final Map<String, String> extraValues;

  /// List of images to export to Anki.
  Map<Field, File> get imagesToExport {
    Map<Field, File> exportFiles = {};

    for (Field field in globalFields) {
      if (field is ImageExportField) {
        if (field.exportFile?.file != null) {
          exportFiles[field] = field.exportFile!.file!;
        }
      }
    }

    return exportFiles;
  }

  /// List of audio to export to Anki.
  Map<Field, File> get audioToExport {
    Map<Field, File> exportFiles = {};

    for (Field field in globalFields) {
      if (field is AudioExportField) {
        if (field.exportFile != null) {
          exportFiles[field] = field.exportFile!;
        }
      }
    }

    return exportFiles;
  }

  /// Whether or not to allow the export button to be pressed.
  bool get isExportable {
    for (String value in textValues.values) {
      if (value.isNotEmpty) {
        return true;
      }
    }

    return false;
  }
}
