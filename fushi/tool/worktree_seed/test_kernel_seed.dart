// A machine-wide "third-party only" seed for flutter test's incremental
// compile cache, so a fresh worktree's first `flutter test` does not compile
// the Flutter SDK and pub packages from scratch.
//
// Why (2026-11-20): flutter test initialises frontend_server from
// fushi/build/test_cache/build/<md5>.cache.dill.track.dill. Copying a sibling
// worktree's file (the old setup_worktree.ps1 warm-up) never helped: every
// fushi test pulls in fushi/lib through test/flutter_test_config.dart, the
// dill records those libraries under the sibling's absolute path, and
// front_end's _initializeFromDill throws PackageChangedError on the first
// package: library whose file no longer matches package_config — then throws
// the whole dill away and compiles cold.
//
// A dill holding only libraries that live outside every worktree (Flutter SDK,
// pub cache) passes that check in any worktree. It is produced by real
// `flutter test` (so the frontend arguments are flutter_tools' own) on a
// generated entry that imports the third-party libraries the worktree uses,
// placed under build/ where no flutter_test_config.dart applies. Measured on
// 2026-11-20 in a fresh worktree: first-run Compile 43.6 s -> 30.0 s for a
// flutter_test-only test, 42.6 s -> 30.0 s for a package:fushi widget test.
//
// Correctness does not depend on the seed being current: frontend_server
// compares every source with the bytes recorded in the dill and recompiles
// what changed, so a stale or partial seed only costs speed.
//
// Tests: test/tools/worktree_seed_test_kernel_test.dart.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Bump when the entry recipe changes, so old cache entries are not reused.
const int kTestSeedFormat = 1;

/// Cache entries (keys) kept per machine; older ones are deleted.
const int kTestSeedKeep = 4;

/// A generation lock younger than this belongs to a setup still generating.
const Duration kTestSeedLockStale = Duration(minutes: 30);

/// Where the generated entry lives, relative to the app package (`fushi/`):
/// under build/, so no test/flutter_test_config.dart wraps it.
const String kTestSeedEntryRel = 'build/test_seed/seed_test.dart';

/// flutter test's compile cache directory, relative to the app package.
const String kTestCacheRel = 'build/test_cache/build';

/// One package from `.dart_tool/package_config.json`.
class SeedPackage {
  const SeedPackage({
    required this.name,
    required this.root,
    required this.libDir,
  });

  final String name;

  /// Absolute package root directory.
  final String root;

  /// Absolute directory `package:<name>/` maps to.
  final String libDir;
}

/// Packages listed in the package_config.json at [configPath], with
/// relative `rootUri`s resolved against its directory.
List<SeedPackage> readPackageConfig(String configPath) {
  final Map<String, Object?> json =
      jsonDecode(File(configPath).readAsStringSync()) as Map<String, Object?>;
  final Uri base = Uri.file(configPath);
  final List<SeedPackage> out = <SeedPackage>[];
  for (final Object? raw in json['packages']! as List<Object?>) {
    final Map<String, Object?> pkg = raw! as Map<String, Object?>;
    String rootUri = pkg['rootUri']! as String;
    if (!rootUri.endsWith('/')) rootUri = '$rootUri/';
    final Uri root = base.resolve(rootUri);
    final String packageUri = (pkg['packageUri'] as String?) ?? 'lib/';
    out.add(
      SeedPackage(
        name: pkg['name']! as String,
        root: p.normalize(root.toFilePath()),
        libDir: p.normalize(root.resolve(packageUri).toFilePath()),
      ),
    );
  }
  return out;
}

/// The `flutterRoot` recorded in the package_config.json at [configPath].
String? readFlutterRoot(String configPath) {
  final Map<String, Object?> json =
      jsonDecode(File(configPath).readAsStringSync()) as Map<String, Object?>;
  final String? uri = json['flutterRoot'] as String?;
  return uri == null ? null : p.normalize(Uri.parse(uri).toFilePath());
}

bool _isUnder(String path, String dir) {
  String norm(String s) {
    final String n = p.normalize(p.absolute(s)).replaceAll(r'\', '/');
    return Platform.isWindows ? n.toLowerCase() : n;
  }

  final String a = norm(path);
  final String b = norm(dir);
  return a == b || a.startsWith(b.endsWith('/') ? b : '$b/');
}

/// Names under `dependencies:` in the pubspec.yaml text [pubspec]
/// (top-level section, two-space-indented keys; dev_dependencies ignored).
Set<String> pubspecDependencies(String pubspec) {
  final Set<String> deps = <String>{};
  bool inSection = false;
  for (final String line in const LineSplitter().convert(pubspec)) {
    if (RegExp(r'^dependencies:\s*(#.*)?$').hasMatch(line)) {
      inSection = true;
      continue;
    }
    if (inSection && RegExp(r'^\S').hasMatch(line)) inSection = false;
    if (!inSection) continue;
    final RegExpMatch? m = RegExp(r'^  ([A-Za-z0-9_]+):').firstMatch(line);
    if (m != null) deps.add(m.group(1)!);
  }
  return deps;
}

/// Packages whose libraries may go into the seed: located outside
/// [repoRoot] and not depending (transitively, per their pubspec
/// `dependencies:`) on any package inside it. A library of such a dependent
/// (e.g. marquee -> the in-repo fading_edge_scrollview override) would drag a
/// worktree-path package: library into the dill and make it unusable in every
/// other worktree. [readPubspec] returns a package root's pubspec text or null.
Map<String, SeedPackage> seedablePackages(
  List<SeedPackage> packages,
  String repoRoot, {
  String? Function(String root)? readPubspec,
}) {
  final String? Function(String) read =
      readPubspec ??
      (String root) {
        final File f = File(p.join(root, 'pubspec.yaml'));
        return f.existsSync() ? f.readAsStringSync() : null;
      };
  final Set<String> tainted = <String>{
    for (final SeedPackage pkg in packages)
      if (_isUnder(pkg.root, repoRoot)) pkg.name,
  };
  final Map<String, Set<String>> deps = <String, Set<String>>{
    for (final SeedPackage pkg in packages)
      if (!tainted.contains(pkg.name))
        pkg.name: pubspecDependencies(read(pkg.root) ?? ''),
  };
  bool changed = true;
  while (changed) {
    changed = false;
    for (final MapEntry<String, Set<String>> e in deps.entries) {
      if (!tainted.contains(e.key) && e.value.any(tainted.contains)) {
        tainted.add(e.key);
        changed = true;
      }
    }
  }
  return <String, SeedPackage>{
    for (final SeedPackage pkg in packages)
      if (!tainted.contains(pkg.name)) pkg.name: pkg,
  };
}

final RegExp _directive = RegExp(
  r'''^\s*(?:import|export)\s+['"]package:([A-Za-z0-9_]+)/([^'"]+)['"]''',
);
final RegExp _webOnly = RegExp(
  r'''['"](?:dart:html|dart:js_interop|dart:js_util|dart:js|package:web/)''',
);

/// Third-party `package:` libraries imported (or exported) by Dart files in
/// [scanDirs], restricted to [seedable] packages and to files that exist.
/// Skipped: conditional imports (the first URI may be a web-only variant),
/// `*_web.dart` files and files touching web-only libraries — on the VM test
/// target those would be compile errors.
List<String> scanSeedLibraries(
  List<String> scanDirs,
  Map<String, SeedPackage> seedable,
) {
  final Set<String> libs = <String>{};
  for (final String dir in scanDirs) {
    final Directory d = Directory(dir);
    if (!d.existsSync()) continue;
    for (final FileSystemEntity e in d.listSync(
      recursive: true,
      followLinks: false,
    )) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      if (e.path.endsWith('_web.dart')) continue;
      final String text;
      try {
        text = e.readAsStringSync();
      } on FileSystemException {
        continue; // Not UTF-8: not a source this compile would read either.
      }
      if (_webOnly.hasMatch(text)) continue;
      for (final String line in const LineSplitter().convert(text)) {
        if (RegExp(r'\bif\s*\(').hasMatch(line)) continue;
        final RegExpMatch? m = _directive.firstMatch(line);
        if (m == null) continue;
        final SeedPackage? pkg = seedable[m.group(1)!];
        if (pkg == null) continue;
        if (!File(p.join(pkg.libDir, m.group(2)!)).existsSync()) continue;
        libs.add('package:${m.group(1)}/${m.group(2)}');
      }
    }
  }
  return libs.toList()..sort();
}

/// Directories whose imports decide the seed: the app's lib/ and test/, and
/// lib/ of every in-repo package (their third-party imports compile too).
List<String> seedScanDirs(String repoRoot) {
  final List<String> dirs = <String>[
    p.join(repoRoot, 'fushi', 'lib'),
    p.join(repoRoot, 'fushi', 'test'),
  ];
  for (final String group in <String>['packages', 'third_party']) {
    final Directory d = Directory(p.join(repoRoot, group));
    if (!d.existsSync()) continue;
    final List<Directory> pkgs = d.listSync().whereType<Directory>().toList()
      ..sort((Directory a, Directory b) => a.path.compareTo(b.path));
    for (final Directory pkg in pkgs) {
      final String lib = p.join(pkg.path, 'lib');
      if (Directory(lib).existsSync()) dirs.add(lib);
    }
  }
  return dirs;
}

/// The seed test entry importing [libs]; one trivial test so flutter test
/// compiles it, runs it and writes the compile cache back.
String renderSeedEntry(List<String> libs) {
  final StringBuffer b = StringBuffer()
    ..writeln(
      '// Generated by fushi/tool/worktree_seed.dart kernel; do not edit.',
    )
    ..writeln('// ignore_for_file: unused_import')
    ..writeln();
  for (int i = 0; i < libs.length; i++) {
    b.writeln("import '${libs[i]}' as i$i;");
  }
  b
    ..writeln("import 'package:flutter_test/flutter_test.dart' as seed;")
    ..writeln()
    ..writeln('void main() {')
    ..writeln("  seed.test('test kernel seed', () {});")
    ..writeln('}');
  return b.toString();
}

/// Inputs that decide whether a cached seed fits a worktree.
class SeedKeyInputs {
  const SeedKeyInputs({
    required this.flutterRoot,
    required this.frameworkRevision,
    required this.engineRevision,
    required this.dartSdkVersion,
    required this.lockSha256,
    required this.appVersion,
  });

  /// SDK libraries are recorded under this path, so another install differs.
  final String flutterRoot;
  final String frameworkRevision;
  final String engineRevision;
  final String dartSdkVersion;

  /// sha256 of the workspace pubspec.lock.
  final String lockSha256;

  /// fushi/pubspec.yaml `version:` (it feeds the dill file name via defines).
  final String appVersion;
}

/// Cache key directory name for [k]: 16 hex of a sha256 over every input.
String seedKey(SeedKeyInputs k) {
  final String flutterRoot = Platform.isWindows
      ? k.flutterRoot.toLowerCase()
      : k.flutterRoot;
  final String joined = <String>[
    'format=$kTestSeedFormat',
    p.normalize(flutterRoot).replaceAll(r'\', '/'),
    k.frameworkRevision,
    k.engineRevision,
    k.dartSdkVersion,
    k.lockSha256,
    k.appVersion,
  ].join('|');
  return sha256.convert(utf8.encode(joined)).toString().substring(0, 16);
}

/// Reads [SeedKeyInputs] for the worktree at [repoRoot]; null (with [why]
/// set) when something is missing (pub get not run, unknown SDK layout).
SeedKeyInputs? readSeedKeyInputs(String repoRoot, List<String> why) {
  final String config = p.join(repoRoot, '.dart_tool', 'package_config.json');
  if (!File(config).existsSync()) {
    why.add('no $config (pub get has not run)');
    return null;
  }
  final String? flutterRoot = readFlutterRoot(config);
  if (flutterRoot == null) {
    why.add('$config has no flutterRoot');
    return null;
  }
  final File versionFile = File(
    p.join(flutterRoot, 'bin', 'cache', 'flutter.version.json'),
  );
  final File lock = File(p.join(repoRoot, 'pubspec.lock'));
  final File appPubspec = File(p.join(repoRoot, 'fushi', 'pubspec.yaml'));
  for (final File f in <File>[versionFile, lock, appPubspec]) {
    if (!f.existsSync()) {
      why.add('missing ${f.path}');
      return null;
    }
  }
  final Map<String, Object?> v =
      jsonDecode(versionFile.readAsStringSync()) as Map<String, Object?>;
  final RegExpMatch? version = RegExp(
    r'^version:\s*(\S+)',
    multiLine: true,
  ).firstMatch(appPubspec.readAsStringSync());
  final String? framework = v['frameworkRevision'] as String?;
  final String? engine = v['engineRevision'] as String?;
  final String? dart = v['dartSdkVersion'] as String?;
  if (framework == null || engine == null || dart == null || version == null) {
    why.add('cannot read SDK revisions or app version');
    return null;
  }
  return SeedKeyInputs(
    flutterRoot: flutterRoot,
    frameworkRevision: framework,
    engineRevision: engine,
    dartSdkVersion: dart,
    lockSha256: sha256.convert(lock.readAsBytesSync()).toString(),
    appVersion: version.group(1)!,
  );
}

bool _isDill(File f) => f.path.endsWith('.cache.dill.track.dill');

/// Compile-cache dills in [dir] (non-empty), sorted by name.
List<File> listSeedDills(String dir) {
  final Directory d = Directory(dir);
  if (!d.existsSync()) return <File>[];
  return d.listSync().whereType<File>().where((File f) {
    return _isDill(f) && f.lengthSync() > 0;
  }).toList()..sort((File a, File b) => a.path.compareTo(b.path));
}

/// Copy (never hard-link: flutter test rewrites the file in place) through a
/// temp name so no reader sees a partial dill.
void _copyAtomically(File src, String dst) {
  Directory(p.dirname(dst)).createSync(recursive: true);
  final String tmp = '$dst.seeding-$pid';
  src.copySync(tmp);
  File(tmp).renameSync(dst);
}

/// Copy the seed dills of [keyDir] into [testCacheDir]; returns the names
/// copied. Nothing is copied when [testCacheDir] already has a dill (that
/// worktree's own cache is always better than the seed).
List<String> restoreSeed(String keyDir, String testCacheDir) {
  if (listSeedDills(testCacheDir).isNotEmpty) return <String>[];
  final List<String> copied = <String>[];
  for (final File f in listSeedDills(keyDir)) {
    final String name = p.basename(f.path);
    _copyAtomically(f, p.join(testCacheDir, name));
    copied.add(name);
  }
  return copied;
}

/// Store the dills of [testCacheDir] as the seed in [keyDir] (replacing it),
/// then delete all but the [keep] most recently stored keys in its parent.
List<String> storeSeed(
  String testCacheDir,
  String keyDir, {
  int keep = kTestSeedKeep,
}) {
  final List<String> stored = <String>[];
  for (final File f in listSeedDills(testCacheDir)) {
    final String name = p.basename(f.path);
    _copyAtomically(f, p.join(keyDir, name));
    stored.add(name);
  }
  if (stored.isNotEmpty) {
    File(
      p.join(keyDir, 'stored'),
    ).writeAsStringSync(DateTime.now().toUtc().toIso8601String());
    pruneSeedCache(p.dirname(keyDir), keep: keep);
  }
  return stored;
}

/// Delete key directories under [cacheDir] beyond the [keep] newest (by the
/// `stored` stamp's mtime; directories without one count as oldest).
void pruneSeedCache(String cacheDir, {int keep = kTestSeedKeep}) {
  final Directory d = Directory(cacheDir);
  if (!d.existsSync()) return;
  DateTime stamp(Directory k) {
    final File f = File(p.join(k.path, 'stored'));
    return f.existsSync()
        ? f.lastModifiedSync()
        : DateTime.fromMillisecondsSinceEpoch(0);
  }

  final List<Directory> keys = d.listSync().whereType<Directory>().toList()
    ..sort((Directory a, Directory b) => stamp(b).compareTo(stamp(a)));
  for (final Directory k in keys.skip(keep)) {
    k.deleteSync(recursive: true);
  }
}

/// Paths inside [repoRoot] that the dill at [dillPath] records, other than
/// the generated entry directory and .dart_tool/. Non-empty means the seed
/// would carry worktree libraries (unusable elsewhere) and must not be stored.
List<String> worktreePathsInDill(String dillPath, String repoRoot) {
  final String text = latin1.decode(File(dillPath).readAsBytesSync());
  String prefix = Uri.directory(repoRoot).toString();
  if (!prefix.endsWith('/')) prefix = '$prefix/';
  const List<String> allowed = <String>[
    'fushi/build/test_seed/',
    '.dart_tool/',
  ];
  final Set<String> found = <String>{};
  // Compare case-insensitively on Windows: drive letters may differ in case.
  final String hay = Platform.isWindows ? text.toLowerCase() : text;
  final String needle = Platform.isWindows ? prefix.toLowerCase() : prefix;
  int at = hay.indexOf(needle);
  while (at >= 0) {
    final int start = at + needle.length;
    int end = start;
    while (end < text.length && end - start < 300) {
      final int c = text.codeUnitAt(end);
      if (c < 0x21 || c == 0x22 || c == 0x27 || c > 0x7e) break;
      end++;
    }
    final String rest = text.substring(start, end);
    if (!allowed.any(
      (String a) => rest.toLowerCase().startsWith(a.toLowerCase()),
    )) {
      found.add(rest);
    }
    at = hay.indexOf(needle, end);
  }
  return found.toList()..sort();
}

/// Generation lock for [keyDir]: a `<key>.lock` file created exclusively.
/// Returns false when another setup holds a lock younger than [stale]; a
/// stale lock (a setup that died mid-generation) is taken over.
bool takeSeedLock(
  String keyDir, {
  Duration stale = kTestSeedLockStale,
  DateTime? now,
}) {
  final File lock = File('$keyDir.lock');
  lock.parent.createSync(recursive: true);
  try {
    lock.createSync(exclusive: true);
    lock.writeAsStringSync('$pid');
    return true;
  } on FileSystemException {
    // Held by someone; take it over only when stale.
  }
  final DateTime since = lock.lastModifiedSync();
  if ((now ?? DateTime.now()).difference(since) < stale) return false;
  lock.writeAsStringSync('$pid');
  return true;
}

/// Release a lock taken by [takeSeedLock].
void releaseSeedLock(String keyDir) {
  final File lock = File('$keyDir.lock');
  if (lock.existsSync()) lock.deleteSync();
}
