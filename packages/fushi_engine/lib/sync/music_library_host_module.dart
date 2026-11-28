/// 互联共享音乐库的 host 模块（设计 docs/specs/2026-11-23-interconnect-music-library-design.md §4，第一个
/// 按统一模块层写的功能，§3.5）。
///
/// 与视频库、书库同级（拍板 design-imusic-q2：不另设开关，跟着互联总开关走）：任何已过 Basic 的已配对
/// 设备都能读。路由全在 [kRemoteMusicRoutePrefix] 下，取流用统一流票（`musicTrack` / `musicVideo`），
/// 原样直出、不转码。客户端上的修改（歌词偏移 / 换来源、MV 微调、歌单编辑）写回 host
/// （design-imusic-q3：照合集的做法）。
///
/// | 路由 | 说明 |
/// |---|---|
/// | `GET albums?offset&limit&sort` | 专辑页 |
/// | `GET albums/<uid>/tracks` | 专辑曲目 |
/// | `GET artists?offset&limit`、`GET artists/<uid>/albums` | 艺人 |
/// | `GET playlists?offset&limit`、`POST playlists {name, trackIds}` | 歌单 / 新建 |
/// | `GET playlists/<uid>/tracks`、`POST playlists/<uid>/tracks {trackIds}` | 歌单曲目 / 加歌 |
/// | `POST playlists/<uid>/entries/remove {entryIds}` | 删条目 |
/// | `PUT playlists/<uid>/entries/<entryId>/position {index}` | 挪条目 |
/// | `PUT playlists/<uid> {name}`、`DELETE playlists/<uid>` | 改名 / 删除 |
/// | `GET search?q&limit` | 搜索 |
/// | `GET tracks/<uid>` | 单曲 |
/// | `GET tracks/<uid>/lyrics`（204 = 没有）、`PUT tracks/<uid>/lyrics {format, raw, offsetMs}` | 歌词 / 换来源 |
/// | `PUT tracks/<uid>/lyrics/offset {source, offsetMs, updatedAt}` | 整首偏移 |
/// | `GET tracks/<uid>/videos`、`PUT videos/<id>/offset {offsetMs, updatedAt}` | MV 绑定 / 微调 |
/// | `POST tracks/<uid>/videos/rematch`、`GET tracks/<uid>/videos/candidates?source=anime|online` | 请 host 重新匹配 / 候选（q9） |
/// | `POST tracks/<uid>/videos {kind, ref, …}`、`DELETE tracks/<uid>/videos/<id>` | 手动绑定 / 解绑（q9） |
/// | `GET covers/<ref>` | 封面 |
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/media/music/host/engine_music_library_host.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart'
    show serveFileWithRange;
import 'package:fushi_engine/sync/interconnect_module.dart';
import 'package:fushi_engine/sync/library_media_streams.dart';
import 'package:fushi_engine/sync/remote_music_dto.dart';
import 'package:shelf/shelf.dart' as shelf;

class MusicLibraryHostModule extends InterconnectHostModule {
  MusicLibraryHostModule(this.host);

  /// null = 这台 host 不提供音乐库（能力位无 `music`，路由 404）。
  final EngineMusicLibraryHost? host;

  @override
  String get name => kRemoteMusicCapability;

  @override
  List<InterconnectCapability> get capabilities => <InterconnectCapability>[
    InterconnectCapability(kRemoteMusicCapability, capability),
  ];

  /// 能力值；null = 本 host 此刻不提供（键不出现）。
  Future<Object?> capability() async {
    final EngineMusicLibraryHost? h = host;
    if (h == null || !h.available) return null;
    return <String, Object?>{
      'v': kRemoteMusicWireVersion,
      'lyrics': true,
      'videos': true,
      'writeback': RemoteMusicWriteback.all,
      // 签票可带码率上限（design-imusic-q6）；光盘 / CDDA / 网络来源经 host 给（q4 / q5）。
      'transcode': true,
      'relay': true,
      'discs': true,
      // 能不能请这台 host 重新匹配 / 手动绑定 MV（design-imusic-q9；无头服务端没有匹配器）。
      'videoMatch': h.videoMatcher != null,
    };
  }

  @override
  List<InterconnectRoute> get routes => <InterconnectRoute>[
    InterconnectRoute(
      const InterconnectPath.subtree(kRemoteMusicRoutePrefix),
      trust: InterconnectTrust.credential,
      handler: handle,
    ),
  ];

  @override
  Map<LibraryMediaStreamKind, LibraryMediaResolver> get streamResolvers {
    final EngineMusicLibraryHost? h = host;
    if (h == null) {
      return const <LibraryMediaStreamKind, LibraryMediaResolver>{};
    }
    return <LibraryMediaStreamKind, LibraryMediaResolver>{
      LibraryMediaStreamKind.musicTrack: h.trackSource,
      LibraryMediaStreamKind.musicVideo: (LibraryMediaRequest r) async {
        final File? f = await h.videoFile(r.id);
        return f == null ? null : LibraryMediaFile(f);
      },
    };
  }

  Future<shelf.Response> handle(InterconnectRequest request) async {
    final EngineMusicLibraryHost? h = host;
    if (h == null || !h.available) {
      return shelf.Response.notFound('Music library off');
    }
    final List<String> seg = request.path
        .substring(kRemoteMusicRoutePrefix.length)
        .split('/')
        .where((String s) => s.isNotEmpty)
        .toList();
    final String method = request.method.toUpperCase();
    final Map<String, String> q = request.raw.url.queryParameters;
    try {
      return await _route(h, request, method, seg, q);
    } on MusicHostWriteError catch (e) {
      return shelf.Response(e.status, body: e.message);
    } on FormatException catch (e) {
      return shelf.Response(400, body: e.message);
    }
  }

  Future<shelf.Response> _route(
    EngineMusicLibraryHost h,
    InterconnectRequest request,
    String method,
    List<String> seg,
    Map<String, String> q,
  ) async {
    if (seg.isEmpty) return shelf.Response.notFound('Not found');
    final int offset = int.tryParse(q['offset'] ?? '') ?? 0;
    final int limit = int.tryParse(q['limit'] ?? '') ?? kRemoteMusicPageLimit;
    switch (seg) {
      case <String>['albums']:
        if (method != 'GET') return shelf.Response(405);
        return _json(
          (await h.listAlbums(
            offset: offset,
            limit: limit,
            sort: q['sort'] ?? 'name',
          )).toJson((RemoteMusicAlbum a) => a.toJson()),
        );
      case <String>['albums', final String uid, 'tracks']:
        if (method != 'GET') return shelf.Response(405);
        return _tracks(await h.albumTracks(uid));
      case <String>['artists']:
        if (method != 'GET') return shelf.Response(405);
        return _json(
          (await h.listArtists(
            offset: offset,
            limit: limit,
          )).toJson((RemoteMusicArtist a) => a.toJson()),
        );
      case <String>['artists', final String uid, 'albums']:
        if (method != 'GET') return shelf.Response(405);
        return _json(<String, Object?>{
          'items': <Object?>[
            for (final RemoteMusicAlbum a in await h.artistAlbums(uid))
              a.toJson(),
          ],
        });
      case <String>['playlists']:
        if (method == 'GET') {
          return _json(
            (await h.listPlaylists(
              offset: offset,
              limit: limit,
            )).toJson((RemoteMusicPlaylist p) => p.toJson()),
          );
        }
        if (method != 'POST') return shelf.Response(405);
        final Map<String, Object?> body = await _body(request);
        return _json(
          (await h.createPlaylist(
            _string(body, 'name'),
            trackUids: _strings(body, 'trackIds'),
          )).toJson(),
        );
      case <String>['playlists', final String uid]:
        if (method == 'PUT') {
          await h.renamePlaylist(uid, _string(await _body(request), 'name'));
          return shelf.Response(204);
        }
        if (method == 'DELETE') {
          await h.deletePlaylist(uid);
          return shelf.Response(204);
        }
        return shelf.Response(405);
      case <String>['playlists', final String uid, 'tracks']:
        if (method == 'GET') return _tracks(await h.playlistTracks(uid));
        if (method != 'POST') return shelf.Response(405);
        await h.addToPlaylist(uid, _strings(await _body(request), 'trackIds'));
        return shelf.Response(204);
      case <String>['playlists', final String uid, 'entries', 'remove']:
        if (method != 'POST') return shelf.Response(405);
        await h.removeFromPlaylist(
          uid,
          _strings(await _body(request), 'entryIds'),
        );
        return shelf.Response(204);
      case <String>[
        'playlists',
        final String uid,
        'entries',
        final String entry,
        'position',
      ]:
        if (method != 'PUT') return shelf.Response(405);
        final Object? index = (await _body(request))['index'];
        if (index is! int) throw const FormatException('index');
        await h.movePlaylistEntry(uid, entry, index);
        return shelf.Response(204);
      case <String>['search']:
        if (method != 'GET') return shelf.Response(405);
        return _json(
          (await h.search(
            q['q'] ?? '',
            limit: int.tryParse(q['limit'] ?? '') ?? 30,
          )).toJson(),
        );
      case <String>['tracks', final String uid]:
        if (method != 'GET') return shelf.Response(405);
        final RemoteMusicTrack? t = await h.track(uid);
        return t == null
            ? shelf.Response.notFound('Track not found')
            : _json(t.toJson());
      case <String>['tracks', final String uid, 'lyrics']:
        if (method == 'GET') {
          final RemoteMusicLyrics? l = await h.lyrics(uid);
          return l == null ? shelf.Response(204) : _json(l.toJson());
        }
        if (method != 'PUT') return shelf.Response(405);
        final Map<String, Object?> body = await _body(request);
        final Uint8List raw;
        try {
          raw = base64Decode(_string(body, 'raw'));
        } on FormatException {
          throw const FormatException('raw');
        }
        final bool ok = await h.chooseLyrics(
          uid,
          format: _string(body, 'format'),
          raw: raw,
          offsetMs: _intOr(body, 'offsetMs', 0),
        );
        return ok
            ? shelf.Response(204)
            : shelf.Response.notFound('Track not found');
      case <String>['tracks', final String uid, 'lyrics', 'offset']:
        if (method != 'PUT') return shelf.Response(405);
        final Map<String, Object?> body = await _body(request);
        final int? applied = await h.setLyricsOffset(
          uid,
          source: _string(body, 'source'),
          offsetMs: _intOr(body, 'offsetMs', 0),
          updatedAt: _intOr(body, 'updatedAt', 0),
        );
        return applied == null
            ? shelf.Response.notFound('Lyrics not found')
            : _json(<String, Object?>{'offsetMs': applied});
      case <String>['tracks', final String uid, 'videos']:
        if (method == 'POST') {
          final RemoteMusicVideoCandidate? c =
              RemoteMusicVideoCandidate.fromJson(await _body(request));
          if (c == null) return shelf.Response(400, body: 'Bad candidate');
          return _json(<String, Object?>{
            'items': <Object?>[
              for (final RemoteMusicVideo v in await h.bindVideo(uid, c))
                v.toJson(),
            ],
          });
        }
        if (method != 'GET') return shelf.Response(405);
        return _json(<String, Object?>{
          'items': <Object?>[
            for (final RemoteMusicVideo v in await h.videos(uid)) v.toJson(),
          ],
        });
      case <String>['tracks', final String uid, 'videos', 'rematch']:
        if (method != 'POST') return shelf.Response(405);
        return _json(<String, Object?>{'bound': await h.rematchVideos(uid)});
      case <String>['tracks', final String uid, 'videos', 'candidates']:
        if (method != 'GET') return shelf.Response(405);
        return _json(<String, Object?>{
          'items': <Object?>[
            for (final RemoteMusicVideoCandidate c in await h.videoCandidates(
              uid,
              q['source'] ?? '',
            ))
              c.toJson(),
          ],
        });
      case <String>['tracks', final String uid, 'videos', final String id]:
        if (method != 'DELETE') return shelf.Response(405);
        final int? videoId = int.tryParse(id);
        if (videoId == null || !await h.unbindVideo(uid, videoId)) {
          return shelf.Response.notFound('Video not found');
        }
        return shelf.Response(204);
      case <String>['videos', final String id, 'offset']:
        if (method != 'PUT') return shelf.Response(405);
        final int? videoId = int.tryParse(id);
        if (videoId == null) return shelf.Response.notFound('Video not found');
        final Map<String, Object?> body = await _body(request);
        final int? applied = await h.setVideoOffset(
          videoId,
          offsetMs: _intOr(body, 'offsetMs', 0),
          updatedAt: _intOr(body, 'updatedAt', 0),
        );
        return applied == null
            ? shelf.Response.notFound('Video not found')
            : _json(<String, Object?>{'offsetMs': applied});
      case <String>['covers', final String ref]:
        if (method != 'GET' && method != 'HEAD') return shelf.Response(405);
        final MusicHostCover? cover = await h.cover(ref);
        if (cover == null) return shelf.Response.notFound('No cover');
        final File? file = cover.file;
        if (file != null) return serveFileWithRange(file, request.raw);
        final Uint8List bytes = cover.bytes!;
        return shelf.Response.ok(
          bytes,
          headers: <String, String>{
            'Content-Type': _imageMime(bytes),
            'Content-Length': '${bytes.length}',
            'Cache-Control': 'private, max-age=3600',
          },
        );
    }
    return shelf.Response.notFound('Not found');
  }

  static shelf.Response _json(Object? body) => shelf.Response.ok(
    jsonEncode(body),
    headers: const <String, String>{'Content-Type': 'application/json'},
  );

  static shelf.Response _tracks(List<RemoteMusicTrack> tracks) =>
      _json(<String, Object?>{
        'items': <Object?>[for (final RemoteMusicTrack t in tracks) t.toJson()],
      });

  static Future<Map<String, Object?>> _body(InterconnectRequest r) async {
    final Object? decoded = jsonDecode(await r.raw.readAsString());
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('body must be a JSON object');
    }
    return decoded;
  }

  static String _string(Map<String, Object?> body, String key) {
    final Object? v = body[key];
    if (v is! String) throw FormatException(key);
    return v;
  }

  static List<String> _strings(Map<String, Object?> body, String key) {
    final Object? v = body[key];
    if (v is! List) throw FormatException(key);
    return <String>[
      for (final Object? e in v)
        if (e is String && e.isNotEmpty) e,
    ];
  }

  static int _intOr(Map<String, Object?> body, String key, int fallback) {
    final Object? v = body[key];
    return v is num ? v.toInt() : fallback;
  }

  static String _imageMime(Uint8List b) {
    if (b.length > 3 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4e) {
      return 'image/png';
    }
    if (b.length > 3 && b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46) {
      return 'image/webp';
    }
    return 'image/jpeg';
  }
}
