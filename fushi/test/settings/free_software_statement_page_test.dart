import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/free_software_statement_page.dart';
import 'package:fushi/src/updates/build_listing.dart';
import 'package:material_ui/material_ui.dart';

Future<void> _pump(WidgetTester tester, {required bool local}) async {
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        home: FreeSoftwareStatementPage(showLocalNotice: local),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows statement and links', (WidgetTester tester) async {
    await _pump(tester, local: false);
    expect(find.text(t.settings_free_software_license_body), findsOneWidget);
    expect(find.text(t.settings_free_software_free_forever), findsOneWidget);
    expect(find.text(t.settings_free_software_paid_advice), findsOneWidget);
    for (final String id in <String>[
      'releases',
      'website',
      'additional-terms',
      'trademark',
    ]) {
      expect(
        find.byKey(ValueKey<String>('free-software-$id'), skipOffstage: false),
        findsOneWidget,
        reason: id,
      );
    }
    expect(
      find.byKey(const ValueKey<String>('free-software-local-notice')),
      findsNothing,
    );
  });

  testWidgets('local notice line on top when active', (
    WidgetTester tester,
  ) async {
    await _pump(tester, local: true);
    expect(
      find.byKey(const ValueKey<String>('free-software-local-notice')),
      findsOneWidget,
    );
    expect(find.text(currentLocalNoticeText().title), findsOneWidget);
  });

  test('link targets', () {
    expect(kFushiReleasesUrl, 'https://github.com/hajisensai/Fushi/releases');
    expect(kFushiAdditionalTermsUrl, endsWith('/ADDITIONAL_TERMS.md'));
    expect(kFushiTrademarkUrl, endsWith('/TRADEMARK.md'));
  });
}
