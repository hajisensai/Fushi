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
/// used to wrap its dropdown in an `Expanded`, which under unbounded width
/// threw "RenderFlex children have non-zero flex but incoming width constraints
/// are unbounded" — blanking the whole route in debug builds and leaving the
/// un-laid-out subtree unable to hit-test (clicks dead). This test pumps the
/// real widget in the real trailing slot and asserts no exception.
void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  testWidgets(
    'ProfileSelector survives unbounded-width trailing measurement',
    (WidgetTester tester) async {
      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      // Guarantee a non-empty profile list so ProfileSelector builds the real
      // dropdown row instead of short-circuiting to SizedBox.shrink().
      final int now = DateTime.now().millisecondsSinceEpoch;
      await db.insertProfile(
        ProfilesCompanion.insert(
            name: 'Default', createdAt: now, updatedAt: now),
      );
      final ProfileRepository repo =
          ProfileRepository(db, AnkiConnectRepository());

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

      expect(tester.takeException(), isNull);
      expect(find.byType(DropdownMenu<int>), findsOneWidget);
    },
  );
}
