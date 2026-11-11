/// 整张发行（release）级的 MusicBrainz 结论：光盘专辑按曲目表对号（音乐方案 §9.2）。
///
/// 两条入口共用同一套曲目表模型：
///
///   * **DVD / BD 章节导入为曲目**：按盘名搜 DVD-Video / Blu-ray 发行，拿每个候选的曲目表
///     与章节时长逐首比对（[matchMusicDiscChapters]）——DVD / BD 的章节本身没有名字，
///     演唱会盘在 MusicBrainz 里常有完整 tracklist，曲数 + 时长对得上就是同一张；
///   * **音频 CD**：MusicBrainz Disc ID（`native/fushi_music` 算）直接查到发行，曲目表按轨号
///     一一对应。
///
/// 纯 Dart、不碰 Flutter。
library;

import 'package:fushi_engine/media/music/metadata/music_metadata_models.dart';

/// 发行里的一首。
class MusicReleaseTrack {
  const MusicReleaseTrack({
    required this.position,
    required this.title,
    this.durationMs,
    this.mbRecordingId,
    this.artistCredit,
  });

  final int position;
  final String title;
  final int? durationMs;
  final String? mbRecordingId;

  /// 这一首的艺人（与整张发行不同才有意义，调用方自己比）。
  final String? artistCredit;
}

/// 发行里的一张盘（medium）。
class MusicReleaseMedium {
  const MusicReleaseMedium({
    required this.position,
    required this.tracks,
    this.format,
    this.title,
  });

  final int position;

  /// `CD` / `DVD-Video` / `Blu-ray` …（MusicBrainz 的 medium format 原文）。
  final String? format;
  final String? title;
  final List<MusicReleaseTrack> tracks;
}

/// 一张发行的曲目表。
class MusicReleaseTracklist {
  const MusicReleaseTracklist({
    required this.mbReleaseId,
    required this.title,
    required this.media,
    this.artistCredit,
    this.releaseGroupId,
    this.date,
    this.country,
    this.barcode,
    this.catalogNumbers = const <String>[],
  });

  final String mbReleaseId;
  final String title;
  final String? artistCredit;
  final String? releaseGroupId;
  final String? date;
  final String? country;
  final String? barcode;
  final List<String> catalogNumbers;
  final List<MusicReleaseMedium> media;

  /// 各盘 format 去重后的展示串（`DVD-Video`、`CD + DVD-Video`）。
  String get formatSummary {
    final List<String> out = <String>[];
    for (final MusicReleaseMedium m in media) {
      final String? f = m.format;
      if (f != null && !out.contains(f)) out.add(f);
    }
    return out.join(' + ');
  }

  int get trackCount =>
      media.fold<int>(0, (int s, MusicReleaseMedium m) => s + m.tracks.length);
}

/// 视频盘在 MusicBrainz 里的 medium format（DVD-Video / Blu-ray 及其变体）。
bool isMusicBrainzVideoDiscFormat(String? format) {
  final String f = (format ?? '').toLowerCase();
  return f.contains('dvd') || f.contains('blu-ray') || f.contains('bd');
}

String? _str(Object? v) {
  if (v is! String) return null;
  final String t = v.trim();
  return t.isEmpty ? null : t;
}

int? _int(Object? v) {
  if (v is int) return v;
  if (v is num) return v.round();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

List<Map<String, Object?>> _maps(Object? v) => <Map<String, Object?>>[
  if (v is List<Object?>)
    for (final Object? e in v)
      if (e is Map<String, Object?>) e,
];

String? _creditText(
  Object? credit,
  List<MusicArtistCredit> Function(Object?) parse,
) {
  final String text = musicArtistCreditText(parse(credit));
  return text.isEmpty ? null : text;
}

/// MusicBrainz release JSON（详情 `media[].tracks[]` 或搜索结果 `media[].track[]`）→
/// 曲目表。[parseCredit] 由 provider 传入（与录音解析共用一份署名解析）。
MusicReleaseTracklist? parseMusicBrainzReleaseTracklist(
  Map<String, Object?> r, {
  required List<MusicArtistCredit> Function(Object?) parseCredit,
}) {
  final String? id = _str(r['id']);
  if (id == null) return null;
  final Map<String, Object?>? group = r['release-group'] is Map<String, Object?>
      ? r['release-group']! as Map<String, Object?>
      : null;
  final List<MusicReleaseMedium> media = <MusicReleaseMedium>[];
  for (final Map<String, Object?> m in _maps(r['media'])) {
    final List<MusicReleaseTrack> tracks = <MusicReleaseTrack>[];
    final List<Map<String, Object?>> raw = <Map<String, Object?>>[
      ..._maps(m['tracks']),
      ..._maps(m['track']),
    ];
    for (int i = 0; i < raw.length; i++) {
      final Map<String, Object?> t = raw[i];
      final Map<String, Object?>? rec = t['recording'] is Map<String, Object?>
          ? t['recording']! as Map<String, Object?>
          : null;
      tracks.add(
        MusicReleaseTrack(
          position: _int(t['position']) ?? _int(t['number']) ?? i + 1,
          title: _str(t['title']) ?? _str(rec?['title']) ?? '',
          durationMs: _int(t['length']) ?? _int(rec?['length']),
          mbRecordingId: _str(rec?['id']),
          artistCredit: _creditText(
            t['artist-credit'] ?? rec?['artist-credit'],
            parseCredit,
          ),
        ),
      );
    }
    media.add(
      MusicReleaseMedium(
        position: _int(m['position']) ?? media.length + 1,
        format: _str(m['format']),
        title: _str(m['title']),
        tracks: tracks,
      ),
    );
  }
  return MusicReleaseTracklist(
    mbReleaseId: id,
    title: _str(r['title']) ?? '',
    artistCredit: _creditText(r['artist-credit'], parseCredit),
    releaseGroupId: _str(group?['id']),
    date: _str(r['date']),
    country: _str(r['country']),
    barcode: _str(r['barcode']),
    catalogNumbers: <String>[
      for (final Map<String, Object?> li in _maps(r['label-info']))
        if (_str(li['catalog-number']) case final String c) c,
    ],
    media: media,
  );
}

/// 搜索 DVD / BD 发行的 Lucene 查询串（纯函数，测试钉死）。
String buildMusicBrainzDiscReleaseQuery(String title, {String? artist}) {
  String phrase(String v) =>
      '"${v.trim().replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
  final List<String> parts = <String>['release:${phrase(title)}'];
  final String? a = artist?.trim();
  if (a != null && a.isNotEmpty) parts.add('artist:${phrase(a)}');
  parts.add('(format:"DVD-Video" OR format:"Blu-ray" OR format:"DVD")');
  return parts.join(' AND ');
}

/// 一次「章节 ↔ 发行曲目」对号的结论。
class MusicDiscReleaseMatch {
  const MusicDiscReleaseMatch({
    required this.release,
    required this.medium,
    required this.tracks,
    required this.meanErrorMs,
    required this.comparedCount,
  });

  final MusicReleaseTracklist release;
  final MusicReleaseMedium medium;

  /// 与章节一一对应（下标 = 章节序）。
  final List<MusicReleaseTrack> tracks;

  /// 有时长的那些曲目里，章节时长与发行曲目时长之差的平均绝对值（毫秒）；没有可比的时长
  /// 时为 null（只靠曲数对上）。
  final int? meanErrorMs;
  final int comparedCount;

  /// 足够可信、可以直接套用：曲数一致，且至少一半曲目有时长、平均误差 ≤ 3 s。只靠曲数
  /// 对上的结论只给用户当候选，不自动套。
  bool get isConfident =>
      meanErrorMs != null &&
      meanErrorMs! <= kMusicDiscMatchMaxMeanErrorMs &&
      comparedCount * 2 >= tracks.length;
}

/// 自动套用的平均时长误差上限：演唱会盘的章节点与 MusicBrainz 曲目时长通常差在 1–2 s
/// 内（MC / 掌声归属不同），超过 3 s 多半是另一个版本。
const int kMusicDiscMatchMaxMeanErrorMs = 3000;

/// 章节时长（毫秒，按序）对一张发行的曲目表：挑曲数相同、平均误差最小的那张 medium。
/// 没有曲数相同的 medium 返回 null。[preferVideo] 时只看视频盘 medium（DVD / BD），找不到
/// 再看全部（有的发行把视频盘录成 `Other`）。
MusicDiscReleaseMatch? matchMusicDiscChapters(
  List<int> chapterMs,
  MusicReleaseTracklist release, {
  bool preferVideo = true,
}) {
  if (chapterMs.isEmpty) return null;
  MusicDiscReleaseMatch? best;
  Iterable<MusicReleaseMedium> pool = release.media.where(
    (MusicReleaseMedium m) => m.tracks.length == chapterMs.length,
  );
  if (preferVideo &&
      pool.any(
        (MusicReleaseMedium m) => isMusicBrainzVideoDiscFormat(m.format),
      )) {
    pool = pool.where(
      (MusicReleaseMedium m) => isMusicBrainzVideoDiscFormat(m.format),
    );
  }
  for (final MusicReleaseMedium m in pool) {
    int total = 0;
    int compared = 0;
    for (int i = 0; i < chapterMs.length; i++) {
      final int? d = m.tracks[i].durationMs;
      if (d == null || d <= 0) continue;
      total += (d - chapterMs[i]).abs();
      compared++;
    }
    final MusicDiscReleaseMatch candidate = MusicDiscReleaseMatch(
      release: release,
      medium: m,
      tracks: m.tracks,
      meanErrorMs: compared == 0 ? null : total ~/ compared,
      comparedCount: compared,
    );
    if (best == null || _better(candidate, best)) best = candidate;
  }
  return best;
}

bool _better(MusicDiscReleaseMatch a, MusicDiscReleaseMatch b) {
  final int? ea = a.meanErrorMs;
  final int? eb = b.meanErrorMs;
  if (ea == null) return false;
  if (eb == null) return true;
  return ea < eb;
}

/// 多张候选发行按对号质量排序（可信的在前，再按平均误差），对不上的丢掉。
List<MusicDiscReleaseMatch> rankMusicDiscReleaseMatches(
  List<int> chapterMs,
  Iterable<MusicReleaseTracklist> releases,
) {
  final List<MusicDiscReleaseMatch> out = <MusicDiscReleaseMatch>[
    for (final MusicReleaseTracklist r in releases)
      ?matchMusicDiscChapters(chapterMs, r),
  ];
  out.sort((MusicDiscReleaseMatch a, MusicDiscReleaseMatch b) {
    if (a.isConfident != b.isConfident) return a.isConfident ? -1 : 1;
    final int ea = a.meanErrorMs ?? 1 << 30;
    final int eb = b.meanErrorMs ?? 1 << 30;
    return ea.compareTo(eb);
  });
  return out;
}

/// 按专辑名（可带艺人）搜任意格式发行的 Lucene 查询串（纯函数，测试钉死）。与
/// [buildMusicBrainzDiscReleaseQuery] 的区别只是不限 DVD / BD 格式——本地专辑的发行
/// 对号（为了拿 Cover Art Archive 的盘面扫描）要找的是 CD / 数字发行。
String buildMusicBrainzAlbumReleaseQuery(String title, {String? artist}) {
  String phrase(String v) =>
      '"${v.trim().replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
  final List<String> parts = <String>['release:${phrase(title)}'];
  final String? a = artist?.trim();
  if (a != null && a.isNotEmpty) parts.add('artist:${phrase(a)}');
  return parts.join(' AND ');
}

/// 一张本地专辑对一张发行的整体对号：本地每张盘（按盘号）各对上发行里**不同**的一张
/// medium，且每张都 [MusicDiscReleaseMatch.isConfident]。
class MusicAlbumReleaseMatch {
  const MusicAlbumReleaseMatch({
    required this.release,
    required this.discs,
    required this.meanErrorMs,
  });

  final MusicReleaseTracklist release;

  /// 本地盘号 → 对上的那张 medium 的结论。
  final Map<int, MusicDiscReleaseMatch> discs;

  /// 全部可比曲目的平均绝对时长误差（毫秒）。
  final int meanErrorMs;

  /// 本地盘数与发行 medium 数一致（不是「只有其中一张」）。
  bool get coversAllMedia => discs.length == release.media.length;
}

/// 本地专辑（盘号 → 该盘按曲序的时长，毫秒）对一张发行。只返回可信结论：任何一张本地
/// 盘找不到可信的 medium，或缺时长，就返回 null（绝不猜）。
///
/// 分配先按位置（本地盘号 = medium 位置）试；不成再按盘号顺序贪心挑误差最小的未用
/// medium。贪心可能漏掉存在的完美分配，但它给出的结果一定每张都可信且互不重复。
MusicAlbumReleaseMatch? matchMusicAlbumRelease(
  Map<int, List<int>> discDurationsMs,
  MusicReleaseTracklist release,
) {
  if (discDurationsMs.isEmpty) return null;
  for (final List<int> d in discDurationsMs.values) {
    if (d.isEmpty || d.any((int ms) => ms <= 0)) return null;
  }
  final List<int> discNos = discDurationsMs.keys.toList()..sort();

  MusicDiscReleaseMatch? confidentOn(int discNo, MusicReleaseMedium m) {
    final MusicDiscReleaseMatch? r = matchMusicDiscChapters(
      discDurationsMs[discNo]!,
      MusicReleaseTracklist(
        mbReleaseId: release.mbReleaseId,
        title: release.title,
        media: <MusicReleaseMedium>[m],
      ),
      preferVideo: false,
    );
    if (r == null || !r.isConfident) return null;
    return MusicDiscReleaseMatch(
      release: release,
      medium: r.medium,
      tracks: r.tracks,
      meanErrorMs: r.meanErrorMs,
      comparedCount: r.comparedCount,
    );
  }

  Map<int, MusicDiscReleaseMatch>? assigned;
  // 1) 按位置。
  final Map<int, MusicDiscReleaseMatch> byPosition =
      <int, MusicDiscReleaseMatch>{};
  for (final int no in discNos) {
    final Iterable<MusicReleaseMedium> at = release.media.where(
      (MusicReleaseMedium m) => m.position == no,
    );
    final MusicDiscReleaseMatch? hit = at.isEmpty
        ? null
        : confidentOn(no, at.first);
    if (hit == null) break;
    byPosition[no] = hit;
  }
  if (byPosition.length == discNos.length) assigned = byPosition;
  // 2) 贪心。
  if (assigned == null) {
    final Map<int, MusicDiscReleaseMatch> greedy =
        <int, MusicDiscReleaseMatch>{};
    final Set<int> used = <int>{};
    for (final int no in discNos) {
      MusicDiscReleaseMatch? best;
      int bestIndex = -1;
      for (int i = 0; i < release.media.length; i++) {
        if (used.contains(i)) continue;
        final MusicDiscReleaseMatch? c = confidentOn(no, release.media[i]);
        if (c == null) continue;
        if (best == null || c.meanErrorMs! < best.meanErrorMs!) {
          best = c;
          bestIndex = i;
        }
      }
      if (best == null) return null;
      used.add(bestIndex);
      greedy[no] = best;
    }
    assigned = greedy;
  }
  int total = 0;
  int compared = 0;
  for (final MusicDiscReleaseMatch m in assigned.values) {
    total += m.meanErrorMs! * m.comparedCount;
    compared += m.comparedCount;
  }
  return MusicAlbumReleaseMatch(
    release: release,
    discs: assigned,
    meanErrorMs: compared == 0 ? 0 : total ~/ compared,
  );
}

/// 多张候选发行里挑本地专辑的那一张：只看可信结论；盘数与发行 medium 数一致的优先，
/// 再按平均误差，误差相同按候选顺序（MusicBrainz 搜索相关度）。都对不上返回 null。
MusicAlbumReleaseMatch? pickMusicAlbumRelease(
  Map<int, List<int>> discDurationsMs,
  Iterable<MusicReleaseTracklist> candidates,
) {
  MusicAlbumReleaseMatch? best;
  for (final MusicReleaseTracklist r in candidates) {
    final MusicAlbumReleaseMatch? m = matchMusicAlbumRelease(
      discDurationsMs,
      r,
    );
    if (m == null) continue;
    if (best == null) {
      best = m;
      continue;
    }
    if (m.coversAllMedia != best.coversAllMedia) {
      if (m.coversAllMedia) best = m;
      continue;
    }
    if (m.meanErrorMs < best.meanErrorMs) best = m;
  }
  return best;
}
