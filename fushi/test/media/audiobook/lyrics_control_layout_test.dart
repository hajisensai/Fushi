import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_control_layout.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_apple.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_contract.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_md3.dart';

/// 歌词模式次要按钮布局（2026-10-25 用户：「睡眠定时砍掉，换为启动统计或者关闭
/// 统计」「可以自定义布局可以自定义快捷键」）。
class _FakeClock implements LyricsPlayerClock {
  @override
  Duration get position => const Duration(seconds: 42);

  @override
  Duration get duration => const Duration(minutes: 10);

  @override
  LyricsPlayerStats get stats => LyricsPlayerStats.empty;
}

LyricsControlLayout _moved(
  LyricsControlLayout base,
  LyricsControlItem item,
  LyricsControlSlot slot,
) => LyricsControlLayout.fromCore(base.core.moveItem(item, slot));

void main() {
  group('LyricsControlLayout 模型', () {
    test('出厂布局：睡眠定时换成计时键，宽 / 窄各一份', () {
      expect(
        LyricsControlLayout.defaults.itemsIn(LyricsControlSlot.toolbar),
        <LyricsControlItem>[
          LyricsControlItem.speed,
          LyricsControlItem.studyTimer,
          LyricsControlItem.replayCue,
          LyricsControlItem.mask,
          LyricsControlItem.typography,
          LyricsControlItem.statistics,
        ],
      );
      expect(
        LyricsControlLayout.defaults.itemsIn(LyricsControlSlot.top),
        <LyricsControlItem>[
          LyricsControlItem.bookMode,
          LyricsControlItem.swapSides,
        ],
      );
      expect(
        LyricsControlLayout.compactDefaults.itemsIn(LyricsControlSlot.top),
        <LyricsControlItem>[
          LyricsControlItem.mask,
          LyricsControlItem.typography,
          LyricsControlItem.statistics,
        ],
      );
      expect(
        LyricsControlLayout.compactDefaults.core.removedItems,
        <LyricsControlItem>[
          LyricsControlItem.bookMode,
          LyricsControlItem.swapSides,
        ],
      );
    });

    test('编码往返保持顺序与移除集', () {
      final LyricsControlLayout custom = _moved(
        _moved(
          LyricsControlLayout.compactDefaults,
          LyricsControlItem.statistics,
          LyricsControlSlot.hidden,
        ),
        LyricsControlItem.replayCue,
        LyricsControlSlot.overflow,
      );
      final LyricsControlLayout decoded = LyricsControlLayout.decode(
        custom.encode(),
        fallback: LyricsControlLayout.compactDefaults,
      );
      expect(decoded, custom);
      expect(decoded.itemsIn(LyricsControlSlot.overflow), <LyricsControlItem>[
        LyricsControlItem.replayCue,
      ]);
      expect(decoded.core.removedItems, contains(LyricsControlItem.statistics));
    });

    test('空 / 坏 JSON 回落出厂；缺席的按钮按出厂位置回填', () {
      expect(LyricsControlLayout.decode(''), LyricsControlLayout.defaults);
      expect(
        LyricsControlLayout.decode('{not json'),
        LyricsControlLayout.defaults,
      );
      // 旧版本存下的布局里没有 swapSides：回填到出厂的顶部区。
      final LyricsControlLayout partial = LyricsControlLayout.decode(
        jsonEncode(<String, Object>{
          'version': 1,
          'slots': <String, List<String>>{
            'toolbar': <String>['speed', 'mask'],
            'top': <String>['bookMode'],
          },
          'removed': <String>[
            'studyTimer',
            'replayCue',
            'typography',
            'statistics',
          ],
        }),
      );
      expect(partial.itemsIn(LyricsControlSlot.top), <LyricsControlItem>[
        LyricsControlItem.bookMode,
        LyricsControlItem.swapSides,
      ]);
      expect(partial.itemsIn(LyricsControlSlot.toolbar), <LyricsControlItem>[
        LyricsControlItem.speed,
        LyricsControlItem.mask,
      ]);
    });
  });

  final Map<String, LyricsPlayerDesign> designs = <String, LyricsPlayerDesign>{
    'md3': const Md3LyricsPlayerDesign(),
    'apple': const AppleLyricsPlayerDesign(),
  };
  final Map<String, Size> sizes = <String, Size>{
    'wide': const Size(1280, 760),
    'narrow': const Size(390, 844),
  };

  const ValueKey<String> timerKey = ValueKey<String>(
    'lyrics_study_timer_button',
  );
  const ValueKey<String> statsKey = ValueKey<String>(
    'lyrics_statistics_button',
  );

  for (final MapEntry<String, LyricsPlayerDesign> d in designs.entries) {
    for (final MapEntry<String, Size> s in sizes.entries) {
      Future<void> pump(
        WidgetTester tester, {
        required LyricsControlLayout wide,
        required LyricsControlLayout compact,
        required bool paused,
        VoidCallback? onToggleStatsTimer,
        VoidCallback? onOpenStatistics,
      }) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = s.value;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (BuildContext context) => d.value.buildChrome(
                  context,
                  LyricsPlayerData(
                    title: '四つ子ぐらし',
                    cover: null,
                    isPlaying: true,
                    speed: 1,
                    lyricsMasked: false,
                    clock: _FakeClock(),
                    statsTimerPaused: paused,
                    wideControls: wide,
                    compactControls: compact,
                  ),
                  LyricsPlayerCallbacks(
                    onClose: () {},
                    onPlayPause: () {},
                    onPreviousCue: () {},
                    onNextCue: () {},
                    onSeek: (_) {},
                    onToggleMask: () {},
                    onOpenStatistics: onOpenStatistics ?? () {},
                    onSpeedChanged: (_) {},
                    onMore: (_) {},
                    onTapBackground: () {},
                    onReplayCue: () {},
                    onToggleStatsTimer: onToggleStatsTimer,
                  ),
                  size: s.value,
                  padding: EdgeInsets.zero,
                  lyricsRect: d.value.lyricsRect(
                    context,
                    s.value,
                    EdgeInsets.zero,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }

      testWidgets('${d.key} ${s.key}：计时键接到回调，睡眠定时已移除', (
        WidgetTester tester,
      ) async {
        int toggles = 0;
        await pump(
          tester,
          wide: LyricsControlLayout.defaults,
          compact: LyricsControlLayout.compactDefaults,
          paused: false,
          onToggleStatsTimer: () => toggles++,
        );
        expect(find.byKey(timerKey), findsOneWidget);
        await tester.tap(find.byKey(timerKey));
        await tester.pump();
        expect(toggles, 1);
        expect(
          find.byKey(const ValueKey<String>('lyrics_sleep_timer_button')),
          findsNothing,
          reason: '睡眠定时已从歌词页移除',
        );

        // 没接回调的宿主不画计时键。
        await pump(
          tester,
          wide: LyricsControlLayout.defaults,
          compact: LyricsControlLayout.compactDefaults,
          paused: true,
        );
        expect(find.byKey(timerKey), findsNothing);
        await tester.pumpWidget(const SizedBox());
      });

      testWidgets('${d.key} ${s.key}：按布局移出 / 收进 ⋯ 的按钮不画在页上', (
        WidgetTester tester,
      ) async {
        int stats = 0;
        await pump(
          tester,
          wide: LyricsControlLayout.defaults,
          compact: LyricsControlLayout.compactDefaults,
          paused: false,
          onToggleStatsTimer: () {},
          onOpenStatistics: () => stats++,
        );
        expect(find.byKey(statsKey), findsOneWidget);
        await tester.tap(find.byKey(statsKey));
        expect(stats, 1);

        await pump(
          tester,
          wide: _moved(
            _moved(
              LyricsControlLayout.defaults,
              LyricsControlItem.statistics,
              LyricsControlSlot.overflow,
            ),
            LyricsControlItem.studyTimer,
            LyricsControlSlot.hidden,
          ),
          compact: _moved(
            _moved(
              LyricsControlLayout.compactDefaults,
              LyricsControlItem.statistics,
              LyricsControlSlot.overflow,
            ),
            LyricsControlItem.studyTimer,
            LyricsControlSlot.hidden,
          ),
          paused: false,
          onToggleStatsTimer: () {},
        );
        expect(find.byKey(statsKey), findsNothing);
        expect(find.byKey(timerKey), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });

      testWidgets('${d.key} ${s.key}：按钮可在顶部与工具条之间搬动', (
        WidgetTester tester,
      ) async {
        // 把计时键搬到顶部：仍然只画一份、照常可点。
        int toggles = 0;
        await pump(
          tester,
          wide: _moved(
            LyricsControlLayout.defaults,
            LyricsControlItem.studyTimer,
            LyricsControlSlot.top,
          ),
          compact: _moved(
            LyricsControlLayout.compactDefaults,
            LyricsControlItem.studyTimer,
            LyricsControlSlot.top,
          ),
          paused: true,
          onToggleStatsTimer: () => toggles++,
        );
        expect(find.byKey(timerKey), findsOneWidget);
        await tester.tap(find.byKey(timerKey));
        expect(toggles, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
