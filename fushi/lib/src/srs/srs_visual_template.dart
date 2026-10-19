/// 可视化卡片模板：用一串「块」（字段 / 文字 / 分隔线 / 正面内容）描述一面卡，编译成标准
/// Anki 模板正文。
///
/// - **模板正文仍是唯一真相**：布局以 `<!--fushi-visual:v1:<base64url JSON>-->` 注释的形式
///   写在模板开头，后面紧跟它编译出的 HTML。复习、导出 .apkg、在 Anki 里打开都只看 HTML，
///   注释无害；编辑器打开模板时读注释还原成块。
/// - 注释里的 JSON 用 base64url 编码：JSON 自带的 `}}` 会被模板解析器当成标签结尾、`--` 会提前
///   结束 HTML 注释，编码后两样都不会出现。
/// - 块里按 **fieldId** 引用字段（改字段名不动布局，与模板正文的铁律 D 一致）；编译时换成
///   名字形式（`{{Expression}}`），由模板编辑器保存时统一换回 fieldId 引用。
/// - 编译结果只用内联样式与宿主注入的 `--fushi-srs-accent` 变量（带默认值），不改笔记类型的
///   共享 CSS：同一类型的别的模板不受影响，导出到 Anki 也照样显示。
/// - 用户在代码页手改了编译结果（[SrsVisualSideState.edited]）后，可视化页会提示「再改会覆盖
///   手写的代码」，不静默覆盖。
library;

import 'dart:convert';

import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi/src/srs/srs_field_catalog.dart';

/// 块的种类。
enum SrsVisualBlockKind {
  /// 显示一个字段。
  field,

  /// 一段固定文字（标题、提示语）。
  text,

  /// 一条分隔线。
  divider,

  /// 背面里重复显示整个正面（Anki 的 `{{FrontSide}}`）。
  frontSide,
}

/// 字号档。
enum SrsVisualSize {
  /// 特大（词条）。
  display(2.2),

  /// 大（例句）。
  title(1.5),

  /// 正文。
  body(1),

  /// 小字（读音、来源、补充）。
  small(0.85);

  const SrsVisualSize(this.em);

  /// 相对正文的倍数。
  final double em;
}

/// 对齐。
enum SrsVisualAlign {
  start('left'),
  center('center'),
  end('right');

  const SrsVisualAlign(this.css);

  final String css;
}

/// 颜色。
enum SrsVisualTone {
  /// 正文色。
  normal,

  /// 强调色（跟随 app 主题色）。
  accent,

  /// 弱化（半透明正文色）。
  muted,
}

/// 字段的显示方式（Anki 过滤器）。
enum SrsVisualFilter {
  /// 原样。
  plain(null),

  /// 注音：`漢字[かんじ]` 显示成假名标在汉字上方。
  furigana('furigana'),

  /// 只显示汉字（去掉 `[读音]`）。
  kanji('kanji'),

  /// 只显示读音。
  kana('kana'),

  /// 先折叠，点一下才显示。
  hint('hint'),

  /// 填空（仅填空类笔记类型）。
  cloze('cloze');

  const SrsVisualFilter(this.ankiFilter);

  /// 模板里的过滤器名；null = 不加过滤器。
  final String? ankiFilter;
}

/// 一个块。不可变。
class SrsVisualBlock {
  const SrsVisualBlock({
    required this.id,
    required this.kind,
    this.fieldId,
    this.fieldName,
    this.text = '',
    this.label = '',
    this.size = SrsVisualSize.body,
    this.align = SrsVisualAlign.center,
    this.bold = false,
    this.tone = SrsVisualTone.normal,
    this.filter = SrsVisualFilter.plain,
    this.boxed = false,
    this.hideWhenEmpty = true,
  });

  /// 块 id（`b1` / `b2` …），只在本面内唯一；编辑器靠它做列表 key。
  final String id;
  final SrsVisualBlockKind kind;

  /// [SrsVisualBlockKind.field] 用：引用的字段 id。
  final String? fieldId;

  /// 编译时记下的字段名，只作 [fieldId] 失效时的回退：克隆笔记类型、跨 profile / 设备导入
  /// .apkg 都会换字段 id（模板正文里的 `{{fld:…}}` 会被改写，注释里的不会），此时按名字
  /// 认回同一个字段（读入时见 [srsReadVisualSide]）。
  final String? fieldName;

  /// [SrsVisualBlockKind.text] 用：固定文字（纯文本，编译时转义）。
  final String text;

  /// 字段块上方的小标题（如「例句」）；空 = 不显示。
  final String label;

  final SrsVisualSize size;
  final SrsVisualAlign align;
  final bool bold;
  final SrsVisualTone tone;
  final SrsVisualFilter filter;

  /// 加一层浅色底框（把一组内容框起来）。
  final bool boxed;

  /// 字段为空时整块（含小标题）不出现（`{{#字段}}…{{/字段}}`）。
  final bool hideWhenEmpty;

  SrsVisualBlock copyWith({
    String? id,
    SrsVisualBlockKind? kind,
    String? fieldId,
    String? fieldName,
    String? text,
    String? label,
    SrsVisualSize? size,
    SrsVisualAlign? align,
    bool? bold,
    SrsVisualTone? tone,
    SrsVisualFilter? filter,
    bool? boxed,
    bool? hideWhenEmpty,
  }) => SrsVisualBlock(
    id: id ?? this.id,
    kind: kind ?? this.kind,
    fieldId: fieldId ?? this.fieldId,
    // 换了字段就不再沿用旧名字（编译时会按新字段重新记）。
    fieldName: fieldName ?? (fieldId == null ? this.fieldName : null),
    text: text ?? this.text,
    label: label ?? this.label,
    size: size ?? this.size,
    align: align ?? this.align,
    bold: bold ?? this.bold,
    tone: tone ?? this.tone,
    filter: filter ?? this.filter,
    boxed: boxed ?? this.boxed,
    hideWhenEmpty: hideWhenEmpty ?? this.hideWhenEmpty,
  );

  /// 持久化形态：只写与默认值不同的项，注释更短。
  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'k': kind.name,
    if (fieldId != null) 'f': fieldId,
    if (fieldName != null) 'n': fieldName,
    if (text.isNotEmpty) 't': text,
    if (label.isNotEmpty) 'l': label,
    if (size != SrsVisualSize.body) 's': size.name,
    if (align != SrsVisualAlign.center) 'a': align.name,
    if (bold) 'b': true,
    if (tone != SrsVisualTone.normal) 'c': tone.name,
    if (filter != SrsVisualFilter.plain) 'x': filter.name,
    if (boxed) 'box': true,
    if (!hideWhenEmpty) 'show': true,
  };

  /// 解析持久化形态；认不出种类 / 字段块没有字段时返回 null（整块丢弃，不猜）。
  static SrsVisualBlock? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final SrsVisualBlockKind? kind = _byName(
      SrsVisualBlockKind.values,
      raw['k'],
    );
    final Object? id = raw['id'];
    if (kind == null || id is! String || id.isEmpty) return null;
    final Object? fieldId = raw['f'];
    if (kind == SrsVisualBlockKind.field &&
        (fieldId is! String || fieldId.isEmpty)) {
      return null;
    }
    return SrsVisualBlock(
      id: id,
      kind: kind,
      fieldId: fieldId is String ? fieldId : null,
      fieldName: raw['n'] is String ? raw['n'] as String : null,
      text: raw['t'] is String ? raw['t'] as String : '',
      label: raw['l'] is String ? raw['l'] as String : '',
      size: _byName(SrsVisualSize.values, raw['s']) ?? SrsVisualSize.body,
      align: _byName(SrsVisualAlign.values, raw['a']) ?? SrsVisualAlign.center,
      bold: raw['b'] == true,
      tone: _byName(SrsVisualTone.values, raw['c']) ?? SrsVisualTone.normal,
      filter:
          _byName(SrsVisualFilter.values, raw['x']) ?? SrsVisualFilter.plain,
      boxed: raw['box'] == true,
      hideWhenEmpty: raw['show'] != true,
    );
  }
}

T? _byName<T extends Enum>(List<T> values, Object? name) {
  if (name is! String) return null;
  for (final T v in values) {
    if (v.name == name) return v;
  }
  return null;
}

/// 注释标记的前缀与版本。
const String kSrsVisualMarkerPrefix = '<!--fushi-visual:v1:';

final RegExp _markerPattern = RegExp(
  r'^\s*<!--fushi-visual:v1:([A-Za-z0-9_\-=]*)-->',
);

/// 编码一面的块成注释标记。
String srsVisualMarker(List<SrsVisualBlock> blocks) {
  final String json = jsonEncode(<String, Object?>{
    'blocks': <Map<String, Object?>>[
      for (final SrsVisualBlock b in blocks) b.toJson(),
    ],
  });
  return '$kSrsVisualMarkerPrefix${base64Url.encode(utf8.encode(json))}-->';
}

/// 从模板正文开头的注释读回块；没有标记 / 解不开返回 null（= 这面不是可视化做的）。
List<SrsVisualBlock>? srsParseVisualMarker(String template) {
  final RegExpMatch? m = _markerPattern.firstMatch(template);
  if (m == null) return null;
  try {
    final Object? decoded = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(m.group(1)!))),
    );
    if (decoded is! Map || decoded['blocks'] is! List) return null;
    return <SrsVisualBlock>[
      for (final Object? raw in decoded['blocks'] as List)
        ?SrsVisualBlock.fromJson(raw),
    ];
  } on FormatException {
    return null;
  }
}

/// 编译用到的笔记类型信息。
class SrsVisualCompileContext {
  const SrsVisualCompileContext({
    required this.fieldNameById,
    this.isCloze = false,
  });

  factory SrsVisualCompileContext.of(SrsNoteTypeView type) =>
      SrsVisualCompileContext(
        fieldNameById: <String, String>{
          for (final SrsFieldDef f in type.fields) f.id: f.name,
        },
        isCloze: type.isCloze,
      );

  final Map<String, String> fieldNameById;
  final bool isCloze;
}

/// 强调色：宿主注入的主题色变量，带默认值（导出到 Anki 没有宿主时用 Fushi 默认绿）。
const String _kAccent = 'var(--fushi-srs-accent, #386A58)';

String _escapeText(String s) => const HtmlEscape(HtmlEscapeMode.element)
    .convert(s)
    .replaceAll('{', '&#123;')
    .replaceAll('}', '&#125;')
    .replaceAll('\n', '<br>');

String _num(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

/// 一块的内联样式。
String _style(SrsVisualBlock b) {
  final List<String> out = <String>[
    'text-align:${b.align.css}',
    if (b.size != SrsVisualSize.body) 'font-size:${_num(b.size.em)}em',
    if (b.size == SrsVisualSize.display || b.size == SrsVisualSize.title)
      'line-height:1.35',
    if (b.bold) 'font-weight:700',
    switch (b.tone) {
      SrsVisualTone.normal => '',
      SrsVisualTone.accent => 'color:$_kAccent',
      SrsVisualTone.muted => 'opacity:0.7',
    },
    'margin:0.45em 0',
    if (b.boxed) ...<String>[
      'background:rgba(127,127,127,0.12)',
      'border-radius:12px',
      'padding:0.6em 0.9em',
    ],
  ];
  return out.where((String s) => s.isNotEmpty).join(';');
}

String _labelHtml(SrsVisualBlock b) => b.label.trim().isEmpty
    ? ''
    : '<div style="font-size:0.75em;opacity:0.65;margin-bottom:0.2em">'
          '${_escapeText(b.label.trim())}</div>';

/// 编译一面（不含注释标记）。字段块引用的字段已不存在时整块跳过（字段被删了）。
String srsCompileVisualBody(
  List<SrsVisualBlock> blocks,
  SrsVisualCompileContext ctx,
) {
  final StringBuffer out = StringBuffer('<div class="fushi-visual">\n');
  for (final SrsVisualBlock b in blocks) {
    switch (b.kind) {
      case SrsVisualBlockKind.field:
        final String? name = ctx.fieldNameById[b.fieldId];
        if (name == null) continue;
        final SrsVisualFilter filter =
            b.filter == SrsVisualFilter.cloze && !ctx.isCloze
            ? SrsVisualFilter.plain
            : b.filter;
        final String tag = filter.ankiFilter == null
            ? '{{$name}}'
            : '{{${filter.ankiFilter}:$name}}';
        final String div =
            '<div class="fv-block" style="${_style(b)}">'
            '${_labelHtml(b)}$tag</div>';
        // 填空字段不包条件段：填空卡的正面由 cN 决定，字段本身恒非空。
        if (b.hideWhenEmpty && filter != SrsVisualFilter.cloze) {
          out.writeln('{{#$name}}$div{{/$name}}');
        } else {
          out.writeln(div);
        }
      case SrsVisualBlockKind.text:
        if (b.text.trim().isEmpty) continue;
        out.writeln(
          '<div class="fv-text" style="${_style(b)}">${_escapeText(b.text)}</div>',
        );
      case SrsVisualBlockKind.divider:
        out.writeln(
          '<hr class="fv-divider" style="border:none;border-top:1px solid '
          '${b.tone == SrsVisualTone.accent ? _kAccent : 'rgba(127,127,127,0.35)'};'
          'margin:0.9em 0">',
        );
      case SrsVisualBlockKind.frontSide:
        out.writeln('{{FrontSide}}');
    }
  }
  out.write('</div>');
  return out.toString();
}

/// 编译一面（注释标记 + 正文），名字形式。
///
/// 注释里的字段块顺手记下当前字段名（[SrsVisualBlock.fieldName]），供字段 id 换了之后回退。
String srsCompileVisualSide(
  List<SrsVisualBlock> blocks,
  SrsVisualCompileContext ctx,
) {
  final List<SrsVisualBlock> named = <SrsVisualBlock>[
    for (final SrsVisualBlock b in blocks)
      ctx.fieldNameById[b.fieldId] == null
          ? b
          : b.copyWith(fieldName: ctx.fieldNameById[b.fieldId]),
  ];
  return '${srsVisualMarker(named)}\n${srsCompileVisualBody(named, ctx)}';
}

/// 把块里失效的字段 id 按记下的字段名认回当前笔记类型的字段（克隆 / 跨设备导入后 id 会换）。
List<SrsVisualBlock> _resolveFieldIds(
  List<SrsVisualBlock> blocks,
  SrsVisualCompileContext ctx,
) {
  final Map<String, String> idByName = <String, String>{
    for (final MapEntry<String, String> e in ctx.fieldNameById.entries)
      e.value: e.key,
  };
  return <SrsVisualBlock>[
    for (final SrsVisualBlock b in blocks)
      if (b.kind != SrsVisualBlockKind.field ||
          ctx.fieldNameById.containsKey(b.fieldId) ||
          idByName[b.fieldName] == null)
        b
      else
        b.copyWith(fieldId: idByName[b.fieldName], fieldName: b.fieldName),
  ];
}

/// 去掉注释标记后的正文。
String _bodyOf(String template) => template.replaceFirst(_markerPattern, '');

/// 打开一面模板时的状态。
class SrsVisualSideState {
  const SrsVisualSideState({required this.blocks, required this.edited});

  /// 读回的块；null = 这面不是可视化做的。
  final List<SrsVisualBlock>? blocks;

  /// 有块，但正文与块编译出来的不一致（有人在代码页手改过）。
  final bool edited;

  bool get isVisual => blocks != null;
}

/// 读一面（名字形式的模板正文）。
SrsVisualSideState srsReadVisualSide(
  String template,
  SrsVisualCompileContext ctx,
) {
  final List<SrsVisualBlock>? parsed = srsParseVisualMarker(template);
  if (parsed == null) {
    return const SrsVisualSideState(blocks: null, edited: false);
  }
  final List<SrsVisualBlock> blocks = _resolveFieldIds(parsed, ctx);
  // 只比正文：注释里的字段 id / 名字是元数据，克隆或导入后它们与正文不同步不算手改。
  final String expected = srsCompileVisualBody(blocks, ctx);
  return SrsVisualSideState(
    blocks: blocks,
    edited: _normalize(expected) != _normalize(_bodyOf(template)),
  );
}

/// 删字段时把可视化的一面里引用它的块去掉并整面重编；这一面不是可视化做的、在代码页手改过
/// （[SrsVisualSideState.edited]）、或根本没引用它时返回 null（不用改）。[template] 是名字形式
/// 的正文，[ctx] 仍含要删的字段。
///
/// 手改过的一面不重编：重编只按注释里的块生成正文，会把手写的部分整段丢掉，而删字段这条路径
/// 上用户看不到可视化页那条「再改会覆盖」的提示。这种面交回 Anki 语义的引用剥离处理。
String? srsVisualDropField(
  String template,
  String fieldId,
  SrsVisualCompileContext ctx,
) {
  final SrsVisualSideState state = srsReadVisualSide(template, ctx);
  final List<SrsVisualBlock>? blocks = state.blocks;
  if (blocks == null ||
      state.edited ||
      !blocks.any((SrsVisualBlock b) => b.fieldId == fieldId)) {
    return null;
  }
  return srsCompileVisualSide(<SrsVisualBlock>[
    for (final SrsVisualBlock b in blocks)
      if (b.fieldId != fieldId) b,
  ], ctx);
}

String _normalize(String s) => s.replaceAll('\r\n', '\n').trim();

/// 一面里下一个没用过的块 id。
String srsNextVisualBlockId(Iterable<SrsVisualBlock> blocks) {
  int max = 0;
  for (final SrsVisualBlock b in blocks) {
    final int? n = b.id.startsWith('b')
        ? int.tryParse(b.id.substring(1))
        : null;
    if (n != null && n > max) max = n;
  }
  return 'b${max + 1}';
}

/// 给一组块重新编号（`b1`…）：AI 产出、自动布局用，保证 id 唯一。
List<SrsVisualBlock> srsRenumberVisualBlocks(List<SrsVisualBlock> blocks) =>
    <SrsVisualBlock>[
      for (final (int i, SrsVisualBlock b) in blocks.indexed)
        b.copyWith(id: 'b${i + 1}'),
    ];

/// 自动布局（「按字段生成」）：正面放词条字段；背面先重复正面（填空类型改放填空字段）、一条
/// 分隔线，再按已知字段的惯例顺序摆其余字段（开关 / 数据字段不放），未知字段按原顺序排在
/// 最后、带字段名小标题。
({List<SrsVisualBlock> front, List<SrsVisualBlock> back})
srsSuggestVisualLayout(SrsNoteTypeView type) {
  final List<SrsFieldDef> fields = type.fields;
  if (fields.isEmpty) {
    return (front: const <SrsVisualBlock>[], back: const <SrsVisualBlock>[]);
  }
  final SrsFieldDef term =
      fields.where((SrsFieldDef f) => f.id == type.termFieldId).firstOrNull ??
      fields.first;
  final List<SrsVisualBlock> front = <SrsVisualBlock>[
    SrsVisualBlock(
      id: 'b1',
      kind: SrsVisualBlockKind.field,
      fieldId: term.id,
      size: type.isCloze ? SrsVisualSize.title : SrsVisualSize.display,
      filter: type.isCloze ? SrsVisualFilter.cloze : SrsVisualFilter.plain,
      hideWhenEmpty: false,
    ),
  ];
  final List<(int, SrsFieldDef)> known = <(int, SrsFieldDef)>[];
  final List<SrsFieldDef> unknown = <SrsFieldDef>[];
  for (final SrsFieldDef f in fields) {
    if (f.id == term.id) continue;
    final SrsFieldInfo? info = srsKnownField(f.name);
    if (info == null) {
      unknown.add(f);
    } else if (info.backOrder != null) {
      known.add((info.backOrder!, f));
    }
  }
  known.sort(
    ((int, SrsFieldDef) a, (int, SrsFieldDef) b) => a.$1.compareTo(b.$1),
  );
  final List<SrsVisualBlock> back = <SrsVisualBlock>[
    // 填空类型的背面不能重复正面：{{FrontSide}} 展开的是问题面，挖空处仍是 [...]，答案
    // 永远不出现。与 Anki 自带填空模板一样，背面自己放一次填空字段（答案面显示挖出的词）。
    if (type.isCloze)
      front.single
    else
      const SrsVisualBlock(id: 'b1', kind: SrsVisualBlockKind.frontSide),
    const SrsVisualBlock(id: 'b2', kind: SrsVisualBlockKind.divider),
    for (final (int _, SrsFieldDef f) in known)
      SrsVisualBlock(
        id: '',
        kind: SrsVisualBlockKind.field,
        fieldId: f.id,
        size: srsKnownField(f.name)!.suggestedSize,
        filter: srsKnownField(f.name)!.suggestedFilter,
        tone: srsKnownField(f.name)!.suggestedSize == SrsVisualSize.small
            ? SrsVisualTone.muted
            : SrsVisualTone.normal,
      ),
    for (final SrsFieldDef f in unknown)
      SrsVisualBlock(
        id: '',
        kind: SrsVisualBlockKind.field,
        fieldId: f.id,
        label: f.name,
      ),
  ];
  return (front: front, back: srsRenumberVisualBlocks(back));
}
