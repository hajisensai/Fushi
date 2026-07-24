import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki/src/storage/app_paths.dart';

const String _profileHeader =
    'exe_sha256\tmodule_name\tmodule_sha256\tcodepage\thook_code\tlabel';
final RegExp _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

class LunaHookCodeProfile {
  const LunaHookCodeProfile({
    required this.executableSha256,
    required this.moduleName,
    required this.moduleSha256,
    required this.codepage,
    required this.hookCode,
    required this.label,
  });

  final String executableSha256;
  final String moduleName;
  final String moduleSha256;
  final int codepage;
  final String hookCode;
  final String label;

  String get identityKey =>
      '$executableSha256|${moduleName.toLowerCase()}|$moduleSha256|$hookCode';

  void validate() {
    if (executableSha256.isEmpty && moduleSha256.isEmpty) {
      throw const FormatException(
          'A profile needs an executable or module hash.');
    }
    if (executableSha256.isNotEmpty &&
        !_sha256Pattern.hasMatch(executableSha256)) {
      throw const FormatException('Invalid executable SHA-256.');
    }
    if (moduleSha256.isNotEmpty &&
        (!_sha256Pattern.hasMatch(moduleSha256) || moduleName.isEmpty)) {
      throw const FormatException('A module hash needs a valid hash and name.');
    }
    if (codepage <= 0 || hookCode.trim().isEmpty) {
      throw const FormatException('Invalid codepage or empty Hook Code.');
    }
    if (<String>[moduleName, hookCode, label].any((value) =>
        value.contains('\t') || value.contains('\n') || value.contains('\r'))) {
      throw const FormatException(
          'Profile fields cannot contain tabs or lines.');
    }
  }

  String toTsvRow() => <Object>[
        executableSha256,
        moduleName,
        moduleSha256,
        codepage,
        hookCode,
        label,
      ].join('\t');
}

List<LunaHookCodeProfile> parseLunaHookCodeProfiles(String input) {
  final List<LunaHookCodeProfile> result = <LunaHookCodeProfile>[];
  for (final String rawLine in const LineSplitter().convert(input)) {
    final String line = rawLine.trimRight();
    if (line.isEmpty || line.startsWith('#') || line == _profileHeader) {
      continue;
    }
    final List<String> fields = line.split('\t');
    if (fields.length != 6) {
      throw const FormatException('Hook Code profile rows need six columns.');
    }
    final LunaHookCodeProfile profile = LunaHookCodeProfile(
      executableSha256: fields[0].toLowerCase(),
      moduleName: fields[1],
      moduleSha256: fields[2].toLowerCase(),
      codepage: int.tryParse(fields[3]) ?? 0,
      hookCode: fields[4],
      label: fields[5],
    );
    profile.validate();
    result.add(profile);
  }
  return result;
}

String encodeLunaHookCodeProfiles(Iterable<LunaHookCodeProfile> profiles) {
  final List<LunaHookCodeProfile> sorted = profiles.toList()
    ..sort((a, b) => a.identityKey.compareTo(b.identityKey));
  return <String>[
    '# Hibiki Luna hook-code profiles v1. UTF-8, tab separated.',
    _profileHeader,
    ...sorted.map((profile) => profile.toTsvRow()),
    '',
  ].join('\n');
}

Future<String> sha256File(File file) async =>
    sha256.convert(await file.readAsBytes()).toString();

class LunaHookCodeProfileStore {
  LunaHookCodeProfileStore(this.file);

  final File file;

  static Future<LunaHookCodeProfileStore> openDefault() async {
    final Directory root = await AppPaths.supportRootDirectory();
    final File file =
        File(p.join(root.path, 'galgame', 'luna_hook_profiles.tsv'));
    final LunaHookCodeProfileStore store = LunaHookCodeProfileStore(file);
    await store.ensureExists();
    return store;
  }

  Future<void> ensureExists() async {
    await file.parent.create(recursive: true);
    if (!await file.exists()) {
      await file.writeAsString(encodeLunaHookCodeProfiles(const []),
          encoding: utf8, flush: true);
    }
  }

  Future<List<LunaHookCodeProfile>> load() async {
    await ensureExists();
    return parseLunaHookCodeProfiles(await file.readAsString(encoding: utf8));
  }

  Future<void> replaceFrom(File imported) async {
    final List<LunaHookCodeProfile> profiles =
        parseLunaHookCodeProfiles(await imported.readAsString(encoding: utf8));
    await save(profiles);
  }

  Future<void> exportTo(File destination) async {
    await destination.writeAsString(
      encodeLunaHookCodeProfiles(await load()),
      encoding: utf8,
      flush: true,
    );
  }

  Future<void> upsert(LunaHookCodeProfile profile) async {
    profile.validate();
    final List<LunaHookCodeProfile> profiles = await load();
    profiles.removeWhere((item) => item.identityKey == profile.identityKey);
    profiles.add(profile);
    await save(profiles);
  }

  Future<void> save(Iterable<LunaHookCodeProfile> profiles) async {
    for (final LunaHookCodeProfile profile in profiles) {
      profile.validate();
    }
    await ensureExists();
    await file.writeAsString(
      encodeLunaHookCodeProfiles(profiles),
      encoding: utf8,
      flush: true,
    );
  }
}
