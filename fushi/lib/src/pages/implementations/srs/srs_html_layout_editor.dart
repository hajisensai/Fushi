/// 结构化字段（词典排版）的所见即所得编辑：按 [srsLayoutHtml] 排出的版面原生画出排版，每个
/// 段落是一个无边框输入框，直接在排版里改字；标签骨架不动（见 srs_html_layout.dart）。
///
/// 每次改字经 [SrsHtmlLayoutEditor.onChanged] 交回整份 HTML（只换改过的那段文字）；改动只进
/// 笔记编辑页的草稿，保存与否由页面决定。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/srs/srs_html_layout.dart';
import 'package:fushi/src/srs/srs_html_text_parts.dart';
import 'package:fushi/utils.dart';

/// 一个段落的输入框控制器：文字 = 各节拼起来；改动按 [srsApplySegmentEdit] 落回各节，
/// 分隔（空白 / 换行 / 图片）删不掉。
class SrsLayoutParagraphController extends TextEditingController {
  factory SrsLayoutParagraphController(
    SrsLayoutParagraph paragraph,
    List<String> parts,
  ) => SrsLayoutParagraphController._(paragraph, <String>[
    for (final SrsLayoutSeg s in paragraph.segs)
      s.part == null ? s.text : parts[s.part!],
  ]);

  SrsLayoutParagraphController._(this.paragraph, this._texts)
    : super(text: _texts.join());

  final SrsLayoutParagraph paragraph;
  List<String> _texts;

  /// 改动落到可改节后的回调：(段号, 新文字)。
  void Function(int part, String text)? onPartChanged;

  /// 各节当前文字（与 [SrsLayoutParagraph.segs] 一一对应）。
  List<String> get segmentTexts => List<String>.unmodifiable(_texts);

  @override
  set value(TextEditingValue newValue) {
    if (newValue.text == text) {
      super.value = newValue;
      return;
    }
    final int caret = newValue.selection.isValid
        ? newValue.selection.end.clamp(0, newValue.text.length)
        : newValue.text.length;
    final ({List<String> texts, int caret})? applied = srsApplySegmentEdit(
      paragraph.segs,
      _texts,
      newValue.text,
      caret,
    );
    if (applied == null) return;
    final List<String> before = _texts;
    _texts = applied.texts;
    final String joined = _texts.join();
    super.value = joined == newValue.text
        ? newValue
        : TextEditingValue(
            text: joined,
            selection: TextSelection.collapsed(offset: applied.caret),
          );
    for (int i = 0; i < paragraph.segs.length; i++) {
      final int? part = paragraph.segs[i].part;
      if (part != null && before[i] != _texts[i]) {
        onPartChanged?.call(part, _texts[i]);
      }
    }
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextRange composing = value.composing;
    final bool hasComposing =
        withComposing && composing.isValid && !composing.isCollapsed;
    final List<TextSpan> children = <TextSpan>[];
    int offset = 0;
    for (int i = 0; i < paragraph.segs.length; i++) {
      final SrsLayoutSeg seg = paragraph.segs[i];
      final String t = _texts[i];
      final bool inComposing =
          hasComposing &&
          offset < composing.end &&
          offset + t.length > composing.start;
      TextStyle s = srsHtmlLookStyle(seg.look, style, scheme);
      if (seg.part == null && seg.text == kSrsLayoutImageGlyph) {
        s = s.copyWith(color: scheme.onSurfaceVariant);
      }
      if (inComposing) {
        s = s.copyWith(decoration: TextDecoration.underline);
      }
      children.add(TextSpan(text: t, style: s));
      offset += t.length;
    }
    return TextSpan(style: style, children: children);
  }
}

/// [SrsHtmlLook] → [TextStyle]（在 [base] 上叠）。
TextStyle srsHtmlLookStyle(
  SrsHtmlLook look,
  TextStyle? base,
  ColorScheme scheme,
) {
  final double size = (base?.fontSize ?? 16) * look.scale;
  final List<TextDecoration> decorations = <TextDecoration>[
    if (look.underline || look.link) TextDecoration.underline,
    if (look.strike) TextDecoration.lineThrough,
  ];
  return (base ?? const TextStyle()).copyWith(
    fontSize: size,
    fontWeight: look.bold ? FontWeight.w700 : null,
    fontStyle: look.italic ? FontStyle.italic : null,
    decoration: decorations.isEmpty
        ? null
        : TextDecoration.combine(decorations),
    color: look.color != null
        ? Color(look.color!)
        : look.link
        ? scheme.primary
        : null,
    backgroundColor: look.background == null ? null : Color(look.background!),
    fontFamily: look.monospace ? 'monospace' : null,
    fontFamilyFallback: look.monospace
        ? const <String>['Consolas', 'Menlo', 'monospace']
        : null,
  );
}

class SrsHtmlLayoutEditor extends StatefulWidget {
  const SrsHtmlLayoutEditor({
    super.key,
    required this.fieldName,
    required this.html,
    required this.onChanged,
  });

  /// 字段名（控件 key 用）。
  final String fieldName;

  /// 进入编辑时的字段 HTML（之后的改动由本控件自己持有，外部换值请换 key 重建）。
  final String html;

  final ValueChanged<String> onChanged;

  @override
  State<SrsHtmlLayoutEditor> createState() => _SrsHtmlLayoutEditorState();
}

class _SrsHtmlLayoutEditorState extends State<SrsHtmlLayoutEditor> {
  late final SrsHtmlTextParts _parts = srsSplitHtmlText(widget.html);
  late final List<String> _values = List<String>.of(_parts.texts);
  late final SrsLayoutBlock _root = srsLayoutHtml(_parts);
  final Map<SrsLayoutParagraph, SrsLayoutParagraphController> _controllers =
      <SrsLayoutParagraph, SrsLayoutParagraphController>{};
  final Map<SrsLayoutParagraph, int> _index = <SrsLayoutParagraph, int>{};

  @override
  void initState() {
    super.initState();
    for (final (int i, SrsLayoutParagraph p) in srsLayoutParagraphs(
      _root,
    ).indexed) {
      _index[p] = i;
      _controllers[p] = SrsLayoutParagraphController(p, _values)
        ..onPartChanged = _onPartChanged;
    }
  }

  @override
  void dispose() {
    for (final SrsLayoutParagraphController c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _onPartChanged(int part, String text) {
    _values[part] = text;
    widget.onChanged(_parts.join(_values));
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    if (_controllers.isEmpty) {
      return Text(
        t.srs_note_field_edit_text_empty,
        style: context.fushiType.bodySmall,
      );
    }
    return Container(
      key: ValueKey<String>('srs-field-layout-${widget.fieldName}'),
      padding: EdgeInsets.all(tokens.spacing.gap),
      decoration: BoxDecoration(
        color: tokens.surfaces.card,
        borderRadius: tokens.radii.controlRadius,
        border: Border.all(color: scheme.primary.withValues(alpha: 0.5)),
      ),
      child: _box(context, _root),
    );
  }

  Widget _box(BuildContext context, SrsLayoutBox box) => switch (box) {
    SrsLayoutParagraph() => _paragraph(context, box),
    SrsLayoutBlock() => _block(context, box),
  };

  Widget _paragraph(BuildContext context, SrsLayoutParagraph p) {
    final TextStyle base = context.fushiType.bodyLarge;
    // 段落嵌在自绘的版式框里：不带装饰（decoration: null 在两套设计系统下
    // 都不加壳，等同原来的 collapsed 空提示）。
    return FushiTextFieldControl(
      key: ValueKey<String>(
        'srs-field-layout-${widget.fieldName}-${_index[p]}',
      ),
      controller: _controllers[p],
      style: base,
      minLines: 1,
      maxLines: null,
      keyboardType: TextInputType.multiline,
      decoration: null,
    );
  }

  Widget _block(BuildContext context, SrsLayoutBlock b) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final double em = context.fushiType.bodyLarge.fontSize ?? 16;
    final List<Widget> children = <Widget>[
      for (final SrsLayoutBox c in b.children) _box(context, c),
    ];
    final double gap = tokens.spacing.gap / 4;
    final Widget content = switch (b.kind) {
      SrsLayoutBlockKind.rule => Divider(
        height: tokens.spacing.gap,
        color: scheme.outlineVariant,
      ),
      SrsLayoutBlockKind.tableRow => IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (final Widget c in children) Expanded(child: c),
          ],
        ),
      ),
      SrsLayoutBlockKind.tableCell => Container(
        padding: EdgeInsets.all(gap * 2),
        decoration: BoxDecoration(
          border: Border.all(color: scheme.outlineVariant, width: 0.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: gap,
          children: children,
        ),
      ),
      SrsLayoutBlockKind.listItem => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (b.marker?.isNotEmpty ?? false)
            Padding(
              padding: EdgeInsetsDirectional.only(end: em * 0.4),
              child: Text(
                b.marker!,
                style: context.fushiType.bodyLarge.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: gap,
              children: children,
            ),
          ),
        ],
      ),
      SrsLayoutBlockKind.block => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: gap,
        children: children,
      ),
    };
    final bool list = b.tag == 'ul' || b.tag == 'ol';
    final double indent = b.indent * em + (list ? em : 0);
    return indent <= 0
        ? content
        : Padding(
            padding: EdgeInsetsDirectional.only(start: indent),
            child: content,
          );
  }
}
