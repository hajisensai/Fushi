import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/mpv_music_output_backend.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/music_signal_path.dart';
import 'package:fushi/src/media/video/video_episode_start_policy.dart';

/// 记录引擎发给后端的每一条命令；测试手动发后端事件。
class _FakeBackend implements MusicOutputBackend {
  final StreamController<MusicBackendEvent> controller =
      StreamController<MusicBackendEvent>.broadcast(sync: true);
  final List<String> log = <String>[];
  MusicOutputSettings? settings;
  MusicPlayItem? current;
  MusicPlayItem? next;
  bool disposed = false;

  @override
  Stream<MusicBackendEvent> get events => controller.stream;

  @override
  Future<void> applySettings(MusicOutputSettings s) async {
    settings = s;
    log.add('settings:${s.replayGain.name}:${s.gapless}');
  }

  /// 每次 openPair / replaceNext 带的 crossfadeNext。
  final List<bool> crossfadeFlags = <bool>[];

  @override
  Future<void> openPair(
    MusicPlayItem current,
    MusicPlayItem? next, {
    required bool play,
    bool crossfadeNext = false,
    Duration startAt = Duration.zero,
  }) async {
    this.current = current;
    this.next = next;
    crossfadeFlags.add(crossfadeNext);
    startAts.add(startAt);
    log.add('open:${current.trackUid}+${next?.trackUid}');
  }

  /// 每次 openPair 带的 startAt（断点续播）。
  final List<Duration> startAts = <Duration>[];

  @override
  Future<void> replaceNext(
    MusicPlayItem? next, {
    bool crossfadeNext = false,
  }) async {
    this.next = next;
    crossfadeFlags.add(crossfadeNext);
    log.add('next:${next?.trackUid}');
  }

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
    await controller.close();
  }

  @override
  Future<MusicSignalPathSnapshot?> readSignalPath() async => null;

  @override
  Future<List<MusicAudioDevice>> listAudioDevices() async =>
      const <MusicAudioDevice>[];
}

MusicPlayItem _item(String uid, {int? durationMs = 200000}) => MusicPlayItem(
  trackUid: uid,
  path: '/m/$uid.flac',
  title: uid,
  durationMs: durationMs,
);

void main() {
  late _FakeBackend backend;
  late MusicPlayerEngine engine;
  final List<String> started = <String>[];

  setUp(() {
    backend = _FakeBackend();
    started.clear();
    engine = MusicPlayerEngine(backendFactory: () => backend, random: Random(1))
      ..onTrackStarted = (MusicPlayItem i) => started.add(i.trackUid);
  });

  tearDown(() => engine.dispose());

  test('后端只持有「当前 + 下一首」；无缝推进后引擎补新的下一首', () async {
    await engine.playQueue(<MusicPlayItem>[
      _item('a'),
      _item('b'),
      _item('c'),
    ], context: MusicQueueContext.album);
    expect(backend.log, <String>['settings:album:true', 'open:a+b']);
    expect(engine.current?.trackUid, 'a');
    expect(engine.isPlaying, isTrue);

    backend.controller.add(const MusicBackendAdvanced());
    await Future<void>.delayed(Duration.zero);
    expect(engine.current?.trackUid, 'b');
    expect(backend.log.last, 'next:c');

    backend.controller.add(const MusicBackendAdvanced());
    await Future<void>.delayed(Duration.zero);
    expect(engine.current?.trackUid, 'c');
    expect(backend.log.last, 'next:null', reason: '最后一首后面没有可预排的');
    expect(started, <String>['a', 'b', 'c']);

    backend.controller.add(const MusicBackendCompleted());
    expect(engine.isPlaying, isFalse);
  });

  test('换曲时 onTrackStarted 里读得到上一首清零前的播放位置（播放事件结算用）', () async {
    final List<Duration?> listened = <Duration?>[];
    engine.onTrackStarted = (MusicPlayItem i) {
      started.add(i.trackUid);
      listened.add(engine.listenedBeforeStart);
      expect(engine.position, Duration.zero, reason: '新曲从 0 开始');
    };
    await engine.playQueue(<MusicPlayItem>[
      _item('a'),
      _item('b'),
      _item('c'),
    ], context: MusicQueueContext.album);
    backend.controller.add(
      const MusicBackendPosition(Duration(seconds: 42), Duration(minutes: 3)),
    );
    // 无缝推进：上一首 a 播到 42 秒。
    backend.controller.add(const MusicBackendAdvanced());
    await Future<void>.delayed(Duration.zero);
    backend.controller.add(
      const MusicBackendPosition(Duration(seconds: 7), Duration(minutes: 3)),
    );
    // 用户切歌（重开）：上一首 b 播到 7 秒。
    await engine.skipNext();
    expect(started, <String>['a', 'b', 'c']);
    expect(listened, <Duration?>[
      null,
      const Duration(seconds: 42),
      const Duration(seconds: 7),
    ]);
    expect(engine.listenedBeforeStart, isNull, reason: '只在回调里有效');
  });

  test('队列来源：playQueue 记住、onTrackStarted 时可读、换队列替换、stop 清掉', () async {
    MusicPlaySource? seen;
    engine.onTrackStarted = (MusicPlayItem i) => seen = engine.source;
    const MusicPlaySource album = MusicPlaySource.album('a1', title: 'A');
    await engine.playQueue(<MusicPlayItem>[
      _item('a'),
      _item('b'),
    ], source: album);
    expect(seen, album);
    await engine.skipNext();
    expect(seen, album, reason: '同一队列里换曲来源不变');
    await engine.setShuffle(true);
    expect(engine.source, album);
    await engine.playQueue(<MusicPlayItem>[_item('c')]);
    expect(seen, isNull, reason: '新队列没传来源 = 未知，不沿用上一个');
    await engine.playQueue(<MusicPlayItem>[
      _item('d'),
    ], source: MusicPlaySource.pluginPlaylist('demo', 'pl/9'));
    expect(engine.source?.hostRef, (hostId: 'demo', itemId: 'pl/9'));
    await engine.stop();
    expect(engine.source, isNull);
  });

  test('AB 循环：下发给后端；空区间 = 关；换曲目（含无缝推进）自动关', () async {
    await engine.playQueue(<MusicPlayItem>[_item('a'), _item('b'), _item('c')]);
    await engine.setAbLoop(
      const MusicAbLoop(Duration(seconds: 10), Duration(seconds: 14)),
    );
    expect(engine.abLoop?.b, const Duration(seconds: 14));
    expect(backend.log.last, 'ab:10000-14000');

    await engine.setAbLoop(
      const MusicAbLoop(Duration(seconds: 5), Duration(seconds: 5)),
    );
    expect(engine.abLoop, isNull, reason: '空区间等于关');
    expect(backend.log.last, 'ab:null-null');

    await engine.setAbLoop(
      const MusicAbLoop(Duration(seconds: 1), Duration(seconds: 2)),
    );
    backend.controller.add(const MusicBackendAdvanced());
    await Future<void>.delayed(Duration.zero);
    expect(engine.abLoop, isNull, reason: '无缝推进到下一首');
    expect(backend.log.where((String l) => l == 'ab:null-null').length, 2);

    await engine.setAbLoop(
      const MusicAbLoop(Duration(seconds: 1), Duration(seconds: 2)),
    );
    await engine.skipNext();
    expect(engine.abLoop, isNull, reason: '手动换曲同样关');
    expect(backend.log.where((String l) => l == 'ab:null-null').length, 3);
  });

  test('ReplayGain：专辑顺序播 album，随机 / 混排 track，关掉 off', () {
    expect(
      musicReplayGainModeFor(
        enabled: true,
        context: MusicQueueContext.album,
        shuffled: false,
      ),
      MusicReplayGainMode.album,
    );
    expect(
      musicReplayGainModeFor(
        enabled: true,
        context: MusicQueueContext.album,
        shuffled: true,
      ),
      MusicReplayGainMode.track,
    );
    expect(
      musicReplayGainModeFor(
        enabled: true,
        context: MusicQueueContext.mixed,
        shuffled: false,
      ),
      MusicReplayGainMode.track,
    );
    expect(
      musicReplayGainModeFor(
        enabled: false,
        context: MusicQueueContext.album,
        shuffled: false,
      ),
      MusicReplayGainMode.off,
    );
  });

  test('随机播放：选中的那首排第一；中途开关随机不打断当前曲目', () async {
    final List<MusicPlayItem> items = <MusicPlayItem>[
      for (final String u in <String>['a', 'b', 'c', 'd', 'e']) _item(u),
    ];
    await engine.playQueue(
      items,
      startIndex: 2,
      context: MusicQueueContext.album,
      shuffle: true,
    );
    expect(engine.current?.trackUid, 'c');
    expect(engine.queue.map((MusicPlayItem i) => i.trackUid).toSet(), <String>{
      'a',
      'b',
      'c',
      'd',
      'e',
    });
    expect(backend.settings?.replayGain, MusicReplayGainMode.track);

    await engine.setShuffle(false);
    expect(engine.current?.trackUid, 'c');
    expect(engine.queue.map((MusicPlayItem i) => i.trackUid), <String>[
      'a',
      'b',
      'c',
      'd',
      'e',
    ]);
    expect(backend.next?.trackUid, 'd');
    expect(backend.settings?.replayGain, MusicReplayGainMode.album);
    expect(
      backend.log.where((String l) => l.startsWith('open:')),
      hasLength(1),
      reason: '开关随机只换下一首，不重开当前曲目',
    );
  });

  test('上一首：播过 3 秒回到本曲开头，否则退到上一首', () async {
    await engine.playQueue(<MusicPlayItem>[_item('a'), _item('b')]);
    await engine.skipNext();
    expect(engine.current?.trackUid, 'b');
    backend.controller.add(
      const MusicBackendPosition(Duration(seconds: 10), null),
    );
    await engine.skipPrevious();
    expect(engine.current?.trackUid, 'b');
    expect(backend.log.last, 'seek:0');
    backend.controller.add(
      const MusicBackendPosition(Duration(seconds: 1), null),
    );
    await engine.skipPrevious();
    expect(engine.current?.trackUid, 'a');
  });

  test('seek 夹在 [0, 时长]；stop 释放后端', () async {
    await engine.playQueue(<MusicPlayItem>[_item('a', durationMs: 1000)]);
    await engine.seekRelative(const Duration(seconds: -5));
    expect(backend.log.last, 'seek:0');
    await engine.seek(const Duration(seconds: 9));
    expect(backend.log.last, 'seek:1000');
    await engine.stop();
    expect(backend.disposed, isTrue);
    expect(engine.isActive, isFalse);
  });

  test('设置开关经 reapplySettings 立即下发给在用的后端', () async {
    bool gapless = true;
    bool replayGain = true;
    final _FakeBackend b = _FakeBackend();
    final MusicPlayerEngine e = MusicPlayerEngine(
      backendFactory: () => b,
      gaplessEnabled: () => gapless,
      replayGainEnabled: () => replayGain,
    );
    addTearDown(e.dispose);
    await e.playQueue(<MusicPlayItem>[
      _item('a'),
    ], context: MusicQueueContext.album);
    expect(b.settings?.gapless, isTrue);
    expect(b.settings?.replayGain, MusicReplayGainMode.album);
    gapless = false;
    replayGain = false;
    await e.reapplySettings();
    expect(b.settings?.gapless, isFalse);
    expect(b.settings?.replayGain, MusicReplayGainMode.off);
    expect(
      musicMpvProperties(
        b.settings!,
        platform: MusicOutputPlatform.windows,
      )['gapless-audio'],
      'no',
    );
  });

  test('mpv 映射：CUE 起止成 EDL 段（不走会冲掉设备缓冲的 start seek）；设置成属性', () {
    final media = musicMediaOf(
      const MusicPlayItem(
        trackUid: 'x',
        path: '/m/full,1.flac',
        title: 'x',
        startMs: 1000,
        endMs: 2500,
      ),
    );
    // 路径带逗号也不会被当成 EDL 分隔符：%字节数% 前缀。
    expect(
      media.uri,
      'edl://%14%/m/full,1.flac,start=1.000000,length=1.500001',
    );
    expect(media.start, isNull);
    expect(media.end, isNull);
    expect(
      musicMediaOf(
        const MusicPlayItem(
          trackUid: 'y',
          path: '/m/日本.flac',
          title: 'y',
          startMs: 0,
        ),
      ).uri,
      '/m/日本.flac',
      reason: '从 0 播到尾的 CUE 首轨等同整文件',
    );
    expect(
      musicEdlUri('/m/日本.flac', startMs: 61000),
      'edl://%14%/m/日本.flac,start=61.000000,length=86400',
      reason: '长度按 UTF-8 字节；最后一轨给开放段长，不截段尾',
    );
    expect(
      musicMpvProperties(
        const MusicOutputSettings(
          gapless: true,
          replayGain: MusicReplayGainMode.album,
        ),
        platform: MusicOutputPlatform.windows,
      ),
      containsPair('gapless-audio', 'weak'),
    );
    final Map<String, String> off = musicMpvProperties(
      const MusicOutputSettings(
        gapless: false,
        replayGain: MusicReplayGainMode.off,
      ),
      platform: MusicOutputPlatform.windows,
    );
    expect(off['gapless-audio'], 'no');
    expect(off['prefetch-playlist'], 'no');
    // ReplayGain 恒由后端按曲目用 volume-gain 施加，mpv 自己的 replaygain 关掉。
    expect(off['replaygain'], 'no');
  });

  test('输出偏好（预放大 / 独占 / 设备 / DSD / 速度 / 音量）经引擎下发给后端', () async {
    final _FakeBackend b = _FakeBackend();
    MusicOutputSettings base = const MusicOutputSettings(
      gapless: true,
      replayGain: MusicReplayGainMode.off,
    );
    final MusicPlayerEngine e = MusicPlayerEngine(
      backendFactory: () => b,
      baseSettings: () => base,
    );
    addTearDown(e.dispose);
    await e.playQueue(<MusicPlayItem>[_item('a')]);
    expect(b.settings?.exclusive, isFalse);
    base = const MusicOutputSettings(
      gapless: true,
      replayGain: MusicReplayGainMode.off,
      replayGainPreampDb: 4,
      exclusive: true,
      audioDevice: 'wasapi/{x}',
      dsdPcmRate: MusicDsdPcmRate.khz352,
      speed: 1.25,
      volume: 70,
    );
    await e.reapplySettings();
    final MusicOutputSettings s = b.settings!;
    expect(s.replayGainPreampDb, 4);
    expect(s.exclusive, isTrue);
    expect(s.dsdPcmRate, MusicDsdPcmRate.khz352);
    // ReplayGain 档位仍由引擎按播放语境决定（这里是混排 → track）。
    expect(s.replayGain, MusicReplayGainMode.track);
    final Map<String, String> win = musicMpvProperties(
      s,
      platform: MusicOutputPlatform.windows,
    );
    expect(win['ao'], 'wasapi');
    expect(win['audio-exclusive'], 'yes');
    expect(win['audio-device'], 'wasapi/{x}');
    expect(win['speed'], '1.2500');
    expect(win['volume'], '70.00');
    expect(
      win.containsKey('audio-samplerate'),
      isFalse,
      reason: '独占时设备跟随源，不全局钉采样率（DSD 走逐文件选项）',
    );
    expect(
      musicMpvProperties(s, platform: MusicOutputPlatform.macos)['ao'],
      'coreaudio',
    );
    expect(
      musicMpvProperties(
        s,
        platform: MusicOutputPlatform.windows,
        exclusiveAllowed: false,
      )['audio-exclusive'],
      'no',
      reason: '独占打不开后退回共享',
    );
    expect(
      musicMpvProperties(
        s,
        platform: MusicOutputPlatform.android,
      ).containsKey('audio-exclusive'),
      isFalse,
      reason: 'Android 走平台 bit-perfect 混音属性，不是 mpv 独占',
    );
  });

  test('睡眠定时「播完本曲停」：不再预排下一首，播完停在下一首开头', () async {
    await engine.playQueue(<MusicPlayItem>[_item('a'), _item('b')]);
    await engine.setStopAfterCurrent(true);
    expect(backend.next, isNull);
    backend.controller.add(const MusicBackendCompleted());
    await Future<void>.delayed(Duration.zero);
    expect(engine.isPlaying, isFalse);
    expect(engine.current?.trackUid, 'b');
    expect(engine.stopAfterCurrent, isFalse);
    await engine.play();
    expect(backend.log.last, 'open:b+null');
  });

  test('Advanced 带曲目 uid 时按 uid 对位（切换期内队列被重排也不错位）', () async {
    await engine.playQueue(<MusicPlayItem>[
      _item('a'),
      _item('b'),
      _item('c'),
    ], context: MusicQueueContext.album);
    backend.controller.add(const MusicBackendAdvanced('c'));
    await Future<void>.delayed(Duration.zero);
    expect(engine.current?.trackUid, 'c');
  });

  group('断点续播（music_resume.dart）', () {
    /// 记下每次问起点的（曲目, 意图），按 [saved] 回答（resolveEpisodeStart 的意图分类）。
    late List<(String, EpisodeStartIntent)> asked;
    late Map<String, int> saved;
    late List<MusicTrackLeave> left;

    Future<Duration> answer(MusicPlayItem i, EpisodeStartIntent intent) {
      asked.add((i.trackUid, intent));
      return Future<Duration>.value(
        Duration(
          milliseconds: resolveEpisodeStart(
            intent,
            saved[i.trackUid] ?? 0,
            i.durationMs,
          ),
        ),
      );
    }

    setUp(() {
      asked = <(String, EpisodeStartIntent)>[];
      saved = <String, int>{};
      left = <MusicTrackLeave>[];
      engine
        ..resolveStartPosition = answer
        ..onTrackLeft = left.add;
    });

    test('列表点开 / 跳转 / 下一首从断点起播，上一首从头', () async {
      saved = <String, int>{'a': 60000, 'b': 30000, 'c': 45000};
      await engine.playQueue(<MusicPlayItem>[
        _item('a'),
        _item('b'),
        _item('c'),
      ]);
      expect(backend.startAts.last, const Duration(seconds: 60));
      expect(engine.position, const Duration(seconds: 60));
      expect(engine.restoringResume, isTrue);
      await engine.skipNext();
      expect(backend.startAts.last, const Duration(seconds: 30));
      await engine.jumpTo(2);
      expect(backend.startAts.last, const Duration(seconds: 45));
      // 位置 ≤ 3 秒时「上一首」退到上一首：manualPrevious 从头。
      await engine.seek(Duration.zero);
      await engine.skipPrevious();
      expect(engine.current?.trackUid, 'b');
      expect(backend.startAts.last, Duration.zero);
      expect(
        asked.map(((String, EpisodeStartIntent) a) => a.$2).toList(),
        <EpisodeStartIntent>[
          EpisodeStartIntent.listSelect,
          EpisodeStartIntent.manualNext,
          EpisodeStartIntent.listSelect,
          EpisodeStartIntent.manualPrevious,
        ],
      );
    });

    test('playQueue(resume: false)：这一次从头，不问断点', () async {
      saved = <String, int>{'a': 60000};
      await engine.playQueue(<MusicPlayItem>[_item('a')], resume: false);
      expect(asked, isEmpty);
      expect(backend.startAts.last, Duration.zero);
    });

    test('无缝推进到的下一首不问断点、从头放', () async {
      saved = <String, int>{'b': 30000};
      await engine.playQueue(<MusicPlayItem>[_item('a'), _item('b')]);
      asked.clear();
      backend.controller.add(const MusicBackendAdvanced());
      await Future<void>.delayed(Duration.zero);
      expect(engine.current?.trackUid, 'b');
      expect(asked, isEmpty);
      expect(engine.position, Duration.zero);
      expect(engine.restoringResume, isFalse);
    });

    test('拿不到流的自动跳过按自动连播问（从头）', () async {
      saved = <String, int>{'b': 30000};
      await engine.playQueue(<MusicPlayItem>[_item('a'), _item('b')]);
      backend.controller.add(
        const MusicBackendFailed(
          'gone',
          reason: MusicPlaybackFailure.trackUnavailable,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(engine.current?.trackUid, 'b');
      expect(asked.last, ('b', EpisodeStartIntent.autoAdvance));
      expect(backend.startAts.last, Duration.zero);
    });

    test('后端不能从曲内起播（Apple Music）时不问断点', () async {
      final MusicPlayerEngine apple = MusicPlayerEngine(
        backendFactory: () => backend,
        capabilitiesOf: (MusicPlayItem i) => const MusicBackendCapabilities(
          signalPath: false,
          abLoop: false,
          startAt: false,
        ),
      )..resolveStartPosition = answer;
      addTearDown(apple.dispose);
      saved = <String, int>{'a': 60000};
      await apple.playQueue(<MusicPlayItem>[_item('a')]);
      expect(asked, isEmpty);
      expect(backend.startAts.last, Duration.zero);
    });

    test('恢复守护：过渡期的 0 不算落地；追上目标、实际已播宽限、用户 seek 都清掉', () async {
      saved = <String, int>{'a': 60000};
      await engine.playQueue(<MusicPlayItem>[_item('a')]);
      backend.controller.add(const MusicBackendPosition(Duration.zero, null));
      expect(engine.restoringResume, isTrue, reason: '打开时的 0 是过渡值');
      backend.controller.add(
        const MusicBackendPosition(Duration(milliseconds: 58600), null),
      );
      expect(engine.restoringResume, isFalse, reason: '差 1.5 秒以内算落地');

      // 起点没落地（不可 seek 的流）：从开头实际播过宽限就放弃守护。
      await engine.jumpTo(0);
      expect(engine.restoringResume, isTrue);
      backend.controller.add(
        const MusicBackendPosition(Duration(seconds: 9), null),
      );
      expect(engine.restoringResume, isTrue);
      backend.controller.add(
        const MusicBackendPosition(kMusicResumeGuardGrace, null),
      );
      expect(engine.restoringResume, isFalse);

      // 恢复还没落地时用户自己往前拖：立即清守护。
      await engine.jumpTo(0);
      expect(engine.restoringResume, isTrue);
      await engine.seek(const Duration(seconds: 5));
      expect(engine.restoringResume, isFalse);
      expect(engine.position, const Duration(seconds: 5));
    });

    test('换曲时报 onTrackLeft：带换下前的位置与「恢复是否落地」', () async {
      saved = <String, int>{'b': 30000};
      await engine.playQueue(<MusicPlayItem>[
        _item('a'),
        _item('b'),
        _item('c'),
      ]);
      backend.controller.add(
        const MusicBackendPosition(Duration(seconds: 12), null),
      );
      await engine.skipNext();
      expect(left.single.item.trackUid, 'a');
      expect(left.single.position, const Duration(seconds: 12));
      expect(left.single.restoring, isFalse);
      expect(left.single.duration, const Duration(milliseconds: 200000));
      // b 的断点还没落地就切走：标成 restoring（位置是过渡值，不能写）。
      await engine.skipNext();
      expect(left.last.item.trackUid, 'b');
      expect(left.last.restoring, isTrue);
      expect(engine.startedItem?.trackUid, 'c');
      await engine.stop();
      expect(left.last.item.trackUid, 'c');
      expect(engine.startedItem, isNull);
    });

    test('读断点期间用户又切了曲：旧结果不套到新曲上', () async {
      final Completer<Duration> slow = Completer<Duration>();
      engine.resolveStartPosition =
          (MusicPlayItem i, EpisodeStartIntent intent) {
            asked.add((i.trackUid, intent));
            return i.trackUid == 'a'
                ? slow.future
                : Future<Duration>.value(Duration.zero);
          };
      final Future<void> first = engine.playQueue(<MusicPlayItem>[
        _item('a'),
        _item('b'),
      ]);
      await Future<void>.delayed(Duration.zero);
      await engine.jumpTo(1);
      slow.complete(const Duration(seconds: 90));
      await first;
      expect(engine.current?.trackUid, 'b');
      expect(backend.startAts, <Duration>[Duration.zero]);
      expect(backend.log.where((String l) => l.startsWith('open:')), <String>[
        'open:b+null',
      ]);
      expect(engine.restoringResume, isFalse);
    });
  });
}
