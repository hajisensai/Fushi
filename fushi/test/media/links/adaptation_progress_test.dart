import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/links/adaptation_progress_section.dart';
import 'package:fushi_engine/media/links/adaptation_progress.dart';

/// 动画进度 ↔ 原作进度（作品图谱 L5 §6）：手动对应点的估算与看到第几集。
void main() {
  const AdaptationSourceUnit vol = AdaptationSourceUnit.volume;
  const List<AdaptationProgressAnchor> anchors = <AdaptationProgressAnchor>[
    AdaptationProgressAnchor(episode: 1, unit: vol, number: 1),
    AdaptationProgressAnchor(episode: 13, unit: vol, number: 4),
    AdaptationProgressAnchor(
      episode: 20,
      unit: AdaptationSourceUnit.chapter,
      number: 41,
    ),
  ];

  test('取集号不晚于当前集的最后一个对应点，不插值', () {
    expect(estimateSourceProgress(anchors, 12)!.number, 1);
    expect(estimateSourceProgress(anchors, 13)!.number, 4);
    expect(estimateSourceProgress(anchors, 25)!.number, 41);
    expect(estimateSourceProgress(anchors, null), isNull);
    expect(
      estimateSourceProgress(const <AdaptationProgressAnchor>[
        AdaptationProgressAnchor(episode: 5, unit: vol, number: 2),
      ], 3),
      isNull,
    );
  });

  test('反向估算只比同单位', () {
    expect(estimateAdaptationEpisode(anchors, vol, 5), 13);
    expect(
      estimateAdaptationEpisode(anchors, AdaptationSourceUnit.chapter, 40),
      isNull,
    );
  });

  test('未知单位读作卷；推断器尚未提供', () {
    expect(AdaptationSourceUnit.parse('weird'), vol);
    expect(kAdaptationProgressInferrer, isNull);
  });

  test('watchedEpisodeFrom：取看过的最大集号，解析不出用顺位', () {
    expect(
      watchedEpisodeFrom(const <WatchedEpisodeFact>[
        (episode: 1, started: true),
        (episode: 2, started: true),
        (episode: 3, started: false),
      ]),
      2,
    );
    expect(
      watchedEpisodeFrom(const <WatchedEpisodeFact>[
        (episode: null, started: false),
        (episode: null, started: true),
      ]),
      2,
    );
    expect(watchedEpisodeFrom(const <WatchedEpisodeFact>[]), isNull);
  });

  test('进度一句话', () {
    LocaleSettings.setLocale(AppLocale.zhCn);
    expect(adaptationProgressLine(anchors, 14), '看到第 14 集 ≈ 原作第 4 卷');
    expect(adaptationProgressLine(anchors, null), '还没开始看');
    expect(
      adaptationProgressLine(const <AdaptationProgressAnchor>[], 3),
      startsWith('还没有对应点'),
    );
  });
}
