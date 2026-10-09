import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/bluray_java_runtime.dart';
import 'package:path/path.dart' as p;

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

  test('installer command is inline and quotes every value as a literal', () {
    final String command = bdjInstallerCommand(
      script: r"C:\Users\O'Neil\bdj\bdj_runtime.ps1",
      action: 'Install',
      bundle: r"C:\Users\O'Neil\bdj",
      startSignal: r'C:\Temp\fushi-bdj-owner-1\ready',
      archive: r'C:\Temp\$env:x.zip',
      stagingDirectory: r'C:\Temp\.bdj-install-0',
    );
    expect(command, isNot(contains('ExecutionPolicy')));
    expect(
      command,
      '& ([scriptblock]::Create([IO.File]::ReadAllText('
      r"'C:\Users\O''Neil\bdj\bdj_runtime.ps1'))) -Action 'Install' "
      r"-Bundle 'C:\Users\O''Neil\bdj' "
      r"-StartSignal 'C:\Temp\fushi-bdj-owner-1\ready' "
      r"-Archive 'C:\Temp\$env:x.zip' "
      r"-StagingDirectory 'C:\Temp\.bdj-install-0'",
    );
  });

  // The command only matters if PowerShell binds it exactly like `-File` did:
  // typed parameters, a thrown error → exit 1, and the script's own exit code.
  test(
    'powershell binds the inline installer command like -File',
    () async {
      final Directory dir = await Directory.systemTemp.createTemp(
        "fushi bdj o'probe ",
      );
      addTearDown(() => dir.delete(recursive: true));
      final File script = File(p.join(dir.path, 'probe.ps1'));
      await script.writeAsString(r'''
[CmdletBinding()]
param(
    [ValidateSet('Install', 'Probe', 'Run')][string]$Action = 'Probe',
    [string]$Bundle,
    [string]$Archive,
    [string]$StartSignal
)
$ErrorActionPreference = 'Stop'
[ordered]@{ action = $Action; bundle = $Bundle; signal = $StartSignal; archive = $Archive } | ConvertTo-Json -Compress
if ($Action -eq 'Install') { throw 'boom' }
exit 7
''');
      Future<ProcessResult> run(String action) =>
          Process.run('powershell.exe', <String>[
            '-NoProfile',
            '-NonInteractive',
            '-Command',
            bdjInstallerCommand(
              script: script.path,
              action: action,
              bundle: dir.path,
              startSignal: p.join(dir.path, 'ready'),
              archive: r'C:\a $x.zip',
            ),
          ]);

      final ProcessResult probe = await run('Probe');
      expect(probe.exitCode, 7, reason: '${probe.stderr}');
      final Map<String, dynamic> bound =
          jsonDecode((probe.stdout as String).trim()) as Map<String, dynamic>;
      expect(bound, <String, Object>{
        'action': 'Probe',
        'bundle': dir.path,
        'signal': p.join(dir.path, 'ready'),
        'archive': r'C:\a $x.zip',
      });

      final ProcessResult install = await run('Install');
      expect(install.exitCode, 1, reason: '${install.stderr}');
      expect(install.stderr as String, contains('boom'));
    },
    skip: Platform.isWindows ? false : 'powershell.exe is Windows-only',
    timeout: const Timeout(Duration(minutes: 2)),
  );

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
