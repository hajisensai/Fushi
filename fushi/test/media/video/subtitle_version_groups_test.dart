// B1 字幕搜索重做：两级版本聚类纯函数。分组键 = 来源合集 × (格式+语言+发布组
// +CC+机翻)；卡内按集号升序；组间排序 语言→机翻殿后→最新→下载量。
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/video/subtitle/subtitle_version_groups.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_provider.dart';

class _FakeCandidate extends VideoSubtitleCandidate {
  _FakeCandidate({
    required super.remoteId,
    required super.fileName,
    super.providerId = 'jimaku',
    super.language = 'ja',
    super.providerPriority = 100,
    super.episode,
    super.uploadedAtMs,
    super.collectionId,
    super.collectionLabel,
    super.aiTranslated,
  });
}

void main() {
  group('subtitleReleaseGroupTag', () {
    test('取开头方括号组名；CRC/分辨率/语言标签不算', () {
      expect(
          subtitleReleaseGroupTag('[SubsPlease] Show - 01.ass'), 'SubsPlease');
      expect(subtitleReleaseGroupTag('【喵萌奶茶屋】剧集 01.srt'), '喵萌奶茶屋');
      expect(subtitleReleaseGroupTag('[A1B2C3D4] Show - 01.ass'), isNull);
      expect(subtitleReleaseGroupTag('[1080p] Show.ass'), isNull);
      expect(subtitleReleaseGroupTag('[CHS] Show.ass'), isNull);
      expect(subtitleReleaseGroupTag('Show - 01.ass'), isNull);
    });
  });

  group('buildSubtitleVersionGroups', () {
    test('同合集同变体折成一张卡；不同格式/组分开', () {
      final List<SubtitleVersionGroup> groups = buildSubtitleVersionGroups(
        <VideoSubtitleCandidate>[
          for (int ep = 1; ep <= 3; ep++)
            _FakeCandidate(
              remoteId: '9:[SubsPlease] Show - 0$ep.ass',
              fileName: '[SubsPlease] Show - 0$ep.ass',
              episode: ep,
              collectionId: '9',
              collectionLabel: 'Show (Jimaku)',
            ),
          _FakeCandidate(
            remoteId: '9:[SubsPlease] Show - 01.srt',
            fileName: '[SubsPlease] Show - 01.srt',
            episode: 1,
            collectionId: '9',
            collectionLabel: 'Show (Jimaku)',
          ),
        ],
      );
      expect(groups, hasLength(2), reason: 'ass 与 srt 是两个版本');
      final SubtitleVersionGroup ass = groups
          .firstWhere((SubtitleVersionGroup group) => group.container == 'ass');
      expect(ass.members, hasLength(3));
      expect(ass.episodes, <int>{1, 2, 3});
      expect(ass.collectionLabel, 'Show (Jimaku)');
      expect(ass.releaseGroupTag, 'SubsPlease');
      expect(ass.variantParts, contains('ASS'));
    });

    test('卡内按集号升序；latest 按上传时间，无时间退化取集号最大', () {
      final List<SubtitleVersionGroup> groups = buildSubtitleVersionGroups(
        <VideoSubtitleCandidate>[
          _FakeCandidate(
            remoteId: 'a:2',
            fileName: 'Show - 02.ass',
            episode: 2,
            collectionId: 'a',
            uploadedAtMs: 2000,
          ),
          _FakeCandidate(
            remoteId: 'a:1',
            fileName: 'Show - 01.ass',
            episode: 1,
            collectionId: 'a',
            uploadedAtMs: 5000,
          ),
        ],
      );
      final SubtitleVersionGroup group = groups.single;
      expect(group.members.first.episode, 1);
      expect(group.latest.uploadedAtMs, 5000);
      expect(group.latestUploadedAtMs, 5000);

      final SubtitleVersionGroup noTime = buildSubtitleVersionGroups(
        <VideoSubtitleCandidate>[
          _FakeCandidate(remoteId: 'b:1', fileName: 'X - 01.ass', episode: 1),
          _FakeCandidate(remoteId: 'b:3', fileName: 'X - 03.ass', episode: 3),
        ],
      ).single;
      expect(noTime.latest.episode, 3);
    });

    test('组间排序：优先语言最前、机翻殿后、最新在前', () {
      final List<SubtitleVersionGroup> groups = buildSubtitleVersionGroups(
        <VideoSubtitleCandidate>[
          _FakeCandidate(
            remoteId: 'os:1',
            providerId: 'opensubtitles',
            fileName: 'Show.en.srt',
            language: 'en',
            uploadedAtMs: 9000,
          ),
          _FakeCandidate(
            remoteId: 'j:1',
            fileName: 'Show.ja.ass',
            language: 'ja',
            uploadedAtMs: 1000,
          ),
          _FakeCandidate(
            remoteId: 'os:2',
            providerId: 'opensubtitles',
            fileName: 'Show.ai.en.srt',
            language: 'en',
            uploadedAtMs: 9999,
            aiTranslated: true,
          ),
          _FakeCandidate(
            remoteId: 'j:2',
            fileName: 'Show.zh.ass',
            language: 'zh',
            uploadedAtMs: 8000,
          ),
        ],
        preferredLanguage: 'zh',
      );
      expect(
        groups.map((SubtitleVersionGroup group) => group.language).toList(),
        <String>['zh', 'ja', 'en', 'en'],
        reason: '偏好语言最前，其后按 ja/zh/en/ko 权重',
      );
      expect(groups[2].aiTranslated, isFalse);
      expect(groups[3].aiTranslated, isTrue, reason: '同语言下机翻殿后');
    });
  });

  group('pickGroupCandidateForEpisode', () {
    SubtitleVersionGroup group(List<VideoSubtitleCandidate> members) =>
        buildSubtitleVersionGroups(members).single;

    test('精确集号命中', () {
      final SubtitleVersionGroup g = group(<VideoSubtitleCandidate>[
        _FakeCandidate(remoteId: 'a:1', fileName: 'S - 01.ass', episode: 1),
        _FakeCandidate(remoteId: 'a:2', fileName: 'S - 02.ass', episode: 2),
      ]);
      expect(pickGroupCandidateForEpisode(g, 2)!.episode, 2);
      expect(pickGroupCandidateForEpisode(g, 5), isNull,
          reason: '没有那一集 → 交还 UI 展开');
    });

    test('无命中但恰有 1 个未编号文件（剧场版/整季包）→ 那一个', () {
      final SubtitleVersionGroup g = group(<VideoSubtitleCandidate>[
        _FakeCandidate(remoteId: 'a:m', fileName: 'Movie.ass'),
      ]);
      expect(pickGroupCandidateForEpisode(g, 7)!.fileName, 'Movie.ass');
      expect(pickGroupCandidateForEpisode(g, null)!.fileName, 'Movie.ass');
    });

    test('未指定集且多文件 → null（不猜）', () {
      final SubtitleVersionGroup g = group(<VideoSubtitleCandidate>[
        _FakeCandidate(remoteId: 'a:1', fileName: 'S - 01.ass', episode: 1),
        _FakeCandidate(remoteId: 'a:2', fileName: 'S - 02.ass', episode: 2),
      ]);
      expect(pickGroupCandidateForEpisode(g, null), isNull);
    });
  });
}
