import 'package:fushi_lints/src/rules/platform_dirs_via_app_paths.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

import 'rule_test_base.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(PlatformDirsViaAppPathsTest);
    defineReflectiveTests(PlatformDirsInPackagesTest);
  });
}

const String _pathProvider = '''
class Directory {}
Future<Directory> getTemporaryDirectory() async => Directory();
Future<Directory> getApplicationDocumentsDirectory() async => Directory();
''';

@reflectiveTest
class PlatformDirsViaAppPathsTest extends FushiRuleTest {
  @override
  void setUp() {
    rule = PlatformDirsViaAppPaths();
    newPackage(
      'path_provider',
    ).addFile('lib/path_provider.dart', _pathProvider);
    super.setUp();
  }

  Future<void> test_call_reported() async {
    const String src = '''
import 'package:path_provider/path_provider.dart';

Future<Object> f() => getTemporaryDirectory();
''';
    await assertDiagnostics(src, <ExpectedDiagnostic>[
      lintAt(src, 'getTemporaryDirectory();'.replaceAll('();', '')),
    ]);
  }

  Future<void> test_tearOff_and_prefix_reported() async {
    const String src = '''
import 'package:path_provider/path_provider.dart' as pp;

Future<Object> Function() resolver = pp.getApplicationDocumentsDirectory;
''';
    await assertDiagnostics(src, <ExpectedDiagnostic>[
      lintAt(src, 'getApplicationDocumentsDirectory'),
    ]);
  }

  Future<void> test_showCombinator_docComment_clean() async {
    await assertNoDiagnostics('''
// ignore: unused_import
import 'package:path_provider/path_provider.dart' show getTemporaryDirectory;

/// Unlike [getTemporaryDirectory], this follows the data root.
void f() {}
''');
  }

  Future<void> test_testDirectory_notInScope() async {
    final String path = writePackageFile('test/a_test.dart', '''
import 'package:path_provider/path_provider.dart';

Future<Object> f() => getTemporaryDirectory();
''');
    await assertNoDiagnosticsInFile(path);
  }

  static const String _platformFallback =
      'lib/src/media/audiobook/audiobook_storage_platform.dart';

  Future<void> test_allowance_exactCount_clean() async {
    final String path = writePackageFile(_platformFallback, '''
import 'package:path_provider/path_provider.dart';

Future<Object> Function()? resolver;
void install() => resolver ??= getApplicationDocumentsDirectory;
''');
    await assertNoDiagnosticsInFile(path);
  }

  Future<void> test_allowance_isPerFunction() async {
    const String src = '''
import 'package:path_provider/path_provider.dart';

Future<Object> Function()? resolver;
void install() => resolver ??= getApplicationDocumentsDirectory;
Future<Object> temp() => getTemporaryDirectory();
''';
    final String path = writePackageFile(_platformFallback, src);
    // 只登记了 getApplicationDocumentsDirectory：别的函数没有额度。
    await assertDiagnosticsInFile(path, <ExpectedDiagnostic>[
      lintAt(src, 'getTemporaryDirectory'),
    ]);
  }

  Future<void> test_allowance_unused_isStale() async {
    final String path = writePackageFile(_platformFallback, '''
void install() {}
''');
    await assertDiagnosticsInFile(path, <ExpectedDiagnostic>[staleAllowance()]);
  }
}

@reflectiveTest
class PlatformDirsInPackagesTest extends FushiRuleTest {
  @override
  String get packageDir => 'packages/fushi_platform';

  @override
  void setUp() {
    rule = PlatformDirsViaAppPaths();
    newPackage(
      'path_provider',
    ).addFile('lib/path_provider.dart', _pathProvider);
    super.setUp();
  }

  Future<void> test_packageLib_notInScope() async {
    await assertNoDiagnostics('''
import 'package:path_provider/path_provider.dart';

Future<Object> f() => getTemporaryDirectory();
''');
  }
}
