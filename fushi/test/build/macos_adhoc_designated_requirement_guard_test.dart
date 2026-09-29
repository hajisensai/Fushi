import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// ad-hoc 签名的 macOS 包默认指定要求是 cdhash，每次构建都变，TCC（辅助功能）
/// 授权因此每次更新都失效——全局查词要重新授权。发布工作流必须在所有 bundle 改动
/// 之后、只在非 Developer ID 路径上给外层 app 钉按 bundle id 判定的指定要求。
void main() {
  final String workflow =
      File('../.github/workflows/release-desktop.yml').readAsStringSync();
  const String stepName =
      '- name: Pin stable designated requirement for ad-hoc macOS app';

  test('ad-hoc macOS 包钉了按 bundle id 判定的指定要求', () {
    expect(workflow, contains(stepName));
    final String step = workflow.substring(
      workflow.indexOf(stepName),
      workflow.indexOf('- name: Import Developer ID certificate'),
    );
    expect(step, contains("if: steps.signing.outputs.macos_signed != 'true'"));
    expect(
      step,
      contains(r'-r="designated => identifier \"$bundle_id\""'),
      reason: '缺了显式 -r，ad-hoc 的指定要求就是每次构建都变的 cdhash。',
    );
    expect(
      step,
      isNot(contains('--deep --sign')),
      reason: '带 --deep 会把同一条 identifier 要求盖到内层 Mach-O 上，'
          '内层不满足、--verify --strict 失败。',
    );
  });

  test('钉指定要求排在最后一次 ad-hoc 整包重签之后', () {
    final int pin = workflow.indexOf(stepName);
    final int lastDeepResign = workflow.lastIndexOf(
      r'codesign --force --deep --sign - --timestamp=none "$app_dir"',
    );
    expect(lastDeepResign, greaterThan(0));
    expect(
      pin,
      greaterThan(lastDeepResign),
      reason: '之后任何 --deep --sign - 重签都会把钉好的指定要求冲回 cdhash。',
    );
  });
}
