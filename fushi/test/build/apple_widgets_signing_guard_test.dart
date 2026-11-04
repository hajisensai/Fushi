// 守卫：FushiWidgets（主屏小组件扩展）在 iOS / macOS 签名链路上的两处不变式。
//
// 1. iOS：扩展 target 的 build configuration 不得在 target 级写签名设置。Xcode 里
//    target 级设置优先于 base configuration（ios/Flutter/FushiWidgets.xcconfig）；CI 往
//    xcconfig 追加 `CODE_SIGN_STYLE = Manual` + PROVISIONING_PROFILE_SPECIFIER，target 级的
//    `CODE_SIGN_STYLE = Automatic` 会把前者盖掉，签名 IPA 构建直接报「FushiWidgets is
//    automatically signed, but provisioning profile … has been manually specified」
//    （2026-11-04 develop 尖端 release-desktop ios job 真红）。Runner 同理不写。
// 2. macOS：tool/apple/macos_widgets_sign.sh 生成给 codesign 用的展开副本时，残留
//    `$(` 检查只能看真正签进去的值。entitlements 的 XML 注释里写着
//    `$(TeamIdentifierPrefix)` 之类说明，对原文 grep 会把注释当成没展开的变量
//    （同日 macos job 真红：「unexpanded build variable left in …」）。
//
// 纯 dart:io，从 fushi/ 运行。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

/// 取出 [pbxproj] 里 baseConfigurationReference 指向 FushiWidgets.xcconfig 的每个
/// XCBuildConfiguration 块的 buildSettings 文本。
List<String> _widgetsBuildSettings(String pbxproj) {
  final RegExp block = RegExp(
    r'/\* (\w+) \*/ = \{\n\s+isa = XCBuildConfiguration;\n'
    r'\s+baseConfigurationReference = \w+ /\* FushiWidgets\.xcconfig \*/;\n'
    r'\s+buildSettings = \{\n([\s\S]*?)\n\s+\};\n\s+name = \1;',
  );
  return block.allMatches(pbxproj).map((RegExpMatch m) => m.group(2)!).toList();
}

void main() {
  test('iOS FushiWidgets target 级不写签名设置，CI 的 xcconfig 手动签名才生效', () {
    final String pbxproj = _read('ios/Runner.xcodeproj/project.pbxproj');
    final List<String> configs = _widgetsBuildSettings(pbxproj);
    expect(
      configs.length,
      3,
      reason: 'FushiWidgets 应有 Debug / Release / Profile 三份配置（与 Runner 一致）',
    );
    for (final String settings in configs) {
      for (final String key in const <String>[
        'CODE_SIGN_STYLE',
        'PROVISIONING_PROFILE_SPECIFIER',
        'PROVISIONING_PROFILE',
        'DEVELOPMENT_TEAM',
        'CODE_SIGN_IDENTITY',
      ]) {
        expect(
          RegExp(
            '^\\s*"?$key(\\[[^\\]]*\\])?"? = ',
            multiLine: true,
          ).hasMatch(settings),
          isFalse,
          reason:
              'FushiWidgets 的 target 级 $key 会盖掉 CI 追加到 '
              'FushiWidgets.xcconfig 的手动签名',
        );
      }
    }
    // 工程级 TargetAttributes 的 ProvisioningStyle 同样会让 Xcode 认定为自动签名。
    expect(pbxproj.contains('ProvisioningStyle'), isFalse);
  });

  test('CI 往 FushiWidgets.xcconfig 追加的是手动签名四件套', () {
    final String workflow = _read('../.github/workflows/release-desktop.yml');
    final int at = workflow.indexOf(
      '} >> fushi/ios/Flutter/FushiWidgets.xcconfig',
    );
    expect(at, greaterThan(-1));
    final String injected = workflow.substring(
      workflow.lastIndexOf('{\n', at),
      at,
    );
    for (final String line in const <String>[
      'echo "CODE_SIGN_STYLE = Manual"',
      r'echo "DEVELOPMENT_TEAM = $APPLE_TEAM_ID"',
      r'echo "PROVISIONING_PROFILE_SPECIFIER = $WIDGETS_PROFILE_NAME"',
      'echo "CODE_SIGN_IDENTITY = Apple Distribution"',
    ]) {
      expect(injected, contains(line));
    }
  });

  test('widgets_target.rb 重建 iOS target 时不写 CODE_SIGN_STYLE', () {
    final String script = _read('tool/apple/widgets_target.rb');
    final int iosBranch = script.indexOf(
      "if platform == 'ios'\n    settings.merge!(",
    );
    expect(iosBranch, greaterThan(-1), reason: '找不到 iOS 设置分支');
    final int macBranch = script.indexOf('  else\n', iosBranch);
    expect(macBranch, greaterThan(iosBranch));
    // 公共设置（iOS 分支之前）与 iOS 分支里都不得出现；macOS 分支（ad-hoc 构建、CI 事后
    // 重签）照旧自动签名。
    final int settingsAt = script.indexOf('settings = {');
    expect(settingsAt, greaterThan(-1));
    expect(
      script.substring(settingsAt, macBranch).contains("'CODE_SIGN_STYLE' =>"),
      isFalse,
      reason:
          '重跑 widgets_target.rb add ios 会把 target 级 CODE_SIGN_STYLE 写回 pbxproj',
    );
  });

  test('macos_widgets_sign.sh 先去注释再查残留变量', () {
    final String script = _read('tool/apple/macos_widgets_sign.sh');
    final int convert = script.indexOf(
      r'plutil -convert xml1 -o - "$src" | sed',
    );
    final int check = script.indexOf(
      r"grep -q '\$(' "
      '"\$out"',
    );
    expect(convert, greaterThan(-1), reason: '展开前必须经 plutil 重新序列化（丢掉注释）');
    expect(check, greaterThan(convert), reason: '残留检查要在去注释之后');
    expect(
      script.contains(r'sed "s|\$(FUSHI_APP_GROUP)|$group|g" "$src"'),
      isFalse,
      reason: '直接对带注释的原文替换 + grep，注释里的 \$( 会误判',
    );

    // 两份要展开的 entitlements：去掉注释后，唯一的构建变量只能是脚本会替换的那个。
    for (final String path in const <String>[
      'macos/FushiWidgets/FushiWidgets.entitlements',
      'macos/Runner/Release.entitlements',
    ]) {
      final String values = _read(
        path,
      ).replaceAll(RegExp(r'<!--[\s\S]*?-->'), '');
      final Iterable<String> vars = RegExp(
        r'\$\([^)]*\)',
      ).allMatches(values).map((RegExpMatch m) => m.group(0)!);
      expect(vars.toSet(), <String>{
        r'$(FUSHI_APP_GROUP)',
      }, reason: '$path 里有 macos_widgets_sign.sh 不展开的构建变量');
    }
  });
}
