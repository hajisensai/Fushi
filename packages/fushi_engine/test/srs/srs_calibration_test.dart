// 校准图 / UM+ 的纯 Dart 部分：JSON 解码、可见箱筛选、坐标范围、加权斜率。
// 分箱、自助法区间与留出预测在 native/fushi_fsrs（calibration.rs），由真实库探针
// （srs_calibration_probe_test.dart）覆盖；这里只测不依赖原生库的那一层。
import 'package:fushi_engine/srs/srs_calibration.dart';
import 'package:test/test.dart';

SrsUmPlusBin _umBin({
  required int index,
  required int count,
  required double disagreement,
  required double fsrsError,
  required double rwkvError,
}) => SrsUmPlusBin(
  index: index,
  count: count,
  disagreement: disagreement,
  fsrsError: fsrsError,
  rwkvError: rwkvError,
);

Map<String, Object?> _umJson(List<Map<String, Object?>> bins) => <String, Object?>{
  'count': bins.fold<int>(
    0,
    (int s, Map<String, Object?> b) => s + (b['count']! as int),
  ),
  'fsrsScore': 0.1,
  'rwkvScore': 0.05,
  'bins': bins,
};

void main() {
  group('SrsCalibrationSeries.fromJson', () {
    test('按位置补箱序，区间缺了就是 null', () {
      final SrsCalibrationSeries? s = SrsCalibrationSeries.fromJson(<String, Object?>{
        'count': 12,
        'logLoss': 0.51,
        'rmse': 0.052,
        'bins': <Object?>[
          <String, Object?>{
            'count': 3,
            'predicted': 0.2,
            'actual': 0.5,
            'lower': 0.1,
            'upper': 0.8,
          },
          <String, Object?>{'count': 9, 'predicted': 0.7, 'actual': 0.6},
        ],
      });
      expect(s, isNotNull);
      expect(s!.count, 12);
      expect(s.bins, hasLength(2));
      expect(s.bins[0].index, 0);
      expect(s.bins[0].lower, 0.1);
      expect(s.bins[0].upper, 0.8);
      expect(s.bins[1].index, 1);
      expect(s.bins[1].lower, isNull);
      expect(s.bins[1].upper, isNull);
      expect(s.bins[1].count, 9);
    });

    test('不是映射（没有这一侧）→ null', () {
      expect(SrsCalibrationSeries.fromJson(null), isNull);
      expect(SrsCalibrationSeries.fromJson(<Object?>[]), isNull);
    });
  });

  group('SrsCalibrationReport.fromJson', () {
    test('两侧都空：eligible 仍按 json，series 都是 null', () {
      final SrsCalibrationReport r = SrsCalibrationReport.fromJson(
        <String, Object?>{'eligible': 7},
        hasRwkv: false,
      );
      expect(r.eligible, 7);
      expect(r.hasRwkv, isFalse);
      expect(r.fsrs, isNull);
      expect(r.rwkv, isNull);
      expect(r.umPlus, isNull);
    });

    test('带 RWKV 时两侧都解出来', () {
      final Map<String, Object?> side = <String, Object?>{
        'count': 4,
        'logLoss': 0.4,
        'rmse': 0.03,
        'bins': <Object?>[
          <String, Object?>{
            'count': 4,
            'predicted': 0.5,
            'actual': 0.5,
            'lower': 0.3,
            'upper': 0.7,
          },
        ],
      };
      final SrsCalibrationReport r = SrsCalibrationReport.fromJson(
        <String, Object?>{'eligible': 9, 'fsrs': side, 'rwkv': side},
        hasRwkv: true,
      );
      expect(r.hasRwkv, isTrue);
      expect(r.fsrs!.count, 4);
      expect(r.rwkv!.bins.single.upper, 0.7);
    });
  });

  group('SrsUmPlus.visibleBins', () {
    final SrsUmPlus um = SrsUmPlus.fromJson(
      _umJson(<Map<String, Object?>>[
        <String, Object?>{
          'index': 0,
          'count': 199,
          'disagreement': -0.3,
          'fsrsError': 0.2,
          'rwkvError': -0.1,
        },
        <String, Object?>{
          'index': 1,
          'count': 200,
          'disagreement': 0.0,
          'fsrsError': 0.15,
          'rwkvError': -0.05,
        },
        <String, Object?>{
          'index': 2,
          'count': 401,
          'disagreement': 0.4,
          'fsrsError': 0.05,
          'rwkvError': 0.01,
        },
      ]),
    )!;

    test('默认藏掉少于 200 条的箱', () {
      expect(
        um.visibleBins(showSmall: false).map((SrsUmPlusBin b) => b.index),
        <int>[1, 2],
      );
    });

    test('打开后全给（199 也画）', () {
      expect(um.visibleBins(showSmall: true), hasLength(3));
    });

    test('count 是全部箱的总数，不受可见性影响', () {
      expect(um.count, 800);
      expect(um.fsrsScore, 0.1);
      expect(um.rwkvScore, 0.05);
    });
  });

  group('坐标范围', () {
    test('没有箱时给兜底区间', () {
      expect(srsUmPlusDisagreementDomain(<SrsUmPlusBin>[]), (-1.0, 1.0));
      expect(srsUmPlusErrorDomain(<SrsUmPlusBin>[]), (-0.1, 0.1));
    });

    test('分歧向外取整到 0.1', () {
      final (double lo, double hi) = srsUmPlusDisagreementDomain(<SrsUmPlusBin>[
        _umBin(index: 0, count: 5, disagreement: 0.05, fsrsError: 0, rwkvError: 0),
        _umBin(index: 1, count: 5, disagreement: 0.35, fsrsError: 0, rwkvError: 0),
      ]);
      expect(lo, closeTo(0.0, 1e-9));
      expect(hi, closeTo(0.4, 1e-9));
    });

    test('误差轴恒含 0，且 0 贴边时向外留一格', () {
      final (double lo, double hi) = srsUmPlusErrorDomain(<SrsUmPlusBin>[
        _umBin(index: 0, count: 5, disagreement: 0, fsrsError: 0.22, rwkvError: 0.0),
      ]);
      expect(lo, closeTo(-0.1, 1e-9));
      expect(hi, closeTo(0.3, 1e-9));
    });
  });

  group('srsUmPlusSlope', () {
    test('按条数加权，线性关系斜率就是系数', () {
      final List<SrsUmPlusBin> bins = <SrsUmPlusBin>[
        _umBin(index: 0, count: 10, disagreement: -0.2, fsrsError: 0.6, rwkvError: 0),
        _umBin(index: 1, count: 30, disagreement: 0.0, fsrsError: 1.0, rwkvError: 0),
        _umBin(index: 2, count: 20, disagreement: 0.3, fsrsError: 1.6, rwkvError: 0),
      ];
      expect(
        srsUmPlusSlope(bins, (SrsUmPlusBin b) => b.fsrsError),
        closeTo(2, 1e-9),
      );
    });

    test('分歧几乎没有变化 / 没有条数 → null', () {
      expect(
        srsUmPlusSlope(<SrsUmPlusBin>[
          _umBin(index: 0, count: 5, disagreement: 0.1, fsrsError: 0.1, rwkvError: 0),
          _umBin(index: 1, count: 5, disagreement: 0.1, fsrsError: 0.2, rwkvError: 0),
        ], (SrsUmPlusBin b) => b.fsrsError),
        isNull,
      );
      expect(srsUmPlusSlope(<SrsUmPlusBin>[], (SrsUmPlusBin b) => b.fsrsError), isNull);
    });
  });
}
