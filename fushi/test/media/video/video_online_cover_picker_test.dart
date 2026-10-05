import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/cover_ui/video_online_cover_picker.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_task.dart';

/// BUG-2955：视频「在线搜索封面」从候选作品取封面图 URL 的判据。
void main() {
  const VideoMetadataLookup lookup = VideoMetadataLookup(
    provider: VideoMetadataProviderKind.anidb,
    externalId: '4925',
    mediaKind: VideoMetadataMediaKind.tv,
  );

  VideoMetadataWork work(List<VideoMetadataImage> images) => VideoMetadataWork(
    provider: VideoMetadataProviderKind.anidb,
    kind: VideoMetadataMediaKind.tv,
    title: 'Mirai Nikki',
    images: images,
  );

  VideoMetadataImage image(VideoMetadataImageKind kind, String url) =>
      VideoMetadataImage(
        kind: kind,
        url: url,
        provider: VideoMetadataProviderKind.anidb,
      );

  test('候选摘要自带封面图时直接用，不再拉完整资料', () async {
    int fetches = 0;
    final String? url = await resolveVideoCandidateCoverUrl(
      VideoSourceScrapeConfirmationCandidate(
        lookup: lookup,
        work: work(<VideoMetadataImage>[
          image(VideoMetadataImageKind.backdrop, 'https://img/backdrop.jpg'),
          image(VideoMetadataImageKind.cover, 'https://img/cover.jpg'),
        ]),
      ),
      fetchWork: (VideoMetadataLookup _) async {
        fetches++;
        return null;
      },
    );
    expect(url, 'https://img/cover.jpg', reason: '只认 cover，背景图不能顶封面');
    expect(fetches, 0);
  });

  test('搜索摘要没带图（AniDB 标题搜索）时按 lookup 拉完整资料取封面', () async {
    final List<VideoMetadataLookup> fetched = <VideoMetadataLookup>[];
    final String? url = await resolveVideoCandidateCoverUrl(
      VideoSourceScrapeConfirmationCandidate(
        lookup: lookup,
        work: work(const <VideoMetadataImage>[]),
      ),
      fetchWork: (VideoMetadataLookup l) async {
        fetched.add(l);
        return work(<VideoMetadataImage>[
          image(VideoMetadataImageKind.cover, 'https://cdn.anidb.net/a.jpg'),
        ]);
      },
    );
    expect(url, 'https://cdn.anidb.net/a.jpg');
    expect(fetched.single.externalId, '4925');
  });

  test('完整资料也没有可下载的封面图时返回 null', () async {
    final String? url = await resolveVideoCandidateCoverUrl(
      VideoSourceScrapeConfirmationCandidate(
        lookup: lookup,
        work: work(<VideoMetadataImage>[
          image(VideoMetadataImageKind.cover, 'file:///local/cover.jpg'),
          image(VideoMetadataImageKind.logo, 'https://img/logo.png'),
        ]),
      ),
      fetchWork: (VideoMetadataLookup _) async => null,
    );
    expect(url, isNull, reason: '非 http(s) 与非 cover 图都不能当在线封面下载');
  });
}
