import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/media_source.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/reader/continuous_chapter_turn_resistance.dart';
import 'package:fushi/src/reader/reader_engine_config.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi/src/reader/reader_settings_ia.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/source_guard.dart';
import '../helpers/test_platform_services.dart';
import '../pages/reader_fushi_page_source_corpus.dart';

/// 反馈 R7k887yaJI（Android 3.3.0）：小说阅读器滚动（continuous）模式
///  ① 斜着滑（拇指弧线）不灵敏：既不跨章、正文也不滚；
///  ② 拉到章末切下一章的阻尼太强，希望可调。
///
/// 真 Chromium 层的滚动行为由 `tool/reader_pitch_headless/continuous_diagonal_pan_probe.mjs`
/// 实测；本文件锁纯函数判据（JS 影子）、设置落盘 → config 下发、shell 接线。
void main() {
  // 手指净位移：从主轴偏 [deg] 度、总长 [len]、朝前进方向（横排 = 手指上推）。
  ({double dx, double dy}) horizontalSwipe(double deg, {double len = 200}) {
    final double r = deg * math.pi / 180;
    return (dx: len * math.sin(r), dy: -len * math.cos(r));
  }

  group('continuousGestureDir：按主轴角度阈值判轴，不再 45° 一刀切', () {
    String? dir(double deg, {bool vertical = false, double len = 200}) {
      final ({double dx, double dy}) s = horizontalSwipe(deg, len: len);
      return ReaderPaginationScripts.continuousGestureDir(
        vertical: vertical,
        // 竖排主轴 = 横向：把横排的 (dx, dy) 旋转成 (−dy, dx)，前进 = 手指右移。
        dx: vertical ? -s.dy : s.dx,
        dy: vertical ? s.dx : s.dy,
        minMainPx: 20,
      );
    }

    test('拇指弧线 30° / 50° / 60° 斜滑都算主轴手势（旧判据 >45° 即丢）', () {
      for (final double deg in <double>[0, 30, 50, 60]) {
        expect(dir(deg), 'forward', reason: '$deg°');
        expect(dir(deg, vertical: true), 'forward', reason: 'vertical $deg°');
      }
    });

    test('基本横着划（>65°）不算阅读滚动', () {
      expect(dir(70), isNull);
      expect(dir(85, vertical: true), isNull);
    });

    test('方向：横排手指下拉 = backward；主轴位移不足阈值 = null', () {
      expect(
        ReaderPaginationScripts.continuousGestureDir(
          vertical: false,
          dx: 40,
          dy: 120,
          minMainPx: 20,
        ),
        'backward',
      );
      expect(
        ReaderPaginationScripts.continuousGestureDir(
          vertical: false,
          dx: 0,
          dy: -19,
          minMainPx: 20,
        ),
        isNull,
      );
    });

    test('阈值常量与正切一致（JS 侧逐字用这个值）', () {
      expect(ReaderPaginationScripts.continuousGestureMaxOffAxisDegrees, 65);
      expect(
        ReaderPaginationScripts.continuousGestureMaxOffAxisTan,
        closeTo(math.tan(65 * math.pi / 180), 1e-12),
      );
    });
  });

  group('continuousBoundaryCrossDir：贴边界之后再拉 pullPx 才跨章', () {
    test('低阻尼：同一手势中途贴到章末（pinned 在手指 300 处）再推 20 → 跨章', () {
      expect(
        ReaderPaginationScripts.continuousBoundaryCrossDir(
          gestureDir: 'forward',
          endFingerMain: 321,
          pinnedForwardAt: 300,
          pinnedBackwardAt: null,
          pullPx: ContinuousChapterTurnResistance.low.pullPx,
        ),
        'forward',
      );
    });
    test('贴边界后拉得不够 → 不跨章', () {
      expect(
        ReaderPaginationScripts.continuousBoundaryCrossDir(
          gestureDir: 'forward',
          endFingerMain: 310,
          pinnedForwardAt: 300,
          pinnedBackwardAt: null,
          pullPx: 20,
        ),
        isNull,
      );
    });
    test('高阻尼：起点就在章首也要拉满 96', () {
      String? back(double end) =>
          ReaderPaginationScripts.continuousBoundaryCrossDir(
            gestureDir: 'backward',
            endFingerMain: end,
            pinnedForwardAt: null,
            pinnedBackwardAt: 0,
            pullPx: ContinuousChapterTurnResistance.high.pullPx,
          );
      expect(back(-60), isNull);
      expect(back(-96), 'backward');
    });
    test('不是主轴手势 → 不跨章', () {
      expect(
        ReaderPaginationScripts.continuousBoundaryCrossDir(
          gestureDir: null,
          endFingerMain: 500,
          pinnedForwardAt: 0,
          pinnedBackwardAt: 0,
          pullPx: 20,
        ),
        isNull,
      );
    });
  });

  group('continuousPanAssistShouldEngage：只接管原生确实不滚的斜滑', () {
    bool engage(
      double deg, {
      bool nativeMoved = false,
      double sinceSlopMs = 64,
      double len = 60,
    }) {
      final ({double dx, double dy}) s = horizontalSwipe(deg, len: len);
      return ReaderPaginationScripts.continuousPanAssistShouldEngage(
        mainTravel: -s.dy,
        crossTravel: s.dx,
        nativeMoved: nativeMoved,
        sinceSlopMs: sinceSlopMs,
      );
    }

    test('起手偏交叉轴 55° / 60°、原生没动 → 接管', () {
      expect(engage(55), isTrue);
      expect(engage(60), isTrue);
    });
    test('主轴占优（≤45°）原生一定会滚 → 绝不接管', () {
      expect(engage(30), isFalse);
      expect(engage(45), isFalse);
    });
    test('原生已经动了 → 不接管（不叠双份滚动）', () {
      expect(engage(60, nativeMoved: true), isFalse);
    });
    test('还没观察够 settle 窗 → 先不判', () {
      expect(engage(60, sinceSlopMs: 16), isFalse);
    });
    test('基本横着划（>65°）→ 不接管', () {
      expect(engage(75), isFalse);
    });
  });

  test('补位惯性：指数衰减、单调趋零、不反向', () {
    double v = 2;
    double prev = v;
    for (int i = 0; i < 60; i++) {
      v = ReaderPaginationScripts.continuousPanAssistFlingVelocity(
        velocity: v,
        dtMs: 16,
      );
      expect(v, lessThan(prev));
      expect(v, greaterThan(0));
      prev = v;
    }
    expect(
      ReaderPaginationScripts.continuousPanAssistFlingVelocity(
        velocity: -1,
        dtMs: 1000,
      ),
      closeTo(-math.pow(0.998, 1000), 1e-9),
    );
  });

  group('ContinuousChapterTurnResistance', () {
    test('标准档逐字保持 TODO-656 既有行为：起点贴边界 + 20px', () {
      expect(ContinuousChapterTurnResistance.standard.pullPx, 20);
      expect(ContinuousChapterTurnResistance.standard.pinMidGesture, isFalse);
    });
    test('低阻尼不必松手重滑；高阻尼拉得更远', () {
      expect(ContinuousChapterTurnResistance.low.pinMidGesture, isTrue);
      expect(
        ContinuousChapterTurnResistance.high.pullPx,
        greaterThan(ContinuousChapterTurnResistance.standard.pullPx),
      );
    });
    test('未知 / 缺失值回落标准档', () {
      expect(
        ContinuousChapterTurnResistance.fromKey(null),
        ContinuousChapterTurnResistance.standard,
      );
      expect(
        ContinuousChapterTurnResistance.fromKey('rubber'),
        ContinuousChapterTurnResistance.standard,
      );
    });
  });

  group('设置落盘 → 引擎 config', () {
    late FushiDatabase db;
    late ReaderSettings readerSettings;

    setUp(() async {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      MediaSource.setDatabase(db);
      readerSettings = ReaderSettings(db);
      await readerSettings.refreshFromDb();
      ReaderFushiSource.readerSettings = readerSettings;
    });

    tearDown(() async {
      ReaderFushiSource.readerSettings = null;
      await db.close();
    });

    test('默认标准档；写入后重启读回；旁路写入同一个 key', () async {
      expect(
        readerSettings.continuousChapterTurnResistance,
        ContinuousChapterTurnResistance.standard,
      );
      await readerSettings.setContinuousChapterTurnResistance(
        ContinuousChapterTurnResistance.low,
      );
      final ReaderSettings restored = ReaderSettings(db);
      await restored.refreshFromDb();
      expect(
        restored.continuousChapterTurnResistance,
        ContinuousChapterTurnResistance.low,
      );

      ReaderFushiSource.readerSettings = null;
      await ReaderFushiSource.instance.setContinuousChapterTurnResistance(
        ContinuousChapterTurnResistance.high,
      );
      await restored.refreshFromDb();
      expect(
        restored.continuousChapterTurnResistance,
        ContinuousChapterTurnResistance.high,
      );
    });

    test('热更新 patch 带上阻尼两键', () {
      final String js = ReaderEngineConfig.liveUpdateInvocation(
        marginTop: 0,
        marginBottom: 0,
        marginLeft: 0,
        marginRight: 0,
        swipeDistThreshold: 24,
        swipeFastDistThreshold: 12,
        swipeFastVelocity: 300,
        wheelGestureQuietMs: 450,
        scanNonJapaneseText: false,
        continuousTurnPullPx: 96,
        continuousTurnPinMidGesture: false,
      );
      final Map<String, dynamic> patch =
          jsonDecode(js.substring(js.indexOf('{'), js.lastIndexOf('}') + 1))
              as Map<String, dynamic>;
      expect(patch['continuousTurnPullPx'], 96);
      expect(patch['continuousTurnPinMidGesture'], isFalse);
    });

    testWidgets('设置项只在滚动模式出现，位于翻页与手势页，改值写穿', (WidgetTester tester) async {
      late SettingsContext settingsContext;
      late SettingsItem item;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Consumer(
              builder: (BuildContext context, WidgetRef ref, _) {
                settingsContext = SettingsContext(
                  context: context,
                  appModel: AppModel(testPlatformServices()),
                  ref: ref,
                  readerSource: ReaderFushiSource.instance,
                  refresh: () {},
                );
                item = buildSettingsSchema(settingsContext)
                    .expand((SettingsDestination d) => d.sections)
                    .expand((SettingsSection s) => s.items)
                    .singleWhere(
                      (SettingsItem i) =>
                          i.id ==
                          'reading_controls.continuous_chapter_turn_resistance',
                    );
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      final SettingsSegmentedItem<ContinuousChapterTurnResistance> seg =
          item as SettingsSegmentedItem<ContinuousChapterTurnResistance>;
      expect(
        seg.options.map((SettingsSegmentOption<Object> o) => o.value),
        ContinuousChapterTurnResistance.values,
      );
      expect(seg.defaultValue, ContinuousChapterTurnResistance.standard);
      for (final String mode in <String>['paginated', 'vn']) {
        await readerSettings.setViewMode(mode);
        expect(seg.isVisible(settingsContext), isFalse, reason: mode);
      }
      await readerSettings.setViewMode('continuous');
      expect(seg.isVisible(settingsContext), isTrue);
      expect(
        kReaderSettingsSections
            .where(
              (ReaderSettingsSectionSpec s) =>
                  s.tab == ReaderSettingsTab.gestures,
            )
            .expand((ReaderSettingsSectionSpec s) => s.itemIds),
        contains('reading_controls.continuous_chapter_turn_resistance'),
      );
      await seg.onChanged(settingsContext, ContinuousChapterTurnResistance.low);
      expect(
        readerSettings.continuousChapterTurnResistance,
        ContinuousChapterTurnResistance.low,
      );
    });
  });

  group('JS / 页面接线', () {
    final String shell = ReaderPaginationScripts.continuousShellSource();

    test('判轴角度阈值与补位常量从 Dart 单一出处注入', () {
      expect(
        shell,
        contains(
          'var MAX_OFF_AXIS_TAN = '
          '${ReaderPaginationScripts.continuousGestureMaxOffAxisTan.toStringAsFixed(4)};',
        ),
      );
      expect(
        shell,
        contains(
          'var ASSIST_SETTLE_MS = '
          '${ReaderPaginationScripts.continuousPanAssistSettleMs};',
        ),
      );
    });

    test('旧 45° 一刀切判据已删除', () {
      expect(
        shell,
        isNot(
          contains(
            'Math.abs(dy) < SWIPE_THRESHOLD || Math.abs(dy) < Math.abs(dx)',
          ),
        ),
      );
      expect(
        shell,
        isNot(
          contains(
            'Math.abs(dx) < SWIPE_THRESHOLD || Math.abs(dx) < Math.abs(dy)',
          ),
        ),
      );
    });

    test('触摸控制器一文档只装一次、只在连续 shell 下动作、阻尼现读 C', () {
      final String code = shell;
      expect(
        containsCodeLine(
          code,
          'if (window.__fushiContinuousTouchInstalled) return;',
        ),
        isTrue,
      );
      expect(containsCodeLine(code, 'r._isContinuousShell()'), isTrue);
      expect(containsCodeLine(code, 'C.continuousTurnPullPx'), isTrue);
      expect(
        containsCodeLine(code, '_cfg().continuousTurnPinMidGesture === true'),
        isTrue,
      );
      // 原生已在滚时补位立刻让出。
      expect(
        containsCodeLine(code, 'Math.abs(ax.pos - assistLastPos) > 2'),
        isTrue,
      );
    });

    test('页面两处 config 构造都下发用户选的阻尼档', () {
      final String page = maskCommentsAndScriptLines(readReaderPageSource());
      expect(
        'continuousTurnPullPx: s.continuousChapterTurnResistance.pullPx'
            .allMatches(page)
            .length,
        2,
      );
      expect(
        's.continuousChapterTurnResistance.pinMidGesture'
            .allMatches(page)
            .length,
        2,
      );
    });

    test('探针文件存在（真 Chromium 斜滑行为的实测入口）', () {
      expect(
        File(
          '../tool/reader_pitch_headless/continuous_diagonal_pan_probe.mjs',
        ).existsSync(),
        isTrue,
      );
    });
  });
}
