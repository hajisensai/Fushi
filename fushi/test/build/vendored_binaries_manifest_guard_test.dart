import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guard: prebuilt third-party binaries stay OUT of git (2026-11-01).
///
/// libmpv / ANGLE / libplacebo / FFmpegKit / bluray-menu jars / LunaHook /
/// jogamp used to be committed; every rebuild added 20-45 MB to history. They
/// now live as assets of the `vendored-binaries` GitHub release, pinned by
/// `tool/vendored_binaries.json` (path / size / sha256 / url), gitignored at
/// their original paths, and restored by `tool/vendored_binaries.py fetch`
/// (tool/bootstrap.*, `.github/actions/fetch-vendored-binaries`, the dist_test
/// worker prepare script). This guard pins every link of that chain so neither
/// half can drift silently:
///
/// * nothing big under `third_party/` / `native/**/third_party/` is tracked
///   again (the only allowlisted big files are the upstream source tree's
///   fonts), and every manifest path is gitignored and untracked;
/// * the manifest is well formed and content-addressed (an old commit keeps
///   resolving to its own bytes);
/// * each consumer's own pin (CMake archive names, SHA256SUMS, VERSION.json,
///   sha256.json, provenance.json, the xcframework layout) agrees with the
///   manifest, so a bump that updates one side but not the other is red here
///   without needing the binaries on disk;
/// * every build / test job that reads the files fetches them right after
///   checkout, and the local / dist entry points call the tool.
///
/// Only text files are read, so this runs in ci-config-gate cheaply.
void main() {
  const String repo = '..';
  final File manifestFile = File('$repo/tool/vendored_binaries.json');
  final Map<String, dynamic> manifest =
      jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
  final List<Map<String, dynamic>> files = (manifest['files'] as List<dynamic>)
      .cast<Map<String, dynamic>>();
  final Map<String, Map<String, dynamic>> byPath =
      <String, Map<String, dynamic>>{
        for (final Map<String, dynamic> entry in files)
          entry['path'] as String: entry,
      };

  String shaOf(String path) {
    final Map<String, dynamic>? entry = byPath[path];
    expect(
      entry,
      isNotNull,
      reason: '$path must be listed in tool/vendored_binaries.json',
    );
    return entry!['sha256'] as String;
  }

  List<String> git(List<String> args) {
    final ProcessResult result = Process.runSync(
      'git',
      args,
      workingDirectory: repo,
      stdoutEncoding: utf8,
    );
    expect(
      result.exitCode,
      0,
      reason: 'git ${args.join(' ')}: ${result.stderr}',
    );
    return (result.stdout as String)
        .split('\n')
        .where((String line) => line.isNotEmpty)
        .toList();
  }

  test('manifest is well formed and content-addressed', () {
    expect(manifest['repo'], 'hajisensai/Fushi');
    expect(manifest['tag'], 'vendored-binaries');
    expect(files, isNotEmpty);
    expect(byPath.length, files.length, reason: 'duplicate paths');
    const Set<String> groups = <String>{
      'windows',
      'galgame',
      'mihon',
      'android',
      'ios',
      'macos',
    };
    for (final Map<String, dynamic> entry in files) {
      final String path = entry['path'] as String;
      final String sha = entry['sha256'] as String;
      expect(groups, contains(entry['group']), reason: path);
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(sha), isTrue, reason: path);
      expect(entry['size'] as int, greaterThan(0), reason: path);
      expect(
        entry['url'],
        'https://github.com/hajisensai/Fushi/releases/download/vendored-binaries/'
        '${sha.substring(0, 16)}-${path.split('/').last}',
        reason:
            '$path: asset names are <sha256[:16]>-<basename> so every '
            'version of a path keeps its own asset (register via '
            'tool/vendored_binaries.py register)',
      );
    }
  });

  test('every manifest path is untracked and gitignored by its own line', () {
    final Set<String> ignoreLines = File(
      '$repo/.gitignore',
    ).readAsLinesSync().map((String line) => line.trim()).toSet();
    final List<String> paths = byPath.keys.toList()..sort();
    for (final String path in paths) {
      expect(
        ignoreLines,
        contains('/$path'),
        reason: '.gitignore must list /$path',
      );
    }
    expect(
      git(<String>['ls-files', '--', ...paths]),
      isEmpty,
      reason: 'vendored binaries must not be tracked (git rm --cached them)',
    );
    final List<String> ignored = git(<String>[
      'check-ignore',
      '--no-index',
      ...paths,
    ]);
    expect(
      ignored.toSet(),
      paths.toSet(),
      reason: 'a later negation rule must not re-include a vendored binary',
    );
  });

  test('no tracked file > 1 MiB under third_party/ or native/**/third_party/', () {
    // The upstream m_extension_server source tree ships its fonts as source;
    // they are not prebuilt binaries and stay as they are.
    bool allowlisted(String path) =>
        path.startsWith(
          'third_party/m_extension_server/upstream_src/AndroidCompat/src/main/resources/font/',
        ) &&
        path.endsWith('.ttf');
    final List<String> tracked =
        git(<String>['ls-files', '--', 'third_party', 'native'])
            .where(
              (String path) =>
                  path.startsWith('third_party/') ||
                  RegExp(r'^native/(.+/)?third_party/').hasMatch(path),
            )
            .toList();
    expect(tracked.length, greaterThan(100), reason: 'enumeration collapsed');
    final List<String> offenders = <String>[];
    for (final String path in tracked) {
      final File file = File('$repo/$path');
      if (!file.existsSync() || allowlisted(path)) continue;
      if (file.lengthSync() > 1024 * 1024) {
        offenders.add('$path (${file.lengthSync()} B)');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'prebuilt binaries go to the vendored-binaries release, not git: '
          'tool/vendored_binaries.py register --group <g> <path>, then publish '
          '(docs/agent/build.md)',
    );
  });

  test(
    'Windows libmpv / ANGLE archives pinned in CMake are manifest entries',
    () {
      final String cmake = File(
        '$repo/third_party/media_kit_libs_windows_video/windows/CMakeLists.txt',
      ).readAsStringSync();
      for (final String name in <String>['LIBMPV', 'ANGLE']) {
        final RegExpMatch? match = RegExp(
          'set\\($name\\s+"([^"]+)"\\)',
        ).firstMatch(cmake);
        expect(match, isNotNull, reason: 'set($name "...") in CMakeLists.txt');
        final String path =
            'third_party/media_kit_libs_windows_video/vendored/${match!.group(1)}';
        expect(byPath[path]?['group'], 'windows', reason: path);
      }
    },
  );

  test('libplacebo SHA256SUMS agrees with the manifest', () {
    final List<String> lines = File(
      '$repo/third_party/libplacebo-win/bin/SHA256SUMS',
    ).readAsLinesSync().where((String l) => l.trim().isNotEmpty).toList();
    expect(lines, isNotEmpty);
    for (final String line in lines) {
      final List<String> parts = line.trim().split(RegExp(r'\s+'));
      expect(
        shaOf('third_party/libplacebo-win/bin/${parts.last}'),
        parts.first.toLowerCase(),
      );
    }
  });

  test('LunaHook VERSION.json agrees with the manifest', () {
    const String dir = 'native/galgame_hook/third_party/lunahook';
    final Map<String, dynamic> version =
        jsonDecode(File('$repo/$dir/VERSION.json').readAsStringSync())
            as Map<String, dynamic>;
    final Map<String, dynamic> pinned =
        version['files'] as Map<String, dynamic>;
    expect(pinned, isNotEmpty);
    pinned.forEach((String name, dynamic sha) {
      expect(shaOf('$dir/$name'), (sha as String).toLowerCase(), reason: name);
    });
  });

  test(
    'Android bluray-menu sha256.json and the FFmpegKit AAR agree with the manifest',
    () {
      const String dir =
          'third_party/media_kit_libs_android_video/android/native/bluray-menu-v1';
      final Map<String, dynamic> pinned =
          jsonDecode(File('$repo/$dir/sha256.json').readAsStringSync())
              as Map<String, dynamic>;
      expect(pinned, isNotEmpty);
      pinned.forEach((String name, dynamic sha) {
        expect(shaOf('$dir/$name'), sha, reason: name);
      });
      expect(
        byPath['third_party/ffmpeg_kit_next_flutter/android/libs/ffmpeg-kit-next.aar']?['group'],
        'android',
      );
    },
  );

  test(
    'Darwin libmpv provenance and the macOS FFmpeg layout agree with the manifest',
    () {
      for (final String platform in <String>['ios', 'macos']) {
        final String dir =
            'third_party/media_kit_libs_${platform}_video/native';
        final Map<String, dynamic> provenance =
            jsonDecode(File('$repo/$dir/provenance.json').readAsStringSync())
                as Map<String, dynamic>;
        final String path = '$dir/${provenance['archive']}';
        expect(shaOf(path), provenance['archive_sha256'], reason: path);
        expect(byPath[path]!['group'], platform, reason: path);
      }
      expect(
        byPath['third_party/media_kit_libs_macos_video/native/ffmpeg-unified-macos.tar.gz']?['group'],
        'macos',
      );
    },
  );

  test('every FFmpegKit iOS framework binary is a manifest entry', () {
    const String frameworks =
        'third_party/ffmpeg_kit_next_flutter/ios/ffmpeg_kit_next_flutter/Frameworks';
    final RegExp plist = RegExp(
      r'^(.+/([A-Za-z0-9_]+)\.framework)/Info\.plist$',
    );
    final List<String> binaries = <String>[
      for (final String path in git(<String>['ls-files', '--', frameworks]))
        if (plist.firstMatch(path) case final RegExpMatch m)
          '${m.group(1)}/${m.group(2)}',
    ];
    expect(
      binaries.length,
      greaterThanOrEqualTo(20),
      reason: 'enumeration collapsed',
    );
    for (final String path in binaries) {
      expect(byPath[path]?['group'], 'ios', reason: path);
    }
  });

  test('jogamp offline Maven jars are manifest entries', () {
    for (final String path in <String>[
      'third_party/jogamp/org/jogamp/jogl/jogl-all/2.5.0/jogl-all-2.5.0.jar',
      'third_party/jogamp/org/jogamp/gluegen/gluegen-rt/2.5.0/gluegen-rt-2.5.0.jar',
    ]) {
      expect(byPath[path]?['group'], 'mihon', reason: path);
    }
  });

  group('fetch is wired into every consumer', () {
    /// workflow -> job -> groups the job's consumers need.
    const Map<String, Map<String, Set<String>>> jobs =
        <String, Map<String, Set<String>>>{
          'main.yml': <String, Set<String>>{
            'build': <String>{'android'},
            'unit-tests': <String>{'all'},
          },
          'release.yml': <String, Set<String>>{
            'build': <String>{'android'},
            'tests': <String>{'all'},
          },
          'build-multiplatform.yml': <String, Set<String>>{
            'android': <String>{'android'},
            'macos': <String>{'macos', 'mihon'},
            'ios': <String>{'ios'},
            'windows': <String>{'windows', 'galgame', 'mihon'},
          },
          'release-desktop.yml': <String, Set<String>>{
            'windows': <String>{'windows', 'galgame', 'mihon'},
            'macos': <String>{'macos', 'mihon'},
            'ios': <String>{'ios'},
          },
          'ci-config-gate.yml': <String, Set<String>>{
            'guards': <String>{'all'},
          },
          'native-galgame-gate.yml': <String, Set<String>>{
            'guards': <String>{'galgame'},
          },
        };

    jobs.forEach((String workflow, Map<String, Set<String>> byJob) {
      byJob.forEach((String job, Set<String> needed) {
        test(
          '$workflow:$job fetches ${needed.join(' ')} right after checkout',
          () {
            final List<String> lines = File(
              '$repo/.github/workflows/$workflow',
            ).readAsStringSync().replaceAll('\r\n', '\n').split('\n');
            final int start = lines.indexOf('  $job:');
            expect(start, isNot(-1), reason: '$workflow has no job $job');
            int end = lines.length;
            for (int i = start + 1; i < lines.length; i++) {
              if (RegExp(r'^  [A-Za-z0-9_-]+:\s*$').hasMatch(lines[i])) {
                end = i;
                break;
              }
            }
            final RegExp stepStart = RegExp(r'^(\s*)- ');
            // Steps of this job, comments dropped, as (indent, first line, body).
            final List<List<String>> steps = <List<String>>[];
            int? indent;
            for (int i = start; i < end; i++) {
              final String line = lines[i];
              if (line.trim().startsWith('#') || line.trim().isEmpty) continue;
              final RegExpMatch? m = stepStart.firstMatch(line);
              if (m != null &&
                  (indent == null || m.group(1)!.length == indent) &&
                  RegExp(
                    r'^\s*- (name|uses|id|if|run|shell|with|env)\b',
                  ).hasMatch(line)) {
                indent ??= m.group(1)!.length;
                steps.add(<String>[line]);
              } else if (steps.isNotEmpty) {
                steps.last.add(line);
              }
            }
            final int checkout = steps.indexWhere(
              (List<String> s) =>
                  s.any((String l) => l.contains('uses: actions/checkout')),
            );
            expect(checkout, isNot(-1), reason: '$workflow:$job checkout');
            expect(checkout + 1, lessThan(steps.length));
            final String fetch = steps[checkout + 1].join('\n');
            expect(
              fetch,
              contains('uses: ./.github/actions/fetch-vendored-binaries'),
              reason:
                  '$workflow:$job must fetch the vendored binaries as the '
                  'step right after checkout (they are not in git)',
            );
            final RegExpMatch? groups = RegExp(
              r'groups:\s*(.+)$',
              multiLine: true,
            ).firstMatch(fetch);
            expect(groups, isNotNull);
            final Set<String> got = groups!
                .group(1)!
                .trim()
                .split(RegExp(r'\s+'))
                .toSet();
            expect(
              got.contains('all') || got.containsAll(needed),
              isTrue,
              reason: '$workflow:$job fetches $got, needs $needed',
            );
          },
        );
      });
    });

    test('composite action runs the single fetch implementation', () {
      final String action = File(
        '$repo/.github/actions/fetch-vendored-binaries/action.yml',
      ).readAsStringSync();
      expect(action, contains('tool/vendored_binaries.py fetch'));
    });

    test('bootstrap, worktree and dist worker entry points fetch', () {
      expect(
        File('$repo/tool/bootstrap.ps1').readAsStringSync(),
        contains("'vendored_binaries.ps1'"),
      );
      expect(
        File('$repo/tool/vendored_binaries.ps1').readAsStringSync(),
        contains("'vendored_binaries.py'"),
      );
      expect(
        File('$repo/tool/bootstrap.sh').readAsStringSync(),
        contains('tool/vendored_binaries.py fetch'),
      );
      final String worker = File(
        '$repo/fushi/tool/dist_test/worker_prepare.sh',
      ).readAsStringSync();
      final int fetchAt = worker.indexOf('tool/vendored_binaries.py fetch');
      expect(fetchAt, isNot(-1));
      // Before the Windows branch's early `exit 0`.
      expect(fetchAt, lessThan(worker.indexOf('MINGW*|MSYS*)')));
    });

    test('native store names fold the vendored bytes of Mihon and galgame', () {
      final String names = File(
        '$repo/.github/actions/native-store-names/names.sh',
      ).readAsStringSync();
      expect(names, contains('tool/vendored_binaries.py identity'));
      expect(names, contains(r'vendored=$mihon_vendored'));
      expect(names, contains(r'vendored=$galgame_vendored'));
    });
  });
}
