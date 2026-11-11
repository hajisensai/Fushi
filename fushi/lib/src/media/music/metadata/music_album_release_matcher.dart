/// 本地专辑 → MusicBrainz 发行（release）的后台自动对号。
///
/// 目的：拿到发行 MBID 才能去 Cover Art Archive 取真盘面扫描（`Medium` 图）。标签里
/// 本来就带 `mb_release_id` 的专辑不碰；其余按「专辑名 + 专辑艺人」搜发行，本地每张盘
/// （按盘号）的曲目时长必须可信地对上发行里不同的一张 medium（[pickMusicAlbumRelease]），
/// 对不上就记「没有」，绝不猜。
///
/// 结论**不写 `music_albums`**：曲库重扫会按标签覆写 `mb_release_id`。落在应用自己的
/// 缓存文件 `<documents>/music_covers/disc/release_matches.json`（albumUid → 发行 id 或
/// null + 检查时间），原子写（tmp + rename）。否定结论 30 天后重查；网络错误不记，整轮停下
/// 等下次触发。
///
/// 触发：启动首帧后一次 + 每次音乐来源扫描完（AppModel 装配）。串行、经
/// [MusicRequestThrottle.musicBrainz]（1 req/s）出站，[dispose] 后不再发新请求。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/metadata/music_metadata_provider.dart';
import 'package:fushi_engine/media/music/metadata/music_release_match.dart';
import 'package:fushi_engine/media/music/metadata/musicbrainz_provider.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/storage/app_paths.dart';

/// 缓存文件名（在 [MusicAlbumReleaseMatcher] 的缓存目录下）。
const String kMusicAlbumReleaseMatchesFile = 'release_matches.json';

/// 缓存里的一条对号结论。
@immutable
class MusicAlbumReleaseMatchEntry {
  const MusicAlbumReleaseMatchEntry({
    required this.releaseId,
    required this.checkedAtMs,
  });

  /// 对上的发行 MBID；null = 查过、没有可信的发行。
  final String? releaseId;
  final int checkedAtMs;

  Map<String, Object?> toJson() => <String, Object?>{
    'release': releaseId,
    'checkedAt': checkedAtMs,
  };

  static MusicAlbumReleaseMatchEntry? fromJson(Object? v) {
    if (v is! Map<String, Object?>) return null;
    final Object? at = v['checkedAt'];
    if (at is! int) return null;
    final Object? id = v['release'];
    return MusicAlbumReleaseMatchEntry(
      releaseId: id is String ? normalizeMusicBrainzId(id) : null,
      checkedAtMs: at,
    );
  }
}

/// 一张专辑对号要的本地数据：盘号 → 按曲序的时长（毫秒，缺时长记 0）。
Map<int, List<int>> musicAlbumDiscDurations(List<MusicTrackRow> tracks) {
  final List<MusicTrackRow> sorted = List<MusicTrackRow>.of(tracks)
    ..sort((MusicTrackRow a, MusicTrackRow b) {
      final int d = (a.discNo ?? 1).compareTo(b.discNo ?? 1);
      if (d != 0) return d;
      return (a.trackNo ?? 1 << 20).compareTo(b.trackNo ?? 1 << 20);
    });
  final Map<int, List<int>> out = <int, List<int>>{};
  for (final MusicTrackRow t in sorted) {
    final int? cue = (t.cueStartMs != null && t.cueEndMs != null)
        ? t.cueEndMs! - t.cueStartMs!
        : null;
    final int ms = t.durationMs ?? cue ?? 0;
    (out[t.discNo ?? 1] ??= <int>[]).add(ms);
  }
  return out;
}

class MusicAlbumReleaseMatcher {
  MusicAlbumReleaseMatcher({
    required FushiDatabase? Function() database,
    MusicReleaseProvider Function()? provider,
    Future<Directory> Function()? cacheDirectory,
    DateTime Function()? now,
    this.negativeRecheckAfter = const Duration(days: 30),
  }) : _database = database,
       _provider = provider ?? MusicBrainzProvider.new,
       _cacheDirectory = cacheDirectory ?? _defaultCacheDirectory,
       _now = now ?? DateTime.now;

  static Future<Directory> _defaultCacheDirectory() async =>
      Directory(p.join((await AppPaths.musicCoversDirectory()).path, 'disc'));

  final FushiDatabase? Function() _database;
  final MusicReleaseProvider Function() _provider;
  final Future<Directory> Function() _cacheDirectory;
  final DateTime Function() _now;

  /// 否定结论的有效期，过期后重查（MusicBrainz 一直有人补录）。
  final Duration negativeRecheckAfter;

  final StreamController<String> _matched =
      StreamController<String>.broadcast();

  Map<String, MusicAlbumReleaseMatchEntry>? _cache;
  Future<Map<String, MusicAlbumReleaseMatchEntry>>? _loading;
  MusicReleaseProvider? _activeProvider;
  bool _running = false;
  bool _again = false;
  bool _disposed = false;

  /// 刚对上发行的 albumUid（UI 据此重新解析盘面图）。
  Stream<String> get matchedAlbums => _matched.stream;

  bool get isRunning => _running;

  /// 自动对号得到的发行 MBID（只查缓存，不联网）。没对上 / 没查过返回 null。
  Future<String?> releaseIdOf(String albumUid) async =>
      (await _load())[albumUid]?.releaseId;

  /// 请求一轮对号。跑着时再来的请求合并成「跑完再看一遍」。
  Future<void> schedule() async {
    if (_disposed) return;
    if (_running) {
      _again = true;
      return;
    }
    _running = true;
    try {
      do {
        _again = false;
        await _runOnce();
      } while (_again && !_disposed);
    } catch (e, stack) {
      debugPrint('[music-release-match] run failed: $e\n$stack');
    } finally {
      _running = false;
    }
  }

  void dispose() {
    _disposed = true;
    _activeProvider?.close();
    _activeProvider = null;
    unawaited(_matched.close());
  }

  bool _needsCheck(MusicAlbumReleaseMatchEntry? e, int nowMs) {
    if (e == null) return true;
    if (e.releaseId != null) return false;
    return nowMs - e.checkedAtMs >= negativeRecheckAfter.inMilliseconds;
  }

  Future<void> _runOnce() async {
    final FushiDatabase? db = _database();
    if (db == null) return;
    final Map<String, MusicAlbumReleaseMatchEntry> cache = await _load();
    final List<MusicAlbumRow> albums = <MusicAlbumRow>[
      for (final MusicAlbumRow a in await db.listMusicAlbums())
        if (normalizeMusicBrainzId(a.mbReleaseId) == null &&
            a.title.trim().isNotEmpty &&
            _needsCheck(cache[a.albumUid], _now().millisecondsSinceEpoch))
          a,
    ];
    if (albums.isEmpty) return;
    final MusicReleaseProvider provider = _provider();
    _activeProvider = provider;
    try {
      for (final MusicAlbumRow album in albums) {
        if (_disposed) return;
        final FushiDatabase? live = _database();
        if (live == null) return;
        final Map<int, List<int>> discs = musicAlbumDiscDurations(
          await live.listMusicTracks(albumUid: album.albumUid),
        );
        if (discs.isEmpty) continue;
        String? releaseId;
        final bool hasAllDurations = discs.values.every(
          (List<int> d) => d.every((int ms) => ms > 0),
        );
        if (hasAllDurations) {
          final List<MusicReleaseTracklist> candidates;
          try {
            candidates = await provider.searchAlbumReleases(
              album.title,
              artist: album.albumArtistCredit,
              discTrackCounts: <int>[
                for (final List<int> d in discs.values) d.length,
              ],
            );
          } on Exception catch (e) {
            // 断网 / 限流 / dispose 关掉了连接：不记结论，整轮停下等下次触发。
            if (!_disposed) {
              debugPrint(
                '[music-release-match] ${album.albumUid} search failed: $e',
              );
            }
            return;
          }
          if (_disposed) return;
          releaseId = pickMusicAlbumRelease(
            discs,
            candidates,
          )?.release.mbReleaseId;
        }
        // 缺时长的专辑不联网（时长对号做不了），直接记「没有」，过期后再看。
        cache[album.albumUid] = MusicAlbumReleaseMatchEntry(
          releaseId: releaseId,
          checkedAtMs: _now().millisecondsSinceEpoch,
        );
        await _save(cache);
        if (releaseId != null && !_matched.isClosed) {
          _matched.add(album.albumUid);
        }
      }
    } finally {
      if (identical(_activeProvider, provider)) _activeProvider = null;
      provider.close();
    }
  }

  Future<Map<String, MusicAlbumReleaseMatchEntry>> _load() {
    final Map<String, MusicAlbumReleaseMatchEntry>? c = _cache;
    if (c != null) {
      return Future<Map<String, MusicAlbumReleaseMatchEntry>>.value(c);
    }
    return _loading ??= _readCache().then((
      Map<String, MusicAlbumReleaseMatchEntry> v,
    ) {
      _cache = v;
      _loading = null;
      return v;
    });
  }

  Future<File> _cacheFile() async => File(
    p.join((await _cacheDirectory()).path, kMusicAlbumReleaseMatchesFile),
  );

  Future<Map<String, MusicAlbumReleaseMatchEntry>> _readCache() async {
    final Map<String, MusicAlbumReleaseMatchEntry> out =
        <String, MusicAlbumReleaseMatchEntry>{};
    final File f = await _cacheFile();
    if (!f.existsSync()) return out;
    try {
      final Object? json = jsonDecode(await f.readAsString());
      final Object? albums = json is Map<String, Object?>
          ? json['albums']
          : null;
      if (albums is Map<String, Object?>) {
        for (final MapEntry<String, Object?> e in albums.entries) {
          final MusicAlbumReleaseMatchEntry? v =
              MusicAlbumReleaseMatchEntry.fromJson(e.value);
          if (v != null) out[e.key] = v;
        }
      }
    } on FormatException catch (e) {
      // 坏文件（半截写入不会发生——原子写；这里只防手改）：当没查过，下一轮重建。
      debugPrint('[music-release-match] cache unreadable, rebuilding: $e');
    }
    return out;
  }

  Future<void> _save(Map<String, MusicAlbumReleaseMatchEntry> cache) async {
    final File f = await _cacheFile();
    await f.parent.create(recursive: true);
    final File tmp = File('${f.path}.tmp');
    await tmp.writeAsString(
      jsonEncode(<String, Object?>{
        'version': 1,
        'albums': <String, Object?>{
          for (final MapEntry<String, MusicAlbumReleaseMatchEntry> e
              in cache.entries)
            e.key: e.value.toJson(),
        },
      }),
      flush: true,
    );
    await tmp.rename(f.path);
  }
}
