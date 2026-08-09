import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/platform_updater.dart';
import 'package:fushi/src/utils/misc/update_checker.dart';
import 'package:path/path.dart' as p;

/// BUG-1481 守卫：**发布通道必须按产品族分开**。
///
/// 改名过渡期两个产品从同一个 GitHub 仓库发版——桥包 `app.hibiki.reader`（bridge 分支）
/// 和本体 `app.fushi.reader`。一个仓库只有一条 `update-manifest` 分支、一套 release tag，
/// 于是「只按通道分」的文件名和「全族共用」的 rolling tag 让两族撞在一起：
///
/// 1. 两族写同一个 `latest-<channel>.json`，CI `merge_update_manifest.py` 的单调 seq
///    守卫把顶层 release 永久判给 commit 数更高的一族 → 另一族客户端读到的
///    version/tag/assets 全不是自己的，自更新**不可能成功**（这条最致命：老 Hibiki
///    用户升不到迁移桥包）。
/// 2. 两族资产挂同一个 `debug-rolling` tag，而 prune 只按平台分组取 top N seq
///    → 低 seq 的那一族每次被另一族的构建删干净。
///
/// 历史名（`latest-<channel>.json` / `debug-rolling`）**冻结给 hibiki 族**：已在野的
/// Hibiki 客户端把那些 URL 编译进了包里，改不动。所以让路的必须是本体。
///
/// 这些用例是「不许退回共用」的硬门：任何一侧改回历史名都会红。
void main() {
  late Directory repoRoot;

  setUpAll(() {
    // 测试的 cwd 是 `fushi/`，仓库根是它的上一级。
    repoRoot = Directory.current.parent;
    expect(
      File(p.join(repoRoot.path, 'tool', 'publish_update_manifest.sh'))
          .existsSync(),
      isTrue,
      reason: 'repo root resolved wrong: ${repoRoot.path}',
    );
  });

  group('客户端读的清单 URL 带产品族', () {
    // 冻结给 hibiki 族的历史文件名。**故意写成字面量**而不是从
    // [kFushiManifestSuffix] 推导：用常量拼断言的话，把常量改成空串会让断言退化成
    // `endsWith('.json')` 恒真，守卫自己先失效（这个洞是变异实测打出来的）。
    // 这三个名字由已在野、改不动的老客户端定义，本来就是外部常量。
    const List<String> frozenHibikiManifests = <String>[
      'latest-beta.json',
      'latest-debug.json',
      'latest-stable.json',
    ];

    test('三个通道的每个镜像 URL 都不是 hibiki 族的历史文件名', () {
      expect(UpdateChannel.values.length, frozenHibikiManifests.length,
          reason: '新增通道时必须同步补一条冻结名，否则新通道会漏出守卫');
      for (final UpdateChannel channel in UpdateChannel.values) {
        final Map<String, String> urls = manifestUrlsForChannel(channel);
        expect(urls, isNotEmpty, reason: '$channel 必须有镜像清单 URL');
        for (final MapEntry<String, String> entry in urls.entries) {
          final String fileName = entry.value.split('/').last;
          expect(
            frozenHibikiManifests,
            isNot(contains(fileName)),
            reason: '$channel 的 ${entry.key} 镜像读的是 $fileName——'
                '这是老 Hibiki 客户端编译进包里的 URL，本体读它就会两族互相覆盖，'
                '老用户从此更新不到迁移桥包',
          );
          expect(
            fileName.contains('fushi'),
            isTrue,
            reason: '$channel 的清单名 $fileName 认不出产品族',
          );
        }
      }
    });

    test('产品族后缀非空，且不等于「无后缀」', () {
      expect(kFushiManifestSuffix.isNotEmpty, isTrue);
      expect(kFushiManifestSuffix.startsWith('-'), isTrue);
    });
  });

  group('CI 侧与客户端同族', () {
    test('publish_update_manifest.sh 写的每个清单名都带同一个产品族后缀', () {
      final String script =
          File(p.join(repoRoot.path, 'tool', 'publish_update_manifest.sh'))
              .readAsStringSync();

      // 只看真正的清单名赋值，不做全文 grep——否则脚本里解释性的注释会把守卫喂饱。
      // 限定 `latest-` 开头是为了排除把变量原样透传给子进程的
      // `MANIFEST_FILE="$MANIFEST_FILE"`，那不是在定义文件名。
      final List<String> assigned = RegExp(r'MANIFEST_FILE="(latest-[^"]+)"')
          .allMatches(script)
          .map((RegExpMatch m) => m.group(1)!)
          .toList();
      expect(
        assigned.length,
        greaterThanOrEqualTo(3),
        reason: '应至少给 debug/beta/formal 三个通道各定一个清单名，'
            '实际解析到 $assigned',
      );

      final String suffix = RegExp(r'MANIFEST_PRODUCT_SUFFIX="([^"]*)"')
              .firstMatch(script)
              ?.group(1) ??
          '';
      expect(
        suffix,
        kFushiManifestSuffix,
        reason: 'CI 脚本的产品族后缀与客户端常量必须一致，'
            '否则 CI 写一个文件、客户端读另一个，更新链路整条断掉',
      );

      for (final String name in assigned) {
        expect(
          name.contains(r'${MANIFEST_PRODUCT_SUFFIX}') ||
              name.endsWith('$kFushiManifestSuffix.json'),
          isTrue,
          reason: '清单名 $name 没带产品族后缀——两族会写同一个文件',
        );
      }
    });

    test('debug rolling tag 按产品族分，不再共用历史 tag', () {
      const List<List<String>> workflows = <List<String>>[
        <String>['.github', 'workflows', 'release.yml'],
        <String>['.github', 'workflows', 'release-desktop.yml'],
      ];

      int assignments = 0;
      for (final List<String> parts in workflows) {
        final File file = File(p.join(repoRoot.path, p.joinAll(parts)));
        expect(file.existsSync(), isTrue, reason: '${file.path} 不存在');
        final String body = file.readAsStringSync();

        // 同样只解析赋值右值，绕开注释。
        for (final RegExpMatch m
            in RegExp(r'ROLLING_DEBUG_TAG=(\S+)').allMatches(body)) {
          assignments++;
          final String tag = m.group(1)!;
          expect(
            tag.contains('fushi'),
            isTrue,
            reason: '${parts.last} 的 rolling tag 是 $tag——'
                '不带产品族的 tag 会让两族资产挂在同一个 release 上，'
                'prune 按平台取 top N seq 时低 seq 的那一族每次被删光',
          );
        }
      }
      expect(assignments, greaterThanOrEqualTo(5),
          reason: 'android 1 处 + desktop 4 处，共 5 处赋值；实际 $assignments');
    });
  });
}
