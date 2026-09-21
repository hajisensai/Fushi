import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/download/subscription_release_scope.dart';

/// BUG-2619：从一条整包资源建订阅，规则按「追更单集」落库，检查时又被整包判据
/// 丢掉，于是生成一条结构上永不命中的订阅。判据必须只有这一份，且必须认得出
/// 「没有区间、没有关键词、只是解析不出集号」的 BD 全集包。
void main() {
  group('subscriptionReleaseIsBatch', () {
    test('认出用户报告的 BD 全集包（无区间、无关键词、只有 [Fin]）', () {
      expect(
        subscriptionReleaseIsBatch(
          '[DMG&MakariHoshiyume&VCB-Studio] Shoujo Kageki Revue Starlight '
          '10-bit 1080p HEVC BDRip [Fin]',
        ),
        isTrue,
      );
    });

    test('认出显式合集形态', () {
      expect(
        subscriptionReleaseIsBatch('[Group] Example Show [01-12] [1080p]'),
        isTrue,
      );
      expect(
        subscriptionReleaseIsBatch('[Group] Example Show Batch [1080p]'),
        isTrue,
      );
      expect(
        subscriptionReleaseIsBatch('[Group] Example Show 全集 [1080p]'),
        isTrue,
      );
      expect(
        subscriptionReleaseIsBatch('[Group] Example Show Season Pack'),
        isTrue,
      );
    });

    test('单集发布不算整包', () {
      expect(
        subscriptionReleaseIsBatch('[SubsPlease] Example Show - 05 [1080p]'),
        isFalse,
      );
      expect(
        subscriptionReleaseIsBatch('Example Show S01E05 1080p WEB-DL'),
        isFalse,
      );
    });

    test('日期与技术标记不被误判成集数区间', () {
      expect(
        looksLikeBatchVideoRelease('[Group] Example Show - 05 [2023-08]'),
        isFalse,
      );
      expect(
        looksLikeBatchVideoRelease('[Group] Example Show - 05 [10-bit]'),
        isFalse,
      );
    });
  });
}
