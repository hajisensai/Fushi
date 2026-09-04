import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/selection_capture_ffi.dart';

/// TODO-1066 — 剪贴板选区捕获的串行闸门。
///
/// 为什么必须有这道闸门：`captureForegroundSelection` 的「存旧剪贴板 → 清空 →
/// 注入 Ctrl+C → 轮询最长 600ms → 还原」是一段跨 await 的事务，而剪贴板是全局
/// 单资源。两次重叠会互相拆台，最终把用户的剪贴板"还原"成空（同源事故见
/// BUG-707）。键盘热键不容易连按到暴露它，手柄按钮和鼠标侧键会。
///
/// 这里测的是闸门本身（`debugRunClipboardExclusive`），不是真捕获——真捕获会
/// 注入 Ctrl+C 并改写跑测试这台机器的剪贴板，测试里绝不能调。
void main() {
  test('重叠调用被串行化：后到的事务不与前一笔交错', () async {
    final List<String> log = <String>[];

    Future<String?> transaction(String name, Duration hold) async {
      log.add('$name:begin');
      await Future<void>.delayed(hold);
      log.add('$name:end');
      return name;
    }

    // A 故意跑得比 B 久：没有闸门的话 B 会在 A 的 await 里插进来，
    // 日志就会出现 a:begin, b:begin, b:end, a:end 的交错。
    final Future<String?> a = SelectionCapture.debugRunClipboardExclusive(
      () => transaction('a', const Duration(milliseconds: 40)),
    );
    final Future<String?> b = SelectionCapture.debugRunClipboardExclusive(
      () => transaction('b', const Duration(milliseconds: 1)),
    );

    expect(await a, 'a');
    expect(await b, 'b');
    expect(log, <String>['a:begin', 'a:end', 'b:begin', 'b:end']);
  });

  test('排队期间被取代 → 事务体一次都不执行', () async {
    bool bodyRan = false;
    bool wanted = true;

    final Future<String?> first = SelectionCapture.debugRunClipboardExclusive(
      () async {
        // 前一笔还在跑时，上游铸了新 route —— 后一笔就此作废。
        wanted = false;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return 'first';
      },
    );
    final Future<String?> superseded =
        SelectionCapture.debugRunClipboardExclusive<String>(
      () async {
        bodyRan = true;
        return 'superseded';
      },
      stillWanted: () => wanted,
    );

    expect(await first, 'first');
    expect(await superseded, isNull);
    expect(
      bodyRan,
      isFalse,
      reason: '已被取代的那次不该再去动剪贴板——结果反正会被上游丢弃',
    );
  });

  test('事务体抛异常也放行后来者（一次失败不得永久堵死这条路）', () async {
    final Future<String?> boom = SelectionCapture.debugRunClipboardExclusive(
      () async => throw StateError('clipboard busy'),
    );
    await expectLater(boom, throwsStateError);

    // 闸门必须已经推进：否则下面这笔会永远挂着。
    final String? after = await SelectionCapture.debugRunClipboardExclusive(
      () async => 'after',
    ).timeout(const Duration(seconds: 2));
    expect(after, 'after');
  });
}
