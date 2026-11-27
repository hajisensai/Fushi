import 'dart:convert';

import 'package:fushi/src/controls/control_layout.dart';

/// 小说阅读器常驻页眉 / 页脚（反馈 JONk4qmF8V，静读天下式状态栏）的槽位。
///
/// 页眉、页脚各左 / 中 / 右三格，外加 [hidden]（「不显示」托盘）。与工具栏布局走
/// 同一套泛型 [ControlLayout]，编辑器也是同一个 `ControlLayoutEditor`。
enum ReaderStatusBarSlot implements ControlSlotSpec {
  headerLeft('header_left'),
  headerCenter('header_center'),
  headerRight('header_right'),
  footerLeft('footer_left'),
  footerCenter('footer_center'),
  footerRight('footer_right'),
  hidden('hidden');

  const ReaderStatusBarSlot(this.storageValue);

  @override
  final String storageValue;

  bool get isHeader =>
      this == headerLeft || this == headerCenter || this == headerRight;

  bool get isFooter =>
      this == footerLeft || this == footerCenter || this == footerRight;

  static const List<ReaderStatusBarSlot> headerSlots = <ReaderStatusBarSlot>[
    headerLeft,
    headerCenter,
    headerRight,
  ];

  static const List<ReaderStatusBarSlot> footerSlots = <ReaderStatusBarSlot>[
    footerLeft,
    footerCenter,
    footerRight,
  ];
}

/// 状态栏里可放的读数。每项只能出现一次（[isSingleInstance]），任何槽位都能放。
///
/// 现有右下角读数胶囊（计时 / 本次字数 / 字每时 / 全书进度条）不在这里：它仍由
/// 「读数与屏幕」的四个开关控制，固定在页脚最右端（页脚右槽的读数排在它左边）。
enum ReaderStatusBarItem implements ControlItemSpec<ReaderStatusBarSlot> {
  clock('clock'),
  battery('battery'),
  chapterTitle('chapter_title'),
  bookTitle('book_title'),
  chapterPage('chapter_page'),
  chapterProgress('chapter_progress'),
  chapterChars('chapter_chars'),
  bookProgress('book_progress'),
  bookChars('book_chars');

  const ReaderStatusBarItem(this.storageValue);

  @override
  final String storageValue;

  @override
  bool get pinnedRequired => false;

  @override
  bool get pinnedOnTouch => false;

  @override
  bool get isSingleInstance => true;

  @override
  ReaderStatusBarSlot get recoverySlot => ReaderStatusBarSlot.hidden;

  @override
  bool canMoveToSlot(
    ReaderStatusBarSlot target, {
    bool isTouchControls = false,
  }) => true;
}

/// 一个槽位只放单实例：同一项拖进另一个槽 = 移动（泛型模型允许跨槽副本，这里在
/// 归一化后置钩子里只保留第一次出现的那份）。
void _keepSingleInstance(
  Map<ReaderStatusBarSlot, List<ReaderStatusBarItem>> slots,
  Set<ReaderStatusBarItem> removed,
) {
  final Set<ReaderStatusBarItem> seen = <ReaderStatusBarItem>{};
  for (final ReaderStatusBarSlot slot in ReaderStatusBarSlot.values) {
    final List<ReaderStatusBarItem>? items = slots[slot];
    if (items == null) continue;
    items.retainWhere(seen.add);
  }
}

const ControlLayoutScheme<ReaderStatusBarSlot, ReaderStatusBarItem>
kReaderStatusBarScheme =
    ControlLayoutScheme<ReaderStatusBarSlot, ReaderStatusBarItem>(
      slots: ReaderStatusBarSlot.values,
      hiddenSlot: ReaderStatusBarSlot.hidden,
      items: ReaderStatusBarItem.values,
      postNormalize: _keepSingleInstance,
    );

/// 页眉 / 页脚布局（不可变）。默认全部不显示（维护者 2026-11-25 拍板「都加上，但是
/// 默认都不显示」）：老用户升级后页眉不出现、页脚只剩原来的读数胶囊，与升级前一致。
class ReaderStatusBarLayout {
  ReaderStatusBarLayout._(this.core);

  factory ReaderStatusBarLayout.fromCore(
    ControlLayout<ReaderStatusBarSlot, ReaderStatusBarItem> core,
  ) => ReaderStatusBarLayout._(core);

  /// 按「槽位 → 有序读数」构建（测试与 CLI 用）；没列出的读数一律不显示。
  factory ReaderStatusBarLayout.fromSlots(
    Map<ReaderStatusBarSlot, List<ReaderStatusBarItem>> slots,
  ) {
    final Set<ReaderStatusBarItem> placed = <ReaderStatusBarItem>{
      for (final List<ReaderStatusBarItem> items in slots.values) ...items,
    };
    return ReaderStatusBarLayout._(
      ControlLayout<ReaderStatusBarSlot, ReaderStatusBarItem>.fromSlots(
        kReaderStatusBarScheme,
        slots,
        removedItems: <ReaderStatusBarItem>{
          for (final ReaderStatusBarItem item in ReaderStatusBarItem.values)
            if (!placed.contains(item)) item,
        },
      ),
    );
  }

  /// 默认布局：页眉页脚都是空的。
  static final ReaderStatusBarLayout defaults = ReaderStatusBarLayout.fromSlots(
    const <ReaderStatusBarSlot, List<ReaderStatusBarItem>>{},
  );

  final ControlLayout<ReaderStatusBarSlot, ReaderStatusBarItem> core;

  List<ReaderStatusBarItem> itemsIn(ReaderStatusBarSlot slot) =>
      core.itemsIn(slot);

  /// 页眉是否有内容（没有 = 不画、不占排版高度）。
  bool get hasHeader =>
      ReaderStatusBarSlot.headerSlots.any((ReaderStatusBarSlot s) {
        return core.itemsIn(s).isNotEmpty;
      });

  /// 页脚三格是否有内容（不含读数胶囊）。
  bool get hasFooter =>
      ReaderStatusBarSlot.footerSlots.any((ReaderStatusBarSlot s) {
        return core.itemsIn(s).isNotEmpty;
      });

  /// 某项是否放在页眉或页脚里（决定要不要为它取数据，例如分页页码、电量）。
  bool shows(ReaderStatusBarItem item) => core.isOnPlayer(item);

  String encode() =>
      jsonEncode(<String, Object>{'version': 1, 'slots': core.encodeSlots()});

  static String? _lastRaw;
  static ReaderStatusBarLayout? _lastDecoded;

  /// 解码持久化 JSON；空串 / 坏载荷 / 一个读数都没放 → [defaults]。同一串重复解码
  /// 走一格缓存（阅读器每帧 build 都会读它）。
  static ReaderStatusBarLayout decode(String raw) {
    if (raw == _lastRaw && _lastDecoded != null) return _lastDecoded!;
    final ReaderStatusBarLayout decoded = _decodeUncached(raw);
    _lastRaw = raw;
    _lastDecoded = decoded;
    return decoded;
  }

  static ReaderStatusBarLayout _decodeUncached(String raw) {
    if (raw.trim().isEmpty) return defaults;
    try {
      final Object? json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) return defaults;
      final Object? slots = json['slots'];
      if (slots is! Map<String, dynamic>) return defaults;
      final Map<ReaderStatusBarSlot, List<ReaderStatusBarItem>> parsed =
          <ReaderStatusBarSlot, List<ReaderStatusBarItem>>{};
      for (final MapEntry<String, dynamic> entry in slots.entries) {
        final ReaderStatusBarSlot? slot = kReaderStatusBarScheme.parseSlot(
          entry.key,
        );
        final Object? list = entry.value;
        if (slot == null || slot == ReaderStatusBarSlot.hidden) continue;
        if (list is! List) continue;
        parsed[slot] = <ReaderStatusBarItem>[
          for (final Object? value in list)
            if (value is String) ?kReaderStatusBarScheme.parseItem(value),
        ];
      }
      return ReaderStatusBarLayout.fromSlots(parsed);
    } on FormatException {
      return defaults;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is ReaderStatusBarLayout && other.core == core;

  @override
  int get hashCode => core.hashCode;
}
