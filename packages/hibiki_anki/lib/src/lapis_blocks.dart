/// Lapis 卡片「自定义区域」的纯函数层：锚点定位、背面模板组合、区域样式 CSS。
///
/// 设计（为什么是这个形状）：
///
/// * **区域只是显示层。** 一个区域 = 把**卡型里已有的字段**摆到模板的另一个
///   位置，不新增、不删除 Anki 字段。加字段会改卡型 schema、逼 Anki 走 full
///   sync，删字段更是不可逆地删卡片数据；而区域的增删只影响「显示不显示」，
///   随时可撤。可逆的需求不做成不可逆的实现。
/// * **真相源是 Hibiki 侧的 [LapisCustomBlock] 列表，模板是产物。** 因此不需要
///   从 Anki 端模板里反解区域（那才是易碎的一步）——[composeLapisBackTemplate]
///   永远从 vendored 基线重新生成整份背面模板，Anki 端是不是我们的产物由指纹
///   判定（同 CSS 侧的 [decideLapisStylingAction]）。
/// * **锚点是 vendored 模板里真实存在的字面结构**，不预埋自定义注释：基线必须
///   逐字节等于上游，且老用户 Anki 里的卡型也没有任何预埋标记。锚串唯一性由
///   `lapis_blocks_test.dart` 守卫，上游 re-vendor 改了结构立刻打红，而不是
///   静默把区域丢掉。
library;

import 'package:collection/collection.dart';

import 'anki_note_type_definition.dart';
import 'lapis_note_type.dart';
import 'lapis_styling.dart';

/// 托管区段标记。用户在 Anki 里看到这段就知道是 Hibiki 生成的；标记之间的内容
/// 每次应用都会被整体重写。
const String lapisBlocksBeginMarker = '<!-- HIBIKI-LAPIS-BLOCKS BEGIN -->';
const String lapisBlocksEndMarker = '<!-- HIBIKI-LAPIS-BLOCKS END -->';

/// 自定义区域的插入位置。
///
/// 每个锚点绑定一段 vendored 背面模板里**唯一**的字面串（[anchorText]），区域
/// 插在它之前还是之后由 [insertAfter] 决定。只提供这 5 个位置而不是任意拖拽：
/// Lapis 的例句/图片位置本身就是可切换的（见 [LapisVisualLayout]），按像素拖出
/// 来的位置在真卡上不一定成立，会退化成所见非所得。
enum LapisBlockAnchor {
  /// 卡片顶部（`<main>` 之后，单词区之前）。
  top('top', '<main>', insertAfter: true),

  /// 单词区下方 / 例句上方。
  aboveSentence('above-sentence', '<div class="sentence"'),

  /// 例句下方 / 释义区上方。
  aboveDefinition('above-definition', '<div class="def-info"'),

  /// 释义框下方。
  belowDefinition('below-definition', '<div class="sentence-alt"'),

  /// 卡片底部（`</main>` 之前）。
  bottom('bottom', '</main>');

  const LapisBlockAnchor(
    this.wireName,
    this.anchorText, {
    this.insertAfter = false,
  });

  final String wireName;

  /// 定位用的字面串，必须在 vendored 背面模板**与编辑器预览 mock** 里各恰好
  /// 出现一次。
  ///
  /// 刻意**不带收尾 `>`**：真模板写的是 `<div class="sentence">`，预览 mock 上
  /// 同一个元素还挂着 `data-hibiki-lapis-targets` 等属性，带 `>` 的锚串在预览里
  /// 一个都匹配不上。收尾留一个引号即可保证唯一——`<div class="sentence"` 不会
  /// 命中 `<div class="sentence-alt"`（`sentence` 后面是 `-` 不是引号）。
  final String anchorText;

  /// true = 插在 [anchorText] 之后，false = 之前。
  final bool insertAfter;

  static LapisBlockAnchor? fromWireName(String value) {
    for (final LapisBlockAnchor anchor in values) {
      if (anchor.wireName == value) return anchor;
    }
    return null;
  }
}

/// 合法的 Anki 字段名：只允许字母数字下划线。
///
/// 字段名会**原样拼进模板 handlebar**（`{{#X}}{{X}}{{/X}}`），所以这里是注入
/// 边界，不是形式主义——`}}` / `<` / 引号漏过去就能改写模板结构。
final RegExp _lapisFieldNamePattern = RegExp(r'^[A-Za-z0-9_]+$');

bool isValidLapisBlockFieldName(String name) =>
    _lapisFieldNamePattern.hasMatch(name);

/// 区域 id：生成 selector 和 data 属性用，同样是注入边界。
final RegExp _lapisBlockIdPattern = RegExp(r'^[a-z0-9-]+$');

bool isValidLapisBlockId(String id) => _lapisBlockIdPattern.hasMatch(id);

/// 一个自定义区域。
class LapisCustomBlock {
  const LapisCustomBlock({
    required this.id,
    required this.anchor,
    required this.fields,
    this.rule = const LapisVisualRule(),
  });

  /// 稳定 id（`b1` / `b2` …）。删除后不复用：复用会让旧 CSS 规则落到新区域上。
  final String id;

  final LapisBlockAnchor anchor;

  /// 这块要显示的 Anki 字段名，按显示顺序。
  final List<String> fields;

  /// 这块自己的样式。**内嵌而不是存进 CSS 侧的字段规则表**：样式跟着拥有者走，
  /// 删区域时样式自动一起没，不会留下指向已删 id 的孤儿规则。
  final LapisVisualRule rule;

  LapisCustomBlock copyWith({
    LapisBlockAnchor? anchor,
    List<String>? fields,
    LapisVisualRule? rule,
  }) =>
      LapisCustomBlock(
        id: id,
        anchor: anchor ?? this.anchor,
        fields: fields ?? this.fields,
        rule: rule ?? this.rule,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'anchor': anchor.wireName,
        'fields': fields,
        if (!rule.isDefault) 'rule': rule.toJson(),
      };

  /// 解析一个区域；id / 锚点 / 字段任一不合法就返回 null（整条丢弃，不猜）。
  static LapisCustomBlock? fromJson(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    final Object? rawId = value['id'];
    if (rawId is! String || !isValidLapisBlockId(rawId)) return null;
    final Object? rawAnchor = value['anchor'];
    final LapisBlockAnchor? anchor =
        rawAnchor is String ? LapisBlockAnchor.fromWireName(rawAnchor) : null;
    if (anchor == null) return null;
    final List<String> fields = (value['fields'] as List<dynamic>? ?? const [])
        .whereType<String>()
        .where(isValidLapisBlockFieldName)
        .toList();
    return LapisCustomBlock(
      id: rawId,
      anchor: anchor,
      fields: fields,
      rule: LapisVisualRule.fromJson(value['rule']) ?? const LapisVisualRule(),
    );
  }
}

/// 下一个可用的区域 id：取现有最大编号 +1，**不复用已删编号**。
String nextLapisBlockId(Iterable<LapisCustomBlock> blocks) {
  int max = 0;
  for (final LapisCustomBlock block in blocks) {
    final Match? m = RegExp(r'^b(\d+)$').firstMatch(block.id);
    final int? n = m == null ? null : int.tryParse(m.group(1)!);
    if (n != null && n > max) max = n;
  }
  return 'b${max + 1}';
}

/// 预览里区域的点击目标名。与 [LapisVisualField.wireName] 共用同一个命名空间，
/// 用 `block-` 前缀区分——字段 wireName 全是固定字面量，不会以 `block-` 开头。
String lapisPreviewBlockTarget(String id) => 'block-$id';

/// [lapisPreviewBlockTarget] 的逆运算；不是区域目标就返回 null。
String? lapisBlockIdFromPreviewTarget(String target) =>
    target.startsWith('block-') ? target.substring('block-'.length) : null;

/// 区域的稳定 selector。样式控件直接复用它，不需要为自定义区域另造一套。
String lapisBlockSelector(String id) => '[data-hibiki-block="$id"]';

/// 区域列表 → JSON（存进 [AnkiSettings.lapisCustomBlocks]）。
List<Map<String, Object?>> lapisBlocksToJson(List<LapisCustomBlock> blocks) =>
    blocks.map((LapisCustomBlock b) => b.toJson()).toList();

/// JSON → 区域列表。坏条目逐条丢弃，不整体失败：一条脏数据不该让所有区域消失。
List<LapisCustomBlock> lapisBlocksFromJson(Object? value) {
  if (value is! List) return const <LapisCustomBlock>[];
  return value
      .map(LapisCustomBlock.fromJson)
      .whereType<LapisCustomBlock>()
      .toList();
}

/// 单个区域的 HTML。
///
/// 每个字段用 `{{#X}}…{{/X}}` 条件包裹：字段为空时 Anki 不渲染那段，整块因此
/// 可能变成真正的空元素——生成时不留缩进空白，配合 [lapisBlocksBaseCss] 的
/// `:empty` 规则，空区域不会在卡上留一条空白带。
String buildLapisBlockHtml(LapisCustomBlock block) {
  final Iterable<String> parts =
      block.fields.where(isValidLapisBlockFieldName).map((String f) => '{{#$f}}'
          '<div class="hibiki-block-field" data-hibiki-field="$f">{{$f}}</div>'
          '{{/$f}}');
  return '<div class="hibiki-block" data-hibiki-block="${block.id}">'
      '${parts.join()}'
      '</div>';
}

/// 自定义区域的基线 CSS：只做「空块不占位」和最小间距，具体外观交给每块自己的
/// [LapisCustomBlock.rule]。随区域一起进托管区段，没有区域时不产出。
const String lapisBlocksBaseCss = '.hibiki-block:empty {\n'
    '  display: none;\n'
    '}\n'
    '.hibiki-block {\n'
    '  margin-block: 0.4em;\n'
    '}';

/// 全部区域的样式 CSS（含基线）。声明生成复用字段规则那一套
/// （[lapisVisualDeclarations]），所以区域天然支持同样的字号/粗体/对齐/颜色/
/// 边框参数。
List<String> buildLapisBlocksCss(List<LapisCustomBlock> blocks) {
  if (blocks.isEmpty) return const <String>[];
  final List<String> rules = <String>[lapisBlocksBaseCss];
  for (final LapisCustomBlock block in blocks) {
    if (block.rule.isDefault) continue;
    final String selector = lapisBlockSelector(block.id);
    final List<String> declarations = lapisVisualDeclarations(block.rule);
    if (declarations.isNotEmpty) {
      rules.add('$selector {\n${declarations.join('\n')}\n}');
    }
    if (block.rule.fontScalePercent != 100) {
      final String factor =
          (block.rule.fontScalePercent / 100).toStringAsFixed(2);
      rules.add('$selector {\n'
          '  font-size: calc(var(--main-def-size) * $factor) !important;\n'
          '}');
    }
  }
  return rules;
}

/// 组合背面模板：vendored 基线 + 各锚点处的托管区段。
///
/// 无区域时**逐字节等于** [LapisNoteType.back]（零破坏：没用这个功能的用户，
/// 推送的模板与出厂完全一致）。
///
/// 锚串在基线里找不到时抛 [StateError] 而不是静默跳过——那意味着 vendored 模板
/// 结构变了，静默跳过会让用户配好的区域凭空消失。
String composeLapisBackTemplate(List<LapisCustomBlock> blocks) =>
    insertLapisBlocksIntoBackHtml(
      LapisNoteType.back,
      blocks,
      renderBlock: buildLapisBlockHtml,
    );

/// 把 [blocks] 按锚点插进一段背面 HTML。
///
/// 真模板与编辑器预览**共用这一个函数**（各自只换 [renderBlock]：真模板产
/// handlebar，预览产示例内容）。定位逻辑写两份必然漂开，那正是「预览里位置对、
/// 真卡上位置不对」的经典来源。
///
/// 锚串找不到时抛 [StateError]，不静默跳过——静默跳过会让用户配好的区域凭空
/// 消失，而这通常意味着 vendored 模板结构变了，属于必须被看见的事故。
String insertLapisBlocksIntoBackHtml(
  String backHtml,
  List<LapisCustomBlock> blocks, {
  required String Function(LapisCustomBlock block) renderBlock,
}) {
  if (blocks.isEmpty) return backHtml;
  String result = backHtml;
  for (final LapisBlockAnchor anchor in LapisBlockAnchor.values) {
    final List<LapisCustomBlock> here =
        blocks.where((LapisCustomBlock b) => b.anchor == anchor).toList();
    if (here.isEmpty) continue;
    final int index = result.indexOf(anchor.anchorText);
    if (index < 0) {
      throw StateError(
        'Lapis back template lost anchor "${anchor.anchorText}" '
        '(${anchor.wireName})',
      );
    }
    final String section = <String>[
      lapisBlocksBeginMarker,
      ...here.map(renderBlock),
      lapisBlocksEndMarker,
    ].join('\n');
    final int at =
        anchor.insertAfter ? index + anchor.anchorText.length : index;
    result = '${result.substring(0, at)}\n$section\n${result.substring(at)}';
  }
  return result;
}

/// 判定 Anki 端**卡模板**相对期望背面 [expectedBack] 的处置方式。
///
/// 与 CSS 侧 [decideLapisStylingAction] 同一套语义，但**必须是独立的一份判定与
/// 指纹**：模板写坏是「卡片内容不显示」，比 CSS 写坏严重一个量级，不能借 CSS 的
/// 指纹替它背书。
///
/// [def] 里找不到 Lapis 那张卡模板（模板被改名/删掉/多卡模板）时一律判
/// [LapisStylingDecision.foreignEdit]：结构已经不是我们认识的样子，只有用户
/// 显式确认才可以覆盖。
LapisStylingDecision decideLapisTemplateAction({
  required AnkiNoteTypeDefinition def,
  required String expectedBack,
  required String? lastAppliedSha,
}) {
  final AnkiCardTemplate? card = def.templates
      .where((AnkiCardTemplate t) => t.name == LapisNoteType.cardName)
      .firstOrNull;
  if (card == null || def.templates.length != 1) {
    return LapisStylingDecision.foreignEdit;
  }
  final String back = normalizeCssForCompare(card.back);
  if (back == normalizeCssForCompare(expectedBack) &&
      normalizeCssForCompare(card.front) ==
          normalizeCssForCompare(LapisNoteType.front)) {
    return LapisStylingDecision.upToDate;
  }
  if (lastAppliedSha != null && lapisCssSha256(back) == lastAppliedSha) {
    return LapisStylingDecision.safeUpdate;
  }
  // 出厂态：用户从没动过背面模板（无区域时 composeLapisBackTemplate 逐字节
  // 等于它，所以这条也覆盖「第一次加区域」）。
  if (back == normalizeCssForCompare(LapisNoteType.back)) {
    return LapisStylingDecision.safeUpdate;
  }
  return LapisStylingDecision.foreignEdit;
}

/// 期望推送到 Anki 的完整卡模板列表（正面不变，背面按区域重算）。
List<AnkiCardTemplate> composeLapisCardTemplates(
  List<LapisCustomBlock> blocks,
) =>
    <AnkiCardTemplate>[
      AnkiCardTemplate(
        name: LapisNoteType.cardName,
        front: LapisNoteType.front,
        back: composeLapisBackTemplate(blocks),
      ),
    ];
