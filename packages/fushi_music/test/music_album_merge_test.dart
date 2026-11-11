import 'package:fushi_music/fushi_music.dart';
import 'package:test/test.dart';

/// 专辑对齐 FFI（`ffm_album_merge_plan`）经真原生库：线格式往返与判据的端到端。
/// 判据细节的穷举在 native/fushi_music/src/album_merge.rs 的单测里。原生库是硬依赖。
void main() {
  test('缺省专辑艺人并进带艺人的一张；艺人不同的不合并', () {
    final List<MusicAlbumMerge> plan = planMusicAlbumMerges(<MusicAlbumMember>[
      (
        trackUid: 't1',
        albumUid: 'ua',
        path: '/m/BOX/01.flac',
        albumTitle: 'Here, the world!',
        albumArtist: 'sumimi',
      ),
      (
        trackUid: 't2',
        albumUid: 'ub',
        path: '/m/BOX/02.flac',
        albumTitle: 'Here, the world!',
        albumArtist: null,
      ),
      (
        trackUid: 'x1',
        albumUid: 'xa',
        path: '/m/Best/01.flac',
        albumTitle: 'Best',
        albumArtist: 'A',
      ),
      (
        trackUid: 'x2',
        albumUid: 'xb',
        path: '/m/Best/02.flac',
        albumTitle: 'Best',
        albumArtist: 'B',
      ),
    ]);
    expect(plan, hasLength(1));
    expect(plan.single.title, 'Here, the world!');
    expect(plan.single.albumArtist, 'sumimi');
    expect(plan.single.trackUids, <String>['t1', 't2']);
    expect(plan.single.albumUid, hasLength(32));
  });

  test('空输入不跨 FFI', () {
    expect(planMusicAlbumMerges(const <MusicAlbumMember>[]), isEmpty);
  });

  test('线格式坏了抛 MusicScanWireError', () {
    expect(
      () => decodeMusicAlbumMerges(
        encodeMusicAlbumMembers(<MusicAlbumMember>[
          (
            trackUid: 't',
            albumUid: 'a',
            path: '/p',
            albumTitle: 'T',
            albumArtist: null,
          ),
        ]),
      ),
      throwsA(isA<MusicScanWireError>()),
    );
  });
}
