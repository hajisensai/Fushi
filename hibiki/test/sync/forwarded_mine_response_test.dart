import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/sync/forwarded_mine_payload.dart';
import 'package:fushi/src/sync/hibiki_remote_api_handlers.dart';
import 'package:fushi/src/sync/hibiki_remote_lookup_service.dart';
import 'package:fushi/src/sync/immersion_mine_payload.dart';

/// 假挖词 service：捕获转发来的 payload，回预设结果。
class _FakeMining implements FushiRemoteMiningService {
  ForwardedMinePayload? forwarded;
  RemoteMineResult result =
      const RemoteMineResult(result: 'success', message: 'ok');

  @override
  Future<RemoteMineResult> mineForwarded(ForwardedMinePayload payload) async {
    forwarded = payload;
    return result;
  }

  @override
  Future<RemoteMineResult> mineEntry(
          {required Map<String, String> fields,
          required String sentence}) async =>
      const RemoteMineResult(result: 'success');

  @override
  Future<RemoteMineResult> mineImmersion(ImmersionMinePayload payload) async =>
      const RemoteMineResult(result: 'success');

  @override
  Future<bool> isDuplicate(
          {required String expression, required String reading}) async =>
      false;
}

void main() {
  group('buildForwardedMineResponse', () {
    test('解析 body → 调 mineForwarded → 摊平 {result,message?,detail?}', () async {
      final _FakeMining m = _FakeMining();
      final Map<String, dynamic> resp = await buildForwardedMineResponse(
        <String, dynamic>{
          'rawPayloadJson': '{"expression":"猫"}',
          'sentence': '猫がいる',
        },
        mining: m,
      );
      expect(m.forwarded!.rawPayloadJson, '{"expression":"猫"}');
      expect(m.forwarded!.sentence, '猫がいる');
      expect(resp['result'], 'success');
      expect(resp['message'], 'ok');
      expect(resp.containsKey('detail'), isFalse);
    });

    test('rawPayloadJson 缺失 → FormatException（调用方转 400）', () {
      expect(
        () => buildForwardedMineResponse(
            <String, dynamic>{'sentence': 'x'}, mining: _FakeMining()),
        throwsFormatException,
      );
    });
  });
}
