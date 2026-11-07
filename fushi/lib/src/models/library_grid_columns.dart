import 'dart:convert';

import 'package:fushi/src/utils/misc/platform_utils.dart' show WindowSizeClass;

/// 库页「每行数量」（2026-11-07 用户拍板）。
///
/// 起因：v3.3.0 起 360dp 手机在 80% 界面缩放下书架从 3 列掉成 2 列（BUG-4219），
/// 不想动整体缩放的用户只能把字一起缩小。改成每个库页可以直接指定每行几个，
/// 默认「自动」（按宽度算，与改造前同一算法）。
///
/// 值按 **库 × 窗口尺寸档** 分别记：手机竖屏挑的 3 列放到平板 / 桌面上封面会
/// 大得离谱，所以 compact / medium / expanded 各存一格。整张表是一个 JSON
/// 偏好 [kLibraryGridColumnsPrefKey]，设备本地（不随备份 / 同步 / Profile 走）：
/// 合适的列数取决于这台设备的屏幕。

/// 偏好键（JSON：`"<domain>.<sizeClass>" → 列数`，缺省 = 自动）。
const String kLibraryGridColumnsPrefKey = 'library_grid_columns';

/// 哪个库页。书架与漫画库同一个页面类但分别记。
enum LibraryGridDomain { books, manga, video, games }

/// [sizeClass] 下可选的固定列数（不含「自动」）。手机竖屏最多 4 列（用户拍板）；
/// 宽档的上限给到足够覆盖常见桌面窗口的自动列数。
List<int> libraryGridColumnChoices(WindowSizeClass sizeClass) =>
    switch (sizeClass) {
      WindowSizeClass.compact => const <int>[2, 3, 4],
      WindowSizeClass.medium => const <int>[3, 4, 5, 6],
      WindowSizeClass.expanded => const <int>[4, 5, 6, 7, 8, 9, 10, 12],
    };

/// 表里的格名。
String libraryGridColumnsSlot(
  LibraryGridDomain domain,
  WindowSizeClass sizeClass,
) => '${domain.name}.${sizeClass.name}';

/// 解码偏好值；坏 JSON / 非整数项一律丢弃（= 自动）。
Map<String, int> decodeLibraryGridColumns(String? raw) {
  if (raw == null || raw.isEmpty) return const <String, int>{};
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return const <String, int>{};
  }
  if (decoded is! Map) return const <String, int>{};
  return <String, int>{
    for (final MapEntry<dynamic, dynamic> e in decoded.entries)
      if (e.key is String && e.value is int) e.key as String: e.value as int,
  };
}

String encodeLibraryGridColumns(Map<String, int> table) => jsonEncode(table);

/// 表里 [domain] × [sizeClass] 的固定列数；没设、或存的值不在该档可选范围内
/// （手改过 / 选项表收窄过）时返回 null = 自动。
int? libraryGridFixedColumnsFrom(
  Map<String, int> table,
  LibraryGridDomain domain,
  WindowSizeClass sizeClass,
) {
  final int? value = table[libraryGridColumnsSlot(domain, sizeClass)];
  if (value == null) return null;
  return libraryGridColumnChoices(sizeClass).contains(value) ? value : null;
}

/// 写一格：[columns] 为 null 时删掉该格（= 自动）。返回新表，不改入参。
Map<String, int> withLibraryGridColumns(
  Map<String, int> table,
  LibraryGridDomain domain,
  WindowSizeClass sizeClass,
  int? columns,
) {
  final Map<String, int> next = Map<String, int>.of(table);
  final String slot = libraryGridColumnsSlot(domain, sizeClass);
  if (columns == null) {
    next.remove(slot);
  } else {
    next[slot] = columns;
  }
  return next;
}
