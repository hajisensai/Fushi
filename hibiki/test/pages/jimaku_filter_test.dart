import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/jimaku_subtitle_dialog.dart';

void main() {
  test('empty keyword keeps all', () {
    final List<String> names = <String>['a.WEBRip.srt', 'b.BD.ass'];
    expect(filterByKeyword(names, '', (String s) => s), names);
  });

  test('case-insensitive substring match', () {
    final List<String> names = <String>['a.WEBRip.srt', 'b.BD.ass', 'c.srt'];
    final List<String> out = filterByKeyword(names, 'webrip', (String s) => s);
    expect(out, <String>['a.WEBRip.srt']);
  });

  test('whitespace-only keyword keeps all', () {
    final List<String> names = <String>['x', 'y'];
    expect(filterByKeyword(names, '   ', (String s) => s), names);
  });
}
