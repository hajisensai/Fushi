/// 卡片模板编辑器：可视化 / 正面模板 / 背面模板 / 共享样式（CSS）四个标签页 + 实时预览。
///
/// - 「可视化」页（[SrsVisualTemplatePanel]）按块拼一面卡，改动编译进正面 / 背面源码（布局以注释
///   形式写在源码开头，见 srs_visual_template.dart）：源码仍是唯一真相，预览、未保存判断、保存都
///   走同一条路径；「让 AI 帮忙」的结果也只进源码草稿。
/// - 编辑时模板按**字段名**显示（`{{Front}}`），保存时换回 fieldId 引用（铁律 D：改字段名不动模板）。
/// - 预览用本笔记类型的第一条笔记（没有笔记就用字段名当示例内容），经与复习页同一个卡面视图
///   （[srsCardFaceBuilderProvider]）渲染；模板有语法错误 / 引用了不存在的字段时显示错误、不许保存。
/// - 有未保存的修改时离开要确认。
library;

import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_anki/fushi_anki_core.dart'
    show
        AnkiCardSpecialFields,
        AnkiRenderedCard,
        AnkiTemplateError,
        renderAnkiCard,
        templateIdsToNames,
        templateNamesToIds;
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi/src/ai/ai_failure_text.dart';
import 'package:fushi/src/ai/ai_srs_template_assistant.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_registry.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_note_preview.dart'
    show SrsStablePreviewFace, srsNotePreviewNativeFushiCard;
import 'package:fushi/src/pages/implementations/srs/srs_ui.dart';
import 'package:fushi/src/pages/implementations/srs/srs_visual_template_panel.dart';
import 'package:fushi/src/srs/srs_field_catalog.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/srs/srs_visual_template.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 模板编辑器的标签页。
enum SrsTemplateEditorTab { visual, front, back, styling }

/// 预览渲染结果（纯函数，便于测试）：成功给出卡面，模板错误给出错误文本。
class SrsTemplatePreview {
  const SrsTemplatePreview({this.card, this.error});

  final AnkiRenderedCard? card;
  final String? error;
}

/// 预览里没有样例内容时字段的占位值 `(字段名)`。字段名来自用户或导入的 Anki 牌组，
/// 是不可信文本：占位值会作为字段**内容**进卡面 HTML，必须转义成纯文本，否则名字里的
/// `<`、`&` 等会被当成标签（名字形如 `<img onerror=…>` 时还会在预览里执行）。
/// 模板编辑器与字段说明页的预览共用这一处。
String srsFieldPlaceholderHtml(String name) =>
    '(${const HtmlEscape(HtmlEscapeMode.element).convert(name)})';

/// 用名字形式的模板渲染一张示例卡。
SrsTemplatePreview srsRenderTemplatePreview({
  required String front,
  required String back,
  required Map<String, String> fieldsByName,
  required bool isCloze,
  required int cardOrd,
  AnkiCardSpecialFields specials = const AnkiCardSpecialFields(),
}) {
  try {
    return SrsTemplatePreview(
      card: renderAnkiCard(
        questionTemplate: front,
        answerTemplate: back,
        noteFields: fieldsByName,
        cardOrd: cardOrd,
        isCloze: isCloze,
        specials: specials,
      ),
    );
  } on AnkiTemplateError catch (e) {
    return SrsTemplatePreview(error: e.message);
  }
}

class SrsTemplateEditorPage extends ConsumerStatefulWidget {
  const SrsTemplateEditorPage({
    super.key,
    required this.noteTypeId,
    required this.templateId,
    this.initialTab = SrsTemplateEditorTab.visual,
  });

  final String noteTypeId;
  final String templateId;
  final SrsTemplateEditorTab initialTab;

  @override
  ConsumerState<SrsTemplateEditorPage> createState() =>
      _SrsTemplateEditorPageState();
}

class _SrsTemplateEditorPageState extends ConsumerState<SrsTemplateEditorPage> {
  final TextEditingController _front = TextEditingController();
  final TextEditingController _back = TextEditingController();
  final TextEditingController _css = TextEditingController();
  late SrsTemplateEditorTab _tab = widget.initialTab;
  bool _previewAnswer = false;
  bool _loading = true;
  bool _saving = false;
  Object? _error;

  SrsDbStore? _store;
  SrsNoteTypeView? _type;
  SrsTemplateDef? _template;
  SrsNoteView? _sample;

  /// 示例笔记的字段值（fieldId → 值），释义样式去重的引用行已展开（预览与复习页同一份内容）。
  Map<String, String> _sampleValues = const <String, String>{};

  /// 载入时的三段原文（判断有没有未保存的修改）。
  String _savedFront = '';
  String _savedBack = '';
  String _savedCss = '';

  Timer? _debounce;
  SrsTemplatePreview _preview = const SrsTemplatePreview();

  /// 卡面上正显示的那张（最近一次能渲染的结果）：打字途中模板出错 / 为空时卡面不拆，
  /// 只盖一层提示，见 [SrsStablePreviewFace]。
  AnkiRenderedCard? _shown;
  ({Map<String, String> fieldsByName, String definitionsHtml})? _shownNative;

  /// AI 顺带写的字段说明（fieldId → 说明），保存模板时一起写入；放弃修改即丢弃。
  Map<String, String> _pendingDescriptions = const <String, String>{};

  /// 上一次 AI 给的说明文字。
  String _aiExplanation = '';

  @override
  void initState() {
    super.initState();
    for (final TextEditingController c in <TextEditingController>[
      _front,
      _back,
      _css,
    ]) {
      c.addListener(_onEdited);
    }
    unawaited(_load());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _front.dispose();
    _back.dispose();
    _css.dispose();
    super.dispose();
  }

  Map<String, String> get _idToName => <String, String>{
    for (final SrsFieldDef f in _type?.fields ?? const <SrsFieldDef>[])
      f.id: f.name,
  };

  Map<String, String> get _nameToId => <String, String>{
    for (final SrsFieldDef f in _type?.fields ?? const <SrsFieldDef>[])
      f.name: f.id,
  };

  Future<void> _load() async {
    try {
      final SrsDbStore? store = await readSrsStore(ref);
      if (store == null) throw StateError('srs store unavailable');
      final SrsNoteTypeView? type = await store.noteType(widget.noteTypeId);
      final SrsTemplateDef? tpl = type?.templates
          .where((SrsTemplateDef x) => x.id == widget.templateId)
          .firstOrNull;
      if (type == null || tpl == null) throw StateError('template not found');
      // 只要一条样本：走索引取第一条 id，不把整个类型的笔记都列出来。
      final List<String> notes = await store.noteIdsOfType(type.id, limit: 1);
      final SrsNoteView? sample = notes.isEmpty
          ? null
          : await store.note(notes.first);
      final Map<String, String> sampleValues = sample == null
          ? const <String, String>{}
          : await store.expandFields(sample.fields, dropMissing: true);
      if (!mounted) return;
      _store = store;
      _type = type;
      _template = tpl;
      _sample = sample;
      _sampleValues = sampleValues;
      _savedFront = templateIdsToNames(tpl.front, _idToName);
      _savedBack = templateIdsToNames(tpl.back, _idToName);
      _savedCss = type.css;
      _front.text = _savedFront;
      _back.text = _savedBack;
      _css.text = _savedCss;
      _debounce?.cancel();
      setState(() => _loading = false);
      _refreshPreview();
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsTemplateEditor.load', e, stack);
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e;
        });
      }
    }
  }

  bool get _dirty =>
      _front.text != _savedFront ||
      _back.text != _savedBack ||
      _css.text != _savedCss ||
      _pendingDescriptions.isNotEmpty;

  SrsVisualCompileContext? get _visualCtx {
    final SrsNoteTypeView? type = _type;
    return type == null ? null : SrsVisualCompileContext.of(type);
  }

  /// 把一面的块编译进对应源码（触发预览刷新与未保存判断）。
  void _setVisualSide({
    required bool back,
    required List<SrsVisualBlock> blocks,
  }) {
    final SrsVisualCompileContext? ctx = _visualCtx;
    if (ctx == null) return;
    (back ? _back : _front).text = srsCompileVisualSide(blocks, ctx);
  }

  /// 按字段自动生成两面布局；当前模板有内容时先确认（会替换源码，保存前仍可放弃）。
  Future<void> _generateVisual() async {
    final SrsNoteTypeView? type = _type;
    if (type == null) return;
    final bool hasContent =
        _front.text.trim().isNotEmpty || _back.text.trim().isNotEmpty;
    if (hasContent) {
      final bool ok = await showFushiConfirmDialog(
        context: context,
        title: t.srs_visual_generate_confirm_title,
        message: t.srs_visual_generate_confirm_body,
        confirmLabel: t.srs_visual_generate,
        cancelLabel: t.cancel,
        icon: FushiIcons.warning,
      );
      if (!ok || !mounted) return;
    }
    final ({List<SrsVisualBlock> front, List<SrsVisualBlock> back}) layout =
        srsSuggestVisualLayout(type);
    _setVisualSide(back: false, blocks: layout.front);
    _setVisualSide(back: true, blocks: layout.back);
  }

  /// 跑一次 AI：结果并进源码草稿；返回要显示的提示（null = 成功）。
  Future<String?> _runAi(String request) async {
    final SrsNoteTypeView? type = _type;
    final SrsVisualCompileContext? ctx = _visualCtx;
    if (type == null || ctx == null) return null;
    final AiProviderConfig? provider = ref
        .read(appProvider)
        .prefsRepo
        .resolveAiFeatureProvider(AiFeature.srsTemplate);
    // 没有可用提供商就一个请求都不发（BUG-2694）。
    if (provider == null) return t.ai_assist_no_provider;
    final AiChatClient client = AiChatClient();
    try {
      final AiSrsTemplateSuggestion s = await requestAiSrsTemplate(
        client: client,
        provider: provider,
        request: request,
        noteType: type,
        sampleByFieldId: _sampleValues,
        currentFront: srsReadVisualSide(_front.text, ctx).blocks,
        currentBack: srsReadVisualSide(_back.text, ctx).blocks,
      );
      if (!mounted) return null;
      if (s.isEmpty) return t.ai_assist_empty;
      // 要替换的一面是代码写的（Anki 导入 / 手写）或在代码页手改过：与「按字段生成」一样
      // 先确认，免得顺手保存就把原模板丢了。
      bool replacesCode(TextEditingController c) {
        if (c.text.trim().isEmpty) return false;
        final SrsVisualSideState state = srsReadVisualSide(c.text, ctx);
        return !state.isVisual || state.edited;
      }

      if ((s.front != null && replacesCode(_front)) ||
          (s.back != null && replacesCode(_back))) {
        final bool ok = await showFushiConfirmDialog(
          context: context,
          title: t.srs_visual_generate_confirm_title,
          message: t.srs_visual_ai_replace_body,
          confirmLabel: t.srs_visual_replace,
          cancelLabel: t.cancel,
          icon: FushiIcons.warning,
        );
        if (!ok || !mounted) return null;
      }
      if (s.front != null) _setVisualSide(back: false, blocks: s.front!);
      if (s.back != null) _setVisualSide(back: true, blocks: s.back!);
      setState(() {
        _pendingDescriptions = <String, String>{
          ..._pendingDescriptions,
          ...s.fieldDescriptions,
        };
        _aiExplanation = <String>[
          if (s.explanation.isNotEmpty) s.explanation,
          if (s.fieldDescriptions.isNotEmpty)
            t.srs_visual_ai_descriptions_pending(
              count: s.fieldDescriptions.length,
            ),
        ].join('\n');
      });
      return null;
    } on AiChatFailure catch (failure) {
      return t.ai_assist_failed(reason: aiFailureText(failure.message));
    } finally {
      client.close();
    }
  }

  void _onEdited() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) _refreshPreview();
    });
    if (mounted) setState(() {});
  }

  Map<String, String> get _sampleFields {
    final SrsNoteTypeView? type = _type;
    if (type == null) return const <String, String>{};
    final SrsNoteView? sample = _sample;
    return <String, String>{
      for (final SrsFieldDef f in type.fields)
        f.name: sample == null
            ? srsFieldPlaceholderHtml(f.name)
            : _sampleValues[f.id] ?? '',
    };
  }

  void _refreshPreview() {
    final SrsNoteTypeView? type = _type;
    final SrsTemplateDef? tpl = _template;
    if (type == null || tpl == null) return;
    final int ord = type.templates.indexWhere(
      (SrsTemplateDef x) => x.id == tpl.id,
    );
    setState(() {
      _preview = srsRenderTemplatePreview(
        front: _front.text,
        back: _back.text,
        fieldsByName: _sampleFields,
        isCloze: type.isCloze,
        // 填空类型预览 c1；普通类型按模板位置。
        cardOrd: type.isCloze ? 0 : (ord < 0 ? 0 : ord),
        specials: AnkiCardSpecialFields(
          tags: _sample?.tags ?? const <String>[],
          noteTypeName: type.name,
          cardName: tpl.name,
        ),
      );
      final AnkiRenderedCard? card = _preview.card;
      if (card != null && !card.isEmpty) {
        _shown = card;
        // 与内置代码逐字一致的 Fushi 卡片与复习页一样走原生混合渲染（不建整面 WebView，
        // 判据在 srsNotePreviewNativeFushiCard 里）；一改就是复习时的模板渲染，预览跟着换。
        // 共享样式按载入时的类型比对，样式框改过就按模板渲染。
        final Map<String, String> nameToId = _nameToId;
        _shownNative = _css.text == type.css
            ? srsNotePreviewNativeFushiCard(
                type: type,
                template: tpl.copyWith(
                  front: templateNamesToIds(_front.text, nameToId),
                  back: templateNamesToIds(_back.text, nameToId),
                ),
                valuesById: <String, String>{
                  for (final SrsFieldDef f in type.fields)
                    f.id: _sampleFields[f.name] ?? '',
                },
                tags: _sample?.tags ?? const <String>[],
              )
            : null;
      }
    });
  }

  Future<void> _save() async {
    final SrsDbStore? store = _store;
    final SrsNoteTypeView? type = _type;
    final SrsTemplateDef? tpl = _template;
    if (store == null || type == null || tpl == null || _saving) return;
    _refreshPreview();
    if (_preview.error != null) {
      FushiToast.show(
        msg: t.srs_note_types_template_error(error: _preview.error!),
        severity: ToastSeverity.error,
      );
      return;
    }
    setState(() => _saving = true);
    try {
      final Map<String, String> nameToId = _nameToId;
      final bool templateChanged =
          _front.text != _savedFront || _back.text != _savedBack;
      // 模板 / CSS / 字段说明一次写入（一个事务、一次缓存刷新），见 saveTemplateEdits。
      final bool wrote = await store.saveTemplateEdits(
        type.id,
        tpl.id,
        front: templateChanged
            ? templateNamesToIds(_front.text, nameToId)
            : null,
        back: templateChanged ? templateNamesToIds(_back.text, nameToId) : null,
        css: _css.text != _savedCss ? _css.text : null,
        fieldDescriptions: _pendingDescriptions,
      );
      if (!mounted) return;
      if (wrote) bumpSrsRevision(ref);
      setState(() {
        _savedFront = _front.text;
        _savedBack = _back.text;
        _savedCss = _css.text;
        _pendingDescriptions = const <String, String>{};
      });
      _refreshPreview();
      FushiToast.show(
        msg: t.srs_note_types_saved,
        severity: ToastSeverity.success,
      );
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsTemplateEditor.save', e, stack);
      FushiToast.show(msg: t.srs_action_failed, severity: ToastSeverity.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 当前源码标签页的输入框；可视化页没有（返回 null）。
  TextEditingController? get _current => switch (_tab) {
    SrsTemplateEditorTab.visual => null,
    SrsTemplateEditorTab.front => _front,
    SrsTemplateEditorTab.back => _back,
    SrsTemplateEditorTab.styling => _css,
  };

  bool get _canInsertField =>
      _tab == SrsTemplateEditorTab.front || _tab == SrsTemplateEditorTab.back;

  /// 在光标处插入 `{{字段名}}`（背面多一个 FrontSide）。
  Future<void> _insertField() async {
    final SrsNoteTypeView? type = _type;
    if (type == null || !_canInsertField) return;
    final String? name = await showFushiChoiceDialog<String>(
      context: context,
      title: t.srs_note_types_insert_field,
      icon: FushiIcons.textFields,
      options: <FushiChoiceOption<String>>[
        if (_tab == SrsTemplateEditorTab.back)
          const FushiChoiceOption<String>(
            value: 'FrontSide',
            label: 'FrontSide',
          ),
        for (final SrsFieldDef f in type.fields)
          FushiChoiceOption<String>(
            value: type.isCloze && f.id == type.fields.first.id
                ? 'cloze:${f.name}'
                : f.name,
            label: f.name,
            subtitle: <String>[
              if (srsFieldDisplayName(f) != f.name) srsFieldDisplayName(f),
              if (srsFieldDisplayDescription(f).isNotEmpty)
                srsFieldDisplayDescription(f),
            ].join(' · '),
          ),
      ],
    );
    final TextEditingController? c = _current;
    if (name == null || c == null) return;
    final TextSelection sel = c.selection;
    final String insert = '{{$name}}';
    final int start = sel.isValid ? sel.start : c.text.length;
    final int end = sel.isValid ? sel.end : c.text.length;
    c.value = TextEditingValue(
      text: c.text.replaceRange(start, end, insert),
      selection: TextSelection.collapsed(offset: start + insert.length),
    );
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
    key: const ValueKey<String>('srs_template_save'),
    icon: FushiIcons.save,
    label: t.srs_note_save,
    onPressed: _saving || !_dirty || _type == null
        ? null
        : () => unawaited(_save()),
  );

  /// 顶栏「AI 帮忙」：任何标签页都能用（不必先切到可视化页）。问一句要求 → 跑 AI → 切到
  /// 可视化页看结果（结果仍只进草稿）。AI 模块关着时没有这个按钮。
  FushiToolbarItem? get _aiItem {
    if (_type == null ||
        !isAiModuleEnabled(ref.watch(appProvider).moduleVisibility)) {
      return null;
    }
    return FushiToolbarItem(
      key: const ValueKey<String>('srs_template_ai'),
      icon: FushiIcons.aiAssistant,
      label: t.ai_assist_section,
      onPressed: () => srsRunLogged('SrsTemplateEditor.ai', _askAi),
    );
  }

  Future<void> _askAi() async {
    final String? request = await showFushiTextInputDialog(
      context: context,
      title: t.ai_assist_section,
      hintText: t.srs_visual_ai_hint,
      confirmLabel: t.srs_visual_ai_run,
      cancelLabel: t.cancel,
      icon: FushiIcons.aiAssistant,
      maxLines: 4,
    );
    if (request == null || request.trim().isEmpty || !mounted) return;
    final String? message = await _runAi(request.trim());
    if (!mounted) return;
    if (message != null) {
      FushiToast.show(msg: message, severity: ToastSeverity.error);
      return;
    }
    setState(() => _tab = SrsTemplateEditorTab.visual);
  }

  FushiToolbarItem get _insertItem => FushiToolbarItem(
    key: const ValueKey<String>('srs_template_insert_field'),
    icon: FushiIcons.textFields,
    label: t.srs_note_types_insert_field,
    onPressed: _type == null || !_canInsertField
        ? null
        : () => srsRunLogged('SrsTemplateEditor.insert', _insertField),
  );

  @override
  Widget build(BuildContext context) {
    final bool apple = isGlassDesign(context);
    final String title = _template?.name ?? t.srs_note_types_template_edit;
    return PopScope<Object?>(
      canPop: !_dirty,
      onPopInvokedWithResult: (bool didPop, Object? result) async {
        if (didPop) return;
        final NavigatorState navigator = Navigator.of(context);
        // 放弃修改：Navigator.pop 不经 PopScope 拦截，直接退出。
        if (await _confirmDiscard() && mounted) navigator.pop();
      },
      child: FushiPageScaffold(
        title: title,
        header: apple ? null : _buildTopBar(context, title),
        actions: apple
            ? <Widget>[
                for (final FushiToolbarItem item in <FushiToolbarItem>[
                  ?_aiItem,
                  _insertItem,
                  _saveItem,
                ])
                  FushiIconButton(
                    key: item.key,
                    icon: item.icon,
                    tooltip: item.label,
                    enabled: item.onPressed != null,
                    onTap: item.onPressed,
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
          <FushiToolbarItem>[?_aiItem, _insertItem, _saveItem],
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const SafeArea(bottom: false, child: FushiLoadingView());
    }
    final SrsNoteTypeView? type = _type;
    if (_error != null || type == null) {
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
    final String? error = _preview.error;
    final Widget tabs = FushiSegmentedButton<SrsTemplateEditorTab>(
      key: const ValueKey<String>('srs-template-tabs'),
      showSelectedIcon: false,
      segments: <ButtonSegment<SrsTemplateEditorTab>>[
        ButtonSegment<SrsTemplateEditorTab>(
          value: SrsTemplateEditorTab.visual,
          label: Text(t.srs_visual_tab),
        ),
        ButtonSegment<SrsTemplateEditorTab>(
          value: SrsTemplateEditorTab.front,
          label: Text(t.srs_note_types_front),
        ),
        ButtonSegment<SrsTemplateEditorTab>(
          value: SrsTemplateEditorTab.back,
          label: Text(t.srs_note_types_back),
        ),
        ButtonSegment<SrsTemplateEditorTab>(
          value: SrsTemplateEditorTab.styling,
          label: Text(t.srs_note_types_styling),
        ),
      ],
      selected: <SrsTemplateEditorTab>{_tab},
      onSelectionChanged: (Set<SrsTemplateEditorTab> s) =>
          setState(() => _tab = s.first),
    );
    Widget editor({required bool wide}) => AnimatedSwitcher(
      duration: fushiMotionDuration(context, FushiMotion.short),
      switchInCurve: FushiMotion.enter,
      switchOutCurve: FushiMotion.exit,
      child: _tab == SrsTemplateEditorTab.visual
          ? _buildVisual(context, type)
          : FushiTextField(
              key: ValueKey<String>('srs-template-${_tab.name}'),
              controller: _current,
              minLines: 8,
              // 宽窗左栏整栏都给源码，多放几行再滚。
              maxLines: wide ? 28 : 16,
              keyboardType: TextInputType.multiline,
              style: context.fushiType.bodyMedium.copyWith(
                fontFamily: 'monospace',
                fontFamilyFallback: const <String>['Consolas', 'Menlo'],
              ),
              helperText: _tab == SrsTemplateEditorTab.styling
                  ? t.srs_note_types_styling_hint
                  : null,
              errorText: _tab == SrsTemplateEditorTab.styling || error == null
                  ? null
                  : t.srs_note_types_template_error(error: error),
            ),
    );
    final double top = tokens.spacing.gap + MediaQuery.paddingOf(context).top;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (!srsUsesTwoPane(constraints)) {
          return ListView(
            padding: withBottomSafeInset(
              context,
              EdgeInsets.fromLTRB(
                tokens.spacing.page,
                top,
                tokens.spacing.page,
                tokens.spacing.section,
              ),
            ),
            children: <Widget>[
              tabs,
              SizedBox(height: tokens.spacing.gap * 1.5),
              editor(wide: false),
              SizedBox(height: tokens.spacing.section),
              _buildPreview(context, type),
            ],
          );
        }
        // 宽窗（手机横屏 / 桌面）：左栏源码、右栏预览并排，改一行就能在旁边看到
        // 结果，不必上下来回滚；预览卡片撑满右栏高度。
        final double half = tokens.spacing.gap * 0.75;
        final EdgeInsets bottom = withBottomSafeInset(
          context,
          EdgeInsets.only(bottom: tokens.spacing.page),
        );
        return FushiEntranceScope(
          child: FushiPinnedPageChromeScope(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Expanded(
                  child: FocusTraversalGroup(
                    child: ListView(
                      key: SrsAdaptiveSections.primaryPaneKey,
                      padding: EdgeInsets.fromLTRB(
                        tokens.spacing.page,
                        top,
                        half,
                        bottom.bottom,
                      ),
                      children: <Widget>[
                        FushiStaggeredEntrance(index: 0, child: tabs),
                        SizedBox(height: tokens.spacing.gap * 1.5),
                        FushiStaggeredEntrance(
                          index: 1,
                          child: editor(wide: true),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: FocusTraversalGroup(
                    child: Padding(
                      key: SrsAdaptiveSections.secondaryPaneKey,
                      padding: EdgeInsets.fromLTRB(
                        half,
                        top,
                        tokens.spacing.page,
                        bottom.bottom,
                      ),
                      child: FushiStaggeredEntrance(
                        index: 2,
                        child: _buildPreview(context, type, fill: true),
                      ),
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

  /// 「可视化」页：编辑哪一面与预览显示哪一面是同一个开关。
  Widget _buildVisual(BuildContext context, SrsNoteTypeView type) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final SrsVisualCompileContext ctx = SrsVisualCompileContext.of(type);
    final bool back = _previewAnswer;
    final SrsVisualSideState side = srsReadVisualSide(
      back ? _back.text : _front.text,
      ctx,
    );
    final bool aiEnabled = isAiModuleEnabled(
      ref.watch(appProvider).moduleVisibility,
    );
    return Column(
      key: const ValueKey<String>('srs-template-visual'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: tokens.spacing.gap,
      children: <Widget>[
        FushiSegmentedButton<bool>(
          key: const ValueKey<String>('srs-visual-side'),
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
          selected: <bool>{back},
          onSelectionChanged: (Set<bool> s) =>
              setState(() => _previewAnswer = s.first),
        ),
        SrsVisualTemplatePanel(
          // 换面时面板重建：展开中的块、AI 输入框按面各自独立。
          key: ValueKey<String>('srs-visual-panel-$back'),
          type: type,
          back: back,
          blocks: side.blocks,
          edited: side.edited,
          onChanged: (List<SrsVisualBlock> blocks) =>
              _setVisualSide(back: back, blocks: blocks),
          onGenerate: () =>
              srsRunLogged('SrsTemplateEditor.generate', _generateVisual),
          onAi: aiEnabled ? _runAi : null,
          aiExplanation: _aiExplanation,
        ),
      ],
    );
  }

  /// [fill]：宽窗右栏里预览卡片撑满剩余高度（否则固定 280 高）。
  Widget _buildPreview(
    BuildContext context,
    SrsNoteTypeView type, {
    bool fill = false,
  }) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final AnkiRenderedCard? card = _preview.card;
    final AnkiRenderedCard? shown = _shown;
    final String language = ref.read(appProvider).defaultContentLanguage;
    final SrsNoteView? sample = _sample;
    final String sampleLabel = sample == null
        ? t.srs_note_types_preview_placeholder
        : t.srs_note_types_preview_sample(
            note: type.fields.isEmpty
                ? sample.id
                : sample
                      .field(type.fields.first.id)
                      .replaceAll(RegExp(r'<[^>]+>'), '')
                      .trim(),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: tokens.spacing.gap,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                t.srs_note_types_preview,
                style: context.fushiType.titleSmall,
              ),
            ),
            FushiSegmentedButton<bool>(
              key: const ValueKey<String>('srs-template-preview-side'),
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
              selected: <bool>{_previewAnswer},
              onSelectionChanged: (Set<bool> s) =>
                  setState(() => _previewAnswer = s.first),
            ),
          ],
        ),
        Text(sampleLabel, style: context.fushiType.bodySmall),
        _sized(
          fill: fill,
          child: FushiCard(
            key: const ValueKey<String>('srs-template-preview'),
            padding: EdgeInsets.zero,
            pressScale: false,
            child: SrsStablePreviewFace(
              face: shown == null
                  ? null
                  : SrsCardFace(
                      cardId: 'preview-${widget.templateId}',
                      showingAnswer: _previewAnswer,
                      bodyHtml: _previewAnswer ? shown.answer : shown.question,
                      css: _css.text,
                      languageCode: language.isEmpty ? null : language,
                      fushiCard: _type?.builtinKey == kSrsBuiltinFushiCardKey,
                      onBridgeKey: (_) {},
                    ),
              native: _shownNative,
              overlay: card == null
                  ? Center(
                      child: FushiPlaceholderMessage(
                        icon: FushiIcons.warning,
                        tone: FushiPlaceholderTone.error,
                        message: t.srs_note_types_template_error(
                          error: _preview.error ?? '',
                        ),
                      ),
                    )
                  : card.isEmpty
                  ? Center(
                      child: FushiPlaceholderMessage(
                        icon: FushiIcons.info,
                        message: t.srs_note_types_preview_empty,
                      ),
                    )
                  : null,
            ),
          ),
        ),
      ],
    );
  }

  Widget _sized({required bool fill, required Widget child}) =>
      fill ? Expanded(child: child) : SizedBox(height: 280, child: child);
}
