// 打包训练集（ffsrs_fit，前缀在原生侧展开）与旧实现（每条复习一份历史前缀、JSON 过 FFI）的回归对拍
// （BUG-3703）。
//
// test/fixtures/fsrs_training_regression_vectors.json 是旧实现（develop 329a739431）在一份固定合成数据
// 上的输出：300 张卡、2137 条按评分时刻交错排序的训练条目，带每张卡的数字 ID。这里用新路径在同一份输入上
// 重算，参数与各项评估都要在容差内一致——覆盖训练权重（fsrs-rs 按条目顺序给近期权重）、全局时序、card ID
// （带 / 不带 ID 两组参数本来就不同）与时间序列切分评估这几项口径。
//
// 原生库是硬依赖：加载失败直接判红，不 skip。
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi_srs/src/algorithm.dart';
import 'package:fushi_srs/src/ffi/ffi_fsrs_engine.dart';
import 'package:fushi_srs/src/fsrs_engine.dart';
import 'package:test/test.dart';

/// 旧路径把小数天经 JSON 解析成 f32，新路径直接存 Float32List，两者对 f64 输入的舍入相同，
/// 输入逐位一致；容差只给 fsrs-rs 内部浮点求和顺序留余量。
const double _tolerance = 1e-5;

Map<String, Object?> _fixture() =>
    jsonDecode(
          File(
            'test/fixtures/fsrs_training_regression_vectors.json',
          ).readAsStringSync(),
        )
        as Map<String, Object?>;

SrsFsrsTrainingSet _trainingSet(
  Map<String, Object?> fixture, {
  required bool withCardIds,
}) {
  final SrsFsrsTrainingSetBuilder builder = SrsFsrsTrainingSetBuilder();
  for (final Object? c in fixture['cards']! as List<Object?>) {
    final Map<String, Object?> card = c! as Map<String, Object?>;
    final List<Object?> ratings = card['ratings']! as List<Object?>;
    final List<Object?> deltas = card['deltas']! as List<Object?>;
    builder.addCard(<SrsFsrsReview>[
      for (int i = 0; i < ratings.length; i++)
        SrsFsrsReview(
          rating: ratings[i]! as int,
          deltaDays: (deltas[i]! as num).toDouble(),
        ),
    ], cardId: withCardIds ? card['id']! as int : null);
  }
  for (final Object? item in fixture['items']! as List<Object?>) {
    final List<Object?> pair = item! as List<Object?>;
    builder.addItem(pair[0]! as int, pair[1]! as int);
  }
  return builder.build();
}

Matcher _closeToList(List<Object?> expected) => pairwiseCompare(
  <double>[for (final Object? v in expected) (v! as num).toDouble()],
  (double e, double a) => (a - e).abs() <= _tolerance * (1 + e.abs()),
  'within $_tolerance of',
);

void _expectEvaluation(SrsEvaluation actual, Object? expected, String what) {
  final Map<String, Object?> e = expected! as Map<String, Object?>;
  expect(
    actual.logLoss,
    closeTo((e['logLoss']! as num).toDouble(), _tolerance),
    reason: '$what logLoss',
  );
  expect(
    actual.rmseBins,
    closeTo((e['rmseBins']! as num).toDouble(), _tolerance),
    reason: '$what rmseBins',
  );
}

void main() {
  final FfiFsrsEngine? engine = FfiFsrsEngine.tryCreate();
  final Map<String, Object?> fixture = _fixture();
  final Map<String, Object?> results =
      fixture['results']! as Map<String, Object?>;

  test('native fushi_fsrs library is available', () {
    expect(engine, isNotNull, reason: 'native library not found');
  });

  test('builder keeps one history per card and expands prefixes on demand', () {
    final SrsFsrsTrainingSet set = _trainingSet(fixture, withCardIds: true);
    final List<Object?> cards = fixture['cards']! as List<Object?>;
    final List<Object?> items = fixture['items']! as List<Object?>;
    expect(set.cardCount, cards.length);
    expect(set.length, items.length);
    // 每张卡只存一份完整历史：评分总数 = 各卡评分数之和，而不是各条前缀长度之和。
    int reviews = 0;
    int prefixReviews = 0;
    for (final Object? c in cards) {
      reviews +=
          ((c! as Map<String, Object?>)['ratings']! as List<Object?>).length;
    }
    for (final Object? i in items) {
      prefixReviews += (i! as List<Object?>)[1]! as int;
    }
    expect(set.ratings, hasLength(reviews));
    expect(prefixReviews, greaterThan(reviews * 3));
    // 展开的第 i 条 = 卡的前 n 次评分，评分与小数天都按原值。
    final List<Object?> first = items.first! as List<Object?>;
    final Map<String, Object?> card =
        cards[first[0]! as int]! as Map<String, Object?>;
    final List<SrsFsrsReview> expanded = set.item(0);
    expect(expanded, hasLength(first[1]! as int));
    for (int k = 0; k < expanded.length; k++) {
      expect(expanded[k].rating, (card['ratings']! as List<Object?>)[k]);
      expect(
        expanded[k].deltaDays,
        closeTo(
          ((card['deltas']! as List<Object?>)[k]! as num).toDouble(),
          1e-6,
        ),
      );
    }
  });

  test('builder rejects prefixes longer than the card history', () {
    final SrsFsrsTrainingSetBuilder b = SrsFsrsTrainingSetBuilder();
    final int card = b.addCard(const <SrsFsrsReview>[
      SrsFsrsReview(rating: 3, deltaDays: 0),
      SrsFsrsReview(rating: 3, deltaDays: 2),
    ]);
    expect(() => b.addItem(card, 3), throwsRangeError);
    expect(() => b.addItem(card, 0), throwsRangeError);
    expect(() => b.addItem(card + 1, 1), throwsRangeError);
    expect(
      () => b.addCard(const <SrsFsrsReview>[], cardId: 5),
      throwsArgumentError,
    );
  });

  for (final SrsAlgorithm a in <SrsAlgorithm>[
    SrsAlgorithm.fsrs6,
    SrsAlgorithm.fsrs7,
  ]) {
    group('matches the old prefix-JSON implementation (${a.wire})', () {
      final Map<String, Object?> expected =
          results[a.wire]! as Map<String, Object?>;
      final SrsFsrsTrainingSet withIds = _trainingSet(
        fixture,
        withCardIds: true,
      );

      test('computeParameters with card ids', () {
        final List<double> params = engine!.computeParameters(
          algorithm: a,
          items: withIds,
        );
        expect(params, _closeToList(expected['params']! as List<Object?>));
      }, timeout: const Timeout(Duration(minutes: 5)));

      test('computeParameters without card ids', () {
        final List<double> params = engine!.computeParameters(
          algorithm: a,
          items: _trainingSet(fixture, withCardIds: false),
        );
        expect(
          params,
          _closeToList(expected['paramsWithoutCardIds']! as List<Object?>),
        );
      }, timeout: const Timeout(Duration(minutes: 5)));

      test('evaluate (default and fitted params)', () {
        _expectEvaluation(
          engine!.evaluate(
            algorithm: a,
            params: const <double>[],
            items: withIds,
          ),
          expected['evaluateDefault'],
          'default',
        );
        final List<double> fitted = <double>[
          for (final Object? v in expected['params']! as List<Object?>)
            (v! as num).toDouble(),
        ];
        _expectEvaluation(
          engine.evaluate(algorithm: a, params: fitted, items: withIds),
          expected['evaluateFresh'],
          'fitted',
        );
      }, timeout: const Timeout(Duration(minutes: 5)));

      test('evaluateTimeSeries', () {
        _expectEvaluation(
          engine!.evaluateTimeSeries(algorithm: a, items: withIds),
          expected['evaluateTimeSeries'],
          'time series',
        );
      }, timeout: const Timeout(Duration(minutes: 5)));
    });
  }
}
