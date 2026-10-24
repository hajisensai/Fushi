import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/music_crossfade.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/music_signal_path.dart';

/// 交叉淡入的纯函数 + 双实例编排状态机（替身实例，手动喂 `audio-pts` / 事件）。真 libmpv 上
/// 的样本级 / 实时验证在 music_crossfade_real_test.dart。
class _FakeInstance implements MusicCrossfadeInstance {
  _FakeInstance(this.id);

  final int id;
  final StreamController<MusicBackendEvent> controller =
      StreamController<MusicBackendEvent>.broadcast(sync: true);
  final List<String> log = <String>[];
  bool filters = false;
  bool hasFilters = true;
  Duration? duration = const Duration(seconds: 200);
  bool pending = false;
  bool disposed = false;
  void Function(double pts)? ptsCallback;
  MusicOutputSettings? settings;

  void pts(double v) => ptsCallback?.call(v);

  @override
  Stream<MusicBackendEvent> get events => controller.stream;

  @override
  set crossfadeFiltersEnabled(bool value) => filters = value;

  @override
  Future<void> openIncoming(
    MusicPlayItem item, {
    required Duration fadeIn,
  }) async => log.add('incoming:${item.trackUid}:${fadeIn.inMilliseconds}');

  @override
  bool get audibleHasCrossfadeFilters => filters && hasFilters;

  @override
  Duration? get audibleMediaDuration => duration;

  @override
  bool get advancePending => pending;

  @override
  Future<void> armFadeOut({
    required Duration start,
    required Duration length,
  }) async => log.add('arm:${start.inMilliseconds}:${length.inMilliseconds}');

  @override
  Future<void> disarmFadeOut() async => log.add('disarm');

  @override
  set onAudiblePts(void Function(double pts)? callback) =>
      ptsCallback = callback;

  @override
  Future<void> applySettings(MusicOutputSettings s) async {
    settings = s;
    log.add('settings');
  }

  @override
  Future<void> openPair(
    MusicPlayItem current,
    MusicPlayItem? next, {
    required bool play,
    bool crossfadeNext = false,
  }) async => log.add('open:${current.trackUid}+${next?.trackUid}:$play');

  @override
  Future<void> replaceNext(
    MusicPlayItem? next, {
    bool crossfadeNext = false,
  }) async => log.add('next:${next?.trackUid}');

  @override
  Future<void> play() async => log.add('play');

  @override
  Future<void> pause() async => log.add('pause');

  @override
  Future<void> seek(Duration position) async =>
      log.add('seek:${position.inMilliseconds}');

  @override
  Future<void> setAbLoop(Duration? a, Duration? b) async =>
      log.add('ab:${a?.inMilliseconds}-${b?.inMilliseconds}');

  @override
  Future<void> stop() async => log.add('stop');

  @override
  Future<void> dispose() async {
    disposed = true;
    log.add('dispose');
    await controller.close();
  }

  @override
  Future<MusicSignalPathSnapshot?> readSignalPath() async => null;

  @override
  Future<List<MusicAudioDevice>> listAudioDevices() async =>
      const <MusicAudioDevice>[];
}

MusicPlayItem _item(
  String uid, {
  String? album,
  int? disc,
  int? track,
  String? path,
  int? startMs,
  int? endMs,
  int durationMs = 200000,
}) => MusicPlayItem(
  trackUid: uid,
  path: path ?? '/m/$uid.flac',
  title: uid,
  albumUid: album,
  discNo: disc,
  trackNo: track,
  startMs: startMs,
  endMs: endMs,
  durationMs: durationMs,
);

const MusicOutputSettings _on = MusicOutputSettings(
  gapless: true,
  replayGain: MusicReplayGainMode.off,
  crossfade: Duration(seconds: 4),
);

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('纯函数', () {
    test('可用性：关 / 独占 / ALSA 硬件直出 / 可用', () {
      MusicCrossfadeAvailability of(
        MusicOutputSettings s, [
        MusicOutputPlatform p = MusicOutputPlatform.windows,
      ]) => musicCrossfadeAvailability(s, platform: p);
      expect(
        of(_on.copyWith(crossfade: Duration.zero)),
        MusicCrossfadeAvailability.off,
      );
      expect(of(_on), MusicCrossfadeAvailability.available);
      expect(
        of(_on.copyWith(exclusive: true)),
        MusicCrossfadeAvailability.disabledByExclusive,
      );
      expect(
        of(
          _on.copyWith(audioDevice: 'alsa/hw:CARD=DAC,DEV=0'),
          MusicOutputPlatform.linux,
        ),
        MusicCrossfadeAvailability.disabledByDirectDevice,
      );
      expect(
        of(_on.copyWith(audioDevice: 'pipewire'), MusicOutputPlatform.linux),
        MusicCrossfadeAvailability.available,
      );
    });

    test('边界判定：CUE 相接 / 专辑相邻轨 = 连续；跳轨 / 换碟 / 换专辑 = 边界', () {
      bool boundary(MusicPlayItem a, MusicPlayItem b, {bool order = false}) =>
          musicTransitionIsBoundary(a, b, albumOrder: order);
      // CUE：同一整轨、首尾相接。
      expect(
        boundary(
          _item('c1', path: '/x.flac', startMs: 0, endMs: 1000),
          _item('c2', path: '/x.flac', startMs: 1000),
        ),
        isFalse,
      );
      // 同文件但不相接（跳了一段）= 边界。
      expect(
        boundary(
          _item('c1', path: '/x.flac', startMs: 0, endMs: 1000),
          _item('c3', path: '/x.flac', startMs: 2000),
        ),
        isTrue,
      );
      expect(
        boundary(
          _item('a1', album: 'A', disc: 1, track: 1),
          _item('a2', album: 'A', disc: 1, track: 2),
        ),
        isFalse,
      );
      expect(
        boundary(
          _item('a1', album: 'A', disc: 1, track: 1),
          _item('a3', album: 'A', disc: 1, track: 3),
        ),
        isTrue,
      );
      expect(
        boundary(
          _item('a9', album: 'A', disc: 1, track: 9),
          _item('b1', album: 'A', disc: 2, track: 1),
        ),
        isTrue,
      );
      expect(boundary(_item('x', album: 'A'), _item('y', album: 'B')), isTrue);
      expect(boundary(_item('x'), _item('y')), isTrue);
      // 缺轨号：按语境。
      expect(
        boundary(_item('x', album: 'A'), _item('y', album: 'A'), order: true),
        isFalse,
      );
      expect(boundary(_item('x', album: 'A'), _item('y', album: 'A')), isTrue);
      // 「连续曲目也淡入」。
      expect(
        musicTransitionCrossfades(
          _item('a1', album: 'A', disc: 1, track: 1),
          _item('a2', album: 'A', disc: 1, track: 2),
          albumOrder: true,
          includeContinuous: true,
        ),
        isTrue,
      );
    });

    test('时间参数：墙钟 × 速度、不超过任一首 45%、太短不做', () {
      expect(
        musicCrossfadeTiming(
          from: const Duration(seconds: 200),
          to: const Duration(seconds: 100),
          crossfade: const Duration(seconds: 4),
          speed: 1,
        ),
        const MusicCrossfadeTiming(
          fadeStart: Duration(milliseconds: 195950),
          fadeLength: Duration(seconds: 4),
        ),
      );
      expect(
        musicCrossfadeTiming(
          from: const Duration(seconds: 200),
          to: null,
          crossfade: const Duration(seconds: 4),
          speed: 1.5,
        )!.fadeLength,
        const Duration(seconds: 6),
      );
      expect(
        musicCrossfadeTiming(
          from: const Duration(seconds: 10),
          to: const Duration(seconds: 4),
          crossfade: const Duration(seconds: 4),
          speed: 1,
        )!.fadeLength,
        const Duration(milliseconds: 1800),
      );
      expect(
        musicCrossfadeTiming(
          from: const Duration(milliseconds: 300),
          to: null,
          crossfade: const Duration(seconds: 4),
          speed: 1,
        ),
        isNull,
      );
      expect(
        musicCrossfadeTiming(
          from: const Duration(seconds: 200),
          to: null,
          crossfade: Duration.zero,
          speed: 1,
        ),
        isNull,
      );
    });

    test('滤镜串：淡入 qsin / 平时 nofade；淡出起点 86400；面板剥掉本模块滤镜', () {
      final String idle = musicCrossfadeAf(fadeIn: Duration.zero);
      expect(idle, contains('curve=nofade'));
      expect(idle, contains('@fushixfout:lavfi=[afade=t=out:st=86400'));
      final String fadeIn = musicCrossfadeAf(
        fadeIn: const Duration(milliseconds: 2500),
      );
      expect(
        fadeIn,
        startsWith('@fushixfin:lavfi=[afade=t=in:st=0:d=2.500000:curve=qsin]'),
      );
      expect(musicStripCrossfadeFilters(idle), isEmpty);
      expect(
        musicStripCrossfadeFilters('lavfi=[aecho=0.8:0.9:1000:0.3],$idle'),
        'lavfi=[aecho=0.8:0.9:1000:0.3]',
      );
      expect(musicStripCrossfadeFilters(''), isEmpty);
    });
  });

  group('编排', () {
    late List<_FakeInstance> made;
    late MusicCrossfadeBackend xf;
    late List<MusicBackendEvent> out;
    late StreamSubscription<MusicBackendEvent> sub;

    setUp(() {
      made = <_FakeInstance>[];
      xf = MusicCrossfadeBackend(
        instanceFactory: () {
          final _FakeInstance i = _FakeInstance(made.length);
          made.add(i);
          return i;
        },
        platform: MusicOutputPlatform.windows,
      );
      out = <MusicBackendEvent>[];
      sub = xf.events.listen(out.add);
    });
    tearDown(() async {
      await sub.cancel();
      await xf.dispose();
    });

    test('关着：单实例，调用原样转发，crossfadeNext 被忽略', () async {
      await xf.applySettings(_on.copyWith(crossfade: Duration.zero));
      await xf.openPair(
        _item('a'),
        _item('b', album: 'other'),
        play: true,
        crossfadeNext: true,
      );
      await xf.replaceNext(_item('c'), crossfadeNext: true);
      await xf.seek(const Duration(seconds: 3));
      await xf.pause();
      await xf.play();
      made.single.pts(199);
      expect(made.single.filters, isFalse);
      expect(made.single.log, <String>[
        'settings',
        'open:a+b:true',
        'next:c',
        'seek:3000',
        'pause',
        'play',
      ]);
      expect(made.length, 1);
    });

    test('开着：排淡出 → 提前 5 s 预加载 → 到淡出起点启动后一首、发 Advanced → 前一首播完释放', () async {
      await xf.applySettings(_on);
      await xf.openPair(
        _item('a'),
        _item('b'),
        play: true,
        crossfadeNext: true,
      );
      final _FakeInstance a = made.single;
      expect(a.filters, isTrue);
      expect(a.log.last, 'open:a+null:true', reason: '下一首不排进 gapless 列表');
      a.controller.add(const MusicBackendPlaying(true));
      a.pts(0.5);
      await _settle();
      expect(a.log.last, 'arm:195950:4000');
      a.pts(150);
      await _settle();
      expect(made.length, 1, reason: '离淡出起点还远，不建第二实例');
      a.pts(191.5);
      await _settle();
      expect(made.length, 2);
      final _FakeInstance b = made[1];
      expect(b.filters, isTrue);
      expect(b.log, <String>['settings', 'incoming:b:4000']);
      expect(b.settings, _on);
      // 预加载期间后一首的事件对外不可见。
      b.controller.add(const MusicBackendPosition(Duration.zero, null));
      await _settle();
      expect(out.whereType<MusicBackendPosition>(), isEmpty);
      a.controller.add(
        const MusicBackendPosition(Duration(seconds: 195), null),
      );
      a.pts(195.96);
      await _settle();
      await _settle();
      expect(b.log.last, 'play');
      expect(out.whereType<MusicBackendAdvanced>().single.trackUid, 'b');
      expect(xf.debugOverlapping, isTrue);
      // 重叠期：只转发当前曲（b）的事件。
      out.clear();
      a.controller.add(
        const MusicBackendPosition(Duration(seconds: 197), null),
      );
      b.controller.add(const MusicBackendPosition(Duration(seconds: 1), null));
      await _settle();
      expect(
        out.whereType<MusicBackendPosition>().map(
          (MusicBackendPosition p) => p.position,
        ),
        <Duration>[const Duration(seconds: 1)],
      );
      a.controller.add(const MusicBackendCompleted());
      await _settle();
      expect(out.whereType<MusicBackendCompleted>(), isEmpty);
      expect(a.disposed, isTrue);
      expect(xf.debugInstanceCount, 1);
      // b 成了主实例：下一次 replaceNext 走它。
      await xf.replaceNext(_item('c'), crossfadeNext: false);
      expect(b.log.last, 'next:c');
    });

    test('排不了淡出（加载时没装滤镜）→ 退回 gapless：下一首排进主实例', () async {
      await xf.applySettings(_on);
      await xf.openPair(
        _item('a'),
        _item('b'),
        play: true,
        crossfadeNext: true,
      );
      final _FakeInstance a = made.single..hasFilters = false;
      a.pts(1);
      await _settle();
      expect(a.log.last, 'next:b');
      a.pts(199);
      await _settle();
      expect(made.length, 1);
    });

    test('太晚才排（离淡出起点不到 1 s）→ 退回 gapless', () async {
      await xf.applySettings(_on);
      await xf.openPair(
        _item('a'),
        _item('b'),
        play: true,
        crossfadeNext: true,
      );
      final _FakeInstance a = made.single;
      a.pts(195.5);
      await _settle();
      expect(a.log.last, 'next:b');
      expect(a.log.where((String l) => l.startsWith('arm')), isEmpty);
    });

    test('锁定前换下一首：撤淡出、按新判定重排；锁定后取消 = 前一首淡完即停', () async {
      await xf.applySettings(_on);
      await xf.openPair(
        _item('a'),
        _item('b'),
        play: true,
        crossfadeNext: true,
      );
      final _FakeInstance a = made.single;
      a.pts(10);
      await _settle();
      await xf.replaceNext(_item('b2', album: 'A'), crossfadeNext: false);
      expect(a.log.sublist(a.log.length - 2), <String>['disarm', 'next:b2']);
      await xf.replaceNext(_item('b3'), crossfadeNext: true);
      expect(a.log.sublist(a.log.length - 2), <String>[
        'next:null',
        'arm:195950:4000',
      ]);
      // 进入锁定线（淡出起点前 1 s 内）且已预加载。
      a.pts(191);
      await _settle();
      a.pts(195.5);
      await _settle();
      expect(made.length, 2);
      await xf.replaceNext(null);
      expect(made[1].disposed, isTrue, reason: '预加载丢掉');
      expect(a.log.last, isNot('disarm'), reason: '锁定后不撤淡出');
      a.controller.add(const MusicBackendCompleted());
      await _settle();
      expect(out.whereType<MusicBackendCompleted>().length, 1);
    });

    test('锁定后换成另一首：仍交叉淡入，只是重新预加载新的下一首', () async {
      await xf.applySettings(_on);
      await xf.openPair(
        _item('a'),
        _item('b'),
        play: true,
        crossfadeNext: true,
      );
      final _FakeInstance a = made.single;
      a.pts(1);
      await _settle();
      a.pts(195.2);
      await _settle();
      expect(made.length, 2);
      await xf.replaceNext(_item('z'), crossfadeNext: true);
      expect(made[1].disposed, isTrue);
      a.pts(195.4);
      await _settle();
      expect(made.length, 3);
      expect(made[2].log.last, 'incoming:z:4000');
    });

    test('重叠期内暂停 / seek：前一首立即释放，操作只作用于当前曲', () async {
      for (final String op in <String>['pause', 'seek', 'openPair', 'speed']) {
        made.clear();
        final MusicCrossfadeBackend x = MusicCrossfadeBackend(
          instanceFactory: () {
            final _FakeInstance i = _FakeInstance(made.length);
            made.add(i);
            return i;
          },
          platform: MusicOutputPlatform.windows,
        );
        await x.applySettings(_on);
        await x.openPair(
          _item('a'),
          _item('b'),
          play: true,
          crossfadeNext: true,
        );
        final _FakeInstance a = made.single;
        a.pts(1);
        await _settle();
        a.pts(192);
        await _settle();
        a.pts(196);
        await _settle();
        await _settle();
        expect(x.debugOverlapping, isTrue, reason: op);
        final _FakeInstance b = made[1];
        switch (op) {
          case 'pause':
            await x.pause();
            expect(b.log.last, 'pause');
          case 'seek':
            await x.seek(const Duration(seconds: 30));
            expect(b.log.last, 'seek:30000');
          case 'openPair':
            await x.openPair(_item('q'), null, play: true);
            expect(b.log.last, 'open:q+null:true');
          case 'speed':
            await x.applySettings(_on.copyWith(speed: 1.25));
            expect(b.settings?.speed, 1.25);
        }
        expect(a.disposed, isTrue, reason: op);
        expect(x.debugOverlapping, isFalse, reason: op);
        expect(x.debugInstanceCount, 1, reason: op);
        await x.dispose();
      }
    });

    test('音量 / ReplayGain 在重叠期内两路都下发（各自按自己的曲目算增益）', () async {
      await xf.applySettings(_on);
      await xf.openPair(
        _item('a'),
        _item('b'),
        play: true,
        crossfadeNext: true,
      );
      final _FakeInstance a = made.single;
      a.pts(1);
      await _settle();
      a.pts(192);
      await _settle();
      a.pts(196);
      await _settle();
      await _settle();
      final MusicOutputSettings louder = _on.copyWith(
        volume: 80,
        replayGain: MusicReplayGainMode.track,
      );
      await xf.applySettings(louder);
      expect(xf.debugOverlapping, isTrue, reason: '音量 / 增益不打断淡入淡出');
      expect(a.settings, louder);
      expect(made[1].settings, louder);
    });

    test('开独占：锁定前撤淡出改 gapless；锁定后前一首淡完由主实例直接开下一首', () async {
      await xf.applySettings(_on);
      await xf.openPair(
        _item('a'),
        _item('b'),
        play: true,
        crossfadeNext: true,
      );
      final _FakeInstance a = made.single;
      a.pts(1);
      await _settle();
      await xf.applySettings(_on.copyWith(exclusive: true));
      expect(a.filters, isFalse);
      expect(a.log.sublist(a.log.length - 3), <String>[
        'disarm',
        'next:b',
        'settings',
      ]);

      // 锁定后再开独占。
      await xf.applySettings(_on);
      await xf.openPair(
        _item('a'),
        _item('b'),
        play: true,
        crossfadeNext: true,
      );
      a.pts(1);
      await _settle();
      a.pts(195.5);
      await _settle();
      expect(made.length, 2);
      await xf.applySettings(_on.copyWith(exclusive: true));
      expect(made[1].disposed, isTrue);
      a.controller.add(const MusicBackendCompleted());
      await _settle();
      await _settle();
      expect(a.log.last, 'open:b+null:true');
      expect(out.whereType<MusicBackendAdvanced>().last.trackUid, 'b');
      expect(out.whereType<MusicBackendCompleted>(), isEmpty);
    });

    test('前一首在启动前就放完（到点时暂停 / 采样太稀）：立刻接上并释放前一首', () async {
      await xf.applySettings(_on);
      await xf.openPair(
        _item('a'),
        _item('b'),
        play: true,
        crossfadeNext: true,
      );
      final _FakeInstance a = made.single;
      a.pts(1);
      await _settle();
      a.pts(192);
      await _settle();
      a.controller.add(const MusicBackendCompleted());
      await _settle();
      await _settle();
      expect(made[1].log.last, 'play');
      expect(a.disposed, isTrue);
      expect(xf.debugOverlapping, isFalse);
      expect(out.whereType<MusicBackendAdvanced>().single.trackUid, 'b');
      expect(out.whereType<MusicBackendCompleted>(), isEmpty);
    });

    test('预加载失败：前一首放完时由主实例直接开下一首', () async {
      await xf.applySettings(_on);
      await xf.openPair(
        _item('a'),
        _item('b'),
        play: true,
        crossfadeNext: true,
      );
      final _FakeInstance a = made.single;
      a.pts(1);
      await _settle();
      a.pts(192);
      await _settle();
      made[1].controller.add(const MusicBackendFailed('cannot open'));
      await _settle();
      expect(made[1].disposed, isTrue);
      a.controller.add(const MusicBackendCompleted());
      await _settle();
      await _settle();
      expect(a.log.last, 'open:b+null:true');
      expect(out.whereType<MusicBackendAdvanced>().single.trackUid, 'b');
    });
  });

  group('引擎判衔接', () {
    late List<bool> flags;
    late MusicOutputSettings settings;
    late MusicPlayerEngine engine;

    setUp(() {
      flags = <bool>[];
      settings = _on;
      engine = MusicPlayerEngine(
        backendFactory: () => _FlagBackend(flags),
        replayGainEnabled: () => false,
        baseSettings: () => settings,
      );
    });
    tearDown(() => engine.dispose());

    test('跨专辑 = 淡入；专辑顺序播（缺轨号）= 不淡入；随机后 = 淡入', () async {
      await engine.playQueue(<MusicPlayItem>[
        _item('a', album: 'A'),
        _item('b', album: 'B'),
      ]);
      expect(flags.last, isTrue);
      await engine.playQueue(<MusicPlayItem>[
        _item('a1', album: 'A'),
        _item('a2', album: 'A'),
        _item('a3', album: 'A'),
      ], context: MusicQueueContext.album);
      expect(flags.last, isFalse);
      await engine.setShuffle(true);
      expect(flags.last, isTrue, reason: '随机后相邻的不再是专辑顺序');
    });

    test('关 / 播完本曲停 → 不淡入；「连续曲目也淡入」→ 淡入；改设置立刻重发', () async {
      settings = _on.copyWith(crossfade: Duration.zero);
      await engine.playQueue(<MusicPlayItem>[
        _item('a', album: 'A'),
        _item('b', album: 'B'),
      ]);
      expect(flags.last, isFalse);
      settings = _on;
      final int before = flags.length;
      await engine.reapplySettings();
      expect(flags.length, before + 1);
      expect(flags.last, isTrue);
      await engine.reapplySettings();
      expect(flags.length, before + 1, reason: '判定没变不重发');
      await engine.setStopAfterCurrent(true);
      expect(flags.last, isFalse);
      await engine.setStopAfterCurrent(false);
      expect(flags.last, isTrue);

      await engine.playQueue(<MusicPlayItem>[
        _item('a1', album: 'A', disc: 1, track: 1),
        _item('a2', album: 'A', disc: 1, track: 2),
      ]);
      expect(flags.last, isFalse);
      settings = _on.copyWith(crossfadeContinuous: true);
      await engine.reapplySettings();
      expect(flags.last, isTrue);
    });
  });
}

/// 只记 crossfadeNext 的后端。
class _FlagBackend implements MusicOutputBackend {
  _FlagBackend(this.flags);

  final List<bool> flags;
  final StreamController<MusicBackendEvent> _c =
      StreamController<MusicBackendEvent>.broadcast();

  @override
  Stream<MusicBackendEvent> get events => _c.stream;

  @override
  Future<void> applySettings(MusicOutputSettings settings) async {}

  @override
  Future<void> openPair(
    MusicPlayItem current,
    MusicPlayItem? next, {
    required bool play,
    bool crossfadeNext = false,
  }) async => flags.add(crossfadeNext);

  @override
  Future<void> replaceNext(
    MusicPlayItem? next, {
    bool crossfadeNext = false,
  }) async => flags.add(crossfadeNext);

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> setAbLoop(Duration? a, Duration? b) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() => _c.close();

  @override
  Future<MusicSignalPathSnapshot?> readSignalPath() async => null;

  @override
  Future<List<MusicAudioDevice>> listAudioDevices() async =>
      const <MusicAudioDevice>[];
}
