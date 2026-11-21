import 'dart:io';

import 'package:test/test.dart';

/// 守卫（BUG-4843）：Linux 无头服务端包的 glibc 基线只有一个数字，README 声明、CI
/// 产物检查、构建 runner 三者一致。
///
/// bundle 里除 glibc 外全是静态链 / 随包的，构建机的 glibc 就是产物的最低要求。
/// ubuntu-latest 换到 26.04 后 `libfushi_compute.so` 要 GLIBC_2.43，而 README 写
/// glibc ≥ 2.35，Debian 13（2.41）上 `serve` 直接抛 `FushiComputeUnavailableError`。
///
/// * `.github/scripts/check_glibc_baseline.sh` 的 `GLIBC_BASELINE` == README 里
///   `glibc ≥ x.y` 的 x.y（脚本运行时也核一次，这里是不用等 CI 的静态面）；
/// * 出 Linux 服务端包 / 给它预存原生件的三个 job 都钉在 glibc 不高于基线的 runner
///   上（`ubuntu-latest` 会随 GitHub 换代漂移，不许用）；
/// * 两个出包 job 都在 bundle 装齐之后、上传 / 冒烟之前跑这份检查。
void main() {
  final String script = File(
    '../.github/scripts/check_glibc_baseline.sh',
  ).readAsStringSync();
  final String readme = File(
    '../packages/fushi_server/README.md',
  ).readAsStringSync();

  final String baseline = RegExp(
    r'^GLIBC_BASELINE=(\d+\.\d+)$',
    multiLine: true,
  ).firstMatch(script)!.group(1)!;

  // GitHub 托管 runner 镜像自带的 glibc（runner 的 glibc = 产物要求的下限）。
  const Map<String, String> runnerGlibc = <String, String>{
    'ubuntu-22.04': '2.35',
    'ubuntu-24.04': '2.39',
  };

  test('README 声明的 glibc 基线与检查脚本一致', () {
    final RegExpMatch? m = RegExp(
      r'Linux：glibc ≥ (\d+\.\d+)',
    ).firstMatch(readme);
    expect(m, isNotNull, reason: 'README 运行期依赖里找不到「Linux：glibc ≥ x.y」');
    expect(
      m!.group(1),
      baseline,
      reason: 'README 写 glibc ≥ ${m.group(1)}，检查脚本基线是 $baseline',
    );
  });

  const Map<String, String> jobs = <String, String>{
    'build-multiplatform.yml': 'linux-server',
    'release-server.yml': 'linux',
    'native-cache-warm.yml': 'linux',
  };

  test('Linux 服务端原生件的 runner glibc 不高于基线', () {
    for (final MapEntry<String, String> e in jobs.entries) {
      final String job = _jobBody(e.key, e.value);
      final String? runsOn = RegExp(
        r'^    runs-on:\s*(\S+)\s*$',
        multiLine: true,
      ).firstMatch(job)?.group(1);
      final String where = '${e.key}#${e.value}';
      expect(
        runnerGlibc.containsKey(runsOn),
        isTrue,
        reason: '$where runs-on: $runsOn 不是 glibc 已知的钉版镜像',
      );
      expect(
        _compareVersions(runnerGlibc[runsOn]!, baseline) <= 0,
        isTrue,
        reason:
            '$where 在 $runsOn（glibc ${runnerGlibc[runsOn]}）上编，超过基线 $baseline',
      );
    }
  });

  test('出包 job 在 bundle 装齐后、上传 / 冒烟前跑 glibc 检查', () {
    const String check =
        'bash .github/scripts/check_glibc_baseline.sh build/fushi_server_linux/bundle';
    final Map<String, List<String>> before = <String, List<String>>{
      'build-multiplatform.yml': <String>[
        'native/fushi_anki_sync/build.sh --debug --install-dir',
        'cp native/fushidicts/prebuilt/linux-x64/libfushidicts_ffi.so',
        'fetch_onnxruntime_nuget.py "\$ORT_VERSION" linux-x64',
      ],
      // 构建命令在 packages/fushi_server/tool/build_linux_bundle.sh（与 Docker 共用），
      // workflow 按子命令调；下一个 test 核脚本里这三件确实进 bundle。
      'release-server.yml': <String>[
        'build_linux_bundle.sh anki-sync',
        'build_linux_bundle.sh fushidicts',
        'build_linux_bundle.sh cli',
      ],
    };
    const Map<String, String> after = <String, String>{
      'build-multiplatform.yml': 'name: fushi_server-linux-x64',
      'release-server.yml': 'name: Smoke (serve + embedded engine + models)',
    };
    for (final String wf in before.keys) {
      final String job = _jobBody(wf, jobs[wf]!);
      final int at = job.indexOf(check);
      expect(at, greaterThanOrEqualTo(0), reason: '$wf 没跑 glibc 基线检查');
      for (final String needle in before[wf]!) {
        final int i = job.indexOf(needle);
        expect(i, greaterThanOrEqualTo(0), reason: '$wf 找不到 $needle');
        expect(i < at, isTrue, reason: '$wf：$needle 在 glibc 检查之后才进 bundle');
      }
      final int end = job.indexOf(after[wf]!);
      expect(end > at, isTrue, reason: '$wf：glibc 检查要在「${after[wf]}」之前');
    }
  });

  test(
    'build_linux_bundle.sh 的 cli / fushidicts / anki-sync 把各自的 ELF 放进 bundle',
    () {
      final String bundle = File(
        '../packages/fushi_server/tool/build_linux_bundle.sh',
      ).readAsStringSync();
      String body(String fn) {
        final int at = bundle.indexOf('\n$fn() {');
        expect(at, greaterThanOrEqualTo(0), reason: '脚本没有 $fn');
        return bundle.substring(at, bundle.indexOf('\n}\n', at));
      }

      expect(
        body('cmd_cli'),
        contains('fetch_onnxruntime_nuget.py "\$ORT_VERSION" linux-x64'),
      );
      expect(
        body('cmd_fushidicts'),
        contains(
          'cp native/fushidicts/prebuilt/linux-x64/libfushidicts_ffi.so',
        ),
      );
      expect(
        body('cmd_anki_sync'),
        contains('native/fushi_anki_sync/build.sh --install-dir'),
      );
    },
  );
}

/// workflow 里某个 job 的原文（`jobs:` 下两格缩进的键到下一个同级键）。
String _jobBody(String workflow, String job) {
  final List<String> lines = File(
    '../.github/workflows/$workflow',
  ).readAsLinesSync();
  final int start = lines.indexOf('  $job:');
  expect(start, greaterThanOrEqualTo(0), reason: '$workflow 没有 job $job');
  final StringBuffer out = StringBuffer();
  for (int i = start + 1; i < lines.length; i++) {
    final String l = lines[i];
    if (RegExp(r'^  [A-Za-z0-9_-]+:').hasMatch(l) ||
        RegExp(r'^\S').hasMatch(l)) {
      break;
    }
    out.writeln(l);
  }
  return out.toString();
}

int _compareVersions(String a, String b) {
  final List<int> pa = a.split('.').map(int.parse).toList();
  final List<int> pb = b.split('.').map(int.parse).toList();
  for (int i = 0; i < pa.length || i < pb.length; i++) {
    final int x = i < pa.length ? pa[i] : 0;
    final int y = i < pb.length ? pb[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}
