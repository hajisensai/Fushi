/// 本机查词结果与服务器（已配对 host）查词结果的合并（零 Flutter）。
///
/// 用户拍板（2026-11-09）：本机与服务器两份结果**合并成一份**，不再「远端给了就只用
/// 远端」——否则服务器一应答，用户本机装的词典（Jitendex、JPDB 频率…）就从弹窗里
/// 消失。合并规则见 [mergeDictionarySearchResults]。
library;

import 'dart:convert';
import 'dart:math';

import '../engine/fushidicts_models.dart' show FushiKanjiResult;
import '../models/dictionary_entry.dart';
import '../models/dictionary_search_result.dart';

/// 把本机结果 [local] 与服务器结果 [remote] 合并成一份。
///
/// * 一边为 null、或没有词条也没有汉字结果：返回另一边——本机那份原样（同一个对象），
///   服务器那份是打过 `remote` 标记的副本（见下）；两边都是 null 时返回 null。
/// * 去重按词典名：服务器结果里属于 [localDictionaryNames]（本机已装且启用的词典）的
///   释义 / 词条丢掉，留本机那份；服务器侧因此变空的词头整组丢掉。
/// * 分组 key = 表记 + 有效读音（空读音 = 表记，BUG-791）；空读音组若该表记在两边合起来
///   只有一个显式读音，就并进那个读音组（与 `soleExplicitReadings` 同一口径，BUG-2753）。
/// * 组内释义 / 词条按 [dictionaryOrder]（配置的本机 + 服务器混排 term 顺序）稳定排序，
///   不在名单里的排最后；排序前的初始顺序是服务器在前、本机在后。
/// * 组的频率 / 音调按词典名取并集：本机有的词典用本机的记录，服务器只补本机没有的
///   词典（本机频率词典因此能给服务器查出的同一词头补上频率）。两边都有的组，词条
///   extra 里的 `frequencies` / `pitches` 也改写成同一份并集（制卡字段读它）。
/// * 组序：匹配长度降序（与引擎主键一致），同长度稳定、服务器组在只有本机的组之前；
///   截到 [maximumTerms] 组。`headwordCount` = 结果里实际的组数（截断后，与
///   [DictionarySearchResult.headwordCount] 的定义一致，「加载更多」以它为基数）；
///   `truncated` = 任一边被截断或合并后超限；`bestLength` = 两边较大者。
/// * 汉字结果取并集，按 (词典, 字) 去重，本机在前。
/// * `remoteDictionaryStyles` 取服务器那份；给了 [localDictionaryStyles] 时与本机样式
///   合并（本机同名优先）——弹窗拿到非 null 的远端样式会**整表替换**本机样式，不合并
///   的话本机词典的样式会丢。合并表按两份输入的实例身份缓存，同输入返回同一实例
///   （弹窗靠 identical 判断要不要重发样式）。
/// * `scrollPosition` 恒 0。
/// * 弹窗 JSON 里来自服务器那份的释义对象带 `remote: true`（[kRemoteGlossaryKey]），
///   `popup.js` 据此在词典标题旁画一枚服务器小图标；本机释义不带这个键（浏览器扩展
///   与旧弹窗见不到它，渲染不变）。[DictionaryEntry] 不变。只有服务器一边有结果时
///   返回的是打过标记的副本（[markRemoteDictionarySearchResult]）。
///
/// 全函数不抛：任一边的 `popupJson` 解析不了（不是 JSON 数组 / 组不是对象 / 缺表记）
/// 时退化成**不去重的拼接**——词条两边直接相接、`popupJson` 置 null（弹窗按词条现场
/// 重建，`popupEntriesJsonOf`），因为坏掉的那份文档无法与另一份结构化地拼在一起。
/// 任一边 `popupJson` 本来就是 null 时，词条照常合并，合并结果的 `popupJson` 也是 null。
DictionarySearchResult? mergeDictionarySearchResults({
  required DictionarySearchResult? local,
  required DictionarySearchResult? remote,
  required List<String> dictionaryOrder,
  required Set<String> localDictionaryNames,
  required int maximumTerms,
  Map<String, String>? localDictionaryStyles,
}) {
  if (_isEmptyResult(local)) {
    return remote == null || _isEmptyResult(remote)
        ? remote ?? local
        : markRemoteDictionarySearchResult(remote);
  }
  if (_isEmptyResult(remote)) return local;
  final DictionarySearchResult l = local!;
  final DictionarySearchResult r = remote!;
  final Map<String, String>? styles = _mergedStyles(
    r.remoteDictionaryStyles,
    localDictionaryStyles,
  );

  final ({bool ok, List<Map<String, dynamic>>? groups}) remotePopup =
      _parsePopup(r.popupJson);
  final ({bool ok, List<Map<String, dynamic>>? groups}) localPopup =
      _parsePopup(l.popupJson);
  if (!remotePopup.ok || !localPopup.ok) {
    return _concatenated(l, r, styles);
  }
  final bool withPopup =
      remotePopup.groups != null && localPopup.groups != null;

  // ── 服务器侧去掉本机已有词典 ─────────────────────────────────────────
  final List<Map<String, dynamic>> remoteGroups = <Map<String, dynamic>>[
    for (final Map<String, dynamic> g
        in remotePopup.groups ?? const <Map<String, dynamic>>[])
      if (_withoutDictionaries(g, localDictionaryNames)
          case final Map<String, dynamic> kept)
        _withRemoteMarks(kept),
  ];
  final List<Map<String, dynamic>> localGroups =
      localPopup.groups ?? const <Map<String, dynamic>>[];
  final List<DictionaryEntry> remoteEntries = <DictionaryEntry>[
    for (final DictionaryEntry e in r.entries)
      if (!localDictionaryNames.contains(e.dictionaryName)) e,
  ];
  final List<DictionaryEntry> localEntries = l.entries;

  // ── 跨两边的唯一显式读音（BUG-2753 同口径）───────────────────────────
  final Map<String, Set<String>> readings = <String, Set<String>>{};
  void noteReading(String expression, String reading) {
    if (reading.isEmpty) return;
    readings.putIfAbsent(expression, () => <String>{}).add(reading);
  }

  for (final Map<String, dynamic> g in <Map<String, dynamic>>[
    ...remoteGroups,
    ...localGroups,
  ]) {
    noteReading(_str(g['expression']), _str(g['reading']));
  }
  for (final DictionaryEntry e in <DictionaryEntry>[
    ...remoteEntries,
    ...localEntries,
  ]) {
    noteReading(e.word, e.reading);
  }
  String resolveReading(String expression, String reading) {
    if (reading.isNotEmpty) return reading;
    final Set<String>? known = readings[expression];
    return known != null && known.length == 1 ? known.single : '';
  }

  // ── 建组：服务器先、本机后；每边先按 popup 顺序，再补只在词条里出现的组 ──
  final Map<String, _MergedGroup> byKey = <String, _MergedGroup>{};
  final List<_MergedGroup> groups = <_MergedGroup>[];
  _MergedGroup groupFor(String expression, String reading) {
    final String resolved = resolveReading(expression, reading);
    final String key =
        '$expression\n${resolved.isEmpty ? expression : resolved}';
    return byKey.putIfAbsent(key, () {
      final _MergedGroup group = _MergedGroup(
        expression: expression,
        reading: resolved,
        index: groups.length,
      );
      groups.add(group);
      return group;
    });
  }

  void addSide({
    required bool isRemote,
    required List<Map<String, dynamic>> popupGroups,
    required List<DictionaryEntry> entries,
  }) {
    for (final Map<String, dynamic> g in popupGroups) {
      final String expression = _str(g['expression']);
      final _MergedGroup group = groupFor(expression, _str(g['reading']));
      final String matched = g['matched'] is String
          ? g['matched'] as String
          : expression;
      group.noteMatched(matched.length);
      (isRemote ? group.remotePopups : group.localPopups).add(g);
    }
    for (final DictionaryEntry e in entries) {
      final _MergedGroup group = groupFor(e.word, e.reading);
      final Object? matched = _decodeExtra(e.extra)?['matched'];
      group.noteMatched(matched is String ? matched.length : e.word.length);
      (isRemote ? group.remoteEntries : group.localEntries).add(e);
    }
  }

  addSide(isRemote: true, popupGroups: remoteGroups, entries: remoteEntries);
  addSide(isRemote: false, popupGroups: localGroups, entries: localEntries);

  // List.sort 不稳定：同长度按建组次序（服务器组在前）。
  groups.sort((a, b) {
    final int byLength = b.matchedLength.compareTo(a.matchedLength);
    return byLength != 0 ? byLength : a.index.compareTo(b.index);
  });
  final int limit = max(0, maximumTerms);
  final bool overLimit = groups.length > limit;
  final List<_MergedGroup> kept = overLimit ? groups.sublist(0, limit) : groups;

  final Map<String, int> rank = <String, int>{
    for (int i = 0; i < dictionaryOrder.length; i++) dictionaryOrder[i]: i,
  };

  // ── 词条 ──────────────────────────────────────────────────────────────
  final List<DictionaryEntry> entries = <DictionaryEntry>[];
  for (final _MergedGroup group in kept) {
    final bool both = group.hasRemote && group.hasLocal;
    final _EntryMetadata? metadata = both ? _entryMetadataUnion(group) : null;
    final List<DictionaryEntry> ordered = _sortedByRank(
      <DictionaryEntry>[...group.remoteEntries, ...group.localEntries],
      rank,
      (DictionaryEntry e) => e.dictionaryName,
    );
    for (final DictionaryEntry e in ordered) {
      entries.add(_rewrittenEntry(e, group.reading, metadata));
    }
  }

  // ── 弹窗 JSON ─────────────────────────────────────────────────────────
  String? popupJson;
  if (withPopup) {
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    bool complete = true;
    for (final _MergedGroup group in kept) {
      final Map<String, dynamic>? merged = _mergedPopupGroup(group, rank);
      if (merged == null) {
        // 某一边的词条里有、popupJson 里却没有的组（来源自相矛盾）：拼不出完整
        // 文档，交给弹窗按合并后的词条现场重建。
        complete = false;
        break;
      }
      out.add(merged);
    }
    popupJson = complete ? _encodeOrNull(out) : null;
  }

  // ── 汉字 ──────────────────────────────────────────────────────────────
  final Set<String> seenKanji = <String>{};
  final List<FushiKanjiResult> kanji = <FushiKanjiResult>[
    for (final FushiKanjiResult k in <FushiKanjiResult>[
      ...l.kanjiResults,
      ...r.kanjiResults,
    ])
      if (seenKanji.add('${k.dictName}\u0000${k.character}')) k,
  ];

  final DictionarySearchResult result = DictionarySearchResult(
    searchTerm: l.searchTerm,
    entries: entries,
    bestLength: max(l.bestLength, r.bestLength),
    kanjiResults: kanji,
    truncated: l.truncated || r.truncated || overLimit,
    headwordCount: kept.length,
  );
  result.popupJson = popupJson;
  result.remoteDictionaryStyles = styles;
  return result;
}

/// 弹窗释义对象上「来自服务器」的标记键（值恒为 `true`；本机释义不带）。
const String kRemoteGlossaryKey = 'remote';

/// 只有服务器结果时的那份：弹窗 JSON 的每条释义打上 [kRemoteGlossaryKey]，其余字段
/// （词条、样式、截断、计数）原样。`popupJson` 为 null 或解析不了时原样返回 [remote]。
DictionarySearchResult markRemoteDictionarySearchResult(
  DictionarySearchResult remote,
) {
  final ({bool ok, List<Map<String, dynamic>>? groups}) parsed = _parsePopup(
    remote.popupJson,
  );
  final List<Map<String, dynamic>>? groups = parsed.groups;
  if (!parsed.ok || groups == null) return remote;
  final String? marked = _encodeOrNull(<Map<String, dynamic>>[
    for (final Map<String, dynamic> g in groups) _withRemoteMarks(g),
  ]);
  if (marked == null) return remote;
  final DictionarySearchResult copy = DictionarySearchResult(
    searchTerm: remote.searchTerm,
    entries: remote.entries,
    bestLength: remote.bestLength,
    scrollPosition: remote.scrollPosition,
    kanjiResults: remote.kanjiResults,
    truncated: remote.truncated,
    headwordCount: remote.headwordCount,
  );
  copy.popupJson = marked;
  copy.remoteDictionaryStyles = remote.remoteDictionaryStyles;
  return copy;
}

/// 组里每条释义对象加 `remote: true`（非对象项原样）。
Map<String, dynamic> _withRemoteMarks(Map<String, dynamic> group) {
  final List<Object?> glossaries = _list(group['glossaries']);
  if (glossaries.isEmpty) return group;
  return <String, dynamic>{
    ...group,
    'glossaries': <Object?>[
      for (final Object? g in glossaries)
        g is Map
            ? <String, dynamic>{
                ...g.cast<String, dynamic>(),
                kRemoteGlossaryKey: true,
              }
            : g,
    ],
  };
}

bool _isEmptyResult(DictionarySearchResult? result) =>
    result == null || (result.entries.isEmpty && result.kanjiResults.isEmpty);

String _str(Object? value) => value is String ? value : '';

/// popupJson → 组对象列表。null 输入 = 没有 popup（`ok` 真、`groups` null）；
/// 解析失败或结构不对 = `ok` 假。
({bool ok, List<Map<String, dynamic>>? groups}) _parsePopup(String? json) {
  if (json == null) return (ok: true, groups: null);
  final Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException {
    return (ok: false, groups: null);
  }
  if (decoded is! List) return (ok: false, groups: null);
  final List<Map<String, dynamic>> groups = <Map<String, dynamic>>[];
  for (final Object? item in decoded) {
    if (item is! Map<String, dynamic> || item['expression'] is! String) {
      return (ok: false, groups: null);
    }
    groups.add(item);
  }
  return (ok: true, groups: groups);
}

Map<String, dynamic>? _decodeExtra(String extra) {
  if (extra.isEmpty) return null;
  try {
    final Object? decoded = jsonDecode(extra);
    return decoded is Map<String, dynamic> ? decoded : null;
  } on FormatException {
    return null;
  }
}

String? _encodeOrNull(Object value) {
  try {
    return jsonEncode(value);
  } on JsonUnsupportedObjectError {
    return null;
  }
}

List<Object?> _list(Object? value) => value is List ? value : const <Object?>[];

/// 服务器组去掉 [names] 里词典的释义；一条不剩时返回 null（整组丢掉）。
Map<String, dynamic>? _withoutDictionaries(
  Map<String, dynamic> group,
  Set<String> names,
) {
  final List<Object?> glossaries = _list(group['glossaries']);
  if (names.isEmpty) return glossaries.isEmpty ? null : group;
  final List<Object?> kept = <Object?>[
    for (final Object? g in glossaries)
      if (!(g is Map && names.contains(g['dictionary']))) g,
  ];
  if (kept.isEmpty) return null;
  if (kept.length == glossaries.length) return group;
  return <String, dynamic>{...group, 'glossaries': kept};
}

/// 合并后的一个弹窗组；该组任何一边都没有 popup 对象时返回 null。
Map<String, dynamic>? _mergedPopupGroup(
  _MergedGroup group,
  Map<String, int> rank,
) {
  final List<Map<String, dynamic>> popups = <Map<String, dynamic>>[
    ...group.remotePopups,
    ...group.localPopups,
  ];
  if (popups.isEmpty) return null;
  if (popups.length == 1) {
    final Map<String, dynamic> only = popups.single;
    return _str(only['reading']) == group.reading
        ? only
        : <String, dynamic>{...only, 'reading': group.reading};
  }
  // 表头（matched / 变形链 / rules）取匹配最长的那份，同长服务器优先。
  Map<String, dynamic> head = popups.first;
  int headLength = -1;
  for (final Map<String, dynamic> p in popups) {
    final Object? matched = p['matched'];
    final int length = matched is String ? matched.length : 0;
    if (length > headLength) {
      head = p;
      headLength = length;
    }
  }
  final List<Object?> glossaries = _sortedByRank(
    <Object?>[
      for (final Map<String, dynamic> p in popups) ..._list(p['glossaries']),
    ],
    rank,
    (Object? g) => g is Map ? _str(g['dictionary']) : '',
  );
  return <String, dynamic>{
    ...head,
    'reading': group.reading,
    'glossaries': glossaries,
    'frequencies': _unionByDictionary(
      local: <Object?>[
        for (final Map<String, dynamic> p in group.localPopups)
          ..._list(p['frequencies']),
      ],
      remote: <Object?>[
        for (final Map<String, dynamic> p in group.remotePopups)
          ..._list(p['frequencies']),
      ],
      dictionaryKey: 'dictionary',
    ),
    'pitches': _unionByDictionary(
      local: <Object?>[
        for (final Map<String, dynamic> p in group.localPopups)
          ..._list(p['pitches']),
      ],
      remote: <Object?>[
        for (final Map<String, dynamic> p in group.remotePopups)
          ..._list(p['pitches']),
      ],
      dictionaryKey: 'dictionary',
    ),
  };
}

/// 频率 / 音调记录按词典名并集：本机记录全留（逐字去重），服务器只补本机没有的
/// 词典。
List<Object?> _unionByDictionary({
  required List<Object?> local,
  required List<Object?> remote,
  required String dictionaryKey,
}) {
  final Set<String> localDictionaries = <String>{
    for (final Object? item in local)
      if (item is Map) _str(item[dictionaryKey]),
  };
  final Set<String> seen = <String>{};
  final List<Object?> out = <Object?>[];
  void add(Object? item) {
    final String? fingerprint = _encodeOrNull(item ?? '');
    if (fingerprint != null && seen.add(fingerprint)) out.add(item);
  }

  local.forEach(add);
  for (final Object? item in remote) {
    if (item is Map && localDictionaries.contains(_str(item[dictionaryKey]))) {
      continue;
    }
    add(item);
  }
  return out;
}

typedef _EntryMetadata = ({List<Object?> frequencies, List<Object?> pitches});

/// 两边都有的组：词条 extra 里频率 / 音调（`dictName` 键）的并集。
_EntryMetadata _entryMetadataUnion(_MergedGroup group) {
  List<Object?> collect(List<DictionaryEntry> entries, String key) => <Object?>[
    for (final DictionaryEntry e in entries)
      ..._list(_decodeExtra(e.extra)?[key]),
  ];
  return (
    frequencies: _unionByDictionary(
      local: collect(group.localEntries, 'frequencies'),
      remote: collect(group.remoteEntries, 'frequencies'),
      dictionaryKey: 'dictName',
    ),
    pitches: _unionByDictionary(
      local: collect(group.localEntries, 'pitches'),
      remote: collect(group.remoteEntries, 'pitches'),
      dictionaryKey: 'dictName',
    ),
  );
}

/// 词条按组改写：空读音补成组读音；[metadata] 非 null 时 extra 的频率 / 音调换成
/// 并集。什么都不变时返回原对象。
DictionaryEntry _rewrittenEntry(
  DictionaryEntry entry,
  String reading,
  _EntryMetadata? metadata,
) {
  String extra = entry.extra;
  if (metadata != null) {
    final Map<String, dynamic>? decoded = _decodeExtra(entry.extra);
    if (decoded != null) {
      if (decoded.containsKey('frequencies') ||
          metadata.frequencies.isNotEmpty) {
        decoded['frequencies'] = metadata.frequencies;
      }
      if (decoded.containsKey('pitches') || metadata.pitches.isNotEmpty) {
        decoded['pitches'] = metadata.pitches;
      }
      extra = _encodeOrNull(decoded) ?? entry.extra;
    }
  }
  final String newReading = entry.reading.isEmpty ? reading : entry.reading;
  if (extra == entry.extra && newReading == entry.reading) return entry;
  return DictionaryEntry(
    id: entry.id,
    dictionaryName: entry.dictionaryName,
    word: entry.word,
    reading: newReading,
    meaning: entry.meaning,
    extra: extra,
    popularity: entry.popularity,
  );
}

/// 按 [rank] 稳定排序；不在名单里的排最后、保持原相对顺序。
List<T> _sortedByRank<T>(
  List<T> items,
  Map<String, int> rank,
  String Function(T item) nameOf,
) {
  if (items.length < 2 || rank.isEmpty) return items;
  final int unknown = rank.length;
  final List<({T item, int rank, int index})> indexed =
      <({T item, int rank, int index})>[
        for (int i = 0; i < items.length; i++)
          (item: items[i], rank: rank[nameOf(items[i])] ?? unknown, index: i),
      ];
  indexed.sort((a, b) {
    final int byRank = a.rank.compareTo(b.rank);
    return byRank != 0 ? byRank : a.index.compareTo(b.index);
  });
  return <T>[for (final e in indexed) e.item];
}

/// popupJson 坏掉时的退化：不去重地拼接（见 [mergeDictionarySearchResults]）。
DictionarySearchResult _concatenated(
  DictionarySearchResult local,
  DictionarySearchResult remote,
  Map<String, String>? styles,
) {
  final DictionarySearchResult result = DictionarySearchResult(
    searchTerm: local.searchTerm,
    entries: <DictionaryEntry>[...remote.entries, ...local.entries],
    bestLength: max(local.bestLength, remote.bestLength),
    kanjiResults: <FushiKanjiResult>[
      ...local.kanjiResults,
      ...remote.kanjiResults,
    ],
    truncated: local.truncated || remote.truncated,
    headwordCount: local.headwordCount + remote.headwordCount,
  );
  result.remoteDictionaryStyles = styles;
  return result;
}

/// 服务器样式 ∪ 本机样式（本机同名优先），按两份输入的实例身份缓存。
final Expando<({Map<String, String> local, Map<String, String> merged})>
_stylesUnionCache =
    Expando<({Map<String, String> local, Map<String, String> merged})>(
      'mergedDictionaryStyles',
    );

Map<String, String>? _mergedStyles(
  Map<String, String>? remote,
  Map<String, String>? local,
) {
  if (remote == null || local == null || local.isEmpty) return remote;
  final ({Map<String, String> local, Map<String, String> merged})? cached =
      _stylesUnionCache[remote];
  if (cached != null && identical(cached.local, local)) return cached.merged;
  final Map<String, String> merged = Map<String, String>.unmodifiable(
    <String, String>{...remote, ...local},
  );
  _stylesUnionCache[remote] = (local: local, merged: merged);
  return merged;
}

class _MergedGroup {
  _MergedGroup({
    required this.expression,
    required this.reading,
    required this.index,
  });

  final String expression;

  /// 组读音（补全后；空 = 无显式读音）。
  final String reading;

  /// 建组次序（服务器组在前），排序的稳定键。
  final int index;
  int matchedLength = 0;
  final List<Map<String, dynamic>> remotePopups = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> localPopups = <Map<String, dynamic>>[];
  final List<DictionaryEntry> remoteEntries = <DictionaryEntry>[];
  final List<DictionaryEntry> localEntries = <DictionaryEntry>[];

  bool get hasRemote => remotePopups.isNotEmpty || remoteEntries.isNotEmpty;
  bool get hasLocal => localPopups.isNotEmpty || localEntries.isNotEmpty;

  void noteMatched(int length) {
    if (length > matchedLength) matchedLength = length;
  }
}
