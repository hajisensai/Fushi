// BUG-4640：slang 的 flat map 必须保持关闭。
//
// flat map = 每种语言一个 `_flatMapFunction`（约 1.2 万个 case 的 string switch）+
// `operator []`，唯一消费者是 slang 的 translation_overrides（本仓没开）。留着它：
//   ① Windows release AOT：gen_snapshot 把超长 string switch 降成 if-else 链，SSA 构建
//      （FlowGraph::RenameRecursive）沿支配树递归，深度随 case 数线性增长，1 MB 主线程栈
//      直接 0xC00000FD（BUG-1589，dart-lang/sdk#61935；CI 只靠 editbin 把栈拉到 128 MB 才过）；
//   ② 五端 Dart AOT 体积：17 个 `_flatMapFunction` 在 iOS 快照里占 15.06 MB（App.framework
//      108 MB 的 14%），Android / 桌面同比例。
// 关掉之后 `t['key']` 这种动态取文案不再编得过（operator [] 不生成），一律走 getter。
// 有人为了 translation_overrides 或「图省事的动态 key」把它打开时，这里先红。
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('slang.yaml 关闭 flat_map，且没开依赖它的 translation_overrides', () {
    final List<String> lines = File(
      'slang.yaml',
    ).readAsLinesSync().map((String l) => l.split('#').first.trim()).toList();
    expect(
      lines,
      contains('flat_map: false'),
      reason: 'fushi/slang.yaml 必须写 `flat_map: false`（slang 默认 true）',
    );
    expect(
      lines.where((String l) => l.startsWith('translation_overrides:')),
      everyElement('translation_overrides: false'),
      reason: 'translation_overrides 需要 flat map，开它等于把 flat map 加回来',
    );
  });

  test('生成的 strings.g.dart 不含 flat map', () {
    final File generated = File('lib/i18n/strings.g.dart');
    expect(
      generated.existsSync(),
      isTrue,
      reason: '先跑 `dart fushi/tool/gen_i18n.dart` 生成 strings.g.dart',
    );
    final String text = generated.readAsStringSync();
    // 规模哨兵：生成物塌成空文件时下面两条恒真。
    expect(text, contains('class Translations'));
    expect(
      text,
      isNot(contains('_flatMapFunction')),
      reason: 'strings.g.dart 里又出现了 flat map：查 slang.yaml / slang 版本默认值',
    );
    expect(text, isNot(contains('setFlatMapFunction')));
  });
}
