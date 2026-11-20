// 视频控制器的句柄 / 订阅生命周期与 libmpv 读取（路线图 #3722 c32）。
//
// 宿主无 libmpv：用假 [PlatformPlayer] 撑起真 [Player]，钉住控制器侧契约——
//  - 句柄释放（数据根迁移 / 删视频 / 文件名整理）后新 Player 的 `video-params` 仍能收到；
//  - 重新选同一条图形轨不撤销在途的整轨抽取；
//  - 续播恢复音轨等到目标轨出现为止，换片 / 卸载 / 用户自己选轨即放弃；
import 'dart:async';
import 'dart:ui' show Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_graphic_subtitle_regions.dart';
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

  /// 每次 `setSubtitleTrack` 选的轨 id（按先后）。
  final List<String> selectedSubtitleIds = <String>[];

  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {
    selectedSubtitleIds.add(track.id);
    state = state.copyWith(track: state.track.copyWith(subtitle: track));
  }

  @override
  Future<void> setAudioTrack(AudioTrack track) async {
    state = state.copyWith(track: state.track.copyWith(audio: track));
  }

  void setTracks(Tracks tracks) {
    state = state.copyWith(tracks: tracks);
    // ignore: invalid_use_of_protected_member
    tracksController.add(tracks);
  }

  void emitVideoParams(VideoParams params) {
    state = state.copyWith(videoParams: params);
    // ignore: invalid_use_of_protected_member
    videoParamsController.add(params);
  }
}

/// 时间表来源替身：每次 load 排队，[complete] 按先后交结果。
class _FakeRegionLoader implements GraphicSubtitleRegionLoader {
  final List<Completer<GraphicSubtitleRegionTrack?>> _pending =
      <Completer<GraphicSubtitleRegionTrack?>>[];

  /// 每次 load 收到的取消信号（按先后）。
  final List<Future<void>?> cancels = <Future<void>?>[];

  @override
  Future<GraphicSubtitleRegionTrack?> load(
    GraphicSubtitleRegionRequest request, {
    required Size fallbackCanvas,
    Future<void>? cancel,
  }) {
    final Completer<GraphicSubtitleRegionTrack?> c =
        Completer<GraphicSubtitleRegionTrack?>();
    _pending.add(c);
    cancels.add(cancel);
    return c.future;
  }

  void complete(List<GraphicSubtitleRegion> regions) {
    _pending
        .removeAt(0)
        .complete(
          GraphicSubtitleRegionTrack(
            canvas: const Size(1920, 1080),
            regions: regions,
          ),
        );
  }
}

const Tracks _pgsTracks = Tracks(
  subtitle: <SubtitleTrack>[
    SubtitleTrack('auto', null, null),
    SubtitleTrack('no', null, null),
    SubtitleTrack('1', 'jpn', 'jpn', codec: 'hdmv_pgs_subtitle'),
    SubtitleTrack('2', 'eng', 'eng', codec: 'hdmv_pgs_subtitle'),
  ],
);

Tracks _audioTracks(List<String> ids) => Tracks(
  audio: <AudioTrack>[
    const AudioTrack('auto', null, null),
    const AudioTrack('no', null, null),
    for (final String id in ids) AudioTrack(id, null, 'jpn'),
  ],
);

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

  group('重新选同一条图形轨（c19 遗留，BUG-4907）', () {
    late _FakeMpv mpv;
    late _FakeRegionLoader loader;
    late VideoPlayerController c;

    setUp(() {
      mpv = _FakeMpv()..setTracks(_pgsTracks);
      loader = _FakeRegionLoader();
      c = VideoPlayerController()
        ..graphicSubtitleRegionLoader = loader
        ..debugAttachPlayerForTesting(Player(platformPlayer: mpv))
        ..debugSetVideoPathForTesting(r'C:\ep01.mkv');
      addTearDown(c.dispose);
    });

    test('抽取在途时再选同一条：不撤销、不重抽，结果照常落地', () async {
      expect(await c.selectEmbeddedGraphicTrack(0), isTrue);
      expect(loader.cancels, hasLength(1));
      bool cancelled = false;
      unawaited(loader.cancels.single!.then((_) => cancelled = true));

      expect(await c.selectEmbeddedGraphicTrack(0), isTrue);
      await pumpEventQueue();
      expect(cancelled, isFalse, reason: '同一条轨的在途抽取不能被杀掉重来');
      expect(loader.cancels, hasLength(1), reason: '不再发第二次抽取');
      expect(mpv.selectedSubtitleIds, <String>['1', '1']);

      loader.complete(<GraphicSubtitleRegion>[
        const GraphicSubtitleRegion(
          startMs: 1000,
          endMs: 2000,
          rect: Rect.fromLTRB(0, 0, 1, 1),
        ),
      ]);
      await pumpEventQueue();
      expect(c.graphicSubtitleTimingCues.single.startMs, 1000);
    });

    test('换成另一条图形轨：旧抽取撤销并按新轨重抽', () async {
      expect(await c.selectEmbeddedGraphicTrack(0), isTrue);
      bool cancelled = false;
      unawaited(loader.cancels.single!.then((_) => cancelled = true));

      expect(await c.selectEmbeddedGraphicTrack(1), isTrue);
      await pumpEventQueue();
      expect(cancelled, isTrue);
      expect(loader.cancels, hasLength(2));
    });

    test('已抽到时间表后再选同一条：表保留，不重抽', () async {
      expect(await c.selectEmbeddedGraphicTrack(0), isTrue);
      loader.complete(<GraphicSubtitleRegion>[
        const GraphicSubtitleRegion(
          startMs: 3000,
          endMs: 4000,
          rect: Rect.fromLTRB(0, 0, 1, 1),
        ),
      ]);
      await pumpEventQueue();
      expect(c.graphicSubtitleTimingCues.single.startMs, 3000);

      expect(await c.selectEmbeddedGraphicTrack(0), isTrue);
      await pumpEventQueue();
      expect(loader.cancels, hasLength(1));
      expect(c.graphicSubtitleTimingCues.single.startMs, 3000);
    });
  });

  group('续播恢复音轨的等待（video-12）', () {
    late _FakeMpv mpv;
    late Player player;
    late VideoPlayerController c;

    setUp(() {
      mpv = _FakeMpv();
      player = Player(platformPlayer: mpv);
      c = VideoPlayerController()..debugAttachPlayerForTesting(player);
      addTearDown(c.dispose);
    });

    test('目标轨晚到（多次轨列表变化之后才出现）也能等到', () async {
      AudioTrack? got;
      bool done = false;
      unawaited(
        c.waitForAudioTrack('3').then((AudioTrack? t) {
          got = t;
          done = true;
        }),
      );
      for (int i = 0; i < 30; i++) {
        mpv.setTracks(_audioTracks(<String>['1', if (i.isOdd) '2']));
        await pumpEventQueue();
      }
      expect(done, isFalse, reason: '目标轨没出现前一直等，不按次数 / 时长放弃');
      mpv.setTracks(_audioTracks(<String>['1', '2', '3']));
      await pumpEventQueue();
      expect(done, isTrue);
      expect(got?.id, '3');
    });

    test('已在列表里：立即返回', () async {
      mpv.setTracks(_audioTracks(<String>['1']));
      expect((await c.waitForAudioTrack('1'))?.id, '1');
    });

    test('换片（load 令牌变了）：放弃，不把上一集的偏好套到新片上', () async {
      final Future<AudioTrack?> waiting = c.waitForAudioTrack('2');
      c.debugAttachPlayerForTesting(player); // 换集复用同一 Player。
      mpv.setTracks(_audioTracks(<String>['1', '2']));
      expect(await waiting, isNull);
    });

    test('等待期间用户自己选了轨：放弃，不覆盖用户的选择', () async {
      final Future<AudioTrack?> waiting = c.waitForAudioTrack('2');
      await c.selectAudioTrack(const AudioTrack('1', null, 'eng'));
      mpv.setTracks(_audioTracks(<String>['1', '2']));
      expect(await waiting, isNull);
    });

    test('Player 销毁（退出 / 放句柄）：放弃', () async {
      final Future<AudioTrack?> waiting = c.waitForAudioTrack('2');
      await player.dispose();
      expect(await waiting, isNull);
    });
  });
}
