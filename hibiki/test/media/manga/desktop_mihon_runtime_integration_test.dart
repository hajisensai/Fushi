import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/mihon/desktop_mihon_runtime.dart';

void main() {
  final Directory resourceDirectory = Directory(
    'build/windows/x64/runner/Debug/mihon_bridge',
  );
  final bool bridgeAvailable = Platform.isWindows &&
      File(
        '${resourceDirectory.path}/runtime/bin/java.exe',
      ).existsSync() &&
      File(
        '${resourceDirectory.path}/m-extension-server.jar',
      ).existsSync();

  test(
    'bundled Java bridge is stopped without a residual process',
    () async {
      final Directory dataDirectory =
          await Directory.systemTemp.createTemp('hibiki-mihon-runtime-test-');
      final DesktopMihonRuntime runtime = DesktopMihonRuntime(
        dataDirectory: dataDirectory,
        resourceDirectory: resourceDirectory,
      );
      try {
        final capabilities = await runtime.getCapabilities();
        expect(capabilities.isUsable, isTrue);
        final int pid = runtime.processId!;

        await runtime.dispose();

        final ProcessResult lookup = await Process.run(
          'powershell.exe',
          <String>[
            '-NoProfile',
            '-NonInteractive',
            '-Command',
            'if (Get-Process -Id $pid -ErrorAction SilentlyContinue) '
                '{ exit 1 }',
          ],
        );
        expect(
          lookup.exitCode,
          0,
          reason: 'Mihon Java PID $pid remained after runtime.dispose()',
        );
      } finally {
        await runtime.dispose();
        if (dataDirectory.existsSync()) {
          await dataDirectory.delete(recursive: true);
        }
      }
    },
    skip: bridgeAvailable
        ? false
        : 'Windows debug bundle with Java/M-Extension-Server is unavailable',
  );
}
