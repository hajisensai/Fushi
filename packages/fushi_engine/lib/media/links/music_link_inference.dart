/// 作品图谱里「动画 / 游戏 ↔ CD」的关系推断（AI 库管家设计稿
/// `docs/specs/2026-11-18-ai-library-curator-design.md` §4.4）。
///
/// 对每张本地专辑（专辑外的散曲按曲目）找它所属的本地动画（视频合集）/ 游戏，只用
/// 本机已有的刮削数据与声纹缓存，**不联网**、不用 Bangumi。证据按强弱：
///
/// 1. 声纹命中（[MusicLinkSpanHit]，`video_theme_song_spans` 里某集的 OP / ED 对上
///    本地曲目）→ `theme_song`，`source = fingerprint`，共享证据（直接生效）；
/// 2. 刮削数据里的专辑名（VGMdb 各语言名、MusicBrainz release / release group 标题）
///    或本地专辑名 / 曲目名带**作品名 + 关键词** → 关系由关键词定（[musicRelationOf]），
///    中证据：交 AI 裁决与 §5.2 门槛，没配 AI 时写成建议；
/// 3. 只有作品名子串、没有关键词 → 弱证据，丢弃（定不出是主题曲还是原声，也挡不住
///    「专辑名碰巧含一个常见词」）。
///
/// 作品名比较走库页搜索同一归一化（[foldMediaTitle]：全半角、大小写、片假名、空白与
/// 标点）；规范化后 ≤ [kMusicLinkMinWorkTitleLength] - 1 个字符的作品名不靠子串判。
///
/// 代码事实（与设计稿 §4.4 第 1 条的差异）：本地刮削只存了 VGMdb 专辑的 id / 目录号 /
/// 各语言名（`music_scrape_meta.vgmdb_json`），没有 product 关系；MusicBrainz release
/// 快照带 release group（标题与 secondary types），没有系列关系。所以第 1 条在这里落成
/// 「刮削出的规范专辑名 + 关键词」与「release group 类别为 Soundtrack」，仍是标题证据。
library;

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi_engine/media/links/media_link_inference.dart';

/// 作品名规范化后至少这么多字符才允许按子串匹配。
const int kMusicLinkMinWorkTitleLength = 3;

/// 声纹命中候选的置信度。
const double kMusicLinkFingerprintConfidence = 0.95;

/// 专辑名带作品名 + 关键词的置信度（中证据）。
const double kMusicLinkAlbumKeywordConfidence = 0.6;

/// 只有曲目名带作品名 + 关键词的置信度（比专辑名弱一档）。
const double kMusicLinkTrackKeywordConfidence = 0.5;

/// 一个可比的音乐标题及它来自哪里（`MediaLinkSource` 的来源名：本地标签 =
/// `title`，VGMdb = `vgmdb`，MusicBrainz = `musicbrainz`）。
typedef MusicLinkTitle = ({String text, String source});

/// 参与推断的一首曲目。
class MusicLinkTrack {
  const MusicLinkTrack({required this.trackUid, required this.title});

  final String trackUid;
  final String title;

  MediaLinkEndpoint get endpoint =>
      (kind: MediaLinkKind.musicTrack, key: trackUid);
}

/// 参与推断的一张专辑。
class MusicLinkAlbum {
  const MusicLinkAlbum({
    required this.albumUid,
    required this.titles,
    this.tracks = const <MusicLinkTrack>[],
    this.releaseGroupTypes = const <String>{},
  });

  final String albumUid;

  /// 第一条是本地专辑名，其余来自刮削。
  final List<MusicLinkTitle> titles;
  final List<MusicLinkTrack> tracks;

  /// MusicBrainz release group 的 primary / secondary types（小写，`soundtrack` …）。
  final Set<String> releaseGroupTypes;

  MediaLinkEndpoint get endpoint =>
      (kind: MediaLinkKind.musicAlbum, key: albumUid);

  String get displayTitle => titles.isEmpty ? albumUid : titles.first.text;
}

/// 一条声纹命中：曲目 [trackUid] 在视频 [videoBookUid] 里被比对出来。
/// [videoEndpoints] 是这条视频可落的作品端点（所在视频合集按 id 升序，最后是单集
/// 端点本身），由 [pickMusicLinkVideoTarget] 选一个。
class MusicLinkSpanHit {
  const MusicLinkSpanHit({
    required this.trackUid,
    required this.videoBookUid,
    required this.episodeIndex,
    required this.videoEndpoints,
  });

  final String trackUid;
  final String videoBookUid;
  final int episodeIndex;
  final List<MediaLinkEndpoint> videoEndpoints;
}

/// 全库音乐侧数据（一次推断内复用）。
class MusicLinkLibrary {
  const MusicLinkLibrary({
    this.albums = const <MusicLinkAlbum>[],
    this.looseTracks = const <MusicLinkTrack>[],
    this.spanHits = const <MusicLinkSpanHit>[],
  });

  static const MusicLinkLibrary empty = MusicLinkLibrary();

  final List<MusicLinkAlbum> albums;

  /// 不属于任何专辑的曲目。
  final List<MusicLinkTrack> looseTracks;
  final List<MusicLinkSpanHit> spanHits;

  bool get isEmpty => albums.isEmpty && looseTracks.isEmpty && spanHits.isEmpty;

  /// [e] 是不是本库里的音乐端点。
  bool contains(MediaLinkEndpoint e) => switch (e.kind) {
    MediaLinkKind.musicAlbum => albums.any(
      (MusicLinkAlbum a) => a.albumUid == e.key,
    ),
    MediaLinkKind.musicTrack =>
      looseTracks.any((MusicLinkTrack t) => t.trackUid == e.key) ||
          albums.any(
            (MusicLinkAlbum a) =>
                a.tracks.any((MusicLinkTrack t) => t.trackUid == e.key),
          ),
    _ => false,
  };
}

// ── 关键词 ──────────────────────────────────────────────────────────────────

/// 原声类关键词（日文 / 中文按 [foldMediaTitle] 折叠后比较）。
const List<String> _kSoundtrackWords = <String>[
  'サウンドトラック',
  'サントラ',
  '劇伴',
  '音楽集',
  'BGM集',
  '原声',
  '原聲',
];

/// 主题曲类关键词（同上）。
const List<String> _kThemeSongWords = <String>[
  '主題歌',
  '主题曲',
  'オープニング',
  'エンディング',
  '挿入歌',
  'キャラクターソング',
  'キャラソン',
  'ドラマCD',
];

/// 拉丁字母关键词：前后不能紧贴字母（`OP` 不命中 `Tropical`、`ED` 不命中
/// `Edition`），数字可以（`OP2`）。
final RegExp _kSoundtrackLatin = RegExp(
  r'(?<![A-Za-z])(OST|O\.S\.T|soundtrack|original score|BGM)(?![A-Za-z])',
  caseSensitive: false,
);
final RegExp _kThemeSongLatin = RegExp(
  r'(?<![A-Za-z])(OP|ED|opening|ending|theme song|insert song|character song)'
  r'(?![A-Za-z])',
  caseSensitive: false,
);

final List<String> _kSoundtrackFolded = <String>[
  for (final String w in _kSoundtrackWords) foldMediaTitle(w),
];
final List<String> _kThemeSongFolded = <String>[
  for (final String w in _kThemeSongWords) foldMediaTitle(w),
];

/// 由音乐标题里的关键词定关系：原声类 → [MediaLinkRelation.soundtrack]，主题曲类
/// → [MediaLinkRelation.themeSong]，都没有 → null。两类都有时取原声（一张 OST 收了
/// TV size 的 OP / ED 仍是原声集）。[releaseGroupTypes] 含 `soundtrack`（MusicBrainz
/// 的专辑类别）等同原声关键词。
MediaLinkRelation? musicRelationOf(
  String title, {
  Set<String> releaseGroupTypes = const <String>{},
}) {
  final String folded = foldMediaTitle(title);
  if (releaseGroupTypes.contains('soundtrack') ||
      _kSoundtrackLatin.hasMatch(title) ||
      _kSoundtrackFolded.any(folded.contains)) {
    return MediaLinkRelation.soundtrack;
  }
  if (_kThemeSongLatin.hasMatch(title) ||
      _kThemeSongFolded.any(folded.contains)) {
    return MediaLinkRelation.themeSong;
  }
  return null;
}

// ── 证据分级 ────────────────────────────────────────────────────────────────

/// 音乐 ↔ 作品一条证据的强弱。
enum MusicLinkEvidence {
  /// 声纹命中（直接生效）。
  fingerprint,

  /// 作品名 + 关键词（建议 / 交 AI）。
  titleKeyword,

  /// 只有作品名子串（丢弃）。
  titleOnly,

  /// 对不上。
  none,
}

/// 一个音乐标题对一部作品的标题证据。
typedef MusicTitleMatch = ({
  MusicLinkEvidence evidence,
  MediaLinkRelation? relation,

  /// 命中的作品名（规范化后），挑更具体的作品用。
  String matchedWorkTitle,
});

/// [musicTitle] 里是否含 [workTitles] 之一（规范化后，作品名至少
/// [kMusicLinkMinWorkTitleLength] 个字符），以及关键词定出的关系。
MusicTitleMatch gradeMusicTitle(
  String musicTitle,
  Iterable<String> workTitles, {
  Set<String> releaseGroupTypes = const <String>{},
}) {
  final String folded = foldMediaTitle(musicTitle);
  String best = '';
  for (final String w in workTitles) {
    final String fw = foldMediaTitle(w);
    if (fw.length < kMusicLinkMinWorkTitleLength) continue;
    if (folded.contains(fw) && fw.length > best.length) best = fw;
  }
  if (best.isEmpty) {
    return (
      evidence: MusicLinkEvidence.none,
      relation: null,
      matchedWorkTitle: '',
    );
  }
  final MediaLinkRelation? relation = musicRelationOf(
    musicTitle,
    releaseGroupTypes: releaseGroupTypes,
  );
  return (
    evidence: relation == null
        ? MusicLinkEvidence.titleOnly
        : MusicLinkEvidence.titleKeyword,
    relation: relation,
    matchedWorkTitle: best,
  );
}

/// 一条声纹命中落到哪个作品端点：[hit] 的候选端点里出现在 [works] 中的，带外部 id
/// 的优先，否则取第一个；都不在 [works] 里就落到单集端点（列表最后一个）。
MediaLinkSubject pickMusicLinkVideoTarget(
  MusicLinkSpanHit hit,
  List<MediaLinkSubject> works,
) {
  MediaLinkSubject? first;
  for (final MediaLinkEndpoint e in hit.videoEndpoints) {
    for (final MediaLinkSubject w in works) {
      if (w.endpoint.kind != e.kind || w.endpoint.key != e.key) continue;
      if (w.externalIds.isNotEmpty) return w;
      first ??= w;
    }
  }
  if (first != null) return first;
  return MediaLinkSubject(
    endpoint: hit.videoEndpoints.isEmpty
        ? (kind: MediaLinkKind.videoEpisode, key: hit.videoBookUid)
        : hit.videoEndpoints.last,
    titles: const <String>[],
  );
}

MediaLinkSubject _albumSubject(MusicLinkAlbum a) => MediaLinkSubject(
  endpoint: a.endpoint,
  titles: <String>[for (final MusicLinkTitle t in a.titles) t.text],
);

MediaLinkSubject _trackSubject(MusicLinkTrack t) =>
    MediaLinkSubject(endpoint: t.endpoint, titles: <String>[t.title]);

/// 只留更具体的作品：一部作品的命中名是另一部命中名的真子串时丢掉它
/// （「進撃の巨人 Season 2 OST」只连 Season 2，不连正篇）。
List<(MediaLinkSubject, MusicTitleMatch)> _mostSpecific(
  List<(MediaLinkSubject, MusicTitleMatch)> hits,
) => <(MediaLinkSubject, MusicTitleMatch)>[
  for (final (MediaLinkSubject, MusicTitleMatch) h in hits)
    if (!hits.any(
      ((MediaLinkSubject, MusicTitleMatch) o) =>
          o.$2.matchedWorkTitle.length > h.$2.matchedWorkTitle.length &&
          o.$2.matchedWorkTitle.contains(h.$2.matchedWorkTitle),
    ))
      h,
];

/// 规则：全库音乐 → 作品候选（纯函数）。[works] = 本地视频合集与游戏（其它种类
/// 忽略）。声纹候选排在前面：同一对条目先到先得（[applyMediaLinkCandidates] 去重）。
List<MediaLinkCandidate> collectMusicLinkCandidates({
  required MusicLinkLibrary music,
  required List<MediaLinkSubject> works,
}) {
  final List<MediaLinkSubject> targets = <MediaLinkSubject>[
    for (final MediaLinkSubject w in works)
      if (w.endpoint.kind == MediaLinkKind.videoCollection ||
          w.endpoint.kind == MediaLinkKind.game)
        w,
  ];
  final List<MediaLinkCandidate> out = <MediaLinkCandidate>[];

  // 1. 声纹命中：专辑里的曲目落到专辑，散曲落到曲目。
  final Map<String, MusicLinkAlbum> albumOfTrack = <String, MusicLinkAlbum>{
    for (final MusicLinkAlbum a in music.albums)
      for (final MusicLinkTrack t in a.tracks) t.trackUid: a,
  };
  final Map<String, MusicLinkTrack> looseByUid = <String, MusicLinkTrack>{
    for (final MusicLinkTrack t in music.looseTracks) t.trackUid: t,
  };
  final Map<String, String> titleOfTrack = <String, String>{
    for (final MusicLinkAlbum a in music.albums)
      for (final MusicLinkTrack t in a.tracks) t.trackUid: t.title,
    for (final MusicLinkTrack t in music.looseTracks) t.trackUid: t.title,
  };
  final Map<String, ({MediaLinkSubject music, MediaLinkSubject video})> pairs =
      <String, ({MediaLinkSubject music, MediaLinkSubject video})>{};
  final Map<String, Set<String>> episodesOf = <String, Set<String>>{};
  final Map<String, Set<String>> tracksOf = <String, Set<String>>{};
  for (final MusicLinkSpanHit hit in music.spanHits) {
    final MusicLinkAlbum? album = albumOfTrack[hit.trackUid];
    final MusicLinkTrack? loose = looseByUid[hit.trackUid];
    final MediaLinkSubject? from = album != null
        ? _albumSubject(album)
        : loose != null
        ? _trackSubject(loose)
        : null;
    if (from == null) continue;
    final MediaLinkSubject video = pickMusicLinkVideoTarget(hit, works);
    final String key =
        '${from.endpoint.kind.dbValue}\u0000${from.endpoint.key}\u0001'
        '${video.endpoint.kind.dbValue}\u0000${video.endpoint.key}';
    pairs.putIfAbsent(key, () => (music: from, video: video));
    (episodesOf[key] ??= <String>{}).add(
      '${hit.videoBookUid}#${hit.episodeIndex}',
    );
    (tracksOf[key] ??= <String>{}).add(hit.trackUid);
  }
  for (final MapEntry<
        String,
        ({MediaLinkSubject music, MediaLinkSubject video})
      >
      e
      in pairs.entries) {
    final String songs = <String>[
      for (final String uid in tracksOf[e.key]!)
        '"${titleOfTrack[uid] ?? uid}"',
    ].join(', ');
    out.add(
      MediaLinkCandidate(
        from: e.value.music,
        to: e.value.video,
        relation: MediaLinkRelation.themeSong,
        source: MediaLinkSource.fingerprint,
        confidence: kMusicLinkFingerprintConfidence,
        reason:
            'Audio fingerprint: $songs found as an opening / ending in '
            '${episodesOf[e.key]!.length} episode(s) of '
            '"${e.value.video.displayTitle}".',
        idEvidence: true,
      ),
    );
  }

  // 2. 标题 + 关键词：专辑名（本地 / VGMdb / MusicBrainz）。专辑名对不上的作品，再看
  //    曲目名（「X」オープニングテーマ），落到曲目。
  for (final MusicLinkAlbum album in music.albums) {
    final List<(MediaLinkSubject, MusicTitleMatch)> hits =
        <(MediaLinkSubject, MusicTitleMatch)>[];
    final Map<MediaLinkSubject, MusicLinkTitle> via =
        <MediaLinkSubject, MusicLinkTitle>{};
    for (final MediaLinkSubject w in targets) {
      for (final MusicLinkTitle t in album.titles) {
        final MusicTitleMatch m = gradeMusicTitle(
          t.text,
          w.titles,
          releaseGroupTypes: t.source == MediaLinkSource.musicbrainz
              ? album.releaseGroupTypes
              : const <String>{},
        );
        if (m.evidence != MusicLinkEvidence.titleKeyword) continue;
        hits.add((w, m));
        via[w] = t;
        break;
      }
    }
    for (final (MediaLinkSubject w, MusicTitleMatch m) in _mostSpecific(hits)) {
      final MusicLinkTitle t = via[w]!;
      out.add(
        MediaLinkCandidate(
          from: _albumSubject(album),
          to: w,
          relation: m.relation!,
          source: t.source,
          confidence: kMusicLinkAlbumKeywordConfidence,
          reason:
              'Album title "${t.text}"${_sourceNote(t.source)} names '
              '"${w.displayTitle}" and reads as '
              '${m.relation == MediaLinkRelation.soundtrack ? 'a soundtrack' : 'a theme / character song release'} '
              '(no shared external id).',
        ),
      );
    }
    // 专辑名已连上的作品不再按曲目连（被更具体的作品挤掉的那部也不按曲目补连）。
    final List<MediaLinkSubject> rest = <MediaLinkSubject>[
      for (final MediaLinkSubject w in targets)
        if (!hits.any(((MediaLinkSubject, MusicTitleMatch) h) => h.$1 == w)) w,
    ];
    out.addAll(_trackCandidates(album.tracks, rest));
  }
  out.addAll(_trackCandidates(music.looseTracks, targets));
  return out;
}

String _sourceNote(String source) => switch (source) {
  MediaLinkSource.vgmdb => ' (VGMdb)',
  MediaLinkSource.musicbrainz => ' (MusicBrainz)',
  _ => '',
};

List<MediaLinkCandidate> _trackCandidates(
  List<MusicLinkTrack> tracks,
  List<MediaLinkSubject> targets,
) {
  final List<MediaLinkCandidate> out = <MediaLinkCandidate>[];
  for (final MusicLinkTrack track in tracks) {
    final List<(MediaLinkSubject, MusicTitleMatch)> hits =
        <(MediaLinkSubject, MusicTitleMatch)>[
          for (final MediaLinkSubject w in targets)
            if (gradeMusicTitle(track.title, w.titles)
                case final MusicTitleMatch m
                when m.evidence == MusicLinkEvidence.titleKeyword)
              (w, m),
        ];
    for (final (MediaLinkSubject w, MusicTitleMatch m) in _mostSpecific(hits)) {
      out.add(
        MediaLinkCandidate(
          from: _trackSubject(track),
          to: w,
          relation: m.relation!,
          source: kMediaLinkTitleMatchSource,
          confidence: kMusicLinkTrackKeywordConfidence,
          reason:
              'Track title "${track.title}" names "${w.displayTitle}" '
              '(no shared external id).',
        ),
      );
    }
  }
  return out;
}

// ── 落库与整批撤销 ──────────────────────────────────────────────────────────

/// 一批音乐关系推断里写进库的一条连接。
class MusicLinkBatchWrite {
  const MusicLinkBatchWrite({
    required this.id,
    required this.disposition,
    this.previous,
  });

  final MediaLinkId id;

  /// [MediaLinkDisposition.apply]（`confirmed_by = ai`）或
  /// [MediaLinkDisposition.suggest]（建议）。
  final MediaLinkDisposition disposition;

  /// 写入前的行（null = 之前没有）。建议只在这一对之间原本没有任何行时才写，恒为 null。
  final MediaLinkRow? previous;
}

/// 一批音乐关系推断的结果（库管家编排用）。
class MusicLinkBatchResult {
  const MusicLinkBatchResult({required this.writes, required this.discarded});

  static const MusicLinkBatchResult empty = MusicLinkBatchResult(
    writes: <MusicLinkBatchWrite>[],
    discarded: 0,
  );

  final List<MusicLinkBatchWrite> writes;

  /// AI 判不相关 / 自动路径下低置信而丢弃的候选数。
  final int discarded;

  Iterable<MusicLinkBatchWrite> get applied => writes.where(
    (MusicLinkBatchWrite w) => w.disposition == MediaLinkDisposition.apply,
  );

  Iterable<MusicLinkBatchWrite> get suggested => writes.where(
    (MusicLinkBatchWrite w) => w.disposition == MediaLinkDisposition.suggest,
  );
}

/// 全库批量推断音乐关系并落库（§5.2 门槛，经 [applyMediaLinkCandidates]）：声纹命中
/// 直接生效，标题 + 关键词按 [trigger] 与 AI 结论生效 / 建议 / 丢弃。用户确认过的、
/// 否决过（墓碑）的一对不碰。返回逐条写入清单，[revertMusicLinkBatch] 整批撤销。
Future<MusicLinkBatchResult> inferMusicMediaLinks({
  required FushiDatabase db,
  required MusicLinkLibrary music,
  required List<MediaLinkSubject> works,
  required MediaLinkInferenceTrigger trigger,
  MediaLinkJudge? judge,
}) async {
  final List<MediaLinkCandidate> candidates = collectMusicLinkCandidates(
    music: music,
    works: works,
  );
  if (candidates.isEmpty) return MusicLinkBatchResult.empty;
  final MediaLinkInferenceOutcome outcome = await applyMediaLinkCandidates(
    db: db,
    candidates: candidates,
    trigger: trigger,
    judge: judge,
  );
  return MusicLinkBatchResult(
    writes: List<MusicLinkBatchWrite>.unmodifiable(<MusicLinkBatchWrite>[
      for (final MediaLinkAiWrite w in outcome.appliedWrites)
        MusicLinkBatchWrite(
          id: w.id,
          disposition: MediaLinkDisposition.apply,
          previous: w.previous,
        ),
      for (final MediaLinkId id in outcome.suggestedIds)
        MusicLinkBatchWrite(id: id, disposition: MediaLinkDisposition.suggest),
    ]),
    discarded: outcome.discarded,
  );
}

/// 整批撤销 [inferMusicMediaLinks] 的写入：生效的退回写入前的行
/// （`revertAiMediaLink`），建议直接删（`discardMediaLinkSuggestion`）。之后已被
/// 用户确认 / 否决的不覆盖。返回实际撤回的条数。
Future<int> revertMusicLinkBatch(
  FushiDatabase db,
  MusicLinkBatchResult batch,
) async {
  int reverted = 0;
  for (final MusicLinkBatchWrite w in batch.writes.reversed) {
    final bool ok = switch (w.disposition) {
      MediaLinkDisposition.apply => await db.revertAiMediaLink(
        w.id,
        previous: w.previous,
      ),
      MediaLinkDisposition.suggest => await db.discardMediaLinkSuggestion(w.id),
      MediaLinkDisposition.discard => false,
    };
    if (ok) reverted++;
  }
  return reverted;
}

// ── 从本地库装载 ────────────────────────────────────────────────────────────

/// 读本机曲库、刮削结果与声纹缓存，装成 [MusicLinkLibrary]（只读，不联网）。
Future<MusicLinkLibrary> loadMusicLinkLibrary(FushiDatabase db) async {
  final List<MusicTrackRow> tracks = await db.listMusicTracks();
  final List<MusicAlbumRow> albums = await db.listMusicAlbums();
  final Map<String, MusicScrapeMetaRow> metaByTrack =
      <String, MusicScrapeMetaRow>{
        for (final MusicScrapeMetaRow m
            in await db.select(db.musicScrapeMeta).get())
          m.trackUid: m,
      };
  final Map<String, List<MusicTrackRow>> tracksByAlbum =
      <String, List<MusicTrackRow>>{};
  final List<MusicLinkTrack> loose = <MusicLinkTrack>[];
  for (final MusicTrackRow t in tracks) {
    if (t.albumUid case final String a) {
      (tracksByAlbum[a] ??= <MusicTrackRow>[]).add(t);
    } else {
      loose.add(MusicLinkTrack(trackUid: t.trackUid, title: t.title));
    }
  }

  final List<MusicLinkAlbum> out = <MusicLinkAlbum>[];
  for (final MusicAlbumRow a in albums) {
    final List<MusicTrackRow> rows =
        tracksByAlbum[a.albumUid] ?? const <MusicTrackRow>[];
    final List<MusicLinkTitle> titles = <MusicLinkTitle>[
      (text: a.title, source: kMediaLinkTitleMatchSource),
    ];
    final Set<String> seen = <String>{foldMediaTitle(a.title)};
    void addTitle(String? text, String source) {
      if (text == null || text.trim().isEmpty) return;
      if (!seen.add(foldMediaTitle(text))) return;
      titles.add((text: text.trim(), source: source));
    }

    for (final MusicTrackRow t in rows) {
      final MusicScrapeMetaRow? m = metaByTrack[t.trackUid];
      if (m == null) continue;
      for (final String name in _vgmdbNames(m.vgmdbJson)) {
        addTitle(name, MediaLinkSource.vgmdb);
      }
      addTitle(m.albumTitle, MediaLinkSource.musicbrainz);
    }
    Set<String> groupTypes = const <String>{};
    if (a.mbReleaseId case final String rid when rid.trim().isNotEmpty) {
      final MusicMetadataRawSnapshotRow? snap = await db.getMusicRawSnapshot(
        provider: 'musicbrainz',
        snapshotKind: 'release',
        externalId: rid.trim(),
      );
      final ({String? title, Set<String> types}) group = _releaseGroupOf(
        snap?.rawJson,
      );
      addTitle(group.title, MediaLinkSource.musicbrainz);
      groupTypes = group.types;
    }
    out.add(
      MusicLinkAlbum(
        albumUid: a.albumUid,
        titles: titles,
        tracks: <MusicLinkTrack>[
          for (final MusicTrackRow t in rows)
            MusicLinkTrack(trackUid: t.trackUid, title: t.title),
        ],
        releaseGroupTypes: groupTypes,
      ),
    );
  }

  final List<VideoThemeSongSpanRow> spans = await (db.select(
    db.videoThemeSongSpans,
  )..where(($VideoThemeSongSpansTable t) => t.startMs.isNotNull())).get();
  final Set<String> bookUids = <String>{
    for (final VideoThemeSongSpanRow s in spans) s.bookUid,
  };
  final Map<String, List<int>> collectionsOf = <String, List<int>>{};
  if (bookUids.isNotEmpty) {
    for (final MediaCollectionItemRow item
        in await (db.select(db.mediaCollectionItems)..where(
              ($MediaCollectionItemsTable t) =>
                  t.mediaType.equals(MediaKind.video.dbValue) &
                  t.entryKey.isIn(bookUids),
            ))
            .get()) {
      (collectionsOf[item.entryKey] ??= <int>[]).add(item.collectionId);
    }
  }
  return MusicLinkLibrary(
    albums: out,
    looseTracks: loose,
    spanHits: <MusicLinkSpanHit>[
      for (final VideoThemeSongSpanRow s in spans)
        MusicLinkSpanHit(
          trackUid: s.trackUid,
          videoBookUid: s.bookUid,
          episodeIndex: s.episodeIndex,
          videoEndpoints: <MediaLinkEndpoint>[
            for (final int id
                in (collectionsOf[s.bookUid] ?? const <int>[]).toList()..sort())
              (
                kind: MediaLinkKind.videoCollection,
                key: collectionTagEntryKey(id),
              ),
            (kind: MediaLinkKind.videoEpisode, key: s.bookUid),
          ],
        ),
    ],
  );
}

/// `music_scrape_meta.vgmdb_json` 的 `names`（语言码 → 专辑名）；格式不对返回空。
List<String> _vgmdbNames(String? raw) {
  if (raw == null || raw.isEmpty) return const <String>[];
  try {
    final Object? json = jsonDecode(raw);
    if (json is! Map) return const <String>[];
    final Object? names = json['names'];
    if (names is! Map) return const <String>[];
    return <String>[
      for (final Object? v in names.values)
        if (v is String && v.trim().isNotEmpty) v,
    ];
  } on FormatException {
    return const <String>[];
  }
}

/// MusicBrainz release 快照里的 release group 标题与类别（小写）。
({String? title, Set<String> types}) _releaseGroupOf(String? raw) {
  if (raw == null || raw.isEmpty) return (title: null, types: const <String>{});
  try {
    final Object? json = jsonDecode(raw);
    final Object? group = json is Map ? json['release-group'] : null;
    if (group is! Map) return (title: null, types: const <String>{});
    final Object? title = group['title'];
    final Object? secondary = group['secondary-types'];
    final Object? primary = group['primary-type'];
    return (
      title: title is String ? title : null,
      types: <String>{
        if (primary is String) primary.toLowerCase(),
        if (secondary is List)
          for (final Object? s in secondary)
            if (s is String) s.toLowerCase(),
      },
    );
  } on FormatException {
    return (title: null, types: const <String>{});
  }
}
