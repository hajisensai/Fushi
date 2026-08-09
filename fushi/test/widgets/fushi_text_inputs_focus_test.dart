import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';

import 'widget_test_helpers.dart';

void main() {
  testWidgets('FushiSearchField registers its text focus node with the root',
      (WidgetTester tester) async {
    final TextEditingController controller = TextEditingController();
    final FocusNode focusNode = FocusNode(debugLabel: 'search-field');
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(buildTestApp(
      FushiFocusRoot(
        child: FushiSearchField(
          focusId: const FushiFocusId('search'),
          controller: controller,
          focusNode: focusNode,
          hintText: 'Search',
          onChanged: (_) {},
          onSubmitted: (_) {},
        ),
      ),
    ));
    await tester.pump();

    final FushiFocusController root = FushiFocusRoot.controllerOf(
      tester.element(find.byType(SearchBar)),
    );
    expect(root.requestById(const FushiFocusId('search')), isTrue);
    await tester.pump();

    expect(root.activeId, const FushiFocusId('search'));
    expect(focusNode.hasPrimaryFocus, isTrue);
  });

  testWidgets('FushiTextField registers with an owned focus node',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildTestApp(
      const FushiFocusRoot(
        child: FushiTextField(
          focusId: FushiFocusId('text-field'),
          hintText: 'Name',
        ),
      ),
    ));
    await tester.pump();

    final FushiFocusController root = FushiFocusRoot.controllerOf(
      tester.element(find.byType(TextFormField)),
    );
    expect(root.requestById(const FushiFocusId('text-field')), isTrue);
    await tester.pump();

    expect(root.activeId, const FushiFocusId('text-field'));
    expect(FocusManager.instance.primaryFocus?.debugLabel, contains('Name'));
  });
}
