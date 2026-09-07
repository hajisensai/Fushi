import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `build_only` 出包不发布开关的不变式。
///
/// 用途：正式版要先出候选包给人装了测，测过再发。没有这个开关时，
/// `workflow_dispatch` 恒 `PUBLISH_MANAGED_RELEASE=true`——想出正式版包就必然
/// 同时发出正式 Release，无法把「构建」和「发布」这两个决定分开。
///
/// 这条守卫钉四件事，每一件失守都会让开关变成**看起来在用、实际没挡住**：
///
/// 1. 两条 workflow 都声明了这个输入，且默认 false（默认发布，保持既有行为）。
/// 2. 摁掉的是 `PUBLISH_MANAGED_RELEASE` 与 `PUBLISH_MANIFEST` 两个开关，且
///    release-desktop 的**四份** channel 解析块都摁到了——它有 windows / macos /
///    ios 等多个 job，每个 job 自带一份完整的通道解析，漏一份就是「那个平台照发」。
/// 3. iOS 的 TestFlight 上传也被挡住：那是不可回收的外发（构建号必须单调）。
/// 4. 正式版桥包硬门加了 `publish_manifest` 门之后**仍然**由 formal 发布触发——
///    这条最容易在「让 build_only 跑通」的过程中被顺手改松。
File _releaseYaml() => File('../.github/workflows/release.yml');
File _desktopYaml() => File('../.github/workflows/release-desktop.yml');

void main() {
  test('两条发布 workflow 都声明 build_only，且默认 false', () {
    for (final MapEntry<String, File> entry in <String, File>{
      'release.yml': _releaseYaml(),
      'release-desktop.yml': _desktopYaml(),
    }.entries) {
      final String yaml = entry.value.readAsStringSync();
      expect(yaml, contains('      build_only:'),
          reason: '${entry.key} 缺 build_only 输入。两条 workflow 同 tag 共用一个 '
              'concurrency 组、产出同一个 release 的不同平台资产，只有一边支持 '
              'build_only 会造出「只有一半平台的正式版」');

      // 默认必须是 false：默认行为保持「dispatch 即发布」，不要因为加了这个开关
      // 就把既有的发布流程改成需要显式开启。
      final int at = yaml.indexOf('      build_only:');
      final String block = yaml.substring(at, at + 400);
      expect(block, contains('default: false'),
          reason: '${entry.key} 的 build_only 默认必须是 false');
      expect(block, contains('type: boolean'),
          reason: '${entry.key} 的 build_only 必须是 boolean，字符串会让下面的 '
              '"= true" 判断在 UI 传值变化时静默失配');
    }
  });

  test('build_only 摁掉的是发布与清单两个开关，desktop 的四份解析块一份不漏', () {
    final String release = _releaseYaml().readAsStringSync();
    expect(release.contains(r'if [ "$INPUT_BUILD_ONLY" = "true" ]; then'), isTrue,
        reason: 'release.yml 没有 build_only 分支');
    expect(release, contains('INPUT_BUILD_ONLY: \${{ github.event.inputs.build_only }}'),
        reason: 'INPUT_BUILD_ONLY 必须挂进 channel step 的 env——不挂就是恒空，'
            '判断永不成立，开关看起来在却完全没挡住');

    final String desktop = _desktopYaml().readAsStringSync();
    final int branches =
        r'if [ "$INPUT_BUILD_ONLY" = "true" ]; then'.allMatches(desktop).length;
    expect(branches, 4,
        reason: 'release-desktop.yml 有 4 份独立的 channel 解析（每个 job 一份），'
            'build_only 必须每份都摁。当前只有 $branches 份——少的那些 job 会照常发布。'
            '若确实增删了 job，改这个数字前先确认每个 job 都覆盖到了');

    final int envs =
        'INPUT_BUILD_ONLY: \${{ github.event.inputs.build_only }}'
            .allMatches(desktop)
            .length;
    expect(envs, greaterThanOrEqualTo(5),
        reason: '4 份 channel 解析 + iOS signing step 各自都要挂 INPUT_BUILD_ONLY；'
            '当前 $envs 处');

    // 摁的必须是这两个开关本身，而不是别的等价物——而且**每一个** build_only 块
    // 都要摁到。这里刻意逐个 occurrence 检查而不是只看第一个：desktop 有 4 份，
    // 只查第一份的话，删掉第 4 份里的 PUBLISH_MANIFEST=false 这条守卫抓不到
    // （实测过：那种写法下变异不红，等于守卫是空壳）。
    for (final MapEntry<String, String> entry in <String, String>{
      'release.yml': release,
      'release-desktop.yml': desktop,
    }.entries) {
      final String yaml = entry.value;
      const String marker = r'if [ "$INPUT_BUILD_ONLY" = "true" ]; then';
      int at = yaml.indexOf(marker);
      int seen = 0;
      while (at >= 0) {
        seen += 1;
        // 块尾就是这段 if 的 `fi`：从 marker 起找第一个行首只有空白 + fi 的行。
        final int end = yaml.indexOf(RegExp(r'\n\s*fi\n'), at);
        expect(end, greaterThan(at),
            reason: '${entry.key} 第 $seen 个 build_only 分支没有闭合的 fi');
        final String block = yaml.substring(at, end);

        expect(block, contains('PUBLISH_MANAGED_RELEASE=false'),
            reason: '${entry.key} 第 $seen 个 build_only 分支没摁 '
                'PUBLISH_MANAGED_RELEASE（该 job 会照常建/改 Release）');
        expect(block, contains('PUBLISH_MANIFEST=false'),
            reason: '${entry.key} 第 $seen 个 build_only 分支没摁 PUBLISH_MANIFEST'
                '——只摁 Release 不摁清单，更新清单会指向一个不存在的 release，'
                '客户端更新器直接踩空');

        at = yaml.indexOf(marker, end);
      }
      expect(seen, greaterThan(0), reason: '${entry.key} 没有任何 build_only 分支');
    }
  });

  test('build_only 时不上传 TestFlight（不可回收的外发）', () {
    final String desktop = _desktopYaml().readAsStringSync();
    final int at = desktop.indexOf('TESTFLIGHT=false');
    expect(at, greaterThan(-1), reason: '找不到 TestFlight 判定块');

    final String block = desktop.substring(at, at + 600);
    expect(block, contains(r'[ "${INPUT_BUILD_ONLY:-}" != true ]'),
        reason: 'TestFlight 上传必须被 build_only 挡住：同一个版本号下构建号必须'
            '单调，传上去不可回收，而 build_only 的语义是「还没决定要不要发」');
  });

  test('正式版桥包硬门仍然由 formal 发布触发', () {
    final String release = _releaseYaml().readAsStringSync();
    final int at = release.indexOf('Require migration bridge assets on the formal tag');
    expect(at, greaterThan(-1), reason: '桥包硬门不见了——它防的是「已出货的老客户端'
        '按文件名挑包、桥包缺席时装成并存的第二个空 app、用户卸掉旧版即永久丢数据」');

    final String block = release.substring(at, at + 600);
    expect(block, contains("steps.channel.outputs.manifest_channel == 'formal'"),
        reason: '桥包门的 formal 判据不得被削弱');
    expect(block, contains("steps.channel.outputs.publish_manifest == 'true'"),
        reason: 'build_only 不发布任何东西时这道门没有保护对象，所以加了 '
            'publish_manifest 门；但真发 formal 时 publish_manifest 仍为 true，'
            '门必须原样生效。去掉这个条件不会红，去掉 formal 条件才会——'
            '两个条件都在，才是「只在真发布时拦」');
  });
}
