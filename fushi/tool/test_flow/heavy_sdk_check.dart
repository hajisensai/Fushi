// Fail-fast SDK check for tool/heavy.dart.
//
// Why (2026-10-25): a `flutter test` started with whatever `flutter` was first
// on PATH (an older 3.44 SDK on this machine) queued for a slot, compiled for
// 155 s and only then failed every suite on "language version 3.13 is too
// high" -- and its native-asset build left an old-format
// `.dart_tool/hooks_runner` cache behind, so the next run with the right SDK
// failed too ("Invalid kernel binary format version") until it was deleted by
// hand. The pinned version is one file read away (`fushi/.fvmrc`) and the SDK's
// own version is another (`<sdk>/bin/cache/flutter.version.json`), so the
// wrapper checks both before it queues and refuses a mismatched SDK outright.
import 'dart:convert';
import 'dart:io';

import 'flutter_sdk_executables.dart';

/// The Flutter version `fushi/.fvmrc` pins, or null when it cannot be read.
String? readPinnedFlutterVersion(String checkoutRoot) {
  final File fvmrc = File('$checkoutRoot/fushi/.fvmrc');
  if (!fvmrc.existsSync()) return null;
  try {
    final Object? json = jsonDecode(fvmrc.readAsStringSync());
    final Object? v = json is Map ? json['flutter'] : null;
    return v is String ? v : null;
  } on FormatException {
    return null;
  }
}

/// The SDK root of a `flutter` / `dart` launcher path
/// (`<root>/bin/flutter[.bat]`, `<root>/bin/dart[.bat]`), or null when the
/// path is not shaped like one.
String? flutterSdkRootOfLauncher(String launcher) {
  final List<String> seg = launcher.replaceAll(r'\', '/').split('/');
  if (seg.length < 3) return null;
  final String name = seg.last.toLowerCase();
  if (!<String>{
    'flutter',
    'flutter.bat',
    'dart',
    'dart.bat',
    'dart.exe',
  }.contains(name)) {
    return null;
  }
  if (seg[seg.length - 2] != 'bin') return null;
  return seg.sublist(0, seg.length - 2).join('/');
}

/// The framework version recorded in `<root>/bin/cache/flutter.version.json`,
/// or null when that SDK has none (a standalone Dart SDK, a never-run SDK).
String? readFlutterSdkVersion(String sdkRoot) {
  final File f = File('$sdkRoot/bin/cache/flutter.version.json');
  if (!f.existsSync()) return null;
  try {
    final Object? json = jsonDecode(f.readAsStringSync());
    final Object? v = json is Map ? json['frameworkVersion'] : null;
    return v is String ? v : null;
  } on FormatException {
    return null;
  }
}

/// First `name` launcher on `PATH`, or null.
String? findOnPath(
  String name, {
  required Map<String, String> environment,
  required bool isWindows,
  required bool Function(String path) fileExists,
}) {
  final String path = environment['PATH'] ?? environment['Path'] ?? '';
  final List<String> exts = isWindows
      ? <String>['.bat', '.exe', '.cmd', '']
      : <String>[''];
  for (final String dir in path.split(isWindows ? ';' : ':')) {
    if (dir.isEmpty) continue;
    for (final String ext in exts) {
      final String candidate = '$dir/$name$ext';
      if (fileExists(candidate)) return candidate;
    }
  }
  return null;
}

/// Result of checking a wrapped command's SDK against the pinned version.
class HeavySdkCheck {
  const HeavySdkCheck({required this.command, this.error});

  /// The command to run: a bare `flutter` / `dart` is replaced by the launcher
  /// that was checked, so the run uses exactly that SDK.
  final List<String> command;

  /// Non-null when the command must not run (wrong SDK version).
  final String? error;
}

/// Resolves a bare `flutter` / `dart` the way the repo tools do
/// ([FlutterSdkExecutables]: FUSHI_FLUTTER, FLUTTER_ROOT, the SDK running this
/// tool, then PATH) and compares that SDK's version with [pinned]. Commands
/// other than flutter / dart (gradlew, fvm, powershell...) pass unchanged; so
/// does an SDK whose version cannot be read (nothing to compare).
HeavySdkCheck checkHeavyCommandSdk(
  List<String> command, {
  required String? pinned,
  FlutterSdkExecutables? executables,
  String? Function(String sdkRoot)? sdkVersionOf,
  String? Function(String name)? pathLookup,
}) {
  if (command.isEmpty || pinned == null) {
    return HeavySdkCheck(command: command);
  }
  final String first = command.first;
  final bool bare = first == 'flutter' || first == 'dart';
  String launcher = first;
  if (bare) {
    final FlutterSdkExecutables exe =
        executables ?? FlutterSdkExecutables.current();
    launcher = exe.resolveCommand(first);
    if (launcher == first) {
      launcher =
          (pathLookup ??
              (String n) => findOnPath(
                n,
                environment: Platform.environment,
                isWindows: Platform.isWindows,
                fileExists: (String p) => File(p).existsSync(),
              ))(first) ??
          first;
    }
  }
  final String? root = flutterSdkRootOfLauncher(launcher);
  if (root == null) return HeavySdkCheck(command: command);
  final String? actual = (sdkVersionOf ?? readFlutterSdkVersion)(root);
  final List<String> resolved = bare
      ? <String>[launcher, ...command.skip(1)]
      : command;
  if (actual == null || actual == pinned) {
    return HeavySdkCheck(command: resolved);
  }
  return HeavySdkCheck(
    command: resolved,
    error:
        'heavy: refusing to run with Flutter $actual ($launcher); this repo '
        'pins $pinned (fushi/.fvmrc). A mismatched SDK compiles for minutes '
        'and then fails, and leaves .dart_tool/hooks_runner unusable for the '
        'right one. Run the pinned SDK\'s dart '
        '(<sdk $pinned>/bin/dart tool/heavy.dart -- ...), put it first on '
        'PATH, or set FUSHI_FLUTTER to its bin/flutter launcher.',
  );
}
