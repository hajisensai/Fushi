import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/cover_ui/cover_aspect_probe.dart';
import 'package:hibiki/src/media/video/video_home_layout.dart';

/// TODO-2486 视频首页布局/筛选纯函数单测（与页面实现同源消费）。
void main() {
  group('videoCardOrientationForAspect', () {
    test('null（未解码/无封面）默认竖卡', () {
      expect(
          videoCardOrientationForAspect(null), VideoCardOrientation.portrait);
    });

    test('阈值与封面组件同一真相源（kCoverLandscapeAspectThreshold）', () {
      expect(
        videoCardOrientationForAspect(kCoverLandscapeAspectThreshold),
        VideoCardOrientation.landscape,
      );
      expect(
        videoCardOrientationForAspect(kCoverLandscapeAspectThreshold - 0.01),
        VideoCardOrientation.portrait,
      );
    });

    test('典型输入：2:3 海报竖卡、16:9 截帧横卡、方图竖卡', () {
      expect(
          videoCardOrientationForAspect(2 / 3), VideoCardOrientation.portrait);
      expect(videoCardOrientationForAspect(16 / 9),
          VideoCardOrientation.landscape);
      expect(videoCardOrientationForAspect(1.0), VideoCardOrientation.portrait);
    });
  });

  group('videoCardWidthForOrientation / videoCoverHeightForPortraitWidth', () {
    test('高度统一下竖卡 2:3、横卡 16:9，竖卡宽反解回目标卡宽', () {
      final double coverHeight = videoCoverHeightForPortraitWidth(160);
      expect(coverHeight, 240);
      expect(
        videoCardWidthForOrientation(
          orientation: VideoCardOrientation.portrait,
          coverHeight: coverHeight,
        ),
        closeTo(160, 0.001),
      );
      expect(
        videoCardWidthForOrientation(
          orientation: VideoCardOrientation.landscape,
          coverHeight: coverHeight,
        ),
        closeTo(240 * 16 / 9, 0.001),
      );
    });
  });

  group('videoHeroHeightForWidth', () {
    test('21:9 影院比例，夹在 [220, 420]', () {
      expect(videoHeroHeightForWidth(840), closeTo(360, 0.001));
      expect(videoHeroHeightForWidth(300), 220);
      expect(videoHeroHeightForWidth(4000), 420);
    });
  });

  group('videoAirYear / videoAirSeasonQuarter', () {
    test('TMDB 全日期与裸年份都解析', () {
      expect(videoAirYear('2024-10-05'), 2024);
      expect(videoAirYear('2024'), 2024);
      expect(videoAirYear(' 1999-01-01 '), 1999);
    });

    test('脏数据归 null（未知桶）', () {
      expect(videoAirYear(null), isNull);
      expect(videoAirYear(''), isNull);
      expect(videoAirYear('未定'), isNull);
      expect(videoAirYear('0000-01-01'), isNull);
    });

    test('季度：1-3 冬 / 4-6 春 / 7-9 夏 / 10-12 秋；无月份 null', () {
      expect(videoAirSeasonQuarter('2024-01-05'), 1);
      expect(videoAirSeasonQuarter('2024-04-05'), 2);
      expect(videoAirSeasonQuarter('2024-07-05'), 3);
      expect(videoAirSeasonQuarter('2024-10-05'), 4);
      expect(videoAirSeasonQuarter('2024'), isNull);
      expect(videoAirSeasonQuarter('2024-13'), isNull);
      expect(videoAirSeasonQuarter(null), isNull);
    });
  });

  group('VideoYearFilter', () {
    test('全部恒真；指定年份精确匹配；未知只收 null 年份', () {
      const VideoYearFilter all = VideoYearFilter.all();
      expect(all.isAll, isTrue);
      expect(all.matches(2024), isTrue);
      expect(all.matches(null), isTrue);

      const VideoYearFilter y2024 = VideoYearFilter.year(2024);
      expect(y2024.matches(2024), isTrue);
      expect(y2024.matches(2023), isFalse);
      // 无刮削资料的条目在指定年份下不显示，但在「未知」桶下不消失。
      expect(y2024.matches(null), isFalse);

      const VideoYearFilter unknown = VideoYearFilter.unknown();
      expect(unknown.matches(null), isTrue);
      expect(unknown.matches(2024), isFalse);
    });

    test('值语义（PopupMenu initialValue 依赖 ==）', () {
      expect(
          const VideoYearFilter.year(2024), const VideoYearFilter.year(2024));
      expect(
          const VideoYearFilter.all(), isNot(const VideoYearFilter.unknown()));
    });
  });

  group('matchesVideoWatchStatus', () {
    test('三档互斥覆盖：未看 / 在看 / 已看完', () {
      // 已看完。
      expect(
        matchesVideoWatchStatus(
          filter: VideoWatchStatusFilter.completed,
          completed: true,
          lastPositionMs: 0,
        ),
        isTrue,
      );
      // 在看 = 未完成但有播放痕迹。
      expect(
        matchesVideoWatchStatus(
          filter: VideoWatchStatusFilter.watching,
          completed: false,
          lastPositionMs: 1200,
        ),
        isTrue,
      );
      expect(
        matchesVideoWatchStatus(
          filter: VideoWatchStatusFilter.watching,
          completed: true,
          lastPositionMs: 1200,
        ),
        isFalse,
      );
      // 未看 = 两者皆无。
      expect(
        matchesVideoWatchStatus(
          filter: VideoWatchStatusFilter.unwatched,
          completed: false,
          lastPositionMs: 0,
        ),
        isTrue,
      );
      expect(
        matchesVideoWatchStatus(
          filter: VideoWatchStatusFilter.unwatched,
          completed: false,
          lastPositionMs: 1,
        ),
        isFalse,
      );
      // 全部恒真。
      expect(
        matchesVideoWatchStatus(
          filter: VideoWatchStatusFilter.all,
          completed: false,
          lastPositionMs: 0,
        ),
        isTrue,
      );
    });
  });

  group('isVideoRecentlyAdded', () {
    final DateTime now = DateTime(2026, 8, 1, 12);

    test('14 天窗口内算最近添加；窗口外/无时间戳/未来时刻不算', () {
      expect(
        isVideoRecentlyAdded(
          importedAt:
              now.subtract(const Duration(days: 13)).millisecondsSinceEpoch,
          now: now,
        ),
        isTrue,
      );
      expect(
        isVideoRecentlyAdded(
          importedAt:
              now.subtract(const Duration(days: 15)).millisecondsSinceEpoch,
          now: now,
        ),
        isFalse,
      );
      expect(isVideoRecentlyAdded(importedAt: null, now: now), isFalse);
      expect(isVideoRecentlyAdded(importedAt: 0, now: now), isFalse);
      expect(
        isVideoRecentlyAdded(
          importedAt: now.add(const Duration(days: 1)).millisecondsSinceEpoch,
          now: now,
        ),
        isFalse,
      );
    });
  });

  group('selectVideoHeroCollections', () {
    test('在看优先按最近观看倒序取前 5', () {
      final List<VideoHeroCandidate> candidates = <VideoHeroCandidate>[
        for (int i = 1; i <= 7; i++)
          VideoHeroCandidate(
            collectionId: i,
            lastWatchedAt: DateTime(2026, 7, i),
            latestImportedAt: 100 - i,
            hasUnfinishedTrace: true,
          ),
      ];
      expect(selectVideoHeroCollections(candidates), <int>[7, 6, 5, 4, 3]);
    });

    test('无在看回落最近添加（成员最近入库倒序）', () {
      final List<VideoHeroCandidate> candidates = <VideoHeroCandidate>[
        const VideoHeroCandidate(collectionId: 1, latestImportedAt: 10),
        const VideoHeroCandidate(collectionId: 2, latestImportedAt: 30),
        const VideoHeroCandidate(collectionId: 3, latestImportedAt: 20),
      ];
      expect(selectVideoHeroCollections(candidates), <int>[2, 3, 1]);
    });

    test('已整套看完的合集不算在看（hasUnfinishedTrace=false 走回落池）', () {
      final List<VideoHeroCandidate> candidates = <VideoHeroCandidate>[
        VideoHeroCandidate(
          collectionId: 1,
          lastWatchedAt: DateTime(2026, 7, 30),
          latestImportedAt: 1,
        ),
        VideoHeroCandidate(
          collectionId: 2,
          lastWatchedAt: DateTime(2026, 7, 1),
          latestImportedAt: 2,
          hasUnfinishedTrace: true,
        ),
      ];
      // 只有 2 在看 → 在看池非空 → 只出在看的（1 不混入）。
      expect(selectVideoHeroCollections(candidates), <int>[2]);
    });
  });
}
