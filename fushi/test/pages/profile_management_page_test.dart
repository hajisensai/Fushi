import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/profile_management_page.dart';
import 'package:fushi/src/profile/profile_deletion_cascade.dart';

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  Widget buildApp(Widget child) {
    return TranslationProvider(child: MaterialApp(home: child));
  }

  testWidgets('profile name dialog fits a compact desktop window', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 240);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildApp(
        const ProfileNameDialog(
          title: 'Create Profile',
          initialName: '',
          submitLabel: 'CREATE',
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('profile delete dialog fits a compact desktop window', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 240);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildApp(
        const ProfileDeleteDialog(
          profileName:
              'Very long profile name used to test compact Windows delete confirmation layout',
          onConfirm: _noop,
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text(t.profile_delete), findsWidgets);
  });

  // 反馈 8TaOy2i-lL：删 Profile 连带删 srs.db 里的复习数据，确认框写明卡数与复习记录数。
  testWidgets(
    'delete dialog states the review data that goes with the profile',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        buildApp(
          const ProfileDeleteDialog(
            profileName: 'Japanese',
            impact: ProfileDeletionImpact(
              srsNotes: 1820,
              srsCards: 1820,
              srsReviews: 7309,
              hasSrsData: true,
            ),
            onConfirm: _noop,
          ),
        ),
      );

      expect(
        find.text(t.profile_delete_srs_impact(cards: 1820, reviews: 7309)),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'delete dialog says nothing about review data when there is none',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        buildApp(
          const ProfileDeleteDialog(profileName: 'Empty', onConfirm: _noop),
        ),
      );

      expect(
        find.byKey(const ValueKey<String>('profile_delete_srs_impact')),
        findsNothing,
      );
    },
  );
}

void _noop() {}
