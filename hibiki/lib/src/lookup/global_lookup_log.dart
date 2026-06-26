// TODO-617 global lookup — best-effort file logger for desktop diagnostics.
//
// The runner is a WIN32 GUI exe with no console, so debugPrint goes nowhere
// when launched standalone. This appends timestamped lines to a fixed file
// (<systemTemp>/hibiki_glookup.log) so the overlay trigger can be diagnosed
// without attaching a debugger. Temporary diagnostic aid for the M0/M1 bring-up.

import 'dart:io';

File? _logFile;

File _resolveLogFile() => _logFile ??= File(
    '${Directory.systemTemp.path}${Platform.pathSeparator}hibiki_glookup.log');

void glog(String message) {
  try {
    _resolveLogFile().writeAsStringSync(
      '${DateTime.now().toIso8601String()}  $message\n',
      mode: FileMode.append,
      flush: true,
    );
  } catch (_) {
    // Never let logging break the trigger.
  }
}
