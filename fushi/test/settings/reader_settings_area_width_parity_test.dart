import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/settings/material_settings_renderer.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../helpers/test_platform_services.dart';

// Guards TODO-1321 / BUG-610: in the reader in-book quick-settings pane the
// schema-projected sub-pages (layout / reading-controls / lookup) are rendered
// by [MaterialSettingsRenderer.buildDetailContent] embedded inside a
// SingleChildScrollView that ALREADY applies horizontal padding. The renderer
// used to always bake in its own detailHorizontalInsets, double-indenting those
// sub-pages so they rendered NARROWER than the pane's bespoke navigation /
// audiobook sub-pages. Root fix: buildDetailContent gained insetHorizontally;
// when false it drops its own horizontal inset and lets the embedder own the
// margins (matching the Cupertino renderer), so the body spans the full pane.
FushiDatabase _testDb() {
  return FushiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
}

class _WidthTestAppModel extends AppModel {
  _WidthTestAppModel() : super(testPlatformServices());

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

SettingsDestination _oneSwitchDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.readerQuickSettings,
    title: 'Layout',
    icon: Icons.tune_outlined,
    sections: <SettingsSection>[
      SettingsSection(
        items: <SettingsItem>[
          SettingsSwitchItem(
            id: 'toggle',
            title: 'Toggle',
            value: (_) => true,
            onChanged: (_, __) {},
          ),
        ],
      ),
    ],
  );
}

Widget _harness({required Widget Function(SettingsContext) builder}) {
  final FushiDatabase db = _testDb();
  final ThemeNotifier themeNotifier = ThemeNotifier(db, () => const TextTheme())
    ..loadFromPrefsSnapshot(<String, String>{
      'design_system': PrefCodec.encode('material'),
      'app_theme_key': PrefCodec.encode('system-theme'),
      'brightness_mode': PrefCodec.encode('system'),
      'custom_theme_seed': PrefCodec.encode(0xFF1F4959),
    });
  final AppModel appModel = _WidthTestAppModel()..themeNotifier = themeNotifier;
  addTearDown(() async {
    themeNotifier.dispose();
    await db.close();
  });

  return ProviderScope(
    overrides: <Override>[
      appProvider.overrideWith((Ref ref) => appModel),
    ],
    child: MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        platform: TargetPlatform.android,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF386A58)),
        extensions: <ThemeExtension<dynamic>>[
          FushiDesignSystemTheme(themeNotifier.designSystemTheme),
        ],
      ),
      home: Consumer(
        builder: (BuildContext context, WidgetRef ref, _) {
          return builder(
            SettingsContext(
              context: context,
              appModel: ref.read(appProvider),
              ref: ref,
              readerSource: ReaderFushiSource.instance,
              refresh: () {},
            ),
          );
        },
      ),
    ),
  );
}

void main() {
  testWidgets(
      'embedded body (insetHorizontally:false) spans full pane width and is '
      'wider than the self-inset variant (TODO-1321/BUG-610)',
      (WidgetTester tester) async {
    const double boxWidth = 500;
    late EdgeInsets shared;

    Widget variant(bool inset) => _harness(
          builder: (SettingsContext ctx) {
            shared = MaterialSettingsRenderer.detailHorizontalInsets(
              FushiDesignTokens.of(ctx.context),
            );
            return Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: boxWidth,
                height: 400,
                child: MaterialSettingsRenderer().buildDetailContent(
                  settingsContext: ctx,
                  destination: _oneSwitchDestination(),
                  shrinkWrap: true,
                  insetHorizontally: inset,
                ),
              ),
            );
          },
        );

    await tester.pumpWidget(variant(false));
    await tester.pumpAndSettle();
    final double flushWidth =
        tester.getSize(find.byType(AdaptiveSettingsSection).first).width;

    await tester.pumpWidget(variant(true));
    await tester.pumpAndSettle();
    final double insetWidth =
        tester.getSize(find.byType(AdaptiveSettingsSection).first).width;

    expect(shared.left + shared.right, greaterThan(0),
        reason:
            'detailHorizontalInsets must be a real inset for the gap to show');
    expect(flushWidth, moreOrLessEquals(boxWidth, epsilon: 1.0),
        reason: 'embedded body must span the full pane width (no self inset)');
    expect(insetWidth,
        moreOrLessEquals(boxWidth - shared.left - shared.right, epsilon: 1.0),
        reason: 'self-inset body carries the horizontal insets');
    expect(flushWidth - insetWidth, greaterThan(20),
        reason:
            'embedded body must be wider than the self-inset one (TODO-1321)');
  });

  test('renderer gates horizontal inset on insetHorizontally + sheet opts out',
      () {
    final String renderer =
        File('lib/src/settings/material_settings_renderer.dart')
            .readAsStringSync();
    expect(
      renderer,
      contains(
          'insetHorizontally ? detailHorizontalInsets(tokens) : EdgeInsets.zero'),
      reason: 'material detail body horizontal inset must be gated on the flag',
    );

    final String sheet =
        File('lib/src/media/audiobook/reader_quick_settings_sheet.dart')
            .readAsStringSync();
    expect(sheet, contains('insetHorizontally: false'),
        reason:
            'schema-projected sub-pages must let the renderer drop its inset');
    expect(sheet, isNot(contains('detailHorizontalInsets')),
        reason: 'theme/css cards must not re-wrap in detailHorizontalInsets');
  });
}
