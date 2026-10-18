import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// 守卫：Rust 计算内核 `native/fushi_compute` 是**硬依赖**（所有者拍板：不维护 Dart 与 Rust
/// 两份实现）。与 fushi_p2p / fushi_fsrs 的 copy-if-present 相反，缺库必须在**构建期**失败，
/// 而不是包照常出、用户手里才发现某个功能不可用。
///
/// 洞的形状：copy-if-present 是本仓原生库的默认写法，照抄一处新接线就会把「缺库静默跳过」
/// 带回来——CI 全绿、包照发。所以这里逐平台钉住「缺库 = 构建失败」，并钉住每个跑 Dart /
/// Flutter 测试的 CI job 都先编好库（否则那些 job 的测试在缺库下跑出来的结论不算数）：
///
/// - Windows / Linux CMake：缺库 `message(FATAL_ERROR ...)`，不在 `if(EXISTS)` 里静默跳过；
/// - macOS Runner 构建阶段 `bundle_fushi_compute.sh`：缺库 `exit 1`；
/// - iOS Runner 构建阶段 `check_fushi_compute.sh`（见 ios_native_umbrella_link_guard_test）；
/// - Android：`checkFushiComputeNative` 挂在 `preBuild` 上，缺 ABI 抛 GradleException；
/// - 本地新 worktree：`tool/bootstrap.ps1` / `bootstrap.sh` 编它；
/// - CI：凡是跑 `flutter test` / `flutter_test_failures.dart` 的 job 都用
///   `setup-fushi-compute` 或显式设 `FUSHI_COMPUTE_LIB`。
void main() {
  // 测试 cwd 是 `fushi/`。
  String read(String path) {
    final File file = File(path);
    expect(file.existsSync(), isTrue, reason: '${file.absolute.path} 不存在');
    return file.readAsStringSync().replaceAll('\r\n', '\n');
  }

  /// CMake 注释是 `#`，与 YAML 同一种掩码。
  String code(String path) => maskHashComments(read(path));

  for (final (String platform, String path, String lib)
      in <(String, String, String)>[
        ('Windows', 'windows/CMakeLists.txt', 'FUSHI_COMPUTE_DLL'),
        ('Linux', 'linux/CMakeLists.txt', 'FUSHI_COMPUTE_SO'),
      ]) {
    test('$platform CMake：缺 fushi_compute 是配置期 FATAL_ERROR', () {
      final String cmake = code(path);
      expect(
        cmake,
        contains('if(NOT EXISTS "\${$lib}")\n  message(FATAL_ERROR'),
        reason: '$path：fushi_compute 缺库必须直接失败',
      );
      expect(
        cmake,
        isNot(contains('if(EXISTS "\${$lib}")')),
        reason: '$path：fushi_compute 不能写成 copy-if-present',
      );
      expect(cmake, contains('install(FILES "\${$lib}"'));
    });
  }

  test('macOS：Bundle fushi_compute 阶段缺库 exit 1，并挂在 Runner 上', () {
    final String script = read('macos/bundle_fushi_compute.sh');
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
        r'shellScript = "/bin/bash \"$PROJECT_DIR/bundle_fushi_compute.sh\"\n";',
      ),
    );
    expect(pbx, contains('/* Bundle fushi_compute dylib */,'));
  });

  test('Android：checkFushiComputeNative 挂在 preBuild 上并在缺库时抛错', () {
    final String gradle = maskComments(read('android/app/build.gradle'));
    expect(
      gradle,
      contains(
        "main.jniLibs.srcDirs += '../../../native/fushi_compute/prebuilt/android'",
      ),
    );
    expect(gradle, contains('tasks.register("checkFushiComputeNative")'));
    expect(gradle, contains("project.findProperty('target-platform')"));
    expect(gradle, contains('libfushi_compute.so'));
    expect(
      gradle,
      contains(
        'if (task.name == "preBuild") {\n'
        '        task.dependsOn(checkFushiComputeNative)',
      ),
    );
    final int check = gradle.indexOf(
      'tasks.register("checkFushiComputeNative")',
    );
    expect(
      gradle.indexOf('throw new GradleException', check),
      greaterThan(check),
    );
  });

  test('本地 bootstrap 编 fushi_compute，缺 cargo 报错而不是跳过', () {
    final String ps1 = maskHashComments(read('../tool/bootstrap.ps1'));
    expect(ps1, contains("'build_windows_dll.ps1'"));
    expect(ps1, contains("'build_macos_dylib.sh'"));
    expect(ps1, contains("'build_linux_so.sh'"));
    expect(ps1, contains('Get-Command cargo'));
    expect(ps1, contains(r'param([switch]$SkipNativeCompute)'));
    final String sh = maskHashComments(read('../tool/bootstrap.sh'));
    expect(sh, contains('bash native/fushi_compute/build_linux_so.sh'));
    expect(sh, contains('bash native/fushi_compute/build_macos_dylib.sh'));
    expect(sh, contains('command -v cargo'));
  });

  group('CI：跑 Dart / Flutter 测试的 job 先编好 fushi_compute', () {
    /// 只跑 workflow / 发布脚本守卫（纯源码扫描，不加载原生库），不需要真库。
    const Map<String, String> exempt = <String, String>{
      'ci-config-gate.yml/guards': '只跑扫 .github / tool 文本的守卫测试',
    };
    final RegExp testCommand = RegExp(
      r'flutter_test_failures\.dart|\bflutter test\b',
    );
    final Directory dir = Directory('../.github/workflows');
    final List<File> files =
        dir
            .listSync()
            .whereType<File>()
            .where((File f) => f.path.endsWith('.yml'))
            .toList()
          ..sort((File a, File b) => a.path.compareTo(b.path));

    test('扫描面非空', () => expect(files.length, greaterThan(10)));

    int testJobs = 0;
    for (final File f in files) {
      final String name = f.uri.pathSegments.last;
      final String text = maskHashComments(
        f.readAsStringSync().replaceAll('\r\n', '\n'),
      );
      for (final MapEntry<String, String> job in _jobs(text).entries) {
        if (!testCommand.hasMatch(job.value)) continue;
        final String id = '$name/${job.key}';
        testJobs++;
        test(id, () {
          if (exempt.containsKey(id)) return;
          final bool built =
              job.value.contains(
                'uses: ./.github/actions/setup-fushi-compute',
              ) ||
              job.value.contains('FUSHI_COMPUTE_LIB');
          expect(
            built,
            isTrue,
            reason:
                '$id 跑 Dart / Flutter 测试，但没先编 fushi_compute（硬依赖）：'
                '加 `uses: ./.github/actions/setup-fushi-compute`。',
          );
        });
      }
    }
    test('规模哨兵：至少找到 main / release / golden 的测试 job', () {
      expect(testJobs, greaterThanOrEqualTo(4));
    });
  });
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
