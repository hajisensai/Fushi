import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/drag_drop/fushi_file_drop_target.dart';
import 'package:fushi/src/pages/implementations/manual_download_task_dialog.dart';
import 'package:fushi/src/utils/misc/fushi_byte_format.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart'
    show DiscoveryMediaKind;
import 'package:path/path.dart' as p;
import '../helpers/glass_unwrap.dart';

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
  late String packTorrent;

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
    // 多文件 v1 metainfo（反馈 pR-icPGMJD 的有声书合集缩影）：三本书各一个文件。
    String bstr(String value) => '${utf8.encode(value).length}:$value';
    String file(String dir, String name, int length) =>
        'd6:lengthi${length}e4:pathl${bstr(dir)}${bstr(name)}ee';
    packTorrent = p.join(tmp.path, 'pack.torrent');
    File(packTorrent).writeAsBytesSync(
      utf8.encode(
        'd4:infod5:filesl'
        '${file('Book A', '01 a.m4b', 100)}'
        '${file('Book B', '01 b.m4b', 200)}'
        '${file('Book C', '01 c.m4b', 400)}'
        'e4:name4:pack6:pieces20:aaaaaaaaaaaaaaaaaaaaee',
      ),
    );
  });

  tearDownAll(() => tmp.deleteSync(recursive: true));

  Widget harness(Widget child, {bool reduceMotion = false}) {
    return TranslationProvider(
      child: MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(disableAnimations: reduceMotion),
            child: Scaffold(body: Center(child: child)),
          ),
        ),
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
        glassUnwrap<TextField>(
          find.byKey(const ValueKey<String>('manual-task-title')),
        ),
      )
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
    final FushiFileDropTarget target = tester.widget<FushiFileDropTarget>(
      find.byType(FushiFileDropTarget),
    );
    await tester.runAsync(() => target.runDrop(paths, Offset.zero));
    await settle(tester, until);
  }

  for (final bool reduceMotion in <bool>[false, true]) {
    testWidgets(
      'source input switches both ways with reduceMotion=$reduceMotion',
      (WidgetTester tester) async {
        await tester.pumpWidget(harness(dialog(), reduceMotion: reduceMotion));
        await tester.pumpAndSettle();
        final Finder magnet = find.byKey(
          const ValueKey<String>('manual-task-magnet-pane'),
        );
        final Finder torrent = find.byKey(
          const ValueKey<String>('manual-task-drop-zone'),
        );
        final Finder sourceSwitch = find.byKey(
          const ValueKey<String>('manual-task-source-kind'),
        );
        expect(magnet, findsOneWidget);
        expect(
          find.ancestor(of: magnet, matching: find.byType(AnimatedSize)),
          reduceMotion ? findsNothing : findsOneWidget,
        );
        await tester.tap(
          find.descendant(
            of: sourceSwitch,
            matching: find.text(t.download_task_add_source_torrent),
          ),
        );
        await tester.pump();
        if (!reduceMotion) await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(torrent, findsOneWidget);
        expect(magnet, findsNothing);

        await tester.tap(
          find.descendant(
            of: sourceSwitch,
            matching: find.text(t.download_task_add_source_magnet),
          ),
        );
        await tester.pump();
        if (!reduceMotion) await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(magnet, findsOneWidget);
        expect(torrent, findsNothing);
      },
    );
  }

  testWidgets('initialTorrentPath prefills file name, title and content kind', (
    WidgetTester tester,
  ) async {
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

  testWidgets('dropping another .torrent onto the open dialog replaces it', (
    WidgetTester tester,
  ) async {
    await pumpDialog(
      tester,
      dialog(initialTorrentPath: validTorrent),
      until: find.text('first.torrent'),
    );
    expect(find.text('first.torrent'), findsOneWidget);

    await dropOnDialog(tester, <String>[
      otherTorrent,
    ], until: find.text('second.torrent'));

    expect(find.text('second.torrent'), findsOneWidget);
    expect(find.text('first.torrent'), findsNothing);
    // 标题是自动预填的（用户没改过）→ 跟着新种子换。
    expect(titleText(tester), 'other');
  });

  testWidgets('dropping non-torrent files onto the dialog is ignored', (
    WidgetTester tester,
  ) async {
    await pumpDialog(
      tester,
      dialog(initialTorrentPath: validTorrent),
      until: find.text('first.torrent'),
    );

    // 非种子在 _handleDialogDrop 里同步早退，没有任何异步落字段可等——立刻断言
    // 「什么都没变」。
    await dropOnDialog(tester, <String>[
      r'C:\x\a.mkv',
      r'C:\x\b.srt',
    ], until: find.text('first.torrent'));

    expect(find.text('first.torrent'), findsOneWidget);
    expect(titleText(tester), 'test');
  });

  testWidgets('a broken torrent reports the same invalid hint as the picker', (
    WidgetTester tester,
  ) async {
    await pumpDialog(
      tester,
      dialog(initialTorrentPath: brokenTorrent),
      until: find.text(t.download_task_add_invalid),
    );

    expect(find.text(t.download_task_add_invalid), findsOneWidget);
    expect(find.text('broken.torrent'), findsNothing);
    expect(titleText(tester), isEmpty);
  });

  group('multi-file torrent file selection (feedback pR-icPGMJD)', () {
    Finder summary(int selected, int bytes) => find.text(
      t.download_file_selection_summary(
        selected: selected,
        total: 3,
        size: FushiByteFormat.bytes(bytes),
      ),
    );

    Future<void> tapKey(WidgetTester tester, String key) async {
      final Finder target = find.byKey(ValueKey<String>(key));
      await tester.ensureVisible(target);
      await tester.pump();
      await tester.tap(target);
      await tester.pump(const Duration(milliseconds: 800));
    }

    testWidgets('lists every file, starts fully selected', (
      WidgetTester tester,
    ) async {
      await pumpDialog(
        tester,
        dialog(initialTorrentPath: packTorrent),
        until: find.text('pack.torrent'),
      );
      await tester.pump(const Duration(milliseconds: 800));

      expect(
        find.byKey(const ValueKey<String>('manual-task-file-selection')),
        findsOneWidget,
      );
      expect(summary(3, 700), findsOneWidget);
      for (final int index in <int>[0, 1, 2]) {
        expect(
          find.byKey(ValueKey<String>('manual-task-file-$index')),
          findsOneWidget,
        );
      }
    });

    testWidgets('filter + select none/all act on the filtered rows', (
      WidgetTester tester,
    ) async {
      await pumpDialog(
        tester,
        dialog(initialTorrentPath: packTorrent),
        until: find.text('pack.torrent'),
      );
      await tester.pump(const Duration(milliseconds: 800));

      await tapKey(tester, 'manual-task-files-select-none');
      expect(summary(0, 0), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('manual-task-files-none-selected')),
        findsOneWidget,
      );

      await tester.enterText(
        glassUnwrap<EditableText>(
          find.byKey(const ValueKey<String>('manual-task-file-filter')),
        ),
        'book b',
      );
      await tester.pump(const Duration(milliseconds: 800));
      expect(
        find.byKey(const ValueKey<String>('manual-task-file-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('manual-task-file-0')),
        findsNothing,
      );

      await tapKey(tester, 'manual-task-files-select-all');
      expect(summary(1, 200), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('manual-task-files-none-selected')),
        findsNothing,
      );

      await tester.enterText(
        glassUnwrap<EditableText>(
          find.byKey(const ValueKey<String>('manual-task-file-filter')),
        ),
        'no such book',
      );
      await tester.pump(const Duration(milliseconds: 800));
      expect(
        find.byKey(const ValueKey<String>('manual-task-files-no-match')),
        findsOneWidget,
      );
      // 筛选只改「显示哪些」，不动勾选。
      expect(summary(1, 200), findsOneWidget);
    });

    testWidgets('tapping a row toggles that file', (WidgetTester tester) async {
      await pumpDialog(
        tester,
        dialog(initialTorrentPath: packTorrent),
        until: find.text('pack.torrent'),
      );
      await tester.pump(const Duration(milliseconds: 800));

      await tapKey(tester, 'manual-task-file-2');
      expect(summary(2, 300), findsOneWidget);
      await tapKey(tester, 'manual-task-file-2');
      expect(summary(3, 700), findsOneWidget);
    });

    testWidgets('single-file torrents show no selection UI', (
      WidgetTester tester,
    ) async {
      await pumpDialog(
        tester,
        dialog(initialTorrentPath: validTorrent),
        until: find.text('first.torrent'),
      );
      expect(
        find.byKey(const ValueKey<String>('manual-task-file-selection')),
        findsNothing,
      );
    });
  });

  test('submit hands the selection to the pipeline (source guard)', () {
    final String src = File(
      'lib/src/pages/implementations/manual_download_task_dialog.dart',
    ).readAsStringSync();
    expect(
      src.contains('selectedFileIndexes: _metainfo == null'),
      isTrue,
      reason: 'enqueueManual must receive the checked torrent files',
    );
    expect(
      src.contains('_fileSelection?.submission'),
      isTrue,
      reason: 'the submitted indexes come from TorrentFileSelection',
    );
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
        expect(
          at,
          greaterThan(-1),
          reason: '$name must switch on DropIntent.importTorrent',
        );
        final int next = src.indexOf('case DropIntent.', at + 1);
        final String body = src.substring(at, next > at ? next : src.length);
        expect(
          body.contains('showManualDownloadTaskDialog('),
          isTrue,
          reason: '$name must open the manual download dialog for torrents',
        );
        expect(
          body.contains('torrentPaths: files.torrents'),
          isTrue,
          reason: '$name must hand every dropped torrent to the dialog',
        );
      });
    });

    test('downloads page is itself a .torrent drop surface', () {
      final String src = File(
        'lib/src/pages/implementations/browse_page.dart',
      ).readAsStringSync();
      expect(
        src.contains('FushiFileDropTarget('),
        isTrue,
        reason: 'downloads page must accept dropped torrents',
      );
      expect(
        src.contains('torrentPaths: files.torrents'),
        isTrue,
        reason: 'downloads page must hand dropped torrents to the dialog',
      );
    });
  });
}
