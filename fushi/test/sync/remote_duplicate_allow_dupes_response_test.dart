import 'package:test/test.dart';
import 'package:fushi_engine/sync/fushi_remote_api_handlers.dart';
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart';

/// 反馈 E0sdqm4h-F / PR #2980 审查：浏览器扩展单击已制卡 ✓ 要与 app 内同一判据（「允许
/// 重复」开着就直接再制一张）。扩展拿不到 app 的设置，只能从 `POST /api/duplicate` 的
/// `allowDuplicates` 位读——service 实现 [FushiRemoteDuplicatePolicyService] 时必须带上，
/// 不实现（无头服务端 / 旧实现）时不带，扩展照旧弹「新增为重复卡 / 取消」。
class _Mining implements FushiRemoteMiningService {
  @override
  Future<bool> isDuplicate({
    required String expression,
    required String reading,
  }) async => true;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      fail('unexpected call: ${invocation.memberName}');
}

class _PolicyMining extends _Mining
    implements FushiRemoteDuplicatePolicyService {
  _PolicyMining(this.allow);

  final bool allow;

  @override
  Future<bool> allowsDuplicates() async => allow;
}

void main() {
  test('policy service：回包带 allowDuplicates（开 / 关都如实）', () async {
    for (final bool allow in <bool>[true, false]) {
      final Map<String, dynamic> body = await buildRemoteDuplicateResponse(
        <String, dynamic>{'expression': '刀', 'reading': 'かたな'},
        mining: _PolicyMining(allow),
      );
      expect(body, <String, dynamic>{
        'duplicate': true,
        'allowDuplicates': allow,
      });
    }
  });

  test('不支持策略的 service：不带 allowDuplicates（扩展照旧问）', () async {
    final Map<String, dynamic> body = await buildRemoteDuplicateResponse(
      <String, dynamic>{'expression': '刀', 'reading': 'かたな'},
      mining: _Mining(),
    );
    expect(body, <String, dynamic>{'duplicate': true});
  });
}
