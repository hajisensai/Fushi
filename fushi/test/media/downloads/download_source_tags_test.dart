import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/downloads/download_source_method.dart';
import 'package:fushi/src/media/downloads/download_task_card.dart';
import 'package:fushi/src/media/downloads/manga_download_tasks_section.dart';
import 'package:fushi/src/media/manga/download/manga_download_service.dart'
    show kMokuroMoeDownloadRuntime;
import 'package:fushi/src/models/preference_keys.dart';
import 'package:fushi/src/pages/implementations/download_notice.dart';
import 'package:fushi/src/profile/profile_keys.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart';

// 10-09 所有者：每个下载结果 / 任务都要标出下载方式（BT / 直链 / 扩展源）与
// 「外部来源」，首次 BT 下载前给一次 P2P 说明、首次从第三方游戏资源站下载前给一次
// 风险说明（同一个说明框按 kind 换文案；可勾「不再提示」，默认不勾）。

Widget _host(Widget child) => TranslationProvider(
  child: MaterialApp(
    theme: ThemeData(useMaterial3: true),
    home: Scaffold(body: Center(child: child)),
  ),
);

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  group('download method mapping', () {
    test('discovery payload kind maps to BT or direct', () {
      expect(
        discoveryTransferMethodOf(DiscoveryPayloadKind.torrent),
        DownloadTransferMethod.torrent,
      );
      expect(
        discoveryTransferMethodOf(DiscoveryPayloadKind.httpFile),
        DownloadTransferMethod.direct,
      );
    });

    test('manga download runtime maps to method and external flag', () {
      expect(mangaDownloadSourceOf('mihon'), (
        method: DownloadTransferMethod.extension,
        external: true,
      ));
      expect(mangaDownloadSourceOf('aidoku'), (
        method: DownloadTransferMethod.extension,
        external: true,
      ));
      expect(mangaDownloadSourceOf(kMokuroMoeDownloadRuntime), (
        method: DownloadTransferMethod.direct,
        external: true,
      ));
      // 互联对端是用户自己的设备：HTTP 拉取，不算外部来源。
      expect(mangaDownloadSourceOf('interconnect'), (
        method: DownloadTransferMethod.direct,
        external: false,
      ));
    });

    test('the notice preference is a known, per-install key', () {
      for (final String key in <String>[
        'p2p_download_notice_dismissed',
        'game_resource_notice_dismissed',
      ]) {
        expect(kKnownPreferenceKeys, contains(key));
        expect(ProfileKeys.isExcludedPref(key), isTrue);
      }
    });
  });

  group('DownloadTaskCard source tags', () {
    testWidgets('renders the method and external tags', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const DownloadTaskCard(
            taskId: 'a',
            title: 'Some torrent',
            status: 'Downloading',
            details: SizedBox.shrink(),
            method: DownloadTransferMethod.torrent,
            externalSource: true,
          ),
        ),
      );
      expect(find.text(t.download_method_torrent), findsOneWidget);
      expect(find.text(t.download_source_external), findsOneWidget);
    });

    testWidgets('own-device direct download has no external tag', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const DownloadTaskCard(
            taskId: 'b',
            title: 'From my PC',
            status: 'Downloading',
            details: SizedBox.shrink(),
            method: DownloadTransferMethod.direct,
          ),
        ),
      );
      expect(find.text(t.download_method_direct), findsOneWidget);
      expect(find.text(t.download_source_external), findsNothing);
    });

    testWidgets('a non-download task shows no tags', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const DownloadTaskCard(
            taskId: 'c',
            title: 'Transcribe',
            status: 'Running',
            details: SizedBox.shrink(),
          ),
        ),
      );
      for (final DownloadTransferMethod m in DownloadTransferMethod.values) {
        expect(find.text(m.label), findsNothing);
      }
    });
  });

  group('P2P download notice', () {
    Future<DownloadNoticeResult?> open(
      WidgetTester tester,
      Future<void> Function() interact, {
      DownloadNoticeKind kind = DownloadNoticeKind.p2p,
    }) async {
      DownloadNoticeResult? result;
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () async {
                result = await showDialog<DownloadNoticeResult>(
                  context: context,
                  builder: (_) => DownloadNoticeDialog(kind: kind),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await interact();
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('"don\'t show again" starts unchecked', (
      WidgetTester tester,
    ) async {
      final DownloadNoticeResult? result = await open(tester, () async {
        expect(find.text(t.download_p2p_notice_body), findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey<String>('download-notice-continue')),
        );
      });
      expect(result?.proceed, isTrue);
      expect(result?.dontShowAgain, isFalse);
    });

    testWidgets('ticking the box is reported on continue', (
      WidgetTester tester,
    ) async {
      final DownloadNoticeResult? result = await open(tester, () async {
        final Finder box = find.byKey(
          const ValueKey<String>('download-notice-dont-show'),
        );
        await tester.ensureVisible(box);
        await tester.pumpAndSettle();
        await tester.tap(box);
        await tester.pump();
        await tester.tap(
          find.byKey(const ValueKey<String>('download-notice-continue')),
        );
      });
      expect(result?.proceed, isTrue);
      expect(result?.dontShowAgain, isTrue);
    });

    testWidgets('cancel aborts the download', (WidgetTester tester) async {
      final DownloadNoticeResult? result = await open(tester, () async {
        await tester.tap(
          find.byKey(const ValueKey<String>('download-notice-cancel')),
        );
      });
      expect(result?.proceed, isFalse);
    });

    testWidgets('without an app model the notice never blocks a download', (
      WidgetTester tester,
    ) async {
      late BuildContext captured;
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (BuildContext context) {
              captured = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(await confirmP2pDownloadNotice(captured), isTrue);
      expect(
        await confirmDownloadNotice(captured, DownloadNoticeKind.gameResource),
        isTrue,
      );
    });

    testWidgets('game resource notice shows the risk text and external tag', (
      WidgetTester tester,
    ) async {
      final DownloadNoticeResult? result = await open(tester, () async {
        expect(find.text(t.download_game_notice_title), findsOneWidget);
        expect(find.text(t.download_game_notice_body), findsOneWidget);
        expect(find.text(t.download_source_external), findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey<String>('download-notice-continue')),
        );
      }, kind: DownloadNoticeKind.gameResource);
      expect(result?.proceed, isTrue);
      expect(result?.dontShowAgain, isFalse);
    });
  });
}
