// 拍板台 left3646 第 2 条：字幕解析逐位一致性测试（packages/fushi_audio 的
// subtitle_native_parity_test.dart）的冻结摘要分 x64 / arm64 两张表，而 PR 上跑 packages 测试的
// 只有 x64。native-compute-gate.yml 的 subtitle-parity-arm64 job 在 macOS arm64 上补跑这一个文件。
// 本守卫钉住这个 job 不被删、不被改成 x64 runner、不丢原生库 / 执行数哨兵，且改字幕解析的 PR
// 能触发它。
import 'dart:io';

import 'package:test/test.dart';

const String _workflowPath = '../.github/workflows/native-compute-gate.yml';
const String _parityTest = 'test/parsers/subtitle_native_parity_test.dart';

/// `jobs:` 下名为 [name] 的 job 正文（到下一个两格缩进的 job 头为止）。
String _jobBody(String yaml, String name) {
  final List<String> lines = yaml.replaceAll('\r\n', '\n').split('\n');
  final int start = lines.indexOf('  $name:');
  if (start == -1) return '';
  final StringBuffer out = StringBuffer();
  for (int i = start + 1; i < lines.length; i++) {
    final String l = lines[i];
    if (RegExp(r'^  [A-Za-z0-9_-]+:\s*$').hasMatch(l)) break;
    out.writeln(l);
  }
  return out.toString();
}

void main() {
  final String yaml = File(_workflowPath).readAsStringSync();
  final String job = _jobBody(yaml, 'subtitle-parity-arm64');

  test(
    'native-compute-gate keeps an arm64 job for the subtitle parity test',
    () {
      expect(job, isNotEmpty, reason: 'subtitle-parity-arm64 job missing');
      expect(
        job,
        contains('runs-on: macos-latest'),
        reason: 'must run on an Apple Silicon (arm64) runner',
      );
      expect(job, contains(r'test "$(uname -m)" = arm64'));
      expect(job, contains('uses: ./.github/actions/setup-fushi-compute'));
      expect(job, contains('working-directory: packages/fushi_audio'));
      expect(job, contains('dart test $_parityTest'));
      expect(
        job,
        contains('-lt 6'),
        reason: 'executed-count sentinel: zero tests run must not pass',
      );
    },
  );

  test('subtitle parser changes trigger the gate on pull requests', () {
    for (final String path in <String>[
      'native/fushi_compute/**',
      'packages/fushi_audio/lib/src/parsers/**',
      'packages/fushi_audio/$_parityTest',
      'packages/fushi_audio/test/parsers/subtitle_parity_corpus.dart',
    ]) {
      expect(yaml, contains("      - '$path'"), reason: path);
    }
  });
}
