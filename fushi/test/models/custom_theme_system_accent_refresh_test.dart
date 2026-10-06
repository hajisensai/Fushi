import 'dart:convert';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi_core/fushi_core.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel(
    'io.material.plugins/dynamic_color',
  );
  const int seed = 0xFF1F4959;
  late FushiDatabase db;
  late ThemeNotifier notifier;
  late int notifications;
  int? accent;

  setUp(() {
    db = FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    notifier = ThemeNotifier(db, () => const TextTheme());
    notifications = 0;
    notifier.addListener(() => notifications++);
    accent = 0xFFE67E22;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          return call.method == 'getAccentColor' ? accent : null;
        });
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    notifier.dispose();
    await db.close();
  });

  void loadCustomTheme({required bool follow, bool pinned = false}) {
    final CustomThemeEntry entry = CustomThemeEntry(
      id: 'accent-theme',
      name: 'Accent theme',
      seed: seed,
      primaryColor: pinned ? seed : null,
      followSystemAccent: follow,
    );
    notifier.loadFromPrefsSnapshot(<String, String>{
      'app_theme_key': PrefCodec.encode('custom-theme:${entry.id}'),
      'custom_themes': PrefCodec.encode(<String>[jsonEncode(entry.toJson())]),
      'selected_custom_theme_id': PrefCodec.encode(entry.id),
    });
    notifications = 0;
  }

  for (final bool pinned in <bool>[false, true]) {
    test('following custom theme refreshes ${pinned ? 'pinned' : 'derived'} '
        'accent and suppresses unchanged notifications', () async {
      loadCustomTheme(follow: true, pinned: pinned);
      await notifier.refreshSystemPalette();
      expect(notifications, 1);
      final Color before = notifier.buildColorScheme(Brightness.light).primary;

      accent = 0xFF146C2E;
      await notifier.refreshSystemPalette();
      expect(notifications, 2);
      final Color after = notifier.buildColorScheme(Brightness.light).primary;
      expect(after, isNot(before));
      expect(
        after,
        buildFushiColorScheme(
          seedColor: Color(accent!),
          brightness: Brightness.light,
          primary: pinned ? Color(accent!) : null,
        ).primary,
      );

      await notifier.refreshSystemPalette();
      expect(notifications, 2, reason: 'Unchanged system color stays silent');

      accent = null;
      await notifier.refreshSystemPalette();
      expect(notifications, 3);
      expect(
        notifier.buildColorScheme(Brightness.light).primary,
        buildFushiColorScheme(
          seedColor: const Color(seed),
          brightness: Brightness.light,
          primary: pinned ? const Color(seed) : null,
        ).primary,
        reason: 'Losing system color restores the saved seed or pinned color',
      );
    });
  }

  test('fixed custom theme ignores system accent changes', () async {
    loadCustomTheme(follow: false);
    final ColorScheme before = notifier.buildColorScheme(Brightness.light);
    await notifier.refreshSystemPalette();
    accent = 0xFF146C2E;
    await notifier.refreshSystemPalette();
    expect(notifications, 0);
    expect(notifier.buildColorScheme(Brightness.light), before);
  });
}
