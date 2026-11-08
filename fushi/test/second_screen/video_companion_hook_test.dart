import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/second_screen/companion/companion_bridge.dart';
import 'package:fushi/src/second_screen/companion/companion_context.dart';
import 'package:fushi/src/second_screen/companion/companion_lookup_routing.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/companion/companion_snapshot.dart';
import 'package:fushi/src/second_screen/companion/modules/video_companion_hook.dart';
import 'package:fushi/src/second_screen/companion/modules/video_companion_now_playing.dart';
import 'package:fushi/src/second_screen/companion/modules/video_companion_schema.dart';
import 'package:fushi_audio/fushi_audio.dart' show AudioCue;
import 'package:fushi_core/fushi_core.dart';

AudioCue _cue(int i) => AudioCue()
  ..bookKey = ''
  ..chapterHref = ''
  ..sentenceIndex = i
  ..textFragmentId = ''
  ..text = 'line $i'
  ..startMs = i * 1000
  ..endMs = i * 1000 + 800
  ..audioFileIndex = 0;

class _FakePage implements VideoCompanionPage {
  String? currentTitle = 'Episode 3';
  String bookUid = 'ep3';
  int? collectionId = 7;
  bool isPlaying = true;
  int positionMs = 5200;
  List<AudioCue> cues = <AudioCue>[for (int i = 0; i < 10; i++) _cue(i)];
  int currentCue = 5;
  String? subtitleSource = 'embedded:0';
  bool ready = true;
  bool autoPause = false;
  bool loopOn = false;
  int? loopTimes;
  int? loopRemaining;
  int? abA;
  int? abB;
  int lookupsCounted = 0;

  int frames = 0;
  int infoLoads = 0;
  int subtitleLoads = 0;
  VideoCompanionInfo? info = const VideoCompanionInfo(
    workTitle: 'Series',
    rating: 8.4,
    votes: 120,
    episodeNumber: 3,
  );
  final List<String> calls = <String>[];

  @override
  String? get title => currentTitle;

  @override
  bool get playing => isPlaying;

  @override
  VideoCompanionFrame? frame() {
    frames++;
    if (!ready) return null;
    return VideoCompanionFrame(
      bookUid: bookUid,
      collectionId: collectionId,
      title: currentTitle ?? '',
      series: 'Playlist',
      episodeIndex: 2,
      episodeCount: 12,
      playing: isPlaying,
      positionMs: positionMs,
      durationMs: 60000,
      speed: 1.25,
      cues: cues,
      currentCueIndex: currentCue,
      audioTracks: const <VideoCompanionTrack>[
        VideoCompanionTrack(id: '1', label: 'Japanese', selected: true),
        VideoCompanionTrack(id: '2', label: 'English', selected: false),
      ],
      subtitleSource: subtitleSource,
      autoPause: autoPause,
      loopOn: loopOn,
      loopTimes: loopTimes,
      loopRemaining: loopRemaining,
      abAMs: abA,
      abBMs: abB,
    );
  }

  @override
  Future<List<VideoCompanionTrack>> subtitleTracks() async {
    subtitleLoads++;
    return <VideoCompanionTrack>[
      VideoCompanionTrack(
        id: 'embedded:0',
        label: 'JP',
        selected: subtitleSource == 'embedded:0',
      ),
      VideoCompanionTrack(
        id: '/subs/en.srt',
        label: 'EN',
        selected: subtitleSource == '/subs/en.srt',
      ),
    ];
  }

  @override
  Future<VideoCompanionInfo?> loadInfo(
    String bookUid,
    int? collectionId,
  ) async {
    infoLoads++;
    return info;
  }

  @override
  Future<void> toggle() async {
    calls.add('toggle');
    isPlaying = !isPlaying;
  }

  @override
  Future<void> previousCue() async => calls.add('previousCue');

  @override
  Future<void> nextCue() async => calls.add('nextCue');

  @override
  Future<void> seekToMs(int positionMs) async =>
      calls.add('seekTo $positionMs');

  @override
  Future<void> seekByMs(int deltaMs) async => calls.add('seekBy $deltaMs');

  @override
  Future<void> jumpToCue(int startMs, String text) async =>
      calls.add('jump $startMs $text');

  @override
  Future<void> selectAudioTrack(String id) async => calls.add('audio $id');

  @override
  Future<void> selectSubtitle(String source) async {
    calls.add('subtitle $source');
    subtitleSource = source;
  }

  @override
  Future<void> subtitleOff() async {
    calls.add('subtitleOff');
    subtitleSource = 'off:';
  }

  @override
  Future<void> mineLine() async => calls.add('mine');

  @override
  Future<void> replayLineThenPause() async => calls.add('replayThenPause');

  @override
  Future<void> setAutoPause(bool on) async {
    calls.add('autoPause $on');
    autoPause = on;
  }

  @override
  Future<void> loopLine(int times) async {
    calls.add('loop $times');
    loopOn = times >= 0;
    loopTimes = times > 0 ? times : null;
    loopRemaining = loopTimes;
  }

  @override
  Future<void> abLoop(VideoCompanionAbStep step) async {
    calls.add('ab ${step.name}');
    switch (step) {
      case VideoCompanionAbStep.setA:
        abA = 1000;
        abB = null;
      case VideoCompanionAbStep.setB:
        abB = 4000;
      case VideoCompanionAbStep.clear:
        abA = null;
        abB = null;
      case VideoCompanionAbStep.toggle:
        break;
    }
  }

  @override
  void countLookup() => lookupsCounted++;
}

class _FakeBridge implements CompanionBridge {
  _FakeBridge({required this.accept});

  final bool accept;
  final List<(String, int, String?)> lookups = <(String, int, String?)>[];

  @override
  Future<bool> sendLookup({
    required String text,
    int charIndex = -1,
    String? sentence,
  }) async {
    lookups.add((text, charIndex, sentence));
    return accept;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late CompanionContextRegistry registry;
  late CompanionVideoPlaybackRegistry nowPlaying;
  late _FakePage page;
  late VideoCompanionHook hook;

  setUp(() {
    registry = CompanionContextRegistry();
    nowPlaying = CompanionVideoPlaybackRegistry();
    page = _FakePage();
    hook = VideoCompanionHook(page, registry: registry, nowPlaying: nowPlaying);
  });

  tearDown(() {
    hook.dispose();
    registry.dispose();
    nowPlaying.dispose();
  });

  group('snapshot', () {
    test('companion not up: claims, but no timer and nothing is built', () {
      fakeAsync((FakeAsync async) {
        hook.attach(null);
        async.elapse(const Duration(seconds: 5));
        expect(registry.current.kind, CompanionContextKind.video);
        expect(registry.current.title, 'Episode 3');
        expect(page.frames, 0);
        expect(page.infoLoads, 0);
        expect(page.subtitleLoads, 0);
        expect(registry.currentSnapshot, isNull);
        expect(async.periodicTimerCount, 0);
      });
    });

    test('companion up: publishes state, cached info and tracks', () {
      fakeAsync((FakeAsync async) {
        registry.setActive(true);
        hook.attach(null);
        async.flushMicrotasks();
        final Map<String, Object?> s = registry.currentSnapshot!;
        expect(s.str(VideoCompanionKeys.title), 'Episode 3');
        expect(s.str(VideoCompanionKeys.series), 'Playlist');
        expect(s.integer(VideoCompanionKeys.episodeIndex), 2);
        expect(s.flag(VideoCompanionKeys.playing), isTrue);
        expect(s.integer(VideoCompanionKeys.positionMs), 5200);
        expect(s.integer(VideoCompanionKeys.durationMs), 60000);
        expect(s.doubleOrNull(VideoCompanionKeys.speed), 1.25);
        expect(s.str(VideoCompanionKeys.cue), 'line 5');
        expect(s.integer(VideoCompanionKeys.cueStart), 5000);
        expect(s.maps(VideoCompanionKeys.cues), hasLength(10));
        expect(s.maps(VideoCompanionKeys.audioTracks).first, <String, Object?>{
          VideoCompanionKeys.id: '1',
          VideoCompanionKeys.label: 'Japanese',
          VideoCompanionKeys.selected: true,
        });
        expect(
          s
              .maps(VideoCompanionKeys.subtitleTracks)
              .map((Map<String, Object?> e) => e[VideoCompanionKeys.source]),
          <String>['embedded:0', '/subs/en.srt'],
        );
        expect(s.flag(VideoCompanionKeys.subtitlesOff), isFalse);
        expect(s.mapOrNull(VideoCompanionKeys.info), <String, Object?>{
          VideoCompanionKeys.workTitle: 'Series',
          VideoCompanionKeys.rating: 8.4,
          VideoCompanionKeys.votes: 120,
          VideoCompanionKeys.episodeNumber: 3,
        });
        // Positions follow at most once per period.
        page.positionMs = 6100;
        async.elapse(const Duration(milliseconds: 500));
        expect(
          registry.currentSnapshot!.integer(VideoCompanionKeys.positionMs),
          5200,
        );
        async.elapse(const Duration(milliseconds: 600));
        expect(
          registry.currentSnapshot!.integer(VideoCompanionKeys.positionMs),
          6100,
        );
        // Metadata and track list are loaded once per video, not per tick.
        async.elapse(const Duration(seconds: 5));
        expect(page.infoLoads, 1);
        expect(page.subtitleLoads, 1);
        // Another video (disc title / web episode) reloads them.
        page.bookUid = 'ep4';
        async.elapse(const Duration(seconds: 1));
        expect(page.infoLoads, 2);
        expect(page.subtitleLoads, 2);
        // Going inactive stops the timer.
        registry.setActive(false);
        final int frames = page.frames;
        async.elapse(const Duration(seconds: 5));
        expect(page.frames, frames);
        expect(async.periodicTimerCount, 0);
      });
    });

    test('player not ready: nothing published yet', () {
      fakeAsync((FakeAsync async) {
        page.ready = false;
        registry.setActive(true);
        hook.attach(null);
        async.elapse(const Duration(seconds: 2));
        expect(registry.currentSnapshot, isNull);
        page.ready = true;
        async.elapse(const Duration(seconds: 1));
        expect(registry.currentSnapshot, isNotNull);
      });
    });

    test('a title known later updates the claim', () {
      fakeAsync((FakeAsync async) {
        page.currentTitle = null;
        registry.setActive(true);
        hook.attach(null);
        expect(registry.current.title, isNull);
        page.currentTitle = 'Loaded title';
        async.elapse(const Duration(seconds: 1));
        expect(registry.current.title, 'Loaded title');
        expect(
          registry.currentSnapshot!.str(VideoCompanionKeys.title),
          'Loaded title',
        );
      });
    });

    test('no metadata cached: no info in the snapshot', () {
      fakeAsync((FakeAsync async) {
        page.info = null;
        registry.setActive(true);
        hook.attach(null);
        async.flushMicrotasks();
        expect(
          registry.currentSnapshot!.containsKey(VideoCompanionKeys.info),
          isFalse,
        );
      });
    });

    test('subtitles off reads as off', () {
      fakeAsync((FakeAsync async) {
        page.subtitleSource = 'off:';
        registry.setActive(true);
        hook.attach(null);
        async.flushMicrotasks();
        expect(
          registry.currentSnapshot!.flag(VideoCompanionKeys.subtitlesOff),
          isTrue,
        );
      });
    });
  });

  group('buildVideoCompanionSnapshot', () {
    VideoCompanionFrame frameWith(List<AudioCue> cues, int current, int pos) =>
        VideoCompanionFrame(
          bookUid: 'b',
          title: 't',
          playing: false,
          positionMs: pos,
          durationMs: 0,
          speed: 1,
          cues: cues,
          currentCueIndex: current,
          audioTracks: const <VideoCompanionTrack>[],
          subtitleSource: null,
        );

    test('the cue window is capped and keeps the current cue', () {
      final List<AudioCue> cues = <AudioCue>[
        for (int i = 0; i < 500; i++) _cue(i),
      ];
      final Map<String, Object?> s = buildVideoCompanionSnapshot(
        frameWith(cues, 250, 250000),
      );
      final List<Map<String, Object?>> window = s.maps(VideoCompanionKeys.cues);
      expect(window, hasLength(VideoCompanionKeys.maxCues));
      expect(
        window.map((Map<String, Object?> c) => c[VideoCompanionKeys.start]),
        contains(250000),
      );
      // Near the end the window still holds maxCues lines.
      final Map<String, Object?> end = buildVideoCompanionSnapshot(
        frameWith(cues, 499, 499000),
      );
      expect(end.maps(VideoCompanionKeys.cues), hasLength(80));
      expect(
        end.maps(VideoCompanionKeys.cues).last[VideoCompanionKeys.start],
        499000,
      );
    });

    test('between cues: window around the playhead, no current cue', () {
      final List<AudioCue> cues = <AudioCue>[
        for (int i = 0; i < 300; i++) _cue(i),
      ];
      final Map<String, Object?> s = buildVideoCompanionSnapshot(
        frameWith(cues, -1, 200500),
      );
      expect(s.integer(VideoCompanionKeys.cueStart), -1);
      expect(s.containsKey(VideoCompanionKeys.cue), isFalse);
      expect(
        s
            .maps(VideoCompanionKeys.cues)
            .map((Map<String, Object?> c) => c[VideoCompanionKeys.start]),
        contains(200000),
      );
      expect(s.flag(VideoCompanionKeys.subtitlesOff), isTrue);
    });

    test('no cues: empty list', () {
      final Map<String, Object?> s = buildVideoCompanionSnapshot(
        frameWith(const <AudioCue>[], -1, 0),
      );
      expect(s.maps(VideoCompanionKeys.cues), isEmpty);
    });
  });

  group('commands', () {
    test('each panel control runs the page action', () async {
      registry.setActive(true);
      hook.attach(null);
      final List<(String, Map<String, Object?>)> sent =
          <(String, Map<String, Object?>)>[
            (VideoCompanionActions.playPause, const <String, Object?>{}),
            (VideoCompanionActions.previousCue, const <String, Object?>{}),
            (VideoCompanionActions.nextCue, const <String, Object?>{}),
            (
              VideoCompanionActions.seekTo,
              const <String, Object?>{VideoCompanionKeys.ms: 30000},
            ),
            (
              VideoCompanionActions.seekBy,
              const <String, Object?>{VideoCompanionKeys.ms: -10000},
            ),
            (
              VideoCompanionActions.jumpToCue,
              const <String, Object?>{
                VideoCompanionKeys.start: 3000,
                VideoCompanionKeys.text: 'line 3',
              },
            ),
            (
              VideoCompanionActions.selectAudio,
              const <String, Object?>{VideoCompanionKeys.id: '2'},
            ),
            (
              VideoCompanionActions.selectSubtitle,
              const <String, Object?>{
                VideoCompanionKeys.source: '/subs/en.srt',
              },
            ),
            (VideoCompanionActions.subtitleOff, const <String, Object?>{}),
            (VideoCompanionActions.mineLine, const <String, Object?>{}),
          ];
      for (final (String action, Map<String, Object?> args) in sent) {
        expect(
          registry.dispatchCommand(CompanionContextKind.video, action, args),
          isTrue,
        );
        await pumpEventQueue();
      }
      expect(page.calls, <String>[
        'toggle',
        'previousCue',
        'nextCue',
        'seekTo 30000',
        'seekBy -10000',
        'jump 3000 line 3',
        'audio 2',
        'subtitle /subs/en.srt',
        'subtitleOff',
        'mine',
      ]);
      // A command publishes right away (no waiting for the next tick).
      expect(
        registry.currentSnapshot!.flag(VideoCompanionKeys.playing),
        isFalse,
      );
      expect(
        registry.currentSnapshot!.flag(VideoCompanionKeys.subtitlesOff),
        isTrue,
      );
    });

    test(
      'line-study commands run the page action and publish the state',
      () async {
        registry.setActive(true);
        hook.attach(null);
        Map<String, Object?> snap() => registry.currentSnapshot!;
        await pumpEventQueue();
        expect(snap().flag(VideoCompanionKeys.autoPause), isFalse);
        expect(snap().mapOrNull(VideoCompanionKeys.loop), <String, Object?>{
          VideoCompanionKeys.on: false,
        });
        expect(snap().containsKey(VideoCompanionKeys.abA), isFalse);

        final List<(String, Map<String, Object?>)> sent =
            <(String, Map<String, Object?>)>[
              (
                VideoCompanionActions.replayLineThenPause,
                const <String, Object?>{},
              ),
              (
                VideoCompanionActions.setAutoPause,
                const <String, Object?>{VideoCompanionKeys.on: true},
              ),
              (
                VideoCompanionActions.loopLine,
                const <String, Object?>{VideoCompanionKeys.times: 3},
              ),
              (
                VideoCompanionActions.abLoop,
                const <String, Object?>{
                  VideoCompanionKeys.step: VideoCompanionAbSteps.a,
                },
              ),
              (
                VideoCompanionActions.abLoop,
                const <String, Object?>{
                  VideoCompanionKeys.step: VideoCompanionAbSteps.b,
                },
              ),
            ];
        for (final (String action, Map<String, Object?> args) in sent) {
          expect(
            registry.dispatchCommand(CompanionContextKind.video, action, args),
            isTrue,
          );
          await pumpEventQueue();
        }
        expect(page.calls, <String>[
          'replayThenPause',
          'autoPause true',
          'loop 3',
          'ab setA',
          'ab setB',
        ]);
        expect(snap().flag(VideoCompanionKeys.autoPause), isTrue);
        expect(snap().mapOrNull(VideoCompanionKeys.loop), <String, Object?>{
          VideoCompanionKeys.on: true,
          VideoCompanionKeys.times: 3,
          VideoCompanionKeys.remaining: 3,
        });
        expect(snap().intOrNull(VideoCompanionKeys.abA), 1000);
        expect(snap().intOrNull(VideoCompanionKeys.abB), 4000);

        await hook.handleCommand(
          VideoCompanionActions.loopLine,
          const <String, Object?>{VideoCompanionKeys.times: 0},
        );
        expect(snap().mapOrNull(VideoCompanionKeys.loop), <String, Object?>{
          VideoCompanionKeys.on: true,
        });
        await hook.handleCommand(
          VideoCompanionActions.loopLine,
          const <String, Object?>{VideoCompanionKeys.times: -1},
        );
        await hook.handleCommand(
          VideoCompanionActions.abLoop,
          const <String, Object?>{
            VideoCompanionKeys.step: VideoCompanionAbSteps.clear,
          },
        );
        expect(snap().mapOrNull(VideoCompanionKeys.loop), <String, Object?>{
          VideoCompanionKeys.on: false,
        });
        expect(snap().containsKey(VideoCompanionKeys.abA), isFalse);
        expect(snap().containsKey(VideoCompanionKeys.abB), isFalse);
      },
    );

    test('malformed line-study args are ignored', () async {
      registry.setActive(true);
      hook.attach(null);
      await hook.handleCommand(
        VideoCompanionActions.setAutoPause,
        const <String, Object?>{VideoCompanionKeys.on: 'yes'},
      );
      await hook.handleCommand(
        VideoCompanionActions.loopLine,
        const <String, Object?>{},
      );
      await hook.handleCommand(
        VideoCompanionActions.abLoop,
        const <String, Object?>{VideoCompanionKeys.step: 'c'},
      );
      expect(page.calls, isEmpty);
    });

    test('a companion lookup counts on the page that owns the claim', () {
      hook.attach(null);
      expect(registry.countLookup(), isTrue);
      expect(page.lookupsCounted, 1);
      hook.dispose();
      expect(registry.countLookup(), isFalse);
      expect(page.lookupsCounted, 1);
    });

    test('malformed args are ignored', () async {
      registry.setActive(true);
      hook.attach(null);
      await hook.handleCommand(
        VideoCompanionActions.seekTo,
        const <String, Object?>{},
      );
      await hook.handleCommand(
        VideoCompanionActions.selectAudio,
        const <String, Object?>{VideoCompanionKeys.id: 3},
      );
      await hook.handleCommand(
        VideoCompanionActions.seekBy,
        const <String, Object?>{VideoCompanionKeys.ms: 0},
      );
      await hook.handleCommand('unknown', const <String, Object?>{});
      expect(page.calls, isEmpty);
    });

    test('commands for another context are not delivered', () {
      hook.attach(null);
      expect(
        registry.dispatchCommand(
          CompanionContextKind.reader,
          VideoCompanionActions.playPause,
          const <String, Object?>{},
        ),
        isFalse,
      );
      expect(page.calls, isEmpty);
    });

    test('dispose releases the claim', () {
      hook.attach(null);
      hook.dispose();
      expect(registry.current.kind, isNot(CompanionContextKind.video));
    });
  });

  group('now playing', () {
    test('the open page is registered, toggles and unregisters', () async {
      expect(nowPlaying.current, isNull);
      hook.attach(null);
      final CompanionVideoPlayback video = nowPlaying.current!;
      expect(video.title(), 'Episode 3');
      expect(video.playing(), isTrue);
      await video.toggle();
      expect(page.calls, <String>['toggle']);
      expect(video.playing(), isFalse);
      hook.dispose();
      expect(nowPlaying.current, isNull);
    });

    test('a playing state change from the tick notifies the bar', () {
      fakeAsync((FakeAsync async) {
        int notified = 0;
        nowPlaying.addListener(() => notified++);
        registry.setActive(true);
        hook.attach(null);
        async.flushMicrotasks();
        final int afterStart = notified;
        async.elapse(const Duration(seconds: 3));
        expect(notified, afterStart);
        page.isPlaying = false;
        async.elapse(const Duration(seconds: 1));
        expect(notified, afterStart + 1);
      });
    });
  });

  group('lookup routing', () {
    tearDown(() {
      companionContexts.setActive(false);
      companionContexts.bindLookupSink(null);
    });

    const String sentence = '😀今日はいい天気';

    test('tapped grapheme becomes a UTF-16 index', () {
      expect(videoCompanionCharIndex(sentence, 0), 0);
      // The emoji is one grapheme but two UTF-16 units.
      expect(videoCompanionCharIndex(sentence, 1), 2);
      expect(videoCompanionCharIndex(sentence, 3), 4);
      expect(sentence.substring(videoCompanionCharIndex(sentence, 3)), 'はいい天気');
    });

    testWidgets('companion up: the Lookup tab takes the subtitle lookup', (
      WidgetTester tester,
    ) async {
      final _FakeBridge bridge = _FakeBridge(accept: true);
      companionContexts.bindLookupSink(bridge.sendLookup);
      companionContexts.setActive(true);
      final int index = videoCompanionCharIndex(sentence, 3);
      expect(
        await routeCompanionLookup(
          text: sentence,
          charIndex: index,
          sentence: sentence,
        ),
        isTrue,
      );
      expect(bridge.lookups.single, (sentence, 4, sentence));
    });

    testWidgets('companion off or panel not ready: in-page popup', (
      WidgetTester tester,
    ) async {
      final _FakeBridge refusing = _FakeBridge(accept: false);
      companionContexts.bindLookupSink(refusing.sendLookup);
      expect(
        await routeCompanionLookup(text: sentence, sentence: sentence),
        isFalse,
      );
      expect(refusing.lookups, isEmpty);
      companionContexts.setActive(true);
      expect(
        await routeCompanionLookup(text: sentence, sentence: sentence),
        isFalse,
      );
      expect(refusing.lookups, hasLength(1));
    });
  });

  group('loadVideoCompanionInfo', () {
    late FushiDatabase db;

    setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    Future<void> video(String uid) => db.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: uid,
        title: uid,
        videoPath: '/videos/$uid.mkv',
      ),
    );

    test('nothing cached: null', () async {
      await video('movie');
      expect(await loadVideoCompanionInfo(db, bookUid: 'movie'), isNull);
    });

    test('a movie: its own work row', () async {
      await video('movie');
      await db.upsertVideoMetadataWork(
        VideoMetadataWorksCompanion.insert(
          bookUid: const Value<String?>('movie'),
          mediaType: 'movie',
          title: 'Movie title',
          overview: const Value<String?>('About the movie.'),
          rating: const Value<double?>(7.5),
          ratingCount: const Value<int?>(42),
          updatedAt: 1,
        ),
      );
      final VideoCompanionInfo info = (await loadVideoCompanionInfo(
        db,
        bookUid: 'movie',
      ))!;
      expect(info.toJson(), <String, Object?>{
        VideoCompanionKeys.workTitle: 'Movie title',
        VideoCompanionKeys.rating: 7.5,
        VideoCompanionKeys.votes: 42,
        VideoCompanionKeys.overview: 'About the movie.',
      });
    });

    test(
      'an episode opened without its playlist: work via its season',
      () async {
        await video('ep3');
        final int collectionId = await db.createMediaCollection(
          'Series',
          collectionType: 'playlist',
        );
        final int workId = await db.upsertVideoMetadataWork(
          VideoMetadataWorksCompanion.insert(
            collectionId: Value<int?>(collectionId),
            mediaType: 'tv',
            title: 'Series title',
            updatedAt: 1,
          ),
        );
        final int seasonId = await db.upsertVideoMetadataSeason(
          VideoMetadataSeasonsCompanion.insert(
            workId: workId,
            seasonNumber: 1,
            updatedAt: 1,
          ),
        );
        await db.upsertVideoMetadataEpisode(
          VideoMetadataEpisodesCompanion.insert(
            seasonId: seasonId,
            bookUid: const Value<String?>('ep3'),
            episodeNumber: 3,
            title: const Value<String?>('The walk'),
            overview: const Value<String?>('  '),
            updatedAt: 1,
          ),
        );
        final VideoCompanionInfo info = (await loadVideoCompanionInfo(
          db,
          bookUid: 'ep3',
        ))!;
        // Blank overview left out, nothing invented.
        expect(info.toJson(), <String, Object?>{
          VideoCompanionKeys.workTitle: 'Series title',
          VideoCompanionKeys.episodeNumber: 3,
          VideoCompanionKeys.episodeTitle: 'The walk',
        });
        // Same result through the playlist.
        expect(
          (await loadVideoCompanionInfo(
            db,
            bookUid: 'ep3',
            collectionId: collectionId,
          ))!.workTitle,
          'Series title',
        );
      },
    );

    test(
      'terms and credits of the work: year, studio, genres, cast, staff',
      () async {
        await video('movie');
        final int workId = await db.upsertVideoMetadataWork(
          VideoMetadataWorksCompanion.insert(
            bookUid: const Value<String?>('movie'),
            mediaType: 'movie',
            title: 'Movie title',
            year: const Value<int?>(2001),
            updatedAt: 1,
          ),
        );
        await db.replaceVideoMetadataTermsForWork(
          workId: workId,
          terms: <VideoMetadataTermsCompanion>[
            VideoMetadataTermsCompanion.insert(
              termKey: 'studio:ghibli',
              kind: 'studio',
              name: 'Studio Ghibli',
              normalizedName: 'ghibli',
            ),
            VideoMetadataTermsCompanion.insert(
              termKey: 'genre:fantasy',
              kind: 'genre',
              name: 'Fantasy',
              normalizedName: 'fantasy',
            ),
            VideoMetadataTermsCompanion.insert(
              termKey: 'keyword:spirits',
              kind: 'keyword',
              name: 'spirits',
              normalizedName: 'spirits',
            ),
          ],
          mappings: <VideoMetadataWorkTermsCompanion>[
            for (final String key in <String>[
              'studio:ghibli',
              'genre:fantasy',
              'keyword:spirits',
            ])
              VideoMetadataWorkTermsCompanion.insert(
                workId: workId,
                termKey: key,
              ),
          ],
        );
        await db.upsertVideoMetadataPeople(<VideoMetadataPeopleCompanion>[
          for (final (String key, String name) p in <(String, String)>[
            ('p1', 'Rumi Hiiragi'),
            ('p2', 'Hayao Miyazaki'),
            ('p3', 'Miyu Irino'),
          ])
            VideoMetadataPeopleCompanion.insert(
              personKey: p.$1,
              name: p.$2,
              updatedAt: 1,
            ),
        ]);
        await db
            .upsertVideoMetadataCharacters(<VideoMetadataCharactersCompanion>[
              VideoMetadataCharactersCompanion.insert(
                characterKey: 'c1',
                name: 'Chihiro',
                updatedAt: 1,
              ),
            ]);
        await db.replaceVideoMetadataCredits(
          workId: workId,
          credits: <VideoMetadataCreditsCompanion>[
            VideoMetadataCreditsCompanion.insert(
              personKey: 'p1',
              creditKind: 'voice_actor',
              characterKey: const Value<String?>('c1'),
              sortOrder: const Value<int>(0),
            ),
            VideoMetadataCreditsCompanion.insert(
              personKey: 'p3',
              creditKind: 'voice_actor',
              roleName: const Value<String>('Haku'),
              sortOrder: const Value<int>(1),
            ),
            VideoMetadataCreditsCompanion.insert(
              personKey: 'p2',
              creditKind: 'director',
              sortOrder: const Value<int>(2),
            ),
            VideoMetadataCreditsCompanion.insert(
              personKey: 'p2',
              creditKind: 'writer',
              job: const Value<String?>('Screenplay'),
              sortOrder: const Value<int>(3),
            ),
          ],
        );
        final VideoCompanionInfo info = (await loadVideoCompanionInfo(
          db,
          bookUid: 'movie',
        ))!;
        expect(info.toJson(), <String, Object?>{
          VideoCompanionKeys.workTitle: 'Movie title',
          VideoCompanionKeys.year: 2001,
          VideoCompanionKeys.studios: <String>['Studio Ghibli'],
          VideoCompanionKeys.genres: <String>['Fantasy'],
          VideoCompanionKeys.cast: <Map<String, Object?>>[
            <String, Object?>{
              VideoCompanionKeys.personName: 'Rumi Hiiragi',
              VideoCompanionKeys.personRole: 'Chihiro',
            },
            <String, Object?>{
              VideoCompanionKeys.personName: 'Miyu Irino',
              VideoCompanionKeys.personRole: 'Haku',
            },
          ],
          VideoCompanionKeys.staff: <Map<String, Object?>>[
            <String, Object?>{
              VideoCompanionKeys.personName: 'Hayao Miyazaki',
              VideoCompanionKeys.staffKind: 'director',
            },
            <String, Object?>{
              VideoCompanionKeys.personName: 'Hayao Miyazaki',
              VideoCompanionKeys.staffKind: 'writer',
              VideoCompanionKeys.staffJob: 'Screenplay',
            },
          ],
        });
      },
    );

    test('lists are capped and blanks dropped', () {
      final VideoCompanionInfo info = VideoCompanionInfo(
        year: 0,
        genres: <String>[' ', for (int i = 0; i < 9; i++) 'g$i'],
        cast: <VideoCompanionCredit>[
          for (int i = 0; i < 15; i++) VideoCompanionCredit(name: 'a$i'),
        ],
        staff: <VideoCompanionCredit>[
          const VideoCompanionCredit(name: '  '),
          for (int i = 0; i < 9; i++)
            VideoCompanionCredit(name: 's$i', kind: 'director'),
        ],
      );
      final Map<String, Object?> json = info.toJson();
      expect(json.containsKey(VideoCompanionKeys.year), isFalse);
      expect(json.strings(VideoCompanionKeys.genres), hasLength(6));
      expect(json.strings(VideoCompanionKeys.genres).first, 'g0');
      expect(json.maps(VideoCompanionKeys.cast), hasLength(10));
      expect(json.maps(VideoCompanionKeys.staff), hasLength(6));
      expect(json.maps(VideoCompanionKeys.staff).first, <String, Object?>{
        VideoCompanionKeys.personName: 's0',
        VideoCompanionKeys.staffKind: 'director',
      });
    });
  });
}
