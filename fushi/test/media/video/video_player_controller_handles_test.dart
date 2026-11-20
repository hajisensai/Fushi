// 视频控制器的句柄 / 订阅生命周期与 libmpv 读取（路线图 #3722 c32）。
//
// 宿主无 libmpv：用假 [PlatformPlayer] 撑起真 [Player]，钉住控制器侧契约——
//  - 句柄释放（数据根迁移 / 删视频 / 文件名整理）后新 Player 的 `video-params` 仍能收到；
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:media_kit/media_kit.dart';

/// 只用 [PlatformPlayer] 自带的 state / 流；libmpv 补丁方法（`setProperty` /
/// `getPropertyAsync`）控制器经 `player.platform` 动态分派，这里按名字提供。
class _FakeMpv extends PlatformPlayer {
  _FakeMpv() : super(configuration: const PlayerConfiguration());

  final Map<String, String> props = <String, String>{};

  /// 每次 `getPropertyAsync` 读的属性名（按先后）。
  final List<String> reads = <String>[];

  Future<void> setProperty(String property, String value) async {
    props[property] = value;
  }

  Future<String> getPropertyAsync(
    String property, {
    bool waitForInitialization = true,
  }) async {
    reads.add(property);
    return props[property] ?? '';
  }

  void emitVideoParams(VideoParams params) {
    state = state.copyWith(videoParams: params);
    // ignore: invalid_use_of_protected_member
    videoParamsController.add(params);
  }
}

const VideoParams _hdrParams = VideoParams(primaries: 'bt.2020', gamma: 'pq');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('句柄释放后换新 Player（video-6）', () {
    test('释放句柄后新 Player 的 video-params 仍驱动 HDR 判据', () async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      final _FakeMpv first = _FakeMpv();
      c.debugAttachPlaybackStreamsForTesting(Player(platformPlayer: first));
      expect(c.debugHdrSourceIsHdr, isFalse);

      // 数据根迁移 / 删视频前放句柄：旧 Player 被销毁。
      await c.debugReleaseMediaHandlesForTesting();

      // 下一次 load 建了新 Player；开片快照里还没有画面参数（慢源 / 网络流）。
      final _FakeMpv second = _FakeMpv();
      c.debugAttachPlaybackStreamsForTesting(Player(platformPlayer: second));
      expect(c.debugHdrSourceIsHdr, isFalse);

      // 参数随后才到：必须经订阅送达判据，而不是挂在已销毁的旧 Player 上收不到。
      second.emitVideoParams(_hdrParams);
      await pumpEventQueue();
      expect(c.debugHdrSourceIsHdr, isTrue);
    });
  });
}
