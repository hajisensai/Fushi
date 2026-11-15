import 'dart:convert';

import 'package:fushi_core/fushi_core.dart' show fushiDebugPrint;

/// 「高级制卡」对话框里可以由用户摆放的分区（反馈 aZ99bm9R6K）。
///
/// 句子分区是对话框的主体（当前句、增减前后文、快捷键都挂在它上面），不进可摆放
/// 列表，宽屏时固定在左栏顶部；漫画的裁切工作区同理固定占左栏整高。
enum AdvancedMiningPanelId {
  /// 卡组。
  deck,

  /// 卡片字段。
  fields,

  /// 单词音频。
  wordAudio,

  /// 句子音频（截取区间 / 试听 / 不要音频）。
  sentenceAudio,

  /// 图片（视频动图 / 片段 / 静帧、galgame 静态截图、漫画取景预览）。
  image;

  /// 持久化用的稳定名（wire key，改了会让存量偏好失效，冻结）。
  String get wireName => switch (this) {
    AdvancedMiningPanelId.deck => 'deck',
    AdvancedMiningPanelId.fields => 'fields',
    AdvancedMiningPanelId.wordAudio => 'word_audio',
    AdvancedMiningPanelId.sentenceAudio => 'sentence_audio',
    AdvancedMiningPanelId.image => 'image',
  };

  static AdvancedMiningPanelId? fromWireName(String name) {
    for (final AdvancedMiningPanelId id in AdvancedMiningPanelId.values) {
      if (id.wireName == name) return id;
    }
    return null;
  }
}

/// 宽屏双栏里分区放在哪一栏。窄屏（单栏 / 手机底部面板）只认顺序与显隐。
enum AdvancedMiningColumn {
  left,
  right;

  String get wireName => name;

  static AdvancedMiningColumn? fromWireName(String name) {
    for (final AdvancedMiningColumn c in AdvancedMiningColumn.values) {
      if (c.wireName == name) return c;
    }
    return null;
  }
}

/// 一个分区的摆放：哪一栏、是否隐藏。隐藏只是不显示：打开对话框时它照常是一键
/// 「+」的默认值，制卡也照常带上（例如隐藏卡组 = 进默认卡组）。
class AdvancedMiningPanelSlot {
  const AdvancedMiningPanelSlot({
    required this.id,
    required this.column,
    this.hidden = false,
  });

  final AdvancedMiningPanelId id;
  final AdvancedMiningColumn column;
  final bool hidden;

  AdvancedMiningPanelSlot copyWith({
    AdvancedMiningColumn? column,
    bool? hidden,
  }) => AdvancedMiningPanelSlot(
    id: id,
    column: column ?? this.column,
    hidden: hidden ?? this.hidden,
  );

  @override
  bool operator ==(Object other) =>
      other is AdvancedMiningPanelSlot &&
      other.id == id &&
      other.column == column &&
      other.hidden == hidden;

  @override
  int get hashCode => Object.hash(id, column, hidden);

  @override
  String toString() =>
      'AdvancedMiningPanelSlot(${id.wireName}, ${column.wireName}'
      '${hidden ? ', hidden' : ''})';
}

/// 「高级制卡」对话框的分区布局：全部可摆放分区的**有序**列表（每个 id 恰好一次）。
///
/// 顺序同时决定宽屏每一栏内的上下次序与窄屏摘要行的次序；栏位只在宽屏双栏生效。
/// 不可变值对象，所有修改返回新实例。
class AdvancedMiningLayout {
  AdvancedMiningLayout._(List<AdvancedMiningPanelSlot> slots)
    : slots = List<AdvancedMiningPanelSlot>.unmodifiable(slots);

  /// 由任意槽位列表规整出合法布局：丢掉重复 id，缺的 id 按默认布局的栏位 / 显隐
  /// 补在末尾（新版本加了分区时，老用户存档里没有它）。
  factory AdvancedMiningLayout(List<AdvancedMiningPanelSlot> slots) {
    final Set<AdvancedMiningPanelId> seen = <AdvancedMiningPanelId>{};
    final List<AdvancedMiningPanelSlot> out = <AdvancedMiningPanelSlot>[
      for (final AdvancedMiningPanelSlot s in slots)
        if (seen.add(s.id)) s,
    ];
    for (final AdvancedMiningPanelSlot s in _defaultSlots) {
      if (seen.add(s.id)) out.add(s);
    }
    return AdvancedMiningLayout._(out);
  }

  /// 默认布局：句子音频放左栏、紧跟句子（反馈 aZ99bm9R6K：左栏下方空着、右栏太挤，
  /// 句子与它的音频是同一类操作）；卡组 / 字段 / 单词音频 / 图片在右栏。
  static const List<AdvancedMiningPanelSlot> _defaultSlots =
      <AdvancedMiningPanelSlot>[
        AdvancedMiningPanelSlot(
          id: AdvancedMiningPanelId.deck,
          column: AdvancedMiningColumn.right,
        ),
        AdvancedMiningPanelSlot(
          id: AdvancedMiningPanelId.fields,
          column: AdvancedMiningColumn.right,
        ),
        AdvancedMiningPanelSlot(
          id: AdvancedMiningPanelId.wordAudio,
          column: AdvancedMiningColumn.right,
        ),
        AdvancedMiningPanelSlot(
          id: AdvancedMiningPanelId.sentenceAudio,
          column: AdvancedMiningColumn.left,
        ),
        AdvancedMiningPanelSlot(
          id: AdvancedMiningPanelId.image,
          column: AdvancedMiningColumn.right,
        ),
      ];

  static final AdvancedMiningLayout defaults = AdvancedMiningLayout._(
    _defaultSlots,
  );

  final List<AdvancedMiningPanelSlot> slots;

  AdvancedMiningPanelSlot slotOf(AdvancedMiningPanelId id) =>
      slots.firstWhere((AdvancedMiningPanelSlot s) => s.id == id);

  bool isHidden(AdvancedMiningPanelId id) => slotOf(id).hidden;

  bool get isDefault => this == defaults;

  /// 按布局顺序取 [present] 里**未隐藏**的分区；给了 [column] 时只取该栏。
  List<AdvancedMiningPanelId> visible(
    Set<AdvancedMiningPanelId> present, {
    AdvancedMiningColumn? column,
  }) => <AdvancedMiningPanelId>[
    for (final AdvancedMiningPanelSlot s in slots)
      if (present.contains(s.id) &&
          !s.hidden &&
          (column == null || s.column == column))
        s.id,
  ];

  /// 按布局顺序取 [present] 里的全部分区（含隐藏的）：布局编辑器的行。
  List<AdvancedMiningPanelSlot> slotsAmong(
    Set<AdvancedMiningPanelId> present,
  ) => <AdvancedMiningPanelSlot>[
    for (final AdvancedMiningPanelSlot s in slots)
      if (present.contains(s.id)) s,
  ];

  AdvancedMiningLayout withColumn(
    AdvancedMiningPanelId id,
    AdvancedMiningColumn column,
  ) => AdvancedMiningLayout._(<AdvancedMiningPanelSlot>[
    for (final AdvancedMiningPanelSlot s in slots)
      s.id == id ? s.copyWith(column: column) : s,
  ]);

  AdvancedMiningLayout withHidden(AdvancedMiningPanelId id, bool hidden) =>
      AdvancedMiningLayout._(<AdvancedMiningPanelSlot>[
        for (final AdvancedMiningPanelSlot s in slots)
          s.id == id ? s.copyWith(hidden: hidden) : s,
      ]);

  /// 在「[present] 里的分区」这个子序列上把第 [from] 个移到最终下标 [to]（与
  /// `FushiReorderableColumn.onReorder` 同口径）；不在 [present] 里的分区（这个
  /// 页面没有的分区）原位不动——编辑器只列出当前页面有的分区，重排不能把别的
  /// 页面的摆放打乱。越界或原地不动时返回自身。
  AdvancedMiningLayout reorderAmong(
    Set<AdvancedMiningPanelId> present,
    int from,
    int to,
  ) {
    final List<AdvancedMiningPanelSlot> sub = slotsAmong(present);
    if (from < 0 ||
        from >= sub.length ||
        to < 0 ||
        to >= sub.length ||
        from == to) {
      return this;
    }
    final AdvancedMiningPanelSlot moved = sub.removeAt(from);
    sub.insert(to, moved);
    int next = 0;
    return AdvancedMiningLayout._(<AdvancedMiningPanelSlot>[
      for (final AdvancedMiningPanelSlot s in slots)
        present.contains(s.id) ? sub[next++] : s,
    ]);
  }

  // ───────────────────────────── 持久化 ─────────────────────────────

  /// `{"v":1,"slots":[{"id":"deck","col":"right","hidden":false},…]}`。
  String toJson() => jsonEncode(<String, Object>{
    'v': 1,
    'slots': <Map<String, Object>>[
      for (final AdvancedMiningPanelSlot s in slots)
        <String, Object>{
          'id': s.id.wireName,
          'col': s.column.wireName,
          'hidden': s.hidden,
        },
    ],
  });

  /// 读存档：null / 空串 / 坏 JSON 返回 null（调用方用 [defaults]）；未知 id 丢弃、
  /// 未知栏位按该分区默认栏位，缺的分区按默认补在末尾。
  static AdvancedMiningLayout? tryParse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final Object? list = decoded['slots'];
      if (list is! List) return null;
      final List<AdvancedMiningPanelSlot> slots = <AdvancedMiningPanelSlot>[];
      for (final Object? e in list) {
        if (e is! Map) continue;
        final Object? idRaw = e['id'];
        final AdvancedMiningPanelId? id = idRaw is String
            ? AdvancedMiningPanelId.fromWireName(idRaw)
            : null;
        if (id == null) continue;
        final Object? colRaw = e['col'];
        final AdvancedMiningColumn column =
            (colRaw is String
                ? AdvancedMiningColumn.fromWireName(colRaw)
                : null) ??
            defaults.slotOf(id).column;
        final Object? hiddenRaw = e['hidden'];
        slots.add(
          AdvancedMiningPanelSlot(
            id: id,
            column: column,
            hidden: hiddenRaw is bool && hiddenRaw,
          ),
        );
      }
      return AdvancedMiningLayout(slots);
    } catch (e) {
      fushiDebugPrint('AdvancedMiningLayout.tryParse: bad pref ($e)');
      return null;
    }
  }

  @override
  bool operator ==(Object other) {
    if (other is! AdvancedMiningLayout || other.slots.length != slots.length) {
      return false;
    }
    for (int i = 0; i < slots.length; i++) {
      if (other.slots[i] != slots[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(slots);

  @override
  String toString() => 'AdvancedMiningLayout($slots)';
}
