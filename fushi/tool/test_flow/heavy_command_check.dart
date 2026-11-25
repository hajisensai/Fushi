// Fail-fast "can this command start at all" check for tool/heavy.dart.
//
// Why (2026-11-20): heavy.dart only learned that its command could not start
// when the slot was finally its own. `.\gradlew.bat :app:assembleRelease`
// typed in fushi/ instead of fushi/android/ queued like any build -- in the
// session records of 11-15..11-20, 23 such runs waited 179 minutes between
// them -- and then died in a second on cmd.exe's "is not recognized as an
// internal or external command". `./gradlew.bat` did the same even from the
// right directory: Windows runs the command through cmd.exe, which reads the
// `.` before the forward slash as the command name.
//
// Whether the executable exists is known before queueing, so it is checked
// there, and the path that was checked (absolute, native separators) is the
// one that is started.

import 'package:path/path.dart' as p;

/// Result of resolving a wrapped command's executable.
class HeavyCommandCheck {
  const HeavyCommandCheck({required this.executable, this.error});

  /// What to start in place of the command's first word: the absolute path of
  /// the file that was found, or the word itself where the shell resolves it
  /// (a bare name found on PATH, a cmd.exe builtin).
  final String executable;

  /// Non-null when the command cannot start (no such file).
  final String? error;
}

/// cmd.exe's own commands: no file anywhere, yet `cmd /c <name>` runs them.
const Set<String> _cmdBuiltins = <String>{
  'call',
  'cd',
  'copy',
  'del',
  'dir',
  'echo',
  'mkdir',
  'move',
  'rd',
  'ren',
  'rmdir',
  'set',
  'start',
  'type',
  'ver',
};

/// The extensions cmd.exe appends to a name that has none.
List<String> _pathExts(Map<String, String> environment) {
  final String raw =
      environment['PATHEXT'] ?? environment['PathExt'] ?? '.COM;.EXE;.BAT;.CMD';
  return <String>[
    for (final String e in raw.split(';'))
      if (e.trim().isNotEmpty) e.trim().toLowerCase(),
  ];
}

/// [path] under [cwd] without `.` / `..` segments, with the platform's
/// separator. Windows paths go through `package:path`'s Windows rules, so a
/// UNC share root (`\\server\share`) stays one root that `..` never climbs
/// above, and a root-relative `\x` lands on [cwd]'s drive or share
/// (HBK-AUDIT-047: a hand-rolled split folded `\\server` into `\server`).
String _absolute(String cwd, String path, {required bool isWindows}) {
  if (!isWindows) return p.posix.normalize(p.posix.join(cwd, path));
  // Windows takes `/` and `\` alike; package:path keeps a root as written
  // (`//nas/share`), so the separators are made native first.
  return p.windows.normalize(
    p.windows.join(cwd.replaceAll('/', r'\'), path.replaceAll('/', r'\')),
  );
}

/// Finds the file [command]'s first word names, the way the shell that
/// heavy.dart starts it through would: a word with a directory in it is that
/// file under [cwd] (on Windows also with a PATHEXT extension appended), a
/// bare word is looked up in [cwd] (Windows only) and on PATH. A word with a
/// directory comes back as the absolute path of the file found; a bare word
/// that resolves comes back unchanged. Nothing found is an error, except a
/// cmd.exe builtin on Windows.
HeavyCommandCheck checkHeavyCommandStarts(
  List<String> command, {
  required String cwd,
  required Map<String, String> environment,
  required bool isWindows,
  required bool Function(String path) fileExists,
}) {
  if (command.isEmpty) {
    return const HeavyCommandCheck(executable: '', error: 'heavy: no command');
  }
  final String first = command.first;
  final List<String> exts = isWindows ? _pathExts(environment) : <String>[];
  // cmd.exe tries the name as typed when it already ends in an extension,
  // else each PATHEXT extension; POSIX takes the name as it is.
  List<String> spellings(String path) {
    if (!isWindows) return <String>[path];
    final String lower = path.toLowerCase();
    if (exts.any(lower.endsWith)) return <String>[path];
    return <String>[for (final String e in exts) '$path$e', path];
  }

  final bool hasDir =
      first.contains('/') || (isWindows && first.contains(r'\'));
  if (hasDir) {
    for (final String c in spellings(
      _absolute(cwd, first, isWindows: isWindows),
    )) {
      if (fileExists(c)) return HeavyCommandCheck(executable: c);
    }
    return HeavyCommandCheck(
      executable: first,
      error:
          'heavy: cannot run $first: no such file from $cwd. Not queueing '
          'for it. (gradlew lives in fushi/android/; run from the directory '
          'the command is relative to.)',
    );
  }
  if (isWindows) {
    if (_cmdBuiltins.contains(first.toLowerCase())) {
      return HeavyCommandCheck(executable: first);
    }
    // cmd.exe looks in the current directory before PATH.
    for (final String c in spellings(_absolute(cwd, first, isWindows: true))) {
      if (fileExists(c)) return HeavyCommandCheck(executable: first);
    }
  }
  final String path = environment['PATH'] ?? environment['Path'] ?? '';
  for (final String dir in path.split(isWindows ? ';' : ':')) {
    if (dir.isEmpty) continue;
    for (final String c in spellings('$dir${isWindows ? r'\' : '/'}$first')) {
      if (fileExists(c)) return HeavyCommandCheck(executable: first);
    }
  }
  return HeavyCommandCheck(
    executable: first,
    error:
        'heavy: cannot run $first: not found in $cwd or on PATH. Not '
        'queueing for it.',
  );
}
