// 守卫：release-desktop.yml 的 Apple 签名 / TestFlight 链路不变式。
//
// 这条链路的失败模式全是「构建照样绿，但产物错了」，靠人肉 review 挡不住：
//   1. TestFlight 上传如果误挂到 push 事件上，一天 5~13 次上传会让 App Store Connect
//      的处理排队压后真正想发的 beta、TestFlight 列表被 debug 构建淹掉。debug 包上
//      TestFlight 只能走定时通道 testflight-debug.yml（每 8 小时查一次 App Store
//      Connect，有新提交才 dispatch channel=debug + testflight_only=true）。
//   2. GitHub Release 的 iOS 资产必须继续是 no-codesign 包 —— 老用户用 AltStore /
//      Sideloadly 自签侧载的就是它，换成 App Store 签名包会直接打断他们。
//   3. macOS 公证要求每个可执行体都带强化运行时 + 安全时间戳。少了任一个，
//      notarytool 会在几分钟后才拒收，报错还只给 submission id。
//   4. 无人值守 runner 上少了 set-key-partition-list，codesign 会等一个永远不来的
//      钥匙串 UI 授权，表现为 job 挂死到超时。
//
// 纯 dart:io，不依赖 Flutter 运行时；从 fushi/ 向上找仓库根。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Directory _repoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (File(
      '${dir.path}/.github/workflows/release-desktop.yml',
    ).existsSync()) {
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
      RegExp(
        r'- name: Upload to TestFlight\n\s+if: always\(\)',
      ).hasMatch(content),
      isFalse,
      reason: 'TestFlight 上传绝不能是 always()',
    );
  });

  test('debug 通道只在 testflight_only 下放行 TestFlight', () {
    // 手动 dispatch 一个普通 debug 重发（不带 testflight_only）不得顺手传 TestFlight；
    // 定时通道 testflight-debug.yml 只走 testflight_only=true 这条。
    expect(
      content.contains(
        r'elif [ "$RELEASE_CHANNEL" = debug ] && [ "${INPUT_TESTFLIGHT_ONLY:-}" = true ]; then',
      ),
      isTrue,
      reason: 'debug 通道放行 TestFlight 必须以 testflight_only=true 为前提',
    );
    expect(
      content.contains(
        r'INPUT_TESTFLIGHT_ONLY: ${{ github.event.inputs.testflight_only }}',
      ),
      isTrue,
      reason: 'signing 步骤必须把 testflight_only 输入喂进 env，否则门里读到的永远是空',
    );
    // push 事件不得出现在门里：定时通道是 dispatch，push 永远不传。
    final int gateAt = content.indexOf('TESTFLIGHT=false');
    expect(gateAt, greaterThan(-1));
    final String gate = content.substring(gateAt, gateAt + 600);
    expect(
      gate.contains('"\$GITHUB_EVENT_NAME" = push'),
      isFalse,
      reason: 'TestFlight 门不得放行 push 事件',
    );
    // testflight_only 的 run 唯一目的就是上传：门关着（缺密钥等）必须红，不能绿着跳过，
    // 否则定时通道看 App Store Connect 的号没涨会每 8 小时白派一次。
    expect(
      RegExp(
        r'if \[ "\$\{INPUT_TESTFLIGHT_ONLY:-\}" = true \] && \[ "\$TESTFLIGHT" != true \]; then\n\s+echo "::error[^\n]*\n\s+exit 1',
      ).hasMatch(content),
      isTrue,
      reason: 'testflight_only 且上传门关闭时必须 ::error + exit 1',
    );
  });

  test('testflight_only 只做签名 iOS + 传 TestFlight，其余全跳', () {
    final int inputAt = content.indexOf('      testflight_only:');
    expect(inputAt, greaterThan(-1), reason: '缺 testflight_only 输入');
    final String input = content.substring(inputAt, inputAt + 400);
    expect(
      input,
      contains('default: false'),
      reason: 'testflight_only 默认必须 false，否则普通 dispatch 什么都不发',
    );
    expect(input, contains('type: boolean'));

    // 三个不该跑的 job 都要在 job 级 if 里摁掉；漏一个就是 testflight_only 顺手
    // 重发了一次 rolling debug（publish）或白跑一小时 runner（windows / macos）。
    for (final String job in const ['windows', 'macos', 'publish']) {
      // 只允许在 job 体（4 空格缩进）内向下找 if，不能越过下一个 job 头。
      final RegExp jobIf = RegExp(
        '\\n  $job:\\n(?:    .*\\n)*?    if: .*testflight_only != \'true\'',
      );
      expect(
        jobIf.hasMatch(content),
        isTrue,
        reason: 'job「$job」的 if 必须含 testflight_only != \'true\'',
      );
    }
    // ios job 本身必须跑（否则什么都传不了），但未签名 IPA 三步要跳。
    expect(
      RegExp('\\n  ios:\\n    if: .*testflight_only').hasMatch(content),
      isFalse,
      reason: 'ios job 不得被 testflight_only 摁掉',
    );
    for (final String step in const [
      'Build iOS release app (no codesign)',
      'Prepare unsigned iOS IPA release asset',
      'Upload iOS IPA artifact',
    ]) {
      expect(
        RegExp(
          '- name: ${RegExp.escape(step)}\\n\\s+if: .*testflight_only != \'true\'',
        ).hasMatch(content),
        isTrue,
        reason: '步骤「$step」在 testflight_only 下必须跳过',
      );
    }
  });

  test('定时 TestFlight 通道：先问 App Store Connect 再 dispatch，一天三次', () {
    final File scheduled = File(
      '${root.path}/.github/workflows/testflight-debug.yml',
    );
    expect(scheduled.existsSync(), isTrue, reason: '缺 testflight-debug.yml');
    final String yml = scheduled.readAsStringSync();

    // 一天三次：cron 小时段恰好三个值。
    final RegExpMatch? cron = RegExp(
      r"- cron: '(\d+) ([\d,]+) \* \* \*'",
    ).firstMatch(yml);
    expect(cron, isNotNull, reason: 'cron 表达式必须是「分 时段 * * *」');
    expect(
      cron!.group(2)!.split(',').length,
      3,
      reason: '用户定的是一天三次（当前 ${cron.group(2)}）',
    );
    expect(
      int.parse(cron.group(1)!),
      isNot(0),
      reason: '分钟数要错开整点，GitHub 整点丢 schedule 触发是出了名的',
    );

    // 判新判据来自 Apple，不是本地记号。
    expect(yml, contains('tool/asc_latest_build_number.sh'));
    expect(yml, contains('tool/release_sequence.sh'));
    expect(
      yml,
      contains('fetch-depth: 0'),
      reason: 'release_sequence.sh 用 rev-list --count，浅克隆会算出 1',
    );
    expect(
      yml,
      contains('ref: develop'),
      reason: '定时 workflow 只从 main 触发，检查对象必须显式指向 develop',
    );

    // 检查 job 校验的密钥必须与 release-desktop ios job 的 CREDS 门同一组六个，
    // 少一个就是「dispatch 出去绿着跳过、号不涨、8 小时后再派」。
    for (final String secret in const [
      'APPSTORE_API_KEY_ID',
      'APPSTORE_API_ISSUER_ID',
      'APPSTORE_API_PRIVATE_KEY',
      'IOS_DIST_CERT_P12_BASE64',
      'IOS_PROVISIONING_PROFILE_BASE64',
      'APPLE_TEAM_ID',
    ]) {
      expect(
        yml,
        contains('$secret: \${{ secrets.$secret }}'),
        reason: '检查 job 必须把 $secret 喂进 env 并校验',
      );
    }
    // 一个 sha 只试一次：dispatch 前必须按 head sha 查既有 dispatch run，
    // 否则 altool 持续拒收会变成一天三次的固定重试。
    expect(
      yml,
      contains(
        'gh run list --workflow release-desktop.yml --event workflow_dispatch',
      ),
      reason: 'dispatch 前必须查同 sha 的既有 run',
    );
    expect(
      yml,
      contains(r'--commit "$HEAD_SHA"'),
      reason: '既有 run 的查询必须按 head sha 过滤',
    );

    // dispatch 到 release-desktop，且只传 TestFlight。
    expect(yml, contains('gh workflow run release-desktop.yml --ref develop'));
    expect(yml, contains('-f channel=debug'));
    expect(yml, contains('-f testflight_only=true'));
    expect(
      yml,
      contains('actions: write'),
      reason: 'gh workflow run 需要 actions: write',
    );
    expect(
      yml.contains('contents: write'),
      isFalse,
      reason: '本 workflow 不写仓库，不该要 contents: write',
    );
    // dispatch 必须挂在比较结果上。
    expect(
      RegExp(
        r'- name: Dispatch release-desktop[^\n]*\n\s+if: steps\.compare\.outputs\.dispatch == '
        "'true'",
      ).hasMatch(yml),
      isTrue,
      reason: 'dispatch 步骤必须由 compare 的 dispatch 输出把关',
    );
  });

  test('App Store Connect JWT 只有一份实现', () {
    expect(File('${root.path}/tool/asc_api_jwt.rb').existsSync(), isTrue);
    expect(
      File('${root.path}/tool/asc_latest_build_number.sh').existsSync(),
      isTrue,
    );
    final String kazumi = File(
      '${root.path}/tool/sign_kazumi_adhoc.sh',
    ).readAsStringSync();
    expect(
      kazumi,
      contains('asc_api_jwt.rb'),
      reason: 'kazumi 脚本必须复用共享 JWT 实现',
    );
    expect(
      kazumi.contains('alg: "ES256"'),
      isFalse,
      reason: 'JWT 生成不得在 kazumi 脚本里再内联一份',
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
      content.contains('path: fushi/build/release-artifacts/fushi-*-ios.ipa'),
      isTrue,
      reason: 'Release 资产必须来自 release-artifacts/（未签名打包路径）',
    );
    expect(
      content.contains('path: fushi/build/ios/ipa'),
      isFalse,
      reason: 'App Store 签名 IPA 不得作为 Release 资产上传',
    );
  });

  test('macOS 签名带强化运行时和安全时间戳', () {
    // 公证的硬性前提。特别是 macos/Runner.xcodeproj 里 fushidicts 的构建脚本用的是
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
    final occurrences = 'security set-key-partition-list'
        .allMatches(content)
        .length;
    expect(
      occurrences,
      greaterThanOrEqualTo(2),
      reason:
          'iOS 与 macOS 两条导入路径都必须调用 set-key-partition-list，'
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
    final plist = File(
      '${root.path}/fushi/ios/Runner/Info.plist',
    ).readAsStringSync();
    expect(
      plist.contains('ITSAppUsesNonExemptEncryption'),
      isTrue,
      reason:
          '不声明的话每个 TestFlight 构建都要网页上手动答出口合规问卷，'
          'CI 自动发布失去意义',
    );
  });
}
