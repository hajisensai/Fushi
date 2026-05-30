import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The dictionary popup's selection.js must expose selectFromPosition (extracted
/// from selectText) so the char caret injected into the popup WebView can drive
/// the same deeper-lookup pipeline as a tap. These guard the asset itself.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late String js;

  setUpAll(() async {
    js = await rootBundle.loadString('assets/popup/selection.js');
  });

  test('defines selectFromPosition and keeps selectText delegating to it', () {
    expect(js, contains('selectFromPosition('));
    expect(js, contains('selectText('));
    expect(
      js,
      contains('return this.selectFromPosition(hit.node, hit.offset'),
    );
  });

  test('fires textSelected from a single place (the shared core)', () {
    final int emitters = "callHandler('textSelected'".allMatches(js).length;
    expect(emitters, 1,
        reason: 'textSelected should only be emitted by selectFromPosition');
  });

  test('still exposes the methods the caret depends on', () {
    expect(js, contains('window.hoshiSelection'));
    expect(js, contains('createWalker'));
    expect(js, contains('clearSelection'));
  });
}
