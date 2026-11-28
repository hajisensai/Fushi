import 'package:fushi_lints/src/rules/pure_dart_package_imports.dart';
import 'package:test/test.dart' show expect, isFalse, isTrue;

import 'rule_test_base.dart';

void main() {
  defineRuleTests<PureDartPackageImportsTest>(
    PureDartPackageImportsTest.new,
    <String, RuleCase<PureDartPackageImportsTest>>{
      'directForbidden_reported': (PureDartPackageImportsTest t) async {
        const String src = '''
import 'package:flutter/foundation.dart';
import 'package:riverpod/riverpod.dart';

Key? k;
Ref? r;
''';
        await t.assertDiagnostics(src, <ExpectedDiagnostic>[
          t.lintAt(src, "import 'package:flutter/foundation.dart';"),
          t.lintAt(src, "import 'package:riverpod/riverpod.dart';"),
        ]);
      },
      'fullBarrel_reportedDirectly': (PureDartPackageImportsTest t) async {
        const String src = '''
import 'package:fushi_anki/fushi_anki.dart';

AnkiNote? n;
''';
        await t.assertDiagnostics(src, <ExpectedDiagnostic>[
          t.lintAt(src, "import 'package:fushi_anki/fushi_anki.dart';"),
        ]);
      },
      'transitiveFlutter_reportedWithChain':
          (PureDartPackageImportsTest t) async {
            const String src = '''
import 'package:fushi_anki/fushi_anki_core.dart';

AnkiNote? n;
''';
            await t.assertDiagnostics(src, <ExpectedDiagnostic>[
              t.lint(
                0,
                "import 'package:fushi_anki/fushi_anki_core.dart';".length,
                messageContainsAll: <Pattern>[
                  'package:fushi_anki/src/widgets.dart',
                  'package:flutter/foundation.dart',
                ],
              ),
            ]);
          },
      'pureDependency_clean': (PureDartPackageImportsTest t) async {
        await t.assertNoDiagnostics('''
import 'dart:io';
import 'package:fushi_core/fushi_core.dart';

CoreModel? m;
File? f;
''');
      },
    },
  );
  defineRuleTests<PureDartRuleScopeTest>(
    PureDartRuleScopeTest.new,
    <String, RuleCase<PureDartRuleScopeTest>>{
      'otherPackage_notInScope': (PureDartRuleScopeTest t) async {
        await t.assertNoDiagnostics('''
import 'package:riverpod/riverpod.dart';

Ref? r;
''');
      },
      'scopePredicate': (PureDartRuleScopeTest t) async {
        final PureDartPackageImports r = PureDartPackageImports();
        for (final String inScope in <String>[
          'packages/fushi_engine/lib/a.dart',
          'packages/fushi_server/bin/fushi_server.dart',
          'packages/fushi_core/lib/src/db.dart',
          'packages/fushi_audio/lib/fushi_audio_core.dart',
        ]) {
          expect(r.appliesTo(inScope), isTrue, reason: inScope);
        }
        for (final String outOfScope in <String>[
          'packages/fushi_engine/test/a_test.dart',
          'packages/fushi_anki/lib/fushi_anki_core.dart',
          'fushi/lib/main.dart',
        ]) {
          expect(r.appliesTo(outOfScope), isFalse, reason: outOfScope);
        }
      },
    },
  );
}

class PureDartPackageImportsTest extends FushiRuleTest {
  @override
  String get packageDir => 'packages/fushi_engine';

  @override
  void setUp() {
    rule = PureDartPackageImports();
    // 测试用的 mock SDK 里没有 dart:ui，Flutter 由 package:flutter/ 前缀代表。
    newPackage('flutter').addFile('lib/foundation.dart', 'class Key {}');
    newPackage('riverpod').addFile('lib/riverpod.dart', 'class Ref {}');
    // 一个纯 Dart 子 barrel，经 package: 进入另一个文件，再落到 Flutter。
    newPackage('fushi_anki')
      ..addFile('lib/fushi_anki_core.dart', "export 'src/core.dart';")
      ..addFile('lib/src/core.dart', '''
import 'package:fushi_anki/src/widgets.dart';
class AnkiNote {}
''')
      ..addFile('lib/src/widgets.dart', '''
import 'package:flutter/foundation.dart';
class AnkiWidget {}
''')
      ..addFile('lib/fushi_anki.dart', "export 'fushi_anki_core.dart';");
    newPackage('fushi_core').addFile('lib/fushi_core.dart', '''
import 'dart:io';
class CoreModel {}
''');
    super.setUp();
  }
}

/// 作用域：只管四个无头服务端闭包包的 lib/ 与 bin/。
class PureDartRuleScopeTest extends FushiRuleTest {
  @override
  String get packageDir => 'packages/fushi_dictionary';

  @override
  void setUp() {
    rule = PureDartPackageImports();
    newPackage('riverpod').addFile('lib/riverpod.dart', 'class Ref {}');
    super.setUp();
  }
}
