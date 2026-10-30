import 'dart:convert';

/// 歌词来源列表中的一个插件项。LRCLIB 不在其中（结构上固定最前）。
class LyricsProviderEntry {
  const LyricsProviderEntry({required this.id, required this.enabled});

  final String id;
  final bool enabled;

  LyricsProviderEntry copyWith({bool? enabled}) =>
      LyricsProviderEntry(id: id, enabled: enabled ?? this.enabled);

  Map<String, Object> toJson() => <String, Object>{
    'id': id,
    'enabled': enabled,
  };

  @override
  bool operator ==(Object other) =>
      other is LyricsProviderEntry &&
      other.id == id &&
      other.enabled == enabled;

  @override
  int get hashCode => Object.hash(id, enabled);

  @override
  String toString() => 'LyricsProviderEntry($id, $enabled)';
}

/// 解析偏好 JSON；坏 JSON / 非数组 / 坏项一律容忍（丢弃），重复 id 保留首个。
List<LyricsProviderEntry> parseLyricsProviders(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const <LyricsProviderEntry>[];
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return const <LyricsProviderEntry>[];
  }
  if (decoded is! List<Object?>) return const <LyricsProviderEntry>[];
  final List<LyricsProviderEntry> out = <LyricsProviderEntry>[];
  final Set<String> seen = <String>{};
  for (final Object? item in decoded) {
    if (item is! Map<Object?, Object?>) continue;
    final Object? id = item['id'];
    if (id is! String || id.isEmpty || !seen.add(id)) continue;
    out.add(LyricsProviderEntry(id: id, enabled: item['enabled'] != false));
  }
  return out;
}

String serializeLyricsProviders(List<LyricsProviderEntry> entries) =>
    jsonEncode(entries.map((LyricsProviderEntry e) => e.toJson()).toList());

/// 与已装（usable 且声明 lyricsSearch）的插件 id 求并：丢弃未装项，
/// 已装但不在列表的追加到末尾并默认启用。`installedIds` 的顺序决定新项顺序。
List<LyricsProviderEntry> mergeLyricsProviders(
  List<LyricsProviderEntry> stored,
  Iterable<String> installedIds,
) {
  final List<String> installed = installedIds.toList();
  final Set<String> installedSet = installed.toSet();
  final List<LyricsProviderEntry> out = <LyricsProviderEntry>[
    for (final LyricsProviderEntry e in stored)
      if (installedSet.contains(e.id)) e,
  ];
  final Set<String> have = out.map((LyricsProviderEntry e) => e.id).toSet();
  for (final String id in installed) {
    if (have.add(id)) out.add(LyricsProviderEntry(id: id, enabled: true));
  }
  return out;
}

/// 把 [from] 处的项挪到 [to]（均为列表内下标，`to` 为移动后的最终位置）。越界返回原列表。
List<LyricsProviderEntry> reorderLyricsProviders(
  List<LyricsProviderEntry> entries,
  int from,
  int to,
) {
  if (from < 0 || from >= entries.length || to < 0 || to >= entries.length) {
    return entries;
  }
  final List<LyricsProviderEntry> out = List<LyricsProviderEntry>.of(entries);
  out.insert(to, out.removeAt(from));
  return out;
}

List<LyricsProviderEntry> toggleLyricsProvider(
  List<LyricsProviderEntry> entries,
  String id,
  bool enabled,
) => <LyricsProviderEntry>[
  for (final LyricsProviderEntry e in entries)
    e.id == id ? e.copyWith(enabled: enabled) : e,
];

/// 查询顺序：已启用的插件 id（LRCLIB 由调用方固定放最前）。
List<String> enabledLyricsProviderIds(List<LyricsProviderEntry> entries) =>
    <String>[
      for (final LyricsProviderEntry e in entries)
        if (e.enabled) e.id,
    ];
