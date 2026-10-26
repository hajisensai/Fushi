/// 一个字段的说明页：这个字段叫什么（人话名字 + 真实字段名）、装什么（说明，可自己写 / 让 AI 写）、
/// 长什么样（示例）、制卡时自动填什么，以及**在卡面上的位置**——预览用复习页同一个卡面视图渲染
/// 这个笔记类型的模板，把本字段的内容框出来高亮。
///
/// 说明写进字段定义（[SrsFieldDef.description]，随同步 / 导出到 Anki 的字段说明走）；内置字段没写
/// 时显示内置说明（[srsKnownFieldDescription]）。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_anki/fushi_anki_core.dart'
    show AnkiCardSpecialFields, AnkiRenderedCard, templateIdsToNames;
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/ai/ai_failure_text.dart';
import 'package:fushi/src/ai/ai_srs_template_assistant.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_registry.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_field_label.dart';
import 'package:fushi/src/pages/implementations/srs/srs_note_preview.dart'
    show SrsStablePreviewFace;
import 'package:fushi/src/pages/implementations/srs/srs_template_editor_page.dart'
    show SrsTemplatePreview, srsFieldPlaceholderHtml, srsRenderTemplatePreview;
import 'package:fushi/src/pages/implementations/srs/srs_ui.dart';
import 'package:fushi/src/pages/implementations/srs/srs_visual_template_panel.dart'
    show srsFieldKindIcon;
import 'package:fushi/src/srs/srs_field_catalog.dart';
import 'package:fushi/src/srs/srs_mining.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 高亮框（预览里框出本字段的内容）。只用内联样式：卡片 CSS 不认识它。
String srsFieldHighlightHtml(String value) =>
    '<span data-fushi-field-spot style="outline:2px dashed '
    'var(--fushi-srs-accent,#386A58);outline-offset:3px;border-radius:4px;'
    'background:rgba(127,127,127,0.16)">$value</span>';

/// 预览用的字段值：本字段换成高亮框包住的内容（样例空时用目录示例 / 字段名占位），
/// 其余字段用样例内容。
Map<String, String> srsFieldSpotlightValues({
  required SrsNoteTypeView type,
  required String fieldId,
  required Map<String, String> sampleById,
}) {
  final bool hasSample = sampleById.isNotEmpty;
  return <String, String>{
    for (final SrsFieldDef f in type.fields)
      f.name: () {
        final String sample = sampleById[f.id] ?? '';
        if (f.id != fieldId) {
          return hasSample ? sample : srsFieldPlaceholderHtml(f.name);
        }
        final String shown = sample.trim().isNotEmpty
            ? sample
            : (srsKnownField(f.name)?.example ??
                  srsFieldPlaceholderHtml(srsFieldDisplayName(f)));
        return srsFieldHighlightHtml(shown);
      }(),
  };
}

class SrsFieldInfoPage extends ConsumerStatefulWidget {
  const SrsFieldInfoPage({
    super.key,
    required this.noteTypeId,
    required this.fieldId,
  });

  final String noteTypeId;
  final String fieldId;

  @override
  ConsumerState<SrsFieldInfoPage> createState() => _SrsFieldInfoPageState();
}

class _SrsFieldInfoPageState extends ConsumerState<SrsFieldInfoPage> {
  final TextEditingController _description = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  bool _aiBusy = false;
  bool _previewBack = false;
  Object? _error;
  String _saved = '';

  SrsDbStore? _store;
  SrsNoteTypeView? _type;
  SrsNoteView? _sample;
  Map<String, String> _sampleValues = const <String, String>{};

  /// 框出本字段的示例卡（[_renderSpotlight]，载入时算一次）。
  SrsTemplatePreview _spot = const SrsTemplatePreview();

  @override
  void initState() {
    super.initState();
    _description.addListener(() {
      if (mounted) setState(() {});
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    _description.dispose();
    super.dispose();
  }

  SrsFieldDef? get _field => _type?.fieldById(widget.fieldId);

  bool get _dirty => _description.text.trim() != _saved;

  Future<void> _load() async {
    try {
      final SrsDbStore? store = await readSrsStore(ref);
      if (store == null) throw StateError('srs store unavailable');
      final SrsNoteTypeView? type = await store.noteType(widget.noteTypeId);
      if (type == null || type.fieldById(widget.fieldId) == null) {
        throw StateError('field not found');
      }
      // 只要一条样本：走索引取第一条 id，不把整个类型的笔记都列出来。
      final List<String> notes = await store.noteIdsOfType(type.id, limit: 1);
      final SrsNoteView? sample = notes.isEmpty
          ? null
          : await store.note(notes.first);
      final Map<String, String> values = sample == null
          ? const <String, String>{}
          : await store.expandFields(sample.fields, dropMissing: true);
      if (!mounted) return;
      _store = store;
      _type = type;
      _sample = sample;
      _sampleValues = values;
      _saved = type.fieldById(widget.fieldId)!.description;
      _description.text = _saved;
      _spot = _renderSpotlight(type);
      setState(() => _loading = false);
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsFieldInfo.load', e, stack);
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e;
        });
      }
    }
  }

  Future<void> _save() async {
    final SrsDbStore? store = _store;
    final SrsNoteTypeView? type = _type;
    if (store == null || type == null || _saving || !_dirty) return;
    setState(() => _saving = true);
    try {
      await store.setFieldDescription(
        type.id,
        widget.fieldId,
        _description.text,
      );
      if (!mounted) return;
      bumpSrsRevision(ref);
      setState(() => _saved = _description.text.trim());
      FushiToast.show(
        msg: t.srs_note_types_saved,
        severity: ToastSeverity.success,
      );
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsFieldInfo.save', e, stack);
      FushiToast.show(msg: t.srs_action_failed, severity: ToastSeverity.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 让 AI 写说明：结果只填进输入框（草稿），用户看过再点保存。
  Future<void> _aiDescribe() async {
    final SrsNoteTypeView? type = _type;
    final SrsFieldDef? field = _field;
    if (type == null || field == null || _aiBusy) return;
    final AiProviderConfig? provider = ref
        .read(appProvider)
        .prefsRepo
        .resolveAiFeatureProvider(AiFeature.srsTemplate);
    if (provider == null) {
      // 没有可用提供商就一个请求都不发（BUG-2694）。
      FushiToast.show(msg: t.ai_assist_no_provider);
      return;
    }
    setState(() => _aiBusy = true);
    final AiChatClient client = AiChatClient();
    try {
      final AiSrsTemplateSuggestion s = await requestAiSrsTemplate(
        client: client,
        provider: provider,
        request: t.srs_field_info_ai_request(name: field.name),
        noteType: type,
        sampleByFieldId: _sampleValues,
      );
      if (!mounted) return;
      final String? text = s.fieldDescriptions[field.id];
      if (text == null || text.isEmpty) {
        FushiToast.show(msg: t.ai_assist_empty);
        return;
      }
      _description.text = text;
    } on AiChatFailure catch (failure) {
      FushiToast.show(
        msg: t.ai_assist_failed(reason: aiFailureText(failure.message)),
        severity: ToastSeverity.error,
      );
    } finally {
      client.close();
      if (mounted) setState(() => _aiBusy = false);
    }
  }

  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    return showFushiConfirmDialog(
      context: context,
      title: t.srs_note_types_discard_title,
      message: t.srs_note_types_discard_body,
      confirmLabel: t.srs_note_types_discard,
      cancelLabel: t.cancel,
      icon: FushiIcons.warning,
      destructive: true,
    );
  }

  FushiToolbarItem get _saveItem => FushiToolbarItem(
    key: const ValueKey<String>('srs-field-info-save'),
    icon: FushiIcons.save,
    label: t.srs_note_save,
    onPressed: _saving || !_dirty ? null : () => unawaited(_save()),
  );

  @override
  Widget build(BuildContext context) {
    final bool apple = isGlassDesign(context);
    final SrsFieldDef? field = _field;
    final String title = field == null
        ? t.srs_field_info_title
        : srsFieldDisplayName(field);
    return PopScope<Object?>(
      canPop: !_dirty,
      onPopInvokedWithResult: (bool didPop, Object? result) async {
        if (didPop) return;
        final NavigatorState navigator = Navigator.of(context);
        if (await _confirmDiscard() && mounted) navigator.pop();
      },
      child: FushiPageScaffold(
        title: title,
        header: apple ? null : _buildTopBar(context, title),
        actions: apple
            ? <Widget>[
                FushiIconButton(
                  key: _saveItem.key,
                  icon: _saveItem.icon,
                  tooltip: _saveItem.label,
                  enabled: _saveItem.onPressed != null,
                  onTap: _saveItem.onPressed,
                ),
              ]
            : const <Widget>[],
        body: Builder(builder: _buildBody),
      ),
    );
  }

  Widget _buildTopBar(BuildContext context, String title) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final NavigatorState? navigator = Navigator.maybeOf(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.gap,
        tokens.spacing.page,
        tokens.spacing.gap,
      ),
      child: FushiFloatingTopBar(
        title: title,
        leading: <FushiToolbarItem>[
          if (navigator != null && navigator.canPop())
            FushiToolbarItem(
              icon: FushiIcons.back,
              label: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: () => unawaited(navigator.maybePop()),
            ),
        ],
        actions: <List<FushiToolbarItem>>[
          <FushiToolbarItem>[_saveItem],
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const SafeArea(bottom: false, child: FushiLoadingView());
    }
    final SrsNoteTypeView? type = _type;
    final SrsFieldDef? field = _field;
    if (_error != null || type == null || field == null) {
      return SafeArea(
        bottom: false,
        child: Center(
          child: FushiPlaceholderMessage(
            icon: FushiIcons.error,
            tone: FushiPlaceholderTone.error,
            message: t.error_load_failed,
            detail: _error == null ? null : '$_error',
          ),
        ),
      );
    }
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double top = tokens.spacing.gap + MediaQuery.paddingOf(context).top;
    final List<Widget> info = <Widget>[
      _identityCard(context, type, field),
      _descriptionCard(context, field),
      _sourceCard(context, type, field),
    ];
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final EdgeInsets bottom = withBottomSafeInset(
          context,
          EdgeInsets.only(bottom: tokens.spacing.section),
        );
        if (!srsUsesTwoPane(constraints)) {
          final List<Widget> all = <Widget>[
            ...info,
            _preview(context, type, field),
          ];
          return FushiEntranceScope(
            child: ListView.separated(
              padding: EdgeInsets.fromLTRB(
                tokens.spacing.page,
                top,
                tokens.spacing.page,
                bottom.bottom,
              ),
              itemCount: all.length,
              separatorBuilder: (BuildContext context, int index) =>
                  SizedBox(height: tokens.spacing.gap),
              itemBuilder: fushiStaggeredItemBuilder(
                (BuildContext context, int index) => all[index],
              ),
            ),
          );
        }
        final double half = tokens.spacing.gap * 0.75;
        return FushiEntranceScope(
          child: FushiPinnedPageChromeScope(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Expanded(
                  child: ListView.separated(
                    key: SrsAdaptiveSections.primaryPaneKey,
                    padding: EdgeInsets.fromLTRB(
                      tokens.spacing.page,
                      top,
                      half,
                      bottom.bottom,
                    ),
                    itemCount: info.length,
                    separatorBuilder: (BuildContext context, int index) =>
                        SizedBox(height: tokens.spacing.gap),
                    itemBuilder: fushiStaggeredItemBuilder(
                      (BuildContext context, int index) => info[index],
                    ),
                  ),
                ),
                Expanded(
                  child: Padding(
                    key: SrsAdaptiveSections.secondaryPaneKey,
                    padding: EdgeInsets.fromLTRB(
                      half,
                      top,
                      tokens.spacing.page,
                      bottom.bottom,
                    ),
                    child: FushiStaggeredEntrance(
                      index: info.length,
                      child: _preview(context, type, field, fill: true),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _identityCard(
    BuildContext context,
    SrsNoteTypeView type,
    SrsFieldDef field,
  ) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final SrsFieldKind kind = srsFieldKind(field);
    final SrsFieldInfo? known = srsKnownField(field.name);
    final String sample = aiSrsPlainText(_sampleValues[field.id] ?? '', 120);
    final String example = sample.isNotEmpty
        ? sample
        : aiSrsPlainText(known?.example ?? '', 120);
    return FushiCard(
      key: const ValueKey<String>('srs-field-info-identity'),
      tone: FushiCardTone.primary,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: tokens.spacing.gap,
        children: <Widget>[
          Row(
            spacing: tokens.spacing.gap * 1.5,
            children: <Widget>[
              FushiIcon(srsFieldKindIcon(kind), size: 32),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      srsFieldDisplayName(field),
                      style: context.fushiType.titleLarge,
                    ),
                    Text(
                      t.srs_field_info_raw_name(name: field.name),
                      style: context.fushiType.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
          Text(srsFieldKindLabel(kind), style: context.fushiType.labelLarge),
          if (example.isNotEmpty && kind != SrsFieldKind.image)
            Text(
              t.srs_field_info_example(value: example),
              key: const ValueKey<String>('srs-field-info-example'),
              style: context.fushiType.bodyMedium,
            ),
          if (_sample == null)
            Text(
              t.srs_field_info_example_from_catalog,
              style: context.fushiType.bodySmall,
            ),
        ],
      ),
    );
  }

  Widget _descriptionCard(BuildContext context, SrsFieldDef field) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final String? builtin = srsKnownFieldDescription(field.name);
    final bool usingBuiltin =
        _description.text.trim().isEmpty && builtin != null;
    final bool aiEnabled = isAiModuleEnabled(
      ref.watch(appProvider).moduleVisibility,
    );
    return FushiCard(
      key: const ValueKey<String>('srs-field-info-description'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: tokens.spacing.gap,
        children: <Widget>[
          Text(
            t.srs_field_info_description,
            style: context.fushiType.titleSmall,
          ),
          if (usingBuiltin)
            Text(
              builtin,
              key: const ValueKey<String>('srs-field-info-builtin-description'),
              style: context.fushiType.bodyMedium,
            ),
          FushiTextField(
            key: const ValueKey<String>('srs-field-info-description-input'),
            controller: _description,
            minLines: 2,
            maxLines: 6,
            hintText: usingBuiltin
                ? t.srs_field_info_description_override_hint
                : t.srs_field_info_description_hint,
          ),
          if (aiEnabled)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: FushiFilledButton.tonalIcon(
                key: const ValueKey<String>('srs-field-info-ai'),
                onPressed: _aiBusy ? null : () => unawaited(_aiDescribe()),
                icon: const FushiIcon(FushiIcons.aiAssistant),
                label: Text(
                  _aiBusy ? t.srs_field_info_ai_busy : t.srs_field_info_ai,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _sourceCard(
    BuildContext context,
    SrsNoteTypeView type,
    SrsFieldDef field,
  ) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final AppModel app = ref.read(appProvider);
    final String slot =
        srsMiningFieldMappingsFor(
          type: type,
          builtinKey: type.builtinKey,
          profileUid: _store!.profileUid,
          stored: app.srsMiningDestination.fieldMappingsByType[type.id],
        )[field.id] ??
        '';
    final List<String> used = <String>[
      for (final SrsTemplateDef tpl in type.templates)
        if (_references(tpl, field.id)) tpl.name,
    ];
    return FushiCard(
      key: const ValueKey<String>('srs-field-info-source'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: tokens.spacing.gap,
        children: <Widget>[
          Text(t.srs_field_info_usage, style: context.fushiType.titleSmall),
          Text(
            srsMiningSlotText(slot),
            key: const ValueKey<String>('srs-field-info-mining'),
            style: context.fushiType.bodyMedium,
          ),
          Text(
            used.isEmpty
                ? t.srs_field_info_templates_none
                : t.srs_field_info_templates(names: used.join('、')),
            style: context.fushiType.bodyMedium,
          ),
        ],
      ),
    );
  }

  static bool _references(SrsTemplateDef tpl, String fieldId) =>
      tpl.front.contains('fld:$fieldId') || tpl.back.contains('fld:$fieldId');

  /// 框出本字段的示例卡。载入时算一次存进 State：说明框每敲一个字都会重建页面，
  /// 不该每次都把几十 KB 的模板（Lapis / Fushi 卡）重新解析渲染一遍。
  SrsTemplatePreview _renderSpotlight(SrsNoteTypeView type) {
    final SrsTemplateDef? tpl =
        type.templates
            .where((SrsTemplateDef x) => _references(x, widget.fieldId))
            .firstOrNull ??
        type.templates.firstOrNull;
    if (tpl == null) return const SrsTemplatePreview();
    final Map<String, String> idToName = <String, String>{
      for (final SrsFieldDef f in type.fields) f.id: f.name,
    };
    return srsRenderTemplatePreview(
      front: templateIdsToNames(tpl.front, idToName),
      back: templateIdsToNames(tpl.back, idToName),
      fieldsByName: srsFieldSpotlightValues(
        type: type,
        fieldId: widget.fieldId,
        sampleById: _sampleValues,
      ),
      isCloze: type.isCloze,
      // 与模板编辑器同口径：填空预览 c1；普通类型按模板在列表里的位置。
      cardOrd: type.isCloze ? 0 : type.templates.indexOf(tpl),
      specials: AnkiCardSpecialFields(
        tags: _sample?.tags ?? const <String>[],
        noteTypeName: type.name,
        cardName: tpl.name,
      ),
    );
  }

  Widget _preview(
    BuildContext context,
    SrsNoteTypeView type,
    SrsFieldDef field, {
    bool fill = false,
  }) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final AnkiRenderedCard? card = _spot.card;
    final String language = ref.read(appProvider).defaultContentLanguage;
    final bool empty = card == null || card.isEmpty;
    // 高亮框是注入卡面 HTML 的，所以这里总用整面 WebView（原生 Fushi 卡面画不出它）。
    final Widget surface = FushiCard(
      key: const ValueKey<String>('srs-field-info-preview'),
      padding: EdgeInsets.zero,
      pressScale: false,
      child: SrsStablePreviewFace(
        face: card == null || card.isEmpty
            ? null
            : SrsCardFace(
                cardId: 'field-spot-${field.id}',
                showingAnswer: _previewBack,
                bodyHtml: _previewBack ? card.answer : card.question,
                css: type.css,
                languageCode: language.isEmpty ? null : language,
                fushiCard: type.builtinKey == kSrsBuiltinFushiCardKey,
                onBridgeKey: (_) {},
              ),
        overlay: empty
            ? Center(
                child: FushiPlaceholderMessage(
                  icon: FushiIcons.info,
                  message: t.srs_note_types_preview_empty,
                ),
              )
            : null,
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: tokens.spacing.gap,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                t.srs_field_info_where,
                style: context.fushiType.titleSmall,
              ),
            ),
            FushiSegmentedButton<bool>(
              key: const ValueKey<String>('srs-field-info-preview-side'),
              showSelectedIcon: false,
              segments: <ButtonSegment<bool>>[
                ButtonSegment<bool>(
                  value: false,
                  label: Text(t.srs_note_types_side_front),
                ),
                ButtonSegment<bool>(
                  value: true,
                  label: Text(t.srs_note_types_side_back),
                ),
              ],
              selected: <bool>{_previewBack},
              onSelectionChanged: (Set<bool> s) =>
                  setState(() => _previewBack = s.first),
            ),
          ],
        ),
        Text(t.srs_field_info_where_hint, style: context.fushiType.bodySmall),
        if (fill)
          Expanded(child: surface)
        else
          SizedBox(height: 320, child: surface),
      ],
    );
  }
}

/// 字段大类的文字。
String srsFieldKindLabel(SrsFieldKind kind) => switch (kind) {
  SrsFieldKind.text => t.srs_field_kind_text,
  SrsFieldKind.rich => t.srs_field_kind_rich,
  SrsFieldKind.audio => t.srs_field_kind_audio,
  SrsFieldKind.image => t.srs_field_kind_image,
  SrsFieldKind.flag => t.srs_field_kind_flag,
  SrsFieldKind.data => t.srs_field_kind_data,
};
