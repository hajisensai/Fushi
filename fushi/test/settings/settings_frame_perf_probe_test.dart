// 设置页帧耗时探针（不是回归门：默认 skip）。
//
// 用法（在 fushi/ 下）：
//   flutter test test/settings/settings_frame_perf_probe_test.dart --no-pub \
//     --dart-define=FUSHI_SETTINGS_PERF_PROBE=true
//
// 每个场景逐帧 `pump(16ms)`，记录：
// - 帧 CPU 时间（build + layout + paint，Stopwatch 包住输入派发与 pump；debug JIT，
//   绝对值比 release 慢数倍，只用于同机前后对比）；
// - 本帧重建的 Element 数（`debugOnRebuildDirtyWidget`，确定性）；
// - 本帧重建的设置行数（行外层 `SettingsSearchTarget` 的 build 次数，确定性）。
// 结果以 `PERF|场景|帧数|平均ms|最差ms|>16ms帧|总重建|行重建/帧均|行重建/帧峰` 打印。
import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema.dart';
import 'package:fushi/src/settings/settings_home_page.dart';
import 'package:fushi/src/settings/settings_search.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/test_platform_services.dart';

const bool _enabled = bool.fromEnvironment('FUSHI_SETTINGS_PERF_PROBE');

class _ProbeAppModel extends AppModel {
  _ProbeAppModel() : super(testPlatformServices());

  @override
  Locale get appLocale => const Locale('en', 'US');

  @override
  PackageInfo get packageInfo => PackageInfo(
    appName: 'Hibiki',
    packageName: 'jp.hibiki.test',
    version: '1.0.0',
    buildNumber: '1',
  );

  @override
  bool get reverseReaderBottomBar => false;
}

Future<AppModel> _buildAppModel() async {
  final FushiDatabase db = FushiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
  addTearDown(db.close);
  final PreferencesRepository prefsRepo = PreferencesRepository(db);
  await prefsRepo.loadFromDb();
  final Directory tempDir = Directory.systemTemp.createTempSync(
    'hibiki_settings_perf_',
  );
  addTearDown(() => tempDir.deleteSync(recursive: true));
  final ThemeNotifier notifier = ThemeNotifier(db, () => const TextTheme())
    ..loadFromPrefsSnapshot(<String, String>{
      'design_system': PrefCodec.encode('material'),
      'brightness_mode': PrefCodec.encode('light'),
    });
  addTearDown(notifier.dispose);
  return _ProbeAppModel()
    ..themeNotifier = notifier
    ..wireLocalAudioForTesting(prefsRepo: prefsRepo, databaseDirectory: tempDir)
    ..wireDatabaseForTesting(db);
}

class _Stats {
  _Stats(this.name);
  final String name;
  final List<double> ms = <double>[];
  final List<int> builds = <int>[];
  final List<int> rows = <int>[];

  String line() {
    if (ms.isEmpty) return 'PERF|$name|0';
    final double avg = ms.reduce((double a, double b) => a + b) / ms.length;
    final double worst = ms.reduce((double a, double b) => a > b ? a : b);
    final int over = ms.where((double v) => v > 16).length;
    final int total = builds.fold(0, (int a, int b) => a + b);
    final double rowAvg = rows.fold(0, (int a, int b) => a + b) / rows.length;
    final int rowPeak = rows.fold(0, (int a, int b) => a > b ? a : b);
    return 'PERF|$name|${ms.length}|${avg.toStringAsFixed(2)}|'
        '${worst.toStringAsFixed(2)}|$over|$total|'
        '${rowAvg.toStringAsFixed(1)}|$rowPeak';
  }
}

final List<String> _report = <String>[];

/// 本帧内等待宿主 IO（真实 SQLite 写穿）花掉的墙钟时间：不算进帧耗时。
int _excludedMicros = 0;

/// 让偏好写穿（真实 SQLite）在宿主事件循环里跑完；耗时从当帧计时里扣除。
Future<void> _settleHostIo(WidgetTester tester, int ms) async {
  final Stopwatch watch = Stopwatch()..start();
  await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
  _excludedMicros += watch.elapsedMicroseconds;
}

/// 逐帧量 [frames] 帧；[input] 在第 i 帧 pump 前执行（输入派发计入本帧耗时）。
Future<_Stats> _measure(
  WidgetTester tester,
  String name,
  int frames, {
  Future<void> Function(int frame)? input,
}) async {
  final _Stats stats = _Stats(name);
  int builds = 0;
  int rows = 0;
  debugOnRebuildDirtyWidget = (Element element, bool builtOnce) {
    builds++;
    // 行内容真正重建（SettingsSchemaItem 自身可能命中记忆化直接返回缓存实例，
    // 所以数它的直接子节点——每行外层的搜索落点包装）。
    if (element.widget is SettingsSearchTarget) rows++;
  };
  try {
    for (int i = 0; i < frames; i++) {
      builds = 0;
      rows = 0;
      _excludedMicros = 0;
      final Stopwatch watch = Stopwatch()..start();
      await input?.call(i);
      await tester.pump(const Duration(milliseconds: 16));
      watch.stop();
      stats.ms.add((watch.elapsedMicroseconds - _excludedMicros) / 1000);
      stats.builds.add(builds);
      stats.rows.add(rows);
    }
  } finally {
    debugOnRebuildDirtyWidget = null;
  }
  _report.add(stats.line());
  // ignore: avoid_print
  print(stats.line());
  return stats;
}

Future<ValueNotifier<bool>> _pumpHome(
  WidgetTester tester,
  AppModel model, {
  required Size size,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(() {
    tester.view.resetDevicePixelRatio();
    tester.view.resetPhysicalSize();
  });
  final ValueNotifier<bool> dark = ValueNotifier<bool>(false);
  addTearDown(dark.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        appProvider.overrideWith((Ref ref) => model),
        platformServicesProvider.overrideWithValue(model.platformServices),
      ],
      child: TranslationProvider(
        child: ValueListenableBuilder<bool>(
          valueListenable: dark,
          builder: (BuildContext context, bool isDark, Widget? _) =>
              MaterialApp(
                theme: model.themeNotifier.theme,
                darkTheme: model.themeNotifier.darkTheme,
                themeMode: isDark ? ThemeMode.dark : ThemeMode.light,
                home: const Scaffold(body: SettingsHomePage(embedded: true)),
              ),
        ),
      ),
    ),
  );
  return dark;
}

/// 把目标滚到视口中部（ensureVisible 默认贴视口顶，会落在叠放的浮动页头底下，
/// 点击就点到页头上了）。
Future<void> _center(WidgetTester tester, Finder target) async {
  await Scrollable.ensureVisible(tester.element(target), alignment: 0.5);
  await tester.pumpAndSettle();
}

Finder _jumpChips() => find.byWidgetPredicate(
  (Widget w) =>
      w.key is ValueKey<String> &&
      (w.key! as ValueKey<String>).value.startsWith('settings-jump.'),
);

Future<void> _scrollScenario(
  WidgetTester tester,
  String label, {
  required Offset at,
  int frames = 60,
  double step = 40,
}) async {
  final TestGesture gesture = await tester.startGesture(at);
  await _measure(
    tester,
    '$label.scroll-down',
    frames,
    input: (int i) => gesture.moveBy(Offset(0, -step)),
  );
  await gesture.up();
  await tester.pump(const Duration(milliseconds: 500));
  final TestGesture back = await tester.startGesture(at);
  await _measure(
    tester,
    '$label.scroll-up',
    frames,
    input: (int i) => back.moveBy(Offset(0, step)),
  );
  await back.up();
  await _measure(tester, '$label.scroll-settle', 40);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SettingsSearchReveal.pendingItemId = null;
  });
  tearDownAll(() {
    // ignore: avoid_print
    print(
      'PERF-SUMMARY\n'
      'PERF|scenario|frames|avgMs|worstMs|>16ms|builds|rowBuilds/f|rowPeak\n'
      '${_report.join('\n')}',
    );
  });

  testWidgets(
    'narrow phone: home, detail, scroll, toggle, jump, search',
    (WidgetTester tester) async {
      final AppModel model = (await tester.runAsync<AppModel>(_buildAppModel))!;
      final ValueNotifier<bool> dark = await _pumpHome(
        tester,
        model,
        size: const Size(412, 915),
      );
      await _measure(tester, 'narrow.home-first', 30);

      // 主页滚动（分类列表 + 浮动页头收展）。
      await _scrollScenario(
        tester,
        'narrow.home',
        at: const Offset(200, 600),
        frames: 20,
        step: 30,
      );

      for (final SettingsDestinationId id in <SettingsDestinationId>[
        SettingsDestinationId.video,
        SettingsDestinationId.reading,
        SettingsDestinationId.appearance,
      ]) {
        final Finder row = find.byKey(ValueKey<SettingsDestinationId>(id));
        await tester.ensureVisible(row);
        await tester.pumpAndSettle();
        await _measure(
          tester,
          'narrow.${id.name}.enter',
          45,
          input: (int i) async {
            if (i == 0) await tester.tap(row);
          },
        );
        await tester.pumpAndSettle();
        await _measure(tester, 'narrow.${id.name}.idle', 10);
        await _scrollScenario(
          tester,
          'narrow.${id.name}',
          at: const Offset(200, 600),
        );
        await tester.pumpAndSettle();

        // 切开关（找视口内第一个开关行）。
        final Finder switches = find.byType(AdaptiveSettingsSwitchRow);
        if (switches.evaluate().isNotEmpty) {
          final Finder target = switches.first;
          await _center(tester, target);
          await tester.pumpAndSettle();
          await _measure(
            tester,
            'narrow.${id.name}.toggle',
            30,
            input: (int i) async {
              if (i == 0) {
                await tester.tap(target, warnIfMissed: false);
                // 偏好写穿走真实 SQLite：让宿主事件循环把写入跑完，refresh 才会落地。
                await _settleHostIo(tester, 5);
              }
            },
          );
          await tester.pumpAndSettle();
          // 还原。
          await tester.tap(target, warnIfMissed: false);
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pumpAndSettle();
        }

        // 拖滑块（找视口内第一个滑条，横拖 20 帧）。
        final Finder sliders = find.byType(Slider);
        if (sliders.evaluate().isNotEmpty) {
          final Finder slider = sliders.first;
          await _center(tester, slider);
          await tester.pumpAndSettle();
          final Offset start = tester.getCenter(slider);
          final TestGesture drag = await tester.startGesture(start);
          await _measure(
            tester,
            'narrow.${id.name}.slider-drag',
            20,
            input: (int i) async {
              await drag.moveBy(Offset(i.isEven ? 6 : -4, 0));
              await _settleHostIo(tester, 5);
            },
          );
          await drag.up();
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pumpAndSettle();
        }

        // 分段跳转条：跳到第 3 个分组再跳回第 1 个。
        final Finder chips = _jumpChips();
        if (chips.evaluate().length >= 3) {
          await _measure(
            tester,
            'narrow.${id.name}.jump',
            40,
            input: (int i) async {
              if (i == 0) await tester.tap(chips.at(1), warnIfMissed: false);
            },
          );
          await tester.pumpAndSettle();
          await _measure(
            tester,
            'narrow.${id.name}.jump-back',
            40,
            input: (int i) async {
              if (i == 0) {
                await tester.tap(_jumpChips().at(0), warnIfMissed: false);
              }
            },
          );
          await tester.pumpAndSettle();
        }

        // 日志流：每帧一条诊断日志（调试日志开着时 debugPrint 同理）。
        await _measure(
          tester,
          'narrow.${id.name}.log-churn',
          30,
          input: (int i) async =>
              ErrorLogService.instance.logDiagnostic('perf-probe', 'tick $i'),
        );

        // 深浅色切换。
        await _measure(
          tester,
          'narrow.${id.name}.theme-dark',
          30,
          input: (int i) async {
            if (i == 0) dark.value = true;
          },
        );
        await tester.pumpAndSettle();
        dark.value = false;
        await tester.pumpAndSettle();

        // 返回主页。
        await _measure(
          tester,
          'narrow.${id.name}.exit',
          40,
          input: (int i) async {
            if (i == 0) {
              await tester
                  .state<NavigatorState>(find.byType(Navigator).first)
                  .maybePop();
            }
          },
        );
        await tester.pumpAndSettle();
      }

      // 搜索索引展平（每次击键都跑一遍）的纯 CPU 成本。
      {
        final Element home = tester.element(find.byType(SettingsHomePage));
        final SettingsContext ctx = SettingsContext(
          context: home,
          appModel: model,
          ref: home as WidgetRef,
          readerSource: ReaderFushiSource.instance,
          refresh: () {},
        );
        final List<SettingsDestination> all = buildSettingsSchema(ctx);
        final Stopwatch watch = Stopwatch()..start();
        int entries = 0;
        for (int i = 0; i < 20; i++) {
          entries = flattenVisibleSettings(all, ctx).length;
        }
        watch.stop();
        final String line =
            'PERF|flatten-index($entries entries)|20|'
            '${(watch.elapsedMicroseconds / 20000).toStringAsFixed(2)}|0|0|0|0|0';
        _report.add(line);
        // ignore: avoid_print
        print(line);
      }

      // 主页搜索输入。
      final Finder field = find.byType(EditableText).first;
      const String query = 'subtitle';
      await _measure(
        tester,
        'narrow.search-type',
        query.length * 3,
        input: (int i) async {
          if (i % 3 == 0) {
            await tester.enterText(field, query.substring(0, i ~/ 3 + 1));
          }
        },
      );
      await tester.pumpAndSettle();
      await _measure(
        tester,
        'narrow.search-clear',
        20,
        input: (int i) async {
          if (i == 0) await tester.enterText(field, '');
        },
      );
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
    skip: !_enabled,
    timeout: const Timeout(Duration(minutes: 10)),
  );

  testWidgets(
    'wide desktop: master-detail switch, scroll, toggle, search',
    (WidgetTester tester) async {
      final AppModel model = (await tester.runAsync<AppModel>(_buildAppModel))!;
      final ValueNotifier<bool> dark = await _pumpHome(
        tester,
        model,
        size: const Size(1400, 900),
      );
      await _measure(tester, 'wide.home-first', 30);
      for (final SettingsDestinationId id in <SettingsDestinationId>[
        SettingsDestinationId.video,
        SettingsDestinationId.reading,
        SettingsDestinationId.appearance,
      ]) {
        final Finder row = find.byKey(ValueKey<SettingsDestinationId>(id));
        await tester.ensureVisible(row);
        await tester.pumpAndSettle();
        await _measure(
          tester,
          'wide.${id.name}.select',
          45,
          input: (int i) async {
            if (i == 0) await tester.tap(row);
          },
        );
        await tester.pumpAndSettle();
        await _scrollScenario(
          tester,
          'wide.${id.name}',
          at: const Offset(900, 600),
        );
        await tester.pumpAndSettle();
        final Finder switches = find.byType(AdaptiveSettingsSwitchRow);
        if (switches.evaluate().isNotEmpty) {
          final Finder target = switches.first;
          await _center(tester, target);
          await tester.pumpAndSettle();
          await _measure(
            tester,
            'wide.${id.name}.toggle',
            30,
            input: (int i) async {
              if (i == 0) {
                await tester.tap(target, warnIfMissed: false);
                await _settleHostIo(tester, 5);
              }
            },
          );
          await tester.pumpAndSettle();
          await tester.tap(target, warnIfMissed: false);
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pumpAndSettle();
        }
        final Finder chips = _jumpChips();
        if (chips.evaluate().length >= 3) {
          await _measure(
            tester,
            'wide.${id.name}.jump',
            40,
            input: (int i) async {
              if (i == 0) await tester.tap(chips.at(2), warnIfMissed: false);
            },
          );
          await tester.pumpAndSettle();
        }
        await _measure(
          tester,
          'wide.${id.name}.log-churn',
          30,
          input: (int i) async =>
              ErrorLogService.instance.logDiagnostic('perf-probe', 'tick $i'),
        );
      }
      await _measure(
        tester,
        'wide.theme-dark',
        30,
        input: (int i) async {
          if (i == 0) dark.value = true;
        },
      );
      await tester.pumpAndSettle();
      dark.value = false;
      await tester.pumpAndSettle();

      final Finder field = find.byType(EditableText).first;
      const String query = 'subtitle';
      await _measure(
        tester,
        'wide.search-type',
        query.length * 3,
        input: (int i) async {
          if (i % 3 == 0) {
            await tester.enterText(field, query.substring(0, i ~/ 3 + 1));
          }
        },
      );
      await tester.pumpAndSettle();
      await _measure(
        tester,
        'wide.search-clear',
        20,
        input: (int i) async {
          if (i == 0) await tester.enterText(field, '');
        },
      );
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
    skip: !_enabled,
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
