import 'dart:io';

/// Locates the `flutter` / `dart` launchers the repo tools spawn.
///
/// Same precedence as `tool/bootstrap.ps1`'s `Resolve-FlutterExe`, minus the
/// version-directory guessing (the tools are already *running* on an SDK):
///
///  1. `FUSHI_FLUTTER` — explicit path to a flutter launcher (bootstrap's
///     override; the dart launcher sits next to it).
///  2. `FLUTTER_ROOT` — the SDK root the flutter tool exports to its children.
///  3. The Flutter SDK whose dart is running this tool
///     (`<sdk>/bin/cache/dart-sdk/bin/dart[.exe]`).
///  4. The bare command name, resolved through `PATH` by the OS.
///
/// A candidate only counts when the launcher file actually exists, so a stale
/// variable falls through instead of producing a "file not found" spawn.
/// No machine-specific path is baked in: the SDK pinned by `fushi/.fvmrc` is
/// whichever one the caller runs on.
class FlutterSdkExecutables {
  FlutterSdkExecutables({
    required this.environment,
    required this.resolvedExecutable,
    required this.isWindows,
    required this.fileExists,
  });

  /// Reads the real process environment and file system.
  factory FlutterSdkExecutables.current() => FlutterSdkExecutables(
    environment: Platform.environment,
    resolvedExecutable: Platform.resolvedExecutable,
    isWindows: Platform.isWindows,
    fileExists: (String path) => File(path).existsSync(),
  );

  final Map<String, String> environment;
  final String resolvedExecutable;
  final bool isWindows;
  final bool Function(String path) fileExists;

  String _launcher(String name) => isWindows ? '$name.bat' : name;

  String _join(String root, String name) {
    final String trimmed = root.replaceAll(RegExp(r'[\\/]+$'), '');
    return _native('$trimmed/bin/${_launcher(name)}');
  }

  String _native(String path) =>
      isWindows ? path.replaceAll('/', r'\') : path.replaceAll(r'\', '/');

  /// The SDK root of the dart running this tool, when it is a Flutter SDK's
  /// bundled dart (`<sdk>/bin/cache/dart-sdk/bin/dart`).
  String? get _runningSdkRoot {
    final List<String> seg = resolvedExecutable
        .replaceAll(r'\', '/')
        .split('/');
    final int cache = seg.lastIndexOf('cache');
    if (cache < 2 || seg[cache - 1] != 'bin') return null;
    if (cache + 1 >= seg.length || seg[cache + 1] != 'dart-sdk') return null;
    return seg.sublist(0, cache - 1).join('/');
  }

  /// SDK roots in precedence order (FUSHI_FLUTTER's SDK, FLUTTER_ROOT, the
  /// running SDK); empty or missing entries are skipped.
  List<String> get _sdkRoots {
    final List<String> roots = <String>[];
    final String? override = environment['FUSHI_FLUTTER'];
    if (override != null && override.isNotEmpty) {
      final List<String> seg = override.replaceAll(r'\', '/').split('/');
      if (seg.length >= 3) roots.add(seg.sublist(0, seg.length - 2).join('/'));
    }
    final String? flutterRoot = environment['FLUTTER_ROOT'];
    if (flutterRoot != null && flutterRoot.isNotEmpty) roots.add(flutterRoot);
    final String? running = _runningSdkRoot;
    if (running != null) roots.add(running);
    return roots;
  }

  /// Path of the flutter launcher, or `flutter` for a PATH lookup.
  String flutter() {
    final String? override = environment['FUSHI_FLUTTER'];
    if (override != null && override.isNotEmpty && fileExists(override)) {
      return _native(override);
    }
    return _firstExisting('flutter') ?? 'flutter';
  }

  /// Path of the dart launcher from the same SDK as [flutter]; falls back to
  /// the dart running this tool, then `dart` for a PATH lookup.
  String dart() {
    final String? sdkDart = _firstExisting('dart');
    if (sdkDart != null) return sdkDart;
    if (resolvedExecutable.isNotEmpty && fileExists(resolvedExecutable)) {
      return resolvedExecutable;
    }
    return 'dart';
  }

  String? _firstExisting(String name) {
    for (final String root in _sdkRoots) {
      final String candidate = _join(root, name);
      if (fileExists(candidate)) return candidate;
    }
    return null;
  }

  /// Maps a bare `flutter` / `dart` command to its resolved launcher; any
  /// other command is returned unchanged.
  String resolveCommand(String executable) => switch (executable) {
    'flutter' => flutter(),
    'dart' => dart(),
    _ => executable,
  };
}
