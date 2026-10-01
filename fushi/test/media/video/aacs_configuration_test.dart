import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/media/video/bluray/aacs_configuration.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late EnginePaths previousPaths;
  late Uint8List unit;
  late String discId;

  String database({String? id}) =>
      '0x${id ?? discId} = Synthetic test disc | V | 0x00112233445566778899aabbccddeeff\n';
  List<int> zip(String text, {String name = 'keydb.cfg'}) =>
      ZipEncoder().encode(Archive()..addFile(ArchiveFile.string(name, text)))!;
  Matcher failure(AacsConfigurationError code) => throwsA(
    isA<AacsConfigurationException>().having((e) => e.code, 'code', code),
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('aacs_configuration_test_');
    previousPaths = enginePaths;
    enginePaths = FixedEnginePaths(documents: root, support: root, temp: root);
    unit = Uint8List.fromList(List<int>.generate(64, (i) => i));
    discId = sha1.convert(unit).toString();
    await Directory(p.join(root.path, 'AACS')).create();
    await File(p.join(root.path, 'AACS', 'Unit_Key_RO.inf')).writeAsBytes(unit);
    aacsKeyDbPathOverride = null;
    aacsHttpClientFactory = null;
    // 不读开发机上真实的 %APPDATA%/aacs、~/.config/aacs。
    aacsStandardConfigurationsForTesting = <String>[];
  });
  tearDown(() async {
    aacsKeyDbPathOverride = null;
    aacsHttpClientFactory = null;
    aacsStandardConfigurationsForTesting = null;
    enginePaths = previousPaths;
    await root.delete(recursive: true);
  });

  test('explicit configuration matches exact disc SHA1 and hex VUK', () async {
    final File local = File(p.join(root.path, 'custom.cfg'));
    await local.writeAsString(database(id: discId.toUpperCase()));
    aacsKeyDbPathOverride = local.path;
    final result = await loadAacsConfiguration(root.path);
    expect(result.unitKeyFile, unit);
    expect(result.volumeUniqueKey, [
      0,
      17,
      34,
      51,
      68,
      85,
      102,
      119,
      136,
      153,
      170,
      187,
      204,
      221,
      238,
      255,
    ]);
  });

  test(
    'explicit path never falls through to network or title matching',
    () async {
      final File local = File(p.join(root.path, 'custom.cfg'));
      await local.writeAsString(database(id: '0' * 40));
      aacsKeyDbPathOverride = local.path;
      aacsHttpClientFactory = () async => throw StateError('must not fetch');
      await expectLater(
        loadAacsConfiguration(root.path),
        failure(AacsConfigurationError.discNotMatched),
      );
    },
  );

  test('missing explicit file reports missing configuration', () async {
    aacsKeyDbPathOverride = p.join(root.path, 'missing.cfg');
    await expectLater(
      loadAacsConfiguration(root.path),
      failure(AacsConfigurationError.missingConfiguration),
    );
  });

  for (final String directory in ['AACS2', 'BDSVM']) {
    test('unsupported protection $directory fails before network', () async {
      await Directory(p.join(root.path, directory)).create();
      aacsHttpClientFactory = () async => throw StateError('must not fetch');
      await expectLater(
        loadAacsConfiguration(root.path),
        failure(AacsConfigurationError.unsupportedDisc),
      );
    });
  }

  test(
    'downloads fixed HTTPS source once and persists private cache',
    () async {
      int requests = 0;
      aacsHttpClientFactory = () async => MockClient((request) async {
        requests++;
        expect(request.url.toString(), aacsConfigurationDownloadUrl);
        expect(
          aacsConfigurationDownloadUrl,
          'https://fvonline-db.bplaced.net/export/keydb_red.zip',
        );
        expect(request.url.scheme, 'https');
        expect(request.followRedirects, isFalse);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return http.Response.bytes(zip(database()), 200);
      });
      final results = await Future.wait([
        loadAacsConfiguration(root.path),
        loadAacsConfiguration(root.path),
      ]);
      expect(results[0].volumeUniqueKey, results[1].volumeUniqueKey);
      expect(requests, 1);
      aacsHttpClientFactory = null;
      expect(
        (await loadAacsConfiguration(root.path)).volumeUniqueKey.length,
        16,
      );
      expect(
        await File(p.join(root.path, 'aacs', 'keydb.cfg')).readAsString(),
        database(),
      );
    },
  );

  test('unknown disc does not refetch newly cached database', () async {
    int requests = 0;
    aacsHttpClientFactory = () async => MockClient((request) async {
      requests++;
      return http.Response.bytes(zip(database(id: '0' * 40)), 200);
    });
    for (int i = 0; i < 2; i++) {
      await expectLater(
        loadAacsConfiguration(root.path),
        failure(AacsConfigurationError.discNotMatched),
      );
    }
    expect(requests, 1);
  });

  for (final String name in ['../keydb.cfg', 'payload.exe']) {
    test(
      'rejects non-database archive entry $name without writing cache',
      () async {
        aacsHttpClientFactory = () async => MockClient(
          (request) async =>
              http.Response.bytes(zip(database(), name: name), 200),
        );
        await expectLater(
          loadAacsConfiguration(root.path),
          failure(AacsConfigurationError.invalidConfiguration),
        );
        expect(
          await File(p.join(root.path, 'aacs', 'keydb.cfg')).exists(),
          isFalse,
        );
      },
    );
  }

  test('rejects highly compressed payloads', () async {
    aacsHttpClientFactory = () async => MockClient(
      (request) async =>
          http.Response.bytes(zip('${database()}${'x' * 1000000}'), 200),
    );
    await expectLater(
      loadAacsConfiguration(root.path),
      failure(AacsConfigurationError.invalidConfiguration),
    );
  });

  test('rejects multiple archive entries before extraction', () async {
    final Archive archive = Archive()
      ..addFile(ArchiveFile.string('keydb.cfg', database()))
      ..addFile(ArchiveFile.string('extra.cfg', database()));
    aacsHttpClientFactory = () async => MockClient(
      (request) async =>
          http.Response.bytes(ZipEncoder().encode(archive)!, 200),
    );
    await expectLater(
      loadAacsConfiguration(root.path),
      failure(AacsConfigurationError.invalidConfiguration),
    );
  });

  test(
    'oversized declared expansion is rejected before decompression',
    () async {
      final Uint8List bytes = Uint8List.fromList(zip(database()));
      final ByteData data = ByteData.sublistView(bytes);
      for (int offset = 0; offset + 46 <= bytes.length; offset++) {
        if (data.getUint32(offset, Endian.little) == 0x02014b50) {
          data.setUint32(offset + 24, 128 * 1024 * 1024, Endian.little);
          break;
        }
      }
      aacsHttpClientFactory = () async =>
          MockClient((request) async => http.Response.bytes(bytes, 200));
      await expectLater(
        loadAacsConfiguration(root.path),
        failure(AacsConfigurationError.invalidConfiguration),
      );
    },
  );

  test('redirects and server failures report networkFailure', () async {
    aacsHttpClientFactory = () async => MockClient(
      (request) async => http.Response(
        '',
        302,
        headers: {'location': 'http://untrusted.example'},
      ),
    );
    await expectLater(
      loadAacsConfiguration(root.path),
      failure(AacsConfigurationError.networkFailure),
    );
  });

  test('invalid archive never exposes response contents', () async {
    aacsHttpClientFactory = () async => MockClient(
      (request) async =>
          http.Response.bytes(utf8.encode('private diagnostic payload'), 200),
    );
    try {
      await loadAacsConfiguration(root.path);
      fail('must throw');
    } on AacsConfigurationException catch (error) {
      expect(error.code, AacsConfigurationError.invalidConfiguration);
      expect(error.toString(), isNot(contains('private')));
    }
  });

  group('local fallback chain (a candidate that cannot be used is skipped)', () {
    const List<int> expectedVuk = <int>[
      0,
      17,
      34,
      51,
      68,
      85,
      102,
      119,
      136,
      153,
      170,
      187,
      204,
      221,
      238,
      255,
    ];

    /// 让 [file] 存在但读不了：Windows 用强制字节锁（他人句柄读即
    /// ERROR_LOCK_VIOLATION，也是「KEYDB 被别的程序占着」的真实形态——
    /// `openRead()` 在这种文件上会永远挂起，见 `_scanKeyDb`），其余平台 chmod 000。以 root 跑时 chmod 拦不住，
    /// 返回 null 由调用方跳过。返回值是还原函数。
    Future<Future<void> Function()?> makeUnreadable(File file) async {
      if (Platform.isWindows) {
        final RandomAccessFile handle = await file.open(mode: FileMode.append);
        await handle.lock(FileLock.exclusive);
        return () async {
          await handle.unlock();
          await handle.close();
        };
      }
      await Process.run('chmod', <String>['000', file.path]);
      Future<void> restore() async {
        await Process.run('chmod', <String>['644', file.path]);
      }

      try {
        await file.readAsBytes();
      } on FileSystemException {
        return restore;
      }
      await restore();
      return null;
    }

    test('unreadable standard KEYDB falls through to the app cache instead of '
        'reporting invalid configuration', () async {
      final File denied = File(p.join(root.path, 'denied', 'KEYDB.cfg'));
      await denied.parent.create();
      await denied.writeAsString(database(id: 'f' * 40));
      final File cache = File(p.join(root.path, 'aacs', 'keydb.cfg'));
      await cache.parent.create();
      await cache.writeAsString(database());
      aacsStandardConfigurationsForTesting = <String>[denied.path];
      final Future<void> Function()? restore = await makeUnreadable(denied);
      if (restore == null) {
        markTestSkipped('running as root: chmod cannot deny reads');
        return;
      }
      try {
        final result = await loadAacsConfiguration(root.path);
        expect(result.volumeUniqueKey, expectedVuk);
      } finally {
        await restore();
      }
    });

    test(
      'unreadable standard KEYDB does not stop the download fallback',
      () async {
        final File denied = File(p.join(root.path, 'denied', 'KEYDB.cfg'));
        await denied.parent.create();
        await denied.writeAsString(database());
        aacsStandardConfigurationsForTesting = <String>[denied.path];
        int fetches = 0;
        aacsHttpClientFactory = () async => MockClient((request) async {
          fetches++;
          return http.Response.bytes(zip(database()), 200);
        });
        final Future<void> Function()? restore = await makeUnreadable(denied);
        if (restore == null) {
          markTestSkipped('running as root: chmod cannot deny reads');
          return;
        }
        try {
          final result = await loadAacsConfiguration(root.path);
          expect(result.volumeUniqueKey, expectedVuk);
          expect(fetches, 1);
        } finally {
          await restore();
        }
      },
    );

    test(
      'only unreadable candidates and no download reports invalid configuration',
      () async {
        final File denied = File(p.join(root.path, 'denied', 'KEYDB.cfg'));
        await denied.parent.create();
        await denied.writeAsString(database());
        aacsStandardConfigurationsForTesting = <String>[denied.path];
        final Future<void> Function()? restore = await makeUnreadable(denied);
        if (restore == null) {
          markTestSkipped('running as root: chmod cannot deny reads');
          return;
        }
        try {
          await expectLater(
            loadAacsConfiguration(root.path),
            failure(AacsConfigurationError.invalidConfiguration),
          );
        } finally {
          await restore();
        }
      },
    );

    test(
      'local KEYDB larger than 64 MiB is scanned, not rejected',
      () async {
        // 完整版 KEYDB 可达上百 MB；旧实现整读 + 64 MiB 上限会把它判成配置无效。
        final File big = File(p.join(root.path, 'big', 'KEYDB.cfg'));
        await big.parent.create();
        final IOSink sink = big.openWrite();
        final String filler = database(id: '0' * 40);
        final String block = filler * ((1024 * 1024) ~/ filler.length + 1);
        for (int i = 0; i < 65; i++) {
          sink.write(block);
        }
        // 末条不带换行：走「文件尾残行」分支；填充行长度不整除 1 MiB 分块，
        // 大量条目跨块边界。
        sink.write(database().trimRight());
        await sink.close();
        expect(await big.length(), greaterThan(64 * 1024 * 1024));
        aacsStandardConfigurationsForTesting = <String>[big.path];
        final result = await loadAacsConfiguration(root.path);
        expect(result.volumeUniqueKey, expectedVuk);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}
