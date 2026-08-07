import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/mining/galgame_helper_installer.dart';

/// BUG-1449：helper 改为**构建期**解压成普通文件随包，消灭「需要与本体保持同步的第二份副本」。
///
/// 旧模型（helper 走网络下载时的设计）是：随包发 zip + sha256 侧车 → 运行期校验、解压、
/// 换入 `voice_hook/<arch>/`。改成随包内置后（BUG-1196）这套机制的前提没了，却留下一个
/// 必须与本体保持同步的解压副本——而「保持同步」正是 BUG-1448 断掉的环节：已装组件停在
/// 五天前的版本，注入后建出旧契约共享内存段，本体报 `protocol_mismatch`。
///
/// 新模型：`install_into_bundle.ps1` 在构建期把两个架构都解压进产物的
/// `voice_hook/<arch>/`，`hibiki.iss` 的 `Source: {#SourceDir}\*` 递归把它带进安装包。
/// helper 与本体同一次构建产出、同一个安装包落地，漂移在结构上不再可能。
///
/// 本文件钉住这条链路上三个「一改就回归」的点。
void main() {
  final File script =
      File('../native/galgame_hook/tools/install_into_bundle.ps1');
  final File iss = File('windows/installer/fushi.iss');
  final List<File> workflows = <File>[
    File('../.github/workflows/release-desktop.yml'),
    File('../.github/workflows/build-multiplatform.yml'),
  ];

  setUpAll(() {
    for (final File f in <File>[script, iss, ...workflows]) {
      expect(f.existsSync(), isTrue, reason: '守卫锚点文件不存在：${f.path}');
    }
  });

  group('构建期解压脚本与 Dart 清单不得漂移 (BUG-1449)', () {
    // 两份清单是不得已（一份给 PowerShell、一份给 Dart），但「两份各自漂移」正是
    // BUG-1345 的形态。这里逐架构逐条比对，任一侧增删都判红。
    for (final String arch in <String>['x86', 'x64']) {
      test('$arch 必需文件清单与 galgameHelperRequiredFiles 逐条一致', () {
        final String src = script.readAsStringSync();
        final int start = src.indexOf("'$arch' = @(");
        expect(start, greaterThanOrEqualTo(0),
            reason: '脚本里找不到 $arch 的清单块，守卫锚点失效');
        final int end = src.indexOf(')', start);
        expect(end, greaterThan(start));
        final String block = src.substring(start, end);

        final List<String> fromScript = RegExp(r"'([^']+\.[A-Za-z0-9]+)'")
            .allMatches(block)
            .map((RegExpMatch m) => m.group(1)!)
            .toList();
        // classdata.tpk / COPYING 之类没有常规扩展名的条目也要覆盖到，
        // 用「引号内不含空格且不是 arch 名」再兜一遍，避免正则漏项导致假绿。
        final List<String> allQuoted = RegExp(r"'([^']+)'")
            .allMatches(block)
            .map((RegExpMatch m) => m.group(1)!)
            .where((String v) => v != arch)
            .toList();

        expect(
          allQuoted..sort(),
          equals(galgameHelperRequiredFiles(arch).toList()..sort()),
          reason: 'install_into_bundle.ps1 的 $arch 清单与 Dart 侧不一致：'
              '构建期校验会漏检或误报，用户装到残缺 helper 才发现',
        );
        // 交叉确认上面的宽松正则确实覆盖了带扩展名的那批（防两个正则一起写错）。
        expect(allQuoted.toSet().containsAll(fromScript), isTrue);
      });
    }
  });

  group('两个 workflow 都走构建期解压，不再随包发 zip (BUG-1449)', () {
    for (final File wf in workflows) {
      test('${wf.path.split('/').last} 调用共用脚本且不复制 zip 到 galgame_helper', () {
        final String src = wf.readAsStringSync();
        expect(
          src.contains('install_into_bundle.ps1'),
          isTrue,
          reason: '${wf.path} 不再调用构建期解压脚本，helper 不会进包',
        );
        // 旧形态的唯一指纹：把 voice_hook_*.zip 复制进 galgame_helper 目录。
        expect(
          RegExp(r"galgame_helper'").hasMatch(src),
          isFalse,
          reason: '${wf.path} 又在随包发 zip 归档：'
              '磁盘上重新出现「需要与本体同步的第二份副本」，正是 BUG-1449 要消灭的形态',
        );
      });
    }
  });

  test('安装器必须清掉上一版残留的随包归档 (BUG-1449)', () {
    final String src = iss.readAsStringSync();
    expect(src.contains('[InstallDelete]'), isTrue,
        reason: 'hibiki.iss 没有 [InstallDelete] 段');
    final int start = src.indexOf('[InstallDelete]');
    final int end = src.indexOf('[Files]', start);
    expect(end, greaterThan(start), reason: '[InstallDelete] 之后应有 [Files]');
    expect(
      src.substring(start, end).contains(r'{app}\galgame_helper'),
      isTrue,
      reason: '升级时不清掉旧 galgame_helper：用户一旦删过 installed.sha256，'
          '旧 zip 会把安装器刚放好的新组件回填成旧的，直接复发 BUG-1448',
    );
  });
}
