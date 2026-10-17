// HBK033: FushiPageScaffold floats its header over the body by default
// (bc65b9dc94c); pages with explicit scroll padding must add the header
// inset (MediaQuery.paddingOf(context).top) or their first item sits under
// the header. Migrated from the Codex round-5 repro.
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/changelog_page.dart';
import 'package:fushi/utils.dart';

void main() {
  testWidgets('initial changelog release stays below the floating header', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: ThemeData(splashFactory: NoSplash.splashFactory),
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: const ChangelogPage(
            initialReleases: <Map<String, dynamic>>[
              <String, dynamic>{
                'tag_name': 'v1.2.0',
                'published_at': '2026-07-10T08:00:00Z',
                'prerelease': false,
                'body': 'Release notes',
              },
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final Rect header = tester.getRect(find.byType(FushiPageChromeTitle));
    final Rect firstRelease = tester.getRect(find.text('v1.2.0'));
    expect(
      firstRelease.top,
      greaterThanOrEqualTo(header.bottom),
      reason:
          'An unscrolled first release must be readable below the header: '
          'header=$header, firstRelease=$firstRelease',
    );
  });
}
