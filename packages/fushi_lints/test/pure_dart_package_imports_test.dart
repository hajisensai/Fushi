import 'package:fushi_lints/src/rules/pure_dart_package_imports.dart';
import 'package:test/test.dart' show expect, isFalse, isTrue;
import 'package:test_reflective_loader/test_reflective_loader.dart';

import 'rule_test_base.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(PureDartPackageImportsTest);
    defineReflectiveTests(PureDartRuleScopeTest);
  });
}

@reflectiveTest
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

  Future<void> test_directForbidden_reported() async {
    const String src = '''
import 'package:flutter/foundation.dart';
import 'package:riverpod/riverpod.dart';

Key? k;
Ref? r;
''';
    await assertDiagnostics(src, <ExpectedDiagnostic>[
      lintAt(src, "import 'package:flutter/foundation.dart';"),
      lintAt(src, "import 'package:riverpod/riverpod.dart';"),
    ]);
  }

  Future<void> test_fullBarrel_reportedDirectly() async {
    const String src = '''
import 'package:fushi_anki/fushi_anki.dart';

AnkiNote? n;
''';
    await assertDiagnostics(src, <ExpectedDiagnostic>[
      lintAt(src, "import 'package:fushi_anki/fushi_anki.dart';"),
    ]);
  }

  Future<void> test_transitiveFlutter_reportedWithChain() async {
    const String src = '''
import 'package:fushi_anki/fushi_anki_core.dart';

AnkiNote? n;
''';
    await assertDiagnostics(src, <ExpectedDiagnostic>[
      lint(
        0,
        "import 'package:fushi_anki/fushi_anki_core.dart';".length,
        messageContainsAll: <Pattern>[
          'package:fushi_anki/src/widgets.dart',
          'package:flutter/foundation.dart',
        ],
      ),
    ]);
  }

  Future<void> test_pureDependency_clean() async {
    await assertNoDiagnostics('''
import 'dart:io';
import 'package:fushi_core/fushi_core.dart';

CoreModel? m;
File? f;
''');
  }
}

/// 作用域：只管四个无头服务端闭包包的 lib/ 与 bin/。
@reflectiveTest
class PureDartRuleScopeTest extends FushiRuleTest {
  @override
  String get packageDir => 'packages/fushi_dictionary';

  @override
  void setUp() {
    rule = PureDartPackageImports();
    newPackage('riverpod').addFile('lib/riverpod.dart', 'class Ref {}');
    super.setUp();
  }

  Future<void> test_otherPackage_notInScope() async {
    await assertNoDiagnostics('''
import 'package:riverpod/riverpod.dart';

Ref? r;
''');
  }

  void test_scopePredicate() {
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
  }
}
