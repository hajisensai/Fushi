import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// 守卫：RWKV-Instant 排程推理 `native/fushi_rwkv`（Rust，AGPL-3.0-or-later）是 app 的**硬依赖**，
/// 与 `native/fushi_compute` 同一形态（见 fushi_compute_hard_dependency_guard_test.dart）：
/// 缺库必须在**构建期**失败，而不是包照常出、用户打开复习页才发现排程推理不可用。
///
/// 洞的形状：copy-if-present 是本仓原生库的默认写法，照抄一处新接线就会把「缺库静默跳过」
/// 带回来——CI 全绿、包照发。所以这里逐平台钉住「缺库 = 构建失败」：
///
/// - Windows / Linux CMake：缺库 `message(FATAL_ERROR ...)`；
/// - macOS Runner 构建阶段 `bundle_fushi_rwkv.sh`：缺库 `exit 1`；
/// - iOS：伞形静态库 `native/fushi_ios_umbrella` 依赖 fushi_rwkv，Runner 在编译前跑
///   `check_fushi_rwkv.sh`（伞形库缺失或不导出 `frwkv_abi_version` 时失败）；
/// - Android：`checkFushiRwkvNative` 挂在 `preBuild` 上，缺 ABI 抛 GradleException；
/// - 本地新 worktree：`tool/bootstrap.ps1` / `bootstrap.sh` 编它；
/// - CI：凡是用 `setup-fushi-compute` 的 job 也用 `setup-fushi-rwkv`（同样的输入），其余
///   跑 Dart / Flutter 测试的 job 显式设 `FUSHI_RWKV_LIB`；出 app 包的 workflow 都编它、
///   出包后核对它在包里。
void main() {
  // 测试 cwd 是 `fushi/`。
  String read(String path) {
    final File file = File(path);
    expect(file.existsSync(), isTrue, reason: '${file.absolute.path} 不存在');
    return file.readAsStringSync().replaceAll('\r\n', '\n');
  }

  /// CMake / YAML / shell 注释都是 `#`。
  String code(String path) => maskHashComments(read(path));

  for (final (String platform, String path, String lib)
      in <(String, String, String)>[
        ('Windows', 'windows/CMakeLists.txt', 'FUSHI_RWKV_DLL'),
        ('Linux', 'linux/CMakeLists.txt', 'FUSHI_RWKV_SO'),
      ]) {
    test('$platform CMake：缺 fushi_rwkv 是配置期 FATAL_ERROR', () {
      final String cmake = code(path);
      expect(
        cmake,
        contains('if(NOT EXISTS "\${$lib}")\n  message(FATAL_ERROR'),
        reason: '$path：fushi_rwkv 缺库必须直接失败',
      );
      expect(
        cmake,
        isNot(contains('if(EXISTS "\${$lib}")')),
        reason: '$path：fushi_rwkv 不能写成 copy-if-present',
      );
      expect(cmake, contains('install(FILES "\${$lib}"'));
      expect(cmake, contains('native/fushi_rwkv/prebuilt/'));
    });
  }

  test('macOS：Bundle fushi_rwkv 阶段缺库 exit 1，并挂在 Runner 上', () {
    final String script = read('macos/bundle_fushi_rwkv.sh');
    expect(script, contains('native/fushi_rwkv/prebuilt/macos/'));
    final RegExp missingBranch = RegExp(
      r'if \[\[ ! -f "\$source" \]\]; then\n(.*?)\nfi',
      dotAll: true,
    );
    final RegExpMatch? m = missingBranch.firstMatch(script);
    expect(m, isNotNull, reason: '找不到缺库分支');
    expect(m!.group(1), contains('exit 1'));
    expect(m.group(1), isNot(contains('exit 0')));

    final String pbx = read('macos/Runner.xcodeproj/project.pbxproj');
    expect(
      pbx,
      contains(
        r'shellScript = "/bin/bash \"$PROJECT_DIR/bundle_fushi_rwkv.sh\"\n";',
      ),
    );
    // 挂进 Runner 的 buildPhases 列表（不只是定义了一个孤立的 phase 对象）。
    final int target = pbx.indexOf(
      '/* Runner */ = {\n\t\t\tisa = PBXNativeTarget;',
    );
    expect(
      target,
      greaterThanOrEqualTo(0),
      reason: '找不到 Runner 的 PBXNativeTarget',
    );
    final int phases = pbx.indexOf('buildPhases = (', target);
    final int phasesEnd = pbx.indexOf(');', phases);
    final int entry = pbx.indexOf('/* Bundle fushi_rwkv dylib */,', phases);
    expect(entry, greaterThan(phases), reason: '构建阶段没挂进 Runner');
    expect(entry, lessThan(phasesEnd), reason: '构建阶段没挂进 Runner');
  });

  test('iOS：伞形库依赖 fushi_rwkv，Runner 在编译前硬检查 frwkv_*', () {
    final String cargo = read('../native/fushi_ios_umbrella/Cargo.toml');
    expect(
      cargo,
      contains('fushi_rwkv = { path = "../fushi_rwkv" }'),
      reason: '伞形库不依赖 fushi_rwkv，iOS Runner 里就没有 frwkv_*',
    );
    final String lib = read('../native/fushi_ios_umbrella/src/lib.rs');
    expect(lib, contains('extern crate fushi_rwkv;'));
    final String build = read(
      '../native/fushi_ios_umbrella/build_ios_staticlib.sh',
    );
    expect(
      build,
      contains(r'"frwkv:2:$SCRIPT_DIR/../../packages/fushi_rwkv/lib"'),
      reason: '伞形库构建后要核对 frwkv_* 符号',
    );
    // 伞形库的持久库件名必须随 fushi_rwkv 源码变：否则改了 RWKV 的 PR 会复用旧 .a。
    final String names = read('../.github/actions/native-store-names/names.sh');
    final RegExpMatch? iosNative = RegExp(
      r'^IOS_NATIVE=\(([^)]*)\)',
      multiLine: true,
    ).firstMatch(names);
    expect(iosNative, isNotNull);
    expect(iosNative!.group(1)!.split(' '), contains('native/fushi_rwkv'));

    final String pbx = read('ios/Runner.xcodeproj/project.pbxproj');
    expect(
      pbx,
      contains(
        r'shellScript = "/bin/bash \"$PROJECT_DIR/check_fushi_rwkv.sh\"\n";',
      ),
    );
    final int target = pbx.indexOf(
      '/* Runner */ = {\n\t\t\tisa = PBXNativeTarget;',
    );
    expect(
      target,
      greaterThanOrEqualTo(0),
      reason: '找不到 Runner 的 PBXNativeTarget',
    );
    final int phases = pbx.indexOf('buildPhases = (', target);
    final int check = pbx.indexOf(
      '/* Check fushi_rwkv (iOS umbrella) */,',
      phases,
    );
    final int sources = pbx.indexOf('/* Sources */,', phases);
    expect(check, greaterThan(phases), reason: '构建阶段没挂进 Runner');
    expect(check, lessThan(sources), reason: '检查阶段必须在 Sources 之前');

    final String script = read('ios/check_fushi_rwkv.sh');
    expect(script, contains(r'prebuilt/ios/${sdk}/libfushi_ios_umbrella.a'));
    expect(script, contains('FUSHI_IOS_NATIVE_LDFLAGS'));
    expect(script, contains('_frwkv_abi_version'));
    expect(script, contains('exit 1'));
  });

  test('Android：checkFushiRwkvNative 挂在 preBuild 上并在缺库时抛错', () {
    final String gradle = maskComments(read('android/app/build.gradle'));
    expect(
      gradle,
      contains(
        "main.jniLibs.srcDirs += '../../../native/fushi_rwkv/prebuilt/android'",
      ),
    );
    expect(gradle, contains('tasks.register("checkFushiRwkvNative")'));
    expect(gradle, contains('libfushi_rwkv.so'));
    final int preBuild = gradle.indexOf('if (task.name == "preBuild") {');
    expect(preBuild, greaterThanOrEqualTo(0));
    expect(
      gradle.indexOf('task.dependsOn(checkFushiRwkvNative)', preBuild),
      greaterThan(preBuild),
    );
    final int check = gradle.indexOf('tasks.register("checkFushiRwkvNative")');
    expect(
      gradle.indexOf('throw new GradleException', check),
      greaterThan(check),
    );
  });

  test('本地 bootstrap 编 fushi_rwkv', () {
    final String ps1 = maskHashComments(read('../tool/bootstrap.ps1'));
    expect(ps1, contains("@('fushi_compute', 'fushi_rwkv')"));
    final String sh = maskHashComments(read('../tool/bootstrap.sh'));
    expect(sh, contains('bash native/fushi_rwkv/build_linux_so.sh'));
    expect(sh, contains('bash native/fushi_rwkv/build_macos_dylib.sh'));
  });

  test('native/fushi_rwkv 有与 fushi_compute 同名的构建 / 核对脚本', () {
    for (final String script in <String>[
      'build_windows_dll.ps1',
      'build_android_so.ps1',
      'build_android_so.sh',
      'build_linux_so.sh',
      'build_macos_dylib.sh',
      'verify_abi.sh',
    ]) {
      expect(
        File('../native/fushi_rwkv/$script').existsSync(),
        isTrue,
        reason: 'native/fushi_rwkv/$script 缺失',
      );
    }
    // verify_abi.sh 的期望集自动取（src/ 的 extern "C" ∪ Dart 绑定），不手维护清单。
    final String verify = read('../native/fushi_rwkv/verify_abi.sh');
    expect(verify, contains('extern "C" fn frwkv_'));
    expect(verify, contains('packages/fushi_rwkv/lib'));
  });

  group('CI：用 setup-fushi-compute 的 job 也编 fushi_rwkv', () {
    final Directory dir = Directory('../.github/workflows');
    final List<File> files =
        dir
            .listSync()
            .whereType<File>()
            .where((File f) => f.path.endsWith('.yml'))
            .toList()
          ..sort((File a, File b) => a.path.compareTo(b.path));

    test('扫描面非空', () => expect(files.length, greaterThan(10)));

    // 「先编 fushi_compute」的那些 job（setup-fushi-compute 或显式 FUSHI_COMPUTE_LIB）正是会
    // 加载 Dart 侧原生库的 job：凡是它们，都必须同样先编 fushi_rwkv。
    int computeJobs = 0;
    for (final File f in files) {
      final String name = f.uri.pathSegments.last;
      final String text = maskHashComments(
        f.readAsStringSync().replaceAll('\r\n', '\n'),
      );
      for (final MapEntry<String, String> job in _jobs(text).entries) {
        final String body = job.value;
        final bool usesComputeAction = body.contains(
          'uses: ./.github/actions/setup-fushi-compute',
        );
        final bool needsCompute =
            usesComputeAction || body.contains('FUSHI_COMPUTE_LIB');
        if (!needsCompute) continue;
        // native-compute-gate 只编 / 测 fushi_compute 自己的 crate。
        if (name == 'native-compute-gate.yml') continue;
        computeJobs++;
        final String id = '$name/${job.key}';
        test(id, () {
          if (usesComputeAction) {
            final int actionUses = RegExp(
              r'uses: \./\.github/actions/setup-fushi-compute\n',
            ).allMatches(body).length;
            final int rwkvUses = RegExp(
              r'uses: \./\.github/actions/setup-fushi-rwkv\n',
            ).allMatches(body).length;
            expect(
              rwkvUses,
              actionUses,
              reason:
                  '$id 用了 setup-fushi-compute 却没有同样次数地用 setup-fushi-rwkv'
                  '（fushi_rwkv 是硬依赖，紧跟着加 `uses: ./.github/actions/setup-fushi-rwkv`，'
                  '同样的 with:）。',
            );
            // android-abis 输入也要一致，否则 checkFushiRwkvNative 会在 Gradle 里失败。
            final List<String> computeAbis = _abisAfter(
              body,
              'setup-fushi-compute',
            );
            final List<String> rwkvAbis = _abisAfter(body, 'setup-fushi-rwkv');
            expect(
              rwkvAbis,
              computeAbis,
              reason: '$id：两个 action 的 android-abis 不一致',
            );
          } else {
            expect(
              body.contains('FUSHI_RWKV_LIB') ||
                  body.contains('native/fushi_rwkv/build_'),
              isTrue,
              reason:
                  '$id 编了 fushi_compute（FUSHI_COMPUTE_LIB），却没编 fushi_rwkv：'
                  '照 fushi_compute 的步骤加 native/fushi_rwkv/build_* 并导出 FUSHI_RWKV_LIB。',
            );
          }
        });
      }
    }
    test('规模哨兵：至少找到 main / release / golden / server 的 job', () {
      expect(computeJobs, greaterThanOrEqualTo(6));
    });
  });

  group('CI：出包的 workflow 编 fushi_rwkv 并核对它在包里', () {
    final Map<String, List<String>> required = <String, List<String>>{
      'build-multiplatform.yml': <String>[
        'native/fushi_rwkv/build_windows_dll.ps1',
        'runner\\Debug\\fushi_rwkv.dll',
        'native/fushi_rwkv/build_macos_dylib.sh',
        'Contents/Frameworks/libfushi_rwkv.dylib',
        'bash ../native/fushi_rwkv/verify_abi.sh "\$bin" nm',
        'native/fushi_rwkv/build_linux_so.sh',
        'bundle/lib/libfushi_rwkv.so',
      ],
      'release.yml': <String>[
        'native/fushi_rwkv/build_android_so.sh',
        'lib/\$abi/libfushi_rwkv.so',
      ],
      'release-desktop.yml': <String>[
        'native/fushi_rwkv/build_windows_dll.ps1',
        'runner\\Release\\fushi_rwkv.dll',
        'native/fushi_rwkv/build_macos_dylib.sh',
        'Contents/Frameworks/libfushi_rwkv.dylib',
        'bash native/fushi_rwkv/verify_abi.sh fushi/build/ios/iphoneos/Runner.app/Runner nm',
        'bash native/fushi_rwkv/verify_abi.sh "\$runner" nm',
      ],
      'release-server.yml': <String>[
        'native/fushi_rwkv/build_linux_so.sh',
        'cp native/fushi_rwkv/prebuilt/linux-x64/libfushi_rwkv.so build/fushi_server_linux/bundle/lib/',
        'native/fushi_rwkv/build_windows_dll.ps1',
        'Copy-Item native/fushi_rwkv/prebuilt/windows-x64/fushi_rwkv.dll \$lib -Force',
      ],
    };
    for (final MapEntry<String, List<String>> e in required.entries) {
      test(e.key, () {
        final String text = code('../.github/workflows/${e.key}');
        for (final String needle in e.value) {
          expect(text, contains(needle), reason: '${e.key} 缺：$needle');
        }
      });
    }
  });
}

/// `uses: ./.github/actions/<action>` 之后紧跟的 `android-abis:` 值（没有 with 则为空串），按出现顺序。
List<String> _abisAfter(String body, String action) {
  final RegExp use = RegExp(
    'uses: \\./\\.github/actions/$action\\n'
    r'(?:\s+with:\n\s+android-abis:\s*(\S[^\n]*))?',
  );
  return <String>[
    for (final RegExpMatch m in use.allMatches(body)) (m.group(1) ?? '').trim(),
  ];
}

/// `jobs:` 下两格缩进的 job id → 该 job 的正文。
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
