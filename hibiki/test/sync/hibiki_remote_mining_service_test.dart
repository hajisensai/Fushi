import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/hibiki_remote_lookup_service.dart';
import 'package:hibiki/src/sync/immersion_mine_payload.dart';

void main() {
  test('HibikiRemoteMiningService is an abstract contract with mineEntry', () {
    expect(_FakeMining(), isA<HibikiRemoteMiningService>());
  });
}

class _FakeMining implements HibikiRemoteMiningService {
  @override
  Future<RemoteMineResult> mineEntry({
    required Map<String, String> fields,
    required String sentence,
  }) async =>
      const RemoteMineResult(result: 'success');

  @override
  Future<RemoteMineResult> mineImmersion(ImmersionMinePayload payload) async =>
      const RemoteMineResult(result: 'success');

  @override
  Future<bool> isDuplicate({
    required String expression,
    required String reading,
  }) async =>
      false;
}
