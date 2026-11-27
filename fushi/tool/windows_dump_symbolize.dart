// BUG-5568: symbolize the Dart frames of a Windows hang / crash minidump.
//
//   dart tool/windows_dump_symbolize.dart verify <shipped app.so> <symbols>
//       CI (release-desktop.yml): the saved debugging info must belong to the
//       shipped app.so (same GNU build-id) and carry .symtab / .debug_line.
//
//   dart tool/windows_dump_symbolize.dart stack --dump <hang-….dmp>
//       --dart-symbols <app.windows-x64.symbols> [--engine-symbols <dir>]
//       [--base 0x…] [--cdb <cdb.exe>] [--threads all|main]
//       Prints cdb's stacks with every Dart frame annotated as
//       `[dart] function (file:line)`. The Dart image base / build-id come from
//       the dump's own user stream; dumps written before BUG-5568 lack it — pass
//       --base from the `dart_aot` line of hang_watchdog.log or a live scan.
//
// Symbols: Dart — the `windows-dart-symbols-<release sequence>` artifact of the
// release-desktop run that built the installed version (sequence = the number
// after `-debug.` / the build number). Engine (flutter_windows.dll, which also
// holds the Dart VM and GC) — the pdb inside the patched-engine zip named by
// ci/patches/flutter-engine/<flutter version>/artifacts.json; see
// docs/agent/build.md「Windows 卡死 / 崩溃 dump 的符号」.
import 'dart:io';
import 'dart:typed_data';

import 'windows_dump/windows_dump_lib.dart';

const String _defaultCdb =
    r'C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\cdb.exe';

Never _usage(String message) {
  stderr
    ..writeln(message)
    ..writeln(
      'usage:\n'
      '  dart tool/windows_dump_symbolize.dart verify <app.so> <symbols>\n'
      '  dart tool/windows_dump_symbolize.dart stack --dump <dmp> '
      '--dart-symbols <file> [--engine-symbols <dir>] [--base 0x…] '
      '[--cdb <exe>] [--threads all|main]',
    );
  exit(64);
}

Map<String, String> _flags(List<String> args) {
  final Map<String, String> out = <String, String>{};
  for (int i = 0; i < args.length; i++) {
    final String a = args[i];
    if (!a.startsWith('--') || i + 1 >= args.length) {
      _usage('bad argument: $a');
    }
    out[a.substring(2)] = args[++i];
  }
  return out;
}

int _verify(List<String> args) {
  if (args.length != 2) _usage('verify takes <app.so> <symbols>');
  final List<String> problems = verifyWindowsDartSymbols(
    shippedAppSo: File(args[0]).readAsBytesSync(),
    savedSymbols: File(args[1]).readAsBytesSync(),
  );
  if (problems.isEmpty) {
    final String? id = summarizeElf(File(args[0]).readAsBytesSync())?.buildId;
    stdout.writeln('Windows Dart symbols OK (build-id $id)');
    return 0;
  }
  for (final String p in problems) {
    stderr.writeln('::error title=Windows Dart symbols::$p');
  }
  return 1;
}

Future<int> _stack(List<String> args) async {
  final Map<String, String> f = _flags(args);
  final String? dumpPath = f['dump'];
  final String? symbolsPath = f['dart-symbols'];
  if (dumpPath == null || symbolsPath == null) {
    _usage('stack needs --dump and --dart-symbols');
  }
  final Uint8List dump = File(dumpPath).readAsBytesSync();
  final Uint8List symbols = File(symbolsPath).readAsBytesSync();
  final ElfSummary? sym = summarizeElf(symbols);
  if (sym == null) _usage('$symbolsPath is not an ELF file');

  DartAotImage? image = readDartAotStream(dump);
  final String? baseFlag = f['base'];
  if (baseFlag != null) {
    // Old dump: no stream. The span is the symbols file's own layout, which
    // matches the shipped image (same build-id ⇒ same snapshot).
    image = DartAotImage(
      base: int.parse(baseFlag.replaceFirst('0x', ''), radix: 16),
      span: 0x7fffffff,
      buildId: sym.buildId,
    );
  }
  if (image == null) {
    _usage(
      'the dump has no dart_aot stream (written before BUG-5568); '
      'pass --base 0x… from hang_watchdog.log',
    );
  }
  if (image.buildId != null && image.buildId != sym.buildId) {
    stderr.writeln(
      'build-id mismatch: dump ${image.buildId} vs symbols ${sym.buildId} — '
      'wrong windows-dart-symbols artifact',
    );
    return 1;
  }

  final String cdb = f['cdb'] ?? _defaultCdb;
  final String symbolPath = <String>[
    ?f['engine-symbols'],
    r'srv*C:\symcache*https://msdl.microsoft.com/download/symbols',
  ].join(';');
  final String threads = f['threads'] == 'main' ? '~0s; kn 300' : '~*kn 300';
  final ProcessResult cdbRun = await Process.run(cdb, <String>[
    '-z',
    dumpPath,
    '-y',
    symbolPath,
    '-c',
    '.symopt+0x40; $threads; q',
  ]);
  final List<String> cdbLines = (cdbRun.stdout as String).split(
    RegExp(r'\r?\n'),
  );
  final List<RawFrame> frames = findDartFrames(cdbLines, image);
  if (frames.isEmpty) {
    stdout.writeln(cdbLines.join('\n'));
    stderr.writeln('no Dart frames found in the dump');
    return 0;
  }

  final Directory tmp = Directory.systemTemp.createTempSync('fushi-dump-');
  try {
    final File trace = File('${tmp.path}/trace.txt')
      ..writeAsStringSync(
        buildDwarfTrace(image, frames.map((RawFrame r) => r.address)),
      );
    final File decodedFile = File('${tmp.path}/decoded.txt');
    final ProcessResult symbolizeRun = await Process.run(
      Platform.isWindows ? 'flutter.bat' : 'flutter',
      <String>[
        'symbolize',
        '-d',
        symbolsPath,
        '-i',
        trace.path,
        '-o',
        decodedFile.path,
      ],
      runInShell: Platform.isWindows,
    );
    if (symbolizeRun.exitCode != 0) {
      stderr
        ..writeln('flutter symbolize failed (${symbolizeRun.exitCode}):')
        ..writeln(symbolizeRun.stdout)
        ..writeln(symbolizeRun.stderr);
      return 1;
    }
    final Map<int, List<String>> decoded = parseDecodedTrace(
      decodedFile.readAsStringSync(),
    );
    stdout.writeln(annotateCdbOutput(cdbLines, frames, decoded).join('\n'));
    return 0;
  } finally {
    tmp.deleteSync(recursive: true);
  }
}

Future<void> main(List<String> args) async {
  if (args.isEmpty) _usage('missing command');
  final List<String> rest = args.sublist(1);
  switch (args.first) {
    case 'verify':
      exitCode = _verify(rest);
    case 'stack':
      exitCode = await _stack(rest);
    default:
      _usage('unknown command ${args.first}');
  }
}
