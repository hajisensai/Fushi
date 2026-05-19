import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/test_helpers.dart';

void main() {
  testWidgets('findPrimaryNavigationTargets scopes icons to NavigationRail',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              NavigationRail(
                selectedIndex: 0,
                destinations: [
                  NavigationRailDestination(
                    icon: Icon(Icons.menu_book),
                    label: Text('Books'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.search),
                    label: Text('Dictionary'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.tune),
                    label: Text('Settings'),
                  ),
                ],
              ),
              Expanded(
                child: Center(
                  child: Icon(Icons.search),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final List<Finder> targets = findPrimaryNavigationTargets();

    expect(targets, hasLength(3));
    expect(tester.getCenter(targets[1]).dx, lessThan(100));
  });

  testWidgets('findPrimaryNavigationTargets preserves rail tab order',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NavigationRail(
            selectedIndex: 0,
            destinations: [
              NavigationRailDestination(
                icon: Icon(Icons.menu_book),
                label: Text('Books'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.search),
                label: Text('Dictionary'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.tune),
                label: Text('Settings'),
              ),
            ],
          ),
        ),
      ),
    );

    final List<Finder> targets = findPrimaryNavigationTargets();

    expect(targets, hasLength(3));
    expect(tester.widget<Icon>(targets[0]).icon, Icons.menu_book);
    expect(tester.widget<Icon>(targets[1]).icon, Icons.search);
    expect(tester.widget<Icon>(targets[2]).icon, Icons.tune);
  });

  testWidgets('findPrimaryNavigationTargets falls back to bottom navigation',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(child: Icon(Icons.search)),
          bottomNavigationBar: BottomNavigationBar(
            items: [
              BottomNavigationBarItem(
                icon: Icon(Icons.menu_book),
                label: 'Books',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.search),
                label: 'Dictionary',
              ),
            ],
          ),
        ),
      ),
    );

    final List<Finder> targets = findPrimaryNavigationTargets();

    expect(targets, hasLength(2));
    expect(tester.widget<Icon>(targets[0]).icon, Icons.menu_book);
    expect(tester.widget<Icon>(targets[1]).icon, Icons.search);
  });

  test('screenshots are optional on Windows drive', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    expect(screenshotsAreRequired, isFalse);
  });
}
