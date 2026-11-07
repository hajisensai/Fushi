import 'dart:io';

import 'package:test/test.dart';
import 'package:path/path.dart' as p;

// 「静态能力位 + 当场探测」成对覆盖守卫（BUG-4122）。
//
// `BaseAnkiRepository` 里有几组成对的能力成员：`bool get supports<X>`（后端类型
// 支不支持）与 `Future<bool> probe<X>()`（连着的那一端此刻真能不能用，默认 =
// 静态位）。`DelegatingAnkiRepository` 把两者**分别**委派给 inner。
//
// 于是：一个装饰器子类只要改了静态位（例如 `SrsMiningAnkiRepository` 把
// `supportsDeckReposition` 改成 true——重排写本机复习库），就**必须**一起覆盖探测；
// 否则探测仍问 inner（Anki 后端），两者自相矛盾。BUG-4122 就是这样：复习下静态位
// 说能重排，探测却问 AnkiConnect / 默认 false，runner 在写前抛
// `AnkiRepositionUnsupportedException`，设置页入口也被置灰。
//
// Dart 不会因为漏覆盖报错，所以在这里钉死：凡继承 `DelegatingAnkiRepository` 的类，
// 覆盖了 `supports<X>` 而基类有 `probe<X>`，就必须同时覆盖 `probe<X>`。
// 成对清单从基类源码**解析**出来，不是写死的：以后基类新增一对能力自动纳入。

/// 本机构建 / 工具链生成的目录：里面是生成物或指回包根的插件符号链接
/// （例如构建 `example/` 后的 `windows/flutter/ephemeral/.plugin_symlinks/` 会
/// 链回包自身，跟链接递归在 Windows 上直接 PathNotFound），不是手写源码。
const Set<String> _generatedDirNames = <String>{
  'ephemeral',
  '.plugin_symlinks',
  'build',
  '.dart_tool',
};

/// 递归找出 [root] 下所有手写源码文件：不跟符号链接，跳过生成目录。
List<File> _dartFiles(Directory root) => root
    .listSync(recursive: true, followLinks: false)
    .whereType<File>()
    .where((File f) => f.path.endsWith('.dart'))
    .where(
      (File f) => !p
          .split(p.relative(f.path, from: root.path))
          .any(_generatedDirNames.contains),
    )
    .toList();

/// [source] 里所有 `class Name extends DelegatingAnkiRepository` 的类体
/// （从类声明行到下一个顶格 `}`）。键 = 类名。
Map<String, String> _delegatingClassBodies(String source) {
  final Map<String, String> bodies = <String, String>{};
  final RegExp decl = RegExp(
    r'^(?:abstract\s+)?class\s+(\w+)\s+extends\s+DelegatingAnkiRepository\b',
    multiLine: true,
  );
  for (final RegExpMatch m in decl.allMatches(source)) {
    final int end = source.indexOf('\n}', m.start);
    bodies[m.group(1)!] = source.substring(
      m.start,
      end < 0 ? source.length : end,
    );
  }
  return bodies;
}

/// [body] 里 `@override` 紧跟着声明的成员名。
Set<String> _overriddenMembers(String body) {
  final RegExp re = RegExp(
    r'@override\s*\n\s*([^\n;{]*?)\b([a-zA-Z_]\w*)\s*[({=]',
  );
  return <String>{for (final RegExpMatch m in re.allMatches(body)) m.group(2)!};
}

void main() {
  // 测试的工作目录是 `fushi/`。
  final File baseFile = File(
    p.join(
      '..',
      'packages',
      'fushi_anki',
      'lib',
      'src',
      'base_anki_repository.dart',
    ),
  );
  final File decoratorFile = File(
    p.join('lib', 'src', 'anki', 'delegating_anki_repository.dart'),
  );

  test('装饰器子类改了静态能力位就必须同时覆盖对应探测', () {
    expect(baseFile.existsSync(), isTrue, reason: '找不到 BaseAnkiRepository');
    final String baseSource = baseFile.readAsStringSync();

    // 基类里成对的 supports<X> / probe<X>。
    final Set<String> pairs = <String>{
      for (final RegExpMatch m in RegExp(
        r'Future<bool>\s+probe(\w+)\(',
      ).allMatches(baseSource))
        if (RegExp(
          'bool\\s+get\\s+supports${m.group(1)}\\b',
        ).hasMatch(baseSource))
          m.group(1)!,
    };
    // 空壳自检：至少有重排与媒体维护两对，解析不出来说明正则失效、守卫恒绿。
    expect(
      pairs,
      containsAll(<String>['DeckReposition', 'MediaMaintenance']),
      reason: '只解析出 $pairs，基类成对能力的正则大概率没匹配上',
    );

    // 装饰器基类本身必须两者都委派（否则子类不覆盖时连 inner 都问不到）。
    final Set<String> delegated = _overriddenMembers(
      decoratorFile.readAsStringSync(),
    );
    for (final String x in pairs) {
      expect(
        delegated,
        containsAll(<String>['supports$x', 'probe$x']),
        reason: 'DelegatingAnkiRepository 必须同时委派 supports$x 与 probe$x',
      );
    }

    final List<File> candidates = <File>[
      ..._dartFiles(Directory('lib')),
      ..._dartFiles(Directory(p.join('..', 'packages'))),
    ];
    final Map<String, Set<String>> subclasses = <String, Set<String>>{};
    for (final File f in candidates) {
      if (p.equals(f.path, decoratorFile.path)) continue;
      final String src = f.readAsStringSync();
      if (!src.contains('extends DelegatingAnkiRepository')) continue;
      _delegatingClassBodies(src).forEach((String name, String body) {
        subclasses[name] = _overriddenMembers(body);
      });
    }
    // 哨兵：本仓至少有自动重排 / 待发队列 / 复习三个装饰器；SRS 是本守卫的起因。
    expect(
      subclasses.keys,
      containsAll(<String>[
        'AutoRepositionAnkiRepository',
        'PendingMiningAnkiRepository',
        'SrsMiningAnkiRepository',
      ]),
      reason: '只扫到 ${subclasses.keys}，扫描根或类声明正则可能不对',
    );

    final List<String> violations = <String>[
      for (final MapEntry<String, Set<String>> e in subclasses.entries)
        for (final String x in pairs)
          if (e.value.contains('supports$x') && !e.value.contains('probe$x'))
            '${e.key}: 覆盖了 supports$x 却没覆盖 probe$x',
    ];
    expect(
      violations,
      isEmpty,
      reason:
          '探测会静默委派给 inner（Anki 后端），与本类声明的静态能力自相矛盾。'
          '请在该类里成对覆盖探测，如实回答本后端此刻的能力。',
    );
  });
}
