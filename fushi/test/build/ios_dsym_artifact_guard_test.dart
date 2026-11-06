// BUG-4102 / BUG-4075：iOS 崩溃诊断只有 `Runner+偏移` 与镜像 UUID，符号化要这一次构建的 dSYM。
// 两条出包路径（未签名 Release 资产、TestFlight 签名归档）各是一个二进制、UUID 不同，dSYM 都要存，
// 且按发布序号命名，取证时按报告里的构建号找。
import 'dart:io';

import 'package:test/test.dart';

void main() {
  final String desktop = File(
    '../.github/workflows/release-desktop.yml',
  ).readAsStringSync();

  String step(String name) {
    final int at = desktop.indexOf('- name: $name\n');
    expect(at, isNonNegative, reason: '缺少步骤「$name」');
    final int next = desktop.indexOf('\n      - name: ', at + 1);
    return desktop.substring(at, next < 0 ? desktop.length : next);
  }

  test('未签名 Release 构建的 dSYM 按序号存为 artifact', () {
    final String s = step('Upload iOS release dSYMs (no codesign)');
    expect(s, contains('actions/upload-artifact@'));
    expect(
      s,
      contains(
        r'name: ios-dsyms-unsigned-${{ steps.channel.outputs.release_sequence }}',
      ),
    );
    expect(s, contains('path: fushi/build/ios/Release-iphoneos/*.dSYM'));
    // 证据步骤失败不拖垮出包。
    expect(s, contains('continue-on-error: true'));
    expect(
      desktop.indexOf('- name: Upload iOS release dSYMs (no codesign)'),
      greaterThan(
        desktop.indexOf('- name: Build iOS release app (no codesign)'),
      ),
    );
  });

  test('TestFlight 签名归档的 dSYM 按序号存为 artifact，不混进 Release 资产', () {
    final String s = step('Upload signed iOS archive dSYMs');
    expect(s, contains("if: steps.signing.outputs.testflight == 'true'"));
    expect(
      s,
      contains(
        r'name: ios-dsyms-testflight-${{ steps.channel.outputs.release_sequence }}',
      ),
    );
    expect(s, contains('path: fushi/build/ios/archive/Runner.xcarchive/dSYMs'));
    expect(s, contains('continue-on-error: true'));
    expect(s, isNot(contains('name: desktop-artifacts-')));
    expect(
      desktop.indexOf('- name: Upload signed iOS archive dSYMs'),
      greaterThan(desktop.indexOf('- name: Build signed iOS App Store IPA')),
    );
  });
}
