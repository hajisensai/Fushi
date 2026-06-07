import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/texthooker_service.dart';

void main() {
  setUp(() => TexthookerService.instance.clear());

  test('appendLine adds and notifies', () {
    int notifications = 0;
    void listener() => notifications++;
    TexthookerService.instance.addListener(listener);

    TexthookerService.instance.appendLine('一行目');
    TexthookerService.instance.appendLine('二行目');

    expect(TexthookerService.instance.lines, ['一行目', '二行目']);
    expect(notifications, 2);
    TexthookerService.instance.removeListener(listener);
  });

  test('blank lines are ignored', () {
    TexthookerService.instance.appendLine('   ');
    TexthookerService.instance.appendLine('');
    expect(TexthookerService.instance.lines, isEmpty);
  });

  test('buffer caps at maxLines, dropping oldest', () {
    for (int i = 0; i < TexthookerService.maxLines + 10; i++) {
      TexthookerService.instance.appendLine('line $i');
    }
    expect(TexthookerService.instance.lines.length, TexthookerService.maxLines);
    expect(TexthookerService.instance.lines.first, 'line 10');
  });

  test('clear empties and notifies', () {
    TexthookerService.instance.appendLine('x');
    int notifications = 0;
    TexthookerService.instance.addListener(() => notifications++);
    TexthookerService.instance.clear();
    expect(TexthookerService.instance.lines, isEmpty);
    expect(notifications, 1);
  });
}
