/// 笔记编辑页的卡片实时预览：按当前（未保存的）字段值，用笔记类型的模板渲染一张卡的正面 /
/// 背面，经与复习页 / 浏览页同一个卡面视图（[srsCardFaceBuilderProvider]）显示。
///
/// - 字段一改（[SrsFieldModel] 通知）就去抖重渲染；只读笔记类型与字段模型，不写任何东西。
/// - 有多个卡片模板（如「正向 / 反向」）时可切换预览哪一张；填空类型按字段里出现的 cN 切换。
/// - 宽窗嵌在编辑页右栏（[SrsNotePreview]），窄窗经 [showSrsNotePreviewSheet] 从底部抽屉打开——
///   抽屉里同样监听字段模型，关掉抽屉改字段、再打开看到的是最新内容。
/// - 预览不自动播放音频（每敲一个字重渲染一次，自动播放会一直响）。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_anki/fushi_anki_core.dart'
    show AnkiCardSpecialFields, AnkiRenderedCard, templateIdsToNames;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_field_editors.dart';
import 'package:fushi/src/pages/implementations/srs/srs_template_editor_page.dart'
    show SrsTemplatePreview, srsRenderTemplatePreview;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 字段里出现的填空编号（`{{c2::…}}` → 2），升序去重；没有填空返回空表。
List<int> srsClozeOrdinals(Iterable<String> values) {
  final RegExp cloze = RegExp(r'\{\{c(\d+)::');
  final Set<int> out = <int>{};
  for (final String v in values) {
    for (final RegExpMatch m in cloze.allMatches(v)) {
      final int? n = int.tryParse(m.group(1)!);
      if (n != null && n > 0) out.add(n);
    }
  }
  return out.toList()..sort();
}

/// 用笔记类型的 [template] 与按 fieldId 给的字段值渲染一张预览卡（纯函数）。
///
/// [clozeOrd] 只对填空类型有效（1 起）；普通类型按模板在类型里的位置出卡。
SrsTemplatePreview srsRenderNotePreview({
  required SrsNoteTypeView type,
  required SrsTemplateDef template,
  required Map<String, String> valuesById,
  List<String> tags = const <String>[],
  int clozeOrd = 1,
}) {
  final Map<String, String> idToName = <String, String>{
    for (final SrsFieldDef f in type.fields) f.id: f.name,
  };
  final int ord = type.templates.indexWhere(
    (SrsTemplateDef x) => x.id == template.id,
  );
  return srsRenderTemplatePreview(
    front: templateIdsToNames(template.front, idToName),
    back: templateIdsToNames(template.back, idToName),
    fieldsByName: <String, String>{
      for (final SrsFieldDef f in type.fields) f.name: valuesById[f.id] ?? '',
    },
    isCloze: type.isCloze,
    cardOrd: type.isCloze
        ? (clozeOrd < 1 ? 0 : clozeOrd - 1)
        : (ord < 0 ? 0 : ord),
    specials: AnkiCardSpecialFields(
      tags: tags,
      noteTypeName: type.name,
      cardName: template.name,
    ),
  );
}

/// 把共享样式引用展开回内联（与复习页渲染同一份内容）；null = 原样用。
typedef SrsNotePreviewExpand =
    Future<Map<String, String>> Function(Map<String, String> valuesById);

/// 一张卡的实时预览：标题 + 正 / 背面切换 +（多模板 / 多填空时）卡片选择 + 卡面。
class SrsNotePreview extends ConsumerStatefulWidget {
  const SrsNotePreview({
    super.key,
    required this.type,
    required this.fields,
    this.expand,
    this.tags = const <String>[],
    this.height,
    this.showTitle = true,
  });

  final SrsNoteTypeView type;

  /// fieldId → 字段模型（编辑页持有；预览只监听）。
  final Map<String, SrsFieldModel> fields;

  final SrsNotePreviewExpand? expand;
  final List<String> tags;

  /// 卡面高度；null = 撑满父级剩余高度（父级须给有界高度）。
  final double? height;

  /// 显示「预览」标题（底部抽屉自带标题时关掉）。
  final bool showTitle;

  @override
  ConsumerState<SrsNotePreview> createState() => _SrsNotePreviewState();
}

class _SrsNotePreviewState extends ConsumerState<SrsNotePreview> {
  bool _showAnswer = false;
  String? _templateId;
  int _clozeOrd = 1;
  SrsTemplatePreview _preview = const SrsTemplatePreview();
  Timer? _debounce;
  int _seq = 0;
  Listenable? _listening;

  @override
  void initState() {
    super.initState();
    _listen();
    _render();
  }

  @override
  void didUpdateWidget(SrsNotePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.fields, widget.fields) ||
        oldWidget.type != widget.type ||
        oldWidget.fields.length != widget.fields.length) {
      _listen();
      _render();
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _listening?.removeListener(_onFieldChanged);
    super.dispose();
  }

  void _listen() {
    _listening?.removeListener(_onFieldChanged);
    _listening = Listenable.merge(widget.fields.values.toList());
    _listening!.addListener(_onFieldChanged);
  }

  void _onFieldChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), () {
      if (mounted) _render();
    });
  }

  Map<String, String> get _values => <String, String>{
    for (final MapEntry<String, SrsFieldModel> e in widget.fields.entries)
      e.key: e.value.value,
  };

  SrsTemplateDef? get _template {
    final List<SrsTemplateDef> templates = widget.type.templates;
    if (templates.isEmpty) return null;
    return templates
            .where((SrsTemplateDef x) => x.id == _templateId)
            .firstOrNull ??
        templates.first;
  }

  Future<void> _render() async {
    final SrsTemplateDef? tpl = _template;
    if (tpl == null) return;
    final int seq = ++_seq;
    Map<String, String> values = _values;
    final SrsNotePreviewExpand? expand = widget.expand;
    if (expand != null) {
      try {
        values = await expand(values);
      } catch (e, stack) {
        // 展开失败不挡预览：原样渲染（引用行 WebView 读不到，只少样式）。
        ErrorLogService.instance.log('SrsNotePreview.expand', e, stack);
      }
    }
    if (!mounted || seq != _seq) return;
    final List<int> ords = srsClozeOrdinals(values.values);
    if (widget.type.isCloze && ords.isNotEmpty && !ords.contains(_clozeOrd)) {
      _clozeOrd = ords.first;
    }
    setState(() {
      _preview = srsRenderNotePreview(
        type: widget.type,
        template: tpl,
        valuesById: values,
        tags: widget.tags,
        clozeOrd: _clozeOrd,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final SrsNoteTypeView type = widget.type;
    final List<int> ords = type.isCloze
        ? srsClozeOrdinals(_values.values)
        : const <int>[];
    final Widget sides = adaptiveSegmentedButton<bool>(
      context: context,
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
      selected: <bool>{_showAnswer},
      onSelectionChanged: (Set<bool> s) =>
          setState(() => _showAnswer = s.first),
    );
    final List<Widget> chooser = <Widget>[
      if (!type.isCloze && type.templates.length > 1)
        for (final SrsTemplateDef tpl in type.templates)
          FushiChoiceChip(
            key: ValueKey<String>('srs-note-preview-template-${tpl.id}'),
            label: Text(tpl.name),
            selected: tpl.id == _template?.id,
            onSelected: (_) {
              setState(() => _templateId = tpl.id);
              unawaited(_render());
            },
          ),
      if (type.isCloze && ords.length > 1)
        for (final int n in ords)
          FushiChoiceChip(
            key: ValueKey<String>('srs-note-preview-cloze-$n'),
            label: Text('c$n'),
            selected: n == _clozeOrd,
            onSelected: (_) {
              setState(() => _clozeOrd = n);
              unawaited(_render());
            },
          ),
    ];
    final double? height = widget.height;
    final Widget surface = FushiCard(
      key: const ValueKey<String>('srs-note-preview-surface'),
      padding: EdgeInsets.zero,
      pressScale: false,
      child: AnimatedSwitcher(
        duration: fushiMotionDuration(context, FushiMotion.short),
        switchInCurve: FushiMotion.enter,
        switchOutCurve: FushiMotion.exit,
        child: KeyedSubtree(
          key: ValueKey<String>('${_template?.id}-$_showAnswer'),
          child: _face(context),
        ),
      ),
    );
    return Column(
      key: const ValueKey<String>('srs-note-preview'),
      mainAxisSize: height == null ? MainAxisSize.max : MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: tokens.spacing.gap,
      children: <Widget>[
        if (widget.showTitle)
          Row(
            spacing: tokens.spacing.gap,
            children: <Widget>[
              const FushiIcon(FushiIcons.visibility, size: 20),
              Expanded(
                child: Text(
                  t.srs_note_types_preview,
                  style: context.fushiType.titleSmall,
                ),
              ),
            ],
          ),
        sides,
        if (chooser.isNotEmpty)
          Wrap(
            spacing: tokens.spacing.gap,
            runSpacing: tokens.spacing.gap / 2,
            children: chooser,
          ),
        if (height == null)
          Expanded(child: surface)
        else
          SizedBox(height: height, child: surface),
      ],
    );
  }

  Widget _face(BuildContext context) {
    final AnkiRenderedCard? card = _preview.card;
    final String? error = _preview.error;
    if (error != null) {
      return Center(
        child: FushiPlaceholderMessage(
          icon: FushiIcons.warning,
          tone: FushiPlaceholderTone.error,
          message: t.srs_note_types_template_error(error: error),
        ),
      );
    }
    if (card == null) return const FushiLoadingView();
    if (card.isEmpty) {
      return Center(
        child: FushiPlaceholderMessage(
          key: const ValueKey<String>('srs-note-preview-empty'),
          icon: FushiIcons.info,
          message: t.srs_note_types_preview_empty,
        ),
      );
    }
    final String language = ref.read(appProvider).defaultContentLanguage;
    return ref.watch(srsCardFaceBuilderProvider)(
      context,
      SrsCardFace(
        cardId: 'note-editor-preview',
        showingAnswer: _showAnswer,
        bodyHtml: _showAnswer ? card.answer : card.question,
        css: widget.type.css,
        languageCode: language.isEmpty ? null : language,
        fushiCard: widget.type.builtinKey == kSrsBuiltinFushiCardKey,
        onBridgeKey: (_) {},
        bridgeKeys: const <String>[],
        autoplayMedia: false,
      ),
    );
  }
}

/// 窄窗：从底部抽屉打开实时预览。
Future<void> showSrsNotePreviewSheet(
  BuildContext context, {
  required SrsNoteTypeView type,
  required Map<String, SrsFieldModel> fields,
  SrsNotePreviewExpand? expand,
  List<String> tags = const <String>[],
}) => adaptiveModalSheet<void>(
  context: context,
  builder: (BuildContext context) => FushiModalSheetFrame(
    key: const ValueKey<String>('srs-note-preview-sheet'),
    title: t.srs_note_types_preview,
    leadingIcon: FushiIcons.visibility,
    body: SrsNotePreview(
      type: type,
      fields: fields,
      expand: expand,
      tags: tags,
      showTitle: false,
      height: (MediaQuery.sizeOf(context).height * 0.55).clamp(240.0, 640.0),
    ),
  ),
);
