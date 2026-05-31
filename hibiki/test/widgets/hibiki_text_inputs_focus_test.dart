import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';

import 'widget_test_helpers.dart';

void main() {
  testWidgets('HibikiSearchField registers its text focus node with the root',
      (WidgetTester tester) async {
    final TextEditingController controller = TextEditingController();
    final FocusNode focusNode = FocusNode(debugLabel: 'search-field');
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(buildTestApp(
      HibikiFocusRoot(
        child: HibikiSearchField(
          focusId: const HibikiFocusId('search'),
          controller: controller,
          focusNode: focusNode,
          hintText: 'Search',
          onChanged: (_) {},
          onSubmitted: (_) {},
        ),
      ),
    ));
    await tester.pump();

    final HibikiFocusController root = HibikiFocusRoot.controllerOf(
      tester.element(find.byType(SearchBar)),
    );
    expect(root.requestById(const HibikiFocusId('search')), isTrue);
    await tester.pump();

    expect(root.activeId, const HibikiFocusId('search'));
    expect(focusNode.hasPrimaryFocus, isTrue);
  });

  testWidgets('HibikiTextField registers with an owned focus node',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildTestApp(
      const HibikiFocusRoot(
        child: HibikiTextField(
          focusId: HibikiFocusId('text-field'),
          hintText: 'Name',
        ),
      ),
    ));
    await tester.pump();

    final HibikiFocusController root = HibikiFocusRoot.controllerOf(
      tester.element(find.byType(TextFormField)),
    );
    expect(root.requestById(const HibikiFocusId('text-field')), isTrue);
    await tester.pump();

    expect(root.activeId, const HibikiFocusId('text-field'));
    expect(FocusManager.instance.primaryFocus?.debugLabel, contains('Name'));
  });
}
