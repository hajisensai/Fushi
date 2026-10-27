import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// Kavita 集成的结构性护栏（源码扫描）。
///
/// 这些边界失效都是静默的：编译、测试照常过，问题要到合并另一条分支（ABS）、
/// 上架审核或用户日志外泄时才暴露。
void main() {
  final List<Directory> roots = <Directory>[
    Directory('lib/src/media/kavita'),
    Directory('lib/src/media/manga/kavita'),
    Directory('lib/src/pages/implementations/kavita'),
    Directory('../packages/fushi_engine/lib/media/kavita'),
  ];

  List<File> kavitaFiles() => <File>[
    for (final Directory root in roots)
      if (root.existsSync())
        for (final FileSystemEntity e in root.listSync(recursive: true))
          if (e is File && e.path.endsWith('.dart')) e,
  ];

  String strip(String source) => maskComments(source);

  test('guard sees the kavita sources (not vacuous)', () {
    expect(kavitaFiles().length, greaterThan(8));
  });

  test(
    'kavita code never imports Audiobookshelf (merge order independence)',
    () {
      final List<String> offenders = <String>[];
      for (final File f in kavitaFiles()) {
        final String code = strip(f.readAsStringSync());
        if (RegExp(
          r'^import .*audiobookshelf',
          multiLine: true,
        ).hasMatch(code)) {
          offenders.add(f.path);
        }
      }
      expect(offenders, isEmpty, reason: 'Kavita 只抄 ABS 的模式，不 import 它的类');
    },
  );

  test('engine kavita client has no flutter / app imports (purity)', () {
    for (final File f in kavitaFiles().where(
      (File f) => f.path.replaceAll('\\', '/').contains('fushi_engine/'),
    )) {
      final String code = strip(f.readAsStringSync());
      expect(code, isNot(contains('package:flutter/')), reason: f.path);
      expect(code, isNot(contains('dart:ui')), reason: f.path);
      expect(code, isNot(contains('package:fushi/')), reason: f.path);
    }
  });

  test('kavita code never logs or prints keys / authenticated urls', () {
    final RegExp logCall = RegExp(
      r'(print|debugPrint|\.log)\s*\([^;]*(apiKey|ImageUrl|CoverUrl|\.uri\(|token)',
      caseSensitive: false,
      dotAll: true,
    );
    final List<String> offenders = <String>[];
    for (final File f in kavitaFiles()) {
      if (logCall.hasMatch(strip(f.readAsStringSync()))) offenders.add(f.path);
    }
    expect(offenders, isEmpty);
  });

  test(
    'streaming is not iOS-gated; platform checks stay out of kavita code',
    () {
      // iOS 合规判据只在 store_compliance.dart 写一次；Kavita 流式是用户自己的服务器，
      // 不进 StoreRestrictedCapability，所以这里不应出现任何平台判断。
      for (final File f in kavitaFiles()) {
        final String code = strip(f.readAsStringSync());
        expect(code, isNot(contains('Platform.isIOS')), reason: f.path);
      }
      final String compliance = File(
        'lib/src/models/store_compliance.dart',
      ).readAsStringSync();
      expect(compliance.toLowerCase(), isNot(contains('kavita')));
    },
  );

  test(
    'the only database touch is the sourceMetadata binding (no schema change)',
    () {
      final String database = File(
        '../packages/fushi_core/lib/src/database/database.dart',
      ).readAsStringSync();
      expect(database, isNot(contains('kavita')));
      final String tables = File(
        '../packages/fushi_core/lib/src/database/tables.dart',
      ).readAsStringSync();
      expect(tables.toLowerCase(), isNot(contains('kavita')));
    },
  );
}
