// 守卫：release-desktop.yml 的 Apple 签名 / TestFlight 链路不变式。
//
// 这条链路的失败模式全是「构建照样绿，但产物错了」，靠人肉 review 挡不住：
//   1. TestFlight 上传如果误挂到 push 事件上，每次提交都会烧掉一个构建号，而构建号
//      在同一 CFBundleShortVersionString 下必须单调递增，浪费掉不可回收。
//   2. GitHub Release 的 iOS 资产必须继续是 no-codesign 包 —— 老用户用 AltStore /
//      Sideloadly 自签侧载的就是它，换成 App Store 签名包会直接打断他们。
//   3. macOS 公证要求每个可执行体都带强化运行时 + 安全时间戳。少了任一个，
//      notarytool 会在几分钟后才拒收，报错还只给 submission id。
//   4. 无人值守 runner 上少了 set-key-partition-list，codesign 会等一个永远不来的
//      钥匙串 UI 授权，表现为 job 挂死到超时。
//
// 纯 dart:io，不依赖 Flutter 运行时；从 hibiki/ 向上找仓库根。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Directory _repoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (File('${dir.path}/.github/workflows/release-desktop.yml')
        .existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail(
    '找不到含 .github/workflows/release-desktop.yml 的仓库根'
    '（从 ${Directory.current.path} 向上）',
  );
}

void main() {
  final root = _repoRoot();
  final workflow = File('${root.path}/.github/workflows/release-desktop.yml');
  late String content;

  setUpAll(() {
    expect(workflow.existsSync(), isTrue, reason: '缺 ${workflow.path}');
    content = workflow.readAsStringSync();
  });

  test('TestFlight 上传只能由手动 workflow_dispatch 的 beta/formal 触发', () {
    // 门必须同时含事件判断和通道判断；少任何一半 push 的 debug 通道就会开始上传。
    expect(
      content.contains(r'[ "$GITHUB_EVENT_NAME" = workflow_dispatch ]'),
      isTrue,
      reason: 'TestFlight 门必须显式要求 workflow_dispatch 事件',
    );
    expect(
      content.contains(r'[ "$RELEASE_CHANNEL" = beta ]'),
      isTrue,
      reason: 'TestFlight 门必须限定 beta/formal 通道',
    );
    // 上传步骤本身必须挂在门的输出上，不能是 always() 或无条件。
    expect(
      content.contains("if: steps.signing.outputs.testflight == 'true'"),
      isTrue,
      reason: '上传步骤必须由 signing 步骤的 testflight 输出把关',
    );
    expect(
      RegExp(r'- name: Upload to TestFlight\n\s+if: always\(\)')
          .hasMatch(content),
      isFalse,
      reason: 'TestFlight 上传绝不能是 always()',
    );
  });

  test('GitHub Release 的 iOS 资产仍是 no-codesign 包', () {
    expect(
      content.contains('flutter build ios --release --no-codesign'),
      isTrue,
      reason: '未签名 IPA 是侧载用户的唯一入口，不能被签名包顶掉',
    );
    // 上传到 Release 的 artifact 必须来自未签名产物目录，而不是 flutter build ipa
    // 的输出（build/ios/ipa）。
    expect(
      content.contains('path: hibiki/build/release-artifacts/hibiki-*-ios.ipa'),
      isTrue,
      reason: 'Release 资产必须来自 release-artifacts/（未签名打包路径）',
    );
    expect(
      content.contains('path: hibiki/build/ios/ipa'),
      isFalse,
      reason: 'App Store 签名 IPA 不得作为 Release 资产上传',
    );
  });

  test('macOS 签名带强化运行时和安全时间戳', () {
    // 公证的硬性前提。特别是 macos/Runner.xcodeproj 里 hoshidicts 的构建脚本用的是
    // `codesign --timestamp=none`，重签这一步就是用来覆盖它的。
    expect(
      content.contains('--force --timestamp --options runtime'),
      isTrue,
      reason: 'Developer ID 重签必须带 --timestamp --options runtime',
    );
    expect(
      content.contains('xcrun notarytool submit'),
      isTrue,
      reason: '签了不公证仍会被 Gatekeeper 拦',
    );
    expect(
      content.contains('xcrun stapler staple'),
      isTrue,
      reason: '不装订票据的话用户离线首启会被拦',
    );
  });

  test('导入证书后必须放开钥匙串分区列表', () {
    // 少了这步，无人值守 runner 上 codesign 会等一个永远不来的 UI 授权。
    // iOS 和 macOS 两个 job 各要一次。
    final occurrences =
        'security set-key-partition-list'.allMatches(content).length;
    expect(
      occurrences,
      greaterThanOrEqualTo(2),
      reason: 'iOS 与 macOS 两条导入路径都必须调用 set-key-partition-list，'
          '实际出现 $occurrences 次',
    );
  });

  test('Apple 凭据缺失时不得让发布链路失败', () {
    // 每个签名步骤都必须带条件；无条件的签名步骤会让 fork 和无账号状态下的
    // 发布直接红掉。
    for (final step in const [
      'Import iOS distribution certificate',
      'Install provisioning profile and signing xcconfig',
      'Build signed iOS App Store IPA',
      'Upload to TestFlight',
    ]) {
      expect(
        RegExp('- name: ${RegExp.escape(step)}\\n\\s+if: ').hasMatch(content),
        isTrue,
        reason: '步骤「$step」必须带 if: 条件',
      );
    }
    for (final step in const [
      'Import Developer ID certificate',
      'Sign macOS app with Developer ID',
      'Notarize and staple macOS app',
    ]) {
      expect(
        RegExp('- name: ${RegExp.escape(step)}\\n\\s+if: ').hasMatch(content),
        isTrue,
        reason: '步骤「$step」必须带 if: 条件',
      );
    }
  });

  test('ITSAppUsesNonExemptEncryption 已声明，TestFlight 不卡出口合规', () {
    final plist =
        File('${root.path}/hibiki/ios/Runner/Info.plist').readAsStringSync();
    expect(
      plist.contains('ITSAppUsesNonExemptEncryption'),
      isTrue,
      reason: '不声明的话每个 TestFlight 构建都要网页上手动答出口合规问卷，'
          'CI 自动发布失去意义',
    );
  });
}
