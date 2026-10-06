import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/torrent/torrent_network_issue_banner.dart';
import 'package:fushi_engine/media/torrent/torrent_network_diagnosis.dart';

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  Widget buildApp(Widget child) {
    return TranslationProvider(
      child:
          MaterialApp(home: Scaffold(body: Column(children: <Widget>[child]))),
    );
  }

  testWidgets('BUG-2950：none 不渲染任何内容、不占高度', (WidgetTester tester) async {
    await tester.pumpWidget(
      buildApp(
        const TorrentNetworkIssueBanner(
          issue: TorrentNetworkIssue.none,
          margin: EdgeInsets.all(12),
        ),
      ),
    );

    expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
    expect(find.text(t.download_network_fake_ip_udp_blocked), findsNothing);
    expect(find.text(t.download_network_dht_unreachable), findsNothing);
    expect(
      tester.getSize(find.byType(TorrentNetworkIssueBanner)).height,
      0,
    );
    expect(torrentNetworkIssueMessage(TorrentNetworkIssue.none), isNull);
  });

  testWidgets('BUG-2950：fake-ip 掐 UDP 显示代理不转发 UDP 的说明', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      buildApp(
        const TorrentNetworkIssueBanner(
          issue: TorrentNetworkIssue.fakeIpUdpBlocked,
        ),
      ),
    );

    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    expect(find.text(t.download_network_fake_ip_udp_blocked), findsOneWidget);
    expect(find.text(t.download_network_dht_unreachable), findsNothing);
  });

  testWidgets('BUG-2950：DHT 不可达显示出站 UDP 被拦的说明', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      buildApp(
        const TorrentNetworkIssueBanner(
          issue: TorrentNetworkIssue.dhtUnreachable,
        ),
      ),
    );

    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    expect(find.text(t.download_network_dht_unreachable), findsOneWidget);
    expect(find.text(t.download_network_fake_ip_udp_blocked), findsNothing);
  });

  testWidgets('BUG-2950：随 ValueListenable 切换', (WidgetTester tester) async {
    final ValueNotifier<TorrentNetworkIssue> issue =
        ValueNotifier<TorrentNetworkIssue>(TorrentNetworkIssue.none);
    addTearDown(issue.dispose);
    await tester.pumpWidget(
      buildApp(
        ValueListenableBuilder<TorrentNetworkIssue>(
          valueListenable: issue,
          builder: (BuildContext context, TorrentNetworkIssue value, _) =>
              TorrentNetworkIssueBanner(issue: value),
        ),
      ),
    );
    expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);

    issue.value = TorrentNetworkIssue.fakeIpUdpBlocked;
    await tester.pump();
    expect(find.text(t.download_network_fake_ip_udp_blocked), findsOneWidget);

    issue.value = TorrentNetworkIssue.none;
    await tester.pump();
    expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
  });
}
