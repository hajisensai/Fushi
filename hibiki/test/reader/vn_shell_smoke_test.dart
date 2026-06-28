import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_visual_novel_scripts.dart';
import 'package:hibiki/src/reader/reader_pagination_scripts.dart';

void main() {
  test('VN shell builds and contains the object + restore + deps', () {
    final String shell = ReaderVisualNovelScripts.vnShellScript(
      initialCharOffset: 1234,
      revealSpeed: 45,
      screenMode: 'block',
    );
    expect(shell.contains('<script>'), isTrue);
    expect(shell.contains('window.hoshiReader = {'), isTrue);
    expect(shell.contains('global.hoshiReaderTextSemantics'), isTrue);
    expect(shell.contains('global.hoshiReaderVnContentStream'), isTrue);
    expect(shell.contains('global.hoshiReaderVnRangeMap'), isTrue);
    expect(shell.contains('global.hoshiReaderMediaSemantics'), isTrue);
    expect(shell.contains('restoreToCharOffset(1234)'), isTrue);
    expect(shell.contains('revealSpeed: 45'), isTrue);
    expect(shell.contains("screenMode: 'block'"), isTrue);
    expect(shell.contains("callHandler('onRestoreComplete')"), isTrue);
    // dispatch via shellScript(vnMode:true) reaches the VN shell.
    final String viaShell = ReaderPaginationScripts.shellScript(
      vnMode: true,
      initialCharOffset: 7,
      vnRevealSpeed: 45,
    );
    expect(viaShell.contains('window.hoshiReader = {'), isTrue);
    expect(viaShell.contains('restoreToCharOffset(7)'), isTrue);
  });
}
