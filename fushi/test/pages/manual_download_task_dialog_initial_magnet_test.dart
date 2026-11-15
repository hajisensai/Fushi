import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/manual_download_task_dialog.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart'
    show DiscoveryMediaKind;
import '../helpers/glass_unwrap.dart';
import '../helpers/source_guard.dart';

/// BUG-4386（反馈 xAeextyOV1）：视频源扩展（Torrentio）给的是磁链。播放页不再把它当
/// 本地文件交给 libmpv，而是把磁链交给下载管线——入口就是下载中心的「添加任务」框，
/// 经 `initialMagnet` / `initialTitle` 预填，与用户自己粘贴同一条提交路径。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  const String magnet =
      'magnet:?xt=urn:btih:72723c6e45267b82cdd8241825425c4f7310cf32'
      '&dn=72723c6e45267b82cdd8241825425c4f7310cf32&index=0';

  Widget harness(Widget child) => TranslationProvider(
    child: MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: Scaffold(body: Center(child: child)),
    ),
  );

  String fieldText(WidgetTester tester, String key) => tester
      .widget<TextField>(
        glassUnwrap<TextField>(find.byKey(ValueKey<String>(key))),
      )
      .controller!
      .text;

  // 非视频域：视频域那一行并排下拉在 Ahem 字体下横向溢出（与 torrent_drop 测试同因）。
  ManualDownloadTaskDialog dialog({String? title}) => ManualDownloadTaskDialog(
    pipeline: null,
    target: null,
    sources: const [],
    defaultSourceId: null,
    initialDiscoveryKind: DiscoveryMediaKind.novel,
    initialMagnet: magnet,
    initialTitle: title,
  );

  testWidgets('initialMagnet + initialTitle prefill the magnet pane', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(harness(dialog(title: 'Fixture Show - Episode 1')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('manual-task-magnet-pane')),
      findsOneWidget,
    );
    expect(fieldText(tester, 'manual-task-magnet'), magnet);
    // 外部给的标题优先于磁链 dn（Torrentio 的 dn 就是 infoHash，用户认不出）。
    expect(fieldText(tester, 'manual-task-title'), 'Fixture Show - Episode 1');
    // 框里已有磁链：不再提示「使用剪贴板里的磁链」。
    expect(
      find.byKey(const ValueKey<String>('manual-task-clipboard-magnet')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('without initialTitle the magnet dn is the fallback title', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(harness(dialog()));
    await tester.pumpAndSettle();
    expect(
      fieldText(tester, 'manual-task-title'),
      '72723c6e45267b82cdd8241825425c4f7310cf32',
    );
  });

  group('播放页把视频源的种子交给下载管线（源码守卫）', () {
    final String page = File(
      'lib/src/pages/implementations/video_fushi_page.dart',
    ).readAsStringSync();

    test('remote-episode failure keeps the torrent payload', () {
      expect(
        compactCode(page),
        contains(
          '_failTorrentVideo=eisAnimeSourceTorrentVideoException?e:null;',
        ),
      );
      expect(
        compactCode(methodBody(page, 'String _describeLoadFailure(')),
        contains(
          'if(errorisAnimeSourceTorrentVideoException){'
          'returnt.video_online_stream_torrent;}',
        ),
      );
    });

    test('failure body offers the download only where downloads exist', () {
      final String body = compactCode(
        methodBody(page, 'Widget _buildFailedBody('),
      );
      expect(
        body,
        contains(
          'torrent!=null&&StoreRestrictedCapability.downloads.isAvailable',
        ),
      );
      expect(body, contains('_downloadTorrentVideo(torrent)'));
      final String action = compactCode(
        methodBody(page, 'Future<void> _downloadTorrentVideo('),
      );
      expect(
        action,
        contains('if(!StoreRestrictedCapability.downloads.isAvailable)return;'),
      );
      expect(action, contains('showManualDownloadTaskDialog('));
      expect(action, contains('initialMagnet:torrent.magnetUri'));
      expect(action, contains('initialTitle:torrent.title'));
    });

    test('every reset of the failure reason also drops the torrent', () {
      // 播放页的状态散在主文件和 `video_fushi/*.part.dart` 里，part 文件同样写
      // `_failReason`，守卫必须一起扫，否则 part 里漏清 `_failTorrentVideo` 测不出。
      final List<File> sources = <File>[
        File('lib/src/pages/implementations/video_fushi_page.dart'),
        ...Directory('lib/src/pages/implementations/video_fushi')
            .listSync()
            .whereType<File>()
            .where((File f) => f.path.endsWith('.part.dart')),
      ];
      expect(sources.length, greaterThan(1));
      int totalResets = 0;
      for (final File source in sources) {
        final String code = maskComments(source.readAsStringSync());
        final int resets = RegExp(
          r'_failReason\s*=\s*null;',
        ).allMatches(code).length;
        final int torrentResets = RegExp(
          r'_failReason\s*=\s*null;\s*_failTorrentVideo\s*=\s*null;',
        ).allMatches(code).length;
        expect(torrentResets, resets, reason: source.path);
        totalResets += resets;
      }
      expect(totalResets, greaterThan(0));
    });
  });
}
