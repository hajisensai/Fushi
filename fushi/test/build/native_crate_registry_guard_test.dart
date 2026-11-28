import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../helpers/source_guard.dart';

/// 守卫：原生库登记表 `native/crates.json` 是「有哪些原生库、各平台要不要、缺了怎么办」的唯一来源，
/// 所有接线都与它一致。取代了以前逐 crate 复制、逐条钉接线点的 fushi_{compute,corpus,music,rwkv}
/// _hard_dependency_guard_test（每份两三百行）。
///
/// 两类消费方：
/// - **从登记表派生**（不许再手写 crate 名单）：Windows / Linux CMake（`native/fushi_native_libs.cmake`）、
///   macOS「Bundle native libraries」阶段（`fushi/macos/bundle_native_libs.sh`）、iOS「Check native libraries」
///   阶段（`fushi/ios/check_native_libs.sh`）、`tool/native_libs.ps1`、`tool/bootstrap.sh`、dist worker、
///   原生产物库命名（names.sh）。缺库语义（always / release / optional）在派生实现里只写一次。
/// - **还在手写、由这里逐项对照登记表**（迁移前的棘轮：新增 crate 时这里先红）：Android gradle 的
///   jniLibs / checkFushi*Native、iOS 伞形 crate 的依赖段与 `extern crate`、CI workflow 的构建与出包核对。
///
/// 登记表本身与源码树的一致性（目录、构建脚本、外部源码、ABI 符号）和「三个入口算出同一个源码键」
/// 由 `tool/native_crates_test.py` 钉住，这里跑它。
void main() {
  // 测试 cwd 是 `fushi/`。
  final String repo = p.normalize(p.absolute('..'));
  String read(String rel) {
    // 也在 group 体里（测试声明期）调用，那里不能 expect：缺文件直接抛。
    final File f = File(p.join(repo, rel));
    if (!f.existsSync()) throw StateError('$rel 不存在');
    return f.readAsStringSync().replaceAll('\r\n', '\n');
  }

  final Map<String, Object?> registry =
      jsonDecode(File(p.join(repo, 'native', 'crates.json')).readAsStringSync())
          as Map<String, Object?>;
  final List<_Crate> crates = <_Crate>[
    for (final Object? raw in registry['crates']! as List<Object?>)
      _Crate(raw! as Map<String, Object?>),
  ];
  Iterable<_Crate> onPlatform(String platform, {String? bundledBy}) =>
      crates.where(
        (_Crate c) =>
            c.platform(platform) != null &&
            (bundledBy == null || c.platform(platform)!.bundledBy == bundledBy),
      );

  test('登记表的规模哨兵', () {
    expect(crates.length, greaterThanOrEqualTo(10));
    expect(
      onPlatform('windows', bundledBy: 'app').length,
      greaterThanOrEqualTo(7),
    );
    expect(
      crates.where((_Crate c) => c.hostTestLib).map((_Crate c) => c.name),
      containsAll(<String>['fushi_compute', 'fushi_fsrs', 'fushi_music']),
    );
  });

  test('tool/native_crates_test.py 通过（登记表 check + 源码键三入口一致）', () {
    final String python = Platform.isWindows ? 'py' : 'python3';
    final List<String> prefix = Platform.isWindows
        ? <String>['-3']
        : <String>[];
    final ProcessResult r = Process.runSync(python, <String>[
      ...prefix,
      p.join(repo, 'tool', 'native_crates_test.py'),
    ], workingDirectory: repo);
    expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
    expect('${r.stderr}', contains('OK'));
  });

  group('派生的消费方不手写 crate 名单', () {
    // 两个以上 crate 名连写（逗号 / 空格 / 引号分隔）就是一份手写清单。
    final RegExp handList = RegExp(
      r"""\bfushi_[a-z0-9_]+['"]?\s*[, ]\s*['"]?fushi_[a-z0-9_]+\b""",
    );
    for (final String rel in <String>[
      'tool/native_libs.ps1',
      'tool/bootstrap.sh',
      'fushi/tool/dist_test/worker_prepare.sh',
      'fushi/tool/dist_test/worker_build.sh',
      'fushi/macos/bundle_native_libs.sh',
      'fushi/ios/check_native_libs.sh',
      'native/fushi_native_libs.cmake',
    ]) {
      test(rel, () {
        final String code = maskHashComments(read(rel));
        expect(
          code.contains('native_crates.py') || code.contains('crates.json'),
          isTrue,
          reason: '$rel 不读登记表',
        );
        expect(
          handList.firstMatch(code)?.group(0),
          isNull,
          reason: '$rel 手写了 crate 清单：改读 tool/native_crates.py',
        );
      });
    }
  });

  for (final (String platform, String prebuilt) in <(String, String)>[
    ('windows', 'windows-x64'),
    ('linux', 'linux-x64'),
  ]) {
    test('$platform CMake 经 fushi_native_libs.cmake 随包，不另写逐 crate 块', () {
      final String cmake = maskHashComments(
        read('fushi/$platform/CMakeLists.txt'),
      );
      expect(cmake, contains('native/fushi_native_libs.cmake")'));
      expect(cmake, contains('fushi_install_native_libs($platform $prebuilt '));
      for (final _Crate c in onPlatform(platform, bundledBy: 'app')) {
        expect(
          cmake,
          isNot(contains('native/${c.name}/prebuilt/')),
          reason: '${c.name} 由登记表随包，CMakeLists 里不能再有它的手写块',
        );
      }
    });
  }

  test('fushi_native_libs.cmake 对三种 required 各有处理', () {
    final String cmake = maskHashComments(
      read('native/fushi_native_libs.cmake'),
    );
    expect(cmake, contains('if(required STREQUAL "always")'));
    expect(cmake, contains('message(FATAL_ERROR'));
    expect(cmake, contains('elseif(required STREQUAL "release")'));
    expect(
      cmake,
      contains(r'CMAKE_INSTALL_CONFIG_NAME MATCHES \"^(Profile|Release)$\"'),
    );
    expect(cmake, contains('elseif(required STREQUAL "optional")'));
  });

  (int, int) runnerPhases(String pbx) {
    final int target = pbx.indexOf(
      '/* Runner */ = {\n\t\t\tisa = PBXNativeTarget;',
    );
    expect(
      target,
      greaterThanOrEqualTo(0),
      reason: '找不到 Runner 的 PBXNativeTarget',
    );
    final int phases = pbx.indexOf('buildPhases = (', target);
    return (phases, pbx.indexOf(');', phases));
  }

  test('macOS：一个「Bundle native libraries」阶段挂在 Runner 上，不留逐 crate 脚本', () {
    final String pbx = read('fushi/macos/Runner.xcodeproj/project.pbxproj');
    expect(
      pbx,
      contains(
        r'shellScript = "/bin/bash \"$PROJECT_DIR/bundle_native_libs.sh\"\n";',
      ),
    );
    final (int phases, int end) = runnerPhases(pbx);
    final int entry = pbx.indexOf('/* Bundle native libraries */,', phases);
    expect(entry, inExclusiveRange(phases, end), reason: '构建阶段没挂进 Runner');
    for (final _Crate c in onPlatform('macos', bundledBy: 'app')) {
      expect(
        File(
          p.join(repo, 'fushi', 'macos', 'bundle_${c.name}.sh'),
        ).existsSync(),
        isFalse,
        reason: '${c.name} 由 bundle_native_libs.sh 随包，不能再有单独脚本',
      );
    }
    final String script = read('fushi/macos/bundle_native_libs.sh');
    expect(script, contains('native_crates.py" bundle macos'));
    for (final String mode in <String>['always)', 'release)', 'optional)']) {
      expect(script, contains(mode), reason: '缺 $mode 分支');
    }
  });

  test('iOS：伞形库的依赖段与 extern crate 正好是登记表里经伞形库链入的那些', () {
    final List<String> members = <String>[
      for (final _Crate c in onPlatform('ios'))
        if (c.platform('ios')!.via == 'fushi_ios_umbrella') c.name,
    ]..sort();
    expect(members, isNotEmpty);
    final String cargo = read('native/fushi_ios_umbrella/Cargo.toml');
    final String deps = cargo.substring(
      cargo.indexOf('[dependencies]'),
      cargo.indexOf('\n[', cargo.indexOf('[dependencies]') + 1),
    );
    final List<String> declared = <String>[
      for (final RegExpMatch m in RegExp(
        r'^(fushi_[a-z0-9_]+) = \{ path = "\.\./\1"',
        multiLine: true,
      ).allMatches(deps))
        m.group(1)!,
    ]..sort();
    expect(
      declared,
      members,
      reason: 'native/fushi_ios_umbrella/Cargo.toml [dependencies]',
    );
    final String lib = maskComments(
      read('native/fushi_ios_umbrella/src/lib.rs'),
    );
    final List<String> linked = <String>[
      for (final RegExpMatch m in RegExp(
        r'extern crate (fushi_[a-z0-9_]+);',
      ).allMatches(lib))
        m.group(1)!,
    ]..sort();
    expect(
      linked,
      members,
      reason: 'native/fushi_ios_umbrella/src/lib.rs 的 extern crate',
    );
  });

  test(
    'iOS：Runner 在 Sources 之前跑「Check native libraries」，且 always 成员都有 ABI 符号可查',
    () {
      final String pbx = read('fushi/ios/Runner.xcodeproj/project.pbxproj');
      expect(
        pbx,
        contains(
          r'shellScript = "/bin/bash \"$PROJECT_DIR/check_native_libs.sh\"\n";',
        ),
      );
      final (int phases, int end) = runnerPhases(pbx);
      final int check = pbx.indexOf(
        '/* Check native libraries (iOS umbrella) */,',
        phases,
      );
      final int sources = pbx.indexOf('/* Sources */,', phases);
      expect(check, inExclusiveRange(phases, end), reason: '构建阶段没挂进 Runner');
      expect(check, lessThan(sources), reason: '检查阶段必须在 Sources 之前');
      final List<_Crate> always = <_Crate>[
        for (final _Crate c in onPlatform('ios'))
          if (c.platform('ios')!.required == 'always' &&
              c.platform('ios')!.via != null)
            c,
      ];
      expect(
        always.map((_Crate c) => c.name),
        containsAll(<String>[
          'fushi_compute',
          'fushi_rwkv',
          'fushi_music',
          'fushi_corpus',
        ]),
      );
      for (final _Crate c in always) {
        expect(
          c.abiSymbol,
          isNotNull,
          reason: '${c.name}: iOS 硬依赖必须有 abi_symbol 供伞形库核对',
        );
      }
    },
  );

  group('Android gradle（手写，按登记表对照）', () {
    final String gradle = maskComments(read('fushi/android/app/build.gradle'));
    final int hook = gradle.indexOf(
      'if (task.name.startsWith("merge") && task.name.endsWith("JniLibFolders")) {',
    );
    final int releaseOnly = gradle.indexOf(
      'if (task.name.contains("Release")) {',
      hook,
    );
    for (final _Crate c in onPlatform('android')) {
      final _Platform a = c.platform('android')!;
      test('${c.name}（${a.required}）', () {
        expect(
          gradle,
          contains(
            "main.jniLibs.srcDirs += '../../../native/${c.name}/prebuilt/android'",
          ),
        );
        final String task = 'checkFushi${c.camel}Native';
        if (a.required == 'optional') {
          expect(
            gradle,
            isNot(contains('tasks.register("$task")')),
            reason: 'optional 不能有缺库检查',
          );
          return;
        }
        final int reg = gradle.indexOf('tasks.register("$task")');
        expect(reg, greaterThanOrEqualTo(0), reason: '缺 $task');
        expect(
          gradle.indexOf('throw new GradleException', reg),
          greaterThan(reg),
        );
        expect(
          gradle.substring(reg, gradle.indexOf('\n}\n', reg)),
          contains(a.artifact!),
        );
        final int dep = gradle.indexOf('task.dependsOn($task)', hook);
        expect(
          dep,
          greaterThan(hook),
          reason: '$task 没挂在 merge*JniLibFolders 上',
        );
        if (a.required == 'always') {
          expect(
            dep,
            lessThan(releaseOnly),
            reason: '$task 是 always，不能只挂 Release',
          );
        } else {
          expect(
            dep,
            greaterThan(releaseOnly),
            reason: '$task 是 release，只挂 Release',
          );
        }
      });
    }
    test('fushiAndroidNativeCrates 与登记表的非 optional Rust crate 一致', () {
      final RegExpMatch? m = RegExp(
        r'def fushiAndroidNativeCrates = \[([^\]]*)\]',
      ).firstMatch(gradle);
      expect(m, isNotNull);
      final List<String> listed =
          RegExp(r"'([a-z0-9_]+)'")
              .allMatches(m!.group(1)!)
              .map((RegExpMatch x) => x.group(1)!)
              .toList()
            ..sort();
      final List<String> expected = <String>[
        for (final _Crate c in onPlatform('android'))
          if (c.language == 'rust' &&
              c.platform('android')!.required != 'optional')
            c.name,
      ]..sort();
      expect(listed, expected);
    });
  });

  test('crate 外的 #[path] 源码都列进登记表 external_sources（BUG-4988）', () {
    final RegExp pathAttr = RegExp(r'#\[path\s*=\s*"([^"]+)"\s*\]');
    final List<String> missing = <String>[];
    int externalSeen = 0;
    for (final _Crate c in crates.where((_Crate c) => c.language == 'rust')) {
      final Directory crateDir = Directory(p.join(repo, 'native', c.name));
      final Directory src = Directory(p.join(crateDir.path, 'src'));
      if (!src.existsSync()) continue;
      for (final File rs
          in src
              .listSync(recursive: true)
              .whereType<File>()
              .where((File f) => f.path.endsWith('.rs'))) {
        for (final RegExpMatch m in pathAttr.allMatches(
          rs.readAsStringSync(),
        )) {
          final String target = p.normalize(
            p.join(p.dirname(rs.path), m.group(1)!),
          );
          if (p.isWithin(crateDir.path, target)) continue;
          externalSeen++;
          final String rel = p.posix.joinAll(
            p.split(p.relative(target, from: repo)),
          );
          if (!c.externalSources.contains(rel)) missing.add('${c.name}: $rel');
          final File gate = File(
            p.join(repo, '.github', 'workflows', 'native-${c.short}-gate.yml'),
          );
          if (gate.existsSync() &&
              !gate.readAsStringSync().contains("- '$rel'")) {
            missing.add('${p.basename(gate.path)} 的 paths 缺 $rel');
          }
        }
      }
    }
    expect(externalSeen, greaterThan(0), reason: '扫描器没找到任何外部 #[path]');
    expect(missing, isEmpty, reason: missing.join('\n'));
  });

  group('CI：出包的 workflow 编每个 always 库并核对它在包里', () {
    final Map<String, String> wf = <String, String>{
      for (final String name in <String>[
        'build-multiplatform.yml',
        'release-desktop.yml',
        'release.yml',
      ])
        name: maskHashComments(read('.github/workflows/$name')),
    };
    for (final _Crate c in crates.where((_Crate c) => c.language == 'rust')) {
      final _Platform? win = c.platform('windows');
      final _Platform? mac = c.platform('macos');
      final _Platform? android = c.platform('android');
      final _Platform? ios = c.platform('ios');
      if (win?.required == 'always' && win?.bundledBy == 'app') {
        test('${c.name}：Windows', () {
          for (final String name in <String>[
            'build-multiplatform.yml',
            'release-desktop.yml',
          ]) {
            expect(
              wf[name],
              contains('native/${c.name}/build_windows_dll.ps1'),
              reason: name,
            );
            expect(
              wf[name],
              contains('\\${win!.artifact}'),
              reason: '$name 没核对包里的 ${win.artifact}',
            );
          }
        });
      }
      if (mac?.required == 'always' && mac?.bundledBy == 'app') {
        test('${c.name}：macOS', () {
          for (final String name in <String>[
            'build-multiplatform.yml',
            'release-desktop.yml',
          ]) {
            expect(
              wf[name],
              contains('native/${c.name}/build_macos_dylib.sh'),
              reason: name,
            );
            expect(
              wf[name],
              contains('Contents/Frameworks/${mac!.artifact}'),
              reason: name,
            );
          }
        });
      }
      if (android != null && android.required == 'always' && c.hostTestLib) {
        test('${c.name}：Android', () {
          expect(
            wf['release.yml'],
            contains('native/${c.name}/build_android_so.sh'),
          );
          expect(wf['release.yml'], contains('lib/\$abi/${android.artifact}'));
        });
      }
      if (ios?.required == 'always' && ios?.via != null) {
        test('${c.name}：iOS Runner 的符号核对', () {
          expect(
            wf['release-desktop.yml'],
            contains('native/${c.name}/verify_abi.sh'),
          );
          expect(
            RegExp(
              'native/${c.name}/verify_abi\\.sh(?: --no-plugin)? fushi/build/ios/iphoneos/Runner\\.app/Runner nm',
            ).hasMatch(wf['release-desktop.yml']!),
            isTrue,
          );
        });
      }
    }
  });

  group('CI：用 setup-fushi-<crate> 的 job 把每个有 action 的主机测试库都备上', () {
    final List<_Crate> withAction = <_Crate>[
      for (final _Crate c in crates.where((_Crate c) => c.hostTestLib))
        if (File(
          p.join(repo, '.github', 'actions', 'setup-${c.dashed}', 'action.yml'),
        ).existsSync())
          c,
    ];
    test('规模哨兵', () => expect(withAction.length, greaterThanOrEqualTo(4)));
    final List<File> files =
        Directory(p.join(repo, '.github', 'workflows'))
            .listSync()
            .whereType<File>()
            .where((File f) => f.path.endsWith('.yml'))
            .toList()
          ..sort((File a, File b) => a.path.compareTo(b.path));
    int jobs = 0;
    for (final File f in files) {
      final String name = p.basename(f.path);
      if (name.startsWith('native-') && name.endsWith('-gate.yml')) continue;
      final String text = maskHashComments(
        f.readAsStringSync().replaceAll('\r\n', '\n'),
      );
      for (final MapEntry<String, String> job in _jobs(text).entries) {
        final Map<String, List<String>> uses = <String, List<String>>{
          for (final _Crate c in withAction)
            c.name: _abisAfter(job.value, 'setup-${c.dashed}'),
        };
        if (uses.values.every((List<String> u) => u.isEmpty)) continue;
        if (_serverOnlyJobs.contains('$name/${job.key}')) continue;
        jobs++;
        test('$name/${job.key}', () {
          final List<String> first = uses.values.firstWhere(
            (List<String> u) => u.isNotEmpty,
          );
          for (final MapEntry<String, List<String>> u in uses.entries) {
            expect(
              u.value,
              first,
              reason:
                  '$name/${job.key}：setup-${u.key.replaceAll('_', '-')} 的次数 / android-abis 与同 job 其他 setup-fushi-* 不一致',
            );
          }
        });
      }
    }
    test(
      '至少找到 main / release / golden 的 app job',
      () => expect(jobs, greaterThanOrEqualTo(3)),
    );
  });
}

final class _Platform {
  _Platform(Map<String, Object?> raw)
    : artifact = raw['artifact'] as String?,
      required = raw['required']! as String,
      bundledBy = raw['bundled_by'] as String?,
      via = raw['via'] as String?;

  final String? artifact;
  final String required;
  final String? bundledBy;
  final String? via;
}

final class _Crate {
  _Crate(Map<String, Object?> raw)
    : name = raw['name']! as String,
      language = raw['language']! as String,
      abiSymbol = raw['abi_symbol'] as String?,
      hostTestLib = raw['host_test_lib'] == true,
      externalSources = <String>[
        for (final Object? s
            in (raw['external_sources'] as List<Object?>?) ?? <Object?>[])
          s! as String,
      ],
      _platforms = <String, _Platform>{
        for (final MapEntry<String, Object?> e
            in ((raw['platforms'] as Map<String, Object?>?) ??
                    <String, Object?>{})
                .entries)
          e.key: _Platform(e.value! as Map<String, Object?>),
      };

  final String name;
  final String language;
  final String? abiSymbol;
  final bool hostTestLib;
  final List<String> externalSources;
  final Map<String, _Platform> _platforms;

  _Platform? platform(String p) => _platforms[p];

  /// `fushi_web_core` → `web-core`（native-<short>-gate.yml）。
  String get short => name.replaceFirst('fushi_', '').replaceAll('_', '-');

  /// `fushi_web_core` → `fushi-web-core`（.github/actions/setup-<dashed>）。
  String get dashed => name.replaceAll('_', '-');

  /// `fushi_web_core` → `WebCore`（gradle 的 checkFushi<Camel>Native）。
  String get camel => name
      .replaceFirst('fushi_', '')
      .split('_')
      .map(
        (String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}',
      )
      .join();
}

List<String> _abisAfter(String body, String action) {
  final RegExp use = RegExp(
    'uses: \\./\\.github/actions/$action\\n'
    r'(?:\s+with:\n\s+android-abis:\s*(\S[^\n]*))?',
  );
  return <String>[
    for (final RegExpMatch m in use.allMatches(body)) (m.group(1) ?? '').trim(),
  ];
}

Map<String, String> _jobs(String workflow) {
  final List<String> lines = workflow.split('\n');
  final int start = lines.indexOf('jobs:');
  final Map<String, String> jobs = <String, String>{};
  if (start < 0) return jobs;
  final RegExp header = RegExp(r'^  ([A-Za-z0-9_-]+):\s*$');
  String? current;
  final StringBuffer body = StringBuffer();
  void flush() {
    final String? job = current;
    if (job != null) jobs[job] = body.toString();
    body.clear();
  }

  for (int i = start + 1; i < lines.length; i++) {
    final String line = lines[i];
    final RegExpMatch? m = header.firstMatch(line);
    if (m != null) {
      flush();
      current = m.group(1);
      continue;
    }
    if (line.isNotEmpty && !line.startsWith(' ')) break;
    body.writeln(line);
  }
  flush();
  return jobs;
}

/// 只编无头服务端的 job：服务端随包的原生库是 app 的子集（packages/fushi_server/tool/build_linux_bundle.sh），
/// 不带 fushi_music / fushi_corpus。登记表还没有「服务端」这一列（见 PR 剩余清单），先按现存的 job 放行；
/// 只减不增——新的服务端 job 要么备齐，要么等登记表有了服务端列再说。
const Set<String> _serverOnlyJobs = <String>{'server-gate.yml/server'};
