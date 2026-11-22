import 'package:fushi_engine/sync/aggregate_snapshot.dart';
import 'package:fushi_engine/sync/aggregate_wire_codec.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';

/// 测试便利：host 服务的聚合端点按**快照**读写（生产接口只搬报文体字节，
/// HBK-AUDIT-028）。走的仍是真实的 [FushiLibraryHostService.getAggregateBody] /
/// [FushiLibraryHostService.applyAggregateBody]，只在测试这一侧编解码。
extension AggregateHostWireTestExt on FushiLibraryHostService {
  Future<AggregateSnapshot> getAggregateSnapshot() async =>
      decodeAggregateWireSnapshot(await getAggregateBody())!;

  Future<void> applyAggregateSnapshot(AggregateSnapshot snapshot) async {
    final bool accepted = await applyAggregateBody(
      encodeAggregateWireJson(snapshot.toJson()),
    );
    if (!accepted) throw StateError('host rejected a valid aggregate body');
  }
}
