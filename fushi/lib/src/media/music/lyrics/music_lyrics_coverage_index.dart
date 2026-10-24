/// 曲库「按难度排序」（设计 §12）：把每首歌歌词的生词覆盖率算好落库
/// （`music_lyric_coverage`，schema v134），曲库页按它排序、显示难度。
///
/// ## 怎么算
/// 与歌词页的覆盖率同一口径（`music_lyrics_coverage.dart`）：整首歌词一次批量分词
/// （`fushidicts_tokenize_terms`），只数词典命中的词，按词头归一；已知 = 复习库里该词
/// 已进入复习队列（[SrsKnownTermSnapshot]）。
///
/// 批处理：每 [kMusicCoverageBatchTracks] 首歌的全部歌词行拼成**一次** FFI 调用，在后台
/// isolate 里分词（`FushiDicts.tokenizeTermsInBackground`）；歌词只取本地来源（用户指定 /
/// sidecar / 内嵌 / 已缓存的 LRCLIB），不为排序发网络请求。每批之间可中断，进度经
/// [MusicLyricsCoverageIndex.progress] 推给界面。
///
/// ## 失效与重算（两段各自失效）
/// - **分词段**：输入指纹 = 词典集合签名（释义词典目录 + 修改时刻，与「我库里的例句」
///   同一签名）+ 歌词解析器版本 + 曲目文件 mtime（内嵌歌词随文件变）+ 该曲
///   `music_lyrics` 各行内容摘要（来源 / 格式 / 是否手动指定 / 原文 SHA-1）。下次运行时
///   指纹不同的曲目重新解析歌词并分词；换词典 = 签名变 = 整库重分词。
///   磁盘上的 sidecar 被改 / 新增而该曲没再打开过歌词页时，`music_lyrics` 行没变，增量
///   运行看不出来——「重新计算」（`force`）会重读每首歌的本地歌词。
/// - **已知段**：复习库每次运行前读一次「已知词」快照，快照指纹（只随已知判定所依赖的
///   分布变，复习一次但队列没变不算）与行里记的不同就用存下的词头重判，不重新分词。
///   复习模块关着时不判，界面不显示难度（不硬造 0%）。
/// - 曲目被删（`deleted_at`）或从曲库消失：行留着无害（按 uid 取不到就不显示），下次
///   运行顺手删掉孤儿行。
library;

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart'
    show FushiDicts, FushiTermToken;
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_music/fushi_music.dart' show FushiLyrics, LyricTimeline;
import 'package:fushi_srs/fushi_srs.dart'
    show SrsKnownTermSnapshot, SrsTermQuery;

import 'package:fushi/src/corpus/library_corpus_service.dart'
    show FushiDictsCorpusNormalizer;
import 'package:fushi/src/media/music/lyrics/music_lyrics_coverage.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_service.dart';
import 'package:fushi/src/media/music/music_library_data.dart';
import 'package:fushi/src/media/music/music_output_backend.dart'
    show MusicPlayItem;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 一次 FFI 分词调用装几首歌的歌词。
const int kMusicCoverageBatchTracks = 24;

/// `music_lyric_coverage.status` 的值域。
enum MusicCoverageStatus {
  ok('ok'),
  noLyrics('no_lyrics'),
  noTerms('no_terms');

  const MusicCoverageStatus(this.dbValue);

  final String dbValue;

  static MusicCoverageStatus? parse(String? v) {
    for (final MusicCoverageStatus s in values) {
      if (s.dbValue == v) return s;
    }
    return null;
  }
}

/// 存下来的词：`[[词头, 读音, 次数], …]`。
String encodeMusicCoverageTerms(List<MusicCoverageTerm> terms) =>
    jsonEncode(<List<Object>>[
      for (final MusicCoverageTerm t in terms)
        <Object>[t.expression, t.reading, t.count],
    ]);

List<MusicCoverageTerm> decodeMusicCoverageTerms(String json) {
  final Object? raw = jsonDecode(json);
  if (raw is! List) return const <MusicCoverageTerm>[];
  return <MusicCoverageTerm>[
    for (final Object? e in raw)
      if (e is List && e.length == 3 && e[0] is String && e[2] is num)
        (
          expression: e[0] as String,
          reading: e[1] is String ? e[1] as String : '',
          count: (e[2] as num).toInt(),
        ),
  ];
}

/// 已知词出现次数（按存下的词判）。
int musicKnownTokensOf(
  List<MusicCoverageTerm> terms,
  SrsKnownTermSnapshot known,
) {
  int n = 0;
  for (final MusicCoverageTerm t in terms) {
    if (known.isKnown(
      SrsTermQuery(t.expression, t.reading.isEmpty ? null : t.reading),
    )) {
      n += t.count;
    }
  }
  return n;
}

/// 该曲 `music_lyrics` 各行的内容摘要（见文件头「分词段」）：`updatedAt` 不算——打开
/// 歌词页时 sidecar 每次重读都会刷新它，内容没变不该触发重算。
String musicLyricRowsDigest(List<MusicLyricRow> rows) {
  final List<String> parts = <String>[
    for (final MusicLyricRow r in rows)
      <String>[
        r.source,
        r.format,
        r.isUserEdited ? '1' : '0',
        sha1.convert(r.raw).toString(),
      ].join('\u0001'),
  ]..sort();
  return parts.join('\u0002');
}

/// 分词段输入指纹。
String musicCoverageInputStamp({
  required String dictionaryStamp,
  required int parserVersion,
  required int trackMtimeAt,
  required String lyricRowsDigest,
}) => sha1
    .convert(
      utf8.encode(
        <Object>[
          dictionaryStamp,
          parserVersion,
          trackMtimeAt,
          lyricRowsDigest,
        ].join('\u0003'),
      ),
    )
    .toString();

/// 一首歌在曲库里的难度视图。
class MusicTrackDifficulty {
  const MusicTrackDifficulty._(
    this.status, {
    this.knownTokens,
    this.totalTokens = 0,
  });

  /// 还没算过 / 正在算。
  static const MusicTrackDifficulty pending = MusicTrackDifficulty._(null);

  factory MusicTrackDifficulty.fromRow(MusicLyricCoverageRow? row) {
    if (row == null) return pending;
    final MusicCoverageStatus? s = MusicCoverageStatus.parse(row.status);
    if (s == null) return pending;
    return MusicTrackDifficulty._(
      s,
      knownTokens: row.knownTokens,
      totalTokens: row.totalTokens,
    );
  }

  final MusicCoverageStatus? status;

  /// null = 已分词但还没判已知（复习模块关着 / 刚分完）。
  final int? knownTokens;
  final int totalTokens;

  /// 已知覆盖率 0–1；只有分词与已知判定都有了才有。
  double? get ratio {
    final int? known = knownTokens;
    if (status != MusicCoverageStatus.ok || known == null || totalTokens <= 0) {
      return null;
    }
    return known / totalTokens;
  }

  int? get percent {
    final double? r = ratio;
    return r == null ? null : (r * 100).round();
  }

  /// 排序分档：0 有覆盖率；1 已分词待判已知；2 待计算；3 无词典词；4 无歌词（最后）。
  int get sortTier => switch (status) {
    MusicCoverageStatus.ok => ratio == null ? 1 : 0,
    null => 2,
    MusicCoverageStatus.noTerms => 3,
    MusicCoverageStatus.noLyrics => 4,
  };
}

/// 曲目列表排序方式（曲库页「歌曲」分区）。持久化值见 [prefValue]。
enum MusicTrackSort {
  /// 曲库顺序（扫描 / 标签顺序）。
  library('library'),

  /// 由易到难：已知覆盖率高的在前。
  easiestFirst('easiest'),

  /// 由难到易：已知覆盖率低的在前。
  hardestFirst('hardest');

  const MusicTrackSort(this.prefValue);

  final String prefValue;

  bool get byDifficulty => this != MusicTrackSort.library;

  static MusicTrackSort parse(String? v) {
    for (final MusicTrackSort s in values) {
      if (s.prefValue == v) return s;
    }
    return MusicTrackSort.library;
  }
}

/// 按难度排序（稳定：同档同覆盖率保持曲库顺序）。没有覆盖率的曲目一律排在后面，
/// 无歌词的最后。
List<MusicTrackRow> sortMusicTracksByDifficulty(
  List<MusicTrackRow> tracks,
  Map<String, MusicTrackDifficulty> difficulty,
  MusicTrackSort sort,
) {
  if (!sort.byDifficulty) return tracks;
  final List<(int, MusicTrackRow, MusicTrackDifficulty)> indexed =
      <(int, MusicTrackRow, MusicTrackDifficulty)>[
        for (int i = 0; i < tracks.length; i++)
          (
            i,
            tracks[i],
            difficulty[tracks[i].trackUid] ?? MusicTrackDifficulty.pending,
          ),
      ];
  indexed.sort((
    (int, MusicTrackRow, MusicTrackDifficulty) a,
    (int, MusicTrackRow, MusicTrackDifficulty) b,
  ) {
    final int tier = a.$3.sortTier.compareTo(b.$3.sortTier);
    if (tier != 0) return tier;
    final double? ra = a.$3.ratio;
    final double? rb = b.$3.ratio;
    if (ra != null && rb != null && ra != rb) {
      return sort == MusicTrackSort.easiestFirst
          ? rb.compareTo(ra)
          : ra.compareTo(rb);
    }
    return a.$1.compareTo(b.$1);
  });
  return <MusicTrackRow>[
    for (final (int, MusicTrackRow, MusicTrackDifficulty) e in indexed) e.$2,
  ];
}

/// 进度（曲库页一行进度条）。
class MusicCoverageProgress {
  const MusicCoverageProgress({
    this.running = false,
    this.done = 0,
    this.total = 0,
  });

  final bool running;
  final int done;
  final int total;
}

/// 一次运行的结论。
enum MusicCoverageRunOutcome {
  /// 跑完（含「没有需要重算的」）。
  completed,

  /// 被 [MusicLyricsCoverageIndex.cancel] 中断（已算完的批次已落库）。
  cancelled,

  /// 没装释义词典（或词典正在装载）：算不了。
  noDictionary,

  /// 数据库还没就绪。
  unavailable,
}

/// 运行结论 + 复习模块是否可用（关着时难度不显示）。
typedef MusicCoverageRunResult = ({
  MusicCoverageRunOutcome outcome,
  bool knownAvailable,
});

/// 只解析本地歌词。
typedef MusicLocalLyricsResolver =
    Future<LyricTimeline?> Function(MusicLyricsTrackRef track);

/// 生词覆盖率索引（编排层：决定算哪些、什么时候算，状态全在表里）。
class MusicLyricsCoverageIndex {
  MusicLyricsCoverageIndex({
    required FushiDatabase? Function() database,
    required MusicLocalLyricsResolver resolveLocal,
    required MusicTermTokenizer tokenize,
    required String? Function() dictionaryStamp,
    required Future<SrsKnownTermSnapshot?> Function() knownSnapshot,
    int Function()? now,
    int batchTracks = kMusicCoverageBatchTracks,
  }) : _database = database,
       _resolveLocal = resolveLocal,
       _tokenize = tokenize,
       _dictionaryStamp = dictionaryStamp,
       _knownSnapshot = knownSnapshot,
       _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
       _batchTracks = batchTracks;

  final FushiDatabase? Function() _database;
  final MusicLocalLyricsResolver _resolveLocal;
  final MusicTermTokenizer _tokenize;
  final String? Function() _dictionaryStamp;
  final Future<SrsKnownTermSnapshot?> Function() _knownSnapshot;
  final int Function() _now;
  final int _batchTracks;

  final ValueNotifier<MusicCoverageProgress> _progress =
      ValueNotifier<MusicCoverageProgress>(const MusicCoverageProgress());

  ValueListenable<MusicCoverageProgress> get progress => _progress;

  Future<MusicCoverageRunResult>? _inFlight;
  bool _cancelRequested = false;

  /// 读出全部覆盖率行（曲库页排序 / 显示用）。
  Future<Map<String, MusicTrackDifficulty>> loadDifficulty() async {
    final FushiDatabase? db = _database();
    if (db == null) return const <String, MusicTrackDifficulty>{};
    final List<MusicLyricCoverageRow> rows = await db
        .select(db.musicLyricCoverage)
        .get();
    return <String, MusicTrackDifficulty>{
      for (final MusicLyricCoverageRow r in rows)
        r.trackUid: MusicTrackDifficulty.fromRow(r),
    };
  }

  /// 中断正在跑的一次（当前批次分完词、落完库后停）。
  void cancel() {
    if (_inFlight != null) _cancelRequested = true;
  }

  /// 增量计算（[force] = 重读每首歌的本地歌词、全部重分词）。同一时刻只跑一次：已经在
  /// 跑时返回那一次的结果；在跑的是增量而这次要 force，跑完再补一次 force。
  Future<MusicCoverageRunResult> run({bool force = false}) {
    final Future<MusicCoverageRunResult>? running = _inFlight;
    if (running != null) {
      if (!force) return running;
      return running.then((_) => run(force: true));
    }
    _cancelRequested = false;
    final Future<MusicCoverageRunResult> f = _run(force: force).whenComplete(
      () {
        _inFlight = null;
        _progress.value = const MusicCoverageProgress();
      },
    );
    _inFlight = f;
    return f;
  }

  Future<MusicCoverageRunResult> _run({required bool force}) async {
    final FushiDatabase? db = _database();
    if (db == null) {
      return (
        outcome: MusicCoverageRunOutcome.unavailable,
        knownAvailable: false,
      );
    }
    final String? dictStamp = _dictionaryStamp();
    if (dictStamp == null) {
      // 没有词典就没有词头：分词段算不了，但已分好的行仍可按新的复习库重判已知。
      final bool known = await _refreshKnown(db);
      return (
        outcome: MusicCoverageRunOutcome.noDictionary,
        knownAvailable: known,
      );
    }
    final List<MusicTrackRow> tracks = await db.listMusicTracks();
    final Map<String, MusicAlbumRow> albums = <String, MusicAlbumRow>{
      for (final MusicAlbumRow a in await db.select(db.musicAlbums).get())
        a.albumUid: a,
    };
    final Map<String, List<MusicLyricRow>> lyricRows = await _lyricRowsByTrack(
      db,
    );
    final Map<String, MusicLyricCoverageRow> existing =
        <String, MusicLyricCoverageRow>{
          for (final MusicLyricCoverageRow r
              in await db.select(db.musicLyricCoverage).get())
            r.trackUid: r,
        };
    // 孤儿行：曲目已不在曲库。
    final Set<String> live = <String>{
      for (final MusicTrackRow t in tracks) t.trackUid,
    };
    final List<String> orphans = <String>[
      for (final String uid in existing.keys)
        if (!live.contains(uid)) uid,
    ];
    if (orphans.isNotEmpty) {
      await (db.delete(
        db.musicLyricCoverage,
      )..where(($MusicLyricCoverageTable c) => c.trackUid.isIn(orphans))).go();
    }

    final int parserVersion = FushiLyrics.parserVersion;
    final List<MusicTrackRow> stale = <MusicTrackRow>[
      for (final MusicTrackRow t in tracks)
        if (force ||
            existing[t.trackUid]?.inputStamp !=
                musicCoverageInputStamp(
                  dictionaryStamp: dictStamp,
                  parserVersion: parserVersion,
                  trackMtimeAt: t.fileMtimeAt,
                  lyricRowsDigest: musicLyricRowsDigest(
                    lyricRows[t.trackUid] ?? const <MusicLyricRow>[],
                  ),
                ))
          t,
    ];

    bool cancelled = false;
    _progress.value = MusicCoverageProgress(running: true, total: stale.length);
    for (int start = 0; start < stale.length; start += _batchTracks) {
      if (_cancelRequested) {
        cancelled = true;
        break;
      }
      final List<MusicTrackRow> batch = stale.sublist(
        start,
        (start + _batchTracks).clamp(0, stale.length),
      );
      final bool ok = await _computeBatch(
        db,
        batch,
        albums,
        dictStamp: dictStamp,
        parserVersion: parserVersion,
      );
      if (!ok) {
        // 分词失败（词典正在重载 / 原生出错）：这批不落库，下次再算；不把它们记成「无词」。
        cancelled = true;
        break;
      }
      _progress.value = MusicCoverageProgress(
        running: true,
        done: start + batch.length,
        total: stale.length,
      );
    }
    final bool knownAvailable = await _refreshKnown(db);
    return (
      outcome: cancelled
          ? MusicCoverageRunOutcome.cancelled
          : MusicCoverageRunOutcome.completed,
      knownAvailable: knownAvailable,
    );
  }

  Future<Map<String, List<MusicLyricRow>>> _lyricRowsByTrack(
    FushiDatabase db, [
    Iterable<String>? trackUids,
  ]) async {
    final SimpleSelectStatement<$MusicLyricsTable, MusicLyricRow> q = db.select(
      db.musicLyrics,
    );
    if (trackUids != null) {
      q.where(($MusicLyricsTable l) => l.trackUid.isIn(trackUids));
    }
    final Map<String, List<MusicLyricRow>> out =
        <String, List<MusicLyricRow>>{};
    for (final MusicLyricRow r in await q.get()) {
      (out[r.trackUid] ??= <MusicLyricRow>[]).add(r);
    }
    return out;
  }

  /// 一批：逐首解析本地歌词 → 全部歌词行一次分词 → 写回。返回 false = 分词失败。
  Future<bool> _computeBatch(
    FushiDatabase db,
    List<MusicTrackRow> batch,
    Map<String, MusicAlbumRow> albums, {
    required String dictStamp,
    required int parserVersion,
  }) async {
    final List<List<String>> textsOf = <List<String>>[];
    for (final MusicTrackRow t in batch) {
      LyricTimeline? timeline;
      try {
        timeline = await _resolveLocal(
          musicLyricsTrackRefOfRow(
            t,
            album: t.albumUid == null ? null : albums[t.albumUid!],
          ),
        );
      } on Object catch (e, st) {
        // 单首歌的歌词文件坏了 / 读不到：记日志，这首按「无歌词」处理，不拖垮整批。
        ErrorLogService.instance.log('MusicLyricsCoverageIndex.resolve', e, st);
      }
      textsOf.add(
        timeline == null ? const <String>[] : musicCoverageTextsOf(timeline),
      );
    }
    final List<String> flat = <String>[
      for (final List<String> texts in textsOf) ...texts,
    ];
    List<List<FushiTermToken>>? tokens = const <List<FushiTermToken>>[];
    if (flat.isNotEmpty) {
      tokens = await _tokenize(flat);
      if (tokens == null || tokens.length != flat.length) return false;
    }
    // 解析歌词时 sidecar / 内嵌会落进 music_lyrics：指纹按解析之后的行算。
    final Map<String, List<MusicLyricRow>> rowsAfter = await _lyricRowsByTrack(
      db,
      <String>[for (final MusicTrackRow t in batch) t.trackUid],
    );
    final int now = _now();
    final List<MusicLyricCoverageCompanion> writes =
        <MusicLyricCoverageCompanion>[];
    int at = 0;
    for (int i = 0; i < batch.length; i++) {
      final MusicTrackRow t = batch[i];
      final List<String> texts = textsOf[i];
      final List<MusicCoverageTerm> terms = aggregateMusicCoverageTerms(
        texts,
        tokens.sublist(at, at + texts.length),
      );
      at += texts.length;
      final MusicCoverageStatus status = texts.isEmpty
          ? MusicCoverageStatus.noLyrics
          : terms.isEmpty
          ? MusicCoverageStatus.noTerms
          : MusicCoverageStatus.ok;
      int total = 0;
      for (final MusicCoverageTerm term in terms) {
        total += term.count;
      }
      writes.add(
        MusicLyricCoverageCompanion.insert(
          trackUid: t.trackUid,
          status: status.dbValue,
          inputStamp: musicCoverageInputStamp(
            dictionaryStamp: dictStamp,
            parserVersion: parserVersion,
            trackMtimeAt: t.fileMtimeAt,
            lyricRowsDigest: musicLyricRowsDigest(
              rowsAfter[t.trackUid] ?? const <MusicLyricRow>[],
            ),
          ),
          termsJson: Value<String>(encodeMusicCoverageTerms(terms)),
          totalTokens: Value<int>(total),
          uniqueTerms: Value<int>(terms.length),
          // 词变了：已知段作废，交给随后的重判。
          knownTokens: const Value<int?>(null),
          knownStamp: const Value<String?>(null),
          computedAt: now,
        ),
      );
    }
    await db.batch((Batch b) {
      for (final MusicLyricCoverageCompanion w in writes) {
        b.insert(db.musicLyricCoverage, w, mode: InsertMode.insertOrReplace);
      }
    });
    return true;
  }

  /// 按当前复习库重判已知段（只动快照指纹变了 / 没判过的行）。返回复习模块是否可用。
  Future<bool> _refreshKnown(FushiDatabase db) async {
    final SrsKnownTermSnapshot? snapshot;
    try {
      snapshot = await _knownSnapshot();
    } on Object catch (e, st) {
      ErrorLogService.instance.log('MusicLyricsCoverageIndex.known', e, st);
      return false;
    }
    if (snapshot == null) return false;
    final List<MusicLyricCoverageRow> rows =
        await (db.select(db.musicLyricCoverage)..where(
              ($MusicLyricCoverageTable c) =>
                  c.status.equals(MusicCoverageStatus.ok.dbValue) &
                  (c.knownStamp.isNull() |
                      c.knownStamp.equals(snapshot!.stamp).not()),
            ))
            .get();
    if (rows.isEmpty) return true;
    await db.batch((Batch b) {
      for (final MusicLyricCoverageRow r in rows) {
        b.update(
          db.musicLyricCoverage,
          MusicLyricCoverageCompanion(
            knownTokens: Value<int?>(
              musicKnownTokensOf(
                decodeMusicCoverageTerms(r.termsJson),
                snapshot!,
              ),
            ),
            knownStamp: Value<String?>(snapshot.stamp),
          ),
          where: ($MusicLyricCoverageTable c) => c.trackUid.equals(r.trackUid),
        );
      }
    });
    return true;
  }

  /// 只重判已知段（曲库页打开、复习库可能变过时）。
  Future<bool> refreshKnown() async {
    final FushiDatabase? db = _database();
    if (db == null) return false;
    return _refreshKnown(db);
  }

  void dispose() {
    cancel();
    _progress.dispose();
  }
}

/// 曲目行 → 解析歌词用的曲目信息（与播放项同口径：艺人缺省回落专辑艺人）。
MusicLyricsTrackRef musicLyricsTrackRefOfRow(
  MusicTrackRow track, {
  MusicAlbumRow? album,
}) {
  final MusicPlayItem item = musicPlayItemOf(track, album: album);
  return MusicLyricsTrackRef(
    trackUid: item.trackUid,
    path: item.path,
    title: item.title,
    artist: item.artist,
    album: item.album,
    durationMs: item.durationMs,
    cueStartMs: item.startMs,
  );
}

/// 进程级覆盖率索引（离开曲库页后台批处理照常跑完）。
final Provider<MusicLyricsCoverageIndex> musicLyricsCoverageIndexProvider =
    Provider<MusicLyricsCoverageIndex>((Ref ref) {
      final AppModel app = ref.read(appProvider);
      final MusicLyricsCoverageIndex index = MusicLyricsCoverageIndex(
        database: () => app.isDatabaseReady ? app.database : null,
        resolveLocal: (MusicLyricsTrackRef track) async =>
            (await app.musicLyrics.resolve(
              track,
              allowOnline: false,
            ))?.timeline,
        tokenize: (List<String> texts) => FushiDicts.isInitialized
            ? FushiDicts.instance.tokenizeTermsInBackground(texts)
            : Future<List<List<FushiTermToken>>?>.value(),
        dictionaryStamp: () => const FushiDictsCorpusNormalizer().signature,
        knownSnapshot: () async {
          final SrsDbStore? store = await ref.read(srsStoreProvider.future);
          return store?.knownTermSnapshot();
        },
      );
      ref.onDispose(index.dispose);
      return index;
    });
