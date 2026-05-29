import 'dart:io';

import 'package:hibiki/creator.dart';
import 'package:hibiki/src/models/app_model.dart';

/// A collection of values that can be used to mutate the current context of
/// the creator.
class CreatorFieldValues {
  /// Initialise an immutable collection of the final parameters.
  ///
  /// HBK-AUDIT-078: 防御性复制两张 map，使 [textValues]/[extraValues] 真正
  /// 不可被外部别名修改（文档声称 "immutable collection"，此前却直接存引用）。
  CreatorFieldValues({
    Map<Field, String> textValues = const {},
    Map<String, String> extraValues = const {},
  })  : textValues = Map<Field, String>.unmodifiable(textValues),
        extraValues = Map<String, String>.unmodifiable(extraValues);

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
  ///
  /// HBK-AUDIT-078: 两张 map 都交给构造函数做防御性复制（之前只复制
  /// textValues，extraValues 直接按引用透传，导致拷贝与原对象共享同一张
  /// extraValues，违反文档承诺的 deep copy 语义）。
  CreatorFieldValues copyWith({
    Map<Field, String>? textValues,
    Map<String, String>? extraValues,
  }) {
    return CreatorFieldValues(
      textValues: textValues ?? this.textValues,
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
  ///
  /// Instance-deterministic: depends only on this object's text values. The
  /// image/audio-only-card idea from HBK-AUDIT-078 was reverted because
  /// imagesToExport/audioToExport read GLOBAL field state (globalFields), which
  /// would make an empty CreatorFieldValues report exportable from unrelated
  /// global state and is non-deterministic in tests. Supporting media-only
  /// cards needs an instance-scoped design, deferred.
  bool get isExportable {
    for (String value in textValues.values) {
      if (value.isNotEmpty) {
        return true;
      }
    }

    return false;
  }
}
