import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// TODO-393「查词窗口句子上下文制卡」：弹窗 popup.js 必须暴露「上 N 句 / 下 N 句」上下文
/// 选择器，把当前句前/后 N 句作上下文发给宿主（callHandler('setSentenceContext')），并只
/// 在宿主接受时渲染。这些守卫钉死 JS 资产本身的关键接线，防回归。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late String js;
  late String css;

  setUpAll(() async {
    js = await rootBundle.loadString('assets/popup/popup.js');
    css = await rootBundle.loadString('assets/popup/popup.css');
  });

  test('context picker fires the generic setSentenceContext handler', () {
    expect(js, contains("'setSentenceContext'"));
    expect(js, contains('sentence-context-picker'));
    expect(js, contains('buildSentenceContextPicker('));
    expect(js, contains('setSentenceContextOnHost('));
  });

  test('picker is gated on the host-supplied sentenceDraftEnabled flag', () {
    expect(js, contains('window.sentenceDraftEnabled'));
  });

  test('context is two mirrored scalars, not free accumulation', () {
    // 上/下 各一个标量，再点覆盖（非累加）。
    expect(js, contains('let sentenceCtxPrev = 0;'));
    expect(js, contains('let sentenceCtxNext = 0;'));
  });

  test('mining never carries an extra sentence field — context signal only',
      () {
    // The context entry must NOT reuse mineEntry/updateEntry field contracts; it
    // only sends the generic setSentenceContext signal. Exactly one mineEntry
    // callHandler and one updateEntry callHandler remain.
    expect("callHandler('mineEntry'".allMatches(js).length, 1);
    expect("callHandler('updateEntry'".allMatches(js).length, 1);
  });

  test('a successful mine resets the JS context mirror scalars', () {
    // Host clears the draft on a successful mine → popup.js must zero its mirror
    // scalars so the picker selection clears at the same event (no drift).
    expect(js, contains('sentenceCtxPrev = 0;'));
    expect(js, contains('sentenceCtxNext = 0;'));
  });

  test('css styles the context picker and its selected step', () {
    expect(css, contains('.sentence-context-picker'));
    expect(css, contains('.context-step'));
    expect(css, contains('.sentence-context-picker .context-step.selected'));
  });
}
