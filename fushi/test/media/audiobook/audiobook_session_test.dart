// ignore_for_file: experimental_member_use
import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart' as ag;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:fushi/src/media/audiobook/audiobook_controller.dart';
import 'package:fushi/src/media/audiobook/audiobook_session.dart';
import 'package:fushi/src/utils/misc/fushi_audio_handler.dart';
import 'package:fushi/src/media/audiobook/floating_lyric_channel.dart';
import 'package:fushi/src/media/audiobook/remote/audiobook_remote_playback.dart';
import 'package:fushi/src/media/range_playback.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:just_audio/just_audio.dart'
    show AudioSource, StreamAudioResponse, StreamAudioSource;
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

/// TODO-291 阶段2 行为守卫：[AudiobookSession] 是进程级常驻控制器持有者。
/// 钉住：
///  - start 后会话持有控制器（退书可后台听书的地基）；
///  - attachReader 把 WebView 侧回调装到控制器；
///  - detachReader **不 dispose 控制器**（核心：退书音频继续），并把
///    getCurrentReaderSection 复位成 -1（跨章守卫天然不动作）；
///  - cue 变化 attach 期转发给 reader（保正文高亮链路），detach 后不再转发；
///  - start 第二本书顶掉第一本（同一时刻一本会话）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  AudioCue cue(int startMs) => AudioCue()
    ..id = startMs
    ..bookKey = 'book'
    ..chapterHref = 'chapter'
    ..sentenceIndex = startMs ~/ 1000
    ..textFragmentId = 'cue-$startMs'
    ..text = 'cue $startMs'
    ..startMs = startMs
    ..endMs = startMs + 1000
    ..audioFileIndex = 0;

  Audiobook ab(String key) => Audiobook()
    ..bookKey = key
    ..audioPaths = const <String>[]
    ..audioRoot = null
    ..alignmentFormat = 'srt'
    ..alignmentPath = '';

  File makeFile(String name) {
    final File f = File('${Directory.systemTemp.path}/$name');
    if (!f.existsSync()) f.writeAsBytesSync(const <int>[0]);
    addTearDown(() {
      if (f.existsSync()) f.deleteSync();
    });
    return f;
  }

  _FakePlatform installPlatform() {
    const MethodChannel ch = MethodChannel('com.ryanheise.audio_session');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ch, (_) async => null);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ch, null);
    });
    final JustAudioPlatform prev = JustAudioPlatform.instance;
    final _FakePlatform platform = _FakePlatform();
    JustAudioPlatform.instance = platform;
    addTearDown(() => JustAudioPlatform.instance = prev);
    return platform;
  }

  setUp(() {
    // 悬浮窗在 host 不可用：override 成不支持，所有悬浮窗调用短路（不打平台通道）。
    FloatingLyricChannel.platformOverride = false;
  });
  tearDown(() {
    FloatingLyricChannel.platformOverride = null;
  });

  AudiobookSession makeSession({
    FushiDatabase? db,
    FushiAudioHandler? handler,
    bool Function()? showMediaNotification,
  }) {
    return AudiobookSession(
      audioHandler: () => handler,
      showFloatingLyric: () => false,
      showMediaNotification: showMediaNotification ?? () => false,
      floatingLyricVisibleLines: () => 1,
      floatingLyricStyle: () => const FloatingLyricStyle(
        fontSize: 16,
        textColor: 0,
        bgColor: 0,
        buttonTextColor: 0,
        buttonBgColor: 0,
        highlightColor: 0,
        activeColor: 0,
      ),
      floatingLyricClickLookup: () => false,
      onFloatingLyricLookup: (_, __, ___) {},
      controlStreams: AudioControlStreams(
        playIntentStream: const Stream<MediaPlayIntent>.empty(),
        seekStream: const Stream<Duration>.empty(),
        skipNextStream: const Stream<void>.empty(),
        skipPreviousStream: const Stream<void>.empty(),
        toggleFloatingLyricStream: const Stream<void>.empty(),
      ),
      // BUG-2558：库给 null = 不建后台听书时钟（默认装置不碰统计）；只有验统计的
      // 用例传内存库进来。
      database: () => db,
      studyIdleTimeout: () => const Duration(minutes: 10),
    );
  }

  SessionPrefs prefs() => const SessionPrefs(
    followAudio: true,
    delayMs: 0,
    speed: 1.0,
    positionMs: 0,
    imagePauseSec: 0,
    volume: 1.0,
  );

  SessionPersistCallbacks persist() => SessionPersistCallbacks(
    onPositionWrite: (_, __) async {},
    onDelayPersist: (_) async {},
    onSpeedPersist: (_) async {},
    onVolumePersist: (_) async {},
    onImagePausePersist: (_) async {},
    onFollowAudioPersist: (_) async {},
  );

  Future<AudiobookSession> startedSession(
    String key, {
    List<AudioCue> cues = const <AudioCue>[],
    int positionMs = 0,
    FushiDatabase? db,
    FushiAudioHandler? handler,
    bool Function()? showMediaNotification,
  }) async {
    installPlatform();
    final AudiobookSession session = makeSession(
      db: db,
      handler: handler,
      showMediaNotification: showMediaNotification,
    );
    addTearDown(session.dispose);
    await session.start(
      info: SessionBookInfo(
        bookKey: key,
        audiobook: ab(key),
        title: 'Book $key',
        mediaIdentifier: 'fushi://book/$key',
      ),
      audioFiles: <File>[makeFile('fushi-session-$key.mp3')],
      prefs: SessionPrefs(
        followAudio: true,
        delayMs: 0,
        speed: 1.0,
        positionMs: positionMs,
        imagePauseSec: 0,
        volume: 1.0,
      ),
      persist: persist(),
      cues: cues,
    );
    return session;
  }

  test('start holds a live controller and book metadata', () async {
    final AudiobookSession session = await startedSession('a');
    expect(session.isActive, isTrue);
    expect(session.controller, isNotNull);
    expect(session.book?.bookKey, 'a');
  });

  test(
    'start loads cues so currentCue resolves without a reader (TODO-354)',
    () async {
      // 后台听书（书架开悬浮字幕）无 reader 喂 cue。把 cue 随 start 传入后，控制器应在
      // load 后立即按当前位置解析 currentCue（悬浮窗首帧有字），无需进 reader。
      final AudiobookSession session = await startedSession(
        'a',
        cues: <AudioCue>[cue(0), cue(1000), cue(2000)],
        positionMs: 1000,
      );
      final AudiobookPlayerController c = session.controller!;
      expect(c.chapterCueCount, 3, reason: 'cue 应灌进控制器供跳句/解析');
      expect(
        c.currentCue,
        isNotNull,
        reason: '无 reader 也应解析出 currentCue（首帧有字）',
      );
      expect(
        c.currentCue?.startMs,
        1000,
        reason: 'currentCue 应对应 initialPositionMs=1000 那一句',
      );
    },
  );

  test(
    'start without cues leaves the controller cue-less (reader path)',
    () async {
      // 不传 cue（reader 自己接管 cue 加载）时不动控制器，保留既有逻辑。
      final AudiobookSession session = await startedSession('a');
      final AudiobookPlayerController c = session.controller!;
      expect(c.chapterCueCount, 0);
      expect(c.currentCue, isNull);
    },
  );

  test(
    'attachReader wires the controller WebView callbacks to the reader',
    () async {
      final AudiobookSession session = await startedSession('a');
      final _FakeReader reader = _FakeReader(section: 3);
      session.attachReader(reader);

      final AudiobookPlayerController c = session.controller!;
      expect(
        c.getCurrentReaderSection?.call(),
        3,
        reason: 'attach 后跨章判定参照系应是 reader 当前章',
      );
      expect(c.onCrossChapter, isNotNull);
      expect(c.onBoundarySkip, isNotNull);
      expect(session.hasReaderAttached, isTrue);
    },
  );

  test(
    'detachReader keeps the controller alive (background listening core)',
    () async {
      final AudiobookSession session = await startedSession('a');
      final _FakeReader reader = _FakeReader(section: 3);
      session.attachReader(reader);

      final AudiobookPlayerController before = session.controller!;
      session.detachReader(reader);

      // 核心：detach 不 dispose 控制器，会话仍活（音频继续播）。
      expect(session.isActive, isTrue);
      expect(identical(session.controller, before), isTrue);
      expect(session.hasReaderAttached, isFalse);
      // getCurrentReaderSection 复位成 -1：跨章守卫 currentSec<0 分支天然不跨章。
      expect(before.getCurrentReaderSection?.call(), -1);
      expect(before.onCrossChapter, isNull);
      expect(before.onBoundarySkip, isNull);
    },
  );

  test(
    'cue change forwards to reader while attached, stops after detach',
    () async {
      final AudiobookSession session = await startedSession('a');
      final _FakeReader reader = _FakeReader(section: 0);
      session.attachReader(reader);

      final AudiobookPlayerController c = session.controller!;
      c.setChapterCues(<AudioCue>[cue(0), cue(1000), cue(2000)]);
      c.debugUpdateCueForPosition(1000);
      expect(
        reader.cueChangedCount,
        greaterThan(0),
        reason: 'attach 期 cue 变化应转发 reader 接 WebView 高亮',
      );

      final int attachedCount = reader.cueChangedCount;
      session.detachReader(reader);
      c.debugUpdateCueForPosition(2000);
      expect(
        reader.cueChangedCount,
        attachedCount,
        reason: 'detach 后 cue 变化不再转发 reader（无 WebView 可动）',
      );
    },
  );

  test(
    'starting a second book stops the first (single active session)',
    () async {
      final AudiobookSession session = await startedSession('a');
      final AudiobookPlayerController first = session.controller!;

      await session.start(
        info: SessionBookInfo(
          bookKey: 'b',
          audiobook: ab('b'),
          title: 'Book b',
          mediaIdentifier: 'fushi://book/b',
        ),
        audioFiles: <File>[makeFile('fushi-session-b.mp3')],
        prefs: prefs(),
        persist: persist(),
      );

      expect(session.book?.bookKey, 'b');
      expect(
        identical(session.controller, first),
        isFalse,
        reason: '切书应顶掉旧控制器换新',
      );
    },
  );

  group('BUG-3777 A 媒体通知开关关着也要保活（最简通知）', () {
    FushiAudioHandler buildHandler() => FushiAudioHandler(
      onPlayIntent: (_) {},
      onSeek: (_) {},
      onRewind: () {},
      onFastForward: () {},
      onSkipToNext: () {},
      onSkipToPrevious: () {},
      onToggleFloatingLyric: () {},
    );

    void expectMinimal(FushiAudioHandler handler, {required bool playing}) {
      final ag.PlaybackState state = handler.playbackState.value;
      expect(state.playing, playing);
      expect(
        state.processingState,
        ag.AudioProcessingState.ready,
        reason: '不能是 idle：idle 会让 audio_service 当场 stop 前台服务',
      );
      expect(state.controls, <ag.MediaControl>[
        if (playing) ag.MediaControl.pause else ag.MediaControl.play,
      ], reason: '最简通知只留播放 / 暂停（无上下句、无悬浮字幕键）');
      expect(state.systemActions, isEmpty, reason: '不声明 seek = 不画进度条');
      expect(state.androidCompactActionIndices, <int>[0]);
      final ag.MediaItem? item = handler.mediaItem.value;
      expect(item, isNotNull, reason: '前台服务的通知要有标题');
      expect(item!.title, 'Book a');
      expect(item.artist, isNull);
      expect(item.artUri, isNull);
      expect(item.duration, isNull);
      expect(item.displaySubtitle, isNull, reason: '不推当前句副标题');
    }

    test('开关关着播放：播放态照推给 audio_service，卡片是最简形态', () async {
      final FushiAudioHandler handler = buildHandler();
      final AudiobookSession session = await startedSession(
        'a',
        cues: <AudioCue>[cue(0), cue(1000)],
        handler: handler,
        showMediaNotification: () => false,
      );
      expectMinimal(handler, playing: false);

      await session.controller!.play();
      await pumpEventQueue();
      expectMinimal(handler, playing: true);

      await session.controller!.pause();
      await pumpEventQueue();
      expectMinimal(handler, playing: false);
    });

    test('播放中切开关：开→关 换最简且全程不出现 idle，关→开 恢复完整', () async {
      final FushiAudioHandler handler = buildHandler();
      bool show = true;
      final AudiobookSession session = await startedSession(
        'a',
        cues: <AudioCue>[cue(0), cue(1000)],
        handler: handler,
        showMediaNotification: () => show,
      );
      await session.controller!.play();
      await pumpEventQueue();
      expect(handler.playbackState.value.playing, isTrue);
      expect(
        handler.playbackState.value.controls.length,
        4,
        reason: '完整形态：上句 / 暂停 / 下句 / 悬浮字幕',
      );

      final List<ag.PlaybackState> seen = <ag.PlaybackState>[];
      final StreamSubscription<ag.PlaybackState> sub = handler.playbackState
          .listen(seen.add);
      addTearDown(sub.cancel);

      show = false;
      session.onMediaNotificationToggled(enabled: false);
      await pumpEventQueue();
      expectMinimal(handler, playing: true);

      show = true;
      session.onMediaNotificationToggled(enabled: true);
      await pumpEventQueue();
      final ag.PlaybackState full = handler.playbackState.value;
      expect(full.playing, isTrue);
      expect(full.controls, contains(ag.MediaControl.skipToNext));
      expect(full.systemActions, contains(ag.MediaAction.seek));
      expect(
        handler.mediaItem.value?.duration,
        isNotNull,
        reason: '完整卡片带时长（进度条）',
      );

      expect(
        seen.where(
          (ag.PlaybackState s) =>
              s.processingState == ag.AudioProcessingState.idle,
        ),
        isEmpty,
        reason: '播放中切开关不得推 idle（会 stop 前台服务）',
      );
    });

    test('停会话照旧清掉通知（idle + 无卡片）', () async {
      final FushiAudioHandler handler = buildHandler();
      final AudiobookSession session = await startedSession(
        'a',
        handler: handler,
        showMediaNotification: () => false,
      );
      await session.controller!.play();
      await pumpEventQueue();
      expect(handler.playbackState.value.playing, isTrue);

      await session.stop();
      expect(
        handler.playbackState.value.processingState,
        ag.AudioProcessingState.idle,
      );
      expect(handler.mediaItem.value, isNull);
    });
  });

  test('stop disposes the controller and clears the session', () async {
    final AudiobookSession session = await startedSession('a');
    await session.stop();
    expect(session.isActive, isFalse);
    expect(session.controller, isNull);
    expect(session.book, isNull);
  });

  group('BUG-2558：退出阅读器后台听书期间的学习统计', () {
    // 根因：阅读器那只 StudyClock 随 reader 页 dispose 一起 detach，于是「退出书籍页
    // → 锁屏 → 经媒体中心继续听」整段没有任何统计写入方。会话自己补一只，与阅读器
    // 那只**互斥**（判据含 hasReaderAttached），两只同时跑就是同一段时间记两遍。
    FushiDatabase memoryDb() {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      return db;
    }

    test('reader 在场不起表、reader 一走接手、重进书再交回（互斥交接）', () async {
      final AudiobookSession session = await startedSession(
        'a',
        db: memoryDb(),
      );
      final AudiobookPlayerController c = session.controller!;
      final _FakeReader reader = _FakeReader(section: 0);

      session.attachReader(reader);
      await c.play();
      await pumpEventQueue();
      expect(
        session.debugBackgroundStudyClockRunning,
        isFalse,
        reason: 'reader 在场时统计归阅读器那只时钟，会话这只必须停着',
      );

      session.detachReader(reader);
      expect(
        session.debugBackgroundStudyClockRunning,
        isTrue,
        reason: '「退出书籍页继续听」这一段过去完全没有统计写入方',
      );

      session.attachReader(reader);
      expect(
        session.debugBackgroundStudyClockRunning,
        isFalse,
        reason: '重进书交回阅读器那只时钟，不得两只并行',
      );
    });

    test('后台暂停即停表、再播即续表（用户要的「关了有声书就关统计」）', () async {
      final AudiobookSession session = await startedSession(
        'a',
        db: memoryDb(),
      );
      final AudiobookPlayerController c = session.controller!;
      final _FakeReader reader = _FakeReader(section: 0);
      session.attachReader(reader);
      session.detachReader(reader);

      await c.play();
      await pumpEventQueue();
      expect(session.debugBackgroundStudyClockRunning, isTrue);

      await c.pause();
      await pumpEventQueue();
      expect(
        session.debugBackgroundStudyClockRunning,
        isFalse,
        reason: '媒体中心 / 耳机键暂停后会话仍在（通知还挂着），但那不是学习时间',
      );

      await c.play();
      await pumpEventQueue();
      expect(
        session.debugBackgroundStudyClockRunning,
        isTrue,
        reason: '后台按播放要立刻续表，不能等回前台',
      );
    });

    test('没在播时 reader 离场不起表（退书时本来就是暂停态）', () async {
      final AudiobookSession session = await startedSession(
        'a',
        db: memoryDb(),
      );
      final _FakeReader reader = _FakeReader(section: 0);
      session.attachReader(reader);
      session.detachReader(reader);
      expect(
        session.debugBackgroundStudyClockRunning,
        isFalse,
        reason: '会话活着 ≠ 在学习；判据要的是「真在出声」',
      );
    });

    test('停会话结算并放掉时钟', () async {
      final AudiobookSession session = await startedSession(
        'a',
        db: memoryDb(),
      );
      final AudiobookPlayerController c = session.controller!;
      final _FakeReader reader = _FakeReader(section: 0);
      session.attachReader(reader);
      session.detachReader(reader);
      await c.play();
      await pumpEventQueue();
      expect(session.debugBackgroundStudyClockRunning, isTrue);

      await session.stop();
      expect(
        session.debugBackgroundStudyClockRunning,
        isFalse,
        reason: '换书 / 显式停会话必须在 _book 被清空前把这只时钟结算掉',
      );
    });

    test('库不可用时不建时钟，播放本身照常（默认装置即此形态）', () async {
      final AudiobookSession session = await startedSession('a');
      final AudiobookPlayerController c = session.controller!;
      final _FakeReader reader = _FakeReader(section: 0);
      session.attachReader(reader);
      session.detachReader(reader);
      await c.play();
      await pumpEventQueue();
      expect(session.debugBackgroundStudyClockRunning, isFalse);
      expect(c.isPlaying, isTrue, reason: '统计不可用不得影响播放');
    });

    test('统计身份回退：statsMediaKey 缺席时用 bookKey', () {
      // launcher 两条分支都会显式填 statsMediaKey（SRT 分支的 bookKey 是 srt_books.uid，
      // 与阅读器用的身份不是同一个串）；旧构造点 / 测试缺席时回退 bookKey。
      expect(
        SessionBookInfo(
          bookKey: 'uid-1',
          audiobook: ab('uid-1'),
          title: 'T',
          mediaIdentifier: 'fushi://book/k',
          statsMediaKey: 'book-key-1',
        ).studyMediaKey,
        'book-key-1',
      );
      expect(
        SessionBookInfo(
          bookKey: 'uid-1',
          audiobook: ab('uid-1'),
          title: 'T',
          mediaIdentifier: 'fushi://book/uid-1',
        ).studyMediaKey,
        'uid-1',
      );
    });
  });

  test(
    'BUG-1240 a new session waits for the old generation to release',
    () async {
      final _FakePlatform platform = installPlatform();
      final AudiobookSession session = makeSession();
      addTearDown(session.dispose);
      await session.start(
        info: SessionBookInfo(
          bookKey: 'old',
          audiobook: ab('old'),
          title: 'Old',
          mediaIdentifier: 'fushi://book/old',
        ),
        audioFiles: <File>[makeFile('fushi-session-old-generation.mp3')],
        prefs: prefs(),
        persist: persist(),
      );
      await session.controller!.play();
      platform.disposeGate = Completer<void>();

      final Future<void> stopOld = session.stop();
      await platform.disposeStarted.future;
      final Future<AudiobookPlayerController?> startNew = session.start(
        info: SessionBookInfo(
          bookKey: 'new',
          audiobook: ab('new'),
          title: 'New',
          mediaIdentifier: 'fushi://book/new',
        ),
        audioFiles: <File>[makeFile('fushi-session-new-generation.mp3')],
        prefs: prefs(),
        persist: persist(),
      );
      await Future<void>.delayed(Duration.zero);

      expect(
        session.book,
        isNull,
        reason: 'the new generation must not publish before old release',
      );
      platform.disposeGate!.complete();
      await stopOld;
      await startNew;
      expect(session.book?.bookKey, 'new');
      expect(session.controller, isNotNull);
    },
  );

  test(
    'BUG-3197 stop re-encodes the live position against the replaced cues',
    () async {
      // 会话期间字幕被整组替换（阅读器内重新导入字幕 -> forceReload 先 stop 旧会话）：
      // stop 落库的全书毫秒必须按**库里新 cue** 推出的文件时长编码，否则下次开书按
      // 新 cue 一拆，听书断点落到别的文件 / 偏移。
      AudioCue fileCue(int index, int file, int endMs) => AudioCue()
        ..id = index + 1
        ..bookKey = 'a'
        ..chapterHref = 'chapter'
        ..sentenceIndex = index
        ..textFragmentId = 'cue-$index'
        ..text = 'cue $index'
        ..startMs = 0
        ..endMs = endMs
        ..audioFileIndex = file;

      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      // 库里已经是新字幕：文件 0 的末句结束于 12s（旧字幕是 10s）。
      await AudiobookRepository(db).saveCues(
        bookKey: 'a',
        cues: <AudioCue>[fileCue(0, 0, 12000), fileCue(1, 1, 25000)],
      );

      installPlatform();
      final AudiobookSession session = makeSession(db: db);
      addTearDown(session.dispose);
      final List<int> writes = <int>[];
      await session.start(
        info: SessionBookInfo(
          bookKey: 'a',
          audiobook: ab('a'),
          title: 'Book a',
          mediaIdentifier: 'fushi://book/a',
        ),
        audioFiles: <File>[
          makeFile('fushi-session-bug3197-0.mp3'),
          makeFile('fushi-session-bug3197-1.mp3'),
        ],
        // 旧字幕编码下的「文件 1 第 3 秒」= 10000 + 3000。
        prefs: const SessionPrefs(
          followAudio: true,
          delayMs: 0,
          speed: 1.0,
          positionMs: 13000,
          imagePauseSec: 0,
          volume: 1.0,
        ),
        persist: SessionPersistCallbacks(
          onPositionWrite: (_, int ms) async => writes.add(ms),
          onDelayPersist: (_) async {},
          onSpeedPersist: (_) async {},
          onVolumePersist: (_) async {},
          onImagePausePersist: (_) async {},
          onFollowAudioPersist: (_) async {},
        ),
        cues: <AudioCue>[fileCue(0, 0, 10000), fileCue(1, 1, 20000)],
      );
      final AudiobookPlayerController c = session.controller!;
      expect(
        c.globalPosition.inMilliseconds,
        13000,
        reason: 'precondition: restored to file 1 at 3s under the old cues',
      );

      writes.clear();
      await session.stop();

      expect(writes, isNotEmpty);
      expect(
        writes.last,
        12000 + 3000,
        reason: 'file 1 at 3s, encoded with the new per-file cue durations',
      );
    },
  );

  test('BUG-3251 replacing the cues while playing switches periodic writes '
      'to the new encoding at once', () async {
    // 书架 / 互联「只更新字幕」在会话**播放中**换掉库里的 cue：此前要等到 stop 才
    // 换编码，期间 app 被直接杀掉，库里留下的就是旧编码。
    AudioCue fileCue(int index, int file, int endMs) => AudioCue()
      ..id = index + 1
      ..bookKey = 'a'
      ..chapterHref = 'chapter'
      ..sentenceIndex = index
      ..textFragmentId = 'cue-$index'
      ..text = 'cue $index'
      ..startMs = 0
      ..endMs = endMs
      ..audioFileIndex = file;

    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final List<AudioCue> oldCues = <AudioCue>[
      fileCue(0, 0, 10000),
      fileCue(1, 1, 20000),
    ];
    await AudiobookRepository(db).saveCues(bookKey: 'a', cues: oldCues);

    installPlatform();
    final AudiobookSession session = makeSession(db: db);
    addTearDown(session.dispose);
    await session.start(
      info: SessionBookInfo(
        bookKey: 'a',
        audiobook: ab('a'),
        title: 'Book a',
        mediaIdentifier: 'fushi://book/a',
      ),
      audioFiles: <File>[
        makeFile('fushi-session-bug3251-0.mp3'),
        makeFile('fushi-session-bug3251-1.mp3'),
      ],
      prefs: const SessionPrefs(
        followAudio: true,
        delayMs: 0,
        speed: 1.0,
        positionMs: 13000,
        imagePauseSec: 0,
        volume: 1.0,
      ),
      persist: SessionPersistCallbacks(
        onPositionWrite: (_, int ms) async {},
        onDelayPersist: (_) async {},
        onSpeedPersist: (_) async {},
        onVolumePersist: (_) async {},
        onImagePausePersist: (_) async {},
        onFollowAudioPersist: (_) async {},
      ),
      cues: oldCues,
    );
    final AudiobookPlayerController c = session.controller!;
    expect(
      c.globalPosition.inMilliseconds,
      13000,
      reason: 'precondition: file 1 at 3s under the old cues',
    );

    // 播放中换字幕：文件 0 的末句改为 12s 结束。
    await AudiobookRepository(db).saveCues(
      bookKey: 'a',
      cues: <AudioCue>[fileCue(0, 0, 12000), fileCue(1, 1, 25000)],
    );
    for (int i = 0; i < 50 && c.globalPosition.inMilliseconds != 15000; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(
      c.globalPosition.inMilliseconds,
      12000 + 3000,
      reason:
          'the live controller adopts the new cues before any stop, so '
          'periodic writes are encoded with the new per-file durations',
    );
  });

  group('remote (streaming) audio', () {
    Future<(AudiobookSession, _FakePlatform, _StubRemote)> startRemote() async {
      final _FakePlatform platform = installPlatform();
      final AudiobookSession session = makeSession();
      addTearDown(session.dispose);
      final _StubRemote remote = _StubRemote();
      await session.start(
        info: SessionBookInfo(
          bookKey: 'r',
          audiobook: ab('r'),
          title: 'Remote',
          mediaIdentifier: 'fushi://book/r',
        ),
        audioFiles: remote.placeholderFiles,
        prefs: prefs(),
        persist: persist(),
        remote: remote,
      );
      return (session, platform, remote);
    }

    test('start(remote): 控制器标记为远端，音源来自接缝，占位文件撑住下标', () async {
      final (AudiobookSession session, _FakePlatform platform, _StubRemote r) =
          await startRemote();
      final AudiobookPlayerController c = session.controller!;
      expect(c.isRemoteAudio, isTrue);
      expect(c.remotePlayback, same(r));
      expect(c.audioFiles, same(r.placeholderFiles));
      // load 用 preload:false，平台播放器在第一次真要播时才建：播一下激活它。
      await c.play();
      await pumpEventQueue();
      final AudioSourceMessage loaded =
          platform.players.first.lastLoad!.audioSourceMessage;
      expect(loaded, isA<ConcatenatingAudioSourceMessage>());
      expect(
        (loaded as ConcatenatingAudioSourceMessage).children,
        hasLength(2),
        reason: '一轨一个流式源，不是按占位路径建的文件源',
      );
    });

    test('trackInputFor：远端书走接缝（地址 + 鉴权头），本机书是文件路径', () async {
      final (AudiobookSession session, _, _StubRemote _) = await startRemote();
      final AudiobookTrackInput remoteInput = await session.controller!
          .trackInputFor(1);
      expect(remoteInput.input, 'https://abs.example/f1');
      expect(remoteInput.headers['Authorization'], 'Bearer t');
      expect(remoteInput.isRemote, isTrue);

      final AudiobookSession local = await startedSession('local');
      final AudiobookPlayerController lc = local.controller!;
      expect(lc.isRemoteAudio, isFalse);
      final AudiobookTrackInput localInput = await lc.trackInputFor(0);
      expect(localInput.input, lc.audioFiles.first.path);
      expect(localInput.headers, isEmpty);
    });

    test('起会话后把播放器接给远端接缝（进度同步用），位置 / 播放状态可读', () async {
      final (AudiobookSession session, _, _StubRemote r) = await startRemote();
      await pumpEventQueue();
      final RemotePlaybackHost host = r.attached!;
      expect(host.isPlaying(), isFalse);
      expect(host.filePosition(), (fileIndex: 0, positionMs: 0));
      int notified = 0;
      void listener() => notified++;
      host.addListener(listener);
      await session.controller!.setSpeed(1.5);
      expect(notified, greaterThan(0), reason: '控制器变化会通知到接缝挂的监听');
      host.removeListener(listener);
      final int before = notified;
      await session.controller!.setSpeed(1.0);
      expect(notified, before, reason: '摘掉监听后不再通知');
      expect(session.controller!.currentFilePosition.fileIndex, 0);
    });

    test('接缝 attach 失败（离线）不影响开书，会话照常可用', () async {
      final _FakePlatform platform = installPlatform();
      expect(platform, isNotNull);
      final AudiobookSession session = makeSession();
      addTearDown(session.dispose);
      final _StubRemote remote = _StubRemote()..attachThrows = true;
      final AudiobookPlayerController? controller = await session.start(
        info: SessionBookInfo(
          bookKey: 'offline',
          audiobook: ab('offline'),
          title: 'Offline',
          mediaIdentifier: 'fushi://book/offline',
        ),
        audioFiles: remote.placeholderFiles,
        prefs: prefs(),
        persist: persist(),
        remote: remote,
      );
      await pumpEventQueue();
      expect(controller, isNotNull);
      expect(session.isActive, isTrue);
    });

    test('stop() 释放接缝，且只释放一次', () async {
      final (AudiobookSession session, _, _StubRemote r) = await startRemote();
      await session.stop();
      expect(r.released, 1);
      await session.stop();
      expect(r.released, 1);
    });

    test('playRange(远端)：播流式源并 seek 到句首，而不是 ClippingAudioSource', () async {
      final (AudiobookSession session, _FakePlatform platform, _StubRemote _) =
          await startRemote();
      final AudiobookPlayerController c = session.controller!;
      // play() 要等播放结束才返回，假平台永远不会结束：不 await。
      unawaited(
        c.playRange(
          const AudioPlaybackRange(audioFileIndex: 1, startMs: 500, endMs: 900),
        ),
      );
      await pumpEventQueue();
      // 主播放器还没激活（preload:false），所以唯一的平台播放器就是句子回放的临时播放器。
      expect(platform.players, hasLength(1));
      final _FakePlayer clip = platform.players.single;
      expect(
        clip.lastLoad!.audioSourceMessage,
        isNot(isA<ClippingAudioSourceMessage>()),
      );
      expect(clip.seeks, contains(const Duration(milliseconds: 500)));
      await c.stopClip(resumeMain: false);
    });

    // BUG-3814 / FDN66-xurt：片段的结局要交给调用方（高级制卡的试听按钮据此复位）。
    test('playRange 交回句柄：被 stopClip 收掉时以 interrupted 结束', () async {
      final (AudiobookSession session, _FakePlatform _, _StubRemote _) =
          await startRemote();
      final AudiobookPlayerController c = session.controller!;
      final Future<RangePlayback?> started = c.playRange(
        const AudioPlaybackRange(audioFileIndex: 1, startMs: 500, endMs: 900),
      );
      await pumpEventQueue();
      await c.stopClip(resumeMain: false);
      final RangePlayback? playback = await started;
      expect(playback, isNotNull);
      expect(await playback!.ended, RangePlaybackEnd.interrupted);
    });

    test('playRange(远端)：越界下标与空区间直接忽略', () async {
      final (AudiobookSession session, _FakePlatform platform, _StubRemote _) =
          await startRemote();
      final AudiobookPlayerController c = session.controller!;
      expect(
        await c.playRange(
          const AudioPlaybackRange(audioFileIndex: 5, startMs: 0, endMs: 900),
        ),
        isNull,
      );
      expect(
        await c.playRange(
          const AudioPlaybackRange(audioFileIndex: 0, startMs: 900, endMs: 900),
        ),
        isNull,
      );
      expect(platform.players, isEmpty, reason: '没有为无效区间建临时播放器');
    });
  });
}

class _FakeReader implements ReaderAudiobookView {
  _FakeReader({required this.section});

  int section;
  int cueChangedCount = 0;
  final List<int> crossChapterCalls = <int>[];

  @override
  int getCurrentReaderSection() => section;

  @override
  Future<void> onCueCrossChapter(int sectionIndex) async {
    crossChapterCalls.add(sectionIndex);
  }

  @override
  Future<void> onBoundarySkip(int delta) async {}

  @override
  void onExplicitCueJump(AudioCue cue) {}

  @override
  void onBeforeAudioJump(int fromGlobalMs) {}

  @override
  void onReaderCueChanged() {
    cueChangedCount++;
  }
}

class _FakePlatform extends JustAudioPlatform {
  _FakePlayer? player;

  /// 按创建顺序记下的全部播放器（第 0 个是主播放器，之后是句子回放的临时播放器）。
  final List<_FakePlayer> players = <_FakePlayer>[];
  Completer<void>? disposeGate;
  Completer<void> disposeStarted = Completer<void>();
  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    player = _FakePlayer(request.id);
    players.add(player!);
    return player!;
  }

  @override
  Future<DisposePlayerResponse> disposePlayer(
    DisposePlayerRequest request,
  ) async {
    if (!disposeStarted.isCompleted) disposeStarted.complete();
    await disposeGate?.future;
    await player?.dispose(DisposeRequest());
    return DisposePlayerResponse();
  }

  @override
  Future<DisposeAllPlayersResponse> disposeAllPlayers(
    DisposeAllPlayersRequest request,
  ) async {
    await player?.dispose(DisposeRequest());
    return DisposeAllPlayersResponse();
  }
}

class _FakePlayer extends AudioPlayerPlatform {
  _FakePlayer(super.id);
  LoadRequest? lastLoad;
  final List<Duration?> seeks = <Duration?>[];
  final StreamController<PlaybackEventMessage> _events =
      StreamController<PlaybackEventMessage>.broadcast();

  void emit(int ms, ProcessingStateMessage state, {required bool playing}) {
    _events.add(
      PlaybackEventMessage(
        processingState: state,
        updateTime: DateTime.now(),
        updatePosition: Duration(milliseconds: ms),
        bufferedPosition: Duration(milliseconds: ms),
        duration: const Duration(seconds: 100),
        icyMetadata: null,
        currentIndex: 0,
        androidAudioSessionId: null,
      ),
    );
  }

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    lastLoad = request;
    emit(
      request.initialPosition?.inMilliseconds ?? 0,
      ProcessingStateMessage.ready,
      playing: false,
    );
    return LoadResponse(duration: const Duration(seconds: 100));
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async => PauseResponse();
  @override
  Future<PlayResponse> play(PlayRequest request) async => PlayResponse();
  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    seeks.add(request.position);
    emit(
      request.position?.inMilliseconds ?? 0,
      ProcessingStateMessage.ready,
      playing: false,
    );
    return SeekResponse();
  }

  @override
  Future<SetAndroidAudioAttributesResponse> setAndroidAudioAttributes(
    SetAndroidAudioAttributesRequest request,
  ) async => SetAndroidAudioAttributesResponse();
  @override
  Future<SetAutomaticallyWaitsToMinimizeStallingResponse>
  setAutomaticallyWaitsToMinimizeStalling(
    SetAutomaticallyWaitsToMinimizeStallingRequest request,
  ) async => SetAutomaticallyWaitsToMinimizeStallingResponse();
  @override
  Future<SetCanUseNetworkResourcesForLiveStreamingWhilePausedResponse>
  setCanUseNetworkResourcesForLiveStreamingWhilePaused(
    SetCanUseNetworkResourcesForLiveStreamingWhilePausedRequest request,
  ) async => SetCanUseNetworkResourcesForLiveStreamingWhilePausedResponse();
  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async =>
      SetLoopModeResponse();
  @override
  Future<SetPitchResponse> setPitch(SetPitchRequest request) async =>
      SetPitchResponse();
  @override
  Future<SetPreferredPeakBitRateResponse> setPreferredPeakBitRate(
    SetPreferredPeakBitRateRequest request,
  ) async => SetPreferredPeakBitRateResponse();
  @override
  Future<SetShuffleModeResponse> setShuffleMode(
    SetShuffleModeRequest request,
  ) async => SetShuffleModeResponse();
  @override
  Future<SetShuffleOrderResponse> setShuffleOrder(
    SetShuffleOrderRequest request,
  ) async => SetShuffleOrderResponse();
  @override
  Future<SetSkipSilenceResponse> setSkipSilence(
    SetSkipSilenceRequest request,
  ) async => SetSkipSilenceResponse();
  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async =>
      SetSpeedResponse();
  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async =>
      SetVolumeResponse();
  @override
  Future<SetWebCrossOriginResponse> setWebCrossOrigin(
    SetWebCrossOriginRequest request,
  ) async => SetWebCrossOriginResponse();
  @override
  Future<DisposeResponse> dispose(DisposeRequest request) async {
    if (!_events.isClosed) await _events.close();
    return DisposeResponse();
  }
}

class _StubRemote implements AudiobookRemotePlayback {
  int released = 0;
  RemotePlaybackHost? attached;
  bool attachThrows = false;

  @override
  int get trackCount => 2;

  @override
  List<int> get trackDurationsMs => const <int>[];

  @override
  final List<File> placeholderFiles = <File>[
    File('abs-remote/a.mp3'),
    File('abs-remote/b.mp3'),
  ];

  @override
  List<AudioSource> buildSources() => <AudioSource>[
    for (int i = 0; i < trackCount; i++) buildTrackSource(i),
  ];

  @override
  AudioSource buildTrackSource(int index) => _StubStreamSource(index);

  @override
  Future<AudiobookTrackInput> trackInput(int index) async =>
      AudiobookTrackInput(
        input: 'https://abs.example/f$index',
        headers: const <String, String>{'Authorization': 'Bearer t'},
      );

  @override
  Future<void> attach(RemotePlaybackHost host) async {
    attached = host;
    if (attachThrows) throw StateError('server unreachable');
  }

  @override
  Future<void> release() async => released++;
}

/// 假平台从不真去拉数据，所以流式源的 request 不会被调用。
class _StubStreamSource extends StreamAudioSource {
  _StubStreamSource(this.index) : super(tag: 'stub:$index');

  final int index;

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) =>
      throw UnimplementedError('fake platform never fetches');
}
