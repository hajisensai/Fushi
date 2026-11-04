// iOS entitlement 与描述文件的对应关系（源码扫描守卫，BUG-4013 起）。
//
// `ios/Runner/Runner.entitlements` 列出 app 要的全部 entitlement（APNs 推送、扩展虚拟地址
// 空间）。描述文件没授予的任何一项签进去，codesign 直接失败、TestFlight 整条断；反过来
// 不接入这份文件，扩展虚拟地址空间就永远不生效，iOS 上地址空间吃满照旧 abort（BUG-4013）。
// 所以 `release-desktop.yml` 必须对**每一个** key 逐项看描述文件：授予就留、没授予就从
// runner 上这份文件删掉，至少剩一项才接入 CODE_SIGN_ENTITLEMENTS。这里钉住这个不变式：
// 往 Runner.entitlements 加 key 却忘了在 workflow 里加对应探测 / 删除，这个测试就红。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const String extendedVa =
      'com.apple.developer.kernel.extended-virtual-addressing';

  final String entitlements = File(
    'ios/Runner/Runner.entitlements',
  ).readAsStringSync().replaceAll('\r\n', '\n');
  final String workflow = File(
    '../.github/workflows/release-desktop.yml',
  ).readAsStringSync().replaceAll('\r\n', '\n');

  /// TestFlight 签名那一步（装描述文件 → 写 xcconfig）的脚本体。
  String signingStep() {
    final int start = workflow.indexOf(
      '- name: Install provisioning profile and signing xcconfig',
    );
    final int end = workflow.indexOf(
      '- name: Build signed iOS App Store IPA',
      start,
    );
    expect(start, isNonNegative);
    expect(end, greaterThan(start));
    return workflow.substring(start, end);
  }

  List<String> entitlementKeys() => RegExp(r'<key>([^<]+)</key>')
      .allMatches(
        // 注释里提到的 key 不算。
        entitlements.replaceAll(RegExp(r'<!--[\s\S]*?-->'), ''),
      )
      .map((RegExpMatch m) => m.group(1)!)
      .toList();

  test('Runner.entitlements requests extended virtual addressing', () {
    expect(
      RegExp(
        '<key>${RegExp.escape(extendedVa)}</key>\\s*<true/>',
      ).hasMatch(entitlements),
      isTrue,
      reason: 'BUG-4013：扩展虚拟地址空间 entitlement 必须为 true',
    );
    expect(
      entitlementKeys(),
      containsAll(<String>['aps-environment', extendedVa]),
    );
  });

  test(
    'every entitlement is probed in the profile and dropped when absent',
    () {
      final String step = signingStep();
      expect(
        step,
        contains('ENTITLEMENTS_FILE="fushi/ios/Runner/Runner.entitlements"'),
      );
      final int wire = step.indexOf(
        'echo "CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements"',
      );
      expect(wire, isNonNegative);
      for (final String key in entitlementKeys()) {
        final int probe = step.indexOf(
          "Print :Entitlements:$key' \"\$PROFILE_PLIST\"",
        );
        final int drop = step.indexOf("Delete :$key' \"\$ENTITLEMENTS_FILE\"");
        expect(probe, isNonNegative, reason: '$key 没有对照描述文件');
        expect(drop, greaterThan(probe), reason: '$key 描述文件没授予时没有删掉');
        expect(wire, greaterThan(drop), reason: '$key 要在接入前处理');
      }
    },
  );

  test('App Group is kept only when both profiles grant it', () {
    const String appGroup = 'com.apple.security.application-groups';
    expect(entitlementKeys(), contains(appGroup));
    final String step = signingStep();
    // 主 app 描述文件与扩展描述文件都得带 group（值也要对得上）才算授予。
    expect(
      step,
      contains(
        "Print :Entitlements:$appGroup' \"\$PROFILE_PLIST\" 2>/dev/null "
        '| grep -qF "\$APP_GROUP"',
      ),
    );
    expect(
      step,
      contains(
        "Print :Entitlements:$appGroup' \"\$W_PLIST\" 2>/dev/null "
        '| grep -qF "\$APP_GROUP"',
      ),
    );
    // 没授予：删掉这项并把扩展整个摘掉，不能只删 key 留下读不到快照的扩展。
    final int drop = step.indexOf("Delete :$appGroup' \"\$ENTITLEMENTS_FILE\"");
    final int strip = step.indexOf('widgets_target.rb strip ios');
    expect(drop, isNonNegative);
    expect(strip, greaterThan(drop));
  });

  test('every widgets extension entitlement is probed in its own profile', () {
    final String widgetsEntitlements = File(
      'ios/FushiWidgets/FushiWidgets.entitlements',
    ).readAsStringSync().replaceAll('\r\n', '\n');
    final List<String> keys = RegExp(r'<key>([^<]+)</key>')
        .allMatches(
          widgetsEntitlements.replaceAll(RegExp(r'<!--[\s\S]*?-->'), ''),
        )
        .map((RegExpMatch m) => m.group(1)!)
        .toList();
    expect(keys, isNotEmpty);
    final String step = signingStep();
    final int wire = step.indexOf(
      'echo "CODE_SIGN_ENTITLEMENTS = FushiWidgets/FushiWidgets.entitlements"',
    );
    expect(wire, isNonNegative);
    expect(
      step.substring(0, wire).lastIndexOf(r'if [ "$WIDGETS" = true ]; then'),
      isNonNegative,
      reason: '扩展 entitlements 只在扩展描述文件通过对照后才接入',
    );
    for (final String key in keys) {
      final int probe = step.indexOf("Print :Entitlements:$key' \"\$W_PLIST\"");
      expect(probe, isNonNegative, reason: '$key 没有对照扩展描述文件');
      expect(wire, greaterThan(probe), reason: '$key 要在接入前对照');
    }
  });

  test('entitlements are wired only when the profile grants at least one', () {
    final String step = signingStep();
    final int wire = step.indexOf(
      'echo "CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements"',
    );
    final String beforeWire = step.substring(0, wire);
    expect(
      beforeWire.lastIndexOf(r'if [ "$WIRE_ENTITLEMENTS" = 1 ]; then'),
      greaterThan(beforeWire.lastIndexOf('Delete :')),
    );
    // 扩展虚拟地址空间：只认描述文件里的 true；缺失时打 warning（不静默）。
    expect(step, contains(r'if [ "$EXTENDED_VA" = "true" ]; then'));
    expect(
      step,
      contains('::warning title=Extended virtual addressing missing::'),
    );
    // 工程本身不得无条件接入（与 feedback_push_wiring_guard_test 同一不变式）。
    expect(
      File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync(),
      isNot(contains('CODE_SIGN_ENTITLEMENTS')),
    );
  });
}
