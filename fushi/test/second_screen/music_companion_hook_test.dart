import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/lyrics/karaoke/karaoke_lyrics_view.dart'
    show KaraokeLookupHit;
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/pages/implementations/music/music_lyrics_companion.dart';
import 'package:fushi/src/second_screen/companion/companion_bridge.dart';
import 'package:fushi/src/second_screen/companion/companion_context.dart';
import 'package:fushi/src/second_screen/companion/companion_page_link.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/companion/companion_snapshot.dart';
import 'package:fushi/src/second_screen/companion/modules/music_companion_schema.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:material_ui/material_ui.dart';

LyricLine _line(
  int start,
  int end,
  String text, {
  LyricRole role = LyricRole.main,
  String? zh,
}) => LyricLine(
  startMs: start,
  endMs: end,
  role: role,
  syllables: <LyricSyllable>[
    LyricSyllable(text: text, startMs: start, endMs: end),
  ],
  translations: zh == null
      ? const <LyricTranslation>[]
      : <LyricTranslation>[LyricTranslation('zh', zh)],
);

/// Four main lines (1 s, 4 s, 8 s, 12 s) with a background line in between.
LyricTimeline _timeline({
  int offsetMs = 0,
  LyricTimingQuality quality = LyricTimingQuality.line,
}) => LyricTimeline(
  format: 'lrc',
  timingQuality: quality,
  offsetMs: offsetMs,
  lines: <LyricLine>[
    _line(1000, 3000, '夜に駆ける', zh: '在夜里奔跑'),
    _line(4000, 6000, '沈むように'),
    _line(4500, 5500, 'ah', role: LyricRole.background),
    _line(8000, 10000, '溶けてゆくように'),
    _line(12000, 14000, '二人だけの空'),
  ],
);

const MusicPlayItem _item = MusicPlayItem(
  trackUid: 'track-1',
  path: '/music/yoru.flac',
  title: '夜に駆ける',
  artist: 'YOASOBI',
  album: 'THE BOOK',
  durationMs: 261000,
  coverPath: '/covers/yoru.jpg',
);

Map<String, Object?>? _snapshot({
  MusicPlayItem? item = _item,
  int positionMs = 4500,
  LyricTimeline? timeline,
  bool userSource = false,
}) => buildMusicCompanionSnapshot(
  item: item,
  playing: true,
  positionMs: positionMs,
  durationMs: 261000,
  canPrevious: true,
  canSeek: true,
  timeline: timeline,
  lyricsLoading: false,
  userSource: userSource,
);

class _FakeBridge implements CompanionBridge {
  final List<(String, int, String?)> lookups = <(String, int, String?)>[];
  bool accept = true;

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

class _Target {
  final List<String> calls = <String>[];
  LyricTimeline? timeline = _timeline(offsetMs: 300);

  MusicCompanionTarget get target => MusicCompanionTarget(
    togglePlayPause: () async => calls.add('toggle'),
    skipPrevious: () async => calls.add('previous'),
    skipNext: () async => calls.add('next'),
    seek: (Duration d) async => calls.add('seek:${d.inMilliseconds}'),
    timeline: () => timeline,
    trackDurationMs: () => 261000,
    nudgeOffset: (int direction) => calls.add('nudge:$direction'),
    chooseSource: () async => calls.add('choose'),
    resetSource: () async => calls.add('reset'),
  );
}

void main() {
  group('snapshot', () {
    test('track, transport and the lyric window around the current line', () {
      final Map<String, Object?> s = _snapshot(timeline: _timeline())!;
      expect(s.str(MusicCompanionKeys.title), '夜に駆ける');
      expect(s.strOrNull(MusicCompanionKeys.artist), 'YOASOBI');
      expect(s.strOrNull(MusicCompanionKeys.album), 'THE BOOK');
      expect(s.strOrNull(MusicCompanionKeys.cover), '/covers/yoru.jpg');
      expect(s.flag(MusicCompanionKeys.playing), isTrue);
      expect(s.integer(MusicCompanionKeys.positionMs), 4500);
      expect(s.integer(MusicCompanionKeys.durationMs), 261000);
      expect(s.flag(MusicCompanionKeys.hasLyrics), isTrue);
      expect(s.flag(MusicCompanionKeys.synced), isTrue);
      expect(s.integer(MusicCompanionKeys.lyricIndex), 1);
      final List<Map<String, Object?>> lines = s.maps(
        MusicCompanionKeys.lyrics,
      );
      // The background line (index 2) is not sent.
      expect(
        lines.map((Map<String, Object?> l) => l.integer('index')).toList(),
        <int>[0, 1, 3, 4],
      );
      expect(lines.first.strOrNull(MusicCompanionKeys.translation), '在夜里奔跑');
      expect(lines[1].strOrNull(MusicCompanionKeys.translation), isNull);
    });

    test('the window is capped around the current line', () {
      final LyricTimeline long = LyricTimeline(
        format: 'lrc',
        timingQuality: LyricTimingQuality.line,
        lines: <LyricLine>[
          for (int i = 0; i < 200; i++)
            _line(i * 1000, i * 1000 + 900, 'line $i'),
        ],
      );
      final Map<String, Object?> s = _snapshot(
        timeline: long,
        positionMs: 100500,
      )!;
      final List<Map<String, Object?>> lines = s.maps(
        MusicCompanionKeys.lyrics,
      );
      expect(lines, hasLength(kMusicCompanionLyricWindow));
      expect(s.integer(MusicCompanionKeys.lyricIndex), 100);
      expect(lines.first.integer('index'), 100 - kMusicCompanionLyricLead);
    });

    test('no lyrics: no lyric section, no offset', () {
      final Map<String, Object?> s = _snapshot()!;
      expect(s.flag(MusicCompanionKeys.hasLyrics), isFalse);
      expect(s.flag(MusicCompanionKeys.synced), isFalse);
      expect(s.containsKey(MusicCompanionKeys.lyrics), isFalse);
      expect(s.integer(MusicCompanionKeys.lyricIndex), -1);
    });

    test('unsynced lyrics have no current line', () {
      final Map<String, Object?> s = _snapshot(
        timeline: _timeline(quality: LyricTimingQuality.unsynced),
      )!;
      expect(s.flag(MusicCompanionKeys.synced), isFalse);
      expect(s.integer(MusicCompanionKeys.lyricIndex), -1);
      expect(s.maps(MusicCompanionKeys.lyrics), hasLength(4));
    });

    test('nothing loaded: null; remote covers and unknowns are left out', () {
      expect(_snapshot(item: null), isNull);
      final Map<String, Object?> s = _snapshot(
        item: const MusicPlayItem(
          trackUid: 'p',
          path: 'plugin://x',
          title: 'Remote',
          coverPath: 'https://example.com/c.jpg',
        ),
      )!;
      expect(s.containsKey(MusicCompanionKeys.cover), isFalse);
      expect(s.containsKey(MusicCompanionKeys.artist), isFalse);
      expect(s.containsKey(MusicCompanionKeys.album), isFalse);
    });
  });

  group('commands', () {
    test('transport, seek and source actions reach the page', () async {
      final _Target t = _Target();
      Future<void> run(String a, [Map<String, Object?> args = const {}]) =>
          handleMusicCompanionCommand(a, args, t.target);
      await run(MusicCompanionActions.playPause);
      await run(MusicCompanionActions.previous);
      await run(MusicCompanionActions.next);
      await run(MusicCompanionActions.seek, <String, Object?>{
        MusicCompanionKeys.ms: 61000,
      });
      await run(MusicCompanionActions.chooseSource);
      await run(MusicCompanionActions.resetSource);
      expect(t.calls, <String>[
        'toggle',
        'previous',
        'next',
        'seek:61000',
        'choose',
        'reset',
      ]);
    });

    test('seek to a lyric line uses the live offset', () async {
      final _Target t = _Target();
      await handleMusicCompanionCommand(
        MusicCompanionActions.seekLine,
        <String, Object?>{MusicCompanionKeys.index: 1},
        t.target,
      );
      // Line 1 starts at 4000 ms lyric time; offset 300 = lyrics earlier.
      expect(t.calls, <String>['seek:3700']);
    });

    test(
      'offset nudges one step; bad args and unsynced lyrics ignored',
      () async {
        final _Target t = _Target();
        Future<void> nudge(Object? d) => handleMusicCompanionCommand(
          MusicCompanionActions.nudgeOffset,
          <String, Object?>{MusicCompanionKeys.direction: d},
          t.target,
        );
        await nudge(1);
        await nudge(-1);
        await nudge(5);
        await nudge('1');
        t.timeline = _timeline(quality: LyricTimingQuality.unsynced);
        await nudge(1);
        await handleMusicCompanionCommand(
          MusicCompanionActions.seekLine,
          <String, Object?>{MusicCompanionKeys.index: 1},
          t.target,
        );
        await handleMusicCompanionCommand('editLyrics', const {}, t.target);
        expect(t.calls, <String>['nudge:1', 'nudge:-1']);
      },
    );
  });

  group('page link', () {
    test('inactive companion: the builder never runs (no timer)', () {
      fakeAsync((FakeAsync async) {
        final CompanionContextRegistry registry = CompanionContextRegistry();
        final CompanionPageLink link = CompanionPageLink(registry: registry);
        int builds = 0;
        link.claim(
          const CompanionContext(CompanionContextKind.music, title: 'x'),
        );
        link.startSnapshots(() {
          builds++;
          return _snapshot(timeline: _timeline());
        });
        async.elapse(const Duration(seconds: 5));
        expect(builds, 0);
        expect(registry.currentSnapshot, isNull);
        link.dispose();
      });
    });

    test('active: published (throttled) and handed to the registry', () {
      fakeAsync((FakeAsync async) {
        final CompanionContextRegistry registry = CompanionContextRegistry();
        registry.setActive(true);
        final CompanionPageLink link = CompanionPageLink(registry: registry);
        int position = 1000;
        int builds = 0;
        final List<String> commands = <String>[];
        link.claim(
          const CompanionContext(CompanionContextKind.music, title: 'x'),
          onCommand: (String a, Map<String, Object?> _) => commands.add(a),
        );
        link.startSnapshots(() {
          builds++;
          return _snapshot(positionMs: position, timeline: _timeline());
        });
        expect(builds, 1);
        expect(
          registry.currentSnapshot?.integer(MusicCompanionKeys.positionMs),
          1000,
        );
        position = 9000;
        async.elapse(const Duration(milliseconds: 500));
        expect(builds, 1);
        async.elapse(const Duration(milliseconds: 600));
        expect(builds, 2);
        expect(
          registry.currentSnapshot?.integer(MusicCompanionKeys.lyricIndex),
          3,
        );
        expect(
          registry.dispatchCommand(
            CompanionContextKind.music,
            MusicCompanionActions.playPause,
            const <String, Object?>{},
          ),
          isTrue,
        );
        expect(commands, <String>[MusicCompanionActions.playPause]);
        link.dispose();
        registry.dispose();
      });
    });
  });

  group('lyric lookup routing', () {
    late _FakeBridge bridge;

    setUp(() => bridge = _FakeBridge());
    tearDown(() {
      companionContexts.setActive(false);
      companionContexts.bindLookupSink(null);
    });

    Future<bool> route(WidgetTester tester, KaraokeLookupHit hit) {
      companionContexts.bindLookupSink(bridge.sendLookup);
      return routeMusicLyricLookup(hit);
    }

    const KaraokeLookupHit hit = KaraokeLookupHit(
      lineIndex: 1,
      syllableIndex: 0,
      charIndexInLine: 2,
      lineText: '沈むように',
      globalRect: Rect.zero,
    );

    testWidgets('companion not in use: falls back, nothing sent', (
      WidgetTester tester,
    ) async {
      expect(await route(tester, hit), isFalse);
      expect(bridge.lookups, isEmpty);
    });

    testWidgets('companion in use: the line goes to the Lookup tab', (
      WidgetTester tester,
    ) async {
      companionContexts.setActive(true);
      expect(await route(tester, hit), isTrue);
      expect(bridge.lookups, <(String, int, String?)>[('沈むように', 2, '沈むように')]);
    });

    testWidgets('panel did not take it: falls back', (
      WidgetTester tester,
    ) async {
      companionContexts.setActive(true);
      bridge.accept = false;
      expect(await route(tester, hit), isFalse);
      expect(bridge.lookups, hasLength(1));
    });
  });
}
