import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// TODO-270 F/G「查词窗口多句合一制卡」(乙方案)：弹窗 popup.js 必须暴露「+句」入口，
/// 把当前句累积进宿主草稿（callHandler('appendSentence')），并只在宿主接受时渲染。
/// 这些守卫钉死 JS 资产本身的关键接线，防回归。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late String js;
  late String css;

  setUpAll(() async {
    js = await rootBundle.loadString('assets/popup/popup.js');
    css = await rootBundle.loadString('assets/popup/popup.css');
  });

  test('append-sentence button fires the generic appendSentence handler', () {
    expect(js, contains("callHandler('appendSentence')"));
    expect(js, contains('append-sentence-button'));
    expect(js, contains('appendSentenceToDraft('));
  });

  test('append button is gated on the host-supplied sentenceDraftEnabled flag',
      () {
    expect(js, contains('window.sentenceDraftEnabled'));
  });

  test('mining never carries an extra sentence field — append signal only', () {
    // The append entry must NOT reuse mineEntry/updateEntry field contracts; it
    // only sends the generic append signal. Exactly one mineEntry callHandler
    // and one updateEntry callHandler remain (the existing mine/overwrite path).
    expect("callHandler('mineEntry'".allMatches(js).length, 1);
    expect("callHandler('updateEntry'".allMatches(js).length, 1);
  });

  test('a successful mine resets the JS draft mirror count', () {
    // Host clears the draft on a successful mine → popup.js must zero its mirror
    // count so the "+句" badge disappears at the same event (no drift).
    expect(js, contains('sentenceDraftCount = 0'));
  });

  test('css styles the append button and its draft badge', () {
    expect(css, contains('.append-sentence-button'));
    expect(css, contains('.append-count'));
    expect(css, contains('.append-sentence-button.has-draft'));
  });
}
