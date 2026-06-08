import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';

void main() {
  group('computeDictionarySyncDiff', () {
    test('union by name: pull remote-only, push local-only, skip shared', () {
      final DictionarySyncDiff diff = computeDictionarySyncDiff(
        localNames: <String>{'JMdict', '明镜'},
        remoteNames: <String>{'明镜', 'NHK'},
      );
      expect(diff.toPull, <String>{'NHK'});
      expect(diff.toPush, <String>{'JMdict'});
    });

    test('empty both sides -> empty diff', () {
      final DictionarySyncDiff diff = computeDictionarySyncDiff(
        localNames: <String>{},
        remoteNames: <String>{},
      );
      expect(diff.toPull, isEmpty);
      expect(diff.toPush, isEmpty);
    });
  });
}
