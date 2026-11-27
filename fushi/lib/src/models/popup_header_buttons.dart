import 'dart:convert';

import 'package:fushi_anki/fushi_anki.dart' show MiningRequestOverrides;

/// 查词弹窗词条头上的按钮（拍板台 b1JDe8McbS：「按钮可自定义与排序，含高级制卡、音频」）。
///
/// [wire] 是 popup.js `createEntryHeader` 里每颗按钮的槽位名，改名会让存量顺序失效，
/// 冻结不改。新增按钮在这里加一项，并在 popup.js 里按同名槽位登记。
enum PopupHeaderButton {
  /// 单词音频 ♪（含音频源菜单）。
  audio('audio'),

  /// 收藏 ☆。
  favorite('favorite'),

  /// Fushi 复习状态标记（复习模块关着时不渲染）。
  srsStatus('srs'),

  /// 默认制卡「+」（当前 Anki 设置的字段映射）。
  mine('mine'),

  /// 在 Anki 中打开 ↗（只在已制卡时出现）。
  openInAnki('openAnki'),

  /// 句子上下文「上 N / 下 N」选择器与清空按钮（只在支持句子草稿的表面出现）。
  sentenceContext('context'),

  /// 应用外查词卡的「调整句子音频」。
  crossAppAudio('crossAppAudio'),

  /// 高级制卡。
  advancedMining('advanced');

  const PopupHeaderButton(this.wire);

  final String wire;

  static PopupHeaderButton? fromWire(String wire) {
    for (final PopupHeaderButton b in values) {
      if (b.wire == wire) return b;
    }
    return null;
  }
}

/// 一颗额外的制卡按钮绑定的制卡方案：只记它和当前字段映射不一样的项，其余继承。
///
/// 拍板台 b1JDe8McbS 方案 A：不绑旧的整包配置（Profile），以免组合拆分后再迁一次。
/// 落卡时经 [MiningRequestOverrides] 随这一次请求走（待发队列、互联转发、暂存原样保留）。
class PopupMiningScheme {
  const PopupMiningScheme({
    required this.id,
    required this.label,
    this.deckName,
    this.fieldTemplates = const <String, String>{},
    this.omitAudio = false,
    this.omitImage = false,
  });

  /// 稳定 id（槽位名 `scheme:<id>` 的后半段），创建后不变。
  final String id;

  /// 按钮上显示的短名（如「假名」）。
  final String label;

  /// 写进哪个卡组；null = 跟随设置。
  final String? deckName;

  /// Anki 字段名 → 这颗按钮改用的模板；不在表里的字段继承字段映射。
  final Map<String, String> fieldTemplates;

  /// 不要句子音频。
  final bool omitAudio;

  /// 不要卡图。
  final bool omitImage;

  /// 弹窗词条头上的槽位名。
  String get slot => '$kPopupMiningSchemeSlotPrefix$id';

  /// 这套方案作为单次制卡请求的覆盖项。
  MiningRequestOverrides get overrides => MiningRequestOverrides(
    deckName: deckName,
    fieldTemplates: fieldTemplates,
    omitAudio: omitAudio,
    omitImage: omitImage,
  );

  PopupMiningScheme copyWith({
    String? label,
    String? deckName,
    bool clearDeckName = false,
    Map<String, String>? fieldTemplates,
    bool? omitAudio,
    bool? omitImage,
  }) => PopupMiningScheme(
    id: id,
    label: label ?? this.label,
    deckName: clearDeckName ? null : (deckName ?? this.deckName),
    fieldTemplates: fieldTemplates ?? this.fieldTemplates,
    omitAudio: omitAudio ?? this.omitAudio,
    omitImage: omitImage ?? this.omitImage,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'label': label,
    if (deckName != null) 'deck': deckName,
    if (fieldTemplates.isNotEmpty) 'fieldTemplates': fieldTemplates,
    if (omitAudio) 'omitAudio': true,
    if (omitImage) 'omitImage': true,
  };

  /// 坏项返回 null（id / 名字缺失）。
  static PopupMiningScheme? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['id'];
    final Object? label = raw['label'];
    if (id is! String || id.isEmpty || label is! String) return null;
    final Object? deck = raw['deck'];
    final Object? templates = raw['fieldTemplates'];
    return PopupMiningScheme(
      id: id,
      label: label,
      deckName: deck is String && deck.trim().isNotEmpty ? deck : null,
      fieldTemplates: templates is Map
          ? Map<String, String>.unmodifiable(<String, String>{
              for (final MapEntry<Object?, Object?> e in templates.entries)
                if (e.key case final String name
                    when name.isNotEmpty && e.value is String)
                  name: e.value! as String,
            })
          : const <String, String>{},
      omitAudio: raw['omitAudio'] == true,
      omitImage: raw['omitImage'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PopupMiningScheme &&
      other.id == id &&
      other.label == label &&
      other.deckName == deckName &&
      other.omitAudio == omitAudio &&
      other.omitImage == omitImage &&
      _mapEquals(other.fieldTemplates, fieldTemplates);

  @override
  int get hashCode => Object.hash(
    id,
    label,
    deckName,
    omitAudio,
    omitImage,
    Object.hashAllUnordered(
      fieldTemplates.entries.map(
        (MapEntry<String, String> e) => Object.hash(e.key, e.value),
      ),
    ),
  );
}

bool _mapEquals(Map<String, String> a, Map<String, String> b) {
  if (a.length != b.length) return false;
  for (final MapEntry<String, String> e in a.entries) {
    if (b[e.key] != e.value) return false;
  }
  return true;
}

/// 制卡方案槽位名的前缀。
const String kPopupMiningSchemeSlotPrefix = 'scheme:';

/// 出厂顺序（与改动前 popup.js 的固定排布逐项一致，没设置过的人界面不变）。
const List<PopupHeaderButton> kDefaultPopupHeaderButtonOrder =
    PopupHeaderButton.values;

/// 查词弹窗词条头按钮的排布：顺序、隐藏哪些、额外的制卡按钮（制卡方案）。
///
/// 存一个偏好键（[kPopupHeaderButtonsPrefKey]），JSON。读时总是先 [normalized]：
/// 未知槽位丢掉、缺的内置按钮按出厂位置补回、方案按 id 去重——存储里有什么坏数据都
/// 不会让某颗按钮从弹窗里消失。
class PopupHeaderButtonsConfig {
  const PopupHeaderButtonsConfig({
    required this.order,
    this.hidden = const <String>{},
    this.schemes = const <PopupMiningScheme>[],
  });

  /// 出厂：内置按钮按原顺序、全部显示、没有额外制卡按钮。
  static final PopupHeaderButtonsConfig defaults = PopupHeaderButtonsConfig(
    order: <String>[
      for (final PopupHeaderButton b in kDefaultPopupHeaderButtonOrder) b.wire,
    ],
  );

  /// 全部槽位（内置按钮 wire 名 + `scheme:<id>`）的显示顺序。
  final List<String> order;

  /// 用户隐藏的槽位。隐藏只是不显示：快捷键 / 高级制卡确认回点照常能找到「+」。
  final Set<String> hidden;

  /// 额外的制卡按钮。
  final List<PopupMiningScheme> schemes;

  bool get isDefault =>
      hidden.isEmpty && schemes.isEmpty && _listEquals(order, defaults.order);

  bool isHidden(String slot) => hidden.contains(slot);

  PopupMiningScheme? schemeById(String id) {
    for (final PopupMiningScheme s in schemes) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// 修正后的副本：
  /// * 方案按 id 去重（先到先得）；
  /// * [order] 去掉未知 / 重复槽位，缺的内置按钮插回它出厂时的前一位之后，缺的方案
  ///   插在最后一颗制卡按钮（「+」或已有方案）之后；
  /// * [hidden] 只留存在的槽位。
  PopupHeaderButtonsConfig normalized() {
    final List<PopupMiningScheme> uniqueSchemes = <PopupMiningScheme>[];
    final Set<String> schemeIds = <String>{};
    for (final PopupMiningScheme s in schemes) {
      if (schemeIds.add(s.id)) uniqueSchemes.add(s);
    }
    final Set<String> known = <String>{
      for (final PopupHeaderButton b in PopupHeaderButton.values) b.wire,
      for (final PopupMiningScheme s in uniqueSchemes) s.slot,
    };
    final List<String> out = <String>[];
    for (final String slot in order) {
      if (known.contains(slot) && !out.contains(slot)) out.add(slot);
    }
    // 缺的内置按钮：插在出厂顺序里它前面那颗（已在 out 里的）之后；前面都没有就放最前。
    for (int i = 0; i < kDefaultPopupHeaderButtonOrder.length; i++) {
      final String wire = kDefaultPopupHeaderButtonOrder[i].wire;
      if (out.contains(wire)) continue;
      int insertAt = 0;
      for (int j = i - 1; j >= 0; j--) {
        final int at = out.indexOf(kDefaultPopupHeaderButtonOrder[j].wire);
        if (at >= 0) {
          insertAt = at + 1;
          break;
        }
      }
      out.insert(insertAt, wire);
    }
    for (final PopupMiningScheme s in uniqueSchemes) {
      if (out.contains(s.slot)) continue;
      out.insert(_afterLastMineSlot(out), s.slot);
    }
    return PopupHeaderButtonsConfig(
      order: List<String>.unmodifiable(out),
      hidden: Set<String>.unmodifiable(hidden.where(known.contains)),
      schemes: List<PopupMiningScheme>.unmodifiable(uniqueSchemes),
    );
  }

  static int _afterLastMineSlot(List<String> order) {
    int last = -1;
    for (int i = 0; i < order.length; i++) {
      final String slot = order[i];
      if (slot == PopupHeaderButton.mine.wire ||
          slot.startsWith(kPopupMiningSchemeSlotPrefix)) {
        last = i;
      }
    }
    return last < 0 ? order.length : last + 1;
  }

  /// 把 [from] 位移到最终下标 [to]（FushiReorderableColumn 语义）。
  PopupHeaderButtonsConfig moved(int from, int to) {
    if (from == to || from < 0 || from >= order.length) return this;
    final List<String> next = <String>[...order];
    final String slot = next.removeAt(from);
    next.insert(to.clamp(0, next.length), slot);
    return PopupHeaderButtonsConfig(
      order: next,
      hidden: hidden,
      schemes: schemes,
    ).normalized();
  }

  PopupHeaderButtonsConfig withHidden(String slot, bool isHidden) {
    final Set<String> next = <String>{...hidden};
    if (isHidden) {
      next.add(slot);
    } else {
      next.remove(slot);
    }
    return PopupHeaderButtonsConfig(
      order: order,
      hidden: next,
      schemes: schemes,
    ).normalized();
  }

  /// 新增或替换（按 id）一套方案；新增的插在最后一颗制卡按钮之后。
  PopupHeaderButtonsConfig withScheme(PopupMiningScheme scheme) {
    final List<PopupMiningScheme> next = <PopupMiningScheme>[
      for (final PopupMiningScheme s in schemes)
        if (s.id == scheme.id) scheme else s,
    ];
    if (!next.any((PopupMiningScheme s) => s.id == scheme.id)) {
      next.add(scheme);
    }
    return PopupHeaderButtonsConfig(
      order: order,
      hidden: hidden,
      schemes: next,
    ).normalized();
  }

  PopupHeaderButtonsConfig withoutScheme(String id) => PopupHeaderButtonsConfig(
    order: order,
    hidden: hidden,
    schemes: <PopupMiningScheme>[
      for (final PopupMiningScheme s in schemes)
        if (s.id != id) s,
    ],
  ).normalized();

  Map<String, Object?> toJson() => <String, Object?>{
    'order': order,
    if (hidden.isNotEmpty) 'hidden': hidden.toList(),
    if (schemes.isNotEmpty)
      'schemes': <Map<String, Object?>>[
        for (final PopupMiningScheme s in schemes) s.toJson(),
      ],
  };

  /// 解析存储值；null / 坏 JSON → 出厂排布。结果总是 [normalized] 过的。
  static PopupHeaderButtonsConfig parse(String? raw) {
    if (raw == null || raw.isEmpty) return defaults;
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) return defaults;
      final Object? order = decoded['order'];
      final Object? hidden = decoded['hidden'];
      final Object? schemes = decoded['schemes'];
      return PopupHeaderButtonsConfig(
        order: <String>[
          if (order is List)
            for (final Object? s in order)
              if (s is String) s,
        ],
        hidden: <String>{
          if (hidden is List)
            for (final Object? s in hidden)
              if (s is String) s,
        },
        schemes: <PopupMiningScheme>[
          if (schemes is List)
            for (final Object? s in schemes)
              if (PopupMiningScheme.fromJson(s) case final PopupMiningScheme p)
                p,
        ],
      ).normalized();
    } on FormatException {
      return defaults;
    }
  }

  String encode() => jsonEncode(toJson());

  /// 注入 popup.js 的 `window.__fushiHeaderButtons`：顺序、隐藏、方案（槽位 → 按钮名
  /// 与单次制卡覆盖项，覆盖项形态与 `MiningRequestOverrides.toJson` 一致，popup.js
  /// 原样塞进 payload 的 `miningOverrides`）。
  Map<String, Object?> toPopupJson() => <String, Object?>{
    'order': order,
    'hidden': hidden.toList(),
    'schemes': <String, Object?>{
      for (final PopupMiningScheme s in schemes)
        s.slot: <String, Object?>{
          'label': s.label,
          'overrides': s.overrides.toJson(),
        },
    },
  };

  @override
  bool operator ==(Object other) =>
      other is PopupHeaderButtonsConfig &&
      _listEquals(other.order, order) &&
      other.hidden.length == hidden.length &&
      other.hidden.containsAll(hidden) &&
      _listEquals(other.schemes, schemes);

  @override
  int get hashCode => Object.hash(
    Object.hashAll(order),
    Object.hashAllUnordered(hidden),
    Object.hashAll(schemes),
  );
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 偏好键（JSON，见 [PopupHeaderButtonsConfig.encode]）。
const String kPopupHeaderButtonsPrefKey = 'popup_header_buttons';
