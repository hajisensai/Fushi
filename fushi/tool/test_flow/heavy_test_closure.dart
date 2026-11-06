// How much source a `flutter test` run compiles: the union of the test files'
// transitive imports (every package, resolved through
// .dart_tool/package_config.json; dart: libraries are the SDK baseline and
// not counted). heavy.dart books a test run's memory from it
// (heavy_budget.dart testBookMb): frontend_server holds that whole program,
// and every flutter_tester loads its own test's kernel of it.
//
// Regex-level on purpose: it runs before every leased test, has to finish in
// a second or two, and only needs a size, not exact resolution.

import 'dart:convert';
import 'dart:io';

// Directives start at column 0 (dart format); a leading `\s*` made the
// multi-line scan backtrack over every blank line and cost seconds.
final RegExp _directive = RegExp(
  r'''^(?:import|export|part)\s+['"]([^'"]+)['"]''',
  multiLine: true,
);

/// Flags of `flutter test` that take a separate value (so the value is not a
/// test target).
const Set<String> _valueFlags = <String>{
  '--name',
  '-n',
  '--plain-name',
  '--tags',
  '-t',
  '--exclude-tags',
  '-x',
  '--reporter',
  '-r',
  '--file-reporter',
  '--dart-define',
  '--dart-define-from-file',
  '--concurrency',
  '-j',
  '--shard-index',
  '--total-shards',
  '--test-randomize-ordering-seed',
  '--timeout',
  '--coverage-path',
  '--device-id',
  '-d',
  '--flavor',
  '--platform',
};

/// The test files a `flutter test` / `dart test` argv names, relative to its
/// working directory, or null when it runs whole directories or the default
/// `test/` (no cheap size: the caller books the ceiling).
List<String>? testTargetsOf(List<String> argv) {
  final int verb = argv.indexWhere((String a) => a.toLowerCase() == 'test', 1);
  if (verb < 0) return null;
  final List<String> out = <String>[];
  for (int i = verb + 1; i < argv.length; i++) {
    final String a = argv[i];
    if (a.startsWith('-')) {
      if (_valueFlags.contains(a)) i++;
      continue;
    }
    // `path/to/a_test.dart?line=12` and `a_test.dart:12` name one file.
    String path = a.split('?').first;
    final int colon = path.lastIndexOf(':');
    if (colon > 1 && int.tryParse(path.substring(colon + 1)) != null) {
      path = path.substring(0, colon);
    }
    if (!path.endsWith('.dart')) return null; // a directory
    out.add(path);
  }
  return out.isEmpty ? null : out;
}

String _slashes(String path) => path.replaceAll(r'\', '/');

/// [base] joined with the relative [rel], `.` / `..` folded, `/`-separated.
String _join(String base, String rel) {
  final List<String> out = <String>[];
  for (final String seg in (rel.isEmpty ? base : '$base/$rel').split('/')) {
    if (seg == '..') {
      if (out.length > 1) out.removeLast();
    } else if (seg != '.' && (seg.isNotEmpty || out.isEmpty)) {
      out.add(seg);
    }
  }
  return out.join('/');
}

/// `package:<name>/` → that package's lib directory, from the nearest
/// .dart_tool/package_config.json at or above [dir]; null when there is none.
/// The package table plus the workspace root (the directory holding
/// `.dart_tool/package_config.json`).
typedef _PackageTable = ({Map<String, String> libs, String workspace});

_PackageTable? _packageLibs(String dir) {
  Directory cur = Directory(dir).absolute;
  while (true) {
    final File config = File('${cur.path}/.dart_tool/package_config.json');
    if (config.existsSync()) {
      final Object? json = jsonDecode(config.readAsStringSync());
      if (json is! Map<String, Object?>) return null;
      final String workspace = _join(_slashes(cur.absolute.path), '');
      final Map<String, String> out = <String, String>{};
      final Uri base = config.parent.uri;
      for (final Object? p
          in (json['packages'] as List<Object?>?) ?? <Object?>[]) {
        if (p is! Map<String, Object?>) continue;
        final String? name = p['name'] as String?;
        final String? root = p['rootUri'] as String?;
        if (name == null || root == null) continue;
        final String pkgUri = (p['packageUri'] as String?) ?? 'lib/';
        final Uri rootUri = base.resolve(root.endsWith('/') ? root : '$root/');
        out[name] = _slashes(
          rootUri.resolve(pkgUri).toFilePath(),
        ).replaceFirst(RegExp(r'/$'), '');
      }
      return (libs: out, workspace: workspace);
    }
    final Directory parent = cur.parent;
    if (parent.path == cur.path) return null;
    cur = parent;
  }
}

/// The part of [path] that holds its directives. They precede every
/// declaration, so the first 16 KiB almost always covers them; a file whose
/// directives run up to that edge is read whole. Scanning whole files instead
/// (multi-megabyte strings.g.dart, drift databases) made a full-app closure
/// take ~10 s.
String? _directiveHead(String path) {
  const int head = 16 * 1024;
  RandomAccessFile? f;
  try {
    f = File(path).openSync();
    final List<int> bytes = f.readSync(head);
    String src = utf8.decode(bytes, allowMalformed: true);
    if (bytes.length == head) {
      final Iterable<RegExpMatch> found = _directive.allMatches(src);
      if (found.isNotEmpty && found.last.end > head - 2048) {
        src = utf8.decode(<int>[
          ...bytes,
          ...f.readSync(f.lengthSync()),
        ], allowMalformed: true);
      }
    }
    return src;
  } on FileSystemException {
    return null;
  } finally {
    f?.closeSync();
  }
}

/// Number of Dart files the [targets] (relative to [cwd]) pull in, or null
/// when a target or the package config cannot be read.
///
/// [edgeCache] (a JSON file) remembers the resolved imports of files outside
/// the workspace: pub-cache and SDK paths carry their version, so their
/// imports never change, and they are ~3/4 of a full-app closure. Reading
/// them on every leased run cost seconds on a busy desktop.
int? testClosureFiles(String cwd, List<String> targets, {File? edgeCache}) {
  final _PackageTable? table = _packageLibs(cwd);
  if (table == null) return null;
  final Map<String, String> libs = table.libs;
  final String workspacePrefix = '${table.workspace}/';
  final Map<String, List<String>> cache = _readEdgeCache(edgeCache);
  bool cacheDirty = false;
  final Set<String> seen = <String>{};
  final List<String> todo = <String>[];
  for (final String t in targets) {
    final File f = File(t).isAbsolute ? File(t) : File('$cwd/$t');
    if (!f.existsSync()) return null;
    final String path = _join(_slashes(f.absolute.path), '');
    if (seen.add(path)) todo.add(path);
  }
  while (todo.isNotEmpty) {
    final String path = todo.removeLast();
    final bool immutable = !path.startsWith(workspacePrefix);
    List<String>? edges = immutable ? cache[path] : null;
    if (edges == null) {
      edges = _edgesOf(path, libs);
      if (edges == null) continue; // generated file not there yet, or a stub
      if (immutable) {
        cache[path] = edges;
        cacheDirty = true;
      }
    }
    for (final String target in edges) {
      if (seen.add(target)) todo.add(target);
    }
  }
  if (cacheDirty && edgeCache != null) _writeEdgeCache(edgeCache, cache);
  return seen.length;
}

/// The files [path] imports, exports or includes as parts.
List<String>? _edgesOf(String path, Map<String, String> libs) {
  final String? src = _directiveHead(path);
  if (src == null) return null;
  final String dir = path.substring(0, path.lastIndexOf('/'));
  final List<String> out = <String>[];
  for (final RegExpMatch m in _directive.allMatches(src)) {
    final String uri = m.group(1)!;
    if (uri.startsWith('package:')) {
      final int slash = uri.indexOf('/');
      if (slash < 0) continue;
      final String? lib = libs[uri.substring('package:'.length, slash)];
      if (lib != null) out.add(_join(lib, uri.substring(slash + 1)));
    } else if (!uri.contains(':')) {
      out.add(_join(dir, uri));
    }
  }
  return out;
}

Map<String, List<String>> _readEdgeCache(File? file) {
  if (file == null) return <String, List<String>>{};
  try {
    final Object? json = jsonDecode(file.readAsStringSync());
    if (json is Map<String, Object?>) {
      return <String, List<String>>{
        for (final MapEntry<String, Object?> e in json.entries)
          if (e.value is List<Object?>)
            e.key: (e.value! as List<Object?>).whereType<String>().toList(),
      };
    }
  } on FileSystemException {
    // first run
  } on FormatException {
    // torn write by a concurrent run: start over
  }
  return <String, List<String>>{};
}

void _writeEdgeCache(File file, Map<String, List<String>> cache) {
  try {
    file.parent.createSync(recursive: true);
    // Write-then-rename so a concurrent reader never sees half a file.
    final File tmp = File('${file.path}.$pid.tmp');
    tmp.writeAsStringSync(jsonEncode(cache));
    tmp.renameSync(file.path);
  } on FileSystemException {
    // Another run won the rename; its cache is as good as ours.
  }
}
