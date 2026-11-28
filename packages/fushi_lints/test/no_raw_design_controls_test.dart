import 'package:fushi_lints/src/rules/no_raw_design_controls.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

import 'rule_test_base.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(NoRawDesignControlsTest);
  });
}

@reflectiveTest
class NoRawDesignControlsTest extends FushiRuleTest {
  @override
  void setUp() {
    rule = NoRawDesignControls();
    newPackage('material_ui').addFile('lib/material_ui.dart', '''
class Widget { const Widget(); }
class SegmentedButton<T> extends Widget {
  const SegmentedButton();
  static Object styleFrom() => Object();
}
class TabBar extends Widget {
  const TabBar();
  const TabBar.secondary();
}
class ListTile extends Widget { const ListTile(); }
class Switch extends Widget {
  const Switch();
  const Switch.adaptive();
}
class Card extends Widget {
  const Card();
  const Card.filled();
}
''');
    newPackage('cupertino_ui').addFile('lib/cupertino_ui.dart', '''
class CupertinoSlidingSegmentedControl<T> { CupertinoSlidingSegmentedControl(); }
''');
    super.setUp();
  }

  Future<void> test_rawSegmentedButton_reported() async {
    const String src = '''
import 'package:material_ui/material_ui.dart';

Widget build() => SegmentedButton<int>();
''';
    await assertDiagnostics(src, <ExpectedDiagnostic>[
      lintAt(src, 'SegmentedButton<int>', occurrence: 0),
    ]);
  }

  Future<void> test_prefixedImport_stillReported() async {
    const String src = '''
import 'package:material_ui/material_ui.dart' as m;

m.Widget build() => const m.Card.filled();
''';
    await assertDiagnostics(src, <ExpectedDiagnostic>[
      lintAt(src, 'm.Card.filled'),
    ]);
  }

  Future<void> test_cupertinoSegments_and_tabBar_reported() async {
    const String src = '''
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';

Object a() => CupertinoSlidingSegmentedControl<int>();
Widget b() => const TabBar.secondary();
Widget c() => const ListTile();
''';
    await assertDiagnostics(src, <ExpectedDiagnostic>[
      lintAt(src, 'CupertinoSlidingSegmentedControl<int>'),
      lintAt(src, 'TabBar.secondary'),
      lintAt(src, 'ListTile', occurrence: 0),
    ]);
  }

  Future<void> test_subclass_staticMember_comment_string_clean() async {
    await assertNoDiagnostics('''
import 'package:material_ui/material_ui.dart';

// SegmentedButton<int>() in a comment
class FushiPillSegmentedButton<T> extends SegmentedButton<T> {
  const FushiPillSegmentedButton() : super();
}

class FushiSegmentedButton extends Widget {
  const FushiSegmentedButton();
}

Object style() => SegmentedButton.styleFrom();
String label() => 'Card()';
Widget build() => const FushiPillSegmentedButton<int>();
Widget other() => const FushiSegmentedButton();
''');
  }

  Future<void> test_sameNameOutsideFramework_clean() async {
    await assertNoDiagnostics('''
class Card { const Card(); }

Object build() => const Card();
''');
  }

  Future<void> test_allowance_exactCount() async {
    const String one = '''
import 'package:material_ui/material_ui.dart';

Widget a() => const ListTile();
Widget b() => const Card();
Widget b2() => const Card.filled();
Widget b3() => const Card();
''';
    final String path = writePackageFile(
      'lib/src/utils/components/glass/fushi_glass_lists.dart',
      one,
    );
    await assertNoDiagnosticsInFile(path);
  }

  Future<void> test_allowance_exceeded_reportsEverySite() async {
    const String src = '''
import 'package:material_ui/material_ui.dart';

Widget a() => const ListTile();
Widget b() => const ListTile();
Widget c() => const Card();
Widget c2() => const Card.filled();
Widget c3() => const Card();
''';
    final String path = writePackageFile(
      'lib/src/utils/components/glass/fushi_glass_lists.dart',
      src,
    );
    await assertDiagnosticsInFile(path, <ExpectedDiagnostic>[
      lintAt(src, 'ListTile', occurrence: 0),
      lintAt(src, 'ListTile', occurrence: 1),
    ]);
  }

  Future<void> test_allowance_underused_isStale() async {
    const String src = '''
import 'package:material_ui/material_ui.dart';

Widget a() => const ListTile();
''';
    final String path = writePackageFile(
      'lib/src/utils/components/glass/fushi_glass_lists.dart',
      src,
    );
    await assertDiagnosticsInFile(path, <ExpectedDiagnostic>[staleAllowance()]);
  }

  Future<void> test_interactiveControl_reportedOnPage() async {
    const String src = '''
import 'package:material_ui/material_ui.dart';

Widget a() => const Switch.adaptive();
''';
    final String path = writePackageFile('lib/src/pages/a_page.dart', src);
    await assertDiagnosticsInFile(path, <ExpectedDiagnostic>[
      lintAt(src, 'Switch.adaptive'),
    ]);
  }

  Future<void> test_interactiveControl_implementationLayer_clean() async {
    final String path = writePackageFile(
      'lib/src/utils/components/glass/fushi_glass_controls.dart',
      '''
import 'package:material_ui/material_ui.dart';

Widget a() => const Switch();
Widget b() => const Switch();
''',
    );
    await assertNoDiagnosticsInFile(path);
  }

  Future<void> test_segmented_hasNoImplementationLayer() async {
    const String src = '''
import 'package:material_ui/material_ui.dart';

Widget a() => const SegmentedButton<int>();
''';
    final String path = writePackageFile(
      'lib/src/utils/components/glass/fushi_glass_controls.dart',
      src,
    );
    await assertDiagnosticsInFile(path, <ExpectedDiagnostic>[
      lintAt(src, 'SegmentedButton<int>'),
    ]);
  }
}
