import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/plugin/music_online_mv_video_client.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoStreamUrls;

void main() {
  group('MusicOnlineMvVideoClient', () {
    test('取流时才调 resolve，并把请求头记给播放页', () async {
      int calls = 0;
      final MusicOnlineMvVideoClient client = MusicOnlineMvVideoClient(
        resolve: () async {
          calls++;
          return (
            url: 'https://mv.example/$calls.mp4',
            headers: <String, String>{'Referer': 'https://music.example/'},
          );
        },
      );
      expect(calls, 0);
      expect(client.httpHeaderFields, isEmpty);

      final RemoteVideoStreamUrls urls = await client.remoteVideoStreamUrls(
        'music-mv:x',
      );
      expect(urls.streamUrl, 'https://mv.example/1.mp4');
      expect(urls.miningVideoHasAudio, isTrue);
      expect(client.httpHeaderFields, <String, String>{
        'Referer': 'https://music.example/',
      });

      // 重试 = 重新取流（地址有时效）。
      final RemoteVideoStreamUrls again = await client.remoteVideoStreamUrls(
        'music-mv:x',
      );
      expect(again.streamUrl, 'https://mv.example/2.mp4');
    });

    test('有 describeError 时把失败包成带用户文案的异常', () async {
      final MusicOnlineMvVideoClient client = MusicOnlineMvVideoClient(
        resolve: () async => throw const FormatException('vip only'),
        describeError: (Object e) => '需要会员',
      );
      await expectLater(
        client.remoteVideoStreamUrls('music-mv:x'),
        throwsA(
          isA<RemoteVideoStreamRefusedException>()
              .having((e) => e.message, 'message', '需要会员')
              .having((e) => e.cause, 'cause', isA<FormatException>()),
        ),
      );
    });

    test('没有 describeError 时原样抛出，交给播放页归类', () async {
      final MusicOnlineMvVideoClient client = MusicOnlineMvVideoClient(
        resolve: () async => throw const FormatException('boom'),
      );
      await expectLater(
        client.remoteVideoStreamUrls('music-mv:x'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  test('musicOnlineMvVideoTitle', () {
    expect(musicOnlineMvVideoTitle('曲', null), '曲');
    expect(musicOnlineMvVideoTitle('曲', '  '), '曲');
    expect(musicOnlineMvVideoTitle('曲', '歌手'), '歌手 - 曲');
  });
}
