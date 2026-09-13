/// 发现页里「Fushi 互联」合集的呈现：对端漫画库卡片、对端扩展源卡片 + 「互联 ·
/// 经 <设备>」徽标、热门行行头徽标、下拉选项带「互联」后缀、按源收窄。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/discovery/manga_discovery_models.dart';
import 'package:fushi/src/media/manga/discovery/manga_discovery_page.dart';
import 'package:fushi/src/media/manga/discovery/manga_discovery_source_feeds.dart';
import 'package:fushi/src/media/manga/discovery/manga_source_catalog_section.dart';
import 'package:fushi/src/media/manga/interconnect/interconnect_manga_source_client.dart';
import 'package:fushi/src/media/manga/interconnect/interconnect_source_browse_page.dart';
import 'package:fushi_engine/sync/manga_sources/host_manga_source_host.dart';

class _EmptyProvider implements MangaDiscoveryProvider {
  @override
  Future<MangaDiscoverySnapshot> fetchSnapshot({int perPage = 20}) async =>
      const MangaDiscoverySnapshot(
        feeds: <MangaDiscoveryFeed, List<MangaDiscoveryEntry>>{},
      );

  @override
  void close() {}
}

InterconnectRemoteSource _source(String id, String name, String device) =>
    InterconnectRemoteSource(
      info: RemoteMangaSourceInfo(
        id: id,
        runtime: 'mihon',
        name: name,
        language: 'ja',
      ),
      peer: InterconnectMangaSourcePeer(
        baseUrl: 'http://$device.local',
        token: 't',
        deviceName: device,
        sources: const <RemoteMangaSourceInfo>[],
      ),
    );

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  Widget wrap(Widget child) => ProviderScope(
    child: TranslationProvider(
      child: MaterialApp(home: Scaffold(body: child)),
    ),
  );

  testWidgets('对端库卡片 + 对端源卡片带徽标；热门行行头带徽标；下拉带「互联」后缀', (
    WidgetTester tester,
  ) async {
    final InterconnectRemoteSource rawkuma = _source(
      'mihon:pkg.rawkuma:1',
      'Rawkuma',
      '书房台式机',
    );
    final List<InterconnectRemoteSource> opened = <InterconnectRemoteSource>[];
    await tester.pumpWidget(
      wrap(
        MangaDiscoveryPage(
          provider: _EmptyProvider(),
          catalogOverride: MangaSourceCatalog(
            interconnectLibrary: true,
            interconnectSources: <InterconnectRemoteSource>[rawkuma],
          ),
          sourceFeedsOverride: <MangaDiscoverySourceFeed>[
            MangaDiscoverySourceFeed(
              id: MangaSourceCatalog.interconnectSourceId(rawkuma),
              name: rawkuma.name,
              language: rawkuma.language,
              viaDevice: rawkuma.peer.displayName,
              loadPopular: () async => <MangaDiscoverySourceItem>[
                MangaDiscoverySourceItem(
                  title: '对端热门作品',
                  buildCover: (BuildContext context) =>
                      const ColoredBox(color: Color(0xFF808080)),
                  open: (BuildContext context) => opened.add(rawkuma),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 对端漫画库卡片。
    expect(
      find.byKey(const ValueKey<String>('manga-interconnect-library')),
      findsOneWidget,
    );
    expect(
      find.text(t.manga_source_interconnect_library_title),
      findsOneWidget,
    );
    // 对端源卡片 + 徽标（卡片一处、热门行行头一处 = 两处）。
    expect(
      find.byKey(
        const ValueKey<String>('manga-interconnect-mihon:pkg.rawkuma:1'),
      ),
      findsOneWidget,
    );
    expect(find.byType(InterconnectSourceBadge), findsNWidgets(2));
    expect(
      find.text(
        '${t.manga_discovery_source_interconnect_badge} · '
        '${t.manga_source_interconnect_via_device(device: '书房台式机')}',
      ),
      findsNWidgets(2),
    );
    expect(
      find.text(t.manga_discovery_source_popular(source: 'Rawkuma')),
      findsOneWidget,
    );
    expect(find.text('对端热门作品'), findsOneWidget);

    // 下拉里对端源带「互联」后缀，选中后只剩它自己的卡片、对端库卡片让位。
    await tester.tap(
      find.byKey(const ValueKey<String>('discovery_source_menu')),
    );
    await tester.pumpAndSettle();
    final String label =
        'Rawkuma · ${t.manga_discovery_source_interconnect_badge}';
    await tester.tap(find.widgetWithText(MenuItemButton, label).last);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('manga-interconnect-library')),
      findsNothing,
    );
    expect(
      find.byKey(
        const ValueKey<String>('manga-interconnect-mihon:pkg.rawkuma:1'),
      ),
      findsOneWidget,
    );
  });

  test('MangaSourceCatalog：isEmpty / filterById 认得互联两类来源', () {
    final InterconnectRemoteSource a = _source('mihon:a:1', 'A', 'd');
    final InterconnectRemoteSource b = _source('mihon:b:2', 'B', 'd');
    final MangaSourceCatalog catalog = MangaSourceCatalog(
      interconnectLibrary: true,
      interconnectSources: <InterconnectRemoteSource>[a, b],
    );
    expect(catalog.isEmpty, isFalse);
    expect(const MangaSourceCatalog().isEmpty, isTrue);
    expect(catalog.sourceOptions.map((o) => o.id), <String>[
      'interconnect:mihon:a:1',
      'interconnect:mihon:b:2',
    ]);
    final MangaSourceCatalog narrowed = catalog.filterById(
      'interconnect:mihon:b:2',
    );
    expect(narrowed.interconnectLibrary, isFalse);
    expect(narrowed.interconnectSources.single.id, 'mihon:b:2');
    expect(catalog.filterById('').interconnectSources, hasLength(2));
  });
}
