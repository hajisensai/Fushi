import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/drag_drop/fushi_file_drop_target.dart';
import 'package:fushi/src/pages/implementations/manual_download_task_dialog.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart'
    show DiscoveryMediaKind;
import 'package:path/path.dart' as p;

/// 拖入 `.torrent` 种子的三条入口都汇到 [ManualDownloadTaskDialog]：
///
/// - 库页 / 下载页拖入 → `initialTorrentPath` 预填（开框即读文件、填文件名与标题）；
/// - 框开着时再拖一个种子进来 → `_handleDialogDrop` 替换所选；
/// - 坏文件 → 与选择器同一条 `download_task_add_invalid` 提示，框不关。
///
/// 另有一组源码守卫钉住三个落点页面确实把 `DropIntent.importTorrent` 接到了
/// 这个对话框上——穷尽 switch 只能保证「列出了」，保证不了「没写成 break」。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  late Directory tmp;
  late String validTorrent;
  late String otherTorrent;
  late String brokenTorrent;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('fushi-torrent-drop-');
    // 最小合法 v1 metainfo：info.name = "test"。
    validTorrent = p.join(tmp.path, 'first.torrent');
    File(validTorrent).writeAsBytesSync(
      utf8.encode(
        'd4:infod6:lengthi1e4:name4:test6:pieces20:aaaaaaaaaaaaaaaaaaaaee',
      ),
    );
    otherTorrent = p.join(tmp.path, 'second.torrent');
    File(otherTorrent).writeAsBytesSync(
      utf8.encode(
        'd4:infod6:lengthi1e4:name5:other6:pieces20:aaaaaaaaaaaaaaaaaaaaee',
      ),
    );
    brokenTorrent = p.join(tmp.path, 'broken.torrent');
    File(brokenTorrent).writeAsStringSync('this is not bencode');
  });

  tearDownAll(() => tmp.deleteSync(recursive: true));

  Widget harness(Widget child) {
    return TranslationProvider(
      child: MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(body: Center(child: child)),
      ),
    );
  }

  /// 默认用非视频域：视频域那一行「媒体类型 + 字幕策略」两个并排下拉在测试的
  /// Ahem 字体（每字 14px 见方）下必然横向溢出、把无关的 RenderFlex 异常算到本
  /// 测试头上；种子读取/替换/报错与内容类型无关，第一条测试已单独钉住类型预填。
  ManualDownloadTaskDialog dialog({
    String? initialTorrentPath,
    DiscoveryMediaKind initialDiscoveryKind = DiscoveryMediaKind.novel,
  }) {
    return ManualDownloadTaskDialog(
      pipeline: null,
      target: null,
      sources: const [],
      defaultSourceId: null,
      initialTorrentPath: initialTorrentPath,
      initialDiscoveryKind: initialDiscoveryKind,
    );
  }

  String titleText(WidgetTester tester) => tester
      .widget<TextField>(
          find.byKey(const ValueKey<String>('manual-task-title')))
      .controller!
      .text;

  /// 对话框读种子是**真实文件 IO**：FakeAsync 下永远不回来，必须 runAsync 包住。
  /// 首次读临时文件在 Windows 上实测可能超过 50ms（杀软扫描），固定短睡会假红、
  /// 固定长睡是撞运气——按 [until] 有界轮询，等到即返回。
  Future<void> settle(WidgetTester tester, Finder until) async {
    await tester.runAsync(() async {
      final Stopwatch clock = Stopwatch()..start();
      while (clock.elapsed < const Duration(seconds: 10)) {
        await tester.pump();
        if (until.evaluate().isNotEmpty) return;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pump();
  }

  Future<void> pumpDialog(
    WidgetTester tester,
    Widget child, {
    required Finder until,
  }) async {
    await tester.runAsync(() => tester.pumpWidget(harness(child)));
    await settle(tester, until);
  }

  Future<void> dropOnDialog(
    WidgetTester tester,
    List<String> paths, {
    required Finder until,
  }) async {
    // 走 FushiFileDropTarget 的唯一咽喉，与 desktop_drop 真回调同一条路径。
    final FushiFileDropTarget target =
        tester.widget<FushiFileDropTarget>(find.byType(FushiFileDropTarget));
    await tester.runAsync(() => target.runDrop(paths, Offset.zero));
    await settle(tester, until);
  }

  testWidgets('initialTorrentPath prefills file name, title and content kind',
      (WidgetTester tester) async {
    await pumpDialog(
      tester,
      dialog(
        initialTorrentPath: validTorrent,
        initialDiscoveryKind: DiscoveryMediaKind.manga,
      ),
      until: find.text('first.torrent'),
    );

    expect(find.text('first.torrent'), findsOneWidget);
    expect(titleText(tester), 'test');
    // 落点表面决定的内容类型真的落到了下拉框上（漫画库拖入 → 漫画）。
    expect(find.text(t.discovery_kind_manga), findsOneWidget);
  });

  testWidgets('dropping another .torrent onto the open dialog replaces it',
      (WidgetTester tester) async {
    await pumpDialog(tester, dialog(initialTorrentPath: validTorrent),
        until: find.text('first.torrent'));
    expect(find.text('first.torrent'), findsOneWidget);

    await dropOnDialog(tester, <String>[otherTorrent],
        until: find.text('second.torrent'));

    expect(find.text('second.torrent'), findsOneWidget);
    expect(find.text('first.torrent'), findsNothing);
    // 标题是自动预填的（用户没改过）→ 跟着新种子换。
    expect(titleText(tester), 'other');
  });

  testWidgets('dropping non-torrent files onto the dialog is ignored',
      (WidgetTester tester) async {
    await pumpDialog(tester, dialog(initialTorrentPath: validTorrent),
        until: find.text('first.torrent'));

    // 非种子在 _handleDialogDrop 里同步早退，没有任何异步落字段可等——立刻断言
    // 「什么都没变」。
    await dropOnDialog(tester, <String>[r'C:\x\a.mkv', r'C:\x\b.srt'],
        until: find.text('first.torrent'));

    expect(find.text('first.torrent'), findsOneWidget);
    expect(titleText(tester), 'test');
  });

  testWidgets('a broken torrent reports the same invalid hint as the picker',
      (WidgetTester tester) async {
    await pumpDialog(tester, dialog(initialTorrentPath: brokenTorrent),
        until: find.text(t.download_task_add_invalid));

    expect(find.text(t.download_task_add_invalid), findsOneWidget);
    expect(find.text('broken.torrent'), findsNothing);
    expect(titleText(tester), isEmpty);
  });

  group('drop surfaces route importTorrent into the dialog (source guard)', () {
    const Map<String, String> surfaces = <String, String>{
      'home-video': 'lib/src/pages/implementations/home_video_page.dart',
      'reader-shelf':
          'lib/src/pages/implementations/reader_history/books.part.dart',
    };
    surfaces.forEach((String name, String path) {
      test('$name handles DropIntent.importTorrent', () {
        final String src = File(path).readAsStringSync();
        final int at = src.indexOf('case DropIntent.importTorrent:');
        expect(at, greaterThan(-1),
            reason: '$name must switch on DropIntent.importTorrent');
        final int next = src.indexOf('case DropIntent.', at + 1);
        final String body = src.substring(at, next > at ? next : src.length);
        expect(body.contains('showManualDownloadTaskDialog('), isTrue,
            reason: '$name must open the manual download dialog for torrents');
        expect(body.contains('torrentPaths: files.torrents'), isTrue,
            reason: '$name must hand every dropped torrent to the dialog');
      });
    });

    test('downloads page is itself a .torrent drop surface', () {
      final String src =
          File('lib/src/pages/implementations/downloads_page.dart')
              .readAsStringSync();
      expect(src.contains('FushiFileDropTarget('), isTrue,
          reason: 'downloads page must accept dropped torrents');
      expect(src.contains('torrentPaths: files.torrents'), isTrue,
          reason: 'downloads page must hand dropped torrents to the dialog');
    });
  });
}
