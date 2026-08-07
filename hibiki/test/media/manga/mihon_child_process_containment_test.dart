import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/mihon/mihon_child_process_containment.dart';

void main() {
  test(
    'Windows containment terminates only its exact child when closed',
    () async {
      final Process child = await Process.start(
        'powershell.exe',
        <String>[
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          'Start-Sleep -Seconds 30',
        ],
      );
      final MihonChildProcessContainment containment =
          MihonChildProcessContainment.platform();
      addTearDown(() async {
        containment.close();
        child.kill();
        try {
          await child.exitCode.timeout(const Duration(seconds: 2));
        } on TimeoutException {
          // The assertion below reports a failed containment more clearly.
        }
      });

      containment.attach(child.pid);
      containment.close();

      await child.exitCode.timeout(const Duration(seconds: 2));
    },
    skip: !Platform.isWindows,
  );
}
