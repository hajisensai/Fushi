#!/usr/bin/env dart

/// Syncs i18n keys across all language files.
///
/// Usage:
///   dart tool/i18n_sync.dart                      # fill missing keys with zh-CN value (or base EN)
///   dart tool/i18n_sync.dart --add key en zh       # add a new key to all files, right
///                                                  # after its alphabetical predecessor
///                                                  # (see [insertKeyAfterPredecessor])
///   dart tool/i18n_sync.dart --remove key          # remove a key from all files
///   dart tool/i18n_sync.dart --rename old new      # rename a key in all files, keeping every
///                                                  # language's existing translation and moving
///                                                  # it to the new name's alphabetical position
///                                                  # (errors out if the new key already exists)
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
        ops.add(
          AddKeyOp(
            key: operands[0],
            enValue: operands[1],
            zhValue: operands[2],
          ),
        );
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
        :final String zhValue,
      ):
        if (current.containsKey(key)) {
          log.add('  skip $label (key "$key" already exists)');
          continue;
        }
        final String value = isZhCn ? zhValue : enValue;
        current = insertKeyAfterPredecessor(current, key, value);
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
        // Re-place the renamed key at its own alphabetical position instead of
        // swapping it into the old key's slot: the files are kept key-sorted
        // (guard test/i18n/i18n_keys_sorted_guard_test.dart), and an in-place
        // rename to a name that sorts elsewhere would break that invariant.
        final dynamic renamedValue = current[oldKey];
        current = insertKeyAfterPredecessor(
          <String, dynamic>{
            for (final MapEntry<String, dynamic> e in current.entries)
              if (e.key != oldKey) e.key: e.value,
          },
          newKey,
          renamedValue,
        );
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

/// Return a copy of [json] with [key] inserted right after its alphabetical
/// predecessor (the greatest existing key that sorts before it), or first when
/// no key sorts before it.
///
/// Why not just append: every concurrent branch that appended a key edited the
/// same last lines of 17 files (the new entry plus the comma it forces onto the
/// previous last entry), so any two i18n-adding PRs conflicted on merge.
/// Placing each key next to its alphabetical neighbour spreads additions
/// across the file — keys of one domain share a prefix and cluster together —
/// so independent additions merge cleanly. The files are not globally sorted,
/// so the predecessor is searched over all keys rather than by binary search.
Map<String, dynamic> insertKeyAfterPredecessor(
  Map<String, dynamic> json,
  String key,
  dynamic value,
) {
  String? predecessor;
  for (final String k in json.keys) {
    if (k.compareTo(key) < 0 &&
        (predecessor == null || k.compareTo(predecessor) > 0)) {
      predecessor = k;
    }
  }
  return _insertAfter(json, predecessor, key, value);
}

/// Return a copy of [json] with [key] inserted right after [anchor] (or first
/// when [anchor] is null). Assumes [key] is not already present.
Map<String, dynamic> _insertAfter(
  Map<String, dynamic> json,
  String? anchor,
  String key,
  dynamic value,
) {
  final Map<String, dynamic> out = <String, dynamic>{};
  if (anchor == null) out[key] = value;
  for (final MapEntry<String, dynamic> e in json.entries) {
    out[e.key] = e.value;
    if (e.key == anchor) out[key] = value;
  }
  return out;
}

/// Return a copy of [json] with every key of [baseOrder] that it lacks filled
/// from [valueOf], each placed right after the nearest preceding base key it
/// already has — so a translation file mirrors the base file's layout and a
/// fill touches the same region the base addition did, instead of the
/// append-at-end merge hotspot. Falls back to [insertKeyAfterPredecessor] when
/// no preceding base key is present.
Map<String, dynamic> fillMissingKeysInBaseOrder(
  Map<String, dynamic> json,
  List<String> baseOrder,
  dynamic Function(String key) valueOf,
) {
  Map<String, dynamic> current = Map<String, dynamic>.of(json);
  String? lastPresent;
  for (final String key in baseOrder) {
    if (!current.containsKey(key)) {
      current = lastPresent == null
          ? insertKeyAfterPredecessor(current, key, valueOf(key))
          : _insertAfter(current, lastPresent, key, valueOf(key));
    }
    lastPresent = key;
  }
  return current;
}

/// Outcome of [mergeI18nThreeWay]: the merged, key-sorted table plus the keys
/// both sides changed differently (left at ours' value in [json]; the driver
/// writes them out as conflict blocks via [renderI18nMergeResult]).
class I18nMergeResult {
  const I18nMergeResult({required this.json, required this.conflicts});

  final Map<String, dynamic> json;
  final List<String> conflicts;
}

/// Key-level three-way merge of one i18n file — the git merge driver
/// (`tool/i18n_merge_driver.dart`) and its tests share this.
///
/// Per key: a side that left the key as in [base] yields to the other side's
/// change (add, edit or delete); both sides making the same change is no
/// conflict; both changing it differently keeps [ours] and reports the key.
/// The result is key-sorted, matching the invariant the guard
/// `test/i18n/i18n_keys_sorted_guard_test.dart` enforces, so a line-level
/// conflict between two sorted files never reaches a human.
I18nMergeResult mergeI18nThreeWay({
  required Map<String, dynamic> base,
  required Map<String, dynamic> ours,
  required Map<String, dynamic> theirs,
}) {
  final Map<String, dynamic> merged = <String, dynamic>{};
  final List<String> conflicts = <String>[];
  final Set<String> keys = <String>{...base.keys, ...ours.keys, ...theirs.keys};
  for (final String key in keys.toList()..sort()) {
    final bool inBase = base.containsKey(key);
    final bool inOurs = ours.containsKey(key);
    final bool inTheirs = theirs.containsKey(key);
    final bool oursChanged =
        inOurs != inBase || !_jsonEquals(ours[key], base[key]);
    final bool theirsChanged =
        inTheirs != inBase || !_jsonEquals(theirs[key], base[key]);

    final bool takeTheirs;
    if (!theirsChanged) {
      takeTheirs = false;
    } else if (!oursChanged) {
      takeTheirs = true;
    } else {
      final bool same =
          inOurs == inTheirs && _jsonEquals(ours[key], theirs[key]);
      if (!same) conflicts.add(key);
      takeTheirs = false;
    }

    if (takeTheirs) {
      if (inTheirs) merged[key] = theirs[key];
    } else if (inOurs) {
      merged[key] = ours[key];
    }
  }
  return I18nMergeResult(json: merged, conflicts: conflicts);
}

bool _jsonEquals(dynamic a, dynamic b) => jsonEncode(a) == jsonEncode(b);

/// Encode [json] exactly as every i18n file is stored on disk.
String encodeI18nJson(Map<String, dynamic> json) {
  const JsonEncoder encoder = JsonEncoder.withIndent('  ');
  return '${encoder.convert(json)}\n';
}

/// Render a [mergeI18nThreeWay] result as the merge driver's output file.
///
/// Without conflicts this is exactly [encodeI18nJson] of the merged table.
/// Every conflicting key instead becomes a git-style conflict block holding
/// [ours]' and [theirs]' entries (an empty side means that side deleted the
/// key). The file is then deliberately not valid JSON: neither side's value is
/// silently dropped, `git diff` shows both, and slang / the sorted-keys guard
/// refuse the file until a human resolves the block.
String renderI18nMergeResult(
  I18nMergeResult result, {
  required Map<String, dynamic> ours,
  required Map<String, dynamic> theirs,
}) {
  if (result.conflicts.isEmpty) return encodeI18nJson(result.json);
  final Set<String> conflicting = result.conflicts.toSet();
  final List<String> keys = <String>{
    ...result.json.keys,
    ...conflicting,
  }.toList()..sort();
  final StringBuffer out = StringBuffer('{\n');
  for (int i = 0; i < keys.length; i++) {
    final String key = keys[i];
    final String comma = i == keys.length - 1 ? '' : ',';
    if (!conflicting.contains(key)) {
      out.writeln('${_encodeI18nEntry(key, result.json[key])}$comma');
      continue;
    }
    out.writeln('<<<<<<< ours');
    if (ours.containsKey(key)) {
      out.writeln('${_encodeI18nEntry(key, ours[key])}$comma');
    }
    out.writeln('=======');
    if (theirs.containsKey(key)) {
      out.writeln('${_encodeI18nEntry(key, theirs[key])}$comma');
    }
    out.writeln('>>>>>>> theirs');
  }
  out.write('}\n');
  return out.toString();
}

/// One top-level entry exactly as [encodeI18nJson] lays it out (two-space
/// indent, nested values indented relative to it), without separator.
String _encodeI18nEntry(String key, dynamic value) {
  const JsonEncoder encoder = JsonEncoder.withIndent('  ');
  final String single = encoder.convert(<String, dynamic>{key: value});
  // "{\n  <entry>\n}" -> "  <entry>"
  return single.substring(2, single.length - 2);
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
      stdout.writeln(
        command.dryRun ? line.replaceFirst('  ', '  would ') : line,
      );
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
    '\n${command.dryRun ? "Would change" : "Changed"} $changed files.',
  );
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

    final Map<String, dynamic> original = _readJson(file);
    final List<String> missing = baseJson.keys
        .where((k) => !original.containsKey(k))
        .toList();
    if (missing.isEmpty) continue;

    final Map<String, dynamic> json = fillMissingKeysInBaseOrder(
      original,
      baseJson.keys.toList(),
      (String key) =>
          (zhCnJson[key] as String?) ?? (baseJson[key] as String? ?? ''),
    );
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
  file.writeAsStringSync(encodeI18nJson(json));
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
