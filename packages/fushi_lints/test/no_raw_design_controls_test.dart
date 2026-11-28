import 'package:fushi_lints/src/rules/no_raw_design_controls.dart';

import 'rule_test_base.dart';

void main() {
  defineRuleTests<NoRawDesignControlsTest>(NoRawDesignControlsTest.new, <
    String,
    RuleCase<NoRawDesignControlsTest>
  >{
    'rawSegmentedButton_reported': (NoRawDesignControlsTest t) async {
      const String src = '''
import 'package:material_ui/material_ui.dart';

Widget build() => SegmentedButton<int>();
''';
      await t.assertDiagnostics(src, <ExpectedDiagnostic>[
        t.lintAt(src, 'SegmentedButton<int>', occurrence: 0),
      ]);
    },
    'prefixedImport_stillReported': (NoRawDesignControlsTest t) async {
      const String src = '''
import 'package:material_ui/material_ui.dart' as m;

m.Widget build() => const m.Card.filled();
''';
      await t.assertDiagnostics(src, <ExpectedDiagnostic>[
        t.lintAt(src, 'm.Card.filled'),
      ]);
    },
    'cupertinoSegments_and_tabBar_reported': (NoRawDesignControlsTest t) async {
      const String src = '''
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';

Object a() => CupertinoSlidingSegmentedControl<int>();
Widget b() => const TabBar.secondary();
Widget c() => const ListTile();
''';
      await t.assertDiagnostics(src, <ExpectedDiagnostic>[
        t.lintAt(src, 'CupertinoSlidingSegmentedControl<int>'),
        t.lintAt(src, 'TabBar.secondary'),
        t.lintAt(src, 'ListTile', occurrence: 0),
      ]);
    },
    'subclass_staticMember_comment_string_clean':
        (NoRawDesignControlsTest t) async {
          await t.assertNoDiagnostics('''
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
        },
    'sameNameOutsideFramework_clean': (NoRawDesignControlsTest t) async {
      await t.assertNoDiagnostics('''
class Card { const Card(); }

Object build() => const Card();
''');
    },
    'allowance_exactCount': (NoRawDesignControlsTest t) async {
      const String one = '''
import 'package:material_ui/material_ui.dart';

Widget a() => const ListTile();
Widget b() => const Card();
Widget b2() => const Card.filled();
Widget b3() => const Card();
''';
      final String path = t.writePackageFile(
        'lib/src/utils/components/glass/fushi_glass_lists.dart',
        one,
      );
      await t.assertNoDiagnosticsInFile(path);
    },
    'allowance_exceeded_reportsEverySite': (NoRawDesignControlsTest t) async {
      const String src = '''
import 'package:material_ui/material_ui.dart';

Widget a() => const ListTile();
Widget b() => const ListTile();
Widget c() => const Card();
Widget c2() => const Card.filled();
Widget c3() => const Card();
''';
      final String path = t.writePackageFile(
        'lib/src/utils/components/glass/fushi_glass_lists.dart',
        src,
      );
      await t.assertDiagnosticsInFile(path, <ExpectedDiagnostic>[
        t.lintAt(src, 'ListTile', occurrence: 0),
        t.lintAt(src, 'ListTile', occurrence: 1),
      ]);
    },
    'allowance_underused_isStale': (NoRawDesignControlsTest t) async {
      const String src = '''
import 'package:material_ui/material_ui.dart';

Widget a() => const ListTile();
''';
      final String path = t.writePackageFile(
        'lib/src/utils/components/glass/fushi_glass_lists.dart',
        src,
      );
      await t.assertDiagnosticsInFile(path, <ExpectedDiagnostic>[
        t.staleAllowance(),
      ]);
    },
    'interactiveControl_reportedOnPage': (NoRawDesignControlsTest t) async {
      const String src = '''
import 'package:material_ui/material_ui.dart';

Widget a() => const Switch.adaptive();
''';
      final String path = t.writePackageFile('lib/src/pages/a_page.dart', src);
      await t.assertDiagnosticsInFile(path, <ExpectedDiagnostic>[
        t.lintAt(src, 'Switch.adaptive'),
      ]);
    },
    'interactiveControl_implementationLayer_clean':
        (NoRawDesignControlsTest t) async {
          final String path = t.writePackageFile(
            'lib/src/utils/components/glass/fushi_glass_controls.dart',
            '''
import 'package:material_ui/material_ui.dart';

Widget a() => const Switch();
Widget b() => const Switch();
''',
          );
          await t.assertNoDiagnosticsInFile(path);
        },
    'segmented_hasNoImplementationLayer': (NoRawDesignControlsTest t) async {
      const String src = '''
import 'package:material_ui/material_ui.dart';

Widget a() => const SegmentedButton<int>();
''';
      final String path = t.writePackageFile(
        'lib/src/utils/components/glass/fushi_glass_controls.dart',
        src,
      );
      await t.assertDiagnosticsInFile(path, <ExpectedDiagnostic>[
        t.lintAt(src, 'SegmentedButton<int>'),
      ]);
    },
  });
}

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
}
