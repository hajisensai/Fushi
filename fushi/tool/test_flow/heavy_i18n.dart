// fushi/lib/i18n/strings.g.dart is not tracked (fushi/tool/gen_i18n.dart
// generates it from the i18n json). A checkout / merge deletes or outdates
// it, so tool/heavy.dart regenerates it before a command that compiles the
// app runs on this machine (an offloaded run's worker regenerates its own in
// worker_prepare.sh). gen_i18n.dart is stamped: when nothing changed it only
// hashes its inputs and exits.
import 'dart:convert';
import 'dart:io';

import 'heavy_sdk_check.dart' show flutterSdkRootOfLauncher;

String _launcherName(String exe) {
  final String last = exe.replaceAll(r'\', '/').split('/').last.toLowerCase();
  return last.replaceFirst(RegExp(r'\.(bat|exe|cmd)$'), '');
}

String _norm(String p, bool isWindows) {
  final String s = p.replaceAll(r'\', '/').replaceFirst(RegExp(r'/+$'), '');
  return isWindows ? s.toLowerCase() : s;
}

/// Whether [command], about to run here from [cwd], compiles code that
/// imports `strings.g.dart`: a `flutter analyze|test|build|run|drive|attach|
/// assemble`, a `dart analyze|test|run`, a `dart <script>.dart` (the test
/// runners wrap flutter test) or a gradle build, run inside
/// `<checkout>/fushi`. `pub` / `format` / `--version` and anything run
/// elsewhere (packages/<name>/ does not depend on the app) do not.
bool heavyCommandNeedsI18n(
  List<String> command, {
  required String cwd,
  required String checkout,
  required bool isWindows,
}) {
  if (command.isEmpty) return false;
  final String app = _norm('$checkout/fushi', isWindows);
  final String here = _norm(cwd, isWindows);
  if (here != app && !here.startsWith('$app/')) return false;
  final String name = _launcherName(command.first);
  final String? sub = command
      .skip(1)
      .cast<String?>()
      .firstWhere((String? a) => !a!.startsWith('-'), orElse: () => null);
  switch (name) {
    case 'flutter':
      return const <String>{
        'analyze',
        'test',
        'build',
        'run',
        'drive',
        'attach',
        'assemble',
      }.contains(sub);
    case 'dart':
      if (sub == null) return false;
      if (const <String>{'analyze', 'test', 'run'}.contains(sub)) return true;
      // gen_i18n.dart itself needs nothing generated first.
      return sub.endsWith('.dart') &&
          sub.replaceAll(r'\', '/').split('/').last != 'gen_i18n.dart';
    case 'gradlew':
      return true;
    case 'powershell':
    case 'pwsh':
      // run_windows_itest.ps1 runs `flutter test -d windows` under fushi/
      // (docs/agent/heavy-lease.md routes it through heavy).
      return command
          .skip(1)
          .any(
            (String a) =>
                a.replaceAll(r'\', '/').split('/').last ==
                'run_windows_itest.ps1',
          );
  }
  return false;
}

/// The Flutter SDK root `flutter pub get` recorded for this checkout
/// (`flutterRoot` in `<checkout>/.dart_tool/package_config.json`), or null.
String? pubGetFlutterRoot(String checkout, {String? Function(String)? read}) {
  final String? text = (read ?? _readOrNull)(
    '$checkout/.dart_tool/package_config.json',
  );
  if (text == null) return null;
  try {
    final Object? json = jsonDecode(text);
    if (json is! Map) return null;
    final Object? root = json['flutterRoot'];
    if (root is! String) return null;
    return Uri.parse(
      root,
    ).toFilePath(windows: false).replaceFirst(RegExp(r'^/(?=[A-Za-z]:)'), '');
  } on FormatException {
    return null;
  }
}

String? _readOrNull(String path) {
  final File f = File(path);
  return f.existsSync() ? f.readAsStringSync() : null;
}

/// The `dart` that runs gen_i18n.dart for [command]: that of the SDK its
/// flutter / dart launcher belongs to (the one heavy_sdk_check matched
/// against fushi/.fvmrc), else of the SDK pub get used, else [fallback] (the
/// dart running heavy.dart). The same SDK as the command matters: the stamp
/// keys on the Dart version, and its `dart format` decides the bytes.
String heavyI18nDart(
  List<String> command, {
  required String checkout,
  required String fallback,
  required bool isWindows,
  bool Function(String path)? fileExists,
  String? Function(String path)? read,
}) {
  final bool Function(String) exists =
      fileExists ?? (String p) => File(p).existsSync();
  final String? launcherRoot = command.isEmpty
      ? null
      : flutterSdkRootOfLauncher(command.first);
  final String? pubRoot = pubGetFlutterRoot(checkout, read: read);
  final List<String> roots = <String>[
    if (launcherRoot != null) launcherRoot,
    if (pubRoot != null) pubRoot,
  ];
  final String exe = isWindows ? 'dart.exe' : 'dart';
  for (final String root in roots) {
    for (final String candidate in <String>[
      '$root/bin/cache/dart-sdk/bin/$exe',
      // [root] may itself be the Dart SDK (a launcher `.../dart-sdk/bin/dart`).
      '$root/bin/$exe',
    ]) {
      if (exists(candidate)) return candidate;
    }
  }
  return fallback;
}
