import 'dart:io';

import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/media/video/video_library_section.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi/src/sync/remote_cover_image.dart';
import 'package:fushi/src/sync/remote_library_source.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi/src/utils/adaptive/shell_style.dart'
    show ShellContentLayout;
import 'package:fushi/src/utils/components/fushi_logo_title.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/shell_layout.dart';
import '../helpers/test_platform_services.dart';

/// BUG-5614：视频页里不在本机库的媒体服务器剧（远端占位折成的合集）色块要画
/// 服务器上的作品背景图与 logo（[RemoteVideoInfo.workBackdropItemId] /
/// [RemoteVideoInfo.workLogoItemId]，经服务器自己的取图器取），不能只剩封面取色
/// + 大字水印。系列墙与首页「继续观看」两处都要。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync(
      'fushi_server_series_art_pp',
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => pathProviderDir.path,
    );
  });
  tearDownAll(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (pathProviderDir.existsSync()) {
      try {
        pathProviderDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  late FushiDatabase db;
  late PlatformServices platformServices;
  late FakeAnkiRepository ankiRepository;
  late AppModel appModel;
  late Directory storeDir;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync(
      'fushi_server_series_art_store',
    );
    platformServices = testPlatformServices();
    ankiRepository = FakeAnkiRepository();
    appModel = AppModel(platformServices)
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
  });

  tearDown(() async {
    await db.close();
    if (storeDir.existsSync()) {
      storeDir.deleteSync(recursive: true);
    }
  });

  Widget buildApp(RemoteVideoClient client, VideoLibrarySection section) =>
      ProviderScope(
        overrides: <Override>[
          platformServicesProvider.overrideWithValue(platformServices),
          ankiRepositoryProvider.overrideWithValue(ankiRepository),
          appProvider.overrideWith((ref) => appModel),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            theme: shellLayoutTheme(ShellContentLayout.collage),
            home: Scaffold(
              body: HomeVideoPage(
                repo: VideoBookRepository(db),
                section: section,
                remoteVideoClientLoader: () async => client,
              ),
            ),
          ),
        ),
      );

  Future<void> sizeUp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// 树里所有 [Image] 与艺术字（[FushiLogoTitle]）的远端图地址（剥掉
  /// [ResizeImage]）。艺术字先经 ImageStream 量宽高比、解码成功才建 [Image]；
  /// 测试里取图直接失败，它退回文字，所以要看它收到的 provider。
  Set<String> remoteImageUrls(WidgetTester tester) {
    final List<ImageProvider<Object>> providers = <ImageProvider<Object>>[
      for (final Image image in tester.widgetList<Image>(find.byType(Image)))
        image.image,
      for (final FushiLogoTitle title in tester.widgetList<FushiLogoTitle>(
        find.byType(FushiLogoTitle),
      ))
        title.logo,
    ];
    final Set<String> urls = <String>{};
    for (ImageProvider<Object> base in providers) {
      while (base is ResizeImage) {
        base = base.imageProvider;
      }
      if (base is RemoteCoverImage) urls.add(base.coverUrl);
    }
    return urls;
  }

  RemoteVideoInfo episode({required int positionMs, required int nowMs}) =>
      RemoteVideoInfo(
        id: 'ep1',
        title: 'Show S01E01',
        durationMs: 1440000,
        hasCover: true,
        coverUrl: '$_kServer/Items/ep1/Images/primary',
        seriesCoverUrl: '$_kServer/Items/series-1/Images/primary',
        workBackdropItemId: 'series-1',
        workLogoItemId: 'series-1',
        positionMs: positionMs,
        positionUpdatedAtMs: positionMs > 0 ? nowMs : 0,
        importedAt: nowMs,
        collection: const RemoteCollectionMembership(
          collectionName: 'Show',
          collectionType: 'playlist',
          sortIndex: 10001,
        ),
      );

  testWidgets('系列墙：纯远端剧的色块画服务器背景图与 logo', (WidgetTester tester) async {
    await sizeUp(tester);
    await db.createMediaCollection('Show', collectionType: 'playlist');
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    await tester.pumpWidget(
      buildApp(
        _FakeServerClient(<RemoteVideoInfo>[
          episode(positionMs: 0, nowMs: nowMs),
        ]),
        VideoLibrarySection.series,
      ),
    );
    await tester.pumpAndSettle();

    final Set<String> urls = remoteImageUrls(tester);
    expect(
      urls,
      contains('$_kServer/Items/series-1/Images/backdrop?w=720'),
      reason: '背景图来自服务器的剧（workBackdropItemId），不是只剩封面取色',
    );
    expect(
      urls,
      contains('$_kServer/Items/series-1/Images/logo?w=800'),
      reason: 'logo 来自服务器的剧（workLogoItemId，hero 尺寸）',
    );
  });

  testWidgets('首页「继续观看」：看到一半的纯远端剧画服务器背景图与 logo', (WidgetTester tester) async {
    await sizeUp(tester);
    await db.createMediaCollection('Show', collectionType: 'playlist');
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    await tester.pumpWidget(
      buildApp(
        _FakeServerClient(<RemoteVideoInfo>[
          episode(positionMs: 300000, nowMs: nowMs),
        ]),
        VideoLibrarySection.home,
      ),
    );
    await tester.pumpAndSettle();

    final Finder card = find.byKey(
      const ValueKey<String>('home_video_continue_collection_1'),
    );
    expect(card, findsWidgets, reason: '前提：远端剧进了「继续观看」');
    final Set<String> urls = remoteImageUrls(tester);
    expect(urls, contains('$_kServer/Items/series-1/Images/backdrop?w=720'));
    expect(urls, contains('$_kServer/Items/series-1/Images/logo?w=800'));
  });

  testWidgets('非媒体服务器来源（互联 host）不拼服务器图', (WidgetTester tester) async {
    await sizeUp(tester);
    await db.createMediaCollection('Show', collectionType: 'playlist');
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    await tester.pumpWidget(
      buildApp(
        _FakeHostClient(<RemoteVideoInfo>[
          episode(positionMs: 0, nowMs: nowMs),
        ]),
        VideoLibrarySection.series,
      ),
    );
    await tester.pumpAndSettle();

    final Set<String> urls = remoteImageUrls(tester);
    expect(urls.where((String u) => u.contains('/backdrop')), isEmpty);
    expect(urls.where((String u) => u.contains('/logo')), isEmpty);
  });
}

const String _kServer = 'https://jf.example';

/// 互联 host 形状的远端视频源：清单 + 封面取图（取图直接失败，只断言图源）。
class _FakeHostClient implements RemoteVideoClient, RemoteCoverFetcher {
  _FakeHostClient(this._videos);
  final List<RemoteVideoInfo> _videos;

  @override
  String get remoteLibrarySourceId => kInterconnectRemoteLibrarySourceId;

  @override
  String get coverCacheNamespace => 'test-server';

  @override
  Future<Uint8List> fetchRemoteCover(String coverUrl) async =>
      throw StateError('no network in test');

  @override
  Future<List<RemoteVideoInfo>> listRemoteVideos() async => _videos;

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 同一份清单，另外是媒体服务器浏览器：作品图地址按条目 id + 图种 + 宽度拼。
/// 来源身份沿用互联的（绕开「自动列出条目」闸门——本文件只测取图链）。
class _FakeServerClient extends _FakeHostClient implements MediaServerBrowser {
  _FakeServerClient(super.videos);

  @override
  String? coverUrl(
    MediaServerItem item, {
    int maxWidth = kMediaServerCoverMaxWidth,
    MediaServerImageKind kind = MediaServerImageKind.primary,
  }) {
    final bool has = switch (kind) {
      MediaServerImageKind.primary => item.hasCover,
      MediaServerImageKind.backdrop => item.hasBackdrop,
      MediaServerImageKind.thumb => item.hasThumb,
      MediaServerImageKind.logo => item.hasLogo,
    };
    return has
        ? '$_kServer/Items/${item.id}/Images/${kind.name}?w=$maxWidth'
        : null;
  }
}
