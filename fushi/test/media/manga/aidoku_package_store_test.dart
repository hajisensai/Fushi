import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/manga/aidoku/aidoku_package_store.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_runtime.dart';

void main() {
  late Directory root;
  late AidokuPackageStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fushi-aidoku-store-');
    store = AidokuPackageStore(Directory('${root.path}/installed'));
  });

  tearDown(() async {
    await root.delete(recursive: true);
  });

  AidokuPackageInspection inspection({int version = 1}) =>
      AidokuPackageInspection(
        manifest: <String, Object?>{
          'info': <String, Object?>{
            'id': 'ja.example',
            'name': 'Example',
            'version': version,
            'languages': <Object?>['ja'],
          },
        },
        imports: const <String>['net.send'],
        exports: const <String>['get_search_manga_list'],
        requiresWebView: false,
      );

  test('installs, lists, and removes an inspected aix package', () async {
    final File source = File('${root.path}/source.aix');
    await source.writeAsBytes(<int>[1, 2, 3], flush: true);

    final AidokuInstalledPackage installed =
        await store.install(source, inspection());
    final List<AidokuInstalledPackage> packages = await store.listInstalled();

    expect(installed.id, 'ja.example');
    expect(await File(installed.packagePath).readAsBytes(), <int>[1, 2, 3]);
    expect(packages, hasLength(1));
    expect(packages.single.name, 'Example');
    expect(packages.single.languages, <String>['ja']);

    await store.remove(packages.single);
    expect(await store.listInstalled(), isEmpty);
  });

  test('reimport atomically replaces the package and metadata', () async {
    final File first = File('${root.path}/first.aix');
    final File second = File('${root.path}/second.aix');
    await first.writeAsBytes(<int>[1]);
    await second.writeAsBytes(<int>[2]);

    await store.install(first, inspection());
    final AidokuInstalledPackage replaced =
        await store.install(second, inspection(version: 2));

    expect(await File(replaced.packagePath).readAsBytes(), <int>[2]);
    final List<AidokuInstalledPackage> packages = await store.listInstalled();
    expect(packages, hasLength(1));
    expect(packages.single.version, 2);
  });

  test('rejects an empty package before changing the store', () async {
    final File source = File('${root.path}/empty.aix');
    await source.create();

    await expectLater(
      store.install(source, inspection()),
      throwsA(
        isA<AidokuRuntimeException>().having(
          (AidokuRuntimeException error) => error.code,
          'code',
          'PACKAGE_SIZE',
        ),
      ),
    );
    expect(await store.listInstalled(), isEmpty);
  });

  test('rejects a package with an empty source identity', () async {
    final File source = File('${root.path}/invalid.aix');
    await source.writeAsBytes(<int>[1]);
    final AidokuPackageInspection invalid = AidokuPackageInspection(
      manifest: <String, Object?>{
        'info': <String, Object?>{
          'id': '  ',
          'name': 'Example',
          'version': 1,
        },
      },
      imports: const <String>[],
      exports: const <String>[],
      requiresWebView: false,
    );

    await expectLater(
      store.install(source, invalid),
      throwsA(
        isA<AidokuRuntimeException>().having(
          (AidokuRuntimeException error) => error.code,
          'code',
          'INVALID_MANIFEST',
        ),
      ),
    );
    expect(await store.listInstalled(), isEmpty);
  });
}
