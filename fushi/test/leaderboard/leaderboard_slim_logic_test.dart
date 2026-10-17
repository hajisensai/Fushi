import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/leaderboard/leaderboard_features.dart';
import 'package:fushi/src/leaderboard/leaderboard_reference_works.dart';
import 'package:fushi/src/leaderboard/leaderboard_reference_works_data.dart';
import 'package:fushi/src/leaderboard/leaderboard_watermelon_layout.dart';

void main() {
  group('大西瓜：字数 → 半径', () {
    test('保序、落在上下限内，且差几个数量级时小球仍认得出', () {
      const int maxValue = 2000000;
      final List<int> values = <int>[
        2000000,
        1000000,
        300000,
        50000,
        8000,
        1000,
        10,
      ];
      final List<double> radii = <double>[
        for (final int v in values) watermelonRadius(v, maxValue),
      ];
      expect(radii.first, closeTo(kWatermelonMaxRadius, 1e-9));
      for (int i = 1; i < radii.length; i++) {
        expect(radii[i], lessThan(radii[i - 1]), reason: 'value ${values[i]}');
        expect(radii[i], greaterThanOrEqualTo(kWatermelonMinRadius));
      }
      // 线性面积下 1000 字只有最大球半径的 2%；混合映射要远大于此。
      final double small = watermelonRadius(1000, maxValue);
      expect(small / kWatermelonMaxRadius, greaterThan(0.35));
      // 但头部差距仍明显：200 万与 30 万的半径比 > 1.4。
      expect(
        watermelonRadius(2000000, maxValue) /
            watermelonRadius(300000, maxValue),
        greaterThan(1.4),
      );
    });

    test('零 / 负值与空榜取最小半径', () {
      expect(watermelonRadius(0, 100), kWatermelonMinRadius);
      expect(watermelonRadius(5, 0), kWatermelonMinRadius);
    });
  });

  group('大西瓜：静态堆叠', () {
    test('任意两球不重叠、全部在容器内、落在地面或别的球上', () {
      final math.Random r = math.Random(3);
      final List<int> values = <int>[
        for (int i = 0; i < 100; i++) (2000000 * math.pow(0.9, i)).round(),
      ];
      values.add(r.nextInt(50));
      final int maxValue = values.reduce(math.max);
      final List<double> radii = <double>[
        for (final int v in values) watermelonRadius(v, maxValue),
      ];
      final WatermelonPile pile = layoutWatermelonPile(radii);
      expect(pile.balls, hasLength(radii.length));
      for (final WatermelonBall a in pile.balls) {
        expect(a.center.x - a.radius, greaterThanOrEqualTo(-1e-6));
        expect(a.center.x + a.radius, lessThanOrEqualTo(pile.width + 1e-6));
        expect(a.center.y - a.radius, greaterThanOrEqualTo(-1e-6));
        expect(a.center.y + a.radius, lessThanOrEqualTo(pile.height + 1e-6));
        bool supported = (a.center.y + a.radius - pile.height).abs() < 1e-6;
        for (final WatermelonBall b in pile.balls) {
          if (identical(a, b)) continue;
          final double d = a.center.distanceTo(b.center);
          expect(
            d,
            greaterThanOrEqualTo(a.radius + b.radius - 1e-6),
            reason: 'balls ${a.index} / ${b.index} overlap',
          );
          if (b.index < a.index &&
              b.center.y > a.center.y &&
              (d - a.radius - b.radius).abs() < 1e-6) {
            supported = true;
          }
        }
        expect(supported, isTrue, reason: 'ball ${a.index} floats');
      }
      // 大致是一堆而不是一条：高宽比在合理范围。
      expect(pile.height / pile.width, inInclusiveRange(0.3, 2.0));
    });

    test('空输入', () {
      final WatermelonPile pile = layoutWatermelonPile(const <double>[]);
      expect(pile.balls, isEmpty);
      expect(pile.width, 0);
    });
  });

  group('总字数卡：参照作品', () {
    test('随包数据：几十部、书 / 漫画 / 动画 / gal 都有、字数为正', () {
      expect(kLeaderboardReferenceWorks.length, greaterThanOrEqualTo(30));
      for (final LeaderboardReferenceKind kind
          in LeaderboardReferenceKind.values) {
        expect(
          kLeaderboardReferenceWorks.where(
            (LeaderboardReferenceWork w) => w.kind == kind,
          ),
          isNotEmpty,
          reason: '$kind',
        );
      }
      for (final LeaderboardReferenceWork w in kLeaderboardReferenceWorks) {
        expect(w.unitChars, greaterThan(0), reason: w.title);
        expect(w.title.trim(), isNotEmpty);
      }
    });

    test('PDF 示例：10,068,859 字 ≈ 82.5 卷無職転生', () {
      final LeaderboardReferenceWork mushoku = kLeaderboardReferenceWorks
          .firstWhere((LeaderboardReferenceWork w) => w.title == '無職転生');
      final LeaderboardReferenceEquivalent? e = pickLeaderboardReference(
        10068859,
        <LeaderboardReferenceWork>[mushoku],
        math.Random(1),
      );
      expect(e!.amount, closeTo(82.5, 0.1));
      expect(mushoku.countsParts, isTrue);
    });

    test('优先挑换算后 ≥ 1 的；都不够时取单位字数最小的；0 字不挑', () {
      const LeaderboardReferenceWork big = LeaderboardReferenceWork(
        jitenId: 1,
        kind: LeaderboardReferenceKind.novel,
        title: 'big',
        totalChars: 1000000,
        parts: 1,
      );
      const LeaderboardReferenceWork small = LeaderboardReferenceWork(
        jitenId: 2,
        kind: LeaderboardReferenceKind.anime,
        title: 'small',
        totalChars: 48000,
        parts: 12,
      );
      for (int seed = 0; seed < 20; seed++) {
        expect(
          pickLeaderboardReference(5000, const <LeaderboardReferenceWork>[
            big,
            small,
          ], math.Random(seed))!.work,
          small,
        );
      }
      expect(
        pickLeaderboardReference(100, const <LeaderboardReferenceWork>[
          big,
          small,
        ], math.Random(0))!.work,
        small,
      );
      expect(
        pickLeaderboardReference(0, const <LeaderboardReferenceWork>[
          big,
        ], math.Random(0)),
        isNull,
      );
    });

    test('不同打开会轮换到不同作品', () {
      final Set<String> seen = <String>{
        for (int seed = 0; seed < 40; seed++)
          pickLeaderboardReference(
            10068859,
            kLeaderboardReferenceWorks,
            math.Random(seed),
          )!.work.title,
      };
      expect(seen.length, greaterThan(5));
    });

    test('下一个百万', () {
      expect(leaderboardNextMillion(0), 1000000);
      expect(leaderboardNextMillion(10068859), 11000000);
      expect(leaderboardNextMillion(2000000), 3000000);
    });
  });

  test('好友 / 作品人气入口默认隐藏（集中开关）', () {
    expect(LeaderboardFeatures.friendsEnabled, isFalse);
    expect(LeaderboardFeatures.popularWorksEnabled, isFalse);
  });
}
