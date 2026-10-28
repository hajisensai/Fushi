import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/discovery/audiobookshelf_server_config.dart';
import 'package:fushi/src/media/kavita/kavita_server_config.dart';
import 'package:fushi/src/pages/implementations/media_server/book_media_servers_view.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_models.dart';

/// 书 / 漫画「媒体服务器」页签：Kavita + ABS 条目、去设置行、空态。
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

  Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

  test('book entries: usable Kavita + signed-in ABS only', () {
    final List<MediaServerLinkEntry> entries = bookMediaServerEntries(
      kavita: <KavitaServerConfig>[
        kavita('1'),
        kavita('2', key: ''),
      ],
      audiobookshelf: <AudiobookshelfServerConfig>[
        abs('a'),
        abs('b', signedIn: false),
      ],
      apiFor: (_) => null,
    );
    expect(entries.map((MediaServerLinkEntry e) => e.id), <String>[
      'kavita-1',
      'abs-a',
    ]);
  });

  test('manga entries: Kavita only', () {
    final List<MediaServerLinkEntry> entries = mangaMediaServerEntries(
      kavita: <KavitaServerConfig>[kavita('1')],
    );
    expect(entries, hasLength(1));
    expect(entries.single.kindLabel, 'Kavita');
  });

  testWidgets('lists rows and an add-server row', (WidgetTester tester) async {
    int settings = 0;
    await tester.pumpWidget(
      host(
        MediaServersListView(
          entries: bookMediaServerEntries(
            kavita: <KavitaServerConfig>[kavita('1')],
            audiobookshelf: <AudiobookshelfServerConfig>[abs('a')],
            apiFor: (_) => null,
          ),
          onOpenSettings: (_) => settings++,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('media-servers-row-kavita-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('media-servers-row-abs-a')),
      findsOneWidget,
    );
    expect(find.text('Audiobookshelf'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('media-servers-add')));
    expect(settings, 1);
  });

  testWidgets('empty state offers go-to-settings', (WidgetTester tester) async {
    int settings = 0;
    await tester.pumpWidget(
      host(
        MediaServersListView(
          entries: const <MediaServerLinkEntry>[],
          onOpenSettings: (_) => settings++,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('media-servers-go-settings')),
    );
    expect(settings, 1);
  });
}
