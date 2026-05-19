import 'package:flutter/material.dart';
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
}
