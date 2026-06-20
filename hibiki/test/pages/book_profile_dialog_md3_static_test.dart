import 'package:flutter_test/flutter_test.dart';
import 'reader_history_source_corpus.dart';

void main() {
  test('book profile dialog owns shared MD3 dialog and sheet chrome', () {
    final String source = readReaderHistorySource();
    final String dialogSource = _between(
      source,
      'class _BookProfileDialog extends StatefulWidget',
      'class BookProfileDialogContent extends StatelessWidget',
    );

    expect(dialogSource, contains('BookProfileDialogFrame('));
    expect(dialogSource, contains('HibikiDialogFrame('));
    expect(dialogSource, contains('HibikiModalSheetFrame('));
    expect(dialogSource, isNot(contains('adaptiveAlertDialog(')));
  });
}

String _between(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  final int endIndex = source.indexOf(end, startIndex);
  expect(startIndex, isNonNegative, reason: 'Missing source marker: $start');
  expect(endIndex, isNonNegative, reason: 'Missing source marker: $end');
  return source.substring(startIndex, endIndex);
}
