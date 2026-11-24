import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/favorites/favorite_video_origin.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/video/media_server/media_server_config.dart';
import 'package:fushi/src/media/video/online/anime_source_book_spec.dart';
import 'package:fushi/src/media/video/online/anime_source_launch.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo;
import 'package:fushi_engine/sync/video_remote_service.dart'
    show videoRemoteFavoriteSourceReasons;

/// 只当身份用的播放客户端（解析器不调它的任何方法）。
class _Client implements RemoteVideoClient {
  _Client(this.name);

  final String name;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// 可配置的来源替身：记下每个来源被问了几次 / 问的是什么。
class _Sources {
  List<MediaServerConfig> mediaServers = const <MediaServerConfig>[];
  FavoriteRemoteVideoLibrary? interconnect;
  FavoriteRemoteVideoLibrary? cloud;
  Exception? onlineError;
  bool onlineSourcesAvailable = true;
  final _Client onlineClient = _Client('online');
  final List<String> cloudAsked = <String>[];
  final List<(AnimeSourceBookSpec, String)> onlineAsked =
      <(AnimeSourceBookSpec, String)>[];

  FavoriteVideoOriginSources get sources => FavoriteVideoOriginSources(
    mediaServers: () async => mediaServers,
    interconnect: () async => interconnect,
    cloud: (String sourceId) async {
      cloudAsked.add(sourceId);
      return cloud;
    },
    onlineSourcesAvailable: onlineSourcesAvailable,
    onlineEpisode: (AnimeSourceBookSpec spec, String bookUid) async {
      onlineAsked.add((spec, bookUid));
      final Exception? error = onlineError;
      if (error != null) throw error;
      return (
        client: onlineClient,
        info: RemoteVideoInfo(id: bookUid, title: spec.episode.name),
      );
    },
  );
}

FavoriteRemoteVideoLibrary _library(
  RemoteVideoClient? client,
  List<RemoteVideoInfo> videos, {
  Exception? listingError,
}) => (
  client: client,
  listing: () async {
    final Exception? error = listingError;
    if (error != null) throw error;
    return videos;
  },
);

const AnimeSourceBookSpec _spec = AnimeSourceBookSpec(
  extensionPackage: 'eu.kanade.ext.demo',
  sourceId: '42',
  anime: MihonAnime(url: '/anime/frieren', title: 'Frieren'),
  episode: MihonEpisode(
    url: '/anime/frieren/ep/3',
    name: 'Episode 3',
    uploadedAt: 0,
    number: 3,
  ),
);

const String _onlineId =
    'anime-source:eu.kanade.ext.demo:42:/anime/frieren/ep/3';

Future<FavoriteVideoOriginResult> _resolve(
  _Sources sources, {
  String itemId = 'item-1',
  String? origin,
  String? locator,
  String title = 'Episode 3',
}) => resolveFavoriteVideoOrigin(
  itemId: itemId,
  originSourceId: origin,
  originLocator: locator,
  expectedTitle: title,
  sources: sources.sources,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    await ErrorLogService.instance.clear();
  });

  test('没有视频键：noLink，不问任何来源', () async {
    final _Sources sources = _Sources();
    final FavoriteVideoOriginResult result = await _resolve(
      sources,
      itemId: '',
      origin: 'interconnect',
    );
    expect(result.failure, FavoriteVideoOriginFailure.noLink);
    expect(sources.cloudAsked, isEmpty);
  });

  group('互联对端', () {
    test('没开互联 / 没配对：peerUnavailable', () async {
      final FavoriteVideoOriginResult result = await _resolve(
        _Sources(),
        origin: 'interconnect',
      );
      expect(result.failure, FavoriteVideoOriginFailure.peerUnavailable);
    });

    test('对端在线且有这条：打开它，客户端是共享的互联客户端（不归调用方）', () async {
      final _Client peer = _Client('peer');
      final _Sources sources = _Sources()
        ..interconnect = _library(peer, <RemoteVideoInfo>[
          const RemoteVideoInfo(id: 'other', title: 'Other'),
          const RemoteVideoInfo(id: 'item-1', title: 'Episode 3'),
        ]);
      final FavoriteVideoOriginResult result = await _resolve(
        sources,
        origin: 'interconnect',
      );
      expect(result.failure, isNull);
      expect(result.launch!.client, same(peer));
      expect(result.launch!.info.id, 'item-1');
      expect(result.launch!.ownsClient, isFalse);
    });

    test('取清单失败：peerOffline，并记错误日志', () async {
      final _Sources sources = _Sources()
        ..interconnect = _library(
          _Client('peer'),
          const <RemoteVideoInfo>[],
          listingError: Exception('connection refused'),
        );
      final FavoriteVideoOriginResult result = await _resolve(
        sources,
        origin: 'interconnect',
      );
      expect(result.failure, FavoriteVideoOriginFailure.peerOffline);
      expect(ErrorLogService.instance.entries, isNotEmpty);
    });

    test('清单里没有，或有但对端没有可串流的字节：peerItemMissing', () async {
      for (final List<RemoteVideoInfo> videos in <List<RemoteVideoInfo>>[
        const <RemoteVideoInfo>[RemoteVideoInfo(id: 'other', title: 'x')],
        const <RemoteVideoInfo>[
          RemoteVideoInfo(id: 'item-1', title: 'x', peerPlayable: false),
        ],
      ]) {
        final _Sources sources = _Sources()
          ..interconnect = _library(_Client('peer'), videos);
        final FavoriteVideoOriginResult result = await _resolve(
          sources,
          origin: 'interconnect',
        );
        expect(result.failure, FavoriteVideoOriginFailure.peerItemMissing);
      }
    });
  });

  group('云盘', () {
    test('按收藏记着的那种云盘去问；关着 / 换了云盘：cloudUnavailable', () async {
      final _Sources sources = _Sources();
      final FavoriteVideoOriginResult result = await _resolve(
        sources,
        origin: 'cloud:webDav',
      );
      expect(sources.cloudAsked, <String>['cloud:webDav']);
      expect(result.failure, FavoriteVideoOriginFailure.cloudUnavailable);
    });

    test('能串流且有这条：打开；没有：cloudItemMissing；连不上：cloudUnreachable', () async {
      final _Client stream = _Client('cloud');
      final _Sources found = _Sources()
        ..cloud = _library(stream, const <RemoteVideoInfo>[
          RemoteVideoInfo(id: 'item-1', title: 'Episode 3'),
        ]);
      final FavoriteVideoOriginResult ok = await _resolve(
        found,
        origin: 'cloud:webDav',
      );
      expect(ok.launch!.client, same(stream));
      expect(ok.launch!.ownsClient, isFalse);

      final _Sources missing = _Sources()
        ..cloud = _library(stream, const <RemoteVideoInfo>[]);
      expect(
        (await _resolve(missing, origin: 'cloud:webDav')).failure,
        FavoriteVideoOriginFailure.cloudItemMissing,
      );

      final _Sources down = _Sources()
        ..cloud = _library(
          stream,
          const <RemoteVideoInfo>[],
          listingError: Exception('timeout'),
        );
      expect(
        (await _resolve(down, origin: 'cloud:webDav')).failure,
        FavoriteVideoOriginFailure.cloudUnreachable,
      );
    });

    test('只能整文件下载的云盘（FTP，无串流客户端）：notReopenable', () async {
      final _Sources sources = _Sources()
        ..cloud = _library(null, const <RemoteVideoInfo>[
          RemoteVideoInfo(id: 'item-1', title: 'Episode 3'),
        ]);
      expect(
        (await _resolve(sources, origin: 'cloud:ftp')).failure,
        FavoriteVideoOriginFailure.notReopenable,
      );
    });
  });

  group('在线视频源', () {
    test('按收藏记下的重开规格重建这一集，客户端归调用方', () async {
      final _Sources sources = _Sources();
      final FavoriteVideoOriginResult result = await _resolve(
        sources,
        itemId: _onlineId,
        origin: 'anime-source:eu.kanade.ext.demo:42',
        locator: _spec.encode(),
      );
      expect(result.launch!.client, same(sources.onlineClient));
      expect(result.launch!.ownsClient, isTrue);
      expect(result.launch!.info.id, _onlineId);
      final (AnimeSourceBookSpec spec, String bookUid) =
          sources.onlineAsked.single;
      expect(bookUid, _onlineId);
      expect(spec.anime.url, '/anime/frieren');
      expect(spec.episode.url, '/anime/frieren/ep/3');
    });

    test('扩展没装 / 停用：onlineSourceMissing', () async {
      final _Sources sources = _Sources()
        ..onlineError = const AnimeSourceLaunchUnavailable('not installed');
      expect(
        (await _resolve(
          sources,
          itemId: _onlineId,
          origin: 'anime-source:eu.kanade.ext.demo:42',
          locator: _spec.encode(),
        )).failure,
        FavoriteVideoOriginFailure.onlineSourceMissing,
      );
    });

    test('本机不能跑在线源（iOS 商店版 / 无扩展运行时）：onlineSourceUnsupported，'
        '不去建客户端', () async {
      final _Sources sources = _Sources()..onlineSourcesAvailable = false;
      for (final String? locator in <String?>[_spec.encode(), null]) {
        expect(
          (await _resolve(
            sources,
            itemId: _onlineId,
            origin: 'anime-source:eu.kanade.ext.demo:42',
            locator: locator,
          )).failure,
          FavoriteVideoOriginFailure.onlineSourceUnsupported,
        );
      }
      expect(sources.onlineAsked, isEmpty);
    });

    test('旧版本收藏没记重开规格：notReopenable，不去建客户端', () async {
      final _Sources sources = _Sources();
      expect(
        (await _resolve(
          sources,
          itemId: _onlineId,
          origin: 'anime-source:eu.kanade.ext.demo:42',
        )).failure,
        FavoriteVideoOriginFailure.notReopenable,
      );
      expect(sources.onlineAsked, isEmpty);
    });
  });

  test('直链 / 音乐 MV 等临时播放：notReopenable', () async {
    for (final String origin in <String>['url_stream', 'music_online_mv']) {
      expect(
        (await _resolve(_Sources(), origin: origin)).failure,
        FavoriteVideoOriginFailure.notReopenable,
      );
    }
  });

  test('记着的媒体服务器没登录：serverSignedOut', () async {
    expect(
      (await _resolve(_Sources(), origin: 'jellyfin:http://gone|u1')).failure,
      FavoriteVideoOriginFailure.serverSignedOut,
    );
  });

  group('旧收藏（没记来源）', () {
    test('哪儿都没有：originUnknown', () async {
      expect(
        (await _resolve(_Sources())).failure,
        FavoriteVideoOriginFailure.originUnknown,
      );
    });

    test('互联对端上 id 与标题都对上：打开它', () async {
      final _Client peer = _Client('peer');
      final _Sources sources = _Sources()
        ..interconnect = _library(peer, const <RemoteVideoInfo>[
          RemoteVideoInfo(id: 'item-1', title: 'Episode 3'),
        ]);
      final FavoriteVideoOriginResult result = await _resolve(sources);
      expect(result.launch!.client, same(peer));
    });

    test('id 撞上但标题不同：不认，originUnknown', () async {
      final _Sources sources = _Sources()
        ..interconnect = _library(_Client('peer'), const <RemoteVideoInfo>[
          RemoteVideoInfo(id: 'item-1', title: 'Something else'),
        ]);
      expect(
        (await _resolve(sources)).failure,
        FavoriteVideoOriginFailure.originUnknown,
      );
    });

    test('对端连不上：peerOffline', () async {
      final _Sources sources = _Sources()
        ..interconnect = _library(
          _Client('peer'),
          const <RemoteVideoInfo>[],
          listingError: Exception('offline'),
        );
      expect(
        (await _resolve(sources)).failure,
        FavoriteVideoOriginFailure.peerOffline,
      );
    });
  });

  group('遥控协议原因', () {
    test('与引擎声明的 reason 集合一一对应', () {
      expect(<String>{
        for (final FavoriteVideoOriginFailure f
            in FavoriteVideoOriginFailure.values)
          f.wireReason,
      }, videoRemoteFavoriteSourceReasons);
      expect(
        FavoriteVideoOriginFailure.values.length,
        videoRemoteFavoriteSourceReasons.length,
      );
    });

    test('按 reason 取回原因；不认识 / 没有的返回 null', () {
      for (final FavoriteVideoOriginFailure f
          in FavoriteVideoOriginFailure.values) {
        expect(FavoriteVideoOriginFailure.fromWireReason(f.wireReason), f);
        expect(f.message, isNotEmpty);
      }
      expect(
        FavoriteVideoOriginFailure.fromWireReason('from_the_future'),
        isNull,
      );
      expect(FavoriteVideoOriginFailure.fromWireReason(null), isNull);
    });
  });
}
