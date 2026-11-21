import 'package:fushi/src/media/video/url_stream_video.dart';
import 'package:fushi_engine/media/video/youtube_source_resolver.dart';
import 'package:test/test.dart';

/// gap-remote-10：YouTube 起播时拿到的 manifest 不再用完即丢——画质菜单的各档挂在本次
/// 起播的客户端上（内存版），点开画质菜单不再重取一遍 manifest。
void main() {
  const String watch = 'https://www.youtube.com/watch?v=dQw4w9WgXcQ';

  YoutubeVariantSet set(String tag) => YoutubeVariantSet(
    variants: <YoutubeVideoVariant>[
      YoutubeVideoVariant(
        height: 1080,
        label: '1080p',
        videoUrl: 'https://g/$tag/1080',
        codec: 'avc1',
      ),
    ],
    audioStreamUrl: 'https://g/$tag/a',
    defaultIndex: 0,
  );

  test('起播已带各档且画质目标相同：直接用，不现取 manifest', () async {
    int fetches = 0;
    final YoutubeVariantSet startup = set('startup');
    final UrlStreamVideoClient client = UrlStreamVideoClient(
      streamUrl: 'https://g/v',
      youtubeCaptionsUrl: watch,
      youtubeVariants: startup,
      youtubeVariantsTargetHeight: 1080,
      youtubeVariantsResolver: (String url, int? target) async {
        fetches++;
        return set('fetched');
      },
    );
    addTearDown(client.close);
    expect(
      await client.youtubeQualityVariants(playbackTargetHeight: 1080),
      same(startup),
    );
    expect(fetches, 0);
  });

  test('起播没带各档（持久缓存命中起播）：第一次现取，之后同一次播放复用', () async {
    final List<String> calls = <String>[];
    final UrlStreamVideoClient client = UrlStreamVideoClient(
      streamUrl: 'https://g/v',
      youtubeCaptionsUrl: watch,
      youtubeVariantsResolver: (String url, int? target) async {
        calls.add('$url@$target');
        return set('fetched');
      },
    );
    addTearDown(client.close);
    final YoutubeVariantSet first = await client.youtubeQualityVariants();
    final YoutubeVariantSet second = await client.youtubeQualityVariants();
    expect(second, same(first));
    expect(calls, <String>['$watch@null']);
  });

  test('画质目标变了：「自动」档下标随目标变，重新取一次', () async {
    int fetches = 0;
    final UrlStreamVideoClient client = UrlStreamVideoClient(
      streamUrl: 'https://g/v',
      youtubeCaptionsUrl: watch,
      youtubeVariants: set('startup'),
      youtubeVariantsTargetHeight: 1080,
      youtubeVariantsResolver: (String url, int? target) async {
        fetches++;
        return set('fetched-$target');
      },
    );
    addTearDown(client.close);
    final YoutubeVariantSet got = await client.youtubeQualityVariants(
      playbackTargetHeight: 2160,
    );
    expect(got.variants.single.videoUrl, 'https://g/fetched-2160/1080');
    expect(fetches, 1);
  });

  test('现取失败不记结果，下次点开再试', () async {
    int fetches = 0;
    final UrlStreamVideoClient client = UrlStreamVideoClient(
      streamUrl: 'https://g/v',
      youtubeCaptionsUrl: watch,
      youtubeVariantsResolver: (String url, int? target) async {
        fetches++;
        if (fetches == 1) throw StateError('manifest failed');
        return set('fetched');
      },
    );
    addTearDown(client.close);
    await expectLater(
      client.youtubeQualityVariants(),
      throwsA(isA<StateError>()),
    );
    expect((await client.youtubeQualityVariants()).isEmpty, isFalse);
    expect(fetches, 2);
  });

  test('不是 YouTube 流：空集，不联网', () async {
    int fetches = 0;
    final UrlStreamVideoClient client = UrlStreamVideoClient(
      streamUrl: 'https://cdn.example/v.m3u8',
      youtubeVariantsResolver: (String url, int? target) async {
        fetches++;
        return set('fetched');
      },
    );
    addTearDown(client.close);
    expect((await client.youtubeQualityVariants()).isEmpty, isTrue);
    expect(fetches, 0);
  });
}
