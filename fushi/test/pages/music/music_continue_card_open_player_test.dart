// BUG-5213：「继续收听」卡正在播放时再点，进播放页而不是重新起播。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/pages/implementations/music/music_library_page.dart';

MusicPlayItem _item(String uid, {String? album}) => MusicPlayItem(
  trackUid: uid,
  path: '/m/$uid.flac',
  title: uid,
  albumUid: album,
);

void main() {
  test('没在放 → 起播', () {
    expect(
      isContinueCardAlreadyPlaying(null, trackUid: 't1', albumUid: 'al'),
      isFalse,
    );
  });

  test('当前曲目就是卡上那首 → 进播放页', () {
    expect(
      isContinueCardAlreadyPlaying(
        _item('t1', album: 'al'),
        trackUid: 't1',
        albumUid: 'al',
      ),
      isTrue,
    );
  });

  test('同一张专辑已经往后放了几首 → 进播放页', () {
    expect(
      isContinueCardAlreadyPlaying(
        _item('t3', album: 'al'),
        trackUid: 't1',
        albumUid: 'al',
      ),
      isTrue,
    );
  });

  test('在放别的专辑 → 起播这张', () {
    expect(
      isContinueCardAlreadyPlaying(
        _item('x1', album: 'other'),
        trackUid: 't1',
        albumUid: 'al',
      ),
      isFalse,
    );
  });

  test('散曲：只认同一首，不拿 null 专辑去配别的散曲', () {
    expect(
      isContinueCardAlreadyPlaying(_item('s2'), trackUid: 's1', albumUid: null),
      isFalse,
    );
    expect(
      isContinueCardAlreadyPlaying(_item('s1'), trackUid: 's1', albumUid: null),
      isTrue,
    );
  });
}
