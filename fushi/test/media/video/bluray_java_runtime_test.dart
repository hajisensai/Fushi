import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/bluray_java_runtime.dart';

Map<String, Object> manifest({
  String url = 'https://example.com/jre.zip',
  String? hash,
}) => <String, Object>{
  'schema': 1,
  'runtime': <String, Object>{
    'url': url,
    'sha256': hash ?? List<String>.filled(64, 'A').join(),
    'componentRootSuffix': 'Fushi/components/bdj/test-runtime',
  },
};

void main() {
  test('pinned archive manifest keeps URL and normalizes SHA256', () {
    final BlurayJavaArchive archive = BlurayJavaArchive.fromManifest(
      manifest(),
    );
    expect(archive.url.toString(), 'https://example.com/jre.zip');
    expect(archive.sha256, List<String>.filled(64, 'a').join());
  });

  test(
    'unversioned/malformed manifests cannot trigger runtime installation',
    () {
      for (final Object? value in <Object?>[
        null,
        <Object>[],
        <String, Object>{},
        <String, Object>{'schema': 2, 'runtime': manifest()['runtime']!},
        <String, Object>{
          'schema': 1,
          'runtime': <String, Object>{'url': 123},
        },
      ]) {
        expect(
          () => BlurayJavaArchive.fromManifest(value),
          throwsA(isA<BlurayJavaRuntimeException>()),
        );
      }
    },
  );

  test('credentials, local files and plaintext download URLs are rejected', () {
    for (final String url in <String>[
      'http://example.com/jre.zip',
      'file:///C:/jre.zip',
      'https://name:secret@example.com/jre.zip',
      'https:///jre.zip',
    ]) {
      expect(
        () => BlurayJavaArchive.fromManifest(manifest(url: url)),
        throwsA(isA<BlurayJavaRuntimeException>()),
      );
    }
  });

  test('a missing or malformed checksum cannot authorize executing Java', () {
    for (final String hash in <String>['', 'abc', 'g' * 64, '0' * 63]) {
      expect(
        () => BlurayJavaArchive.fromManifest(manifest(hash: hash)),
        throwsA(isA<BlurayJavaRuntimeException>()),
      );
    }
  });

  test('component destination stays within the private BD-J namespace', () {
    for (final String path in <String>[
      '../../other',
      'C:/Windows/System32',
      'Fushi/components/bdj/../other',
      'Fushi/components/other/runtime',
    ]) {
      final Map<String, Object> data = manifest();
      (data['runtime']! as Map<String, Object>)['componentRootSuffix'] = path;
      expect(
        () => BlurayJavaArchive.fromManifest(data),
        throwsA(isA<BlurayJavaRuntimeException>()),
      );
    }
  });

  test('missing bundled installer is an unavailable capability', () async {
    final BlurayJavaRuntimeManager manager = BlurayJavaRuntimeManager(
      bundleDirectory: 'not-a-bundled-runtime',
    );
    expect(manager.canInstall, isFalse);
    expect(await manager.probeJavaHome(), isNull);
    await expectLater(
      manager.install(),
      throwsA(isA<BlurayJavaRuntimeException>()),
    );
  });
}
