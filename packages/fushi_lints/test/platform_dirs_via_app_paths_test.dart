import 'package:fushi_lints/src/rules/platform_dirs_via_app_paths.dart';

import 'rule_test_base.dart';

void main() {
  defineRuleTests<PlatformDirsViaAppPathsTest>(
    PlatformDirsViaAppPathsTest.new,
    <String, RuleCase<PlatformDirsViaAppPathsTest>>{
      'call_reported': (PlatformDirsViaAppPathsTest t) async {
        const String src = '''
import 'package:path_provider/path_provider.dart';

Future<Object> f() => getTemporaryDirectory();
''';
        await t.assertDiagnostics(src, <ExpectedDiagnostic>[
          t.lintAt(src, 'getTemporaryDirectory();'.replaceAll('();', '')),
        ]);
      },
      'tearOff_and_prefix_reported': (PlatformDirsViaAppPathsTest t) async {
        const String src = '''
import 'package:path_provider/path_provider.dart' as pp;

Future<Object> Function() resolver = pp.getApplicationDocumentsDirectory;
''';
        await t.assertDiagnostics(src, <ExpectedDiagnostic>[
          t.lintAt(src, 'getApplicationDocumentsDirectory'),
        ]);
      },
      'showCombinator_docComment_clean': (PlatformDirsViaAppPathsTest t) async {
        await t.assertNoDiagnostics('''
// ignore: unused_import
import 'package:path_provider/path_provider.dart' show getTemporaryDirectory;

/// Unlike [getTemporaryDirectory], this follows the data root.
void f() {}
''');
      },
      'testDirectory_notInScope': (PlatformDirsViaAppPathsTest t) async {
        final String path = t.writePackageFile('test/a_test.dart', '''
import 'package:path_provider/path_provider.dart';

Future<Object> f() => getTemporaryDirectory();
''');
        await t.assertNoDiagnosticsInFile(path);
      },
      'allowance_exactCount_clean': (PlatformDirsViaAppPathsTest t) async {
        final String path = t.writePackageFile(_platformFallback, '''
import 'package:path_provider/path_provider.dart';

Future<Object> Function()? resolver;
void install() => resolver ??= getApplicationDocumentsDirectory;
''');
        await t.assertNoDiagnosticsInFile(path);
      },
      'allowance_isPerFunction': (PlatformDirsViaAppPathsTest t) async {
        const String src = '''
import 'package:path_provider/path_provider.dart';

Future<Object> Function()? resolver;
void install() => resolver ??= getApplicationDocumentsDirectory;
Future<Object> temp() => getTemporaryDirectory();
''';
        final String path = t.writePackageFile(_platformFallback, src);
        // 只登记了 getApplicationDocumentsDirectory：别的函数没有额度。
        await t.assertDiagnosticsInFile(path, <ExpectedDiagnostic>[
          t.lintAt(src, 'getTemporaryDirectory'),
        ]);
      },
      'allowance_unused_isStale': (PlatformDirsViaAppPathsTest t) async {
        final String path = t.writePackageFile(_platformFallback, '''
void install() {}
''');
        await t.assertDiagnosticsInFile(path, <ExpectedDiagnostic>[
          t.staleAllowance(),
        ]);
      },
    },
  );
  defineRuleTests<PlatformDirsInPackagesTest>(
    PlatformDirsInPackagesTest.new,
    <String, RuleCase<PlatformDirsInPackagesTest>>{
      'packageLib_notInScope': (PlatformDirsInPackagesTest t) async {
        await t.assertNoDiagnostics('''
import 'package:path_provider/path_provider.dart';

Future<Object> f() => getTemporaryDirectory();
''');
      },
    },
  );
}

const String _platformFallback =
    'lib/src/media/audiobook/audiobook_storage_platform.dart';

const String _pathProvider = '''
class Directory {}
Future<Directory> getTemporaryDirectory() async => Directory();
Future<Directory> getApplicationDocumentsDirectory() async => Directory();
''';

class PlatformDirsViaAppPathsTest extends FushiRuleTest {
  @override
  void setUp() {
    rule = PlatformDirsViaAppPaths();
    newPackage('path_provider')
        .addFile('lib/path_provider.dart', _pathProvider);
    super.setUp();
  }
}

class PlatformDirsInPackagesTest extends FushiRuleTest {
  @override
  String get packageDir => 'packages/fushi_platform';

  @override
  void setUp() {
    rule = PlatformDirsViaAppPaths();
    newPackage('path_provider')
        .addFile('lib/path_provider.dart', _pathProvider);
    super.setUp();
  }
}
