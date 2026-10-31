/// 一首歌用哪份歌词（设计 §5.4）+ `music_lyrics` 落库（`timeline_cache` 二进制 + 版本）。
///
/// 优先级：① 用户手动指定（`is_user_edited`）→ ② 同目录 sidecar → ③ 文件内嵌 →
/// ④ LRCLIB（精确匹配；失败不自动采用模糊结果，由用户挑）。
///
/// - 解析与格式互转全在 Rust（`package:fushi_music`）；这里只做 IO 与编排；
/// - 在线结果只缓存进 DB，不写用户目录；「导出到文件旁边」是显式操作（[exportBesideAudio]）；
/// - CUE 虚拟曲目（整轨里的一段）不认同名 sidecar / 内嵌歌词：那些属于整张镜像，不属于这一首；
/// - 每个来源一行，各自记偏移；查不到的在线结果记一行 `format = none` 的负缓存，
///   [kLrclibNegativeCacheTtl] 内不再查。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:drift/drift.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_music/fushi_music.dart';

import 'package:fushi/src/media/music/lyrics/lrclib_client.dart';
import 'package:fushi/src/media/music/lyrics/lyrics_candidate_scoring.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_sources.dart';
import 'package:fushi/src/media/music/plugin/music_plugins.dart';

/// 负缓存（在线没查到）的有效期。
const Duration kLrclibNegativeCacheTtl = Duration(days: 7);

/// 插件说「这首没有歌词」后多久再问（平台常在发行后补歌词，比 LRCLIB 短）。
const Duration kPluginLyricsNegativeCacheTtl = Duration(days: 1);

/// 向在线音源插件要一首歌的歌词（app 装配：`MusicPluginManager.source(id).lyrics`）。
typedef MusicPluginLyricsFetcher =
    Future<MusicPluginLyrics?> Function(String pluginId, String trackId);

/// 向歌词插件搜候选（app 装配：`MusicPluginManager.source(id).lyricsSearch`）。
typedef MusicPluginLyricsSearcher =
    Future<List<MusicPluginLyricsCandidate>> Function(
      String pluginId,
      String title, {
      String? artist,
      String? album,
      int? durationMs,
      String? query,
    });

/// 按候选的 ref 向歌词插件取词（app 装配：`MusicPluginManager.source(id).lyricsFetch`）。
typedef MusicPluginLyricsRefFetcher =
    Future<MusicPluginLyrics?> Function(String pluginId, Object ref);

/// 已启用的歌词插件 id，按用户排序（LRCLIB 不在其中，固定最前）。
typedef MusicLyricsProviderIds = Future<List<String>> Function();

/// 插件歌词有译文时的落库格式：`raw` 是插件给的**原始各轨**（[MusicPluginLyrics.toJson] 的
/// JSON），不是合并后的派生物。合并规则随解析器版本变（如译文配对），缓存版本对不上时由
/// [parseStoredMusicLyrics] 用当前解析器从原始各轨就地重新合并——平台曲目自带歌词（③'）与
/// 歌词插件（⑤）共用这一条，不必回插件重取，也不会在旧合并结果上重解析而把旧错误留住。
const String kMusicPluginLyricsTracksFormat = 'plugin-tracks';

/// 插件歌词 → 落库原文 + 时间轴。有译文（`translation`）时按时间与原文配对、合进同一条时间轴，
/// 落库存原始各轨（[kMusicPluginLyricsTracksFormat]）；没有译文就原样存插件给的格式。
Future<({Uint8List raw, String format, LyricTimeline timeline})>
buildMusicPluginLyrics(
  MusicPluginLyrics lyrics,
  int? durationMs,
  Future<LyricTimeline> Function(Uint8List bytes, String hint, int? d) parse,
) async {
  final MusicPluginLyricText original = lyrics.original!;
  final Uint8List raw = utf8.encode(original.text);
  final LyricTimeline primary = await parse(raw, original.format, durationMs);
  final MusicPluginLyricText? tr = lyrics.translation;
  if (tr == null) {
    return (raw: raw, format: original.format, timeline: primary);
  }
  final LyricTimeline secondary = await parse(
    utf8.encode(tr.text),
    tr.format,
    durationMs,
  );
  final String lang = tr.language ?? 'zh-Hans';
  final LyricTimeline merged = await Isolate.run(
    () => FushiLyrics.mergeTranslation(primary, secondary, lang),
  );
  return (
    raw: utf8.encode(
      jsonEncode(
        MusicPluginLyrics(original: original, translation: tr).toJson(),
      ),
    ),
    format: kMusicPluginLyricsTracksFormat,
    timeline: merged,
  );
}

/// `music_lyrics` 一行（`raw` + `format`）→ 时间轴。所有读这张表的地方（歌词解析、语料索引）
/// 共用这一条，不各自猜解析提示：
/// - [kMusicPluginLyricsTracksFormat]：从插件原始各轨重新合并；
/// - 手动指定行的 raw 是 TTML（无损交换格式）——选的是 ASS 时除外：ASS 原文要留给 libass
///   原样渲染，按 ASS 解析；
/// - 其余按行记的格式解析。
///
/// 原始各轨解不开时抛 [LyricsParseException]（与格式解析失败同一类错误）。
Future<LyricTimeline> parseStoredMusicLyrics(
  Uint8List raw,
  String format, {
  required bool isUserEdited,
  required Future<LyricTimeline> Function(Uint8List bytes, String hint, int? d)
  parse,
  int? durationMs,
}) async {
  if (format == kMusicPluginLyricsTracksFormat) {
    final MusicPluginLyrics? tracks;
    try {
      tracks = MusicPluginLyrics.fromJson(jsonDecode(utf8.decode(raw)));
    } on FormatException catch (e) {
      throw LyricsParseException('plugin lyrics tracks: ${e.message}');
    }
    if (tracks == null) {
      throw const LyricsParseException('plugin lyrics tracks: no original');
    }
    return (await buildMusicPluginLyrics(tracks, durationMs, parse)).timeline;
  }
  return parse(
    raw,
    isUserEdited && !musicLyricsFormatIsAss(format) ? 'ttml' : format,
    durationMs,
  );
}

/// 负缓存行的 format。
const String kMusicLyricsNoneFormat = 'none';

/// 解析歌词所需的曲目信息。
class MusicLyricsTrackRef {
  const MusicLyricsTrackRef({
    required this.trackUid,
    required this.path,
    required this.title,
    this.artist,
    this.album,
    this.durationMs,
    this.cueStartMs,
  });

  final String trackUid;
  final String path;
  final String title;
  final String? artist;
  final String? album;
  final int? durationMs;

  /// CUE 虚拟曲目的起点；非 null 时不认 sidecar / 内嵌。
  final int? cueStartMs;

  bool get isCueTrack => cueStartMs != null;

  /// 这一首认不认同目录 sidecar / 文件内嵌歌词：CUE 虚拟曲目（那些属于整张镜像）与在线音源
  /// 插件曲目（[path] 是 `fushi-plugin` URI，不是本地文件）都不认。解析与选来源面板共用。
  bool get readsLocalLyrics =>
      !isCueTrack && parseMusicPluginTrackPath(path) == null;
}

/// 解析结果：生效的时间轴（已带该来源的偏移）+ 它来自哪个来源。
class MusicLyricsResolution {
  const MusicLyricsResolution({
    required this.timeline,
    required this.source,
    this.rawAss,
  });

  final LyricTimeline timeline;

  /// `music_lyrics.source`。
  final String source;

  /// 生效来源是 ASS / SSA 时的原文（原样渲染交给 libass，设计 §6.3）；其它格式为 null。
  final Uint8List? rawAss;
}

/// 格式名是 ASS / SSA（`music_lyrics.format` / 时间轴 format / sidecar 扩展名）。
bool musicLyricsFormatIsAss(String format) {
  final String f = format.toLowerCase();
  return f == 'ass' || f == 'ssa';
}

Uint8List? _assRawOf(String format, Uint8List raw) =>
    musicLyricsFormatIsAss(format) && raw.isNotEmpty ? raw : null;

/// 可供用户挑的一份候选（选来源面板）。
class MusicLyricsCandidate {
  const MusicLyricsCandidate({
    required this.source,
    required this.label,
    required this.format,
    required this.raw,
    required this.timeline,
  });

  final String source;

  /// 展示用（文件名 / LRCLIB 记录标题）。
  final String label;
  final String format;
  final Uint8List raw;
  final LyricTimeline timeline;
}

typedef _Sidecar = ({LyricTimeline timeline, Uint8List raw, String label});

/// 列目录（测试注入）。
typedef MusicLyricsDirLister = List<String> Function(String dir);

List<String> _listDirFiles(String dir) {
  try {
    return <String>[
      for (final FileSystemEntity e in Directory(dir).listSync())
        if (e is File) e.path,
    ];
  } on FileSystemException {
    return const <String>[];
  }
}

class MusicLyricsService {
  MusicLyricsService({
    required FushiDatabase? Function() database,
    required LrclibClient lrclib,
    required bool Function() onlineEnabled,
    MusicLyricsDirLister listDir = _listDirFiles,
    Future<List<EmbeddedLyrics>> Function(String path, int? durationMs)?
    readEmbedded,
    Future<LyricTimeline> Function(Uint8List bytes, String hint, int? durMs)?
    parse,
    int Function()? now,
    MusicPluginLyricsFetcher? pluginLyrics,
    MusicPluginLyricsSearcher? pluginSearch,
    MusicPluginLyricsRefFetcher? pluginFetch,
    MusicLyricsProviderIds? providers,
  }) : _database = database,
       _pluginLyrics = pluginLyrics,
       _pluginSearch = pluginSearch,
       _pluginFetch = pluginFetch,
       _providers = providers,
       _lrclib = lrclib,
       _onlineEnabled = onlineEnabled,
       _listDir = listDir,
       _readEmbedded =
           readEmbedded ??
           ((String p, int? d) => FushiLyricsAsync.embedded(p, durationMs: d)),
       _parse =
           parse ??
           ((Uint8List b, String h, int? d) =>
               FushiLyricsAsync.parse(b, hint: h, durationMs: d)),
       _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final FushiDatabase? Function() _database;
  final LrclibClient _lrclib;
  final bool Function() _onlineEnabled;
  final MusicLyricsDirLister _listDir;
  final Future<List<EmbeddedLyrics>> Function(String path, int? durationMs)
  _readEmbedded;
  final Future<LyricTimeline> Function(Uint8List bytes, String hint, int? d)
  _parse;
  final int Function() _now;
  final MusicPluginLyricsFetcher? _pluginLyrics;
  final MusicPluginLyricsSearcher? _pluginSearch;
  final MusicPluginLyricsRefFetcher? _pluginFetch;
  final MusicLyricsProviderIds? _providers;

  Future<List<MusicLyricRow>> _rows(FushiDatabase db, String trackUid) =>
      (db.select(
        db.musicLyrics,
      )..where(($MusicLyricsTable t) => t.trackUid.equals(trackUid))).get();

  /// 行 → 时间轴：缓存版本对得上就直接解码，否则从原文重解析并回写缓存。
  Future<LyricTimeline> _timelineOf(
    FushiDatabase db,
    MusicLyricRow row,
    int? durationMs,
  ) async {
    final Uint8List? cache = row.timelineCache;
    final int version = FushiLyrics.parserVersion;
    LyricTimeline t;
    if (cache != null && row.timelineVersion == version) {
      t = decodeLyricTimeline(cache);
    } else {
      // 手动指定的 ASS 行重建时按 ASS 解析（外挂翻译文件合并的结果此时不保留）；插件原始各轨
      // 按当前解析器重新合并。
      t = await parseStoredMusicLyrics(
        row.raw,
        row.format,
        isUserEdited: row.isUserEdited,
        parse: _parse,
        durationMs: durationMs,
      );
      t = t.copyWith(source: row.source, isUserEdited: row.isUserEdited);
      await _writeCache(db, row.trackUid, row.source, t);
    }
    return t.copyWith(source: row.source, offsetMs: row.offsetMs);
  }

  Future<void> _writeCache(
    FushiDatabase db,
    String trackUid,
    String source,
    LyricTimeline t,
  ) =>
      (db.update(db.musicLyrics)..where(
            ($MusicLyricsTable r) =>
                r.trackUid.equals(trackUid) & r.source.equals(source),
          ))
          .write(
            MusicLyricsCompanion(
              timelineCache: Value<Uint8List?>(encodeLyricTimeline(t)),
              timelineVersion: Value<int>(FushiLyrics.parserVersion),
              timingQuality: Value<String>(t.timingQuality.dbName),
            ),
          );

  /// 写 / 更新一个来源的行；偏移只在新行时取 0，已有行保留用户调过的偏移。
  Future<void> _upsert(
    FushiDatabase db, {
    required String trackUid,
    required String source,
    required String format,
    required Uint8List raw,
    LyricTimeline? timeline,
    bool isUserEdited = false,
    int? offsetMs,
  }) async {
    await db
        .into(db.musicLyrics)
        .insert(
          MusicLyricsCompanion.insert(
            trackUid: trackUid,
            source: source,
            format: format,
            raw: raw,
            timelineCache: Value<Uint8List?>(
              timeline == null ? null : encodeLyricTimeline(timeline),
            ),
            timelineVersion: Value<int>(
              timeline == null ? 0 : FushiLyrics.parserVersion,
            ),
            offsetMs: Value<int>(offsetMs ?? 0),
            timingQuality: Value<String>(
              timeline?.timingQuality.dbName ?? 'line',
            ),
            isUserEdited: Value<bool>(isUserEdited),
            updatedAt: _now(),
          ),
          onConflict: DoUpdate(
            (_) => MusicLyricsCompanion(
              format: Value<String>(format),
              raw: Value<Uint8List>(raw),
              timelineCache: Value<Uint8List?>(
                timeline == null ? null : encodeLyricTimeline(timeline),
              ),
              timelineVersion: Value<int>(
                timeline == null ? 0 : FushiLyrics.parserVersion,
              ),
              timingQuality: Value<String>(
                timeline?.timingQuality.dbName ?? 'line',
              ),
              isUserEdited: Value<bool>(isUserEdited),
              updatedAt: Value<int>(_now()),
              offsetMs: offsetMs == null
                  ? const Value<int>.absent()
                  : Value<int>(offsetMs),
            ),
          ),
        );
  }

  /// 按优先级解析一首歌的歌词；没有任何来源返回 null。网络错误不吞：在线查询失败时
  /// 已有的本地结果照常返回，没有本地结果时把异常抛给调用方（界面显示「在线查询失败」）。
  Future<MusicLyricsResolution?> resolve(MusicLyricsTrackRef track) async {
    final FushiDatabase? db = _database();
    if (db == null) return null;
    final List<MusicLyricRow> rows = await _rows(db, track.trackUid);
    MusicLyricRow? rowOf(String source) {
      for (final MusicLyricRow r in rows) {
        if (r.source == source) return r;
      }
      return null;
    }

    // ① 用户手动指定。
    for (final MusicLyricRow r in rows) {
      if (r.isUserEdited) {
        return MusicLyricsResolution(
          timeline: await _timelineOf(db, r, track.durationMs),
          source: r.source,
          rawAss: _assRawOf(r.format, r.raw),
        );
      }
    }

    // 在线音源插件曲目没有本地文件：不找 sidecar / 内嵌，先问插件。
    final ({String pluginId, String trackId})? plugin =
        parseMusicPluginTrackPath(track.path);

    // ② sidecar（每次重读：本地文件可能被用户换掉；Rust 解析远小于 IO 开销）。
    if (track.readsLocalLyrics) {
      final _Sidecar? side = await _readSidecars(track);
      if (side != null) {
        final MusicLyricRow? prev = rowOf(MusicLyricsSource.sidecar);
        await _upsert(
          db,
          trackUid: track.trackUid,
          source: MusicLyricsSource.sidecar,
          format: side.timeline.format,
          raw: side.raw,
          timeline: side.timeline,
        );
        return MusicLyricsResolution(
          timeline: side.timeline.copyWith(
            source: MusicLyricsSource.sidecar,
            offsetMs: prev?.offsetMs ?? 0,
          ),
          source: MusicLyricsSource.sidecar,
          rawAss: _assRawOf(side.timeline.format, side.raw),
        );
      }
    }

    // ③ 内嵌（读文件头在后台 isolate）。
    if (track.readsLocalLyrics) {
      final MusicLyricRow? prev = rowOf(MusicLyricsSource.embedded);
      final EmbeddedLyrics? emb = await _bestEmbedded(track);
      if (emb != null) {
        await _upsert(
          db,
          trackUid: track.trackUid,
          source: MusicLyricsSource.embedded,
          format: emb.format,
          raw: emb.raw,
          timeline: emb.timeline,
        );
        return MusicLyricsResolution(
          timeline: emb.timeline.copyWith(
            source: MusicLyricsSource.embedded,
            offsetMs: prev?.offsetMs ?? 0,
          ),
          source: MusicLyricsSource.embedded,
          rawAss: _assRawOf(emb.format, emb.raw),
        );
      }
    }

    // ③' 插件自带歌词（逐字歌词等）：缓存（含负缓存）→ 问插件。插件报错不吞成
    // 「没有歌词」：不写负缓存，继续往 LRCLIB 回落。
    final MusicPluginLyricsFetcher? fetchPlugin = _pluginLyrics;
    if (plugin != null && fetchPlugin != null) {
      final String source = MusicLyricsSource.plugin(plugin.pluginId);
      final MusicLyricRow? prev = rowOf(source);
      final bool hasLyrics =
          prev != null && prev.format != kMusicLyricsNoneFormat;
      // 现在落库的是插件原始各轨（[kMusicPluginLyricsTracksFormat]），版本变了由 _timelineOf
      // 就地重新合并。早期版本落的是「原文 + 翻译合并后」的派生 TTML：只重解析这份 TTML 修不好
      // 旧合并结果，这种旧行版本对不上时回插件取原始两轨重新合并（之后就按原始各轨落库）。
      final bool mergedByOldParser =
          hasLyrics &&
          prev.format != kMusicPluginLyricsTracksFormat &&
          prev.timelineVersion != FushiLyrics.parserVersion;
      if (hasLyrics && !mergedByOldParser) {
        return MusicLyricsResolution(
          timeline: await _timelineOf(db, prev, track.durationMs),
          source: source,
        );
      }
      final bool stale =
          prev == null ||
          mergedByOldParser ||
          _now() - prev.updatedAt >=
              kPluginLyricsNegativeCacheTtl.inMilliseconds;
      if (stale) {
        MusicPluginLyrics? got;
        bool failed = false;
        try {
          got = await fetchPlugin(plugin.pluginId, plugin.trackId);
        } on MusicPluginException {
          failed = true;
        }
        if (got != null) {
          final ({Uint8List raw, String format, LyricTimeline timeline}) built =
              await buildMusicPluginLyrics(got, track.durationMs, _parse);
          final LyricTimeline t = built.timeline.copyWith(source: source);
          await _upsert(
            db,
            trackUid: track.trackUid,
            source: source,
            format: built.format,
            raw: built.raw,
            timeline: t,
          );
          // 重取旧缓存时保留用户调过的偏移（_upsert 不动已有行的偏移）。
          return MusicLyricsResolution(
            timeline: t.copyWith(offsetMs: prev?.offsetMs ?? 0),
            source: source,
          );
        }
        if (mergedByOldParser) {
          // 这次没取到原始两轨（离线 / 插件报错 / 平台临时没给）：先用旧合并结果顶上，
          // 不回写缓存版本，下次解析仍会再问插件。
          final LyricTimeline old = await _parse(
            prev.raw,
            prev.format,
            track.durationMs,
          );
          return MusicLyricsResolution(
            timeline: old.copyWith(source: source, offsetMs: prev.offsetMs),
            source: source,
          );
        }
        if (!failed) {
          await _upsert(
            db,
            trackUid: track.trackUid,
            source: source,
            format: kMusicLyricsNoneFormat,
            raw: Uint8List(0),
          );
        }
      }
    }

    // ④ LRCLIB（固定第一）→ ⑤ 已启用的歌词插件按用户排序，第一个命中的胜出。
    // LRCLIB 联网失败不挡后面的插件：记下异常，插件也没结果时再抛给调用方。
    Object? lrclibError;
    StackTrace? lrclibStack;
    try {
      final MusicLyricsResolution? viaLrclib = await _resolveLrclib(
        db,
        track,
        rowOf(MusicLyricsSource.lrclib),
      );
      if (viaLrclib != null) return viaLrclib;
    } on Exception catch (e, st) {
      lrclibError = e;
      lrclibStack = st;
    }
    final MusicLyricsResolution? viaPlugins = await _resolvePluginProviders(
      db,
      track,
      rowOf,
    );
    if (viaPlugins != null) return viaPlugins;
    if (lrclibError != null) {
      Error.throwWithStackTrace(lrclibError, lrclibStack!);
    }
    return null;
  }

  /// LRCLIB：先看缓存（含负缓存），再按需在线查。
  Future<MusicLyricsResolution?> _resolveLrclib(
    FushiDatabase db,
    MusicLyricsTrackRef track,
    MusicLyricRow? cached,
  ) async {
    if (cached != null) {
      if (cached.format != kMusicLyricsNoneFormat) {
        return MusicLyricsResolution(
          timeline: await _timelineOf(db, cached, track.durationMs),
          source: MusicLyricsSource.lrclib,
        );
      }
      if (_now() - cached.updatedAt < kLrclibNegativeCacheTtl.inMilliseconds) {
        return null;
      }
    }
    if (!_onlineEnabled() || (track.artist ?? '').trim().isEmpty) return null;
    final LrclibRecord? hit = await _lrclib.get(
      title: track.title,
      artist: track.artist!,
      album: track.album,
      durationMs: track.durationMs,
    );
    final ({String raw, String format})? best = hit?.bestLyrics;
    if (best == null) {
      await _upsert(
        db,
        trackUid: track.trackUid,
        source: MusicLyricsSource.lrclib,
        format: kMusicLyricsNoneFormat,
        raw: Uint8List(0),
      );
      return null;
    }
    final Uint8List raw = utf8.encode(best.raw);
    final LyricTimeline t = (await _parse(
      raw,
      best.format,
      track.durationMs,
    )).copyWith(source: MusicLyricsSource.lrclib);
    await _upsert(
      db,
      trackUid: track.trackUid,
      source: MusicLyricsSource.lrclib,
      format: best.format,
      raw: raw,
      timeline: t,
    );
    return MusicLyricsResolution(
      timeline: t.copyWith(offsetMs: cached?.offsetMs ?? 0),
      source: MusicLyricsSource.lrclib,
    );
  }

  /// 歌词插件来源：按用户排序逐个「缓存（含负缓存）→ lyricsSearch → 评分挑 → lyricsFetch」，
  /// 第一个拿到歌词的胜出。插件报错只跳过它（不写负缓存），不影响后面的插件。
  ///
  /// 缓存键是 [MusicLyricsSource.lyricsPlugin]，与平台曲目自带歌词（③'，
  /// [MusicLyricsSource.plugin]）分开；缓存命中走 [_timelineOf]，与 ③' 同一条新鲜度判断
  /// （原始各轨按当前解析器重新合并）。
  Future<MusicLyricsResolution?> _resolvePluginProviders(
    FushiDatabase db,
    MusicLyricsTrackRef track,
    MusicLyricRow? Function(String source) rowOf,
  ) async {
    final MusicLyricsProviderIds? listProviders = _providers;
    final MusicPluginLyricsSearcher? search = _pluginSearch;
    final MusicPluginLyricsRefFetcher? fetch = _pluginFetch;
    if (listProviders == null || search == null || fetch == null) return null;
    final List<String> ids = await listProviders();
    for (final String id in ids) {
      final String source = MusicLyricsSource.lyricsPlugin(id);
      final MusicLyricRow? prev = rowOf(source);
      if (prev != null) {
        if (prev.format != kMusicLyricsNoneFormat) {
          return MusicLyricsResolution(
            timeline: await _timelineOf(db, prev, track.durationMs),
            source: source,
          );
        }
        if (_now() - prev.updatedAt <
            kPluginLyricsNegativeCacheTtl.inMilliseconds) {
          continue;
        }
      }
      if (!_onlineEnabled()) continue;
      try {
        final MusicPluginLyrics? got = await _searchAndFetch(
          id,
          track,
          search,
          fetch,
        );
        if (got == null) {
          await _upsert(
            db,
            trackUid: track.trackUid,
            source: source,
            format: kMusicLyricsNoneFormat,
            raw: Uint8List(0),
          );
          continue;
        }
        final ({Uint8List raw, String format, LyricTimeline timeline}) built =
            await buildMusicPluginLyrics(got, track.durationMs, _parse);
        final LyricTimeline t = built.timeline.copyWith(source: source);
        await _upsert(
          db,
          trackUid: track.trackUid,
          source: source,
          format: built.format,
          raw: built.raw,
          timeline: t,
        );
        return MusicLyricsResolution(
          timeline: t.copyWith(offsetMs: prev?.offsetMs ?? 0),
          source: source,
        );
      } on MusicPluginException {
        continue;
      } on LyricsParseException {
        continue;
      }
    }
    return null;
  }

  Future<MusicPluginLyrics?> _searchAndFetch(
    String pluginId,
    MusicLyricsTrackRef track,
    MusicPluginLyricsSearcher search,
    MusicPluginLyricsRefFetcher fetch,
  ) async {
    final Map<String, MusicPluginLyricsCandidate> byKey =
        <String, MusicPluginLyricsCandidate>{};
    final List<LyricsCandidate> all = await searchWithFallbackQueries(
      title: track.title,
      artist: track.artist,
      durationMs: track.durationMs,
      run: (String q) async {
        final List<MusicPluginLyricsCandidate> items = await search(
          pluginId,
          track.title,
          artist: track.artist,
          album: track.album,
          durationMs: track.durationMs,
          query: q,
        );
        final List<LyricsCandidate> out = <LyricsCandidate>[];
        for (final MusicPluginLyricsCandidate c in items) {
          final String key = jsonEncode(c.ref);
          byKey[key] = c;
          out.add(
            LyricsCandidate(
              providerId: pluginId,
              title: c.title,
              artist: c.artist ?? '',
              durationMs: c.durationMs,
              ref: <String, String>{'k': key},
            ),
          );
        }
        return out;
      },
    );
    final LyricsCandidate? best = pickBestLyricsCandidate(
      all,
      title: track.title,
      artist: track.artist,
      durationMs: track.durationMs,
    );
    if (best == null) return null;
    final MusicPluginLyrics? lyrics = await fetch(
      pluginId,
      byKey[best.ref['k']]!.ref,
    );
    return lyrics?.original == null ? null : lyrics;
  }

  Future<_Sidecar?> _readSidecars(MusicLyricsTrackRef track) async {
    final String dir = File(track.path).parent.path;
    final List<String> siblings = _listDir(dir);
    final LyricSidecarSet set = pickLyricSidecars(track.path, siblings);
    final LyricSidecarFile? primary =
        set.primary ?? await _ultraStarByHeader(track.path, siblings);
    if (primary == null) return null;
    final Uint8List raw;
    try {
      raw = await File(primary.path).readAsBytes();
    } on FileSystemException {
      return null;
    }
    LyricTimeline t;
    try {
      t = await _parse(raw, primary.ext, track.durationMs);
    } on LyricsParseException {
      return null;
    }
    for (final LyricSidecarFile tr in set.translations) {
      try {
        final LyricTimeline sec = await _parse(
          await File(tr.path).readAsBytes(),
          tr.ext,
          track.durationMs,
        );
        t = FushiLyrics.mergeTranslation(t, sec, tr.translationLang!);
      } on LyricsParseException {
        continue;
      } on FileSystemException {
        continue;
      }
    }
    return (
      timeline: t,
      raw: raw,
      label: File(primary.path).uri.pathSegments.last,
    );
  }

  /// UltraStar 歌曲包：主名不同、头部 `#MP3:` / `#AUDIO:` 指向这首音频的 `.txt`。
  Future<LyricSidecarFile?> _ultraStarByHeader(
    String audioPath,
    List<String> siblings,
  ) async {
    final String audioName = File(audioPath).uri.pathSegments.last;
    for (final String p in ultraStarCandidates(audioPath, siblings)) {
      final List<int> head;
      try {
        final RandomAccessFile f = await File(p).open();
        try {
          head = await f.read(kUltraStarHeadBytes);
        } finally {
          await f.close();
        }
      } on FileSystemException {
        continue;
      }
      final String? ref = ultraStarAudioReference(
        utf8.decode(head, allowMalformed: true),
      );
      if (ref != null && ref.toLowerCase() == audioName.toLowerCase()) {
        return LyricSidecarFile(path: p, ext: 'ultrastar');
      }
    }
    return null;
  }

  Future<EmbeddedLyrics?> _bestEmbedded(MusicLyricsTrackRef track) async {
    try {
      return pickBestEmbedded(
        await _readEmbedded(track.path, track.durationMs),
      );
    } on LyricsParseException {
      return null;
    }
  }

  /// 选来源面板：列出所有本地候选（sidecar 正文、各条内嵌、缓存的 LRCLIB 结果）。
  Future<List<MusicLyricsCandidate>> localCandidates(
    MusicLyricsTrackRef track,
  ) async {
    final List<MusicLyricsCandidate> out = <MusicLyricsCandidate>[];
    if (track.readsLocalLyrics) {
      final _Sidecar? side = await _readSidecars(track);
      if (side != null) {
        out.add(
          MusicLyricsCandidate(
            source: MusicLyricsSource.sidecar,
            label: side.label,
            format: side.timeline.format,
            raw: side.raw,
            timeline: side.timeline,
          ),
        );
      }
      try {
        for (final EmbeddedLyrics e in await _readEmbedded(
          track.path,
          track.durationMs,
        )) {
          out.add(
            MusicLyricsCandidate(
              source: MusicLyricsSource.embedded,
              label: e.key,
              format: e.format,
              raw: e.raw,
              timeline: e.timeline,
            ),
          );
        }
      } on LyricsParseException {
        // 文件读不了：没有内嵌候选。
      }
    }
    final FushiDatabase? db = _database();
    if (db != null) {
      for (final MusicLyricRow r in await _rows(db, track.trackUid)) {
        if (r.format == kMusicLyricsNoneFormat) continue;
        // 插件来源的标签是插件 id；平台曲目自带歌词与歌词插件搜到的是两种来源，界面按
        // [MusicLyricsCandidate.source] 再标出是哪一种。
        final String? label = r.source == MusicLyricsSource.lrclib
            ? 'LRCLIB'
            : MusicLyricsSource.pluginIdOf(r.source) ??
                  MusicLyricsSource.lyricsPluginIdOf(r.source);
        if (label == null) continue;
        final LyricTimeline timeline = await _timelineOf(
          db,
          r,
          track.durationMs,
        );
        out.add(
          MusicLyricsCandidate(
            source: r.source,
            label: label,
            // 原始各轨不是歌词格式：展示合并后时间轴的格式（[choose] 存 TTML）。
            format: r.format == kMusicPluginLyricsTracksFormat
                ? timeline.format
                : r.format,
            raw: r.raw,
            timeline: timeline,
          ),
        );
      }
    }
    return out;
  }

  /// 在线模糊搜索（用户点「搜索在线歌词」时）：返回候选，不落库。
  Future<List<MusicLyricsCandidate>> searchOnline(
    MusicLyricsTrackRef track, {
    String? title,
    String? artist,
  }) async {
    final List<LrclibRecord> records = await _lrclib.search(
      title: title ?? track.title,
      artist: artist ?? track.artist,
      durationMs: track.durationMs,
    );
    final List<MusicLyricsCandidate> out = <MusicLyricsCandidate>[];
    for (final LrclibRecord r in records) {
      final ({String raw, String format})? best = r.bestLyrics;
      if (best == null) continue;
      final Uint8List raw = utf8.encode(best.raw);
      out.add(
        MusicLyricsCandidate(
          source: MusicLyricsSource.lrclib,
          label: '${r.trackName} — ${r.artistName}',
          format: best.format,
          raw: raw,
          timeline: await _parse(raw, best.format, track.durationMs),
        ),
      );
    }
    return out;
  }

  /// 用户挑定一份候选：写成 `user` 行（`is_user_edited` = 手动指定，永远最高）。原文存
  /// TTML（无损交换格式，翻译合并后的结果也一并保住）；ASS / SSA 候选例外，原文照存——
  /// 字幕组特效要交给 libass 原样渲染，转成 TTML 会全部丢掉（设计 §6.3）。
  ///
  /// 只有「选来源」这一条写入口：所有者 2026-10-24 拍板不做歌词编辑（改字 / 翻译 /
  /// 注音 / 单行偏移），这里不接受任意改过的时间轴。
  Future<void> choose(String trackUid, MusicLyricsCandidate candidate) async {
    final FushiDatabase? db = _database();
    if (db == null) return;
    final LyricTimeline t = candidate.timeline.copyWith(
      source: MusicLyricsSource.user,
      isUserEdited: true,
    );
    final bool ass = musicLyricsFormatIsAss(candidate.format);
    await _upsert(
      db,
      trackUid: trackUid,
      source: MusicLyricsSource.user,
      format: ass ? candidate.format.toLowerCase() : 'ttml',
      raw: ass
          ? candidate.raw
          : FushiLyrics.export(t.copyWith(offsetMs: 0), 'ttml'),
      timeline: t.copyWith(offsetMs: 0),
      isUserEdited: true,
      offsetMs: candidate.timeline.offsetMs,
    );
  }

  /// 撤销手动指定，回到自动优先级。
  Future<void> clearUserEdit(String trackUid) async {
    final FushiDatabase? db = _database();
    if (db == null) return;
    await (db.delete(db.musicLyrics)..where(
          ($MusicLyricsTable r) =>
              r.trackUid.equals(trackUid) &
              r.source.equals(MusicLyricsSource.user),
        ))
        .go();
  }

  /// 整首偏移（实时生效由界面负责，这里持久化）。
  Future<void> setOffset(String trackUid, String source, int offsetMs) async {
    final FushiDatabase? db = _database();
    if (db == null) return;
    await (db.update(db.musicLyrics)..where(
          ($MusicLyricsTable r) =>
              r.trackUid.equals(trackUid) & r.source.equals(source),
        ))
        .write(MusicLyricsCompanion(offsetMs: Value<int>(offsetMs)));
  }

  /// 显式操作：把时间轴导出到音频文件旁边（`<主名>.<ext>`），返回写出的路径。
  /// 已存在同名文件时不覆盖，抛 [FileSystemException]（由界面问用户）。
  Future<String> exportBesideAudio(
    MusicLyricsTrackRef track,
    LyricTimeline timeline,
    String format, {
    bool overwrite = false,
  }) async {
    final File audio = File(track.path);
    final String name = audio.uri.pathSegments.last;
    final int dot = name.lastIndexOf('.');
    final String stem = dot <= 0 ? name : name.substring(0, dot);
    final File out = File(
      '${audio.parent.path}${Platform.pathSeparator}$stem.$format',
    );
    if (!overwrite && out.existsSync()) {
      throw FileSystemException('lyrics file already exists', out.path);
    }
    await out.writeAsBytes(FushiLyrics.export(timeline, format), flush: true);
    return out.path;
  }
}
