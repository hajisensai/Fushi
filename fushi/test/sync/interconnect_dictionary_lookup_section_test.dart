import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/sync/interconnect_dictionary_lookup_section.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart' show RemoteDictionaryMetaRow;

/// 「配对与设备」里每台 host 的「用这台服务器查词典」（设计稿 3）：开关整组写
/// [FushiClientUrl.lookupEnabled]、摘要行、刷新；以及关掉的 host 在新增 / 改地址后
/// 不会悄悄重新参与查词。
const List<FushiClientUrl> _urls = <FushiClientUrl>[
  FushiClientUrl(
    url: 'https://192.168.1.10:38765',
    hostId: 'h1',
    deviceName: 'Box',
    token: 'tok',
    fingerprintSha256: 'aa:bb',
  ),
  FushiClientUrl(
    url: 'https://[fd00::10]:38765',
    hostId: 'h1',
    deviceName: 'Box',
    learned: true,
  ),
  FushiClientUrl(url: 'http://10.0.0.5:38765', hostId: 'h2', deviceName: 'NAS'),
];

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  test(
    'withInterconnectHostLookupEnabled writes every address of the host',
    () {
      final List<FushiClientUrl> off = withInterconnectHostLookupEnabled(
        _urls,
        'h1',
        false,
      );
      expect(off.map((FushiClientUrl u) => u.lookupEnabled).toList(), <bool>[
        false,
        false,
        true,
      ]);
      // copyWith：指纹 / 令牌 / 学习标记原样保留。
      expect(off.first.fingerprintSha256, 'aa:bb');
      expect(off.first.token, 'tok');
      expect(off[1].learned, isTrue);
      expect(interconnectHostLookupEnabled(off, 'h1'), isFalse);
      expect(interconnectHostLookupEnabled(off, 'h2'), isTrue);
      // 没有变化时原样返回（调用方据此不落库）。
      expect(
        identical(withInterconnectHostLookupEnabled(off, 'h1', false), off),
        isTrue,
      );
    },
  );

  test('new addresses of a host switched off inherit the off state', () {
    final List<FushiClientUrl> before = withInterconnectHostLookupEnabled(
      _urls,
      'h1',
      false,
    );
    // 学到一条新地址（同一台 h1）+ 手动加一条还没归组的地址。
    final List<FushiClientUrl> after =
        inheritInterconnectLookupDisabled(before, <FushiClientUrl>[
          ...before,
          const FushiClientUrl(url: 'https://100.64.0.10:38765', hostId: 'h1'),
          const FushiClientUrl(url: 'http://192.168.1.99:38765'),
        ]);
    expect(after[3].lookupEnabled, isFalse);
    // 没有 hostId 的新地址不属于 h1，不跟着关。
    expect(after[4].lookupEnabled, isTrue);
    // h2 开着：照常。
    expect(after[2].lookupEnabled, isTrue);

    // 配对后那条未归组的地址拿到 h1 的身份：同样继承关掉。
    final List<FushiClientUrl> paired =
        inheritInterconnectLookupDisabled(after, <FushiClientUrl>[
          for (final FushiClientUrl u in after)
            u.url == 'http://192.168.1.99:38765' ? u.copyWith(hostId: 'h1') : u,
        ]);
    expect(paired[4].lookupEnabled, isFalse);

    // 用户在设置页把整组打开：原有地址的值不被改回去。
    final List<FushiClientUrl> reopened = withInterconnectHostLookupEnabled(
      paired,
      'h1',
      true,
    );
    expect(
      identical(inheritInterconnectLookupDisabled(paired, reopened), reopened),
      isTrue,
    );

    // 只要 h1 还有一条开着，新地址保持默认开。
    final List<FushiClientUrl> mixed = <FushiClientUrl>[before.first, _urls[1]];
    expect(
      inheritInterconnectLookupDisabled(mixed, <FushiClientUrl>[
        ...mixed,
        const FushiClientUrl(url: 'https://100.64.0.10:38765', hostId: 'h1'),
      ]).last.lookupEnabled,
      isTrue,
    );
  });

  test('summaries count hosted dictionaries and the last refresh', () {
    RemoteDictionaryMetaRow row(
      String host,
      String name,
      int seen, {
      int? gone,
    }) => RemoteDictionaryMetaRow(
      hostId: host,
      name: name,
      type: 'term',
      lastSeenAt: seen,
      missingSince: gone,
      order: 0,
      hidden: false,
    );
    final Map<String, InterconnectHostDictionarySummary> s =
        interconnectHostDictionarySummariesOf(<RemoteDictionaryMetaRow>[
          row('h1', 'A', 100),
          row('h1', 'B', 300),
          row('h1', 'Gone', 50, gone: 300),
          row('h2', 'C', 200),
        ]);
    expect(s['h1']!.hosted, 2);
    expect(s['h1']!.lastRefreshedAt, 300);
    expect(s['h2']!.hosted, 1);
    expect(s.containsKey('h3'), isFalse);
  });

  testWidgets(
    'switch row writes lookupEnabled for that host; refresh per host',
    (WidgetTester tester) async {
      List<FushiClientUrl> urls = _urls;
      final List<String> refreshed = <String>[];
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            theme: buildFushiFallbackTheme(
              Brightness.light,
            ).copyWith(platform: TargetPlatform.windows),
            home: Scaffold(
              body: StatefulBuilder(
                builder: (BuildContext context, StateSetter setState) =>
                    SingleChildScrollView(
                      child: InterconnectDictionaryLookupSection(
                        urls: urls,
                        summaries:
                            const <String, InterconnectHostDictionarySummary>{
                              'h1': InterconnectHostDictionarySummary(
                                hosted: 3,
                                lastRefreshedAt: null,
                              ),
                            },
                        refreshingHosts: const <String>{},
                        onLookupChanged: (String hostId, bool enabled) =>
                            setState(
                              () => urls = withInterconnectHostLookupEnabled(
                                urls,
                                hostId,
                                enabled,
                              ),
                            ),
                        onRefresh: refreshed.add,
                      ),
                    ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      // 一台 host 一组（h1 的两条地址合并）。
      expect(
        find.byKey(const ValueKey<String>('interconnect-lookup-switch-h1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('interconnect-lookup-switch-h2')),
        findsOneWidget,
      );
      expect(
        find.text('Use this server for dictionary lookups'),
        findsNWidgets(2),
      );
      expect(
        find.text(
          'Only affects dictionary lookups. Sync, profile transfer and other '
          'features keep working.',
        ),
        findsNWidgets(2),
      );
      expect(
        find.text('Dictionaries available: 3 hosted · last refreshed Never'),
        findsOneWidget,
      );

      Future<void> focusInside(Finder target) async {
        final Element leaf = tester.element(
          find
              .descendant(
                of: target,
                matching: find.byWidgetPredicate((_) => true),
              )
              .last,
        );
        Focus.of(leaf).requestFocus();
        await tester.pump();
      }

      final Finder h1Switch = find.descendant(
        of: find.byKey(const ValueKey<String>('interconnect-lookup-switch-h1')),
        matching: find.byType(Switch),
      );
      await focusInside(h1Switch);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(urls.map((FushiClientUrl u) => u.lookupEnabled).toList(), <bool>[
        false,
        false,
        true,
      ]);

      await focusInside(
        find.byKey(const ValueKey<String>('interconnect-lookup-refresh-h2')),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(refreshed, <String>['h2']);
    },
  );

  group('one intent, one switch (applyInterconnectHostLookupIntent)', () {
    Future<({List<FushiClientUrl> urls, List<bool> globalWrites})> run({
      required List<FushiClientUrl> start,
      required String hostId,
      required bool enabled,
      required bool global,
    }) async {
      List<FushiClientUrl> urls = start;
      final List<bool> globalWrites = <bool>[];
      await applyInterconnectHostLookupIntent(
        hostId: hostId,
        enabled: enabled,
        mutateUrls:
            (List<FushiClientUrl> Function(List<FushiClientUrl>) transform) async {
              urls = transform(urls);
            },
        remoteLookupEnabled: global,
        setRemoteLookupEnabled: (bool value) async => globalWrites.add(value),
      );
      return (urls: urls, globalWrites: globalWrites);
    }

    test('turning a host on also turns on remote lookup when it is off', () async {
      final List<FushiClientUrl> off = withInterconnectHostLookupEnabled(
        _urls,
        'h1',
        false,
      );
      final r = await run(start: off, hostId: 'h1', enabled: true, global: false);
      expect(interconnectHostLookupEnabled(r.urls, 'h1'), isTrue);
      expect(r.globalWrites, <bool>[true]);
    });

    test('global setting already on: only the pairing is written', () async {
      final List<FushiClientUrl> off = withInterconnectHostLookupEnabled(
        _urls,
        'h1',
        false,
      );
      final r = await run(start: off, hostId: 'h1', enabled: true, global: true);
      expect(interconnectHostLookupEnabled(r.urls, 'h1'), isTrue);
      expect(r.globalWrites, isEmpty);
    });

    test('switching the last host off leaves the global setting alone', () async {
      List<FushiClientUrl> urls = withInterconnectHostLookupEnabled(
        _urls,
        'h2',
        false,
      );
      final r = await run(start: urls, hostId: 'h1', enabled: false, global: true);
      urls = r.urls;
      expect(interconnectHostLookupEnabled(urls, 'h1'), isFalse);
      expect(interconnectHostLookupEnabled(urls, 'h2'), isFalse);
      expect(r.globalWrites, isEmpty);
    });
  });

  test('added peers: device name is the title, the URL the subtitle', () {
    expect(interconnectPeerRowLabels(_urls.first), (
      title: 'Box',
      url: 'https://192.168.1.10:38765',
    ));
    expect(
      interconnectPeerRowLabels(
        const FushiClientUrl(url: 'http://10.0.0.9:38765', deviceName: '  '),
      ),
      (title: 'http://10.0.0.9:38765', url: null),
    );
  });

  testWidgets('switch subtitle says it also turns on remote lookup when off', (
    WidgetTester tester,
  ) async {
    Future<void> pump({required bool remoteLookupEnabled}) =>
        tester.pumpWidget(
          TranslationProvider(
            child: MaterialApp(
              theme: buildFushiFallbackTheme(
                Brightness.light,
              ).copyWith(platform: TargetPlatform.windows),
              home: Scaffold(
                body: SingleChildScrollView(
                  child: InterconnectDictionaryLookupSection(
                    urls: _urls.take(1).toList(),
                    summaries: const <String, InterconnectHostDictionarySummary>{},
                    refreshingHosts: const <String>{},
                    remoteLookupEnabled: remoteLookupEnabled,
                    onLookupChanged: (String hostId, bool enabled) {},
                    onRefresh: null,
                  ),
                ),
              ),
            ),
          ),
        );
    await pump(remoteLookupEnabled: false);
    await tester.pump();
    expect(
      find.textContaining('Also turns on remote dictionary lookup'),
      findsOneWidget,
    );
    await pump(remoteLookupEnabled: true);
    await tester.pump();
    expect(
      find.textContaining('Also turns on remote dictionary lookup'),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}
