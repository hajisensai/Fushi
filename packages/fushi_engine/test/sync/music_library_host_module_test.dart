/// 互联共享音乐库 host 模块（设计 docs/specs/2026-11-23-interconnect-music-library-design.md §4）：对真实
/// [FushiSyncServer] + 内存库跑路由、统一流票、写回。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/host/engine_music_library_host.dart';
import 'package:fushi_engine/media/music/host/music_stream_materializer.dart';
import 'package:fushi_engine/media/music/metadata/music_video_match.dart'
    show MusicVideoKind;
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/interconnect_module.dart';
import 'package:fushi_engine/sync/library_media_streams.dart';
import 'package:fushi_engine/sync/music_library_host_module.dart';
import 'package:fushi_engine/sync/remote_music_dto.dart';
import 'package:test/test.dart';

const String _token = 'music-host-token';

String _basic(String password) =>
    'Basic ${base64Encode(utf8.encode('hibiki:$password'))}';

typedef _Res = ({int status, List<int> bytes, String body});

Future<_Res> _send(
  FushiSyncServer server,
  String method,
  String pathAndQuery, {
  bool auth = true,
  Object? json,
  Map<String, String> headers = const <String, String>{},
}) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest req = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${server.port}$pathAndQuery'),
    );
    if (auth) req.headers.set('authorization', _basic(_token));
    headers.forEach(req.headers.set);
    if (json != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(json));
    }
    final HttpClientResponse res = await req.close();
    final List<int> bytes = <int>[
      for (final List<int> c in await res.toList()) ...c,
    ];
    return (
      status: res.statusCode,
      bytes: bytes,
      body: utf8.decode(bytes, allowMalformed: true),
    );
  } finally {
    client.close(force: true);
  }
}

Map<String, Object?> _obj(_Res r) => jsonDecode(r.body) as Map<String, Object?>;

List<Map<String, Object?>> _items(_Res r) => <Map<String, Object?>>[
  for (final Object? e in _obj(r)['items']! as List<Object?>)
    e! as Map<String, Object?>,
];

void main() {
  late Directory tmp;
  late FushiDatabase db;
  late FushiSyncServer server;
  late File song1;
  late File song2;
  late File mv;
  late File cover;
  late int mvId;

  Future<void> track(
    String uid, {
    required String path,
    String? albumUid,
    int? trackNo,
    int? sourceId,
    int? cueStart,
    bool embeddedCover = false,
  }) => db
      .into(db.musicTracks)
      .insert(
        MusicTracksCompanion.insert(
          trackUid: uid,
          path: path,
          title: 'Title $uid',
          albumUid: Value<String?>(albumUid),
          trackNo: Value<int?>(trackNo),
          sourceId: Value<int?>(sourceId),
          cueStartMs: Value<int?>(cueStart),
          durationMs: const Value<int?>(180000),
          codec: const Value<String?>('flac'),
          hasEmbeddedCover: Value<bool>(embeddedCover),
          artistCredit: const Value<String?>('Aimer'),
          fileMtimeAt: 1,
          fileSize: 1000,
          addedAt: 1,
        ),
      );

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('music_host_module_');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    song1 = File('${tmp.path}/a/01 Song.flac')
      ..createSync(recursive: true)
      ..writeAsBytesSync(List<int>.generate(4000, (int i) => i % 251));
    song2 = File('${tmp.path}/a/02 Other.flac')
      ..writeAsBytesSync(List<int>.filled(500, 7));
    File('${tmp.path}/a/02 Other.lrc').writeAsStringSync('[00:01.00]hello');
    mv = File('${tmp.path}/mv/BDMV/STREAM/00001.m2ts')
      ..createSync(recursive: true)
      ..writeAsBytesSync(List<int>.filled(3000, 9));
    cover = File('${tmp.path}/a/cover.jpg')
      ..writeAsBytesSync(<int>[0xff, 0xd8, 0xff, 1, 2, 3]);
    await db
        .into(db.musicAlbums)
        .insert(
          MusicAlbumsCompanion.insert(
            albumUid: 'alb1',
            title: 'First Album',
            albumArtistCredit: const Value<String?>('Aimer'),
            coverPath: Value<String?>(cover.path),
            addedAt: 1,
            updatedAt: 5,
          ),
        );
    await db
        .into(db.musicAlbums)
        .insert(
          MusicAlbumsCompanion.insert(
            albumUid: 'alb2',
            title: 'Second Album',
            addedAt: 1,
            updatedAt: 9,
          ),
        );
    await track('t2', path: song2.path, albumUid: 'alb1', trackNo: 2);
    await track('t1', path: song1.path, albumUid: 'alb1', trackNo: 1);
    await track('cd', path: 'cdda://E:', albumUid: 'alb2', trackNo: 1);
    await track(
      'net',
      path: 'sftp://nas/music/x.flac',
      albumUid: 'alb2',
      trackNo: 2,
      sourceId: 3,
    );
    await db
        .into(db.musicLyrics)
        .insert(
          MusicLyricsCompanion.insert(
            trackUid: 't1',
            source: 'embedded',
            format: 'lrc',
            raw: Uint8List.fromList(utf8.encode('[00:00.50]emb')),
            updatedAt: 100,
          ),
        );
    await db.upsertMusicVideo(
      MusicVideosCompanion.insert(
        trackUid: 't1',
        kind: MusicVideoKind.local,
        ref: mv.path,
        offsetMs: const Value<int>(1200),
        updatedAt: 10,
      ),
    );
    await db.upsertMusicVideo(
      MusicVideosCompanion.insert(
        trackUid: 't1',
        kind: MusicVideoKind.youtube,
        ref: 'https://www.youtube.com/watch?v=abc',
        updatedAt: 10,
      ),
    );
    await db.upsertMusicVideo(
      MusicVideosCompanion.insert(
        trackUid: 't2',
        kind: MusicVideoKind.local,
        ref: '${tmp.path}/missing.mkv',
        updatedAt: 10,
      ),
    );
    mvId = (await db.listMusicVideos(
      't1',
    )).firstWhere((MusicVideoRow r) => r.kind == MusicVideoKind.local).id;
    server = FushiSyncServer(
      syncDataDir: tmp.path,
      port: 0,
      token: _token,
      modules: <InterconnectHostModule>[
        MusicLibraryHostModule(
          EngineMusicLibraryHost(database: () => db, cddaSupported: false),
        ),
      ],
    );
    await server.start();
  });

  tearDown(() async {
    await server.stop();
    await db.close();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  test('能力位：music 对象，带回写种类', () async {
    final Map<String, Object?> caps = _obj(
      await _send(server, 'GET', '/api/capabilities'),
    );
    expect(caps['music'], <String, Object?>{
      'v': 1,
      'lyrics': true,
      'videos': true,
      'writeback': RemoteMusicWriteback.all,
      'transcode': true,
      'relay': true,
      'discs': true,
    });
  });

  test('专辑分页、曲目按轨号、放不了的标原因', () async {
    final _Res page = await _send(
      server,
      'GET',
      '/api/library/music/albums?limit=1',
    );
    expect(_obj(page)['nextOffset'], 1);
    expect(_obj(page)['total'], 2);
    expect(_items(page).single['id'], 'alb1');
    expect(_items(page).single['trackCount'], 2);
    expect(_items(page).single['coverRef'], 'a:alb1');

    final List<Map<String, Object?>> tracks = _items(
      await _send(server, 'GET', '/api/library/music/albums/alb1/tracks'),
    );
    expect(tracks.map((Map<String, Object?> t) => t['id']), <String>[
      't1',
      't2',
    ]);
    expect(tracks.first['peerPlayable'], true);
    expect(tracks.first['hasVideos'], true);

    final List<Map<String, Object?>> other = _items(
      await _send(server, 'GET', '/api/library/music/albums/alb2/tracks'),
    );
    expect(
      <Object?>[
        for (final Map<String, Object?> t in other) t['unplayableReason'],
      ],
      <String>[RemoteMusicUnplayable.cdda, RemoteMusicUnplayable.networkSource],
    );
  });

  test('歌单：跳过 host 曲库以外的条目，带条目 id；写回新建 / 加 / 删 / 挪 / 改名 / 删除', () async {
    final MusicPlaylistRow pl = await db.createMusicPlaylist(
      'Mix',
      at: 1,
      trackUids: <String>['t1', 'srv-remote-uid', 't2'],
    );
    Future<List<Map<String, Object?>>> list() async => _items(
      await _send(
        server,
        'GET',
        '/api/library/music/playlists/${pl.playlistUid}/tracks',
      ),
    );
    final List<Map<String, Object?>> first = await list();
    expect(first.map((Map<String, Object?> t) => t['id']), <String>[
      't1',
      't2',
    ]);
    expect(first.first['playlistEntryId'], isNotNull);

    expect(
      (await _send(
        server,
        'POST',
        '/api/library/music/playlists/${pl.playlistUid}/tracks',
        json: <String, Object?>{
          'trackIds': <String>['t1', 'not-in-host'],
        },
      )).status,
      204,
    );
    List<Map<String, Object?>> now = await list();
    expect(now.map((Map<String, Object?> t) => t['id']), <String>[
      't1',
      't2',
      't1',
    ]);
    expect(
      (await _send(
        server,
        'PUT',
        '/api/library/music/playlists/${pl.playlistUid}/entries/'
            '${now.last['playlistEntryId']}/position',
        json: <String, Object?>{'index': 0},
      )).status,
      204,
    );
    expect(
      (await _send(
        server,
        'POST',
        '/api/library/music/playlists/${pl.playlistUid}/entries/remove',
        json: <String, Object?>{
          'entryIds': <String>['${first.first['playlistEntryId']}'],
        },
      )).status,
      204,
    );
    now = await list();
    expect(now.map((Map<String, Object?> t) => t['id']), <String>['t1', 't2']);

    expect(
      (await _send(
        server,
        'PUT',
        '/api/library/music/playlists/${pl.playlistUid}',
        json: <String, Object?>{'name': 'Renamed'},
      )).status,
      204,
    );
    expect((await db.getMusicPlaylist(pl.playlistUid))!.name, 'Renamed');

    final _Res created = await _send(
      server,
      'POST',
      '/api/library/music/playlists',
      json: <String, Object?>{
        'name': 'New',
        'trackIds': <String>['t2'],
      },
    );
    expect(_obj(created)['trackCount'], 1);
    expect(
      (await _send(
        server,
        'DELETE',
        '/api/library/music/playlists/${_obj(created)['id']}',
      )).status,
      204,
    );
    expect(await db.getMusicPlaylist(_obj(created)['id']! as String), isNull);
  });

  test('智能歌单不能加歌（409）', () async {
    await db
        .into(db.musicPlaylists)
        .insert(
          MusicPlaylistsCompanion.insert(
            playlistUid: 'smart',
            name: 'Smart',
            rulesJson: const Value<String?>('{}'),
            createdAt: 1,
            updatedAt: 1,
          ),
        );
    expect(
      (await _send(
        server,
        'POST',
        '/api/library/music/playlists/smart/tracks',
        json: <String, Object?>{
          'trackIds': <String>['t1'],
        },
      )).status,
      409,
    );
  });

  test('搜索与单曲', () async {
    final Map<String, Object?> r = _obj(
      await _send(server, 'GET', '/api/library/music/search?q=first'),
    );
    expect((r['albums']! as List<Object?>).length, 1);
    final Map<String, Object?> t = _obj(
      await _send(server, 'GET', '/api/library/music/tracks/t2'),
    );
    expect(t['album'], 'First Album');
    expect(
      (await _send(server, 'GET', '/api/library/music/tracks/nope')).status,
      404,
    );
  });

  test('歌词：库里的行优先；没有时现读 sidecar；都没有 204', () async {
    final RemoteMusicLyrics emb = RemoteMusicLyrics.fromJson(
      _obj(await _send(server, 'GET', '/api/library/music/tracks/t1/lyrics')),
    )!;
    expect(emb.source, 'embedded');
    expect(utf8.decode(emb.raw), '[00:00.50]emb');
    final RemoteMusicLyrics side = RemoteMusicLyrics.fromJson(
      _obj(await _send(server, 'GET', '/api/library/music/tracks/t2/lyrics')),
    )!;
    expect(side.source, 'sidecar');
    expect(side.format, 'lrc');
    expect(
      (await _send(
        server,
        'GET',
        '/api/library/music/tracks/net/lyrics',
      )).status,
      204,
    );
  });

  test('歌词写回：偏移按 updatedAt LWW，换来源写成手动指定', () async {
    Future<int> put(int offset, int at) async =>
        _obj(
              await _send(
                server,
                'PUT',
                '/api/library/music/tracks/t1/lyrics/offset',
                json: <String, Object?>{
                  'source': 'embedded',
                  'offsetMs': offset,
                  'updatedAt': at,
                },
              ),
            )['offsetMs']!
            as int;
    expect(await put(300, 200), 300);
    expect(await put(-500, 150), 300, reason: '旧写入不生效');
    expect(
      (await _send(
        server,
        'PUT',
        '/api/library/music/tracks/t1/lyrics',
        json: <String, Object?>{
          'format': 'ttml',
          'raw': base64Encode(utf8.encode('<tt/>')),
          'offsetMs': 40,
        },
      )).status,
      204,
    );
    final RemoteMusicLyrics now = RemoteMusicLyrics.fromJson(
      _obj(await _send(server, 'GET', '/api/library/music/tracks/t1/lyrics')),
    )!;
    expect(now.source, 'user');
    expect(now.isUserEdited, isTrue);
    expect(now.offsetMs, 40);
  });

  test('统一流票：曲目 Range 取流；放不了的拒签；MV 绑定与流；偏移写回', () async {
    final _Res issued = await _send(
      server,
      'POST',
      kLibraryMediaStreamUrlPath,
      json: <String, Object?>{'kind': 'musicTrack', 'id': 't1'},
    );
    expect(issued.status, 200);
    final Uri url = Uri.parse(_obj(issued)['url']! as String);
    final _Res ranged = await _send(
      server,
      'GET',
      '${url.path}?${url.query}',
      auth: false,
      headers: <String, String>{'range': 'bytes=0-99'},
    );
    expect(ranged.status, 206);
    expect(ranged.bytes, song1.readAsBytesSync().sublist(0, 100));
    for (final String uid in <String>['cd', 'net', 'nope']) {
      expect(
        (await _send(
          server,
          'POST',
          kLibraryMediaStreamUrlPath,
          json: <String, Object?>{'kind': 'musicTrack', 'id': uid},
        )).status,
        404,
        reason: uid,
      );
    }

    final List<RemoteMusicVideo> videos = <RemoteMusicVideo>[
      for (final Map<String, Object?> v in _items(
        await _send(server, 'GET', '/api/library/music/tracks/t1/videos'),
      ))
        RemoteMusicVideo.fromJson(v)!,
    ];
    expect(videos.map((RemoteMusicVideo v) => v.kind).toSet(), <String>{
      MusicVideoKind.local,
      MusicVideoKind.youtube,
    });
    expect(
      videos.firstWhere((RemoteMusicVideo v) => v.kind == 'youtube').youtubeRef,
      'https://www.youtube.com/watch?v=abc',
    );
    expect(
      _items(await _send(server, 'GET', '/api/library/music/tracks/t2/videos')),
      isEmpty,
      reason: '文件不在的绑定不出',
    );
    final _Res mvIssued = await _send(
      server,
      'POST',
      kLibraryMediaStreamUrlPath,
      json: <String, Object?>{'kind': 'musicVideo', 'id': '$mvId'},
    );
    final Uri mvUrl = Uri.parse(_obj(mvIssued)['url']! as String);
    final _Res mvBytes = await _send(
      server,
      'GET',
      '${mvUrl.path}?${mvUrl.query}',
      auth: false,
    );
    expect(mvBytes.status, 200);
    expect(mvBytes.bytes.length, 3000);

    expect(
      _obj(
        await _send(
          server,
          'PUT',
          '/api/library/music/videos/$mvId/offset',
          json: <String, Object?>{'offsetMs': 1300, 'updatedAt': 99},
        ),
      )['offsetMs'],
      1300,
    );
    expect(
      (await db.listMusicVideos(
        't1',
      )).firstWhere((MusicVideoRow r) => r.id == mvId).offsetMs,
      1300,
    );
  });

  test('封面：专辑目录封面', () async {
    final _Res r = await _send(
      server,
      'GET',
      '/api/library/music/covers/a:alb1',
    );
    expect(r.status, 200);
    expect(r.bytes, cover.readAsBytesSync());
    expect(
      (await _send(server, 'GET', '/api/library/music/covers/a:alb2')).status,
      404,
    );
  });

  test('没接音乐库：能力位无 music，路由 404', () async {
    final FushiSyncServer bare = FushiSyncServer(
      syncDataDir: '${tmp.path}/bare',
      port: 0,
      token: _token,
      modules: <InterconnectHostModule>[MusicLibraryHostModule(null)],
    );
    await bare.start();
    addTearDown(bare.stop);
    expect(
      _obj(await _send(bare, 'GET', '/api/capabilities')).containsKey('music'),
      isFalse,
    );
    final _Res r = await _send(bare, 'GET', '/api/library/music/albums');
    expect(r.status, 404);
    expect(r.body, 'Music library off');
  });

  group('host 给字节：网络来源中继 / 光盘与 CDDA 截段 / 转码（design-imusic-q4 / q5 / q6）', () {
    late HttpServer upstream;
    late FushiSyncServer full;
    late List<List<String>> ffmpegCalls;
    late List<({String drive, int start, int? end})> cddaCalls;
    final List<int> remoteBytes = List<int>.generate(5000, (int i) => i % 199);
    String? upstreamAuth;

    setUp(() async {
      upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstream.listen((HttpRequest r) async {
        upstreamAuth = r.headers.value('authorization');
        final String? range = r.headers.value('range');
        if (range != null) {
          final RegExpMatch m = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range)!;
          final int a = int.parse(m[1]!);
          final int b = int.parse(m[2]!);
          r.response.statusCode = 206;
          r.response.headers.set(
            'content-range',
            'bytes $a-$b/${remoteBytes.length}',
          );
          r.response.add(remoteBytes.sublist(a, b + 1));
        } else {
          r.response.add(remoteBytes);
        }
        await r.response.close();
      });
      ffmpegCalls = <List<String>>[];
      cddaCalls = <({String drive, int start, int? end})>[];
      await track(
        'disc',
        path: '${tmp.path}/bd/BDMV/PLAYLIST/00800.mpls',
        albumUid: 'alb2',
        trackNo: 3,
        cueStart: 60000,
      );
      final MusicStreamMaterializer materializer = MusicStreamMaterializer(
        cacheDir: Directory('${tmp.path}/cache'),
        ffmpeg: (List<String> args) async {
          ffmpegCalls.add(args);
          // 替身：把参数写进输出文件，测试据此核对。
          File(args.last).writeAsStringSync(args.join(' '));
          return (code: 0, output: '');
        },
        cdda:
            ({
              required String drivePath,
              required int startMs,
              int? endMs,
              required String wavPath,
            }) async {
              cddaCalls.add((drive: drivePath, start: startMs, end: endMs));
              File(wavPath).writeAsBytesSync(<int>[1, 2, 3]);
            },
      );
      full = FushiSyncServer(
        syncDataDir: tmp.path,
        port: 0,
        token: _token,
        modules: <InterconnectHostModule>[
          MusicLibraryHostModule(
            EngineMusicLibraryHost(
              database: () => db,
              cddaSupported: true,
              materializer: materializer,
              networkSource: (MusicTrackRow t) async => (
                url: Uri.parse('http://127.0.0.1:${upstream.port}/x.flac'),
                headers: <String, String>{'Authorization': 'Basic nas'},
              ),
            ),
          ),
        ],
      );
      await full.start();
    });

    tearDown(() async {
      await full.stop();
      await upstream.close(force: true);
    });

    Future<({Map<String, Object?> issued, _Res bytes})> play(
      String uid, {
      Map<String, Object?>? options,
      Map<String, String> headers = const <String, String>{},
    }) async {
      final _Res issued = await _send(
        full,
        'POST',
        kLibraryMediaStreamUrlPath,
        json: <String, Object?>{
          'kind': 'musicTrack',
          'id': uid,
          'options': ?options,
        },
      );
      expect(issued.status, 200, reason: issued.body);
      final Uri url = Uri.parse(_obj(issued)['url']! as String);
      return (
        issued: _obj(issued),
        bytes: await _send(
          full,
          'GET',
          '${url.path}?${url.query}',
          auth: false,
          headers: headers,
        ),
      );
    }

    test('能力位与曲目列表：这台 host 给得出字节的都不标原因', () async {
      final Map<String, Object?> music =
          _obj(await _send(full, 'GET', '/api/capabilities'))['music']!
              as Map<String, Object?>;
      expect(music['transcode'], true);
      expect(music['relay'], true);
      final List<Map<String, Object?>> other = _items(
        await _send(full, 'GET', '/api/library/music/albums/alb2/tracks'),
      );
      expect(
        other.map((Map<String, Object?> t) => t['unplayableReason']),
        everyElement(isNull),
      );
    });

    test('网络来源：host 带自己的凭据代读，Range 透传，client 不见上游凭据', () async {
      final r = await play(
        'net',
        headers: <String, String>{'range': 'bytes=10-19'},
      );
      expect(r.issued['segmentApplied'], false);
      expect(r.issued['transcoded'], false);
      expect(r.bytes.status, 206);
      expect(r.bytes.bytes, remoteBytes.sublist(10, 20));
      expect(upstreamAuth, 'Basic nas');
      expect(r.issued.toString(), isNot(contains('nas')));
    });

    test('光盘标题：按章节起止截成 FLAC，告诉 client 段已应用', () async {
      final r = await play('disc');
      expect(r.issued['segmentApplied'], true);
      expect(r.bytes.status, 200);
      final List<String> args = ffmpegCalls.single;
      expect(args, containsAllInOrder(<String>['-ss', '60.000', '-i']));
      expect(args, contains('${tmp.path}/bd/BDMV/PLAYLIST/00800.mpls'));
      expect(args, containsAllInOrder(<String>['-c:a', 'flac']));
      // 第二次取流命中缓存，不再跑 ffmpeg。
      await play('disc');
      expect(ffmpegCalls, hasLength(1));
    });

    test('CDDA：Windows 光驱按盘时间轴读一段，再编码', () async {
      final r = await play('cd');
      expect(r.issued['segmentApplied'], true);
      expect(cddaCalls.single.drive, 'E:');
      expect(cddaCalls.single.start, 0);
      expect(ffmpegCalls.single.last, endsWith('.flac.part'));
    });

    test('码率上限：高于上限的转 AAC；网络来源也经 ffmpeg 读上游（带头部）', () async {
      final r = await play(
        't1',
        options: <String, Object?>{kMusicStreamOptionMaxBitrate: 128},
      );
      expect(r.issued['transcoded'], true);
      expect(r.issued['codec'], 'aac');
      expect(r.issued['bitrateKbps'], 128);
      expect(
        ffmpegCalls.single,
        containsAllInOrder(<String>['-c:a', 'aac', '-b:a', '128k']),
      );
      expect(ffmpegCalls.single, contains(song1.path));

      await play(
        'net',
        options: <String, Object?>{kMusicStreamOptionMaxBitrate: 96},
      );
      final List<String> net = ffmpegCalls.last;
      expect(net, containsAllInOrder(<String>['-headers']));
      expect(net.join(' '), contains('Authorization: Basic nas'));
      expect(net, contains('http://127.0.0.1:${upstream.port}/x.flac'));

      // 下载要整首：CUE 虚拟曲目由 host 无损截段。
      await track('cue', path: song1.path, albumUid: 'alb1', cueStart: 3000);
      final rc = await play(
        'cue',
        options: <String, Object?>{kMusicStreamOptionSegment: true},
      );
      expect(rc.issued['segmentApplied'], true);
      expect(ffmpegCalls.last, containsAllInOrder(<String>['-c:a', 'flac']));
      expect(ffmpegCalls.last, containsAllInOrder(<String>['-ss', '3.000']));

      // 不合理的上限当没给：原样直出。
      final r2 = await play(
        't1',
        options: <String, Object?>{kMusicStreamOptionMaxBitrate: 4},
      );
      expect(r2.issued['transcoded'], false);
      expect(r2.bytes.bytes, song1.readAsBytesSync());
    });
  });
}
