/// 复习卡片字段的「AI 改写 / 补全」入口，笔记编辑页、浏览页检查器、复习页编辑底栏共用这一份
/// （BUG-5380：以前只有编辑页自己写了一份，检查器里同一个字段编辑器没有 AI 键）。
///
/// - 入口判据：AI 模块开着（[isAiModuleEnabled]，唯一 UI 判据）且字段装的是文字（[srsFieldAiEligible]）。
/// - 没有指派「复习卡片字段」的提供商就只提示、一个请求都不发（[srsFieldAiProvider]）。
/// - 提示词：内置模板 + 用户改动 / 变体（`ai_srs_field_actions.dart`），三个入口都经这里的
///   [showSrsFieldAiFor] 拼消息；输出语言按「设置 › AI › AI 输出语言」（空 = 界面语言）。
/// - 结果只交回调用方：编辑页 / 检查器写进字段编辑器的模型（[SrsFieldModel.reset]），编辑页点保存才落库、
///   检查器按自动保存走浏览页的写入（压进浏览页撤销栈）；复习页走它自己的可撤销写入。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_srs/fushi_srs.dart' show SrsFieldDef, SrsNoteTypeView;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/ai/ai_srs_field_actions.dart';
import 'package:fushi/src/ai/ai_srs_field_assistant.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_registry.dart' show isAiModuleEnabled;
import 'package:fushi/src/pages/implementations/srs/srs_field_ai_prompt_editor_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_field_ai_sheet.dart';
import 'package:fushi/src/pages/implementations/srs/srs_field_editors.dart'
    show SrsFieldModel;
import 'package:fushi/src/srs/srs_field_catalog.dart' as catalog;
import 'package:fushi/src/srs/srs_providers.dart' show srsRunLogged;
import 'package:fushi/src/stats/study_goals.dart' show studyGoalLanguageName;
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

/// 字段能不能 AI 改写：装文字的字段（文字 / 富文本），不是图片 / 音频 / 开关 / 数据。
bool srsFieldAiEligible(SrsFieldDef field) =>
    switch (catalog.srsFieldKind(field)) {
      catalog.SrsFieldKind.text || catalog.SrsFieldKind.rich => true,
      _ => false,
    };

/// 指派给「复习卡片字段」的 AI 提供商；没有指派就提示并返回 null（调用方据此一个请求都不发）。
AiProviderConfig? srsFieldAiProvider(AppModel appModel) {
  final AiProviderConfig? provider = appModel.prefsRepo
      .resolveAiFeatureProvider(AiFeature.srsNoteField);
  if (provider == null) FushiToast.show(msg: t.ai_assist_no_provider);
  return provider;
}

/// 语言标签 → 交给 AI 的语言名（各语言自称，[studyGoalLanguageName]）：`ja` → 日本語。
String srsFieldAiOutputLanguageName(String tag) => studyGoalLanguageName(tag);

/// 界面语言的标签。中文两份译文的文字体系是确定的（简体 / 繁體），按文字子标签给，
/// 免得语言名退化成笼统的「中文」。
String srsFieldAiAppLanguageTag(AppLocale locale) => switch (locale) {
  AppLocale.zhCn => 'zh-Hans',
  AppLocale.zhHk => 'zh-Hant',
  _ => locale.languageTag,
};

/// 「AI 输出语言」可选的语言标签（= App 的界面语言）。
List<String> srsFieldAiOutputLanguageTags() => <String>[
  for (final AppLocale locale in AppLocale.values)
    srsFieldAiAppLanguageTag(locale),
];

/// 实际生效的输出语言名：设置为空 = 跟随界面语言。
String srsFieldAiOutputLanguage(AppModel appModel) {
  final String tag = appModel.prefsRepo.aiOutputLanguage;
  return srsFieldAiOutputLanguageName(
    tag.isNotEmpty
        ? tag
        : srsFieldAiAppLanguageTag(LocaleSettings.currentLocale),
  );
}

/// 给 [field] 打开字段 AI 抽屉，返回字段的新值（null = 没采用）。
///
/// [valuesById] 每次生成时现取整条笔记各字段的值（编辑页 / 检查器里别的字段可能刚改过）。
Future<String?> showSrsFieldAiFor(
  BuildContext context, {
  required AppModel appModel,
  required AiProviderConfig provider,
  required SrsNoteTypeView noteType,
  required SrsFieldDef field,
  required String current,
  required Map<String, String> Function() valuesById,
}) => showSrsFieldAiSheet(
  context,
  fieldLabel: catalog.srsFieldDisplayName(field),
  fieldName: field.name,
  current: current,
  promptStore: appModel.prefsRepo,
  actionStore: appModel.prefsRepo,
  editPrompt: (BuildContext context, AiSrsFieldAction action) =>
      openSrsFieldAiPromptEditor(
        context,
        store: appModel.prefsRepo,
        target: SrsFieldAiPromptRef.forAction(action),
        preview: SrsFieldAiPromptPreview(
          noteTypeName: noteType.name,
          fields: noteType.fields,
          valuesById: valuesById(),
          targetFieldId: field.id,
          outputLanguage: srsFieldAiOutputLanguage(appModel),
          task: action.task,
        ),
      ),
  run: (AiSrsFieldAction action, String instruction) async {
    final AiChatClient client = AiChatClient();
    try {
      return await requestAiSrsField(
        client: client,
        provider: provider,
        prompt: buildAiSrsFieldPrompt(
          noteTypeName: noteType.name,
          fields: noteType.fields,
          valuesById: valuesById(),
          targetFieldId: field.id,
          action: action,
          actions: appModel.prefsRepo.aiFieldActions,
          instruction: instruction,
          outputLanguage: srsFieldAiOutputLanguage(appModel),
        ),
      );
    } finally {
      client.close();
    }
  },
);

/// 对一个字段编辑器跑字段 AI：确认提供商 → 抽屉 → 采用的结果整体换进模型（[SrsFieldModel.reset]，编辑器按
/// 新内容重新判类型；AI 可能写出列表等结构化内容）。
///
/// [model] 在抽屉关掉后现取：等待期间字段模型可能被换掉（编辑页换了笔记类型），取不到就不写。
Future<void> runSrsFieldAiOnModel(
  BuildContext context, {
  required AppModel appModel,
  required SrsNoteTypeView noteType,
  required SrsFieldDef field,
  required SrsFieldModel? Function() model,
  required Map<String, String> Function() valuesById,
}) async {
  final SrsFieldModel? before = model();
  if (before == null) return;
  final AiProviderConfig? provider = srsFieldAiProvider(appModel);
  if (provider == null) return;
  final String? value = await showSrsFieldAiFor(
    context,
    appModel: appModel,
    provider: provider,
    noteType: noteType,
    field: field,
    current: before.value,
    valuesById: valuesById,
  );
  if (value == null || !context.mounted) return;
  model()?.reset(value);
}

/// 字段标题行的「AI」键（`srs-field-ai-<字段名>`）：AI 模块开着、且字段装的是文字时才有，否则空表。
///
/// [context] 传页面 State 自己的 context（抽屉关掉后据它判断页面还在不在），[logTag] 进错误日志。
List<Widget> srsFieldAiHeaderActions(
  BuildContext context,
  WidgetRef ref, {
  required String logTag,
  required SrsNoteTypeView noteType,
  required SrsFieldDef field,
  required SrsFieldModel? Function() model,
  required Map<String, String> Function() valuesById,
}) {
  final AppModel appModel = ref.watch(appProvider);
  if (!isAiModuleEnabled(appModel.moduleVisibility) ||
      !srsFieldAiEligible(field)) {
    return const <Widget>[];
  }
  return <Widget>[
    FushiIconButton(
      key: ValueKey<String>('srs-field-ai-${field.name}'),
      icon: FushiIcons.aiAssistant,
      size: 20,
      tooltip: t.srs_note_field_ai,
      onTap: () => srsRunLogged(
        logTag,
        () => runSrsFieldAiOnModel(
          context,
          appModel: ref.read(appProvider),
          noteType: noteType,
          field: field,
          model: model,
          valuesById: valuesById,
        ),
      ),
    ),
  ];
}
