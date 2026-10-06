import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/lookup/effective_lookup_size.dart';
import 'package:fushi/src/lookup/lookup_popup_size_preview.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:fushi/src/settings/glass_settings_renderer.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema.dart';
import 'package:fushi/src/settings/settings_schema_lookup.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

/// 小说阅读器快捷设置 › 查词：弹窗宽高调整（用户 2026-10-05）。
///
/// 三条证据：① 宽高滑杆 + 预览 + 停靠 + 字号等确实投影进书内查词面板，且
/// 写穿全局偏好（与拖拽把手同一真值）；② 「只在小说中停靠」只翻小说的有效值；
/// ③ 弹窗几何在新范围的任意尺寸下都不越出屏幕（横 / 竖排、停靠 / 跟随、
/// 手机 / 平板 / 桌面）。
FushiDatabase _testDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

Future<AppModel> _prefsBackedAppModel(FushiDatabase db) async {
  final PreferencesRepository prefsRepo = PreferencesRepository(db);
  await prefsRepo.loadFromDb();
  final Directory tempDir = Directory.systemTemp.createTempSync(
    'fushi_reader_popup_size_',
  );
  addTearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });
  return AppModel(testPlatformServices())
    ..wireLocalAudioForTesting(prefsRepo: prefsRepo, databaseDirectory: tempDir)
    ..wireDatabaseForTesting(db);
}

/// 渲染「书内快捷设置 › 查词」那一组（与 ReaderQuickSettingsSheet 的
/// `_buildReaderGroupContent(ReaderGroup.lookup, …)` 同一投影）。
Widget _readerLookupHarness(
  FushiDatabase db,
  AppModel appModel,
  void Function(SettingsContext) onContext, {
  String designSystem = 'material',
}) {
  final ThemeNotifier themeNotifier = ThemeNotifier(db, () => const TextTheme())
    ..loadFromPrefsSnapshot(<String, String>{
      'design_system': PrefCodec.encode(designSystem),
      'app_theme_key': PrefCodec.encode('system-theme'),
      'brightness_mode': PrefCodec.encode('system'),
      'custom_theme_seed': PrefCodec.encode(0xFF1F4959),
    });
  appModel.themeNotifier = themeNotifier;
  addTearDown(themeNotifier.dispose);
  return ProviderScope(
    overrides: <Override>[appProvider.overrideWith((Ref ref) => appModel)],
    child: MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        platform: TargetPlatform.android,
        extensions: <ThemeExtension<dynamic>>[
          FushiDesignSystemTheme(themeNotifier.designSystemTheme),
        ],
      ),
      home: StatefulBuilder(
        builder: (BuildContext context, StateSetter setState) {
          return Consumer(
            builder: (BuildContext context, WidgetRef ref, _) {
              final SettingsContext sctx = SettingsContext(
                context: context,
                appModel: ref.read(appProvider),
                ref: ref,
                readerSource: ReaderFushiSource.instance,
                refresh: () => setState(() {}),
              );
              onContext(sctx);
              return resolveSettingsRenderer(context).buildDetailPage(
                settingsContext: sctx,
                destination: buildReaderGroupDestination(
                  sctx,
                  ReaderGroup.lookup,
                  t.settings_destination_lookup,
                ),
              );
            },
          );
        },
      ),
    ),
  );
}

Finder _switchRow(String title) => find.byWidgetPredicate(
  (Widget w) => w is AdaptiveSettingsSwitchRow && w.title == title,
);

void main() {
  group('reader quick settings › lookup projection', () {
    testWidgets('size / preview / docking / font size lead the lookup group', (
      WidgetTester tester,
    ) async {
      final FushiDatabase db = _testDb();
      addTearDown(db.close);
      final AppModel appModel = await _prefsBackedAppModel(db);
      late SettingsContext sctx;
      await tester.pumpWidget(
        _readerLookupHarness(db, appModel, (SettingsContext c) => sctx = c),
      );
      await tester.pump(const Duration(milliseconds: 100));

      final List<SettingsItem> items = collectReaderItems(
        sctx,
      )[ReaderGroup.lookup]!;
      final List<String> ids = items
          .map((SettingsItem i) => i.id)
          .toList(growable: false);
      expect(ids.take(6).toList(), <String>[
        'lookup.popup_max_width',
        'lookup.popup_max_height',
        'lookup.popup_size_preview',
        'lookup.popup_bottom_docked_books_only',
        'lookup.popup_bottom_docked.books',
        'lookup.dictionary_font_size',
      ]);
      for (final String id in <String>[
        'lookup.scan_non_japanese',
        'lookup.collapse_dictionaries',
        'lookup.popup_auto_expand_dictionaries',
        'lookup.compact_glossaries',
        // 既有投影项仍在。
        'lookup.auto_read_on_lookup',
        'lookup.pause_on_lookup',
        'reading_controls.enable_swipe_to_close',
      ]) {
        expect(ids, contains(id));
      }
      // 组内排序键唯一：Dart 的 List.sort 不稳定，同序号会让两行随机换位。
      final List<int> orders = items
          .map((SettingsItem i) => i.reader!.order)
          .toList();
      expect(orders.toSet().length, orders.length, reason: '组内 order 不得重复');

      // 只有 MD3 渲染器下的真实面板：预览行确实渲染出来。
      expect(
        find.byKey(const ValueKey<String>('lookup_popup_size_preview')),
        findsOneWidget,
      );
      // 小说专属停靠入口在总开关关着时出现，小说细分开关不出。
      expect(_switchRow(t.popup_bottom_docked_books_only), findsOneWidget);
      expect(_switchRow(t.popup_bottom_docked_books), findsNothing);
    });

    testWidgets(
      'width / height sliders write the shared prefs and share the clamp '
      'range with the drag handle',
      (WidgetTester tester) async {
        final FushiDatabase db = _testDb();
        addTearDown(db.close);
        final AppModel appModel = await _prefsBackedAppModel(db);
        late SettingsContext sctx;
        await tester.pumpWidget(
          _readerLookupHarness(db, appModel, (SettingsContext c) => sctx = c),
        );
        await tester.pump(const Duration(milliseconds: 100));

        final List<SettingsItem> items = collectReaderItems(
          sctx,
        )[ReaderGroup.lookup]!;
        final SettingsSliderItem width =
            items.firstWhere(
                  (SettingsItem i) => i.id == 'lookup.popup_max_width',
                )
                as SettingsSliderItem;
        final SettingsSliderItem height =
            items.firstWhere(
                  (SettingsItem i) => i.id == 'lookup.popup_max_height',
                )
                as SettingsSliderItem;

        expect(width.min, kLookupPopupMinWidth);
        expect(width.max, kLookupPopupMaxWidth);
        expect(height.min, kLookupPopupMinHeight);
        expect(height.max, kLookupPopupMaxHeight);
        expect(width.value(sctx), 400, reason: '默认宽 400');
        expect(height.value(sctx), 360, reason: '默认高 360');

        width.onChanged(sctx, 620);
        height.onChanged(sctx, 480);
        await tester.pump(const Duration(milliseconds: 50));

        expect(appModel.popupMaxWidth, 620);
        expect(appModel.popupMaxHeight, 480);
        expect(await db.getPref('popup_max_width'), isNotNull);
        expect(await db.getPref('popup_max_height'), isNotNull);

        // 偏好仓库重载后值仍在（真写穿 DB，而非只改内存）。
        final PreferencesRepository reloaded = PreferencesRepository(db);
        await reloaded.loadFromDb();
        expect(reloaded.popupMaxWidth, 620);
        expect(reloaded.popupMaxHeight, 480);

        // 预览随滑杆重建：说明文字报出当前屏幕上的实际尺寸。
        final Text caption = tester.widget<Text>(
          find.byKey(
            const ValueKey<String>('lookup_popup_size_preview_caption'),
          ),
        );
        final Size screen =
            tester.view.physicalSize / tester.view.devicePixelRatio;
        final Rect expected = lookupPopupPreviewRect(
          screen: screen,
          maxWidth: 620 * appModel.appUiScale,
          maxHeight: 480 * appModel.appUiScale,
          bottomDocked: false,
          verticalWriting: ReaderFushiSource.instance.readerWritingMode
              .startsWith('vertical'),
        );
        expect(
          caption.data,
          t.lookup_popup_size_preview_effective(
            width: expected.width.round(),
            height: expected.height.round(),
          ),
        );
      },
    );

    testWidgets(
      '"Dock only in novels" flips only the novels value and hands over to '
      'the per-module switch',
      (WidgetTester tester) async {
        final FushiDatabase db = _testDb();
        addTearDown(db.close);
        final AppModel appModel = await _prefsBackedAppModel(db);
        await tester.pumpWidget(
          _readerLookupHarness(db, appModel, (SettingsContext c) {}),
        );
        await tester.pump(const Duration(milliseconds: 100));

        expect(appModel.popupBottomDocked, isFalse);
        final AdaptiveSettingsSwitchRow row = tester
            .widget<AdaptiveSettingsSwitchRow>(
              _switchRow(t.popup_bottom_docked_books_only),
            );
        expect(row.value, isFalse);

        row.onChanged!(true);
        await tester.pump(const Duration(milliseconds: 100));

        expect(appModel.popupBottomDockedFor(ModuleId.books), isTrue);
        for (final ModuleId other in <ModuleId>[
          ModuleId.manga,
          ModuleId.video,
          ModuleId.games,
        ]) {
          expect(
            appModel.popupBottomDockedFor(other),
            isFalse,
            reason: '$other 打开前不停靠，打开后也不能被连带停靠',
          );
        }
        expect(await db.getPref('popup_bottom_docked_books'), isNotNull);

        // 总开关已开：本入口让位，小说细分开关接手且值为开。
        expect(_switchRow(t.popup_bottom_docked_books_only), findsNothing);
        final Finder books = _switchRow(t.popup_bottom_docked_books);
        expect(books, findsOneWidget);
        expect(tester.widget<AdaptiveSettingsSwitchRow>(books).value, isTrue);

        tester.widget<AdaptiveSettingsSwitchRow>(books).onChanged!(false);
        await tester.pump(const Duration(milliseconds: 100));
        expect(appModel.popupBottomDockedFor(ModuleId.books), isFalse);
      },
    );

    test('enablePopupBottomDockedOnlyInBooks keeps manually-docked modules '
        'semantics: only books changes effective value', () async {
      final FushiDatabase db = _testDb();
      addTearDown(db.close);
      final AppModel appModel = await _prefsBackedAppModel(db);
      final Map<ModuleId, bool> before = <ModuleId, bool>{
        for (final ModuleId m
            in PreferencesRepository.kPopupBottomDockedModules)
          m: appModel.popupBottomDockedFor(m),
      };
      await enablePopupBottomDockedOnlyInBooks(appModel);
      for (final ModuleId m
          in PreferencesRepository.kPopupBottomDockedModules) {
        expect(
          appModel.popupBottomDockedFor(m),
          m == ModuleId.books ? isTrue : before[m],
        );
      }
    });
  });

  testWidgets('Apple (glass) design renders the same lookup rows + preview', (
    WidgetTester tester,
  ) async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final AppModel appModel = await _prefsBackedAppModel(db);
    await tester.pumpWidget(
      _readerLookupHarness(
        db,
        appModel,
        (SettingsContext c) {},
        designSystem: 'glass',
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey<String>('lookup_popup_size_preview')),
      findsOneWidget,
    );
    expect(_switchRow(t.popup_bottom_docked_books_only), findsOneWidget);
  });

  group('popup geometry stays on-screen across the slider range', () {
    const Map<String, Size> screens = <String, Size>{
      'small phone': Size(320, 568),
      'phone': Size(390, 844),
      'phone landscape': Size(844, 390),
      'tablet': Size(820, 1180),
      'tablet landscape': Size(1366, 1024),
      'desktop': Size(1920, 1080),
    };
    const List<double> widths = <double>[
      kLookupPopupMinWidth,
      400,
      800,
      1200,
      kLookupPopupMaxWidth,
    ];
    const List<double> heights = <double>[
      kLookupPopupMinHeight,
      360,
      800,
      kLookupPopupMaxHeight,
    ];
    const List<double> uiScales = <double>[1.0, 1.5];

    for (final MapEntry<String, Size> s in screens.entries) {
      test('${s.key} ${s.value.width.toInt()}×${s.value.height.toInt()}', () {
        final Size screen = s.value;
        int checked = 0;
        for (final double w in widths) {
          for (final double h in heights) {
            for (final double scale in uiScales) {
              for (final bool vertical in <bool>[false, true]) {
                for (final bool docked in <bool>[false, true]) {
                  // 选区扫遍整屏（含四角与贴边），覆盖翻页页顶 / 滚动中段 /
                  // VN 底部台词框等落点。
                  for (final double fx in <double>[0, 0.05, 0.5, 0.95]) {
                    for (final double fy in <double>[0, 0.05, 0.5, 0.95]) {
                      final Rect sel = Rect.fromLTWH(
                        screen.width * fx,
                        screen.height * fy,
                        vertical ? 26 : 52,
                        vertical ? 52 : 26,
                      ).intersect(Offset.zero & screen);
                      final Rect r = resolvePopupRect(
                        selectionRect: sel,
                        screen: screen,
                        bottomDocked: docked,
                        maxWidth: w * scale,
                        maxHeight: h * scale,
                        padding: 6,
                        topReserve: 24,
                        bottomReserve: 48,
                        verticalWriting: vertical,
                      );
                      const double eps = 0.001;
                      final String ctx =
                          'w=$w h=$h scale=$scale vertical=$vertical '
                          'docked=$docked sel=$sel → $r';
                      expect(r.width, greaterThanOrEqualTo(0), reason: ctx);
                      expect(r.height, greaterThanOrEqualTo(0), reason: ctx);
                      expect(r.left, greaterThanOrEqualTo(-eps), reason: ctx);
                      expect(r.top, greaterThanOrEqualTo(-eps), reason: ctx);
                      expect(
                        r.right,
                        lessThanOrEqualTo(screen.width + eps),
                        reason: ctx,
                      );
                      expect(
                        r.bottom,
                        lessThanOrEqualTo(screen.height + eps),
                        reason: ctx,
                      );
                      if (!docked) {
                        // 停靠面板按设计铺满整宽，只有跟随模式受宽度上限约束。
                        expect(
                          r.width,
                          lessThanOrEqualTo(w * scale + eps),
                          reason: '实际宽不超过用户上限 $ctx',
                        );
                      }
                      expect(
                        r.height,
                        lessThanOrEqualTo(h * scale + eps),
                        reason: '实际高不超过用户上限 $ctx',
                      );
                      if (docked) {
                        expect(
                          r.bottom,
                          lessThanOrEqualTo(screen.height - 48 + eps),
                          reason: '停靠面板不压底栏预留 $ctx',
                        );
                      }
                      checked++;
                    }
                  }
                }
              }
            }
          }
        }
        expect(checked, greaterThan(0));
      });
    }

    test('preview rect equals the host geometry (single source of truth)', () {
      const Size screen = Size(390, 844);
      for (final bool vertical in <bool>[false, true]) {
        for (final bool docked in <bool>[false, true]) {
          final Rect preview = lookupPopupPreviewRect(
            screen: screen,
            maxWidth: 2000,
            maxHeight: 1600,
            bottomDocked: docked,
            verticalWriting: vertical,
          );
          final Rect host = resolvePopupRect(
            selectionRect: lookupPopupPreviewSelection(
              screen: screen,
              verticalWriting: vertical,
            ),
            screen: screen,
            bottomDocked: docked,
            maxWidth: 2000,
            maxHeight: 1600,
            verticalWriting: vertical,
          );
          expect(preview, host);
          expect(preview.right, lessThanOrEqualTo(screen.width));
          expect(preview.bottom, lessThanOrEqualTo(screen.height));
        }
      }
    });
  });

  testWidgets('preview renders in a tight phone column without overflow', (
    WidgetTester tester,
  ) async {
    for (final bool vertical in <bool>[false, true]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              child: LookupPopupSizePreview(
                maxWidth: 2000,
                maxHeight: 1600,
                bottomDocked: false,
                verticalWriting: vertical,
                screenOverride: const Size(390, 844),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final Size frame = tester.getSize(
        find.byKey(const ValueKey<String>('lookup_popup_size_preview_frame')),
      );
      expect(frame.width, lessThanOrEqualTo(300));
      expect(frame.height, lessThanOrEqualTo(200.5));
    }
  });
}
