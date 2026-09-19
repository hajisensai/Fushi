import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_home_view.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_session.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_widgets.dart';
import 'package:fushi/src/sync/remote_cover_cache.dart';
import 'package:fushi/utils.dart';

import 'fake_media_server_browser.dart';

/// 库卡封面回退（BUG-2602）：库自身没图、或服务器**声称**有图但图片端点 404
/// （UHD Media Server 兼容层的真实形态：16 个库全报 `ImageTags.Primary`，其中
/// 4 个任何取图变体都 404），都要用库里条目的海报拼贴顶上，而不是整格只剩一个
/// 类型图标。
void main() {
  late Directory coverDir;

  setUpAll(() {
    coverDir = Directory.systemTemp.createTempSync('fushi-library-card-covers');
  });

  setUp(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
    RemoteCoverCache.debugSetDirResolver(() async => coverDir);
  });

  tearDownAll(() {
    RemoteCoverCache.debugSetDirResolver(null);
    coverDir.deleteSync(recursive: true);
  });

  const MediaServerLibrary noCover = MediaServerLibrary(
    id: 'lib-nocover',
    name: '国产动漫',
    kind: MediaServerLibraryKind.tvShows,
  );
  const MediaServerLibrary lyingCover = MediaServerLibrary(
    id: 'lib-404',
    name: '追新',
    kind: MediaServerLibraryKind.tvShows,
    hasCover: true,
  );

  Widget harness(Widget child) {
    return TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(width: kMediaServerLibraryCardWidth, child: child),
          ),
        ),
      ),
    );
  }

  testWidgets('库无封面 → 用条目海报拼贴（最多 3 张，跳过无图条目）', (WidgetTester tester) async {
    final _CoverFakeBrowser browser = _CoverFakeBrowser();
    await tester.pumpWidget(
      harness(
        MediaServerLibraryCard(
          browser: browser,
          library: noCover,
          fallbackItems: <MediaServerItem>[
            _series('s1'),
            _series('s2', hasCover: false),
            _series('s3'),
            _series('s4'),
            _series('s5'),
          ],
          onTap: () {},
        ),
      ),
    );
    await _settleWithImages(tester);

    expect(find.byType(MediaServerLibraryCollage), findsOneWidget);
    expect(find.byType(ShelfCoverPlaceholder), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('media-server-collage-s1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('media-server-collage-s2')),
      findsNothing,
      reason: '无图条目不占拼贴位',
    );
    expect(
      find.byKey(const ValueKey<String>('media-server-collage-s3')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('media-server-collage-s4')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('media-server-collage-s5')),
      findsNothing,
      reason: '拼贴只取前 $kMediaServerLibraryCollageCount 张',
    );
    expect(
      browser.fetchedUrls,
      isNot(contains(startsWith('lib|'))),
      reason: '库本身没图就不该去请求库封面',
    );
  });

  testWidgets('库声称有封面但取图 404 → 回退到条目拼贴', (WidgetTester tester) async {
    final _CoverFakeBrowser browser = _CoverFakeBrowser(libraryCover404: true);
    await tester.pumpWidget(
      harness(
        MediaServerLibraryCard(
          browser: browser,
          library: lyingCover,
          fallbackItems: <MediaServerItem>[_series('s1'), _series('s2')],
          onTap: () {},
        ),
      ),
    );
    await _settleWithImages(tester);

    expect(
      browser.fetchedUrls,
      contains('lib|lib-404'),
      reason: 'hasCover=true 仍先请求库封面（正常服务器这就够了）',
    );
    expect(find.byType(MediaServerLibraryCollage), findsOneWidget);
    expect(find.byType(ShelfCoverPlaceholder), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('media-server-collage-s1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('media-server-collage-s2')),
      findsOneWidget,
    );
  });

  testWidgets('库无封面且条目也全无图 → 才画类型图标', (WidgetTester tester) async {
    final _CoverFakeBrowser browser = _CoverFakeBrowser();
    await tester.pumpWidget(
      harness(
        MediaServerLibraryCard(
          browser: browser,
          library: noCover,
          fallbackItems: <MediaServerItem>[_series('s1', hasCover: false)],
          onTap: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ShelfCoverPlaceholder), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('首页把每库一行的条目喂给库卡做拼贴素材', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final _CoverFakeBrowser browser = _CoverFakeBrowser(libraryCover404: true);
    browser.libraries.addAll(<MediaServerLibrary>[noCover, lyingCover]);
    browser.children['lib-nocover'] = <MediaServerItem>[
      _series('a1'),
      _series('a2'),
    ];
    browser.children['lib-404'] = <MediaServerItem>[_series('b1')];

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: MediaServerHomeView(
              session: MediaServerSession(
                browser: browser,
                play: (BuildContext _, MediaServerPlayRequest __) {},
              ),
            ),
          ),
        ),
      ),
    );
    await _settleWithImages(tester);

    final Finder noCoverCard = find.byKey(
      const ValueKey<String>('media-server-library-lib-nocover'),
    );
    final Finder lyingCard = find.byKey(
      const ValueKey<String>('media-server-library-lib-404'),
    );
    expect(noCoverCard, findsOneWidget);
    expect(lyingCard, findsOneWidget);
    expect(
      find.descendant(
        of: noCoverCard,
        matching: find.byKey(const ValueKey<String>('media-server-collage-a1')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: lyingCard,
        matching: find.byKey(const ValueKey<String>('media-server-collage-b1')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: noCoverCard,
        matching: find.byType(ShelfCoverPlaceholder),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: lyingCard,
        matching: find.byType(ShelfCoverPlaceholder),
      ),
      findsNothing,
    );
  });
}

MediaServerItem _series(String id, {bool hasCover = true}) => MediaServerItem(
  id: id,
  name: 'Series $id',
  type: MediaServerItemType.series,
  hasCover: hasCover,
);

/// 让真实的 `RemoteCoverImage` 读盘 / 拉网 / 解码在 FakeAsync 之外跑完（与像素
/// 预览测试同一套等法）。
Future<void> _settleWithImages(WidgetTester tester) async {
  await tester.pumpAndSettle();
  for (int i = 0; i < 10; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pumpAndSettle();
}

/// 1×1 透明 PNG：让条目海报真的解码出来（拼贴列不走 errorBuilder）。
final Uint8List _onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

/// 有封面的假浏览器：条目海报按 `hasCover` 给 URL 并真的返回一张 PNG；库封面
/// 按 `hasCover` 给 URL，[libraryCover404] 时取图抛（= 真服务器的 404）。
class _CoverFakeBrowser extends FakeMediaServerBrowser {
  _CoverFakeBrowser({this.libraryCover404 = false})
    : super(serverId: 'fake:covers');

  final bool libraryCover404;
  final List<String> fetchedUrls = <String>[];

  @override
  String? coverUrl(
    MediaServerItem item, {
    int maxWidth = kMediaServerCoverMaxWidth,
    MediaServerImageKind kind = MediaServerImageKind.primary,
  }) => item.hasCover ? 'item|${item.id}|${kind.name}' : null;

  @override
  String? libraryCoverUrl(
    MediaServerLibrary library, {
    int maxWidth = kMediaServerCoverMaxWidth,
  }) => library.hasCover ? 'lib|${library.id}' : null;

  @override
  Future<Uint8List> fetchRemoteCover(String coverUrl) async {
    fetchedUrls.add(coverUrl);
    if (coverUrl.startsWith('lib|') && libraryCover404) {
      throw StateError('404 $coverUrl');
    }
    return _onePixelPng;
  }
}
