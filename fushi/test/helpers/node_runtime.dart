/// 真跑 node（以及经 node 起的 headless Chrome）的测试共用的环境判定。
///
/// 约定：
/// - **CI 上缺 node / Chrome 一律失败**（`CI=true` 或 `GITHUB_ACTIONS=true`）：这类用例
///   往往是某段注入脚本的唯一行为报警器，在 CI 上跳过 = 守卫零执行、照样全绿。
/// - **本地缺时用 `test(skip:)` 明确跳过**并写出原因（报告里是 skipped + 原因），不在
///   用例体里静默 `return` / `markTestSkipped` 之后照常算通过。
///
/// 用法：在 `main()` 里探一次（声明期同步执行），`skip:` 交给 [NodeTestRuntime.skipReason]，
/// 用例体里经 [NodeTestRuntime.requireNode] 拿 node（CI 缺依赖在这里失败）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 一次 node 跑手运行的退出码与输出。
typedef NodeHarnessResult = ({int exitCode, String stdout, String stderr});

/// 跑一个 node 跑手：[payload] 编成 JSON 经 stdin 送入，命令行不传文件路径（跑手用
/// `test/reader/reader_harness_support.js` 的 `readPayload()` 读）。[arguments] 只放不涉及
/// 文件的参数（如变异名）。工作目录是当前目录（`fushi/`），[harness] 写相对路径。
///
/// [timeout]（应短于用例超时）到了就杀进程树（跑手起的 headless Chrome 一并杀掉），
/// 退出码记为 -1，输出照常带回已打印的部分，失败原因可读。
Future<NodeHarnessResult> runNodeHarness(
  String node,
  String harness,
  Object? payload, {
  List<String> arguments = const <String>[],
  Map<String, String>? environment,
  Duration? timeout,
}) async {
  final Process process = await Process.start(
    node,
    <String>[harness, ...arguments],
    workingDirectory: Directory.current.path,
    environment: environment,
  );
  final Future<String> stdout = process.stdout.transform(utf8.decoder).join();
  final Future<String> stderr = process.stderr.transform(utf8.decoder).join();
  process.stdin.add(utf8.encode(jsonEncode(payload)));
  await process.stdin.close();
  Future<int> exitCode = process.exitCode;
  if (timeout != null) {
    exitCode = exitCode.timeout(
      timeout,
      onTimeout: () {
        killProcessTree(process);
        return -1;
      },
    );
  }
  return (exitCode: await exitCode, stdout: await stdout, stderr: await stderr);
}

/// 是否跑在 CI 上（GitHub Actions 同时设 `CI=true` 与 `GITHUB_ACTIONS=true`）。
bool get isCiEnvironment {
  final Map<String, String> env = Platform.environment;
  bool on(String key) => (env[key] ?? '').trim().toLowerCase() == 'true';
  return on('CI') || on('GITHUB_ACTIONS');
}

/// PATH 上能跑起来的 node 可执行名；没有返回 null。
String? resolveNodeExecutable() {
  for (final String name
      in Platform.isWindows ? <String>['node.exe', 'node'] : <String>['node']) {
    try {
      if (Process.runSync(name, <String>['--version']).exitCode == 0) {
        return name;
      }
    } on ProcessException {
      // 试下一个可执行名。
    }
  }
  return null;
}

/// headless Chrome 是否可用：与浏览器 harness 同一个判定
/// （`tool/reader_pitch_headless/cdp_client.mjs` 的 `resolveChrome`），不在 Dart 里抄候选路径。
bool chromeAvailableVia(String node) {
  final File cdp = File('../tool/reader_pitch_headless/cdp_client.mjs');
  if (!cdp.existsSync()) return false;
  final ProcessResult result = Process.runSync(node, <String>[
    '-e',
    'import(process.argv[1]).then('
        '(m) => process.exit(m.resolveChrome() ? 0 : 77), '
        '() => process.exit(78))',
    Uri.file(cdp.absolute.path).toString(),
  ]);
  return result.exitCode == 0;
}

/// 杀掉 [process] 及其子进程（node harness 起的 headless Chrome）：只杀 node 会把 Chrome
/// 留作孤儿，继续占 CPU / 内存拖慢同机的其它测试。Windows 用 `taskkill /T`；POSIX 先杀直接
/// 子进程（Chrome 浏览器进程一死，它的 renderer 随之退出）再杀 node 本身。
void killProcessTree(Process process) {
  if (Platform.isWindows) {
    Process.runSync('taskkill', <String>['/PID', '${process.pid}', '/T', '/F']);
    return;
  }
  try {
    Process.runSync('pkill', <String>['-KILL', '-P', '${process.pid}']);
  } on ProcessException {
    // 没有 pkill 时至少杀掉 node 本身。
  }
  process.kill(ProcessSignal.sigkill);
}

/// 一个测试文件要的 node（以及可选的 Chrome）的探测结果。
class NodeTestRuntime {
  NodeTestRuntime._({
    required this.node,
    required this.needsChrome,
    required this.chromeAvailable,
  });

  /// 在 `main()` 里同步探一次。[needsChrome] = 用例还要经 node 起 headless Chrome。
  factory NodeTestRuntime.probe({bool needsChrome = false}) {
    final String? node = resolveNodeExecutable();
    return NodeTestRuntime._(
      node: node,
      needsChrome: needsChrome,
      chromeAvailable: needsChrome && node != null && chromeAvailableVia(node),
    );
  }

  /// 能跑起来的 node 可执行名；没有为 null。
  final String? node;

  /// 用例是否还要 headless Chrome。
  final bool needsChrome;

  /// [needsChrome] 时 Chrome 是否可用。
  final bool chromeAvailable;

  String? get _missing {
    if (node == null) return 'node not found on PATH';
    if (needsChrome && !chromeAvailable) {
      return 'headless Chrome not found (tool/reader_pitch_headless/'
          'cdp_client.mjs resolveChrome; set CHROME_PATH)';
    }
    return null;
  }

  /// 交给 `test(skip:)` / `group(skip:)`：本地缺依赖 → 跳过原因；依赖齐全或在 CI 上 → null
  /// （CI 上照跑，由 [requireNode] 失败）。
  String? get skipReason {
    final String? missing = _missing;
    if (missing == null || isCiEnvironment) return null;
    return '$missing; install it to run this test (required on CI)';
  }

  /// 用例体开头调：返回 node 可执行名；CI 上缺依赖直接失败。
  String requireNode() {
    final String? missing = _missing;
    if (missing != null) {
      fail(
        '$missing. On CI this test must run — skipping it would leave the '
        'guarded script with zero executions. Fix the CI image instead of '
        'turning this into a skip.',
      );
    }
    return node!;
  }
}
