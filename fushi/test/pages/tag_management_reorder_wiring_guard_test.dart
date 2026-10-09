import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

void main() {
  test(
    'tag rows use local scale-safe handles and final-index reorder semantics',
    () {
      final String code = maskCommentsAndStrings(
        File(
          'lib/src/pages/implementations/tag_management_page.dart',
        ).readAsStringSync(),
      );
      expect(containsIdentifierCall(code, 'FushiReorderableColumn'), isTrue);
      expect(
        containsIdentifierCall(code, 'FushiReorderableDragHandle'),
        isTrue,
      );
      expect(containsIdentifierCall(code, 'ReorderableListView'), isFalse);
      expect(
        containsIdentifierCall(code, 'ReorderableDragStartListener'),
        isFalse,
      );
      expect(namedArgumentValues(code, 'useDragHandles'), contains('true'));
      final String reorder = methodBody(code, 'Future<void> _onReorder');
      expect(
        RegExp(r'newIndex\s*(?:-=|--|=\s*newIndex\s*-)').hasMatch(reorder),
        isFalse,
        reason:
            'shared reorder passes the final index; SDK downward-index adjustment would lose moves',
      );
      expect(containsIdentifierCall(reorder, 'reorderTagsSafely'), isTrue);
    },
  );
}
