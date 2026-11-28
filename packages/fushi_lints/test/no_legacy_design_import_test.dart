import 'package:fushi_lints/src/rules/no_legacy_design_import.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

import 'rule_test_base.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(NoLegacyDesignImportTest);
  });
}

@reflectiveTest
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

  Future<void> test_materialImport_reported() async {
    const String src = '''
import 'package:flutter/material.dart';

Widget? w;
''';
    await assertDiagnostics(src, <ExpectedDiagnostic>[
      lintAt(src, "import 'package:flutter/material.dart';"),
    ]);
  }

  Future<void> test_cupertinoExport_reported() async {
    const String src = '''
export 'package:flutter/cupertino.dart';
''';
    await assertDiagnostics(src, <ExpectedDiagnostic>[
      lintAt(src, "export 'package:flutter/cupertino.dart';"),
    ]);
  }

  Future<void> test_designPackages_clean() async {
    await assertNoDiagnostics('''
import 'package:material_ui/material_ui.dart';

Card? c;
''');
  }

  Future<void> test_outsideLib_notInScope() async {
    final String path = writePackageFile('test/a_test.dart', '''
import 'package:flutter/material.dart';

Widget? w;
''');
    await assertNoDiagnosticsInFile(path);
  }

  Future<void> test_allowedFile_legacyPrefix_clean() async {
    final String path = writePackageFile(
      'lib/src/pages/implementations/changelog_page.dart',
      '''
import 'package:flutter/material.dart' as legacy;

legacy.Widget? w;
''',
    );
    await assertNoDiagnosticsInFile(path);
  }

  Future<void> test_allowedFile_withoutPrefix_reported() async {
    const String src = '''
import 'package:flutter/material.dart';

Widget? w;
''';
    final String path = writePackageFile(
      'lib/src/pages/implementations/changelog_page.dart',
      src,
    );
    // 不带 `as legacy` 的旧 import 不吃豁免；豁免额度也就没人用，同时报过期。
    await assertDiagnosticsInFile(path, <ExpectedDiagnostic>[
      staleAllowance(),
      lintAt(src, "import 'package:flutter/material.dart';"),
    ]);
  }

  Future<void> test_allowedFile_secondImport_reportsAll() async {
    const String src = '''
import 'package:flutter/material.dart' as legacy;
import 'package:flutter/cupertino.dart' as legacy;

legacy.Widget? w;
legacy.CupertinoApp? a;
''';
    final String path = writePackageFile(
      'lib/src/pages/implementations/changelog_page.dart',
      src,
    );
    // 豁免是按 kind（具体哪个旧库）计的：cupertino 没有额度。
    await assertDiagnosticsInFile(path, <ExpectedDiagnostic>[
      lintAt(src, "import 'package:flutter/cupertino.dart' as legacy;"),
    ]);
  }

  Future<void> test_allowedFile_migrated_staleAllowance() async {
    final String path = writePackageFile(
      'lib/src/pages/implementations/changelog_page.dart',
      '''
import 'package:material_ui/material_ui.dart';

Card? c;
''',
    );
    await assertDiagnosticsInFile(path, <ExpectedDiagnostic>[staleAllowance()]);
  }
}
