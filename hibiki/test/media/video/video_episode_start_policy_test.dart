import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_episode_start_policy.dart';

void main() {
  group('resolveEpisodeStart', () {
    test('clamps negative saved positions before applying intent', () {
      for (final EpisodeStartIntent intent in EpisodeStartIntent.values) {
        expect(
          resolveEpisodeStart(intent, -2500, 100000),
          0,
          reason: '$intent must never seek before the beginning',
        );
      }
    });

    test('manual previous and auto advance always start from the beginning',
        () {
      for (final int? durationMs in <int?>[null, 0, 100000]) {
        expect(
          resolveEpisodeStart(
            EpisodeStartIntent.manualPrevious,
            42000,
            durationMs,
          ),
          0,
        );
        expect(
          resolveEpisodeStart(
            EpisodeStartIntent.autoAdvance,
            42000,
            durationMs,
          ),
          0,
        );
      }
    });

    test('unknown duration preserves resumable intents except forced starts',
        () {
      for (final int? durationMs in <int?>[null, 0, -1]) {
        expect(
          resolveEpisodeStart(
            EpisodeStartIntent.initialOpen,
            42000,
            durationMs,
          ),
          42000,
        );
        expect(
          resolveEpisodeStart(
            EpisodeStartIntent.manualNext,
            42000,
            durationMs,
          ),
          42000,
        );
        expect(
          resolveEpisodeStart(
            EpisodeStartIntent.listSelect,
            42000,
            durationMs,
          ),
          42000,
        );
      }
    });

    test('known duration preserves non-near-end saved positions', () {
      for (final EpisodeStartIntent intent in <EpisodeStartIntent>[
        EpisodeStartIntent.initialOpen,
        EpisodeStartIntent.manualNext,
        EpisodeStartIntent.listSelect,
      ]) {
        expect(resolveEpisodeStart(intent, 50000, 100000), 50000);
      }
    });

    test('known duration resets at the ninety percent boundary', () {
      for (final EpisodeStartIntent intent in <EpisodeStartIntent>[
        EpisodeStartIntent.initialOpen,
        EpisodeStartIntent.manualNext,
        EpisodeStartIntent.listSelect,
      ]) {
        expect(resolveEpisodeStart(intent, 89999, 100000), 89999);
        expect(resolveEpisodeStart(intent, 90000, 100000), 0);
      }
    });

    test('known duration resets at the three second remaining boundary', () {
      for (final EpisodeStartIntent intent in <EpisodeStartIntent>[
        EpisodeStartIntent.initialOpen,
        EpisodeStartIntent.manualNext,
        EpisodeStartIntent.listSelect,
      ]) {
        expect(resolveEpisodeStart(intent, 16999, 20000), 16999);
        expect(resolveEpisodeStart(intent, 17000, 20000), 0);
      }
    });

    test('explicit cue starts keep the requested anchor', () {
      expect(
        resolveEpisodeStart(EpisodeStartIntent.explicitCue, 97000, 100000),
        97000,
      );
      expect(
        resolveEpisodeStart(EpisodeStartIntent.explicitCue, 42000, null),
        42000,
      );
    });
  });

  group('shouldAutoPlayNextOnCompletion (TODO-639)', () {
    test('all three gates satisfied -> auto-play next', () {
      expect(
        shouldAutoPlayNextOnCompletion(
          autoPlayNextEnabled: true,
          hasNextEpisode: true,
          alreadyAdvancing: false,
        ),
        isTrue,
      );
    });

    test('toggle off -> never auto-play next (the core opt-out)', () {
      expect(
        shouldAutoPlayNextOnCompletion(
          autoPlayNextEnabled: false,
          hasNextEpisode: true,
          alreadyAdvancing: false,
        ),
        isFalse,
        reason: '关掉自动连播开关后，一集播完必须停在本集、不进下一集',
      );
    });

    test('no next episode (last/single) -> do not advance', () {
      expect(
        shouldAutoPlayNextOnCompletion(
          autoPlayNextEnabled: true,
          hasNextEpisode: false,
          alreadyAdvancing: false,
        ),
        isFalse,
      );
    });

    test('already advancing -> reentrancy guard blocks a second advance', () {
      expect(
        shouldAutoPlayNextOnCompletion(
          autoPlayNextEnabled: true,
          hasNextEpisode: true,
          alreadyAdvancing: true,
        ),
        isFalse,
      );
    });

    test('countdown seconds constant is a small positive number', () {
      expect(kAutoPlayNextCountdownSeconds, greaterThan(0));
      expect(kAutoPlayNextCountdownSeconds, lessThanOrEqualTo(10));
    });
  });
}
