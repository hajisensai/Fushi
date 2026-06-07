import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/hibiki_remote_lookup_service.dart';

void main() {
  test('HibikiRemoteMiningService is an abstract contract with mineEntry', () {
    expect(_FakeMining(), isA<HibikiRemoteMiningService>());
  });
}

class _FakeMining implements HibikiRemoteMiningService {
  @override
  Future<String> mineEntry({
    required Map<String, String> fields,
    required String sentence,
  }) async =>
      'success';
}
