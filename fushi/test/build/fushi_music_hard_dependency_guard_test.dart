import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// 守卫：音乐胖核心 `native/fushi_music`（Rust，GPL-3.0-only）是 app 的**硬依赖**，
/// 与 `native/fushi_compute` 同一形态（见 fushi_compute_hard_dependency_guard_test.dart）：
/// 缺库必须在**构建期**失败，而不是包照常出、用户打开复习页才发现排程推理不可用。
///
/// 洞的形状：copy-if-present 是本仓原生库的默认写法，照抄一处新接线就会把「缺库静默跳过」
/// 带回来——CI 全绿、包照发。所以这里逐平台钉住「缺库 = 构建失败」：
///
/// - Windows / Linux CMake：缺库 `message(FATAL_ERROR ...)`；
/// - macOS Runner 构建阶段 `bundle_fushi_music.sh`：缺库 `exit 1`；
/// - iOS：伞形静态库 `native/fushi_ios_umbrella` 依赖 fushi_music，Runner 在编译前跑
///   `check_fushi_music.sh`（伞形库缺失或不导出 `ffm_abi_version` 时失败）；
/// - Android：`checkFushiMusicNative` 挂在 `preBuild` 上，缺 ABI 抛 GradleException；
/// - 本地新 worktree：`tool/bootstrap.ps1`（经 `tool/native_libs.ps1` 的 `$NativeTestCrates`）/
///   `bootstrap.sh` 编它；
/// - CI：凡是用 `setup-fushi-compute` 的 job 也用 `setup-fushi-music`（同样的输入），其余
///   跑 Dart / Flutter 测试的 job 显式设 `FUSHI_MUSIC_LIB`；出 app 包的 workflow 都编它、
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
        ('Windows', 'windows/CMakeLists.txt', 'FUSHI_MUSIC_DLL'),
        ('Linux', 'linux/CMakeLists.txt', 'FUSHI_MUSIC_SO'),
      ]) {
    test('$platform CMake：缺 fushi_music 是配置期 FATAL_ERROR', () {
      final String cmake = code(path);
      expect(
        cmake,
        contains('if(NOT EXISTS "\${$lib}")\n  message(FATAL_ERROR'),
        reason: '$path：fushi_music 缺库必须直接失败',
      );
      expect(
        cmake,
        isNot(contains('if(EXISTS "\${$lib}")')),
        reason: '$path：fushi_music 不能写成 copy-if-present',
      );
      expect(cmake, contains('install(FILES "\${$lib}"'));
      expect(cmake, contains('native/fushi_music/prebuilt/'));
    });
  }

  test('macOS：Bundle fushi_music 阶段缺库 exit 1，并挂在 Runner 上', () {
    final String script = read('macos/bundle_fushi_music.sh');
    expect(script, contains('native/fushi_music/prebuilt/macos/'));
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
        r'shellScript = "/bin/bash \"$PROJECT_DIR/bundle_fushi_music.sh\"\n";',
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
    final int entry = pbx.indexOf('/* Bundle fushi_music dylib */,', phases);
    expect(entry, greaterThan(phases), reason: '构建阶段没挂进 Runner');
    expect(entry, lessThan(phasesEnd), reason: '构建阶段没挂进 Runner');
  });

  test('iOS：伞形库依赖 fushi_music，Runner 在编译前硬检查 ffm_*', () {
    final String cargo = read('../native/fushi_ios_umbrella/Cargo.toml');
    expect(
      cargo,
      // default-features = false：iOS 不编 plugin 特性（在线音源插件的 JS 运行时，App Store 合规，
      // StoreRestrictedCapability.onlineMusicSource）；其余 ffm_* 照样是硬依赖。
      contains(
        'fushi_music = { path = "../fushi_music", default-features = false }',
      ),
      reason: '伞形库不依赖 fushi_music，iOS Runner 里就没有 ffm_*',
    );
    // 不带 plugin 特性的产物，符号核对必须排除插件绑定（否则 ffm_plugin_* 缺失把 iOS 构建打红）；
    // 但只排除插件目录，其余 ffm_* 一个不少。
    final String verifyAbi = read('../native/fushi_music/verify_abi.sh');
    expect(verifyAbi, contains('PLUGIN_EXCLUDE=(--exclude-dir=plugin)'));
    final String lib = read('../native/fushi_ios_umbrella/src/lib.rs');
    expect(lib, contains('extern crate fushi_music;'));
    final String build = read(
      '../native/fushi_ios_umbrella/build_ios_staticlib.sh',
    );
    expect(
      build,
      contains(r'"ffm:7:$SCRIPT_DIR/../../packages/fushi_music/lib"'),
      reason: '伞形库构建后要核对 ffm_* 符号',
    );
    // 伞形库的持久库件名必须随 fushi_music 源码变：否则改了 RWKV 的 PR 会复用旧 .a。
    final String names = read('../.github/actions/native-store-names/names.sh');
    final RegExpMatch? iosNative = RegExp(
      r'^IOS_NATIVE=\(([^)]*)\)',
      multiLine: true,
    ).firstMatch(names);
    expect(iosNative, isNotNull);
    expect(iosNative!.group(1)!.split(' '), contains('native/fushi_music'));

    final String pbx = read('ios/Runner.xcodeproj/project.pbxproj');
    expect(
      pbx,
      contains(
        r'shellScript = "/bin/bash \"$PROJECT_DIR/check_fushi_music.sh\"\n";',
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
      '/* Check fushi_music (iOS umbrella) */,',
      phases,
    );
    final int sources = pbx.indexOf('/* Sources */,', phases);
    expect(check, greaterThan(phases), reason: '构建阶段没挂进 Runner');
    expect(check, lessThan(sources), reason: '检查阶段必须在 Sources 之前');

    final String script = read('ios/check_fushi_music.sh');
    expect(script, contains(r'prebuilt/ios/${sdk}/libfushi_ios_umbrella.a'));
    expect(script, contains('FUSHI_IOS_NATIVE_LDFLAGS'));
    expect(script, contains('_ffm_abi_version'));
    expect(script, contains('exit 1'));
  });

  test('Android：checkFushiMusicNative 挂在 preBuild 上并在缺库时抛错', () {
    final String gradle = maskComments(read('android/app/build.gradle'));
    expect(
      gradle,
      contains(
        "main.jniLibs.srcDirs += '../../../native/fushi_music/prebuilt/android'",
      ),
    );
    expect(gradle, contains('tasks.register("checkFushiMusicNative")'));
    expect(gradle, contains('libfushi_music.so'));
    final int preBuild = gradle.indexOf('if (task.name == "preBuild") {');
    expect(preBuild, greaterThanOrEqualTo(0));
    expect(
      gradle.indexOf('task.dependsOn(checkFushiMusicNative)', preBuild),
      greaterThan(preBuild),
    );
    final int check = gradle.indexOf('tasks.register("checkFushiMusicNative")');
    expect(
      gradle.indexOf('throw new GradleException', check),
      greaterThan(check),
    );
  });

  test('本地 bootstrap 编 fushi_music', () {
    // bootstrap.ps1 把备库交给 tool/native_libs.ps1，crate 清单在它的 $NativeTestCrates。
    final String ps1 = maskHashComments(read('../tool/bootstrap.ps1'));
    expect(ps1, contains("'native_libs.ps1'"));
    final String libs = maskHashComments(read('../tool/native_libs.ps1'));
    final RegExpMatch? crates = RegExp(
      r'^\$NativeTestCrates = @\(([^)]*)\)',
      multiLine: true,
    ).firstMatch(libs);
    expect(
      crates,
      isNotNull,
      reason: 'tool/native_libs.ps1 找不到 \$NativeTestCrates',
    );
    expect(crates!.group(1), contains("'fushi_music'"));
    final String sh = maskHashComments(read('../tool/bootstrap.sh'));
    expect(sh, contains('bash native/fushi_music/build_linux_so.sh'));
    expect(sh, contains('bash native/fushi_music/build_macos_dylib.sh'));
  });

  test('native/fushi_music 有与 fushi_compute 同名的构建 / 核对脚本', () {
    for (final String script in <String>[
      'build_windows_dll.ps1',
      'build_android_so.ps1',
      'build_android_so.sh',
      'build_linux_so.sh',
      'build_macos_dylib.sh',
      'verify_abi.sh',
    ]) {
      expect(
        File('../native/fushi_music/$script').existsSync(),
        isTrue,
        reason: 'native/fushi_music/$script 缺失',
      );
    }
    // verify_abi.sh 的期望集取自 Dart 绑定的 lookup 名（同 fushi_compute），不手维护清单。
    final String verify = read('../native/fushi_music/verify_abi.sh');
    expect(verify, contains('ffm_[a-z0-9_]+'));
    expect(verify, contains('packages/fushi_music/lib'));
  });

  group('CI：用 setup-fushi-compute 的 job 也编 fushi_music', () {
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
    // 加载 Dart 侧原生库的 job：凡是它们，都必须同样先编 fushi_music。
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
        // 无头服务端不依赖 fushi_music（fushi_engine / fushi_server 都不引用音乐包），
        // 只编服务端 bundle 的 job 不需要它。
        if (_serverOnlyJobs.contains('$name/${job.key}')) continue;
        computeJobs++;
        final String id = '$name/${job.key}';
        test(id, () {
          if (usesComputeAction) {
            final int actionUses = RegExp(
              r'uses: \./\.github/actions/setup-fushi-compute\n',
            ).allMatches(body).length;
            final int rwkvUses = RegExp(
              r'uses: \./\.github/actions/setup-fushi-music\n',
            ).allMatches(body).length;
            expect(
              rwkvUses,
              actionUses,
              reason:
                  '$id 用了 setup-fushi-compute 却没有同样次数地用 setup-fushi-music'
                  '（fushi_music 是硬依赖，紧跟着加 `uses: ./.github/actions/setup-fushi-music`，'
                  '同样的 with:）。',
            );
            // android-abis 输入也要一致，否则 checkFushiMusicNative 会在 Gradle 里失败。
            final List<String> computeAbis = _abisAfter(
              body,
              'setup-fushi-compute',
            );
            final List<String> rwkvAbis = _abisAfter(body, 'setup-fushi-music');
            expect(
              rwkvAbis,
              computeAbis,
              reason: '$id：两个 action 的 android-abis 不一致',
            );
          } else {
            expect(
              body.contains('FUSHI_MUSIC_LIB') ||
                  body.contains('native/fushi_music/build_'),
              isTrue,
              reason:
                  '$id 编了 fushi_compute（FUSHI_COMPUTE_LIB），却没编 fushi_music：'
                  '照 fushi_compute 的步骤加 native/fushi_music/build_* 并导出 FUSHI_MUSIC_LIB。',
            );
          }
        });
      }
    }
    test('规模哨兵：至少找到 main / release / golden 的 app job', () {
      expect(computeJobs, greaterThanOrEqualTo(4));
    });
  });

  group('CI：出包的 workflow 编 fushi_music 并核对它在包里', () {
    final Map<String, List<String>> required = <String, List<String>>{
      'build-multiplatform.yml': <String>[
        'native/fushi_music/build_windows_dll.ps1',
        'runner\\Debug\\fushi_music.dll',
        'native/fushi_music/build_macos_dylib.sh',
        'Contents/Frameworks/libfushi_music.dylib',
        'bash ../native/fushi_music/verify_abi.sh --no-plugin "\$bin" nm',
        'uses: ./.github/actions/setup-fushi-music',
      ],
      'release.yml': <String>[
        'native/fushi_music/build_android_so.sh',
        'lib/\$abi/libfushi_music.so',
      ],
      'release-desktop.yml': <String>[
        'native/fushi_music/build_windows_dll.ps1',
        'runner\\Release\\fushi_music.dll',
        'native/fushi_music/build_macos_dylib.sh',
        'Contents/Frameworks/libfushi_music.dylib',
        'bash native/fushi_music/verify_abi.sh --no-plugin fushi/build/ios/iphoneos/Runner.app/Runner nm',
        'bash native/fushi_music/verify_abi.sh --no-plugin "\$runner" nm',
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

/// 只出无头服务端 bundle 的 job（服务端不依赖 fushi_music）。
const Set<String> _serverOnlyJobs = <String>{
  'build-multiplatform.yml/linux-server',
  'release-server.yml/linux',
  'release-server.yml/windows',
  'server-gate.yml/server',
};
