// 真实数据探针：在一份 srs.db 副本上算校准图 + UM+，结果写成 JSON。只在设了 FUSHI_CAL_DB 时运行。
//
//   FUSHI_CAL_DB=<srs.db 副本> FUSHI_CAL_PROFILE=<profile uid> FUSHI_CAL_RWKV=<含 sm56 权重的目录>
//   FUSHI_CAL_OUT=<输出 json> dart test test/srs/srs_calibration_probe_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/srs/srs_calibration.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_rwkv_models.dart';
import 'package:fushi_engine/srs/srs_rwkv_service.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

void main() {
  final Map<String, String> env = Platform.environment;
  final String? dbPath = env['FUSHI_CAL_DB'];
  test(
    'calibration probe on a real srs.db copy',
    () async {
      final SrsStorage storage = await SrsStorage.open(
        path: dbPath!,
        inline: true,
      );
      final FfiFsrsEngine engine = FfiFsrsEngine.tryCreate()!;
      final SrsDbStore store = await SrsDbStore.open(
        db: storage.db,
        core: storage.core,
        profileUid: env['FUSHI_CAL_PROFILE']!,
        deviceId: 'calibration-probe',
        engine: engine,
      );
      final String? rwkvDir = env['FUSHI_CAL_RWKV'];
      final SrsRwkvService? rwkv = rwkvDir == null
          ? null
          : SrsRwkvService(
              store: store,
              models: SrsRwkvModels(dir: Directory(rwkvDir)),
              snapshotDir: Directory.systemTemp.createTempSync('cal_snap_'),
            );
      final Stopwatch sw = Stopwatch()..start();
      final SrsCalibrationData data = await srsCalibrationData(
        store,
        rwkv: rwkv,
        fsrsLibraryPath: srsFsrsLibraryPath(),
        onProgress: (SrsCalibrationPhase p, int done, int total) {},
      );
      final int prepMs = sw.elapsedMilliseconds;
      final SrsCalibrationReport r = srsCalibrationReport(engine, data);
      Map<String, Object?> series(SrsCalibrationSeries? s) => s == null
          ? <String, Object?>{}
          : <String, Object?>{
              'count': s.count,
              'logLoss': s.logLoss,
              'rmse': s.rmse,
              'bins': <Object?>[
                for (final SrsCalibrationBin b in s.bins)
                  <String, Object?>{
                    'index': b.index,
                    'count': b.count,
                    'predicted': b.predicted,
                    'actual': b.actual,
                    'lower': b.lower,
                    'upper': b.upper,
                  },
              ],
            };
      final SrsUmPlus? um = r.umPlus;
      final Map<String, Object?> out = <String, Object?>{
        'items': data.length,
        'fsrsPredicted': data.fsrs.where((double v) => !v.isNaN).length,
        'rwkvRows': data.rwkvTags.length,
        'prepMs': prepMs,
        'eligible': r.eligible,
        'fsrs': series(r.fsrs),
        'rwkv': series(r.rwkv),
        'umPlus': um == null
            ? null
            : <String, Object?>{
                'count': um.count,
                'fsrsScore': um.fsrsScore,
                'rwkvScore': um.rwkvScore,
                'fsrsSlope': srsUmPlusSlope(
                  um.bins,
                  (SrsUmPlusBin b) => b.fsrsError,
                ),
                'rwkvSlope': srsUmPlusSlope(
                  um.bins,
                  (SrsUmPlusBin b) => b.rwkvError,
                ),
                'bins': <Object?>[
                  for (final SrsUmPlusBin b in um.bins)
                    <String, Object?>{
                      'index': b.index,
                      'count': b.count,
                      'disagreement': b.disagreement,
                      'fsrsError': b.fsrsError,
                      'rwkvError': b.rwkvError,
                    },
                ],
              },
      };
      File(
        env['FUSHI_CAL_OUT']!,
      ).writeAsStringSync(const JsonEncoder.withIndent(' ').convert(out));
      await storage.close();
    },
    skip: dbPath == null ? 'FUSHI_CAL_DB not set' : false,
    timeout: const Timeout(Duration(minutes: 30)),
  );
}
