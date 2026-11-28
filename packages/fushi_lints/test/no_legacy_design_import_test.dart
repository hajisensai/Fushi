import 'package:fushi_lints/src/rules/no_legacy_design_import.dart';

import 'rule_test_base.dart';

void main() {
  defineRuleTests<NoLegacyDesignImportTest>(NoLegacyDesignImportTest.new, <
    String,
    RuleCase<NoLegacyDesignImportTest>
  >{
    'materialImport_reported': (NoLegacyDesignImportTest t) async {
      const String src = '''
import 'package:flutter/material.dart';

Widget? w;
''';
      await t.assertDiagnostics(src, <ExpectedDiagnostic>[
        t.lintAt(src, "import 'package:flutter/material.dart';"),
      ]);
    },
    'cupertinoExport_reported': (NoLegacyDesignImportTest t) async {
      const String src = '''
export 'package:flutter/cupertino.dart';
''';
      await t.assertDiagnostics(src, <ExpectedDiagnostic>[
        t.lintAt(src, "export 'package:flutter/cupertino.dart';"),
      ]);
    },
    'designPackages_clean': (NoLegacyDesignImportTest t) async {
      await t.assertNoDiagnostics('''
import 'package:material_ui/material_ui.dart';

Card? c;
''');
    },
    'outsideLib_notInScope': (NoLegacyDesignImportTest t) async {
      final String path = t.writePackageFile('test/a_test.dart', '''
import 'package:flutter/material.dart';

Widget? w;
''');
      await t.assertNoDiagnosticsInFile(path);
    },
    'allowedFile_legacyPrefix_clean': (NoLegacyDesignImportTest t) async {
      final String path = t.writePackageFile(
        'lib/src/pages/implementations/changelog_page.dart',
        '''
import 'package:flutter/material.dart' as legacy;

legacy.Widget? w;
''',
      );
      await t.assertNoDiagnosticsInFile(path);
    },
    'allowedFile_withoutPrefix_reported': (NoLegacyDesignImportTest t) async {
      const String src = '''
import 'package:flutter/material.dart';

Widget? w;
''';
      final String path = t.writePackageFile(
        'lib/src/pages/implementations/changelog_page.dart',
        src,
      );
      // 不带 `as legacy` 的旧 import 不吃豁免；豁免额度也就没人用，同时报过期。
      await t.assertDiagnosticsInFile(path, <ExpectedDiagnostic>[
        t.staleAllowance(),
        t.lintAt(src, "import 'package:flutter/material.dart';"),
      ]);
    },
    'allowedFile_secondImport_reportsAll': (NoLegacyDesignImportTest t) async {
      const String src = '''
import 'package:flutter/material.dart' as legacy;
import 'package:flutter/cupertino.dart' as legacy;

legacy.Widget? w;
legacy.CupertinoApp? a;
''';
      final String path = t.writePackageFile(
        'lib/src/pages/implementations/changelog_page.dart',
        src,
      );
      // 豁免是按 kind（具体哪个旧库）计的：cupertino 没有额度。
      await t.assertDiagnosticsInFile(path, <ExpectedDiagnostic>[
        t.lintAt(src, "import 'package:flutter/cupertino.dart' as legacy;"),
      ]);
    },
    'allowedFile_migrated_staleAllowance': (NoLegacyDesignImportTest t) async {
      final String path = t.writePackageFile(
        'lib/src/pages/implementations/changelog_page.dart',
        '''
import 'package:material_ui/material_ui.dart';

Card? c;
''',
      );
      await t.assertDiagnosticsInFile(path, <ExpectedDiagnostic>[
        t.staleAllowance(),
      ]);
    },
  });
}

class NoLegacyDesignImportTest extends FushiRuleTest {
  @override
  void setUp() {
    rule = NoLegacyDesignImport();
    newPackage('flutter')
      ..addFile('lib/material.dart', 'class Widget {}')
      ..addFile('lib/cupertino.dart', 'class CupertinoApp {}');
    newPackage('material_ui').addFile('lib/material_ui.dart', 'class Card {}');
    super.setUp();
  }
}
