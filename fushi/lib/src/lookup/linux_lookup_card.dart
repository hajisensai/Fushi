import 'dart:io';

import 'package:fushi/src/floating_ball/floating_ball_config.dart'
    show linuxSessionIsX11;
import 'package:path/path.dart' as p;

/// File name of the Linux global lookup card helper (linux/lookup_card/). The
/// runner forwards `app.fushi.reader/global_lookup` to it; it sits next to the
/// `fushi` executable in the bundle.
const String kLinuxLookupCardHelper = 'fushi_lookup_card';

/// Whether this Linux session can show the global lookup card: the helper
/// places its own window, which only X11 allows, and it is only built where
/// WebKitGTK 4.1 was available, so a bundle without it simply has no card.
///
/// [context] is the path style (defaults to the running platform's; tests pass
/// `p.posix` so the Linux layout can be checked on any CI runner).
bool linuxLookupCardAvailable({
  required Map<String, String> environment,
  required String resolvedExecutable,
  bool Function(String path)? fileExists,
  p.Context? context,
}) {
  if (!linuxSessionIsX11(environment)) return false;
  final p.Context ctx = context ?? p.context;
  final String helper = ctx.join(
    ctx.dirname(resolvedExecutable),
    kLinuxLookupCardHelper,
  );
  return (fileExists ?? (String path) => File(path).existsSync())(helper);
}

/// [linuxLookupCardAvailable] for this process (the answer cannot change while
/// it runs).
final bool linuxLookupCardAvailableHere =
    Platform.isLinux &&
    linuxLookupCardAvailable(
      environment: Platform.environment,
      resolvedExecutable: Platform.resolvedExecutable,
    );
