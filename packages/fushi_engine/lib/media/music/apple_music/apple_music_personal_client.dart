/// Apple Music 个人数据（已登录用户）：为你推荐、最近播放、重度轮播、个人电台、评分（喜欢 /
/// 不喜欢）与加入资料库。
///
/// 回包里的歌曲一律登记到 [catalog]（[AppleMusicCatalogClient.adoptSongs]），所以从这里拿到的
/// 曲目用 catalog 来源播放、身份（`trackUid`）与在 catalog 里点播同一首一致。专辑 / 歌单条目按
/// [AppleMusicItem.library] 交给 catalog 或资料库来源打开。
///
/// 只用公开的 Apple Music API（`/v1/me/...`）。
///
/// 纯 Dart、不碰 Flutter（引擎纯度守卫）。
library;

import 'dart:async';

import 'package:fushi_engine/media/music/apple_music/apple_music_catalog_client.dart';
import 'package:fushi_engine/media/music/apple_music/apple_music_items.dart';
import 'package:fushi_engine/media/music/apple_music/apple_music_user_api.dart';
import 'package:fushi_engine/media/music/server/music_server.dart';
import 'package:http/http.dart' as http;

/// 可评分 / 可加入资料库的 catalog 资源种类。
enum AppleMusicResourceType {
  song('songs'),
  album('albums'),
  playlist('playlists');

  const AppleMusicResourceType(this.wire);

  final String wire;
}

/// 评分：喜欢 / 不喜欢（Apple 的 1 / -1）。
enum AppleMusicRating {
  love(1),
  dislike(-1);

  const AppleMusicRating(this.value);

  final int value;

  static AppleMusicRating? fromValue(Object? v) => switch (v) {
    1 => AppleMusicRating.love,
    -1 => AppleMusicRating.dislike,
    _ => null,
  };
}

/// 最近播放单页上限（Apple 文档：recent/played `limit` 最大 10，tracks 最大 30）。
const int _kRecentPlayedLimit = 10;
const int _kRecentTracksLimit = 30;

/// 重度轮播单页上限（Apple 文档：heavy-rotation `limit` 最大 10）。
const int _kHeavyRotationLimit = 10;

class AppleMusicPersonalClient {
  AppleMusicPersonalClient({
    required AppleMusicUserCredentialsProvider credentials,
    required this.catalog,
    http.Client? client,
    Uri? apiBase,
  }) : _api = AppleMusicUserApi(
         credentials: credentials,
         client: client,
         apiBase: apiBase,
       );

  final AppleMusicUserApi _api;

  /// 播放用的 catalog 来源（应当是 [AppleMusicCatalogClient.fullTracks] 的那个）。
  final AppleMusicCatalogClient catalog;

  /// 翻 offset 分页，凑满 [total] 条或没有下一页为止。
  Future<List<Object?>> _paged(
    String path,
    int pageLimit,
    int total, [
    Map<String, String> query = const <String, String>{},
  ]) async {
    final List<Object?> out = <Object?>[];
    int offset = 0;
    while (out.length < total) {
      final Map<String, Object?> body = await _api.get(path, <String, String>{
        ...query,
        'limit': '$pageLimit',
        'offset': '$offset',
      });
      final List<Object?> data = appleMusicDataOf(body);
      out.addAll(data);
      final Object? next = body['next'];
      if (data.isEmpty || next is! String || next.isEmpty) break;
      offset += data.length;
    }
    return out.take(total).toList(growable: false);
  }

  /// 歌曲条目登记进 catalog（放不了的丢掉），其余条目原样保留。
  List<AppleMusicItem> _items(List<Object?> raw) {
    final List<AppleMusicItem> out = <AppleMusicItem>[];
    final Set<String> seen = <String>{};
    for (final Object? r in raw) {
      final AppleMusicItem? item;
      if (r is Map<String, Object?> &&
          (r['type'] == 'songs' || r['type'] == 'library-songs')) {
        final MusicServerTrack? t = catalog.adoptSongs(<Object?>[
          r,
        ]).firstOrNull;
        item = t == null ? null : AppleMusicSongItem(t);
      } else {
        item = parseAppleMusicItem(r);
      }
      if (item != null && seen.add(item.key)) out.add(item);
    }
    return out;
  }

  // ---------------------------------------------------------------- 为你推荐 / 最近

  /// 「为你推荐」的各行（Apple 个性化推荐，顺序照回包）。
  Future<List<AppleMusicShelf>> recommendations() async {
    final List<Object?> raw = await _api.getAll(
      '/v1/me/recommendations',
      maxPages: 3,
    );
    final List<AppleMusicShelf> out = <AppleMusicShelf>[];
    for (final Object? r in raw) {
      final AppleMusicShelf? shelf = parseAppleMusicRecommendation(r);
      if (shelf == null) continue;
      // 推荐行里的歌曲同样要能放：重新按 catalog 规则过一遍。
      final Object? rel = r is Map<String, Object?> ? r['relationships'] : null;
      final List<AppleMusicItem> items = _items(
        appleMusicDataOf(rel is Map<String, Object?> ? rel['contents'] : null),
      );
      if (items.isNotEmpty) {
        out.add(AppleMusicShelf(title: shelf.title, items: items));
      }
    }
    return out;
  }

  /// 最近播放的专辑 / 歌单 / 电台。
  Future<List<AppleMusicItem>> recentlyPlayed({int limit = 30}) async =>
      _items(await _paged('/v1/me/recent/played', _kRecentPlayedLimit, limit));

  /// 最近播放的歌曲（catalog 曲目，可直接放）。
  Future<List<MusicServerTrack>> recentTracks({int limit = 60}) async =>
      catalog.adoptSongs(
        await _paged(
          '/v1/me/recent/played/tracks',
          _kRecentTracksLimit,
          limit,
          const <String, String>{'types': 'songs,library-songs'},
        ),
      );

  /// 最近播放的电台。
  Future<List<AppleMusicStation>> recentStations({int limit = 20}) async =>
      <AppleMusicStation>[
        for (final Object? r in await _paged(
          '/v1/me/recent/radio-stations',
          _kRecentPlayedLimit,
          limit,
        ))
          if (parseAppleMusicStation(r) case final AppleMusicStation s) s,
      ];

  /// 重度轮播（最近反复听的专辑 / 歌单）。
  Future<List<AppleMusicItem>> heavyRotation({int limit = 20}) async => _items(
    await _paged('/v1/me/history/heavy-rotation', _kHeavyRotationLimit, limit),
  );

  /// 个人电台（「〇〇的电台」：按收听历史生成）。没有回 null。
  Future<AppleMusicStation?> personalStation() async {
    final Map<String, Object?> body = await _api.get(
      '/v1/catalog/${catalog.storefront}/stations',
      const <String, String>{'filter[identity]': 'personal'},
    );
    return appleMusicDataOf(
      body,
    ).map(parseAppleMusicStation).nonNulls.firstOrNull;
  }

  // ---------------------------------------------------------------- 评分

  String _ratingPath(AppleMusicResourceType type, String id) =>
      '/v1/me/ratings/${type.wire}/${Uri.encodeComponent(id)}';

  /// 当前评分；没评过回 null。
  Future<AppleMusicRating?> rating(
    AppleMusicResourceType type,
    String id,
  ) async {
    final Map<String, Object?> body;
    try {
      body = await _api.get(_ratingPath(type, id));
    } on AppleMusicApiException catch (e) {
      if (e.httpStatus == 404) return null;
      rethrow;
    }
    for (final Object? r in appleMusicDataOf(body)) {
      if (r is! Map<String, Object?>) continue;
      final Object? a = r['attributes'];
      if (a is Map<String, Object?>) {
        return AppleMusicRating.fromValue(a['value']);
      }
    }
    return null;
  }

  /// 设评分；[rating] 为 null = 清掉评分。
  Future<void> setRating(
    AppleMusicResourceType type,
    String id,
    AppleMusicRating? rating,
  ) async {
    if (rating == null) {
      try {
        await _api.send('DELETE', _ratingPath(type, id));
      } on AppleMusicApiException catch (e) {
        // 本来就没评过：已经是目标状态。
        if (e.httpStatus != 404) rethrow;
      }
      return;
    }
    await _api.send(
      'PUT',
      _ratingPath(type, id),
      body: <String, Object?>{
        'type': 'rating',
        'attributes': <String, Object?>{'value': rating.value},
      },
    );
  }

  // ---------------------------------------------------------------- 资料库

  /// 把 catalog 歌曲 / 专辑 / 歌单加入用户资料库（Apple 异步处理，回 202）。
  Future<void> addToLibrary(
    Map<AppleMusicResourceType, List<String>> ids,
  ) async {
    final Map<String, String> query = <String, String>{
      for (final MapEntry<AppleMusicResourceType, List<String>> e
          in ids.entries)
        if (e.value.isNotEmpty) 'ids[${e.key.wire}]': e.value.join(','),
    };
    if (query.isEmpty) return;
    await _api.send('POST', '/v1/me/library', query: query);
  }

  void close() => _api.close();
}
