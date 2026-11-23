import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/advanced_mining_handoff.dart';
import 'package:fushi/src/lookup/advanced_mining_handoff_gate.dart';

/// HBK-AUDIT-003：转交来的高级制卡在「问词条下标」的异步往返途中被用户手动查词
/// 取代时，旧回包不得打开对话框（旧 DOM 下标套到新结果上就是制错卡）。
/// 用可手动完成的定位 Future 精确摆出竞态。
class _Result {
  _Result(this.label);
  final String label;
}

class _View {}

class _Harness {
  _Harness() {
    gate = AdvancedMiningHandoffGate<_Result, _View>(
      currentGeneration: () => generation,
      renderedTarget: () => rendered,
      locate: (AdvancedMiningRenderTarget<_Result, _View> target, handoff) {
        final Completer<int> completer = Completer<int>();
        locates.add((target: target, handoff: handoff, reply: completer));
        return completer.future;
      },
      open: (int index, AdvancedMiningHandoff handoff) async {
        opened.add((index: index, handoff: handoff));
      },
      onNotFound: notFound.add,
    );
  }

  late final AdvancedMiningHandoffGate<_Result, _View> gate;
  int generation = 0;
  AdvancedMiningRenderTarget<_Result, _View>? rendered;
  final _View view = _View();
  final List<
    ({
      AdvancedMiningRenderTarget<_Result, _View> target,
      AdvancedMiningHandoff handoff,
      Completer<int> reply,
    })
  >
  locates =
      <
        ({
          AdvancedMiningRenderTarget<_Result, _View> target,
          AdvancedMiningHandoff handoff,
          Completer<int> reply,
        })
      >[];
  final List<({int index, AdvancedMiningHandoff handoff})> opened =
      <({int index, AdvancedMiningHandoff handoff})>[];
  final List<AdvancedMiningHandoff> notFound = <AdvancedMiningHandoff>[];

  /// 页面铸新查词代（_mintSearchGeneration 的语义）。
  int mint() {
    gate.revoke();
    return ++generation;
  }

  void render(String label) {
    rendered = (result: _Result(label), view: view);
  }
}

const AdvancedMiningHandoff _a = AdvancedMiningHandoff(
  expression: '生',
  reading: 'なま',
  matched: '生',
);
const AdvancedMiningHandoff _b = AdvancedMiningHandoff(
  expression: '晴れる',
  reading: 'はれる',
  matched: '晴れた',
);

void main() {
  test('正常路径：画完这次结果 → 定位 → 用回包下标打开对话框', () async {
    final _Harness h = _Harness();
    h.gate.arm(_a, generation: h.mint());
    h.render('A');
    final Future<void> done = h.gate.onRendered();
    expect(h.locates, hasLength(1));
    h.locates.single.reply.complete(3);
    await done;
    expect(h.opened.single.index, 3);
    expect(h.opened.single.handoff, _a);
    expect(h.gate.pending, isNull);
  });

  test('A 定位在途、用户手动查 B、A 先回包 → A 不打开对话框', () async {
    final _Harness h = _Harness();
    h.gate.arm(_a, generation: h.mint());
    h.render('A');
    final Future<void> done = h.gate.onRendered();
    expect(h.locates, hasLength(1));

    // 用户在往返途中手动查了别的词：铸新代即撤销转交。
    h.mint();
    expect(h.gate.pending, isNull);
    h.rendered = null; // B 还在查

    h.locates.single.reply.complete(2); // A 的旧回包（旧 DOM 下标）
    await done;
    expect(h.opened, isEmpty);
    expect(h.notFound, isEmpty);

    // B 画完后也不会再为 A 打开任何东西。
    h.render('B');
    await h.gate.onRendered();
    expect(h.locates, hasLength(1));
    expect(h.opened, isEmpty);
  });

  test('同一转交、同一查词代，但回包前结果已换（WebView 重画了别的结果）→ 不打开', () async {
    final _Harness h = _Harness();
    h.gate.arm(_a, generation: h.mint());
    h.render('A');
    final Future<void> done = h.gate.onRendered();
    h.render('A-rerendered'); // 结果对象换了，旧下标不再对应眼下的 DOM
    h.locates.single.reply.complete(1);
    await done;
    expect(h.opened, isEmpty);
    // 转交仍挂着，下次渲染信号重新定位。
    expect(h.gate.pending, _a);
    final Future<void> again = h.gate.onRendered();
    expect(h.locates, hasLength(2));
    expect(identical(h.locates.last.target, h.rendered), isTrue);
    h.locates.last.reply.complete(4);
    await again;
    expect(h.opened.single.index, 4);
  });

  test('旧转交 A 在途时来了新转交 B 且 B 已画完 → A 回包作废，立刻为 B 定位', () async {
    final _Harness h = _Harness();
    h.gate.arm(_a, generation: h.mint());
    h.render('A');
    final Future<void> doneA = h.gate.onRendered();

    // 新的外部查词请求带着转交 B：撤销 A、铸代、挂上 B，B 的结果在往返途中画完。
    h.gate.revoke();
    h.gate.arm(_b, generation: h.mint());
    h.render('B');
    final Future<void> busy = h.gate.onRendered(); // 撞上 A 的往返，记下待重问
    await busy;
    expect(h.locates, hasLength(1));

    h.locates.first.reply.complete(0); // A 的旧回包
    await Future<void>.delayed(Duration.zero);
    expect(h.opened, isEmpty);
    expect(h.locates, hasLength(2));
    expect(h.locates.last.handoff, _b);
    h.locates.last.reply.complete(5);
    await doneA;
    expect(h.opened.single.handoff, _b);
    expect(h.opened.single.index, 5);
  });

  test('尾批还在画（-2）→ 不打开；往返途中来过渲染信号就立刻再问', () async {
    final _Harness h = _Harness();
    h.gate.arm(_a, generation: h.mint());
    h.render('A');
    final Future<void> done = h.gate.onRendered();
    await h.gate.onRendered(); // 尾批画完的信号撞上往返
    h.locates.single.reply.complete(kPopupEntryIndexStillRendering);
    await Future<void>.delayed(Duration.zero);
    expect(h.locates, hasLength(2));
    h.locates.last.reply.complete(1);
    await done;
    expect(h.opened.single.index, 1);
  });

  test('找不到词条（-1）→ 记一笔、不猜下标、转交结束', () async {
    final _Harness h = _Harness();
    h.gate.arm(_a, generation: h.mint());
    h.render('A');
    final Future<void> done = h.gate.onRendered();
    h.locates.single.reply.complete(-1);
    await done;
    expect(h.opened, isEmpty);
    expect(h.notFound.single, _a);
    expect(h.gate.pending, isNull);
  });

  test('页面 dispose 后在途回包丢弃', () async {
    final _Harness h = _Harness();
    h.gate.arm(_a, generation: h.mint());
    h.render('A');
    final Future<void> done = h.gate.onRendered();
    h.gate.dispose();
    h.locates.single.reply.complete(2);
    await done;
    expect(h.opened, isEmpty);
  });
}
