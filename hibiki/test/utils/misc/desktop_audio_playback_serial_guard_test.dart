import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/desktop_audio_playback.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  // BUG-342: DesktopAudioPlayback uses one shared, never-disposed just_audio
  // AudioPlayer (one fixed player id for the whole process). just_audio toggles
  // the native media_kit platform on/off under that id, and the activating call
  // registers the id with media_kit via init(id) BEFORE it checks whether a
  // newer activation interrupted it. If two playback cycles
  // (stop→setVolume→load→play) overlap — e.g. rapid auto-read / manual re-taps
  // of successive lookups — one activation registers the id during its in-flight
  // window while another supersedes it; the superseded one then throws `abort`
  // *after* registering, leaking a native player whose id is never disposed.
  // Every later activation calls init() with the same id and just_audio_media_kit
  // throws `Player <id> already exists!`, silencing all preview/auto-read audio
  // until the app restarts. The fix serializes EVERY activation-changing
  // operation — including play(), which is the second activation trigger
  // (_setPlatformActive(true) in just_audio's play() else-branch) — so the
  // stop→load→play cycles never interleave.
  group('AudioActivationQueue serialization', () {
    test('queued operations never interleave (strict one-at-a-time)', () async {
      final AudioActivationQueue queue = AudioActivationQueue();
      final List<String> events = <String>[];
      int active = 0;
      int maxConcurrent = 0;

      Future<void> op(String name, int gateMs) async {
        active++;
        maxConcurrent = active > maxConcurrent ? active : maxConcurrent;
        events.add('$name:start');
        // Yield across multiple microtask/event-loop turns to expose any
        // interleaving the way an `await player.ready()` gap would.
        await Future<void>.delayed(Duration(milliseconds: gateMs));
        events.add('$name:end');
        active--;
      }

      // Fire three cycles "simultaneously" without awaiting between them, the
      // way rapid auto-read does.
      final Future<void> a = queue.run<void>(() => op('A', 30));
      final Future<void> b = queue.run<void>(() => op('B', 5));
      final Future<void> c = queue.run<void>(() => op('C', 20));
      await Future.wait(<Future<void>>[a, b, c]);

      expect(maxConcurrent, 1,
          reason: 'activation-changing operations must run strictly serially');
      expect(
        events,
        <String>[
          'A:start', 'A:end', //
          'B:start', 'B:end', //
          'C:start', 'C:end', //
        ],
        reason: 'each operation must fully settle before the next one starts, '
            'in submission order',
      );
    });

    test('a failing operation does not stall the chain for later callers',
        () async {
      final AudioActivationQueue queue = AudioActivationQueue();
      final List<String> events = <String>[];

      final Future<void> failing = queue.run<void>(() async {
        events.add('first:start');
        throw StateError('boom');
      });
      final Future<int> next = queue.run<int>(() async {
        events.add('second:start');
        return 42;
      });

      await expectLater(failing, throwsStateError);
      // The second operation must still run and return its own value.
      expect(await next, 42);
      expect(events, <String>['first:start', 'second:start']);
    });

    test('the caller observes its own operation result/error', () async {
      final AudioActivationQueue queue = AudioActivationQueue();
      expect(await queue.run<String>(() async => 'ok'), 'ok');
      await expectLater(
        queue.run<void>(() async => throw ArgumentError('bad')),
        throwsArgumentError,
      );
    });
  });

  // The exact regression the second-round rework targets: a play() that stays
  // OUTSIDE the serial body (fire-and-forget) keeps running its activation
  // after its run body has settled, so the next body's stop/load starts while
  // the previous play()'s _setPlatformActive(true) is still in flight — the very
  // interleaving that re-leaks the player id. These tests model "the run body
  // returned but there is still un-awaited async work" and assert it CAN
  // interleave (proving the hazard is real), then assert that awaiting the
  // activation work INSIDE the body removes it.
  group('AudioActivationQueue play()-escape race', () {
    test('un-awaited activation work escapes the serial boundary (the bug)',
        () async {
      final AudioActivationQueue queue = AudioActivationQueue();
      bool activationInFlight = false;
      bool sawOverlap = false;

      // Cycle A: a body that fires activation work WITHOUT awaiting it (the
      // first-round mistake: unawaited(_player.play())).
      Future<void> badPlay() async {
        // stop/load portion (awaited, fine).
        await Future<void>.delayed(const Duration(milliseconds: 1));
        // Activation toggle escapes the body: it keeps running after the body
        // returns, mirroring unawaited(play()).
        activationInFlight = true;
        Future<void>(() async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          activationInFlight = false;
        });
        // Body returns while activation is still in flight.
      }

      // Cycle B: its stop/load runs and observes A's activation still in
      // flight — i.e. they interleave on the shared id.
      Future<void> nextCycleStopLoad() async {
        if (activationInFlight) sawOverlap = true;
      }

      await queue.run<void>(badPlay);
      await queue.run<void>(nextCycleStopLoad);
      // Let the escaped activation finish.
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(sawOverlap, isTrue,
          reason: 'un-awaited (escaped) activation overlaps the next cycle — '
              'this is the leak path the rework must close');
    });

    test('awaiting activation INSIDE the body keeps it within the boundary',
        () async {
      final AudioActivationQueue queue = AudioActivationQueue();
      bool activationInFlight = false;
      bool sawOverlap = false;

      // Cycle A: same activation work, but AWAITED inside the body (the fix:
      // await _player.play()).
      Future<void> goodPlay() async {
        await Future<void>.delayed(const Duration(milliseconds: 1));
        activationInFlight = true;
        // Awaited: the body does not settle until activation is stable. Models
        // play() returning once playCompleter resolves (native play accepted),
        // NOT when the clip ends.
        await Future<void>.delayed(const Duration(milliseconds: 20));
        activationInFlight = false;
      }

      Future<void> nextCycleStopLoad() async {
        if (activationInFlight) sawOverlap = true;
      }

      await queue.run<void>(goodPlay);
      await queue.run<void>(nextCycleStopLoad);

      expect(sawOverlap, isFalse,
          reason:
              'awaiting activation inside the run body keeps stop→load→play '
              'strictly serial — no interleaving on the shared player id');
    });
  });

  // stop() must be able to supersede an in-flight/queued playback cycle so a
  // future dismiss-stop does not fight an incoming activation (and so a queued
  // play does not start a fresh activation just to be torn down).
  group('AudioActivationQueue stop preemption', () {
    test('preempt() bumps the generation so a queued playback can detect it',
        () async {
      final AudioActivationQueue queue = AudioActivationQueue();
      final int before = queue.generation;
      bool bailedOut = false;

      // A playback body captures the generation at submission, yields, then
      // re-checks before its activation step.
      final int submitted = queue.generation;
      final Future<void> playback = queue.run<void>(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        if (queue.generation != submitted) {
          bailedOut = true; // superseded by a stop — do not activate.
        }
      });

      // A dismiss-stop arrives while the playback is still queued/yielding.
      queue.preempt();

      await playback;
      expect(queue.generation, greaterThan(before),
          reason: 'preempt() must advance the generation');
      expect(bailedOut, isTrue,
          reason: 'a playback superseded by a stop must detect it and bail '
              'before starting a new activation');
    });

    test('without a preempt, a playback body keeps its activation', () async {
      final AudioActivationQueue queue = AudioActivationQueue();
      bool bailedOut = false;
      final int submitted = queue.generation;
      await queue.run<void>(() async {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        if (queue.generation != submitted) bailedOut = true;
      });
      expect(bailedOut, isFalse,
          reason: 'no stop arrived, so the playback must proceed normally');
    });
  });

  group('DesktopAudioPlayback wiring guard', () {
    final String source =
        _read('lib/src/utils/misc/desktop_audio_playback.dart');
    // Collapse whitespace so dart format line-wrapping cannot break the guard.
    final String flat = source.replaceAll(RegExp(r'\s+'), ' ');

    test('playback and stop route through the activation queue', () {
      // The single shared AudioPlayer must funnel every activation-changing
      // operation through the serial queue, or overlapping cycles can leak the
      // player id again (BUG-342).
      expect(source, contains('AudioActivationQueue _activation'));
      expect(flat, contains('_activation.run<bool>('),
          reason: 'preview playback must be serialized');
      expect(flat, contains('_activation.run<void>('),
          reason: 'stop must share the same serial queue as playback');
    });

    test('play() is awaited INSIDE the serial body, not fire-and-forget', () {
      // Second-round fix: play() also toggles platform activation, so it must
      // be awaited within the run body. The first-round mistake —
      // unawaited(_player.play()) — let activation escape the boundary and is
      // explicitly forbidden here.
      expect(flat, contains('await _player.play()'),
          reason: 'play() must be awaited inside the serial run body so its '
              '_setPlatformActive(true) stays within the activation boundary');
      expect(flat, isNot(contains('unawaited(_player.play())')),
          reason: 'fire-and-forget play() re-opens the interleaving leak path');
    });

    test('stop() preempts so it can supersede an in-flight playback cycle', () {
      // Robust against dart format wrapping: just require both the preempt call
      // and a generation re-check guarding activation exist.
      expect(flat, contains('_activation.preempt()'),
          reason: 'stop must signal preemption so queued playback can bail');
      expect(
        RegExp(r'_activation\.generation\s*!=\s*submittedGeneration')
            .hasMatch(flat),
        isTrue,
        reason: 'a playback body must re-check the generation before starting '
            'a fresh activation, so a dismiss-stop can supersede it',
      );
    });
  });
}
