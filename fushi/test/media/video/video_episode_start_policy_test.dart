import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_episode_start_policy.dart';

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

  // BUG-2043：全屏换集的路由决策真值表。生产路径 `_switchEpisode`
  // （video_fushi/episode.part.dart）不再手写布尔表达式，直接消费本函数的输出，
  // 所以「条件被改成恒真/恒假、接管块整体变死代码」这类回归在这里就红——纯源码
  // 守卫（video_fullscreen_switch_flatten_guard_test.dart）只看字面、证明不了可达性。
  group('resolveEpisodeSwitchPlan', () {
    test('窗口模式（无全屏路由、未接管原生全屏）-> 顶替，不交接全屏', () {
      const EpisodeSwitchPlan plan = EpisodeSwitchPlan(
        mode: EpisodeSwitchMode.replace,
        handOverNativeFullscreen: false,
      );
      expect(
        resolveEpisodeSwitchPlan(
          fullscreenRouteActive: false,
          ownsHandedOverNativeFullscreen: false,
          hasCurrentRoute: true,
        ),
        plan,
      );
      expect(
        resolveEpisodeSwitchPlan(
          fullscreenRouteActive: false,
          ownsHandedOverNativeFullscreen: false,
          hasCurrentRoute: false,
        ),
        plan,
      );
    });

    test('全屏路由在栈上 -> 接管，并把原生全屏交给新页', () {
      expect(
        resolveEpisodeSwitchPlan(
          fullscreenRouteActive: true,
          ownsHandedOverNativeFullscreen: false,
          hasCurrentRoute: true,
        ),
        const EpisodeSwitchPlan(
          mode: EpisodeSwitchMode.takeover,
          handOverNativeFullscreen: true,
        ),
      );
    });

    test('接管来的原生全屏还没压上路由 -> 仍算全屏，走接管（不得只看路由）', () {
      // 上一次换集的新页还在就绪窗口里（持有原生全屏、自己的全屏路由未压上），
      // 此时再按下一集：只看 fullscreenRouteActive 会误判成窗口模式 →
      // pushReplacement → 原生全屏没人收口，窗口停在无全屏路由的原生全屏态。
      expect(
        resolveEpisodeSwitchPlan(
          fullscreenRouteActive: false,
          ownsHandedOverNativeFullscreen: true,
          hasCurrentRoute: true,
        ),
        const EpisodeSwitchPlan(
          mode: EpisodeSwitchMode.takeover,
          handOverNativeFullscreen: true,
        ),
      );
    });

    test('拿不到本页路由 -> 退回顶替（摘不掉本页会漏栈），但仍交接全屏态', () {
      for (final bool routeActive in <bool>[true, false]) {
        expect(
          resolveEpisodeSwitchPlan(
            fullscreenRouteActive: routeActive,
            ownsHandedOverNativeFullscreen: !routeActive,
            hasCurrentRoute: false,
          ),
          const EpisodeSwitchPlan(
            mode: EpisodeSwitchMode.replace,
            handOverNativeFullscreen: true,
          ),
          reason: 'routeActive=$routeActive',
        );
      }
    });

    test('全部 8 种输入组合的真值表完全钉死', () {
      final Map<String, EpisodeSwitchPlan> expected =
          <String, EpisodeSwitchPlan>{
        // key = 'fullscreenRouteActive,ownsHandedOver,hasCurrentRoute'
        'false,false,false': const EpisodeSwitchPlan(
          mode: EpisodeSwitchMode.replace,
          handOverNativeFullscreen: false,
        ),
        'false,false,true': const EpisodeSwitchPlan(
          mode: EpisodeSwitchMode.replace,
          handOverNativeFullscreen: false,
        ),
        'false,true,false': const EpisodeSwitchPlan(
          mode: EpisodeSwitchMode.replace,
          handOverNativeFullscreen: true,
        ),
        'false,true,true': const EpisodeSwitchPlan(
          mode: EpisodeSwitchMode.takeover,
          handOverNativeFullscreen: true,
        ),
        'true,false,false': const EpisodeSwitchPlan(
          mode: EpisodeSwitchMode.replace,
          handOverNativeFullscreen: true,
        ),
        'true,false,true': const EpisodeSwitchPlan(
          mode: EpisodeSwitchMode.takeover,
          handOverNativeFullscreen: true,
        ),
        'true,true,false': const EpisodeSwitchPlan(
          mode: EpisodeSwitchMode.replace,
          handOverNativeFullscreen: true,
        ),
        'true,true,true': const EpisodeSwitchPlan(
          mode: EpisodeSwitchMode.takeover,
          handOverNativeFullscreen: true,
        ),
      };
      expect(expected.length, 8, reason: '真值表必须覆盖全部 2^3 组合');
      for (final bool a in <bool>[false, true]) {
        for (final bool b in <bool>[false, true]) {
          for (final bool c in <bool>[false, true]) {
            expect(
              resolveEpisodeSwitchPlan(
                fullscreenRouteActive: a,
                ownsHandedOverNativeFullscreen: b,
                hasCurrentRoute: c,
              ),
              expected['$a,$b,$c'],
              reason: 'fullscreenRouteActive=$a owns=$b hasCurrentRoute=$c',
            );
          }
        }
      }
    });
  });
}
