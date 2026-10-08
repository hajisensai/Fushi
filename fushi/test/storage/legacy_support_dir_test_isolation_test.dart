import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/storage/legacy_support_dir_migration.dart';
import 'package:path/path.dart' as p;

class _TrackingSupportPath {
  _TrackingSupportPath(this.path);

  final String path;
  int calls = 0;

  Future<Directory> resolve() async {
    calls++;
    return Directory(path);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('isolated Windows startup does not migrate real support directories', () {
    late Directory sandbox;
    late Directory legacy;
    late Directory current;
    late Directory staging;
    late _TrackingSupportPath provider;

    setUp(() {
      // Every filesystem mutation is confined to this test-owned temporary root.
      sandbox = Directory.systemTemp.createTempSync(
        'fushi-migration-isolation-',
      );
      legacy = Directory(p.join(sandbox.path, 'Hibiki', 'Hibiki'))
        ..createSync(recursive: true);
      current = Directory(p.join(sandbox.path, 'Fushi', 'Fushi'))
        ..createSync(recursive: true);
      staging = Directory(current.path + kSupportMigrationStagingSuffix)
        ..createSync(recursive: true);
      File(
        p.join(legacy.path, 'fushi.db'),
      ).writeAsStringSync('legacy sentinel');
      File(
        p.join(staging.path, 'partial'),
      ).writeAsStringSync('staging sentinel');
      provider = _TrackingSupportPath(current.path);
    });

    tearDown(() {
      sandbox.deleteSync(recursive: true);
    });

    void expectUntouched() {
      expect(
        provider.calls,
        0,
        reason: 'the isolation gate must precede the platform directory API',
      );
      expect(
        File(p.join(legacy.path, 'fushi.db')).readAsStringSync(),
        'legacy sentinel',
      );
      expect(current.listSync(), isEmpty);
      expect(
        File(p.join(staging.path, 'partial')).readAsStringSync(),
        'staging sentinel',
      );
    }

    test('FUSHI_TEST_ROOT environment skips before path_provider', () async {
      final LegacySupportMigrationOutcome result =
          await migrateLegacySupportDir(
            environment: <String, String>{
              'FUSHI_TEST_ROOT': p.join(sandbox.path, 'isolated-root'),
            },
            dartDefineRoot: '',
            supportDirectoryResolver: provider.resolve,
          );
      expect(result, LegacySupportMigrationOutcome.notApplicable);
      expectUntouched();
    });

    test('FUSHI_TEST_ROOT dart-define skips before path_provider', () async {
      final LegacySupportMigrationOutcome result =
          await migrateLegacySupportDir(
            environment: const <String, String>{},
            dartDefineRoot: p.join(sandbox.path, 'isolated-root'),
            supportDirectoryResolver: provider.resolve,
          );
      expect(result, LegacySupportMigrationOutcome.notApplicable);
      expectUntouched();
    });

    for (final String blank in <String>['', '   ']) {
      // 只有「照常迁移」依赖 Windows 的 Hibiki\Hibiki → Fushi\Fushi 目录布局；
      // 上面两条隔离门在 Platform 判断之前，任何平台（含 Linux CI）都要跑。
      test('blank test root retains normal migration ($blank)', () async {
        final LegacySupportMigrationOutcome result =
            await migrateLegacySupportDir(
              environment: <String, String>{'FUSHI_TEST_ROOT': blank},
              dartDefineRoot: blank,
              supportDirectoryResolver: provider.resolve,
            );
        expect(result, LegacySupportMigrationOutcome.moved);
        expect(provider.calls, 1);
        expect(legacy.existsSync(), isFalse);
        expect(
          File(p.join(current.path, 'fushi.db')).readAsStringSync(),
          'legacy sentinel',
        );
        expect(staging.existsSync(), isFalse);
      }, skip: !Platform.isWindows);
    }
  });
}
