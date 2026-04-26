import 'package:json_annotation/json_annotation.dart';
import 'package:hibiki/creator.dart';
import 'package:hibiki/language.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/utils.dart';

@JsonSerializable()
class AnkiMapping {
  AnkiMapping({
    required this.label,
    required this.model,
    required this.fieldMappings,
    required this.creatorFieldKeys,
    required this.creatorCollapsedFieldKeys,
    required this.order,
    required this.tags,
    required this.exportMediaTags,
    required this.useBrTags,
    required this.prependDictionaryNames,
    this.enhancements,
    this.actions,
    this.id,
  });

  factory AnkiMapping.defaultMapping({
    required Language language,
    required int order,
  }) {
    return AnkiMapping(
      label: standardProfileName,
      model: standardModelName,
      fieldMappings: Map<String, String>.from(
          AnkiHandlebar.defaultFieldMappingsForStandardModel),
      creatorFieldKeys: defaultCreatorFieldKeys,
      creatorCollapsedFieldKeys: defaultCreatorCollapsedFieldKeys,
      order: order,
      tags: [standardModelName],
      enhancements: defaultEnhancementsByLanguage[language.languageCountryCode],
      actions: defaultActionsByLanguage[language.languageCountryCode],
      exportMediaTags: true,
      useBrTags: true,
      prependDictionaryNames: true,
    );
  }

  static const Map<String, Map<String, Map<int, String>>>
      defaultEnhancementsByLanguage = {
    'ja-JP': {
      SentenceField.key: {
        0: ClearFieldEnhancement.key,
        1: TextSegmentationEnhancement.key,
        2: SentencePickerEnhancement.key,
      },
      TermField.key: {
        0: ClearFieldEnhancement.key,
        1: SearchDictionaryEnhancement.key,
        2: OpenStashEnhancement.key,
      },
      ReadingField.key: {0: ClearFieldEnhancement.key},
      MeaningField.key: {
        0: ClearFieldEnhancement.key,
        1: TextSegmentationEnhancement.key,
      },
      NotesField.key: {0: ClearFieldEnhancement.key},
      ImageField.key: {
        0: ClearFieldEnhancement.key,
        1: CameraEnhancement.key,
        2: PickImageEnhancement.key,
        3: CropImageEnhancement.key,
      },
      AudioField.key: {
        0: ClearFieldEnhancement.key,
        1: PickAudioEnhancement.key,
        2: AudioRecorderEnhancement.key,
      },
      AudioSentenceField.key: {
        0: ClearFieldEnhancement.key,
      },
      TagsField.key: {
        0: ClearFieldEnhancement.key,
        1: SaveTagsEnhancement.key,
      },
      ContextField.key: {0: ClearFieldEnhancement.key},
      PitchAccentField.key: {0: ClearFieldEnhancement.key},
      FuriganaField.key: {0: ClearFieldEnhancement.key},
      FrequencyField.key: {0: ClearFieldEnhancement.key},
      CollapsedMeaningField.key: {0: ClearFieldEnhancement.key},
      ExpandedMeaningField.key: {0: ClearFieldEnhancement.key},
      HiddenMeaningField.key: {0: ClearFieldEnhancement.key},
      ClozeBeforeField.key: {0: ClearFieldEnhancement.key},
      ClozeAfterField.key: {0: ClearFieldEnhancement.key},
      ClozeInsideField.key: {0: ClearFieldEnhancement.key},
    },
    'en-US': {
      SentenceField.key: {
        0: ClearFieldEnhancement.key,
        1: TextSegmentationEnhancement.key
      },
      TermField.key: {
        0: ClearFieldEnhancement.key,
        1: SearchDictionaryEnhancement.key,
        2: OpenStashEnhancement.key,
      },
      ReadingField.key: {0: ClearFieldEnhancement.key},
      MeaningField.key: {
        0: ClearFieldEnhancement.key,
        1: TextSegmentationEnhancement.key,
      },
      NotesField.key: {0: ClearFieldEnhancement.key},
      ImageField.key: {
        0: ClearFieldEnhancement.key,
        1: CameraEnhancement.key,
        2: PickImageEnhancement.key,
        3: CropImageEnhancement.key,
      },
      AudioField.key: {
        0: ClearFieldEnhancement.key,
        1: PickAudioEnhancement.key,
        2: AudioRecorderEnhancement.key,
      },
      AudioSentenceField.key: {
        0: ClearFieldEnhancement.key,
      },
      TagsField.key: {
        0: ClearFieldEnhancement.key,
        1: SaveTagsEnhancement.key,
      },
      ContextField.key: {0: ClearFieldEnhancement.key},
      PitchAccentField.key: {0: ClearFieldEnhancement.key},
      FuriganaField.key: {0: ClearFieldEnhancement.key},
      FrequencyField.key: {0: ClearFieldEnhancement.key},
      CollapsedMeaningField.key: {0: ClearFieldEnhancement.key},
      ExpandedMeaningField.key: {0: ClearFieldEnhancement.key},
      HiddenMeaningField.key: {0: ClearFieldEnhancement.key},
      ClozeBeforeField.key: {0: ClearFieldEnhancement.key},
      ClozeAfterField.key: {0: ClearFieldEnhancement.key},
      ClozeInsideField.key: {0: ClearFieldEnhancement.key},
    },
  };

  static const List<String> defaultCreatorFieldKeys = [
    SentenceField.key,
    TermField.key,
    ReadingField.key,
    MeaningField.key,
    NotesField.key,
    ImageField.key,
    AudioField.key,
    AudioSentenceField.key,
  ];

  static const List<String> defaultCreatorCollapsedFieldKeys = [
    TagsField.key,
    ContextField.key,
    ClozeBeforeField.key,
    ClozeInsideField.key,
    ClozeAfterField.key,
    FuriganaField.key,
    FrequencyField.key,
    PitchAccentField.key,
  ];

  static const Map<String, Map<int, String>> defaultActionsByLanguage = {
    'ja-JP': {
      0: CardCreatorAction.key,
      1: InstantExportAction.key,
      2: AddToStashAction.key,
      3: CopyToClipboardAction.key,
      4: ShareAction.key,
      5: PlayAudioAction.key,
    },
    'en-US': {
      0: CardCreatorAction.key,
      1: InstantExportAction.key,
      2: AddToStashAction.key,
      3: CopyToClipboardAction.key,
      4: ShareAction.key,
      5: PlayAudioAction.key,
    }
  };

  static String standardModelName = 'hibiki Kinomoto';
  static String standardProfileName = 'Standard';

  int? id;
  final String label;
  final String model;

  /// Handlebar-based field mappings: Anki field name → handlebar pattern.
  Map<String, String> fieldMappings;

  List<String> creatorFieldKeys;
  List<String> creatorCollapsedFieldKeys;
  final List<String> tags;

  bool get isExportFieldsEmpty =>
      fieldMappings.values.where((v) => v.isNotEmpty).isEmpty;

  Map<int, String>? actions;

  String get actionsJson => QuickActionsConverter.toIsar(actions!);
  set actionsJson(String object) =>
      actions = QuickActionsConverter.fromIsar(object);

  late Map<String, Map<int, String>>? enhancements;

  String get enhancementsJson => EnhancementsConverter.toIsar(enhancements!);
  set enhancementsJson(String object) =>
      enhancements = EnhancementsConverter.fromIsar(object);

  static int autoModeSlotNumber = -1;

  bool? exportMediaTags;
  bool? useBrTags;
  bool? prependDictionaryNames;
  int order;

  List<Field> keysToFields(List<String> keys) {
    List<Field> fields = [];
    for (String key in keys) {
      final field = fieldsByKey[key];
      if (field != null) fields.add(field);
    }
    return fields;
  }

  List<Field> getCreatorFields() => keysToFields(creatorFieldKeys);

  List<Field> getCreatorCollapsedFields() =>
      keysToFields(creatorCollapsedFieldKeys);

  AnkiMapping copyWith({
    String? label,
    String? model,
    Map<String, String>? fieldMappings,
    List<String>? creatorFieldKeys,
    List<String>? creatorCollapsedFieldKeys,
    List<String>? tags,
    int? order,
    int? id,
    Map<String, Map<int, String>>? enhancements,
    Map<int, String>? actions,
    bool? exportMediaTags,
    bool? useBrTags,
    bool? prependDictionaryNames,
  }) {
    return AnkiMapping(
      label: label ?? this.label,
      model: model ?? this.model,
      fieldMappings:
          fieldMappings ?? Map<String, String>.from(this.fieldMappings),
      creatorFieldKeys: creatorFieldKeys ?? List.from(this.creatorFieldKeys),
      creatorCollapsedFieldKeys:
          creatorCollapsedFieldKeys ?? List.from(this.creatorCollapsedFieldKeys),
      tags: tags ?? this.tags,
      order: order ?? this.order,
      id: id ?? this.id,
      enhancements: enhancements ?? this.enhancements,
      actions: actions ?? this.actions,
      exportMediaTags: exportMediaTags ?? this.exportMediaTags,
      useBrTags: useBrTags ?? this.useBrTags,
      prependDictionaryNames:
          prependDictionaryNames ?? this.prependDictionaryNames,
    );
  }

  List<String> getManualFieldEnhancementNames({required Field field}) {
    return (enhancements![field.uniqueKey] ?? {})
        .entries
        .where((entry) => entry.key != autoModeSlotNumber)
        .map((entry) => entry.value)
        .toList();
  }

  String? getAutoFieldEnhancementName({required Field field}) {
    return (enhancements![field.uniqueKey] ?? {})[autoModeSlotNumber];
  }

  List<String> getActionNames() {
    return actions!.values.toList();
  }

  List<Enhancement> getManualFieldEnhancement(
      {required AppModel appModel, required Field field}) {
    List<String> enhancementNames =
        getManualFieldEnhancementNames(field: field);
    List<Enhancement> enhancements = enhancementNames
        .map((enhancementName) =>
            appModel.enhancements[field]![enhancementName]!)
        .toList();

    return enhancements;
  }

  Enhancement? getAutoFieldEnhancement(
      {required AppModel appModel, required Field field}) {
    String? enhancementName = getAutoFieldEnhancementName(field: field);
    if (enhancementName == null) {
      return null;
    }

    Enhancement? enhancement = appModel.enhancements[field]![enhancementName];
    return enhancement;
  }

  List<QuickAction> getActions({required AppModel appModel}) {
    List<String> actionNames = getActionNames();
    List<QuickAction> actions = actionNames
        .map((enhancementName) => appModel.quickActions[enhancementName]!)
        .toList();

    return actions;
  }

  @override
  bool operator ==(Object other) =>
      other is AnkiMapping && label == other.label;

  @override
  int get hashCode => label.hashCode;
}
