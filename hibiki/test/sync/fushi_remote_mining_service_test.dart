import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/forwarded_mine_payload.dart';
import 'package:fushi/src/sync/fushi_remote_lookup_service.dart';
import 'package:fushi/src/sync/immersion_mine_payload.dart';

void main() {
  test('FushiRemoteMiningService is an abstract contract with mineEntry', () {
    expect(_FakeMining(), isA<FushiRemoteMiningService>());
  });
}

class _FakeMining implements FushiRemoteMiningService {
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
  Future<RemoteMineResult> mineForwarded(ForwardedMinePayload payload) async =>
      const RemoteMineResult(result: 'success');

  @override
  Future<bool> isDuplicate({
    required String expression,
    required String reading,
  }) async =>
      false;
}
