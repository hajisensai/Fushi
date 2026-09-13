import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

// `AutoRepositionAnkiRepository` 的委派完整性守卫。
//
// 那个类的语义是「行为与被包装的仓库完全一致，只在 mineEntry 成功后多一个副作用」。
// 它靠**逐个方法手写委派**做到这点——而 Dart 没有自动转发，漏掉一个方法不会报错：
// 调用会静默掉回 `BaseAnkiRepository` 的降级默认（`supportsNoteTypeEditing` 变
// false、`noteFields` 恒返回 null、`listNewCards` 恒返回空……）。表现出来就是
// 「打开自动重排以后某个不相干的功能坏了」，而且不可能有人一眼看出关联。
//
// 所以这里把不变式钉死：**基类里凡是被任一后端实现覆盖过的实例成员，装饰器
// 都必须覆盖**。以后给基类加方法、或某个后端新覆盖一个方法，忘了同步装饰器
// 就会在这里红。
//
// 后端清单是**磁盘枚举**出来的（扫 `extends BaseAnkiRepository`），不是写死的
// 文件名——将来新增一个后端实现，它的 override 面自动纳入本守卫的扫描范围。

/// 从一份 Dart 源码里抓出所有 `@override` 紧跟着声明的成员名。
Set<String> _overriddenMembers(String source) {
  final Set<String> names = <String>{};
  final RegExp re = RegExp(
    r'@override\s*\n\s*([^\n;{]*?)\b([a-zA-Z_]\w*)\s*[({=]',
  );
  for (final RegExpMatch m in re.allMatches(source)) {
    final String name = m.group(2)!;
    names.add(name);
  }
  return names;
}

/// 递归找出 [root] 下所有源码文件。
List<File> _dartFiles(Directory root) => root
    .listSync(recursive: true)
    .whereType<File>()
    .where((File f) => f.path.endsWith('.dart'))
    .toList();

void main() {
  // 测试的工作目录是 `fushi/`。
  final Directory appLib = Directory('lib');
  final Directory packagesDir = Directory(p.join('..', 'packages'));
  final File decoratorFile =
      File(p.join('lib', 'src', 'anki', 'auto_reposition_anki_repository.dart'));
  final File baseFile = File(p.join(
    '..',
    'packages',
    'fushi_anki',
    'lib',
    'src',
    'base_anki_repository.dart',
  ));

  test('装饰器覆盖了所有被后端实现覆盖过的基类成员', () {
    expect(decoratorFile.existsSync(), isTrue,
        reason: '找不到装饰器源码，本守卫失去意义');
    expect(baseFile.existsSync(), isTrue, reason: '找不到 BaseAnkiRepository');

    final String decoratorSource = decoratorFile.readAsStringSync();
    final Set<String> delegated = _overriddenMembers(decoratorSource);
    // 空壳自检：装饰器至少得覆盖十几个成员，否则说明正则没匹配上，
    // 下面的差集会恒为空、守卫恒绿。
    expect(delegated.length, greaterThan(15),
        reason: '只解析出 ${delegated.length} 个委派，正则大概率没匹配上');

    // 枚举所有后端实现（含 app 侧的 AnkiMobile / RemoteMining）。
    final List<File> candidates = <File>[
      ..._dartFiles(appLib),
      if (packagesDir.existsSync()) ..._dartFiles(packagesDir),
    ];
    final Set<String> backendOverrides = <String>{};
    int backendCount = 0;
    for (final File f in candidates) {
      if (p.equals(f.path, decoratorFile.path)) continue;
      final String src = f.readAsStringSync();
      if (!src.contains('extends BaseAnkiRepository')) continue;
      backendCount++;
      backendOverrides.addAll(_overriddenMembers(src));
    }
    // 哨兵：本仓至少有 AnkiConnect / AnkiDroid / AnkiMobile / RemoteMining 四个
    // 实现。扫到的数量掉下来，多半是扫描根写错了、而不是真的删了后端。
    expect(backendCount, greaterThanOrEqualTo(4),
        reason: '只扫到 $backendCount 个后端实现，扫描根可能不对');

    // 只关心基类里真实存在的成员：后端自己的私有辅助方法不算。
    final String baseSource = baseFile.readAsStringSync();
    final Set<String> required = backendOverrides
        .where((String n) => RegExp('\\b$n\\s*[({=;]').hasMatch(baseSource))
        .toSet();

    final Set<String> missing = required.difference(delegated);
    expect(
      missing,
      isEmpty,
      reason: '这些成员被某个后端覆盖过，但 AutoRepositionAnkiRepository 没有委派：'
          '$missing\n'
          '漏委派不会报错，只会让调用静默掉回基类降级默认。'
          '请在 auto_reposition_anki_repository.dart 里补上纯委派实现。',
    );
  });
}
