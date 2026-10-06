import 'dart:convert';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart' hide buildFushiColorScheme;
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/settings/settings_actions.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/theme_preset_card.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const Color accent = Color(0xFF146C2E);
  const MethodChannel channel = MethodChannel(
    'io.material.plugins/dynamic_color',
  );
  const CustomThemeEntry custom = CustomThemeEntry(
    id: 'preview',
    name: 'Preview',
    seed: 0xFF6750A4,
    primaryColor: 0xFF6750A4,
    surfaceColor: 0xFF234567,
    neutralDerived: true,
    followSystemAccent: true,
  );
  late FushiDatabase db;
  late ThemeNotifier notifier;

  setUp(() {
    db = FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    notifier = ThemeNotifier(db, () => const TextTheme());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          return call.method == 'getAccentColor' ? accent.toARGB32() : null;
        });
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    notifier.dispose();
    await db.close();
  });

  void load(
    CustomThemeEntry entry, {
    bool pureBlack = false,
    bool eink = false,
  }) {
    notifier.loadFromPrefsSnapshot(<String, String>{
      'app_theme_key': PrefCodec.encode('custom-theme:${entry.id}'),
      'custom_themes': PrefCodec.encode(<String>[jsonEncode(entry.toJson())]),
      'selected_custom_theme_id': PrefCodec.encode(entry.id),
      'brightness_mode': PrefCodec.encode('dark'),
      'pure_black_dark': PrefCodec.encode(pureBlack),
      'eink_mode': PrefCodec.encode(eink),
    });
  }

  test('preview and active scheme preserve surface, neutral roles and system '
      'accent in both brightness modes', () async {
    load(custom);
    await notifier.refreshSystemPalette();
    for (final Brightness brightness in Brightness.values) {
      final ColorScheme preview = notifier.buildCustomThemeColorScheme(
        custom,
        brightness,
      );
      expect(preview, notifier.buildColorScheme(brightness));
      expect(preview.primary, accent);
      expect(preview.surface, const Color(0xFF234567));
      expect(
        preview,
        buildFushiColorScheme(
          seedColor: accent,
          brightness: brightness,
          primary: accent,
          surface: const Color(0xFF234567),
          neutralDerived: true,
        ),
      );
    }
  });

  test('unsaved previews follow pure black and e-ink without changing '
      'the selected theme', () {
    const CustomThemeEntry draft = CustomThemeEntry(
      id: 'draft',
      name: 'Unsaved',
      seed: 0xFFB3261E,
    );
    load(custom, pureBlack: true);
    expect(
      notifier.buildCustomThemeColorScheme(draft, Brightness.dark).surface,
      Colors.black,
    );
    expect(
      notifier.buildCustomThemeColorScheme(draft, Brightness.light).surface,
      isNot(Colors.black),
    );
    expect(notifier.appThemeKey, 'custom-theme:preview');
    expect(notifier.customThemeById('draft'), isNull);

    load(custom, pureBlack: true, eink: true);
    for (final Brightness brightness in Brightness.values) {
      expect(
        notifier.buildCustomThemeColorScheme(draft, brightness),
        buildEinkColorScheme(brightness),
      );
    }
  });

  test('derived system accent and unavailable-system fallback match active '
      'custom themes', () async {
    const CustomThemeEntry derived = CustomThemeEntry(
      id: 'derived',
      name: 'Derived',
      seed: 0xFF6750A4,
      followSystemAccent: true,
      neutralDerived: true,
    );
    load(derived, pureBlack: true);
    for (final bool withSystemAccent in <bool>[false, true]) {
      if (withSystemAccent) await notifier.refreshSystemPalette();
      for (final Brightness brightness in Brightness.values) {
        final ColorScheme preview = notifier.buildCustomThemeColorScheme(
          derived,
          brightness,
        );
        expect(preview, notifier.buildColorScheme(brightness));
        expect(
          preview,
          buildFushiColorScheme(
            seedColor: withSystemAccent ? accent : Color(derived.seed),
            brightness: brightness,
            neutralDerived: true,
            pureBlack: true,
          ),
        );
      }
    }
  });

  testWidgets('settings custom theme card shows the active resolved scheme', (
    WidgetTester tester,
  ) async {
    load(custom, pureBlack: true);
    await notifier.refreshSystemPalette();
    final AppModel model = AppModel(testPlatformServices())
      ..themeNotifier = notifier;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: notifier.darkTheme,
          home: Scaffold(
            body: SingleChildScrollView(
              child: Consumer(
                builder: (BuildContext context, WidgetRef ref, Widget? child) {
                  return buildThemeSelector(
                    SettingsContext(
                      context: context,
                      appModel: model,
                      ref: ref,
                      readerSource: ReaderFushiSource.instance,
                      refresh: () {},
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    final FushiThemePresetCard card = tester.widget<FushiThemePresetCard>(
      find.byKey(const ValueKey<String>('theme-preset-custom-theme:preview')),
    );
    expect(card.seed, accent);
    expect(card.scheme, notifier.buildColorScheme(Brightness.dark));
    expect(card.scheme.surface, const Color(0xFF234567));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
