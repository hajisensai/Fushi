#!/usr/bin/env dart

/// Syncs i18n keys across all language files.
///
/// Usage:
///   dart tool/i18n_sync.dart                      # fill missing keys with zh-CN value (or base EN)
///   dart tool/i18n_sync.dart --add key en zh       # add a new key to all files
///   dart tool/i18n_sync.dart --remove key          # remove a key from all files
///   dart tool/i18n_sync.dart --rename old new      # rename a key in all files, keeping every
///                                                  # language's existing translation (errors out
///                                                  # if the new key already exists anywhere)
///   dart tool/i18n_sync.dart --sort                # sort keys alphabetically in all files
///                                                  # (stable, idempotent)
///   dart tool/i18n_sync.dart --dry-run             # show what would change without writing
///
/// `--add` / `--remove` / `--rename` / `--sort` may be repeated and mixed in one
/// invocation; they run **in the order given**, each language file is read once,
/// all operations are applied to it, and it is written once:
///
///   dart tool/i18n_sync.dart --remove a --remove b --add c en zh
///
/// Every argument must be consumed by a flag. An unknown argument, a missing
/// operand, or an operand that is itself a flag aborts with a usage error —
/// nothing is written. This is the whole point of the op-list model: the old
/// implementation took `args.indexOf('--remove')` (first flag only) and then
/// `args.sublist(idx + 1).where((a) => !a.startsWith('--'))` (every later
/// operand, flags stripped) and used just `rest[0]`, so `--remove a --remove b`
/// silently deleted only `a` and dropped `b` on the floor with no diagnostic.
library;

import 'dart:convert';
import 'dart:io';

const String _i18nDir = 'lib/i18n';
const String _baseFile = 'strings.i18n.json';
const String _zhCnFile = 'strings_zh-CN.i18n.json';

const String usage = '''
Usage:
  dart tool/i18n_sync.dart                      fill missing keys from zh-CN (or base EN)
  dart tool/i18n_sync.dart --add <key> <en> <zh>
  dart tool/i18n_sync.dart --remove <key>
  dart tool/i18n_sync.dart --rename <old_key> <new_key>
  dart tool/i18n_sync.dart --sort
  dart tool/i18n_sync.dart --dry-run            preview without writing

--add / --remove / --rename / --sort may be repeated and mixed; they run in the
order given.''';

/// One key-table edit. A command line is an ordered list of these — repeating a
/// flag repeats the op instead of silently discarding the extra operands.
sealed class I18nOp {
  const I18nOp();

  /// How this op was spelled on the command line (for diagnostics).
  String describe();
}

final class AddKeyOp extends I18nOp {
  const AddKeyOp({
    required this.key,
    required this.enValue,
    required this.zhValue,
  });

  final String key;
  final String enValue;
  final String zhValue;

  @override
  String describe() => '--add $key';
}

final class RemoveKeyOp extends I18nOp {
  const RemoveKeyOp(this.key);

  final String key;

  @override
  String describe() => '--remove $key';
}

final class RenameKeyOp extends I18nOp {
  const RenameKeyOp({required this.oldKey, required this.newKey});

  final String oldKey;
  final String newKey;

  @override
  String describe() => '--rename $oldKey $newKey';
}

final class SortKeysOp extends I18nOp {
  const SortKeysOp();

  @override
  String describe() => '--sort';
}

/// A parsed command line: the ops to run, in order, plus the global flags.
final class I18nCommand {
  const I18nCommand({required this.ops, required this.dryRun});

  final List<I18nOp> ops;
  final bool dryRun;
}

/// Bad command line — nothing has been read or written yet.
final class I18nUsageError implements Exception {
  const I18nUsageError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// An op that cannot be carried out safely (e.g. renaming onto an existing
/// key). Thrown during the in-memory dry run so no file is ever half-written.
final class I18nOpError implements Exception {
  const I18nOpError(this.message);

  final String message;

  @override
  String toString() => message;
}

const Set<String> _flags = <String>{
  '--add',
  '--remove',
  '--rename',
  '--sort',
  '--dry-run',
};

/// Parse argv into an ordered op list. Throws [I18nUsageError] on anything it
/// cannot account for — no argument is ever ignored.
I18nCommand parseI18nCommand(List<String> args) {
  final List<I18nOp> ops = <I18nOp>[];
  bool dryRun = false;
  int i = 0;

  while (i < args.length) {
    final String token = args[i];
    switch (token) {
      case '--dry-run':
        dryRun = true;
        i += 1;
      case '--sort':
        ops.add(const SortKeysOp());
        i += 1;
      case '--add':
        final List<String> operands = _takeOperands(args, i + 1, 3, token);
        ops.add(AddKeyOp(
          key: operands[0],
          enValue: operands[1],
          zhValue: operands[2],
        ));
        i += 1 + operands.length;
      case '--remove':
        final List<String> operands = _takeOperands(args, i + 1, 1, token);
        ops.add(RemoveKeyOp(operands[0]));
        i += 1 + operands.length;
      case '--rename':
        final List<String> operands = _takeOperands(args, i + 1, 2, token);
        ops.add(RenameKeyOp(oldKey: operands[0], newKey: operands[1]));
        i += 1 + operands.length;
      default:
        throw I18nUsageError('Error: unknown argument "$token".\n\n$usage');
    }
  }

  for (final I18nOp op in ops) {
    if (op is RenameKeyOp && op.oldKey == op.newKey) {
      throw I18nUsageError(
        'Error: old and new key are identical ("${op.oldKey}").',
      );
    }
  }

  return I18nCommand(ops: ops, dryRun: dryRun);
}

/// Take exactly [count] operands for [flag]. A missing operand — or one that is
/// itself a known flag — is a usage error, never a silently shifted argument.
List<String> _takeOperands(
  List<String> args,
  int start,
  int count,
  String flag,
) {
  final List<String> operands = <String>[];
  for (int i = start; i < args.length && operands.length < count; i++) {
    if (_flags.contains(args[i])) break;
    operands.add(args[i]);
  }
  if (operands.length < count) {
    throw I18nUsageError(
      'Error: $flag expects $count operand(s), got ${operands.length}.\n\n'
      '$usage',
    );
  }
  return operands;
}

/// Result of running the op list against one language file, in memory.
final class I18nApplyResult {
  const I18nApplyResult({
    required this.json,
    required this.log,
    required this.hitsPerOp,
  });

  /// The key table after every op (a new map; the input is not mutated).
  final Map<String, dynamic> json;

  /// Human-readable lines describing what each op did to this file.
  final List<String> log;

  /// Per-op count of edits landed on this file, index-aligned with the ops
  /// list. Lets the caller tell "key absent everywhere" from "key removed".
  final List<int> hitsPerOp;

  bool get changed => hitsPerOp.any((int hits) => hits > 0);
}

/// Apply [ops] in order to one language file's key table. Pure: no IO, no
/// mutation of [json]. Throws [I18nOpError] for conditions that must abort the
/// whole run before anything is written.
I18nApplyResult applyI18nOps({
  required Map<String, dynamic> json,
  required List<I18nOp> ops,
  required bool isZhCn,
  required String label,
}) {
  Map<String, dynamic> current = Map<String, dynamic>.of(json);
  final List<String> log = <String>[];
  final List<int> hitsPerOp = List<int>.filled(ops.length, 0);

  for (int i = 0; i < ops.length; i++) {
    final I18nOp op = ops[i];
    switch (op) {
      case AddKeyOp(
          :final String key,
          :final String enValue,
          :final String zhValue
        ):
        if (current.containsKey(key)) {
          log.add('  skip $label (key "$key" already exists)');
          continue;
        }
        final String value = isZhCn ? zhValue : enValue;
        current[key] = value;
        hitsPerOp[i] = 1;
        log.add('  add "$key": "$value" -> $label');
      case RemoveKeyOp(:final String key):
        if (!current.containsKey(key)) continue;
        current.remove(key);
        hitsPerOp[i] = 1;
        log.add('  remove "$key" from $label');
      case RenameKeyOp(:final String oldKey, :final String newKey):
        if (current.containsKey(newKey)) {
          throw I18nOpError(
            'Error: target key "$newKey" already exists in $label; aborting.',
          );
        }
        if (!current.containsKey(oldKey)) {
          log.add('  skip $label (key "$oldKey" not present)');
          continue;
        }
        current = <String, dynamic>{
          for (final MapEntry<String, dynamic> e in current.entries)
            (e.key == oldKey ? newKey : e.key): e.value,
        };
        hitsPerOp[i] = 1;
        log.add('  rename "$oldKey" -> "$newKey" in $label');
      case SortKeysOp():
        final List<String> keys = current.keys.toList();
        final List<String> sortedKeys = List<String>.of(keys)..sort();
        if (_listEquals(keys, sortedKeys)) continue;
        current = <String, dynamic>{
          for (final String k in sortedKeys) k: current[k],
        };
        hitsPerOp[i] = 1;
        log.add('  sort $label');
    }
  }

  return I18nApplyResult(json: current, log: log, hitsPerOp: hitsPerOp);
}

void main(List<String> args) {
  final I18nCommand command;
  try {
    command = parseI18nCommand(args);
  } on I18nUsageError catch (e) {
    stderr.writeln(e.message);
    exit(1);
  }

  if (command.ops.isEmpty) {
    _syncMissing(command.dryRun);
    return;
  }
  _runOps(command);
}

/// Run the op list: read every file once, apply all ops in memory, then write
/// only the files that actually changed. Any [I18nOpError] aborts before the
/// first write, so a run is all-or-nothing.
void _runOps(I18nCommand command) {
  final List<I18nOp> ops = command.ops;
  final List<File> files = _allI18nFiles();
  final Map<String, I18nApplyResult> results = <String, I18nApplyResult>{};
  final List<int> totalHitsPerOp = List<int>.filled(ops.length, 0);

  for (final File file in files) {
    final I18nApplyResult result;
    try {
      result = applyI18nOps(
        json: _readJson(file),
        ops: ops,
        isZhCn: _isZhCn(file),
        label: file.path,
      );
    } on I18nOpError catch (e) {
      stderr.writeln(e.message);
      exit(1);
    }
    results[file.path] = result;
    for (int i = 0; i < ops.length; i++) {
      totalHitsPerOp[i] += result.hitsPerOp[i];
    }
  }

  // A rename that matched nothing is a typo, not a no-op: abort before writing
  // (matches the pre-op-list behaviour). Other ops only warn, so existing
  // scripts that remove an already-absent key keep their exit code.
  for (int i = 0; i < ops.length; i++) {
    if (totalHitsPerOp[i] > 0) continue;
    final I18nOp op = ops[i];
    switch (op) {
      case RenameKeyOp(:final String oldKey):
        stderr.writeln('Error: key "$oldKey" not found in any i18n file.');
        exit(1);
      case RemoveKeyOp(:final String key):
        stderr.writeln(
          'warning: key "$key" not found in any i18n file (nothing removed).',
        );
      case AddKeyOp(:final String key):
        stderr.writeln(
          'warning: key "$key" already exists in every i18n file (nothing added).',
        );
      case SortKeysOp():
        break;
    }
  }

  int changed = 0;
  for (final File file in files) {
    final I18nApplyResult result = results[file.path]!;
    for (final String line in result.log) {
      stdout
          .writeln(command.dryRun ? line.replaceFirst('  ', '  would ') : line);
    }
    if (!result.changed) continue;
    changed++;
    if (!command.dryRun) _writeJson(file, result.json);
  }

  // Keep the historical sort-only message: `--sort` on already-sorted files is
  // the one case where "changed nothing" is the expected happy path.
  if (changed == 0 && ops.length == 1 && ops.single is SortKeysOp) {
    stdout.writeln('All i18n files are already sorted.');
    return;
  }
  stdout.writeln(
      '\n${command.dryRun ? "Would change" : "Changed"} $changed files.');
}

/// Fill missing keys in translation files using zh-CN value, falling back to base EN.
void _syncMissing(bool dryRun) {
  final File baseFile = File('$_i18nDir/$_baseFile');
  final File zhCnFile = File('$_i18nDir/$_zhCnFile');
  final Map<String, dynamic> baseJson = _readJson(baseFile);
  final Map<String, dynamic> zhCnJson = _readJson(zhCnFile);

  final List<File> files = _allI18nFiles();
  int totalAdded = 0;

  for (final File file in files) {
    if (_isBase(file)) continue;

    final Map<String, dynamic> json = _readJson(file);
    final List<String> missing =
        baseJson.keys.where((k) => !json.containsKey(k)).toList();
    if (missing.isEmpty) continue;

    for (final String key in missing) {
      final String fallback =
          (zhCnJson[key] as String?) ?? (baseJson[key] as String? ?? '');
      json[key] = fallback;
    }
    totalAdded += missing.length;

    if (dryRun) {
      stdout.writeln('  ${file.path}: ${missing.length} missing keys');
      for (final String k in missing) {
        stdout.writeln('    + $k');
      }
    } else {
      _writeJson(file, json);
      stdout.writeln('  ${file.path}: filled ${missing.length} keys');
    }
  }

  if (totalAdded == 0) {
    stdout.writeln('All translation files are in sync.');
  } else {
    stdout.writeln(
      '\n${dryRun ? "Would fill" : "Filled"} $totalAdded missing keys across files.',
    );
  }
}

// ── helpers ──────────────────────────────────────────────────────────────────

List<File> _allI18nFiles() {
  final Directory dir = Directory(_i18nDir);
  return dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.i18n.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}

Map<String, dynamic> _readJson(File file) {
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

void _writeJson(File file, Map<String, dynamic> json) {
  const JsonEncoder encoder = JsonEncoder.withIndent('  ');
  file.writeAsStringSync('${encoder.convert(json)}\n');
}

bool _listEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _isBase(File file) => file.path.replaceAll('\\', '/').endsWith(_baseFile);
bool _isZhCn(File file) => file.path.replaceAll('\\', '/').endsWith(_zhCnFile);
