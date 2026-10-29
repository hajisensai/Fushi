import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/discovery/audiobookshelf_server_config.dart';
import 'package:fushi/src/media/kavita/kavita_server_config.dart';
import 'package:fushi/src/media/manga/manga_library_page.dart';
import 'package:fushi/src/pages/implementations/media_library_shell.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_server_list_view.dart';
import 'package:fushi/src/pages/implementations/media_server/user_media_servers_view.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_models.dart';

/// 书 / 漫画「媒体服务器」页签：只在配了可用服务器时出现（随配置变化出现 /
/// 消失），行与视频域同一个列表组件。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  KavitaServerConfig kavita(String id, {String key = 'k'}) =>
      KavitaServerConfig(
        id: id,
        name: 'Kav $id',
        serverUrl: Uri.parse('https://kavita.example.com'),
        apiKey: key,
      );

  AudiobookshelfServerConfig abs(String id, {bool signedIn = true}) =>
      AudiobookshelfServerConfig(
        id: id,
        name: 'Abs $id',
        serverUrl: Uri.parse('https://abs.example.com'),
        username: 'u',
        tokens: signedIn
            ? const AudiobookshelfTokens(accessToken: 'a', refreshToken: 'r')
            : null,
      );

  group('hasUserMediaServers（页签门）', () {
    test('没配 / 只有不可用的服务器：书、漫画都没有页签', () {
      for (final UserMediaServersDomain d in UserMediaServersDomain.values) {
        expect(
          hasUserMediaServers(
            d,
            kavita: const <KavitaServerConfig>[],
            audiobookshelf: const <AudiobookshelfServerConfig>[],
          ),
          isFalse,
        );
        expect(
          hasUserMediaServers(
            d,
            kavita: <KavitaServerConfig>[kavita('1', key: '')],
            audiobookshelf: <AudiobookshelfServerConfig>[
              abs('a', signedIn: false),
            ],
          ),
          isFalse,
          reason: '没 API key 的 Kavita、未登录的 ABS 都不算',
        );
      }
    });

    test('书：可用 Kavita 或已登录 ABS 任一即出现', () {
      expect(
        hasUserMediaServers(
          UserMediaServersDomain.book,
          kavita: <KavitaServerConfig>[kavita('1')],
          audiobookshelf: const <AudiobookshelfServerConfig>[],
        ),
        isTrue,
      );
      expect(
        hasUserMediaServers(
          UserMediaServersDomain.book,
          kavita: const <KavitaServerConfig>[],
          audiobookshelf: <AudiobookshelfServerConfig>[abs('a')],
        ),
        isTrue,
      );
    });

    test('漫画：只认 Kavita，只配了 ABS 不出页签', () {
      expect(
        hasUserMediaServers(
          UserMediaServersDomain.manga,
          kavita: const <KavitaServerConfig>[],
          audiobookshelf: <AudiobookshelfServerConfig>[abs('a')],
        ),
        isFalse,
      );
      expect(
        hasUserMediaServers(
          UserMediaServersDomain.manga,
          kavita: <KavitaServerConfig>[kavita('1')],
          audiobookshelf: const <AudiobookshelfServerConfig>[],
        ),
        isTrue,
      );
    });
  });

  group('userMediaServerRows', () {
    testWidgets('书：可用 Kavita + 已登录 ABS；漫画：只有 Kavita', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const SizedBox.shrink());
      final BuildContext context = tester.element(find.byType(SizedBox));
      final List<KavitaServerConfig> k = <KavitaServerConfig>[
        kavita('1'),
        kavita('2', key: ''),
      ];
      final List<AudiobookshelfServerConfig> a = <AudiobookshelfServerConfig>[
        abs('a'),
        abs('b', signedIn: false),
      ];
      expect(
        userMediaServerRows(
          context,
          UserMediaServersDomain.book,
          kavita: k,
          audiobookshelf: a,
          apiFor: (_) => null,
        ).map((MediaServerListRowData r) => r.id),
        <String>['kavita-1', 'abs-a'],
      );
      final List<MediaServerListRowData> manga = userMediaServerRows(
        context,
        UserMediaServersDomain.manga,
        kavita: k,
        audiobookshelf: a,
        apiFor: (_) => null,
      );
      expect(manga.map((MediaServerListRowData r) => r.id), <String>[
        'kavita-1',
      ]);
      expect(manga.single.kindLabel, 'Kavita');
    });
  });

  group('共用列表组件 MediaServerGroupedList', () {
    Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

    testWidgets('每台一行 + 组下方「去设置添加服务器」行', (WidgetTester tester) async {
      int settings = 0;
      int opened = 0;
      await tester.pumpWidget(
        host(
          MediaServerGroupedList(
            top: 0,
            onOpenSettings: () => settings++,
            rows: <MediaServerListRowData>[
              MediaServerListRowData(
                id: 'kavita-1',
                name: 'Kav 1',
                url: 'https://kavita.example.com',
                kindLabel: 'Kavita',
                icon: Icons.book,
                onTap: () => opened++,
              ),
              MediaServerListRowData(
                id: 'abs-a',
                name: 'Abs a',
                url: 'https://abs.example.com',
                kindLabel: 'Audiobookshelf',
                icon: Icons.dns,
                accountName: 'u',
                onTap: () {},
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('media-server-card-kavita-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('media-server-card-abs-a')),
        findsOneWidget,
      );
      expect(find.text('Audiobookshelf'), findsOneWidget);
      expect(find.text('u'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey<String>('media-server-card-kavita-1')),
      );
      expect(opened, 1);
      await tester.tap(
        find.byKey(const ValueKey<String>('media-server-list-add')),
      );
      expect(settings, 1);
    });

    testWidgets('空态给出去设置入口', (WidgetTester tester) async {
      int settings = 0;
      await tester.pumpWidget(
        host(MediaServerListEmpty(top: 0, onOpenSettings: () => settings++)),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('media-server-list-go-settings')),
      );
      expect(settings, 1);
    });
  });

  testWidgets('漫画库页：未配置 Kavita 时没有「媒体服务器」页签，配置后出现、删掉后消失', (
    WidgetTester tester,
  ) async {
    final StateProvider<bool> configured = StateProvider<bool>((_) => false);
    MediaLibraryShell? built;
    late WidgetRef outerRef;
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          userMediaServersAvailableProvider(
            UserMediaServersDomain.manga,
          ).overrideWith((Ref ref) => ref.watch(configured)),
        ],
        child: Consumer(
          builder: (BuildContext context, WidgetRef ref, Widget? _) {
            outerRef = ref;
            built =
                const MangaLibraryPage().build(context, ref)
                    as MediaLibraryShell;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    List<MediaLibraryViewKind> kinds() =>
        built!.views.map((MediaLibraryViewSpec v) => v.kind).toList();

    expect(kinds(), isNot(contains(MediaLibraryViewKind.mediaServers)));

    outerRef.read(configured.notifier).state = true;
    await tester.pump();
    expect(kinds(), contains(MediaLibraryViewKind.mediaServers));

    outerRef.read(configured.notifier).state = false;
    await tester.pump();
    expect(kinds(), isNot(contains(MediaLibraryViewKind.mediaServers)));
  });
}
