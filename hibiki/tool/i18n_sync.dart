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
import 'dart:convert';
import 'dart:io';

const String _i18nDir = 'lib/i18n';
const String _baseFile = 'strings.i18n.json';
const String _zhCnFile = 'strings_zh-CN.i18n.json';

void main(List<String> args) {
  final bool dryRun = args.contains('--dry-run');
  final int addIdx = args.indexOf('--add');
  final int removeIdx = args.indexOf('--remove');
  final int renameIdx = args.indexOf('--rename');
  final bool sortMode = args.contains('--sort');

  if (addIdx >= 0) {
    _addKey(args, addIdx, dryRun);
  } else if (removeIdx >= 0) {
    _removeKey(args, removeIdx, dryRun);
  } else if (renameIdx >= 0) {
    _renameKey(args, renameIdx, dryRun);
  } else if (sortMode) {
    _sortKeys(dryRun);
  } else {
    _syncMissing(dryRun);
  }
}

/// Add a new key to all language files.
void _addKey(List<String> args, int idx, bool dryRun) {
  final List<String> rest =
      args.sublist(idx + 1).where((a) => !a.startsWith('--')).toList();
  if (rest.length < 3) {
    stderr.writeln(
      'Usage: dart tool/i18n_sync.dart --add <key> <en_value> <zh_value>',
    );
    exit(1);
  }
  final String key = rest[0];
  final String enValue = rest[1];
  final String zhValue = rest[2];

  final List<File> files = _allI18nFiles();
  int changed = 0;

  for (final File file in files) {
    final Map<String, dynamic> json = _readJson(file);
    if (json.containsKey(key)) {
      stdout.writeln('  skip ${file.path} (key already exists)');
      continue;
    }

    final String value = _isZhCn(file) ? zhValue : enValue;
    json[key] = value;
    changed++;

    if (dryRun) {
      stdout.writeln('  would add "$key": "$value" to ${file.path}');
    } else {
      _writeJson(file, json);
      stdout.writeln('  added "$key" to ${file.path}');
    }
  }
  stdout.writeln('\n${dryRun ? "Would change" : "Changed"} $changed files.');
}

/// Remove a key from all language files.
void _removeKey(List<String> args, int idx, bool dryRun) {
  final List<String> rest =
      args.sublist(idx + 1).where((a) => !a.startsWith('--')).toList();
  if (rest.isEmpty) {
    stderr.writeln('Usage: dart tool/i18n_sync.dart --remove <key>');
    exit(1);
  }
  final String key = rest[0];
  final List<File> files = _allI18nFiles();
  int changed = 0;

  for (final File file in files) {
    final Map<String, dynamic> json = _readJson(file);
    if (!json.containsKey(key)) continue;
    json.remove(key);
    changed++;

    if (dryRun) {
      stdout.writeln('  would remove "$key" from ${file.path}');
    } else {
      _writeJson(file, json);
      stdout.writeln('  removed "$key" from ${file.path}');
    }
  }
  stdout.writeln('\n${dryRun ? "Would change" : "Changed"} $changed files.');
}

/// Rename a key in all language files, preserving each language's translation.
///
/// Unlike `--remove` + `--add` (which would reset all non-en/zh translations
/// to a fallback), this keeps every existing value untouched and only changes
/// the key. Fails without writing anything if the target key already exists
/// in any file.
void _renameKey(List<String> args, int idx, bool dryRun) {
  final List<String> rest =
      args.sublist(idx + 1).where((a) => !a.startsWith('--')).toList();
  if (rest.length < 2) {
    stderr.writeln(
        'Usage: dart tool/i18n_sync.dart --rename <old_key> <new_key>');
    exit(1);
  }
  final String oldKey = rest[0];
  final String newKey = rest[1];
  if (oldKey == newKey) {
    stderr.writeln('Error: old and new key are identical ("$oldKey").');
    exit(1);
  }

  final List<File> files = _allI18nFiles();

  // Pre-flight: never write a partial rename.
  final Map<String, Map<String, dynamic>> parsed =
      <String, Map<String, dynamic>>{};
  int found = 0;
  for (final File file in files) {
    final Map<String, dynamic> json = _readJson(file);
    if (json.containsKey(newKey)) {
      stderr.writeln(
        'Error: target key "$newKey" already exists in ${file.path}; aborting.',
      );
      exit(1);
    }
    if (json.containsKey(oldKey)) found++;
    parsed[file.path] = json;
  }
  if (found == 0) {
    stderr.writeln('Error: key "$oldKey" not found in any i18n file.');
    exit(1);
  }

  int changed = 0;
  for (final File file in files) {
    final Map<String, dynamic> json = parsed[file.path]!;
    if (!json.containsKey(oldKey)) {
      stdout.writeln('  skip ${file.path} (key not present)');
      continue;
    }

    final Map<String, dynamic> renamed = <String, dynamic>{};
    json.forEach((String k, dynamic v) {
      renamed[k == oldKey ? newKey : k] = v;
    });
    changed++;

    if (dryRun) {
      stdout.writeln('  would rename "$oldKey" -> "$newKey" in ${file.path}');
    } else {
      _writeJson(file, renamed);
      stdout.writeln('  renamed "$oldKey" -> "$newKey" in ${file.path}');
    }
  }
  stdout.writeln('\n${dryRun ? "Would change" : "Changed"} $changed files.');
}

/// Sort keys alphabetically in all language files (stable, idempotent).
void _sortKeys(bool dryRun) {
  final List<File> files = _allI18nFiles();
  int changed = 0;

  for (final File file in files) {
    final Map<String, dynamic> json = _readJson(file);
    final List<String> keys = json.keys.toList();
    final List<String> sortedKeys = List<String>.of(keys)..sort();
    if (_listEquals(keys, sortedKeys)) continue;

    final Map<String, dynamic> sorted = <String, dynamic>{
      for (final String k in sortedKeys) k: json[k],
    };
    changed++;

    if (dryRun) {
      stdout.writeln('  would sort ${file.path}');
    } else {
      _writeJson(file, sorted);
      stdout.writeln('  sorted ${file.path}');
    }
  }

  if (changed == 0) {
    stdout.writeln('All i18n files are already sorted.');
  } else {
    stdout.writeln('\n${dryRun ? "Would change" : "Changed"} $changed files.');
  }
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
