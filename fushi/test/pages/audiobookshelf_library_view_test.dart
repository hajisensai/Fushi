// Books 库里的 Audiobookshelf 标签页：库与条目、只有电子书的条目不列、「继续收听」、分页、
// 搜索、加载失败可重试、切换媒体库、点封面进详情页（书 / 播客）。假服务器 + 真组件。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/discovery/audiobookshelf_server_config.dart';
import 'package:fushi/src/pages/implementations/audiobookshelf/audiobookshelf_library_view.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_api.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_models.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';

Map<String, Object?> _libItem(
  String id,
  String title, {
  String author = 'Author',
  int? audioFiles = 1,
  String mediaType = 'book',
  double duration = 3725,
}) => <String, Object?>{
  'id': id,
  'libraryId': 'lib1',
  'mediaType': mediaType,
  'media': <String, Object?>{
    'metadata': <String, Object?>{'title': title, 'authorName': author},
    'numAudioFiles': audioFiles,
    'duration': duration,
  },
};

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: <String, String>{'content-type': 'application/json'},
);

class _Server {
  final List<String> requests = <String>[];
  bool librariesFail = false;
  int total = 3;
  List<Map<String, Object?>> page0 = <Map<String, Object?>>[
    _libItem('b1', 'Fables', author: 'Aesop'),
    _libItem('b2', 'Second Book'),
    _libItem('e1', 'Only An Ebook', audioFiles: 0),
  ];
  List<Map<String, Object?>> page1 = <Map<String, Object?>>[];
  List<Map<String, Object?>> searchHits = <Map<String, Object?>>[];
  List<Map<String, Object?>> inProgress = <Map<String, Object?>>[];

  Future<http.Response> handle(http.Request request) async {
    requests.add('${request.url.path}?${request.url.query}');
    final String path = request.url.path;
    if (path.endsWith('/cover')) return http.Response('no', 404);
    if (path == '/api/libraries') {
      if (librariesFail) return http.Response('down', 503);
      return _json(<String, Object?>{
        'libraries': <Object?>[
          <String, Object?>{
            'id': 'lib1',
            'name': 'Audiobooks',
            'mediaType': 'book',
          },
          <String, Object?>{
            'id': 'lib2',
            'name': 'Podcasts',
            'mediaType': 'podcast',
          },
        ],
      });
    }
    if (path == '/api/libraries/lib1/items') {
      final int page = int.parse(request.url.queryParameters['page'] ?? '0');
      return _json(<String, Object?>{
        'results': page == 0 ? page0 : page1,
        'total': total,
        'limit': 40,
        'page': page,
      });
    }
    if (path == '/api/libraries/lib2/items') {
      return _json(<String, Object?>{
        'results': <Object?>[
          _libItem('p1', 'The Show', mediaType: 'podcast', audioFiles: null),
        ],
        'total': 1,
        'limit': 40,
        'page': 0,
      });
    }
    if (path.endsWith('/search')) {
      return _json(<String, Object?>{
        'book': <Object?>[
          for (final Map<String, Object?> hit in searchHits)
            <String, Object?>{'libraryItem': hit},
        ],
      });
    }
    if (path == '/api/me/items-in-progress') {
      return _json(<String, Object?>{'libraryItems': inProgress});
    }
    if (path == '/api/items/b1') {
      return _json(<String, Object?>{
        ..._libItem('b1', 'Fables', author: 'Aesop'),
        'media': <String, Object?>{
          'metadata': <String, Object?>{
            'title': 'Fables',
            'authorName': 'Aesop',
            'narratorName': 'Reader R',
          },
          'tracks': <Object?>[
            <String, Object?>{
              'index': 1,
              'ino': '10',
              'duration': 100,
              'startOffset': 0,
            },
          ],
        },
        'libraryFiles': <Object?>[],
      });
    }
    if (path == '/api/items/p1') {
      return _json(<String, Object?>{
        ..._libItem('p1', 'The Show', mediaType: 'podcast', audioFiles: null),
        'media': <String, Object?>{
          'metadata': <String, Object?>{'title': 'The Show'},
          'episodes': <Object?>[
            <String, Object?>{
              'id': 'old',
              'title': 'Older Episode',
              'publishedAt': 1000000000000,
              'audioFile': <String, Object?>{'ino': '1', 'duration': 60},
            },
            <String, Object?>{
              'id': 'new',
              'title': 'Newer Episode',
              'publishedAt': 1700000000000,
              'audioFile': <String, Object?>{'ino': '2', 'duration': 120},
            },
          ],
        },
      });
    }
    return http.Response('not found', 404);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory cache;
  late _Server server;

  setUpAll(() async {
    // AppCachedHttpImage 构造即起磁盘缓存管理器，要 path_provider 应答。
    cache = await Directory.systemTemp.createTemp('abs-view-cache-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (MethodCall call) async => cache.path,
        );
  });
  tearDownAll(() => cache.delete(recursive: true));

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    server = _Server();
  });

  final AudiobookshelfServerConfig config = AudiobookshelfServerConfig(
    id: 'srv',
    name: 'Home',
    serverUrl: Uri.parse('https://abs.example.com'),
    username: 'me',
    tokens: const AudiobookshelfTokens(accessToken: 'a'),
  );

  Future<void> pumpView(
    WidgetTester tester, {
    List<AudiobookshelfServerConfig>? servers,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 1400);
    addTearDown(tester.view.reset);
    final AudiobookshelfApi api = AudiobookshelfApi(
      serverUrl: config.serverUrl,
      providerId: 'abs-test',
      tokens: const AudiobookshelfTokens(accessToken: 'a'),
      client: MockClient(server.handle),
    );
    addTearDown(api.close);
    await tester.pumpWidget(
      ProviderScope(
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: AudiobookshelfLibraryView(
                servers: servers ?? <AudiobookshelfServerConfig>[config],
                apiFor: (AudiobookshelfServerConfig _) => api,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('显示媒体库名与条目；只有电子书的条目不列', (WidgetTester tester) async {
    await pumpView(tester);
    expect(find.text('Audiobooks'), findsOneWidget);
    expect(find.text('Fables'), findsOneWidget);
    expect(find.text('Second Book'), findsOneWidget);
    expect(find.text('Only An Ebook'), findsNothing);
    expect(find.text('Aesop · 1:02:05'), findsOneWidget);
  });

  testWidgets('有进行中的条目 → 显示「继续收听」一行', (WidgetTester tester) async {
    server.inProgress = <Map<String, Object?>>[_libItem('b2', 'Second Book')];
    await pumpView(tester);
    expect(find.text('Continue listening'), findsOneWidget);
    // 同一本书在「继续收听」行与网格里各出现一次。
    expect(find.text('Second Book'), findsNWidgets(2));
  });

  testWidgets('没有进行中的条目 → 没有这一行', (WidgetTester tester) async {
    await pumpView(tester);
    expect(find.text('Continue listening'), findsNothing);
  });

  testWidgets('第一页没填满视口 → 自动补取下一页', (WidgetTester tester) async {
    server
      ..total = 50
      ..page0 = <Map<String, Object?>>[_libItem('b1', 'Fables')]
      ..page1 = <Map<String, Object?>>[_libItem('b9', 'Page Two Book')];
    await pumpView(tester);
    expect(find.text('Fables'), findsOneWidget);
    expect(find.text('Page Two Book'), findsOneWidget);
    expect(
      server.requests.where(
        (r) => r.contains('/lib1/items') && r.contains('page=1'),
      ),
      isNotEmpty,
    );
  });

  testWidgets('搜索：防抖后按关键词查，结果替换网格；清空回到浏览', (WidgetTester tester) async {
    server.searchHits = <Map<String, Object?>>[_libItem('s1', 'Search Hit')];
    await pumpView(tester);

    await tester.enterText(find.byType(TextField), 'hit');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(find.text('Search Hit'), findsOneWidget);
    expect(find.text('Fables'), findsNothing);
    expect(
      server.requests.where(
        (r) => r.contains('/search') && r.contains('q=hit'),
      ),
      hasLength(1),
    );

    await tester.enterText(find.byType(TextField), '');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(find.text('Fables'), findsOneWidget);
    expect(find.text('Search Hit'), findsNothing);
  });

  testWidgets('搜索没有结果 → 「没有匹配项」', (WidgetTester tester) async {
    await pumpView(tester);
    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(find.text('No matches'), findsOneWidget);
  });

  testWidgets('加载失败 → 报错并给「重试」，重试成功后显示条目', (WidgetTester tester) async {
    server.librariesFail = true;
    await pumpView(tester);
    expect(find.text('Could not load from the server'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    server.librariesFail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Fables'), findsOneWidget);
  });

  testWidgets('空的媒体库 → 「这里还没有内容」', (WidgetTester tester) async {
    server
      ..total = 0
      ..page0 = <Map<String, Object?>>[];
    await pumpView(tester);
    expect(find.text('Nothing here yet'), findsOneWidget);
  });

  testWidgets('切换媒体库：选「Podcasts」后列出播客', (WidgetTester tester) async {
    await pumpView(tester);
    await tester.tap(find.text('Audiobooks'));
    await tester.pumpAndSettle();
    expect(find.text('Choose library'), findsOneWidget);
    await tester.tap(find.text('Podcasts'));
    await tester.pumpAndSettle();
    expect(find.text('The Show'), findsOneWidget);
    expect(find.text('Fables'), findsNothing);
  });

  testWidgets('多台服务器时多一个服务器切换按钮；单台没有', (WidgetTester tester) async {
    await pumpView(tester);
    expect(find.text('Home'), findsNothing);
    final AudiobookshelfServerConfig second = AudiobookshelfServerConfig(
      id: 'srv2',
      name: 'Work',
      serverUrl: Uri.parse('https://abs2.example.com'),
      tokens: const AudiobookshelfTokens(accessToken: 'b'),
    );
    await pumpView(
      tester,
      servers: <AudiobookshelfServerConfig>[config, second],
    );
    expect(find.text(config.displayName), findsOneWidget);
  });

  testWidgets('点书的封面卡 → 进详情页：标题、旁白、「流式播放」按钮', (WidgetTester tester) async {
    await pumpView(tester);
    await tester.tap(find.text('Fables'));
    await tester.pumpAndSettle();
    expect(find.text('Narrated by Reader R'), findsOneWidget);
    expect(find.text('Stream'), findsOneWidget);
  });

  testWidgets('播客详情：单集按发布时间从新到旧，每集可点', (WidgetTester tester) async {
    await pumpView(tester);
    await tester.tap(find.text('Audiobooks'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Podcasts'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('The Show'));
    await tester.pumpAndSettle();

    expect(find.text('Episodes'), findsOneWidget);
    final double newer = tester.getTopLeft(find.text('Newer Episode')).dy;
    final double older = tester.getTopLeft(find.text('Older Episode')).dy;
    expect(newer, lessThan(older));
    expect(find.text('Stream'), findsNothing, reason: '播客是逐集流式，没有整本的按钮');
  });
}
