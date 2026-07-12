/// TODO-616 B 排序的渲染层辅助（纯函数，widget-free 单测）。
///
/// UI v2 Phase E：旧 `groupAndSortShelfEntries`（按 [ShelfEntries].seriesId 折叠）
/// 已删——分组唯一真相源是 `collection_grouping.dart` 的 `groupByCollections`
/// （MediaCollections 引用表）。本文件只保留选择键解码与合集默认名推导。

/// 一条书架 / 视频选择键解码后的稳定身份 `(mediaType, entryKey)`。
/// 直接喂 [HibikiDatabase.addToCollection] / [HibikiDatabase.upsertShelfOrder]。
class ShelfEntryRef {
  const ShelfEntryRef({required this.mediaType, required this.entryKey});

  /// 媒体种类：'epub' | 'srt' | 'video'。
  final String mediaType;

  /// 稳定身份：本地 = bookKey / srtUid / videoBookUid。
  final String entryKey;

  @override
  bool operator ==(Object other) =>
      other is ShelfEntryRef &&
      other.mediaType == mediaType &&
      other.entryKey == entryKey;

  @override
  int get hashCode => Object.hash(mediaType, entryKey);

  @override
  String toString() => 'ShelfEntryRef($mediaType, $entryKey)';
}

/// 选择键所属的来源表面：书架（SRT/EPUB 双类前缀）vs 视频库（裸 bookUid）。
enum ShelfSelectionSurface { books, video }

/// TODO-616 A1：把书架 / 视频库批量选择集里的「选择键」解码成 ShelfEntries 的稳定
/// 身份 `(mediaType, entryKey)`，供「组合成系列」逐条 `setSeriesForEntry` 用。
///
/// 两套选择键编码不对称（计划 §⑦ 风险 6），故按 [surface] 分支：
/// - [ShelfSelectionSurface.books]：书架 `_selectedKeys`——
///   - SRT 键 = `'srt_' + srtUid` → `('srt', srtUid)`；
///   - EPUB 键 = `'hoshi://book/<bookKey>'`（MediaItem.mediaIdentifier）→
///     `('epub', bookKey)`（内联解析 `hoshi://book/` URI，与
///     `ReaderHibikiSource.parseBookKey` 同语义，但保持本函数 widget/DB-free 可单测）。
///   - 无法识别（非 srt_ 前缀且非 hoshi://book/）→ null（调用方跳过该条）。
/// - [ShelfSelectionSurface.video]：视频库 `_selectedUids`——裸 bookUid →
///   `('video', selectionKey)`（视频选择集本就直接是 bookUid，无前缀）。
ShelfEntryRef? shelfSelectionToEntry(
  String selectionKey,
  ShelfSelectionSurface surface,
) {
  switch (surface) {
    case ShelfSelectionSurface.video:
      if (selectionKey.isEmpty) return null;
      return ShelfEntryRef(mediaType: 'video', entryKey: selectionKey);
    case ShelfSelectionSurface.books:
      if (selectionKey.startsWith('srt_')) {
        final String uid = selectionKey.substring(4);
        if (uid.isEmpty) return null;
        return ShelfEntryRef(mediaType: 'srt', entryKey: uid);
      }
      final String? bookKey = _parseHoshiBookKey(selectionKey);
      if (bookKey == null || bookKey.isEmpty) return null;
      return ShelfEntryRef(mediaType: 'epub', entryKey: bookKey);
  }
}

/// TODO-1125 B：从一批成员标题推导一个合集默认名（批量「组合成系列」预填用）。
///
/// 心智模型：用户框选「某系列 第1巻 / 第2巻 / …」批量组合时，剥掉每个标题尾部的
/// 卷号 / 集数 / 上下 / 罗马数字 / `#N` 标记，取剥离后各标题的最长公共前缀作为默认名。
/// 无公共前缀 / 推导为空 → 返回 [fallback]（现成的 `t.series_default_name`「新系列」）。
///
/// 纯函数（widget/DB-free），便于单测。不做任何随机 / 时间依赖。
String deriveSeriesDefaultName(
  List<String> memberTitles, {
  required String fallback,
}) {
  final List<String> cleaned = <String>[
    for (final String raw in memberTitles)
      if (_stripVolumeMarker(raw) case final String s when s.isNotEmpty) s,
  ];
  if (cleaned.isEmpty) return fallback;
  if (cleaned.length == 1) return cleaned.first;

  final String common = _longestCommonPrefix(cleaned).trim();
  // 去掉公共前缀尾部残留的分隔符 / 悬挂标记，避免「系列名 第」这种半截。
  final String trimmed = common
      .replaceAll(RegExp(r'[\s\-–—_·:：、。.]+$'), '')
      .replaceAll(RegExp(r'第$'), '')
      .trim();
  return trimmed.isEmpty ? fallback : trimmed;
}

/// 剥掉标题尾部的卷号 / 集数 / 上下 / 罗马数字 / `#N` 等卷集标记 + 收尾分隔符。
/// 只剥「尾部」标记（前缀主干是真正的系列名），trim 后返回；无标记则原样 trim。
String _stripVolumeMarker(String title) {
  String s = title.trim();
  // 去尾部成对括号块（画质 / 字幕组 tag），可能夹在卷号后：`名 (上)` `名 [完]`。
  s = s.replaceAll(RegExp(r'[\[(（【][^\])）】]*[\])）】]\s*$'), '').trimRight();
  // 反复剥尾部标记，直到不再匹配（应对「名 第1巻 上」这类叠加标记）。
  bool changed = true;
  while (changed) {
    final String before = s;
    for (final RegExp re in _volumeMarkerTail) {
      s = s.replaceAll(re, '');
    }
    s = s.replaceAll(RegExp(r'[\s\-–—_·:：、。.#]+$'), '').trimRight();
    changed = s != before;
  }
  return s.trim();
}

/// 尾部卷集标记正则（都锚定 `$`，只吃结尾）：
/// `第12巻/卷/話/话/集/章` / `vol.3` / `上|下|前|後|完` / 罗马数字 / `#12` / 纯尾数。
final List<RegExp> _volumeMarkerTail = <RegExp>[
  RegExp(r'第\s*\d{1,4}\s*[巻卷話话集章篇部]\s*$'),
  RegExp(r'[\s\-_]*[vV][oO][lL]\.?\s*\d{1,4}\s*$'),
  RegExp(r'[\s\-_]*[#＃]\s*\d{1,4}\s*$'),
  RegExp(r'[\s（(【\[]*[上下前後后完]\s*[)）\]】]*\s*$'),
  RegExp(r'\s+[ivxIVX]{1,5}\s*$'),
  RegExp(r'[\s\-_]+\d{1,4}\s*$'),
];

/// 一批字符串的最长公共前缀（逐字符，Unicode code unit 级即可满足 CJK / ASCII）。
String _longestCommonPrefix(List<String> items) {
  if (items.isEmpty) return '';
  String prefix = items.first;
  for (final String s in items.skip(1)) {
    int i = 0;
    final int max = prefix.length < s.length ? prefix.length : s.length;
    while (i < max && prefix.codeUnitAt(i) == s.codeUnitAt(i)) {
      i++;
    }
    prefix = prefix.substring(0, i);
    if (prefix.isEmpty) break;
  }
  return prefix;
}

/// 内联解析 `hoshi://book/<bookKey>`（与 ReaderHibikiSource.parseBookKey 同语义，
/// 复制到本 widget-free 文件以便纯函数单测，不引依赖）。
///
/// BUG-658 / TODO-1344：取前缀之后的 RAW 余串，绝不 percent-decode。sanitizeTtu
/// Filename 会把标题里的 `/?<>\\:|%"*` 编成 `%XX`，因此合法 bookKey 本身可能含字面
/// `%3F`/`%3C` 等（如 `業物語 %3C物語%3E (...)`、`...Sheep%3F`）。旧实现用
/// `Uri.pathSegments` 解析会把这些反解码（`%3F`→`?`），得到的键与存库主键不符，
/// 导致这类书排序错位、且与 ReaderHibikiSource.parseBookKey 的行为分叉。裸切片对含
/// `%` 与不含 `%` 的键都无损，且与旧结果对不含 `%` 的键完全一致。
String? _parseHoshiBookKey(String identifier) {
  const String prefix = 'hoshi://book/';
  if (!identifier.startsWith(prefix)) return null;
  final String bookKey = identifier.substring(prefix.length);
  if (bookKey.isEmpty) return null;
  return bookKey;
}
