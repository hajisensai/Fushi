// 反馈 QAondMh4M5：网络音乐来源的曲目起播时按 sourceId 的 transport 取流；服务器曲库 /
// 插件 / 本地曲目的分支不变。
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/mpv_music_output_backend.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_remote_media.dart';
import 'package:fushi/src/media/source_library/source_library_credential_store.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_music/fushi_music.dart' show MusicPluginStream;

class _FakeRemote implements MusicRemoteMediaResolver {
  final List<MusicPlayItem> asked = <MusicPlayItem>[];

  @override
  Future<MusicRemoteStream?> resolve(MusicPlayItem item) async {
    asked.add(item);
    if (item.sourceId != 7) return null;
    return (
      url: 'http://127.0.0.1:4000/cloud/tok/a.flac',
      headers: <String, String>{'X-Test': '1'},
    );
  }

  @override
  void forgetSource(int sourceId) {}
}

void main() {
  test('YouTube 内置音源曲目：起播时按 videoId 取 audio-only 流，带回放头与过期时刻；'
      '算作「起播要联网取流」', () async {
    const MusicPlayItem item = MusicPlayItem(
      trackUid: 'srvyt',
      path: 'fushi-music-youtube://video/dQw4w9WgXcQ',
      title: 'Song',
    );
    expect(musicItemResolvesStream(item), isTrue);
    final List<String> asked = <String>[];
    final MusicResolvedMedia r = await resolveMusicMedia(
      item,
      youtubeResolver: (String id) async {
        asked.add(id);
        return (
          url: 'https://rr1.googlevideo.com/videoplayback?expire=1700000000',
          headers: <String, String>{'User-Agent': 'UA'},
          expiresAt: 1700000000000,
        );
      },
      remoteResolver: _FakeRemote(),
    );
    expect(asked, <String>['dQw4w9WgXcQ']);
    expect(
      r.media.uri,
      'https://rr1.googlevideo.com/videoplayback?expire=1700000000',
    );
    expect(r.media.httpHeaders, <String, String>{'User-Agent': 'UA'});
    expect(r.expiresAt, 1700000000000);
  });

  test('a network-source track plays the resolved URL with its headers; a '
      'CUE track points its EDL segment at the resolved URL', () async {
    final _FakeRemote remote = _FakeRemote();
    final MusicResolvedMedia whole = await resolveMusicMedia(
      const MusicPlayItem(
        trackUid: 'a',
        path: 'sftp://nas:22/m/a.flac',
        title: 'a',
        sourceId: 7,
      ),
      remoteResolver: remote,
    );
    expect(whole.media.uri, 'http://127.0.0.1:4000/cloud/tok/a.flac');
    expect(whole.media.httpHeaders, <String, String>{'X-Test': '1'});

    final MusicResolvedMedia cue = await resolveMusicMedia(
      const MusicPlayItem(
        trackUid: 'b',
        path: 'sftp://nas:22/m/a.flac',
        title: 'b',
        sourceId: 7,
        startMs: 1000,
        endMs: 2000,
      ),
      remoteResolver: remote,
    );
    expect(cue.media.uri, startsWith('edl://'));
    expect(cue.media.uri, contains('http://127.0.0.1:4000/cloud/tok/a.flac'));
    expect(cue.media.uri, isNot(contains('sftp://')));
  });

  test('server-library, plugin and local tracks keep their branches', () async {
    final _FakeRemote remote = _FakeRemote();
    // 服务器曲库（Jellyfin / Subsonic）：http 路径但没有 sourceId——不进远程分支。
    final MusicResolvedMedia server = await resolveMusicMedia(
      const MusicPlayItem(
        trackUid: 's',
        path: 'https://jellyfin.test/Audio/1/universal?api_key=k',
        title: 's',
      ),
      remoteResolver: remote,
    );
    expect(
      server.media.uri,
      'https://jellyfin.test/Audio/1/universal?api_key=k',
    );
    expect(remote.asked, isEmpty);
    expect(
      musicItemResolvesStream(
        const MusicPlayItem(trackUid: 's', path: 'https://x/y.mp3', title: 's'),
      ),
      isFalse,
    );

    final MusicResolvedMedia plugin = await resolveMusicMedia(
      const MusicPlayItem(
        trackUid: 'p',
        path: 'fushi-music-plugin://demo/1',
        title: 'p',
      ),
      remoteResolver: remote,
      pluginResolver: (String path) async => const MusicPluginStream(
        url: 'https://cdn.test/1.mp3',
        headers: <String, String>{},
      ),
    );
    expect(plugin.media.uri, 'https://cdn.test/1.mp3');
    expect(remote.asked, isEmpty);

    // 本地来源下的曲目：解析器交回 null，原路径播放。
    final MusicResolvedMedia local = await resolveMusicMedia(
      const MusicPlayItem(
        trackUid: 'l',
        path: '/m/a.flac',
        title: 'l',
        sourceId: 3,
      ),
      remoteResolver: remote,
    );
    expect(local.media.uri, '/m/a.flac');
    expect(
      musicItemResolvesStream(
        const MusicPlayItem(
          trackUid: 'l',
          path: '/m/a.flac',
          title: 'l',
          sourceId: 3,
        ),
      ),
      isFalse,
    );
    expect(
      musicItemResolvesStream(
        const MusicPlayItem(
          trackUid: 'r',
          path: 'sftp://nas:22/m/a.flac',
          title: 'r',
          sourceId: 7,
        ),
      ),
      isTrue,
    );
  });

  group('SourceMusicRemoteMediaResolver', () {
    late FushiDatabase db;
    setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    Future<int> addSource(String transport, String root) =>
        db.insertMediaSource(
          MediaSourcesCompanion.insert(
            label: root,
            mediaKind: 'music',
            transport: Value<String>(transport),
            rootPath: root,
            configJson: Value<String?>(
              jsonEncode(<String, Object?>{'username': 'u'}),
            ),
            createdAt: 1,
          ),
        );

    test('WebDAV: the entry URL with Basic auth inside the source root only; '
        'local sources resolve to null', () async {
      final int dav = await addSource('webdav', 'https://dav.test/m');
      await SourceLibraryCredentialStore(db).saveSecret(dav, password: 'pw');
      final int local = await addSource('local', '/m');
      final SourceMusicRemoteMediaResolver r = SourceMusicRemoteMediaResolver(
        () => db,
      );
      final MusicRemoteStream? inside = await r.resolve(
        MusicPlayItem(
          trackUid: 'a',
          path: 'https://dav.test/m/A/01.flac',
          title: 'a',
          sourceId: dav,
        ),
      );
      expect(inside!.url, 'https://dav.test/m/A/01.flac');
      expect(
        inside.headers['Authorization'],
        'Basic ${base64Encode(utf8.encode('u:pw'))}',
      );
      final MusicRemoteStream? outside = await r.resolve(
        MusicPlayItem(
          trackUid: 'b',
          path: 'https://elsewhere.test/01.flac',
          title: 'b',
          sourceId: dav,
        ),
      );
      expect(outside!.headers, isEmpty);
      expect(
        await r.resolve(
          MusicPlayItem(
            trackUid: 'c',
            path: '/m/a.flac',
            title: 'c',
            sourceId: local,
          ),
        ),
        isNull,
      );
    });
  });
}
