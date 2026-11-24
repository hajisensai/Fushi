/// 一首歌用哪份歌词（设计 §5.4）+ `music_lyrics` 落库（`timeline_cache` 二进制 + 版本）。
///
/// 优先级：① 用户手动指定（`is_user_edited`）→ ② 同目录 sidecar → ③ 文件内嵌 →
/// ③' 媒体服务器存的歌词（服务器曲目）/ 插件自带歌词 →
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
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/server/music_server.dart'
    show MusicHostLyrics, MusicHostLyricsLayer, MusicServerLyrics;
import 'package:fushi_music/fushi_music.dart';

import 'package:fushi/src/media/music/lyrics/lrclib_client.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_auto_sync.dart';
import 'package:fushi_asr_subtitles/asr_subtitles.dart' show LyricsAlignment;
import 'package:fushi/src/media/music/lyrics/lyrics_candidate_scoring.dart';
import 'package:fushi_engine/media/music/lyrics/music_local_lyrics.dart';
import 'package:fushi_engine/media/music/lyrics/music_lyrics_sources.dart';

export 'package:fushi_engine/media/music/lyrics/music_lyrics_sources.dart'
    show kMusicLyricsNoneFormat, preferredMusicLyricRow;
import 'package:fushi/src/media/music/plugin/music_plugins.dart';

/// 负缓存（在线没查到）的有效期。
const Duration kLrclibNegativeCacheTtl = Duration(days: 7);

/// 插件说「这首没有歌词」后多久再问（平台常在发行后补歌词，比 LRCLIB 短）。
const Duration kPluginLyricsNegativeCacheTtl = Duration(days: 1);

/// 歌词插件里书写系统对不上时，同一插件最多再取几条同名候选找原文版（含第一条；
/// 插件候选不带正文，只能逐条取来看）。
const int kPluginLyricsScriptProbeLimit = 3;

/// 向在线音源插件要一首歌的歌词（app 装配：`MusicPluginManager.source(id).lyrics`）。
typedef MusicPluginLyricsFetcher =
    Future<MusicPluginLyrics?> Function(String pluginId, String trackId);

/// 服务器曲目的歌词（app 装配：播放项经 `MusicServerTrackResolver` 认回服务器后问
/// `MusicServerLyricsProvider.lyricsFor`）。不是服务器曲目（或那台服务器不存歌词）回 null；
/// 是服务器曲目时回 `(lyrics: …)`，`lyrics` 为 null = 服务器上这首没有歌词。网络 / 服务器
/// 错误抛（不写负缓存，回落到在线来源）。
typedef MusicServerLyricsFetcher =
    Future<({MusicServerLyrics? lyrics})?> Function(
      String trackUid,
      String path,
    );

/// 服务器说「这首没有歌词」后多久再问（管理员会补 .lrc / 装歌词插件，与插件同档）。
const Duration kServerLyricsNegativeCacheTtl = Duration(days: 1);

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

/// 已启用的在线歌词来源，按用户排序：[MusicLyricsSource.lrclib] 或歌词插件 id
/// （app 装配：`enabledLyricsProviderIds(mergeLyricsSourceList(...))`）。
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
/// - 其余按行记的格式解析。手动指定行的 `format` 记的就是原文的真实格式：选来源存 TTML
///   （ASS / SSA 原样）、纯文本歌词自动对时存 LRC（[kMusicLyricsAutoSyncFormat]）。
///
/// 原始各轨解不开时抛 [LyricsParseException]（与格式解析失败同一类错误）。
Future<LyricTimeline> parseStoredMusicLyrics(
  Uint8List raw,
  String format, {
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
  return parse(raw, format, durationMs);
}

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
  bool get readsLocalLyrics => !isCueTrack && isLocalFile;

  /// [path] 是本机文件路径：不是任何 `scheme://` 地址（插件 `fushi-music-plugin://`、
  /// 服务器曲库 / 网络音乐来源的 http(s) / `sftp://` 条目、`cdda://`）。只有本机文件才有
  /// 同目录 sidecar、内嵌标签可读，也才能「导出到文件旁边」（反馈 QAondMh4M5）。
  bool get isLocalFile => !_uriScheme.hasMatch(path);

  static final RegExp _uriScheme = RegExp(r'^[A-Za-z][A-Za-z0-9+.\-]+://');
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

  /// 正文的主导书写系统（界面据此标出「日文 / 拉丁字母」，区分原文版与罗马音版）。
  LyricsScript? get script =>
      lyricsScriptProfile(musicLyricsTimelineText(timeline)).dominant;
}

/// 时间轴各行正文拼成一段（判书写系统用）。
String musicLyricsTimelineText(LyricTimeline t) =>
    t.lines.map((LyricLine l) => l.text).join('\n');

/// 一个在线来源（LRCLIB / 歌词插件）的解析结果；[scriptMismatch] = 歌词书写系统与曲目
/// 元数据对不上（罗马音 / 翻译版）又没挑到原文版：只当兜底，所有在线来源都没有对得上的
/// 才用它（兜底之间按用户排的来源顺序取最靠前的）。
typedef _OnlineOutcome = ({
  MusicLyricsResolution resolution,
  bool scriptMismatch,
});

/// 歌词插件取到并解析好的一份歌词；[scriptMismatch] 同 [_OnlineOutcome]。
typedef _PluginFetched = ({
  Uint8List raw,
  String format,
  LyricTimeline timeline,
  bool scriptMismatch,
});

typedef _Sidecar = ({LyricTimeline timeline, Uint8List raw, String label});

/// 列目录（测试注入）。
typedef MusicLyricsDirLister = MusicLocalLyricsDirLister;

/// [audioPath] 旁的 [path] 是不是本机字幕管线（视频库「生成日语字幕」的旧产物，
/// `<主名>.ja.srt`）写的。生产接 `isDefaultVideoSubtitlePipelineOutput`。
typedef MusicGeneratedSidecarCheck =
    Future<bool> Function(String audioPath, String path);

/// 一首要写手动指定的曲目（[MusicLyricsService.chooseFileForTracks]）：CUE 虚拟曲目带
/// 区间（`[cueStartMs, cueEndMs)`，end 为 null = 到文件尾），普通曲目两者都为 null。
typedef MusicLyricsFileTrack = ({
  String trackUid,
  int? cueStartMs,
  int? cueEndMs,
  int? durationMs,
});

class MusicLyricsService {
  MusicLyricsService({
    required FushiDatabase? Function() database,
    required LrclibClient lrclib,
    required bool Function() onlineEnabled,
    MusicLyricsDirLister listDir = listMusicDirFiles,
    MusicEmbeddedLyricsReader? readEmbedded,
    Future<LyricTimeline> Function(Uint8List bytes, String hint, int? durMs)?
    parse,
    int Function()? now,
    MusicServerLyricsFetcher? serverLyrics,
    MusicPluginLyricsFetcher? pluginLyrics,
    MusicPluginLyricsSearcher? pluginSearch,
    MusicPluginLyricsRefFetcher? pluginFetch,
    MusicLyricsProviderIds? providers,
    MusicGeneratedSidecarCheck? isGeneratedSidecar,
    MusicHostLyricsLayer? hostLyrics,
  }) : _database = database,
       _hostLyrics = hostLyrics,
       _isGeneratedSidecar = isGeneratedSidecar,
       _serverLyrics = serverLyrics,
       _pluginLyrics = pluginLyrics,
       _pluginSearch = pluginSearch,
       _pluginFetch = pluginFetch,
       _providers = providers,
       _lrclib = lrclib,
       _onlineEnabled = onlineEnabled,
       _local = MusicLocalLyrics(listDir: listDir, readEmbedded: readEmbedded),
       _parse =
           parse ??
           ((Uint8List b, String h, int? d) =>
               FushiLyricsAsync.parse(b, hint: h, durationMs: d)),
       _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final FushiDatabase? Function() _database;
  final LrclibClient _lrclib;
  final bool Function() _onlineEnabled;

  /// 本地歌词层（sidecar 选取 + 内嵌），与互联 host 共用（BUG-5300）。
  final MusicLocalLyrics _local;
  final Future<LyricTimeline> Function(Uint8List bytes, String hint, int? d)
  _parse;
  final int Function() _now;
  final MusicServerLyricsFetcher? _serverLyrics;
  final MusicPluginLyricsFetcher? _pluginLyrics;
  final MusicPluginLyricsSearcher? _pluginSearch;
  final MusicPluginLyricsRefFetcher? _pluginFetch;
  final MusicLyricsProviderIds? _providers;
  final MusicGeneratedSidecarCheck? _isGeneratedSidecar;

  /// 互联 host 曲目的歌词层（design-imusic-q3 选 c：host 上生效的那份为准，本机的修改写回）。
  final MusicHostLyricsLayer? _hostLyrics;

  /// 解析过的互联 host 曲目：trackUid → 播放路径（[setOffset] / [choose] 据此写回 host）。
  final Map<String, String> _hostPaths = <String, String>{};

  final StreamController<String> _generated =
      StreamController<String>.broadcast();

  /// [saveGenerated] 写完一首就发它的 trackUid（等着这份转录的纯文本歌词自动对时跑完后
  /// 再发一次）：歌词页 / 桌面歌词正显示这首时重载（生成任务常在页面关掉之后才结束）。
  Stream<String> get generatedUpdates => _generated.stream;

  /// 等转录的纯文本歌词自动对时（[autoSyncWhenGenerated]）：trackUid → 曲目与歌词。只在
  /// 内存里（重启后再点一次即可，转录已经在库里，直接对）。
  final Map<String, ({MusicLyricsTrackRef track, LyricTimeline plain})>
  _pendingAutoSync =
      <String, ({MusicLyricsTrackRef track, LyricTimeline plain})>{};

  final StreamController<MusicLyricsAutoSyncEvent> _autoSyncResults =
      StreamController<MusicLyricsAutoSyncEvent>.broadcast();

  /// 后台自动对时（转录完成后才跑的那种）的结果：界面据此提示「对好了 / 对不上」。
  Stream<MusicLyricsAutoSyncEvent> get autoSyncResults =>
      _autoSyncResults.stream;

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

    // ⓪ 互联 host 曲目：host 上生效的那份（含 host 上的手动指定与偏移）为准，落一份本机缓存；
    // host 离线 / 没有歌词时退回本机已有的行与在线查询。
    final MusicHostLyricsLayer? hostLayer = _hostLyrics;
    if (hostLayer != null && hostLayer.handles(track.path)) {
      _hostPaths[track.trackUid] = track.path;
      MusicHostLyrics? remote;
      try {
        remote = await hostLayer.lyricsFor(track.path);
      } on Object catch (e) {
        debugPrint('[music-lyrics] host lyrics failed: $e');
      }
      if (remote != null && remote.raw.isNotEmpty) {
        final LyricTimeline t = await _writeHostLyrics(
          db,
          trackUid: track.trackUid,
          durationMs: track.durationMs,
          lyrics: remote,
        );
        final Uint8List raw = Uint8List.fromList(remote.raw);
        return MusicLyricsResolution(
          timeline: t.copyWith(
            source: remote.source,
            offsetMs: remote.offsetMs,
          ),
          source: remote.source,
          rawAss: _assRawOf(remote.format, raw),
        );
      }
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

    // ② sidecar（每次重读：本地文件可能被用户换掉；Rust 解析远小于 IO 开销）。本机字幕
    // 管线以前写在音频旁的 `<主名>.ja.srt` 已有对应的 `asr` 行（存量迁移转过来、或在音乐库
    // 重新生成过）时不当 sidecar：它是生成字幕那一档的旧副本，否则重新生成之后仍显示
    // 旧稿（sidecar 档位高于 asr）。
    if (track.readsLocalLyrics) {
      final bool skipGenerated = _hasGenerated(rowOf(MusicLyricsSource.asr));
      final _Sidecar? side = await _readSidecars(
        track,
        skipGenerated: skipGenerated,
      );
      if (side == null &&
          skipGenerated &&
          rowOf(MusicLyricsSource.sidecar) != null) {
        // 以前把那份旧产物当 sidecar 缓存过：删掉，语料对账（[preferredMusicLyricRow]，
        // sidecar 档位高于 asr）才会跟着改用生成字幕，搜到的与显示的是同一份。
        await (db.delete(db.musicLyrics)..where(
              ($MusicLyricsTable r) =>
                  r.trackUid.equals(track.trackUid) &
                  r.source.equals(MusicLyricsSource.sidecar),
            ))
            .go();
      }
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

    // ③'' 本机生成的字幕（[MusicLyricsSource.asr]，只读库、不联网）：广播剧 CD 等
    // 没有文件自带歌词的曲目，生成后就用它；CUE 虚拟曲目也有（按曲目区间切好入库）。
    final MusicLyricRow? generated = rowOf(MusicLyricsSource.asr);
    if (generated != null && generated.format != kMusicLyricsNoneFormat) {
      return MusicLyricsResolution(
        timeline: await _timelineOf(db, generated, track.durationMs),
        source: MusicLyricsSource.asr,
      );
    }

    // ③' 媒体服务器存的歌词（Jellyfin `/Audio/{id}/Lyrics`、OpenSubsonic
    // `getLyricsBySongId`）：服务器曲目没有本地文件，服务器读到的 .lrc / 内嵌歌词就是
    // 「文件自带」那一档，排在在线搜索前。缓存（含负缓存）→ 问服务器；服务器报错不写负缓存，
    // 继续往在线来源回落。
    final MusicServerLyricsFetcher? fetchServer = _serverLyrics;
    // 离线副本（本机文件、uid 仍在服务器曲目命名空间 `srv`）也走这一档：下载时存下的那行
    // 直接用，服务器不在也有歌词。
    if (fetchServer != null &&
        !track.isCueTrack &&
        (!track.isLocalFile || track.trackUid.startsWith('srv'))) {
      final MusicLyricsResolution? hit = await _resolveServerLyrics(
        db,
        track,
        rowOf(MusicLyricsSource.server),
        fetchServer,
      );
      if (hit != null) return hit;
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

    // ④ 在线来源：LRCLIB 与已启用的歌词插件同在一份用户排好的有序列表里（[_providers]），
    // 按顺序逐个问，第一个书写系统对得上的胜出，后面的不问。
    // LRCLIB 联网失败不挡后面的来源：记下异常，其余来源也没结果时再抛给调用方。
    // 书写系统对不上的版本（罗马音 / 翻译）只当兜底：所有来源都没有对得上的才用，
    // 兜底之间也按列表顺序取最靠前的。
    final LyricsScriptExpectation? expected = expectedLyricsScript(
      title: track.title,
      artist: track.artist,
      album: track.album,
    );
    Object? lrclibError;
    StackTrace? lrclibStack;
    MusicLyricsResolution? fallback;
    for (final String id in await _onlineSourceOrder()) {
      final _OnlineOutcome? outcome;
      if (id == MusicLyricsSource.lrclib) {
        try {
          outcome = await _resolveLrclib(
            db,
            track,
            rowOf(MusicLyricsSource.lrclib),
          );
        } on Exception catch (e, st) {
          lrclibError = e;
          lrclibStack = st;
          continue;
        }
      } else {
        outcome = await _resolvePluginProvider(db, track, id, rowOf, expected);
      }
      if (outcome == null) continue;
      if (!outcome.scriptMismatch) return outcome.resolution;
      fallback ??= outcome.resolution;
    }
    if (fallback != null) return fallback;
    if (lrclibError != null) {
      Error.throwWithStackTrace(lrclibError, lrclibStack!);
    }
    return null;
  }

  /// 服务器歌词（③'）：有缓存且新鲜就用；负缓存在 [kServerLyricsNegativeCacheTtl] 内不再问；
  /// 否则问服务器并落库（重取时保留用户调过的偏移）。不是服务器曲目 / 没有 / 出错回 null。
  Future<MusicLyricsResolution?> _resolveServerLyrics(
    FushiDatabase db,
    MusicLyricsTrackRef track,
    MusicLyricRow? prev,
    MusicServerLyricsFetcher fetch,
  ) async {
    const String source = MusicLyricsSource.server;
    if (prev != null && prev.format != kMusicLyricsNoneFormat) {
      return MusicLyricsResolution(
        timeline: await _timelineOf(db, prev, track.durationMs),
        source: source,
      );
    }
    if (prev != null &&
        _now() - prev.updatedAt <
            kServerLyricsNegativeCacheTtl.inMilliseconds) {
      return null;
    }
    final ({MusicServerLyrics? lyrics})? got;
    try {
      got = await fetch(track.trackUid, track.path);
    } on Exception {
      return null;
    }
    if (got == null) return null;
    final LyricTimeline? t = await _writeServerLyrics(
      db,
      trackUid: track.trackUid,
      durationMs: track.durationMs,
      lyrics: got.lyrics,
    );
    if (t == null) return null;
    return MusicLyricsResolution(
      timeline: t.copyWith(offsetMs: prev?.offsetMs ?? 0),
      source: source,
    );
  }

  /// 服务器给的歌词落库（[MusicLyricsSource.server] 行；[lyrics] 为 null 记负缓存）。回生效的
  /// 时间轴，没有歌词回 null。
  Future<LyricTimeline?> _writeServerLyrics(
    FushiDatabase db, {
    required String trackUid,
    required int? durationMs,
    required MusicServerLyrics? lyrics,
  }) async {
    const String source = MusicLyricsSource.server;
    if (lyrics == null) {
      await _upsert(
        db,
        trackUid: trackUid,
        source: source,
        format: kMusicLyricsNoneFormat,
        raw: Uint8List(0),
      );
      return null;
    }
    final ({String text, String format}) raw = lyrics.toRaw();
    final Uint8List bytes = Uint8List.fromList(utf8.encode(raw.text));
    final LyricTimeline t = (await _parse(
      bytes,
      raw.format,
      durationMs,
    )).copyWith(source: source);
    await _upsert(
      db,
      trackUid: trackUid,
      source: source,
      format: raw.format,
      raw: bytes,
      timeline: t,
    );
    return t;
  }

  /// 下载离线副本时把服务器歌词存进歌词缓存（`music_lyrics` 的 [MusicLyricsSource.server]
  /// 行，与串流时解析出的是同一行）：离线放下载的那份时照样有歌词。已有服务器歌词时服务器
  /// 说「没有」不覆盖（保留能用的那份）；用户调过的偏移不动。
  Future<void> storeServerLyrics({
    required String trackUid,
    required int? durationMs,
    required MusicServerLyrics? lyrics,
  }) async {
    final FushiDatabase? db = _database();
    if (db == null) return;
    if (lyrics == null) {
      for (final MusicLyricRow r in await _rows(db, trackUid)) {
        if (r.source == MusicLyricsSource.server &&
            r.format != kMusicLyricsNoneFormat) {
          return;
        }
      }
    }
    await _writeServerLyrics(
      db,
      trackUid: trackUid,
      durationMs: durationMs,
      lyrics: lyrics,
    );
  }

  /// host 给的歌词落库：按 host 上的来源 / 偏移 / 手动指定写一行本机缓存（host 离线、或放离线副本时
  /// 照样有 host 上那份）。回解析好的时间轴。
  Future<LyricTimeline> _writeHostLyrics(
    FushiDatabase db, {
    required String trackUid,
    required int? durationMs,
    required MusicHostLyrics lyrics,
  }) async {
    final Uint8List raw = Uint8List.fromList(lyrics.raw);
    final LyricTimeline t = await _parse(raw, lyrics.format, durationMs);
    await _upsert(
      db,
      trackUid: trackUid,
      source: lyrics.source,
      format: lyrics.format,
      raw: raw,
      timeline: t,
      isUserEdited: lyrics.isUserEdited,
      offsetMs: lyrics.offsetMs,
    );
    return t;
  }

  /// 下载互联 host 曲目的离线副本时把 host 上生效的歌词存进歌词缓存（design-imusic-q12）；
  /// [lyrics] 为 null（host 上没有）时什么也不写。
  Future<void> storeHostLyrics({
    required String trackUid,
    required int? durationMs,
    required MusicHostLyrics? lyrics,
  }) async {
    final FushiDatabase? db = _database();
    if (db == null || lyrics == null || lyrics.raw.isEmpty) return;
    try {
      await _writeHostLyrics(
        db,
        trackUid: trackUid,
        durationMs: durationMs,
        lyrics: lyrics,
      );
    } on LyricsParseException catch (e) {
      debugPrint('[music-lyrics] host lyrics unparsable: $e');
    }
  }

  /// 在线歌词来源的查询顺序：[MusicLyricsSource.lrclib] 或歌词插件 id。没装配来源列表
  /// （iOS 等没有插件宿主的平台、或测试）时只有 LRCLIB。
  Future<List<String>> _onlineSourceOrder() async {
    final MusicLyricsProviderIds? listProviders = _providers;
    if (listProviders == null) {
      return const <String>[MusicLyricsSource.lrclib];
    }
    return listProviders();
  }

  /// LRCLIB：先看缓存（含负缓存），再按需在线查。
  ///
  /// 精确匹配（`/api/get`）或缓存里的歌词书写系统与曲目元数据明显对不上（[expectedLyricsScript]
  /// 期望日文，正文却几乎全是拉丁字母：罗马音 / 翻译版）时不直接采用：按 [lyricsQueries] 走
  /// `/api/search`，挑同名、同录音时长且书写系统对得上的那条（[_searchLrclibInScript]）。
  /// 挑不到仍留着这条，但标 `scriptMismatch`，让歌词插件里书写系统对得上的先上。
  ///
  /// 缓存里这种行每 [kLrclibNegativeCacheTtl] 重挑一次，按行的 `updated_at` 计：改版前落库的
  /// 罗马音行只有更新时间已早于 TTL 的才会第一次解析就重挑；TTL 内落库的旧行要等到期
  /// （表里没有「是否搜过原文版」的标记，与「刚搜过没有」分不开），期间排在插件之后兜底。
  /// 重挑换行时保留用户调过的偏移。
  Future<_OnlineOutcome?> _resolveLrclib(
    FushiDatabase db,
    MusicLyricsTrackRef track,
    MusicLyricRow? cached,
  ) async {
    final LyricsScriptExpectation? expected = expectedLyricsScript(
      title: track.title,
      artist: track.artist,
      album: track.album,
    );
    final bool canQuery =
        _onlineEnabled() && (track.artist ?? '').trim().isNotEmpty;
    if (cached != null) {
      if (cached.format != kMusicLyricsNoneFormat) {
        final MusicLyricsResolution kept = MusicLyricsResolution(
          timeline: await _timelineOf(db, cached, track.durationMs),
          source: MusicLyricsSource.lrclib,
        );
        if (!lyricsScriptMismatches(
          expected,
          musicLyricsTimelineText(kept.timeline),
        )) {
          return (resolution: kept, scriptMismatch: false);
        }
        if (!canQuery ||
            _now() - cached.updatedAt <
                kLrclibNegativeCacheTtl.inMilliseconds) {
          return (resolution: kept, scriptMismatch: true);
        }
        final ({String raw, String format})? alt;
        try {
          alt = await _searchLrclibInScript(track, expected!.script);
        } on Exception {
          // 重挑联网失败：已有缓存照常顶上（与 resolve「在线失败时本地结果照常返回」一致），
          // 不刷新更新时间，下次解析再挑。
          return (resolution: kept, scriptMismatch: true);
        }
        if (alt == null) {
          // 搜过了没有原文版：刷新更新时间，TTL 内不再重挑。
          await (db.update(db.musicLyrics)..where(
                ($MusicLyricsTable r) =>
                    r.trackUid.equals(track.trackUid) &
                    r.source.equals(MusicLyricsSource.lrclib),
              ))
              .write(MusicLyricsCompanion(updatedAt: Value<int>(_now())));
          return (resolution: kept, scriptMismatch: true);
        }
        return (
          resolution: await _storeLrclib(db, track, alt, cached.offsetMs),
          scriptMismatch: false,
        );
      }
      if (_now() - cached.updatedAt < kLrclibNegativeCacheTtl.inMilliseconds) {
        return null;
      }
    }
    if (!canQuery) return null;
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
    final int offsetMs = cached?.offsetMs ?? 0;
    if (!lyricsScriptMismatches(expected, best.raw)) {
      return (
        resolution: await _storeLrclib(db, track, best, offsetMs),
        scriptMismatch: false,
      );
    }
    final ({String raw, String format})? alt;
    try {
      alt = await _searchLrclibInScript(track, expected!.script);
    } on Exception {
      // 精确命中已到手、只是搜不了原文版：这次先用它（排在插件之后），不落库，下次解析重查。
      final Uint8List raw = utf8.encode(best.raw);
      final LyricTimeline t = (await _parse(
        raw,
        best.format,
        track.durationMs,
      )).copyWith(source: MusicLyricsSource.lrclib, offsetMs: offsetMs);
      return (
        resolution: MusicLyricsResolution(
          timeline: t,
          source: MusicLyricsSource.lrclib,
        ),
        scriptMismatch: true,
      );
    }
    if (alt != null) {
      return (
        resolution: await _storeLrclib(db, track, alt, offsetMs),
        scriptMismatch: false,
      );
    }
    return (
      resolution: await _storeLrclib(db, track, best, offsetMs),
      scriptMismatch: true,
    );
  }

  /// 解析并落库一份 LRCLIB 歌词（已有行保留偏移，返回值带上 [offsetMs]）。
  Future<MusicLyricsResolution> _storeLrclib(
    FushiDatabase db,
    MusicLyricsTrackRef track,
    ({String raw, String format}) lyrics,
    int offsetMs,
  ) async {
    final Uint8List raw = utf8.encode(lyrics.raw);
    final LyricTimeline t = (await _parse(
      raw,
      lyrics.format,
      track.durationMs,
    )).copyWith(source: MusicLyricsSource.lrclib);
    await _upsert(
      db,
      trackUid: track.trackUid,
      source: MusicLyricsSource.lrclib,
      format: lyrics.format,
      raw: raw,
      timeline: t,
    );
    return MusicLyricsResolution(
      timeline: t.copyWith(offsetMs: offsetMs),
      source: MusicLyricsSource.lrclib,
    );
  }

  /// `/api/search` 里挑书写系统为 [expected] 的同一首：按 [lyricsQueries] 逐条查，只认时长在
  /// LRCLIB 同录音容差内（[lrclibDurationMatches]）的记录，再由 [pickBestLyricsCandidate]
  /// 按标题 / 艺人 / 时长裁决（正文书写系统对不上的剔除）。没有返回 null；网络错误照常抛出。
  Future<({String raw, String format})?> _searchLrclibInScript(
    MusicLyricsTrackRef track,
    LyricsScript expected,
  ) async {
    final Map<String, ({String raw, String format})> byId =
        <String, ({String raw, String format})>{};
    final List<LyricsCandidate> all = await searchWithFallbackQueries(
      title: track.title,
      artist: track.artist,
      durationMs: track.durationMs,
      expectedScript: expected,
      requireScriptMatch: true,
      run: (String q) async {
        final List<LyricsCandidate> out = <LyricsCandidate>[];
        for (final LrclibRecord r in await _lrclib.search(
          title: track.title,
          artist: track.artist,
          durationMs: track.durationMs,
          query: q,
        )) {
          final ({String raw, String format})? lyr = r.bestLyrics;
          if (lyr == null || !lrclibDurationMatches(r, track.durationMs)) {
            continue;
          }
          final String id = '${r.id}';
          byId[id] = lyr;
          final double? sec = r.durationSec;
          out.add(
            LyricsCandidate(
              providerId: MusicLyricsSource.lrclib,
              title: r.trackName,
              artist: r.artistName,
              durationMs: sec == null ? null : (sec * 1000).round(),
              ref: <String, String>{'id': id},
              lyricsText: lyr.raw,
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
      expectedScript: expected,
      requireScriptMatch: true,
    );
    return best == null ? null : byId[best.ref['id']];
  }

  /// 一个歌词插件来源：「缓存（含负缓存）→ lyricsSearch → 评分挑 → lyricsFetch」。拿到书写系统
  /// 对得上（[lyricsScriptMismatches]）的歌词返回 `scriptMismatch` = false；插件报错返回 null
  /// （不写负缓存），由调用方接着问列表里的下一个来源。拿到的歌词对不上（罗马音 / 只有翻译）
  /// 照常落库，但标 `scriptMismatch` = true，只当兜底。
  ///
  /// 缓存里对不上的行与 LRCLIB 一样按 `updated_at` 每 [kPluginLyricsNegativeCacheTtl] 重挑
  /// 一次（[_searchAndFetch] 会在同一插件的同名候选里接着找原文版）：挑到对得上的就换掉
  /// 并保留用户偏移；还是对不上或没结果只刷新更新时间，旧行照常兜底；插件报错不刷新。
  ///
  /// 缓存键是 [MusicLyricsSource.lyricsPlugin]，与平台曲目自带歌词（③'，
  /// [MusicLyricsSource.plugin]）分开；缓存命中走 [_timelineOf]，与 ③' 同一条新鲜度判断
  /// （原始各轨按当前解析器重新合并）。没装配插件搜索 / 取词回调时返回 null。
  Future<_OnlineOutcome?> _resolvePluginProvider(
    FushiDatabase db,
    MusicLyricsTrackRef track,
    String id,
    MusicLyricRow? Function(String source) rowOf,
    LyricsScriptExpectation? expected,
  ) async {
    final MusicPluginLyricsSearcher? search = _pluginSearch;
    final MusicPluginLyricsRefFetcher? fetch = _pluginFetch;
    if (search == null || fetch == null) return null;
    final String source = MusicLyricsSource.lyricsPlugin(id);
    final MusicLyricRow? prev = rowOf(source);
    // 缓存里有歌词但书写系统对不上、且已到重挑时间：带着它去重挑，挑不到原文版仍用它兜底。
    MusicLyricsResolution? kept;
    if (prev != null) {
      final bool fresh =
          _now() - prev.updatedAt <
          kPluginLyricsNegativeCacheTtl.inMilliseconds;
      if (prev.format != kMusicLyricsNoneFormat) {
        final MusicLyricsResolution cachedHit = MusicLyricsResolution(
          timeline: await _timelineOf(db, prev, track.durationMs),
          source: source,
        );
        if (!lyricsScriptMismatches(
          expected,
          musicLyricsTimelineText(cachedHit.timeline),
        )) {
          return (resolution: cachedHit, scriptMismatch: false);
        }
        if (fresh || !_onlineEnabled()) {
          return (resolution: cachedHit, scriptMismatch: true);
        }
        kept = cachedHit;
      } else if (fresh) {
        return null;
      }
    }
    if (!_onlineEnabled()) return null;
    final _OnlineOutcome? keptFallback = kept == null
        ? null
        : (resolution: kept, scriptMismatch: true);
    try {
      final _PluginFetched? got = await _searchAndFetch(
        id,
        track,
        search,
        fetch,
        expected,
      );
      if (got == null) {
        if (keptFallback != null) {
          await _touch(db, track.trackUid, source);
          return keptFallback;
        }
        await _upsert(
          db,
          trackUid: track.trackUid,
          source: source,
          format: kMusicLyricsNoneFormat,
          raw: Uint8List(0),
        );
        return null;
      }
      final LyricTimeline t = got.timeline.copyWith(source: source);
      final bool mismatch = got.scriptMismatch;
      if (keptFallback != null && mismatch) {
        // 重挑还是对不上：旧行照用，TTL 内不再重挑。
        await _touch(db, track.trackUid, source);
        return keptFallback;
      }
      await _upsert(
        db,
        trackUid: track.trackUid,
        source: source,
        format: got.format,
        raw: got.raw,
        timeline: t,
      );
      return (
        resolution: MusicLyricsResolution(
          timeline: t.copyWith(offsetMs: prev?.offsetMs ?? 0),
          source: source,
        ),
        scriptMismatch: mismatch,
      );
    } on MusicPluginException {
      return keptFallback;
    } on LyricsParseException {
      return keptFallback;
    }
  }

  /// 只刷新一行的更新时间（重挑过但没换掉：TTL 内不再重挑）。
  Future<void> _touch(FushiDatabase db, String trackUid, String source) =>
      (db.update(db.musicLyrics)..where(
            ($MusicLyricsTable r) =>
                r.trackUid.equals(trackUid) & r.source.equals(source),
          ))
          .write(MusicLyricsCompanion(updatedAt: Value<int>(_now())));

  /// 在一个歌词插件里搜候选、评分、取歌词并解析。
  ///
  /// 插件候选不带正文，同名的原文版与罗马音 / 翻译版靠评分分不开：[expected] 已知时按
  /// [rankLyricsCandidates] 的名次逐条取，解析后书写系统对得上的就用它；最多取
  /// [kPluginLyricsScriptProbeLimit] 条，都对不上返回取到的第一条（`scriptMismatch` =
  /// true，调用方当兜底）。[expected] 为 null 时只取第一名。某条解析失败跳过它；一条都没
  /// 解析成而有解析失败时抛出那个 [LyricsParseException]（与只取一条时一样不写负缓存）。
  Future<_PluginFetched?> _searchAndFetch(
    String pluginId,
    MusicLyricsTrackRef track,
    MusicPluginLyricsSearcher search,
    MusicPluginLyricsRefFetcher fetch,
    LyricsScriptExpectation? expected,
  ) async {
    final List<MusicPluginLyricsCandidate> ranked = await _rankedPluginHits(
      pluginId,
      track,
      search,
      title: track.title,
      artist: track.artist,
      durationMs: track.durationMs,
    );
    _PluginFetched? first;
    LyricsParseException? parseError;
    StackTrace? parseStack;
    final int probes = expected == null ? 1 : kPluginLyricsScriptProbeLimit;
    for (final MusicPluginLyricsCandidate c in ranked.take(probes)) {
      final MusicPluginLyrics? lyrics = await fetch(pluginId, c.ref);
      if (lyrics?.original == null) continue;
      final ({Uint8List raw, String format, LyricTimeline timeline}) built;
      try {
        built = await buildMusicPluginLyrics(lyrics!, track.durationMs, _parse);
      } on LyricsParseException catch (e, st) {
        parseError ??= e;
        parseStack ??= st;
        continue;
      }
      final bool mismatch = lyricsScriptMismatches(
        expected,
        musicLyricsTimelineText(built.timeline),
      );
      final _PluginFetched got = (
        raw: built.raw,
        format: built.format,
        timeline: built.timeline,
        scriptMismatch: mismatch,
      );
      if (!mismatch) return got;
      first ??= got;
    }
    if (first == null && parseError != null) {
      Error.throwWithStackTrace(parseError, parseStack!);
    }
    return first;
  }

  /// 在一个歌词插件里按 [title] / [artist] 搜（[searchWithFallbackQueries] 逐级放宽查询词），
  /// 候选按 [rankLyricsCandidates] 排好返回。自动解析传曲目元数据；用户手动搜索
  /// （[searchOnline]）传搜索框里的关键词，且 [durationMs] 传 null：用户手动指定的歌常是
  /// 时长不同的版本（视频带前奏 / 翻唱），不按时长剔除。插件报错原样抛出，由调用方决定
  /// 跳过与否。
  Future<List<MusicPluginLyricsCandidate>> _rankedPluginHits(
    String pluginId,
    MusicLyricsTrackRef track,
    MusicPluginLyricsSearcher search, {
    required String title,
    required String? artist,
    required int? durationMs,
  }) async {
    final Map<String, MusicPluginLyricsCandidate> byKey =
        <String, MusicPluginLyricsCandidate>{};
    final List<LyricsCandidate> all = await searchWithFallbackQueries(
      title: title,
      artist: artist,
      durationMs: durationMs,
      run: (String q) async {
        final List<MusicPluginLyricsCandidate> items = await search(
          pluginId,
          title,
          artist: artist,
          album: track.album,
          durationMs: durationMs,
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
    return <MusicPluginLyricsCandidate>[
      for (final LyricsCandidate c in rankLyricsCandidates(
        all,
        title: title,
        artist: artist,
        durationMs: durationMs,
      ))
        byKey[c.ref['k']]!,
    ];
  }

  static bool _hasGenerated(MusicLyricRow? row) =>
      row != null && row.format != kMusicLyricsNoneFormat;

  /// [skipGenerated]：本机字幕管线写的旁置文件（[MusicGeneratedSidecarCheck]）不算
  /// sidecar（这首已有 `asr` 行时由调用方置位）。
  Future<_Sidecar?> _readSidecars(
    MusicLyricsTrackRef track, {
    bool skipGenerated = false,
  }) async {
    final MusicGeneratedSidecarCheck? generated = _isGeneratedSidecar;
    final LyricSidecarSet set = await _local.sidecars(
      track.path,
      exclude: skipGenerated && generated != null
          ? (String path) => generated(track.path, path)
          : null,
    );
    final LyricSidecarFile? primary = set.primary;
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

  Future<EmbeddedLyrics?> _bestEmbedded(MusicLyricsTrackRef track) =>
      _local.bestEmbedded(track.path, durationMs: track.durationMs);

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
        for (final EmbeddedLyrics e in await _local.allEmbedded(
          track.path,
          durationMs: track.durationMs,
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
        // 生成字幕的标签由界面按来源换成本地化名（`musicLyricsCandidateTitle`）。
        final String? label = r.source == MusicLyricsSource.lrclib
            ? 'LRCLIB'
            : r.source == MusicLyricsSource.asr
            ? 'ASR'
            : r.source == MusicLyricsSource.server
            ? 'Server'
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

  /// 在线搜索（用户点「搜索在线歌词」时）：返回候选，不落库。
  ///
  /// [title] / [artist] 是用户在搜索框里改过的关键词（YouTube 翻唱等标题与歌名对不上时
  /// 手动找）：null = 用曲目元数据；[artist] 传空串 = 不限艺人。所有在线来源都按同一组
  /// 关键词搜，来源与顺序同自动解析：来源列表里已启用的 LRCLIB 与歌词插件按用户排序逐个问
  /// （没装配来源列表时只有 LRCLIB）；每个插件取评分前 [kPluginLyricsScriptProbeLimit] 条——
  /// 插件候选不带正文，只能逐条取来。
  ///
  /// 书写系统与关键词对得上的（原文版）排前，组内保持来源顺序与各来源自己的排序。某个
  /// 来源出错只跳过它；全部来源都没结果且有来源出错时抛出第一个错误（界面显示错误，而不是
  /// 「没有候选」）。
  Future<List<MusicLyricsCandidate>> searchOnline(
    MusicLyricsTrackRef track, {
    String? title,
    String? artist,
  }) async {
    final String typedTitle = title?.trim() ?? '';
    final String effectiveTitle = typedTitle.isEmpty ? track.title : typedTitle;
    final String? typedArtist = artist?.trim();
    final String? effectiveArtist = artist == null
        ? track.artist
        : (typedArtist!.isEmpty ? null : typedArtist);
    final LyricsScriptExpectation? expected = expectedLyricsScript(
      title: effectiveTitle,
      artist: effectiveArtist,
      album: track.album,
    );
    final List<MusicLyricsCandidate> matching = <MusicLyricsCandidate>[];
    final List<MusicLyricsCandidate> others = <MusicLyricsCandidate>[];
    void add(MusicLyricsCandidate c) =>
        (lyricsScriptMismatches(expected, musicLyricsTimelineText(c.timeline))
                ? others
                : matching)
            .add(c);
    Object? firstError;
    StackTrace? firstStack;

    Future<void> searchLrclib() async {
      for (final LrclibRecord r in await _lrclib.search(
        title: effectiveTitle,
        artist: effectiveArtist,
        durationMs: track.durationMs,
      )) {
        final ({String raw, String format})? best = r.bestLyrics;
        if (best == null) continue;
        final Uint8List raw = utf8.encode(best.raw);
        add(
          MusicLyricsCandidate(
            source: MusicLyricsSource.lrclib,
            label: '${r.trackName} — ${r.artistName}',
            format: best.format,
            raw: raw,
            timeline: await _parse(raw, best.format, track.durationMs),
          ),
        );
      }
    }

    Future<void> searchPlugin(
      String id,
      MusicPluginLyricsSearcher search,
      MusicPluginLyricsRefFetcher fetch,
    ) async {
      final List<MusicPluginLyricsCandidate> hits = await _rankedPluginHits(
        id,
        track,
        search,
        title: effectiveTitle,
        artist: effectiveArtist,
        durationMs: null,
      );
      for (final MusicPluginLyricsCandidate hit in hits.take(
        kPluginLyricsScriptProbeLimit,
      )) {
        final MusicPluginLyrics? lyrics = await fetch(id, hit.ref);
        if (lyrics?.original == null) continue;
        final ({Uint8List raw, String format, LyricTimeline timeline}) built;
        try {
          built = await buildMusicPluginLyrics(
            lyrics!,
            track.durationMs,
            _parse,
          );
        } on LyricsParseException {
          continue;
        }
        final String? hitArtist = hit.artist?.trim();
        add(
          MusicLyricsCandidate(
            source: MusicLyricsSource.lyricsPlugin(id),
            label: hitArtist == null || hitArtist.isEmpty
                ? hit.title
                : '${hit.title} — $hitArtist',
            // 原始各轨不是歌词格式：展示合并后时间轴的格式（与 [localCandidates] 一致）。
            format: built.format == kMusicPluginLyricsTracksFormat
                ? built.timeline.format
                : built.format,
            raw: built.raw,
            timeline: built.timeline,
          ),
        );
      }
    }

    // 与自动解析同一份来源列表（[_onlineSourceOrder]）：用户排的顺序、停用的 LRCLIB /
    // 插件都照办。
    final MusicPluginLyricsSearcher? search = _pluginSearch;
    final MusicPluginLyricsRefFetcher? fetch = _pluginFetch;
    for (final String id in await _onlineSourceOrder()) {
      if (id == MusicLyricsSource.lrclib) {
        try {
          await searchLrclib();
        } on Object catch (e, st) {
          firstError ??= e;
          firstStack ??= st;
        }
      } else if (search != null && fetch != null) {
        try {
          await searchPlugin(id, search, fetch);
        } on MusicPluginException catch (e, st) {
          firstError ??= e;
          firstStack ??= st;
        }
      }
    }

    if (matching.isEmpty && others.isEmpty && firstError != null) {
      Error.throwWithStackTrace(firstError, firstStack!);
    }
    return <MusicLyricsCandidate>[...matching, ...others];
  }

  /// 用户挑定一份候选：写成 `user` 行（`is_user_edited` = 手动指定，永远最高）。原文存
  /// TTML（无损交换格式，翻译合并后的结果也一并保住）；ASS / SSA 候选例外，原文照存——
  /// 字幕组特效要交给 libass 原样渲染，转成 TTML 会全部丢掉（设计 §6.3）。
  ///
  /// 这里只接受「选来源」：所有者 2026-10-24 拍板不另做音乐歌词编辑界面（改字 / 翻译 /
  /// 注音 / 单行偏移），不接受任意改过的时间轴。纯文本歌词的自动对时与它在通用字幕
  /// 工作台里的逐行微调另走 [saveAutoSynced] / [setAutoSyncedLineStart]。
  Future<void> choose(String trackUid, MusicLyricsCandidate candidate) async {
    // 用户另选了来源：之前登记的「转录落库后自动对时」作废，否则转录一落库就拿旧的纯文本
    // 盖掉这次的手动指定。
    _pendingAutoSync.remove(trackUid);
    final FushiDatabase? db = _database();
    if (db == null) return;
    final LyricTimeline t = candidate.timeline.copyWith(
      source: MusicLyricsSource.user,
      isUserEdited: true,
    );
    final bool ass = musicLyricsFormatIsAss(candidate.format);
    final String format = ass ? candidate.format.toLowerCase() : 'ttml';
    final Uint8List raw = ass
        ? candidate.raw
        : FushiLyrics.export(t.copyWith(offsetMs: 0), 'ttml');
    await _upsert(
      db,
      trackUid: trackUid,
      source: MusicLyricsSource.user,
      format: format,
      raw: raw,
      timeline: t.copyWith(offsetMs: 0),
      isUserEdited: true,
      offsetMs: candidate.timeline.offsetMs,
    );
    // 互联 host 曲目：手动指定写回 host（另一台设备也看到同一份）。
    await _writeBackHost(
      trackUid,
      (MusicHostLyricsLayer h, String path) => h.chooseLyrics(
        path,
        format: format,
        raw: raw,
        offsetMs: candidate.timeline.offsetMs,
      ),
    );
  }

  /// 写回 host 失败不打断本机操作（本机缓存已经改了；host 在线时下一次修改再写回）。
  Future<void> _writeBackHost(
    String trackUid,
    Future<void> Function(MusicHostLyricsLayer host, String path) write,
  ) async {
    final MusicHostLyricsLayer? host = _hostLyrics;
    final String? path = _hostPaths[trackUid];
    if (host == null || path == null) return;
    try {
      await write(host, path);
    } on Object catch (e) {
      debugPrint('[music-lyrics] host write-back failed: $e');
    }
  }

  /// 写入本机生成的字幕（[MusicLyricsSource.asr] 行）：重生成覆盖原文与时间轴，保留
  /// 用户调过的整首偏移。不碰 `user` 行——用户手动指定过别的来源时仍显示那份，界面
  /// 「重置来源」后回到生成字幕。时间轴不带注音（ASR 转写本来就没有 ruby）。
  Future<void> saveGenerated(
    String trackUid, {
    required String format,
    required Uint8List raw,
    required LyricTimeline timeline,
  }) async {
    final FushiDatabase? db = _database();
    if (db == null) return;
    await _upsert(
      db,
      trackUid: trackUid,
      source: MusicLyricsSource.asr,
      format: format,
      raw: raw,
      timeline: timeline.copyWith(source: MusicLyricsSource.asr, offsetMs: 0),
    );
    _generated.add(trackUid);
    final ({MusicLyricsTrackRef track, LyricTimeline plain})? pending =
        _pendingAutoSync.remove(trackUid);
    // 等着这份转录的自动对时另起一条：它的成败只经 [autoSyncResults] 报给界面，不回传
    // 给生成任务——转录已经落库，对时失败（对齐超限、解析失败）不能把生成任务判成失败、
    // 也不能挡住同一文件后面曲目（CUE）的转录落库。
    if (pending != null) {
      unawaited(_runPendingAutoSync(pending.track, pending.plain));
    }
  }

  Future<void> _runPendingAutoSync(
    MusicLyricsTrackRef track,
    LyricTimeline plain,
  ) async {
    MusicLyricsAutoSyncOutcome outcome;
    try {
      outcome = await autoSyncPlainLyrics(track, plain);
    } on Object catch (e) {
      outcome = MusicLyricsAutoSyncOutcome(
        MusicLyricsAutoSyncStatus.failed,
        error: e.toString(),
      );
    }
    _autoSyncResults.add((trackUid: track.trackUid, outcome: outcome));
    if (outcome.status == MusicLyricsAutoSyncStatus.synced) {
      _generated.add(track.trackUid);
    }
  }

  /// 这首的生成字幕（ASR 转录，`asr` 行）时间轴；没有返回 null。
  Future<LyricTimeline?> generatedTimeline(MusicLyricsTrackRef track) async {
    final FushiDatabase? db = _database();
    if (db == null) return null;
    for (final MusicLyricRow r in await _rows(db, track.trackUid)) {
      if (r.source != MusicLyricsSource.asr ||
          r.format == kMusicLyricsNoneFormat) {
        continue;
      }
      final LyricTimeline t = await _timelineOf(db, r, track.durationMs);
      return t.lines.isEmpty ? null : t;
    }
    return null;
  }

  /// 纯文本歌词自动对时（拍板台 niQk_Ns4OV）：拿这首的生成字幕当时间参照逐行对时间，
  /// 对上了就存成本地 LRC、设成这首的手动指定（[saveAutoSynced]）。还没有生成字幕时返回
  /// [MusicLyricsAutoSyncStatus.needsTranscript]（界面先开生成面板，并用
  /// [autoSyncWhenGenerated] 登记，转录落库时自动接着对）。
  Future<MusicLyricsAutoSyncOutcome> autoSyncPlainLyrics(
    MusicLyricsTrackRef track,
    LyricTimeline plain,
  ) async {
    if (!musicLyricsCanAutoSync(plain)) {
      return const MusicLyricsAutoSyncOutcome(
        MusicLyricsAutoSyncStatus.noPlainLyrics,
      );
    }
    final LyricTimeline? transcript = await generatedTimeline(track);
    if (transcript == null) {
      return const MusicLyricsAutoSyncOutcome(
        MusicLyricsAutoSyncStatus.needsTranscript,
      );
    }
    final LyricsAlignment alignment = await alignMusicPlainLyrics(
      plain,
      transcript,
      durationMs: track.durationMs,
    );
    final Uint8List? lrc = musicAlignedLrc(
      alignment,
      title: track.title,
      artist: track.artist,
    );
    if (lrc == null) {
      return const MusicLyricsAutoSyncOutcome(
        MusicLyricsAutoSyncStatus.noPlainLyrics,
      );
    }
    if (!alignment.isReliable) {
      return MusicLyricsAutoSyncOutcome(
        MusicLyricsAutoSyncStatus.unreliable,
        anchoredLines: alignment.anchoredLines,
      );
    }
    final LyricTimeline timeline = await saveAutoSynced(track, lrc);
    return MusicLyricsAutoSyncOutcome(
      MusicLyricsAutoSyncStatus.synced,
      lines: timeline.lines.length,
      anchoredLines: alignment.anchoredLines,
    );
  }

  /// 登记：这首的生成字幕落库（[saveGenerated]）后自动对时 [plain]。同一首再登记覆盖前一次。
  void autoSyncWhenGenerated(MusicLyricsTrackRef track, LyricTimeline plain) {
    _pendingAutoSync[track.trackUid] = (track: track, plain: plain);
  }

  /// 有没有在等转录的自动对时。
  bool autoSyncPending(String trackUid) =>
      _pendingAutoSync.containsKey(trackUid);

  /// 把一份对好时间的 LRC 存成这首的手动指定（`user` 行，`format = lrc`，原文就是 LRC），
  /// 偏移归零（时间是新对的）。互联 host 曲目同样写回 host。返回解析后的时间轴。
  ///
  /// 写入口只有两个：自动对时的结果，与字幕工作台对这份结果的逐行微调
  /// （[setAutoSyncedLineStart]）。不另立歌词编辑界面（功能黑名单「单独的音乐歌词编辑
  /// 界面」：歌词走通用字幕工作台）。
  Future<LyricTimeline> saveAutoSynced(
    MusicLyricsTrackRef track,
    Uint8List lrc,
  ) async {
    final LyricTimeline parsed = await _parse(
      lrc,
      kMusicLyricsAutoSyncFormat,
      track.durationMs,
    );
    final LyricTimeline t = parsed.copyWith(
      source: MusicLyricsSource.user,
      isUserEdited: true,
      offsetMs: 0,
    );
    final FushiDatabase? db = _database();
    if (db == null) return t;
    await _upsert(
      db,
      trackUid: track.trackUid,
      source: MusicLyricsSource.user,
      format: kMusicLyricsAutoSyncFormat,
      raw: lrc,
      timeline: t,
      isUserEdited: true,
      offsetMs: 0,
    );
    await _writeBackHost(
      track.trackUid,
      (MusicHostLyricsLayer h, String path) => h.chooseLyrics(
        path,
        format: kMusicLyricsAutoSyncFormat,
        raw: lrc,
        offsetMs: 0,
      ),
    );
    return t;
  }

  /// 生效的手动指定是不是自动对时存下的 LRC（字幕工作台据此给逐行微调）。
  Future<bool> hasAutoSynced(String trackUid) async =>
      (await _autoSyncedRow(trackUid)) != null;

  Future<MusicLyricRow?> _autoSyncedRow(String trackUid) async {
    final FushiDatabase? db = _database();
    if (db == null) return null;
    for (final MusicLyricRow r in await _rows(db, trackUid)) {
      if (r.isUserEdited &&
          r.source == MusicLyricsSource.user &&
          r.format == kMusicLyricsAutoSyncFormat) {
        return r;
      }
    }
    return null;
  }

  /// 字幕工作台逐行微调：把自动对时结果第 [index] 行的起点改成 [startMs]（时间轴时间，
  /// 不含整首偏移），夹在前后两行之间。生效的不是自动对时的 LRC 时什么也不做、返回 false。
  /// 用户调过的整首偏移保留。
  Future<bool> setAutoSyncedLineStart(
    MusicLyricsTrackRef track,
    int index,
    int startMs,
  ) async {
    final FushiDatabase? db = _database();
    final MusicLyricRow? row = await _autoSyncedRow(track.trackUid);
    if (db == null || row == null) return false;
    final LyricTimeline current = await _timelineOf(db, row, track.durationMs);
    final Uint8List? lrc = musicLrcWithLineStart(
      current,
      index,
      startMs,
      title: track.title,
      artist: track.artist,
    );
    if (lrc == null) return false;
    final LyricTimeline parsed = await _parse(
      lrc,
      kMusicLyricsAutoSyncFormat,
      track.durationMs,
    );
    await _upsert(
      db,
      trackUid: track.trackUid,
      source: MusicLyricsSource.user,
      format: kMusicLyricsAutoSyncFormat,
      raw: lrc,
      timeline: parsed.copyWith(
        source: MusicLyricsSource.user,
        isUserEdited: true,
        offsetMs: 0,
      ),
      isUserEdited: true,
    );
    await _writeBackHost(
      track.trackUid,
      (MusicHostLyricsLayer h, String path) => h.chooseLyrics(
        path,
        format: kMusicLyricsAutoSyncFormat,
        raw: lrc,
        offsetMs: row.offsetMs,
      ),
    );
    return true;
  }

  /// [trackUids] 里已有生成字幕（`asr` 行，非负缓存）的曲目：批量生成跳过它们，存量迁移
  /// 不覆盖。
  Future<Set<String>> tracksWithGenerated(List<String> trackUids) async {
    final FushiDatabase? db = _database();
    if (db == null || trackUids.isEmpty) return const <String>{};
    // 按块查：整个来源批量时曲目数没有上限，一条 IN 会撞 SQLite 变量上限。
    final Set<String> out = <String>{};
    for (int i = 0; i < trackUids.length; i += _kInChunk) {
      final List<String> chunk = trackUids.sublist(
        i,
        i + _kInChunk > trackUids.length ? trackUids.length : i + _kInChunk,
      );
      final List<MusicLyricRow> rows =
          await (db.select(db.musicLyrics)..where(
                ($MusicLyricsTable l) =>
                    l.trackUid.isIn(chunk) &
                    l.source.equals(MusicLyricsSource.asr) &
                    l.format.equals(kMusicLyricsNoneFormat).not(),
              ))
              .get();
      out.addAll(<String>[for (final MusicLyricRow r in rows) r.trackUid]);
    }
    return out;
  }

  /// [tracksWithGenerated] 每条 IN 的 uid 数（远低于 SQLite 变量上限，同仓库其余分块口径）。
  static const int _kInChunk = 500;

  /// 这首有没有用户手动指定的歌词（`is_user_edited`）。
  Future<bool> hasUserChoice(String trackUid) async {
    final FushiDatabase? db = _database();
    if (db == null) return false;
    return (await _rows(db, trackUid)).any((MusicLyricRow r) => r.isUserEdited);
  }

  /// 把一份整文件的字幕 / 歌词文件 [path] 设成这个文件下各曲目 [tracks] 的手动指定
  /// （`user` 行，走 [choose] 同一写法）：存量迁移带走旧视频行上用户选过、又不在音频旁
  /// （sidecar 规则认不到）的字幕——不搬的话删视频行会把 app 目录里的导入副本一起回收
  /// （BUG-4175）。CUE 虚拟曲目按区间截取并平移成曲内时间（整批一次后台 isolate），普通
  /// 曲目整份。已有手动指定的曲目不覆盖（用户在音乐库里选过的优先）。
  ///
  /// 返回写了的曲目；读不了 / 解析不了 / 一行都没有返回 null（调用方决定要不要保留源行）。
  /// 数据库未就绪抛 [StateError]（不能当成「写成了」让调用方删源行）。
  Future<List<String>?> chooseFileForTracks(
    String path,
    List<MusicLyricsFileTrack> tracks,
  ) async {
    final FushiDatabase? db = _database();
    if (db == null) throw StateError('music lyrics: database not ready');
    final Uint8List raw;
    try {
      raw = await File(path).readAsBytes();
    } on FileSystemException {
      return null;
    }
    final String name = File(path).uri.pathSegments.last;
    final int dot = name.lastIndexOf('.');
    final String ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
    final bool whole = tracks.length == 1 && tracks.single.cueStartMs == null;
    final LyricTimeline t;
    try {
      t = await _parse(raw, ext, whole ? tracks.single.durationMs : null);
    } on LyricsParseException {
      return null;
    }
    if (t.lines.isEmpty) return null;
    final List<MusicLyricsFileTrack> pending = <MusicLyricsFileTrack>[
      for (final MusicLyricsFileTrack tr in tracks)
        if (!await hasUserChoice(tr.trackUid)) tr,
    ];
    final List<MusicLyricsFileTrack> cue = <MusicLyricsFileTrack>[
      for (final MusicLyricsFileTrack tr in pending)
        if (tr.cueStartMs != null) tr,
    ];
    final List<({LyricTimeline timeline, Uint8List ttml})> cut = cue.isEmpty
        ? const <({LyricTimeline timeline, Uint8List ttml})>[]
        : await FushiLyricsAsync.sliceAll(t, <({int startMs, int? endMs})>[
            for (final MusicLyricsFileTrack tr in cue)
              (startMs: tr.cueStartMs!, endMs: tr.cueEndMs),
          ]);
    final List<String> wrote = <String>[];
    int at = 0;
    for (final MusicLyricsFileTrack tr in pending) {
      if (tr.cueStartMs == null) {
        await choose(
          tr.trackUid,
          MusicLyricsCandidate(
            source: MusicLyricsSource.user,
            label: name,
            format: t.format,
            raw: raw,
            timeline: t,
          ),
        );
      } else {
        final ({LyricTimeline timeline, Uint8List ttml}) c = cut[at++];
        // 这一曲的区间里一行都没有：不写空的手动指定（会把这首钉成「没有歌词」）。
        if (c.timeline.lines.isEmpty) continue;
        await choose(
          tr.trackUid,
          MusicLyricsCandidate(
            source: MusicLyricsSource.user,
            label: name,
            format: 'ttml',
            raw: c.ttml,
            timeline: c.timeline,
          ),
        );
      }
      wrote.add(tr.trackUid);
    }
    return wrote;
  }

  /// 撤销手动指定，回到自动优先级。
  Future<void> clearUserEdit(String trackUid) async {
    // 重置来源同样作废等转录的自动对时（见 [choose]）。
    _pendingAutoSync.remove(trackUid);
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
    await _writeBackHost(
      trackUid,
      (MusicHostLyricsLayer h, String path) =>
          h.setLyricsOffset(path, source: source, offsetMs: offsetMs),
    );
  }

  /// 显式操作：把时间轴导出到音频文件旁边（`<主名>.<ext>`），返回写出的路径。
  /// 已存在同名文件时不覆盖，抛 [FileSystemException]（由界面问用户）。
  Future<String> exportBesideAudio(
    MusicLyricsTrackRef track,
    LyricTimeline timeline,
    String format, {
    bool overwrite = false,
  }) async {
    // 不是本机文件（网络来源 / 插件 / 服务器曲目）就没有「文件旁边」：明确拒绝，不往
    // 当前目录下写一个用地址拼出来的相对路径。界面对这类曲目不给入口。
    if (!track.isLocalFile) {
      throw FileSystemException('not a local audio file', track.path);
    }
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
