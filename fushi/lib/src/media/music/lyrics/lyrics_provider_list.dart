import 'dart:convert';

import 'package:fushi_engine/media/music/lyrics/music_lyrics_sources.dart';

/// 有序列表里的一项（id + 是否启用）。歌词来源列表（[mergeLyricsSourceList]）里是
/// LRCLIB（[MusicLyricsSource.lrclib]）或一个歌词插件 id；「来源」页的在线音源顺序也复用它。
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

/// 歌词来源列表（`music_lyrics_providers` 偏好）：LRCLIB 与已装歌词插件同在一份有序列表里，
/// 数组顺序即查询顺序，LRCLIB 用 [MusicLyricsSource.lrclib] 作 id（插件 id 不含冒号，不会撞）。
///
/// 旧偏好只存插件、LRCLIB 由宿主固定在最前：读到没有 LRCLIB 项的数组时把它补在最前并启用，
/// 存量用户的查询顺序不变；之后用户怎么排、停不停用都照存。插件部分同 [mergeLyricsProviders]
/// （丢弃未装、新装追加末尾默认启用）。
List<LyricsProviderEntry> mergeLyricsSourceList(
  List<LyricsProviderEntry> stored,
  Iterable<String> installedPluginIds,
) {
  const String lrclib = MusicLyricsSource.lrclib;
  final bool hasLrclib = stored.any((LyricsProviderEntry e) => e.id == lrclib);
  return mergeLyricsProviders(
    <LyricsProviderEntry>[
      if (!hasLrclib) const LyricsProviderEntry(id: lrclib, enabled: true),
      ...stored,
    ],
    <String>[
      lrclib,
      for (final String id in installedPluginIds)
        if (id != lrclib) id,
    ],
  );
}

/// 查询顺序：已启用项的 id，按列表顺序。
List<String> enabledLyricsProviderIds(List<LyricsProviderEntry> entries) =>
    <String>[
      for (final LyricsProviderEntry e in entries)
        if (e.enabled) e.id,
    ];
