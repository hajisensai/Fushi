import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';

/// 测试里的「设备间同步」：每台设备依次对同一个位置跑 [rounds] 轮同步 v2（设计 §6.2）。
Future<void> srsSyncPeers(
  List<SrsDbStore> stores,
  SrsLocationStore location, {
  int rounds = 2,
  int Function()? nowMs,
  String locationId = 'test',
}) async {
  for (int r = 0; r < rounds; r++) {
    for (final SrsDbStore s in stores) {
      await srsSync2Round(
        host: s,
        location: location,
        locationId: locationId,
        nowMs: nowMs ?? () => s.now().$1,
      );
    }
  }
}

/// 一台设备对 [location] 跑一轮同步 v2。
Future<SrsSync2Report> srsSyncOnce(SrsDbStore s, SrsLocationStore location) =>
    srsSync2Round(
      host: s,
      location: location,
      locationId: 'test',
      nowMs: () => s.now().$1,
    );
