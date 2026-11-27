import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// Guard: the Mihon desktop runtime builds without reaching any third-party host
/// (2026-11-27).
///
/// The release build used to resolve M-Extension-Server's Gradle dependencies live
/// (Maven Central answered 429 and failed the Linux release), download the Gradle
/// distribution through `gradlew`, and fetch the JDK from corretto.aws / adoptium on
/// every cache miss. Now:
///
/// * both build scripts take the JDK, the Gradle distribution and a Gradle read-only
///   dependency cache from the vendored offline kit (`third_party/mihon_build`, pinned in
///   `tool/vendored_binaries.json`) and run Gradle `--offline` with a fresh
///   `GRADLE_USER_HOME`; nothing in them downloads;
/// * the JDK pins written into each runtime's checksums.json agree with the manifest;
/// * every CI job that bundles the runtime restores it from the native artifact store
///   first (no actions/cache: the 10 GB quota evicts entries before they are read) and
///   fetches the offline kit only on a miss.
///
/// Text only, so it runs in ci-config-gate.
void main() {
  const String repo = '..';
  final String sh = File(
    '$repo/tool/mihon/build_desktop_runtime.sh',
  ).readAsStringSync();
  final String ps1 = File(
    '$repo/tool/mihon/build_desktop_runtime.ps1',
  ).readAsStringSync().replaceAll('\r\n', '\n');
  final Map<String, dynamic> manifest =
      jsonDecode(File('$repo/tool/vendored_binaries.json').readAsStringSync())
          as Map<String, dynamic>;
  final Map<String, Map<String, dynamic>> byPath =
      <String, Map<String, dynamic>>{
        for (final Map<String, dynamic> entry
            in (manifest['files'] as List<dynamic>)
                .cast<Map<String, dynamic>>())
          entry['path'] as String: entry,
      };
  const String kit = 'third_party/mihon_build';

  String pinned(String script, RegExp pattern, String what) {
    final RegExpMatch? match = pattern.firstMatch(script);
    expect(match, isNotNull, reason: 'cannot find $what');
    return match!.group(1)!;
  }

  test(
    'build scripts never download (no curl / Invoke-WebRequest / gradlew)',
    () {
      for (final MapEntry<String, String> script in <String, String>{
        'build_desktop_runtime.sh': sh,
        'build_desktop_runtime.ps1': ps1,
      }.entries) {
        final String code = script.value
            .split('\n')
            .where((String l) => !l.trimLeft().startsWith('#'))
            .join('\n');
        for (final String banned in <String>[
          'curl ',
          'wget ',
          'Invoke-WebRequest',
          'Start-BitsTransfer',
          'https://',
          'gradlew',
        ]) {
          expect(
            code.contains(banned),
            isFalse,
            reason:
                '${script.key} must not use `$banned`: the build is offline',
          );
        }
        expect(code, contains('GRADLE_RO_DEP_CACHE'), reason: script.key);
        expect(code, contains('--offline'), reason: script.key);
        expect(
          code,
          contains('gradle-ro-dep-cache.tar.gz'),
          reason: script.key,
        );
        expect(
          code,
          contains('vendored_binaries.py'),
          reason: '${script.key} fetches its kit through the vendored tool',
        );
        expect(code, contains('mihon-build'), reason: script.key);
      }
    },
  );

  test('offline kit entries are in the manifest under their groups', () {
    final String gradle = pinned(
      sh,
      RegExp(r'gradle_version="([^"]+)"'),
      'sh gradle_version',
    );
    expect(
      pinned(ps1, RegExp(r'\$gradleVersion = "([^"]+)"'), 'ps1 gradleVersion'),
      gradle,
    );
    expect(byPath['$kit/gradle-$gradle-bin.zip']?['group'], 'mihon-build');
    expect(byPath['$kit/gradle-ro-dep-cache.tar.gz']?['group'], 'mihon-build');
  });

  test('sh build runs from a canonical (symlink-free) working directory', () {
    // macOS $TMPDIR 在 /var/folders 下（/var -> /private/var）。GRADLE_RO_DEP_CACHE
    // 带符号链接时 Kotlin DSL 的 script classpath 会漏掉只读缓存里的插件 jar
    // （"Unresolved reference 'JvmTarget'"），所以工作目录必须先 pwd -P 规范化。
    expect(
      RegExp(
        r'working_root="\$\(cd "\$\(mktemp -d [^\n]*\)" && pwd -P\)"',
      ).hasMatch(sh),
      isTrue,
      reason: 'working_root must be canonicalized with pwd -P',
    );
  });

  test('JDK pins in the scripts agree with the vendored manifest', () {
    final String corretto = pinned(
      sh,
      RegExp(r'corretto_version="([^"]+)"'),
      'corretto_version',
    );
    final Map<String, List<String>> shJdks = <String, List<String>>{
      'mihon-jdk-linux-x64': <String>['linux-x64', 'x64_archive_sha256'],
      'mihon-jdk-linux-arm64': <String>[
        'linux-aarch64',
        'arm64_archive_sha256',
      ],
      'mihon-jdk-macos-arm64': <String>[
        'macosx-aarch64',
        'arm64_archive_sha256',
      ],
    };
    // The Linux case block reassigns arm64_archive_sha256; read each pin from its own line pair.
    final List<RegExpMatch> pairs = RegExp(
      r'(x64|arm64)_archive="amazon-corretto-\$corretto_version-([a-z0-9_-]+)\.tar\.gz"\s*\n\s*\1_archive_sha256="([0-9a-f]{64})"',
    ).allMatches(sh).toList();
    final Map<String, String> shaBySuffix = <String, String>{
      for (final RegExpMatch m in pairs) m.group(2)!: m.group(3)!,
    };
    shJdks.forEach((String group, List<String> spec) {
      final String path =
          '$kit/jdk/amazon-corretto-$corretto-${spec[0]}.tar.gz';
      final Map<String, dynamic>? entry = byPath[path];
      expect(entry, isNotNull, reason: '$path must be a manifest entry');
      expect(entry!['group'], group, reason: path);
      expect(shaBySuffix[spec[0]], entry['sha256'], reason: path);
    });
    expect(sh, contains('jdk_group="mihon-jdk-macos-arm64"'));
    expect(sh, contains(r'jdk_group="mihon-jdk-linux-$host_architecture"'));
    expect(sh, contains('x86_64) host_architecture="x64"'));
    expect(sh, contains('arm64|aarch64) host_architecture="arm64"'));
    final String temurin = pinned(
      ps1,
      RegExp(r'\$temurinArchive = "([^"]+)"'),
      'temurinArchive',
    );
    final String temurinSha = pinned(
      ps1,
      RegExp(r'\$temurinSha256 = "([0-9a-f]{64})"'),
      'temurinSha256',
    );
    final Map<String, dynamic>? entry = byPath['$kit/jdk/$temurin'];
    expect(
      entry,
      isNotNull,
      reason: '$kit/jdk/$temurin must be a manifest entry',
    );
    expect(entry!['group'], 'mihon-jdk-windows-x64');
    expect(entry['sha256'], temurinSha);
    expect(ps1, contains('"--group", "mihon-jdk-windows-x64"'));
  });

  test('every CI job that bundles the runtime restores it from the store first', () {
    final List<File> workflows =
        Directory('$repo/.github/workflows')
            .listSync()
            .whereType<File>()
            .where((File f) => f.path.endsWith('.yml'))
            .toList()
          ..sort((File a, File b) => a.path.compareTo(b.path));
    int sites = 0;
    for (final File file in workflows) {
      final String text = file.readAsStringSync().replaceAll('\r\n', '\n');
      final String name = file.uri.pathSegments.last;
      expect(
        text.contains('mihon-runtime-v1-\${{ hashFiles'),
        isFalse,
        reason:
            '$name: the Mihon runtime lives in the native artifact store, not actions/cache',
      );
      for (final RegExpMatch call in RegExp(
        r'build_desktop_runtime\.(sh|ps1)|tool/linux/build_bundle\.sh',
      ).allMatches(text)) {
        final String before = text.substring(0, call.start);
        if (before.split('\n').last.trimLeft().startsWith('#')) continue;
        if (call.group(0)!.startsWith('build_desktop_runtime.sh') &&
            before.endsWith('chmod +x tool/mihon/')) {
          continue;
        }
        sites++;
        final int restore = before.lastIndexOf('id: mihon_runtime_store');
        expect(
          restore,
          isNot(-1),
          reason: '$name: ${call.group(0)} without a store restore',
        );
        final String between = before.substring(restore);
        expect(
          between,
          contains('uses: ./.github/actions/native-artifact-store'),
          reason: name,
        );
        expect(between, contains('outputs.mihon }}'), reason: name);
        expect(
          between,
          contains('name: Fetch Mihon offline build kit'),
          reason:
              '$name: fetch the offline kit (on a miss) before ${call.group(0)}',
        );
        expect(
          between,
          contains("if: steps.mihon_runtime_store.outputs.hit != 'true'"),
          reason: name,
        );
        final String after = text.substring(call.end);
        final int save = after.indexOf(
          'name: Save Mihon desktop runtime to native artifact store',
        );
        expect(
          save,
          isNot(-1),
          reason: '$name: ${call.group(0)} without a store save',
        );
      }
    }
    // release-desktop windows / macos / linux, build-multiplatform windows / macos.
    expect(
      sites,
      5,
      reason: 'enumeration collapsed or a new bundling site appeared',
    );
  });

  test(
    'the Linux bundle reads the restored runtime and fetches only the mihon group',
    () {
      final String bundle = File(
        '$repo/tool/linux/build_bundle.sh',
      ).readAsStringSync();
      expect(
        bundle,
        contains(r'FUSHI_VENDORED_GROUPS="${FUSHI_VENDORED_GROUPS:-mihon}"'),
      );
      expect(bundle, contains('FUSHI_MIHON_RUNTIME_DIR'));
      final String workflow = File(
        '$repo/.github/workflows/release-desktop.yml',
      ).readAsStringSync();
      expect(
        workflow,
        contains('-e FUSHI_MIHON_RUNTIME_DIR=/src/build/mihon-runtime'),
      );
    },
  );
}
