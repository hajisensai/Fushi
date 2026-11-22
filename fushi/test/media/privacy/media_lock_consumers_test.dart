import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/music_library_data.dart';
import 'package:fushi/src/media/privacy/media_visibility.dart';
import 'package:fushi_core/fushi_core.dart';

/// 上锁作品在只拿着 trackUid 的消费端（歌单）也藏起来（拍板台 qiqSbvdxrk / PR 4144
/// 审查缺口 2）：歌单页不列、不进播放队列，歌单卡上的「N 首」也不数。
void main() {
  late FushiDatabase db;
  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    MediaLockSession.instance.resetForTest();
  });
  tearDown(() async {
    MediaLockSession.instance.resetForTest();
    await db.close();
  });

  Future<void> album(String uid) => db
      .into(db.musicAlbums)
      .insert(
        MusicAlbumsCompanion.insert(
          albumUid: uid,
          title: 'album-$uid',
          addedAt: 1,
          updatedAt: 1,
        ),
      );

  Future<void> track(String uid, String albumUid) => db
      .into(db.musicTracks)
      .insert(
        MusicTracksCompanion.insert(
          trackUid: uid,
          path: '/m/$uid.flac',
          title: 'T $uid',
          fileMtimeAt: 1,
          fileSize: 1,
          addedAt: 1,
          albumUid: Value<String?>(albumUid),
        ),
      );

  test('上锁专辑的曲目：歌单不列、歌单计数不数；解锁后都回来', () async {
    await album('locked');
    await album('open');
    await track('t-locked', 'locked');
    await track('t-open', 'open');
    final MusicPlaylistRow playlist = await db.createMusicPlaylist(
      'mix',
      at: 1,
      trackUids: <String>['t-locked', 't-open'],
    );
    await db.setMediaLocked(TagHostKind.musicAlbum, 'locked', true);

    MediaVisibility visibility = await MediaVisibility.load(db);
    final List<MusicPlaylistItem> items = await loadMusicPlaylistItems(
      db,
      playlist.playlistUid,
      remoteAvailable: false,
      hiddenTrack: visibility.hidesMusicTrack,
    );
    expect(items.map((MusicPlaylistItem i) => i.entry.trackUid), <String>[
      't-open',
    ]);

    final MusicLibrarySnapshot snapshot = (await MusicLibrarySnapshot.load(
      db,
      remoteAvailable: false,
    )).withoutAlbums(visibility.hidesMusicAlbum);
    expect(snapshot.albums.map((MusicAlbumRow a) => a.albumUid), <String>[
      'open',
    ]);
    expect(snapshot.playlistTrackCounts[playlist.playlistUid], 1);

    MediaLockSession.instance.unlock();
    visibility = await MediaVisibility.load(db);
    expect(
      await loadMusicPlaylistItems(
        db,
        playlist.playlistUid,
        remoteAvailable: false,
        hiddenTrack: visibility.hidesMusicTrack,
      ),
      hasLength(2),
    );
  });
}
