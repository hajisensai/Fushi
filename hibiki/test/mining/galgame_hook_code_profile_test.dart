import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/mining/galgame_audio_source.dart';
import 'package:hibiki/src/mining/galgame_hook_code_profile.dart';

void main() {
  String repeated(String value) => List<String>.filled(64, value).join();

  test('profile TSV round-trips executable and module SHA-256 identities', () {
    final List<LunaHookCodeProfile> parsed = parseLunaHookCodeProfiles('''
exe_sha256\tmodule_name\tmodule_sha256\tcodepage\thook_code\tlabel
${repeated('a')}\t\t\t932\tHQ@1234\texecutable
\tkirikiri.dll\t${repeated('b')}\t932\tEX@5678\tmodule
''');
    expect(parsed, hasLength(2));
    expect(
      parseLunaHookCodeProfiles(encodeLunaHookCodeProfiles(parsed)),
      hasLength(2),
    );
  });

  test('profile store imports, persists, exports, and upserts', () async {
    final Directory temp =
        await Directory.systemTemp.createTemp('luna_profile');
    addTearDown(() => temp.delete(recursive: true));
    final File persistent = File('${temp.path}/profiles.tsv');
    final File imported = File('${temp.path}/import.tsv');
    final File exported = File('${temp.path}/export.tsv');
    await imported.writeAsString('''
exe_sha256\tmodule_name\tmodule_sha256\tcodepage\thook_code\tlabel
${repeated('c')}\t\t\t932\tHQ@1234\tfirst
''');
    final LunaHookCodeProfileStore store = LunaHookCodeProfileStore(persistent);
    await store.replaceFrom(imported);
    await store.upsert(
      LunaHookCodeProfile(
        executableSha256: repeated('d'),
        moduleName: '',
        moduleSha256: '',
        codepage: 932,
        hookCode: 'EX@5678',
        label: 'second',
      ),
    );
    await store.exportTo(exported);
    expect(
        parseLunaHookCodeProfiles(await exported.readAsString()), hasLength(2));
  });

  test('injector arguments pass profile and explicit diagnostic codes', () {
    expect(
      buildEngineHookInjectorArguments(
        targetPid: 42,
        launchExe: null,
        lunaHookProfilePath: r'C:\profiles.tsv',
        lunaHookCodes: const <String>['HQ@1234', 'EX@5678'],
      ),
      containsAllInOrder(<String>[
        '--luna-hook-profile',
        r'C:\profiles.tsv',
        '--luna-hook-code',
        'HQ@1234',
        '--luna-hook-code',
        'EX@5678',
      ]),
    );
  });

  test('invalid path-only profile is rejected', () {
    expect(
      () => parseLunaHookCodeProfiles(
        'exe_sha256\tmodule_name\tmodule_sha256\tcodepage\thook_code\tlabel\n'
        '\t\t\t932\tHQ@1234\tpath-only\n',
      ),
      throwsFormatException,
    );
  });
}
