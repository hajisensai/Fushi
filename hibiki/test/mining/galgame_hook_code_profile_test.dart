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

  // ── v2（options 尾列）────────────────────────────────────────────────────
  // native 侧 `native/galgame_hook/config/luna_hook_profiles.tsv` +
  // `include/luna_hook_config.h` 已是 v2；Dart 侧曾只认六列，读到 v2 表直接抛
  // FormatException（连 v2 表头行都过不去），导出还会把 options 静默丢掉。

  test('v2 seven-column rows parse and keep the options column verbatim', () {
    const String options =
        'block=EXHQXN8@1647F4;block-name=Krkr2wcs;prefer=HQXN-C@1D2F80;'
        'defer-ms=8000';
    final List<LunaHookCodeProfile> parsed = parseLunaHookCodeProfiles('''
# Hibiki Luna hook-code profiles v2. UTF-8, tab separated.
exe_sha256\tmodule_name\tmodule_sha256\tcodepage\thook_code\tlabel\toptions
${repeated('a')}\t\t\t932\tHQ@1234\twith options\t$options
''');
    expect(parsed, hasLength(1));
    expect(parsed.single.options, options);
  });

  test('v2 round-trips through encode without losing options', () {
    const String options = 'pc-hooks;defer-ms=8000';
    final String encoded = encodeLunaHookCodeProfiles(<LunaHookCodeProfile>[
      LunaHookCodeProfile(
        executableSha256: repeated('a'),
        moduleName: '',
        moduleSha256: '',
        codepage: 932,
        hookCode: 'HQ@1234',
        label: 'with options',
        options: options,
      ),
    ]);
    expect(encoded, contains('profiles v2.'));
    expect(
        encoded,
        contains('exe_sha256\tmodule_name\tmodule_sha256\tcodepage\t'
            'hook_code\tlabel\toptions'));
    expect(parseLunaHookCodeProfiles(encoded).single.options, options);
  });

  test('an options-only row (no hook code) is valid, as native accepts it', () {
    final List<LunaHookCodeProfile> parsed = parseLunaHookCodeProfiles(
      'exe_sha256\tmodule_name\tmodule_sha256\tcodepage\thook_code\tlabel'
      '\toptions\n'
      '${repeated('a')}\t\t\t932\t\tsafe profile\tblock=EXHQXN8@1647F4\n',
    );
    expect(parsed.single.hookCode, isEmpty);
    expect(parsed.single.options, 'block=EXHQXN8@1647F4');
  });

  test('a row with neither hook code nor options is still rejected', () {
    expect(
      () => parseLunaHookCodeProfiles(
        'exe_sha256\tmodule_name\tmodule_sha256\tcodepage\thook_code\tlabel'
        '\toptions\n'
        '${repeated('a')}\t\t\t932\t\tempty\t\n',
      ),
      throwsFormatException,
    );
  });

  test('the shipped native v2 profile table parses', () async {
    final File shipped =
        File('../native/galgame_hook/config/luna_hook_profiles.tsv');
    // 真相源就在本仓：直接拿它当 fixture，Dart 侧与 native 侧的列定义漂开时必红。
    expect(await shipped.exists(), isTrue,
        reason: 'native 侧 profile 真相源应存在于 ${shipped.absolute.path}');
    final List<LunaHookCodeProfile> parsed =
        parseLunaHookCodeProfiles(await shipped.readAsString());
    expect(parsed, isNotEmpty);
    expect(parsed.any((LunaHookCodeProfile p) => p.options.isNotEmpty), isTrue,
        reason: 'v2 表里应至少有一行带 options');
  });

  // ── 向后兼容：v1 不能被 v2 改动破坏 ─────────────────────────────────────

  test('a v1-only profile set still encodes as v1 six columns', () {
    final String encoded = encodeLunaHookCodeProfiles(<LunaHookCodeProfile>[
      LunaHookCodeProfile(
        executableSha256: repeated('a'),
        moduleName: '',
        moduleSha256: '',
        codepage: 932,
        hookCode: 'HQ@1234',
        label: 'plain',
      ),
    ]);
    // 没人用 options 就别升版本：旧 Hibiki（只认六列）读自己的表不会炸。
    expect(encoded, contains('profiles v1.'));
    expect(encoded, isNot(contains('\toptions')));
    expect(encoded, contains('${repeated('a')}\t\t\t932\tHQ@1234\tplain'));
  });

  test('unknown extra columns are ignored (v1/v2/v3 are prefix subsets)', () {
    final List<LunaHookCodeProfile> parsed = parseLunaHookCodeProfiles(
      'exe_sha256\tmodule_name\tmodule_sha256\tcodepage\thook_code\tlabel'
      '\toptions\tfuture\n'
      '${repeated('a')}\t\t\t932\tHQ@1234\tv3 row\tpc-hooks\twhatever\n',
    );
    expect(parsed.single.options, 'pc-hooks');
  });

  test('rows shorter than six columns are still rejected', () {
    expect(
      () => parseLunaHookCodeProfiles(
        'exe_sha256\tmodule_name\tmodule_sha256\tcodepage\thook_code\tlabel\n'
        '${repeated('a')}\t\t\t932\tHQ@1234\n',
      ),
      throwsFormatException,
    );
  });
}
