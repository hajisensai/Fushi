// dist_test worker (Windows): link each Windows plugin into
// windows/flutter/ephemeral/.plugin_symlinks with a junction, before
// `flutter build windows` makes directory symlinks there.
//   dart fushi/tool/dist_test/plugin_junctions.dart <app dir>
//
// Why: the Flutter tool only remakes these links when
// .flutter-plugins-dependencies changes, so a link left pointing at another
// pub cache stays; and a directory symlink needs Developer Mode or the
// symlink privilege on the worker account, a junction nothing. The Flutter
// tool keeps a link that is already there, so the build goes on with these.
// worker_build.sh first checks that native programs can go through a
// junction at all (on wight-win, 2026-10-30, they could not). Plain dart:io
// and dart:convert: this runs before anything else is set up.
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('usage: plugin_junctions.dart <app dir>');
    exit(2);
  }
  final String app = args.single;
  final File deps = File('$app/.flutter-plugins-dependencies');
  if (!deps.existsSync()) {
    stderr.writeln('error: no ${deps.path} (pub get has not run)');
    exit(1);
  }
  final Object? info = jsonDecode(deps.readAsStringSync());
  final Object? byPlatform = info is Map<String, Object?>
      ? info['plugins']
      : null;
  final Object? plugins = byPlatform is Map<String, Object?>
      ? byPlatform['windows']
      : null;
  final Directory links = Directory(
    '$app/windows/flutter/ephemeral/.plugin_symlinks',
  );
  // Start fresh, as the Flutter tool does after a pub get: a link left from
  // another pub cache would be kept as it is. Deleting a link never touches
  // what it points to.
  if (links.existsSync()) {
    for (final FileSystemEntity e in links.listSync(followLinks: false)) {
      await _removeLink(e.path);
    }
  } else {
    links.createSync(recursive: true);
  }
  for (final Object? p in plugins is List<Object?> ? plugins : <Object?>[]) {
    if (p is! Map<String, Object?>) continue;
    final Object? name = p['name'];
    final Object? path = p['path'];
    if (name is! String || path is! String) continue;
    if (!RegExp(r'^[A-Za-z0-9_]+$').hasMatch(name)) {
      stderr.writeln('error: bad plugin name "$name"');
      exit(1);
    }
    final ProcessResult r = await Process.run('cmd.exe', <String>[
      '/c',
      'mklink',
      '/J',
      '${links.path}\\$name'.replaceAll('/', '\\'),
      // No trailing separator: quoted for cmd, it would escape the quote.
      path.replaceAll('/', '\\').replaceFirst(RegExp(r'\\+$'), ''),
    ]);
    if (r.exitCode != 0) {
      stderr.writeln('error: junction for $name: ${r.stdout}${r.stderr}');
      exit(1);
    }
  }
}

/// Removes a link (symlink or junction) and only the link: rmdir fails on a
/// real directory that is not empty.
Future<void> _removeLink(String path) async {
  final ProcessResult r = await Process.run('cmd.exe', <String>[
    '/c',
    'rmdir',
    path.replaceAll('/', '\\'),
  ]);
  if (r.exitCode != 0) {
    stderr.writeln('error: could not remove $path: ${r.stdout}${r.stderr}');
    exit(1);
  }
}
