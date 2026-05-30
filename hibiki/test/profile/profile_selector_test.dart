import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/profile/profile_repository.dart';
import 'package:hibiki/src/profile/profile_selector.dart';
import 'package:hibiki/src/profile/profile_view_model.dart';
import 'package:hibiki/src/utils/components/settings_shared.dart';
import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// Regression for the desktop "empty Anki settings page + dead left mouse" bug.
///
/// [ProfileSelector] is embedded as the `trailing` of an [AdaptiveSettingsRow]
/// on the Anki settings page. AdaptiveSettingsRow's Row places a non-flex
/// trailing beside an `Expanded(label)` sibling, so RenderFlex measures the
/// trailing with UNBOUNDED main-axis width. ProfileSelector's Material branch
/// used to wrap its dropdown in an `Expanded`, which under unbounded width threw
/// "RenderFlex children have non-zero flex but incoming width constraints are
/// unbounded" — blanking the whole route in debug builds and leaving the
/// un-laid-out subtree unable to hit-test (clicks dead). These tests pump the
/// real widget in the real trailing slot and assert no exception — both at a
/// normal width and at a narrow (320px) window where a fixed-width trailing
/// would overflow.
Future<void> _pumpProfileSelectorRow(WidgetTester tester) async {
  final HibikiDatabase db = HibikiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  // Guarantee a non-empty profile list so ProfileSelector builds the real
  // dropdown row instead of short-circuiting to SizedBox.shrink().
  final int now = DateTime.now().millisecondsSinceEpoch;
  await db.insertProfile(
    ProfilesCompanion.insert(name: 'Default', createdAt: now, updatedAt: now),
  );
  final ProfileRepository repo = ProfileRepository(db, AnkiConnectRepository());

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        profileRepositoryProvider.overrideWithValue(repo),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: ListView(
              children: const <Widget>[
                AdaptiveSettingsRow(
                  title: 'Profile',
                  trailing: ProfileSelector(),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  // Let ProfileViewModel._load() populate profiles and rebuild.
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  testWidgets(
    'ProfileSelector survives unbounded-width trailing measurement',
    (WidgetTester tester) async {
      await _pumpProfileSelectorRow(tester);

      expect(tester.takeException(), isNull);
      expect(find.byType(DropdownMenu<int>), findsOneWidget);
    },
  );

  testWidgets(
    'ProfileSelector trailing does not overflow a narrow (320px) row',
    (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 640);
      addTearDown(tester.view.reset);

      await _pumpProfileSelectorRow(tester);

      // A fixed/greedy-width trailing would trip a RenderFlex overflow here,
      // surfaced via takeException().
      expect(tester.takeException(), isNull);
      expect(find.byType(DropdownMenu<int>), findsOneWidget);
    },
  );
}
