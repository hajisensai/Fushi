// 反馈批 download-ext（XFsZIWYbr8 / GWal_-1tfs / rnvZvDwhS1 / Dnx43C5bpE）的行为钉子：
// ① 工具栏动作默认平铺、只有宽度放不下才从低优先级起收进「⋯」；
// ② 下载中的进度圈落在原下载钮的命中区中心；
// ③ 集卡「观看至」与规格摘要放得下同一行、放不下才折行，任何字号不溢出；
// ④ 合辑可整组选中；
// ⑤ 扩展源已完成任务：来源标签不是「配对设备」、提供删除（可连文件）且不再只清记录。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/collections/collection_detail_layout.dart';
import 'package:fushi/src/media/detail/media_detail_kit.dart';
import 'package:fushi/src/media/downloads/download_task_entry.dart';
import 'package:fushi/src/media/video/video_library_delete.dart';
import 'package:fushi/src/pages/implementations/interconnect_download_tasks_section.dart';
import 'package:fushi/src/pages/implementations/video_resource_version_group_list.dart';
import 'package:fushi/src/sync/interconnect_download_manager.dart';
import 'package:fushi_core/fushi_core.dart'
    show LocalFileDeleteFailure, LocalFileDeleteReport, deleteLocalFiles;
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart'
    show VideoBookDeleteFailure;
import 'package:fushi_engine/media/video/download/video_resource_version_groups.dart';
import 'package:material_ui/material_ui.dart';

class _Res extends VideoResourceCandidate {
  _Res({required super.remoteId, required super.title})
    : super(
        providerId: 'nyaa',
        providerInstanceId: 'nyaa',
        providerPriority: 100,
        releaseGroup: 'G',
        resolution: '1080p',
      );
}

Widget _host(Widget child) => TranslationProvider(
  child: MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  group('MediaDetailMoreButton 自适应溢出（默认展开、放不下才收）', () {
    List<MediaDetailMenuItem> items(int n, List<String> taps) =>
        <MediaDetailMenuItem>[
          for (int i = 0; i < n; i++)
            MediaDetailMenuItem(
              key: ValueKey<String>('item$i'),
              icon: Icons.refresh,
              label: 'L$i',
              onSelected: () => taps.add('item$i'),
            ),
        ];

    Widget sized(double width, Widget child) => Align(
      alignment: AlignmentDirectional.topStart,
      child: SizedBox(width: width, child: child),
    );

    testWidgets('宽度够：动作再多也全部平铺，没有「⋯」', (WidgetTester tester) async {
      final List<String> taps = <String>[];
      await tester.pumpWidget(
        _host(
          sized(
            600,
            MediaDetailMoreButton(
              buttonKey: const ValueKey<String>('more'),
              items: items(5, taps),
              adaptiveOverflow: true,
            ),
          ),
        ),
      );
      for (int i = 0; i < 5; i++) {
        expect(find.byKey(ValueKey<String>('item$i')), findsOneWidget);
      }
      expect(find.byTooltip(t.common_more_actions), findsNothing);
      await tester.tap(find.byKey(const ValueKey<String>('item4')));
      expect(taps, <String>['item4']);
    });

    testWidgets('宽度不够：从最低优先级起收进「⋯」，高优先级仍平铺', (WidgetTester tester) async {
      final List<String> taps = <String>[];
      await tester.pumpWidget(
        _host(
          sized(
            120,
            MediaDetailMoreButton(
              buttonKey: const ValueKey<String>('more'),
              items: items(4, taps),
              adaptiveOverflow: true,
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey<String>('item0')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('item3')), findsNothing);
      expect(find.byKey(const ValueKey<String>('more')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('more')));
      await tester.pumpAndSettle();
      // 菜单里只有被收起的那几项，平铺的不重复出现。
      expect(find.byKey(const ValueKey<String>('item3')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('item0')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('item3')));
      await tester.pumpAndSettle();
      expect(taps, <String>['item3']);
    });

    testWidgets('按实际 56px 钮宽测宽：六个动作 340px 放不下全展开，376px 才全平铺', (
      WidgetTester tester,
    ) async {
      // 6 * 56 + 5 * 8 = 376。旧实现按 48 估宽，340 预算下误判全展开并溢出。
      await tester.pumpWidget(
        _host(
          sized(
            340,
            MediaDetailMoreButton(
              buttonKey: const ValueKey<String>('more'),
              items: items(6, <String>[]),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey<String>('item5')), findsNothing);
      expect(find.byTooltip(t.common_more_actions), findsOneWidget);
      final double rowWidth = tester
          .getSize(find.byType(MediaDetailMoreButton))
          .width;
      expect(rowWidth, lessThanOrEqualTo(340));

      // 换一棵树重来：展开方向带回差，复用同一个 State 要多 24px 才放出下一颗。
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        _host(
          sized(
            376,
            MediaDetailMoreButton(
              buttonKey: const ValueKey<String>('more'),
              items: items(6, <String>[]),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      for (int i = 0; i < 6; i++) {
        expect(find.byKey(ValueKey<String>('item$i')), findsOneWidget);
      }
      expect(find.byTooltip(t.common_more_actions), findsNothing);
    });

    testWidgets('显式关掉 adaptiveOverflow 时恒收进菜单', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          MediaDetailMoreButton(
            buttonKey: const ValueKey<String>('more'),
            items: items(1, <String>[]),
            adaptiveOverflow: false,
          ),
        ),
      );
      expect(find.byKey(const ValueKey<String>('more')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('item0')), findsNothing);
    });

    test('默认按工具栏规则自适应溢出（漫画 / 小说等调用方不传参也遵守）', () {
      final MediaDetailMoreButton button = MediaDetailMoreButton(
        items: items(1, <String>[]),
      );
      expect(button.adaptiveOverflow, isTrue);
    });

    test('不再按动作个数写死平铺上限（源码守卫）', () {
      final String source = File(
        'lib/src/media/detail/media_detail_kit.dart',
      ).readAsStringSync();
      expect(source, isNot(contains('kInlineActionsMax')));
      expect(source, isNot(contains('inlineMax')));
      expect(source, contains('FushiTopBarOverflowFit'));
    });
  });

  testWidgets('下载中进度圈与原下载钮同心（右偏 14dp 的回归）', (WidgetTester tester) async {
    Widget row(MediaDetailDownloadState state, Widget? trailing) => SizedBox(
      width: 360,
      child: MediaDetailItemRow(
        title: 'Episode',
        index: 0,
        count: 1,
        downloadState: state,
        trailing: trailing,
      ),
    );
    await tester.pumpWidget(
      _host(
        Column(
          children: <Widget>[
            row(
              MediaDetailDownloadState.none,
              const SizedBox.square(
                key: ValueKey<String>('btn'),
                dimension: 48,
              ),
            ),
            row(MediaDetailDownloadState.downloading, null),
          ],
        ),
      ),
    );
    final double buttonCenterX = tester
        .getCenter(find.byKey(const ValueKey<String>('btn')))
        .dx;
    final Finder ring = find.byKey(
      const ValueKey<String>('media-detail-item-downloading'),
    );
    expect(tester.getCenter(ring).dx, closeTo(buttonCenterX, 0.5));
  });

  group('集卡状态行：观看至与规格摘要', () {
    const ValueKey<String> watchedKey = ValueKey<String>(
      'collection-episode-watched',
    );

    Widget card({
      required double width,
      required Widget trailing,
      String title = 'Episode 1',
      List<String> meta = const <String>[],
      double textScale = 1,
    }) => Align(
      alignment: AlignmentDirectional.topStart,
      child: Builder(
        builder: (BuildContext context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: SizedBox(
            width: width,
            height: kCollectionEpisodeCardHeight,
            child: CollectionEpisodeCard(
              thumb: const SizedBox(
                width: kCollectionEpisodeThumbWidth,
                height: kCollectionEpisodeThumbHeight,
              ),
              number: '1',
              title: title,
              meta: meta,
              positionMs: 90000,
              trailingStatus: trailing,
            ),
          ),
        ),
      ),
    );

    testWidgets('放得下时同一行：观看至在起始侧、规格在末端，不互相挤', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          card(
            width: 900,
            trailing: const Text(
              '1080p · HEVC',
              key: ValueKey<String>('specs'),
            ),
          ),
        ),
      );
      final Finder specs = find.byKey(const ValueKey<String>('specs'));
      expect(find.byKey(watchedKey), findsOneWidget);
      expect(
        tester.getCenter(find.byKey(watchedKey)).dy,
        closeTo(tester.getCenter(specs).dy, 1),
      );
      expect(
        tester.getTopRight(find.byKey(watchedKey)).dx,
        lessThan(tester.getTopLeft(specs).dx),
      );
    });

    testWidgets('规格未探到（零尺寸）：观看至仍落在底部状态行，不空出一行', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(card(width: 420, trailing: const SizedBox.shrink())),
      );
      final Rect cardRect = tester.getRect(find.byType(CollectionEpisodeCard));
      expect(
        tester.getBottomLeft(find.byKey(watchedKey)).dy,
        closeTo(cardRect.bottom - kCollectionEpisodeCardPadding, 1),
      );
    });

    testWidgets('系统字号放大 + 无简介：两种规格状态都不溢出', (WidgetTester tester) async {
      for (final Widget trailing in <Widget>[
        const SizedBox.shrink(),
        const Text('1080p · HDR10 · HEVC'),
      ]) {
        await tester.pumpWidget(
          _host(
            card(
              width: 420,
              trailing: trailing,
              title: 'A rather long episode title that wraps onto two lines',
              meta: const <String>['24 min'],
              textScale: 1.3,
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        expect(find.byKey(watchedKey), findsOneWidget);
      }
    });
  });

  testWidgets('合辑：展开后「全选本组」一次选中 / 取消整组', (WidgetTester tester) async {
    final List<VideoResourceCandidate> items = <VideoResourceCandidate>[
      _Res(remoteId: 'a', title: '[G] Show - 01 (1080p).mkv'),
      _Res(remoteId: 'b', title: '[G] Show - 02 (1080p).mkv'),
      _Res(remoteId: 'c', title: '[G] Show - 03 (1080p).mkv'),
    ];
    final List<VideoResourceVersionGroup> groups =
        buildVideoResourceVersionGroups(items);
    final Set<String> selected = <String>{};
    late StateSetter rebuild;
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            rebuild = setState;
            return SizedBox(
              height: 600,
              child: VideoResourceVersionGroupList(
                groups: groups,
                selectedIdentityKeys: selected,
                multiSelect: true,
                onSelect: (VideoResourceCandidate c) {},
                onSetGroupSelected:
                    (List<VideoResourceCandidate> members, bool on) {
                      rebuild(() {
                        for (final VideoResourceCandidate m in members) {
                          on
                              ? selected.add(m.identityKey)
                              : selected.remove(m.identityKey);
                        }
                      });
                    },
              ),
            );
          },
        ),
      ),
    );
    await tester.tap(find.byTooltip(t.resource_version_show_files));
    await tester.pump();
    final Finder selectAll = find.byKey(
      ValueKey<String>('resource-select-all-${groups.single.key}'),
    );
    expect(selectAll, findsOneWidget);
    await tester.tap(selectAll);
    await tester.pump();
    expect(selected.length, 3);
    await tester.tap(selectAll);
    await tester.pump();
    expect(selected, isEmpty);
  });

  group('扩展源已完成任务条目', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('dlext_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    Future<DownloadTaskEntry> entryFor(
      InterconnectDownloadOrigin origin, {
      Future<void> Function({required bool deleteFiles})? deleter,
    }) async {
      final InterconnectDownloadManager manager = InterconnectDownloadManager();
      addTearDown(manager.dispose);
      await manager.startVideoDownload(
        id: 'ep1',
        title: 'Episode 1',
        dest: File('${tmp.path}/ep1.mp4'),
        origin: origin,
        run:
            (
              File dest, {
              void Function(double progress)? onProgress,
              void Function(int received, int? total)? onBytes,
              Future<void>? cancelSignal,
            }) async => dest.writeAsBytesSync(<int>[1]),
      );
      return interconnectDownloadTaskEntry(
        manager,
        manager.taskFor('ep1')!,
        deleteCompletedFiles: deleter,
      );
    }

    test('扩展源：标签是「扩展源」而不是配对设备，且可连文件删除、不再只清记录', () async {
      bool? deletedWithFiles;
      final DownloadTaskEntry entry = await entryFor(
        InterconnectDownloadOrigin.extension,
        deleter: ({required bool deleteFiles}) async =>
            deletedWithFiles = deleteFiles,
      );
      expect(entry.status, DownloadTaskStatus.completed);
      expect(entry.collectionTitle, t.download_method_extension);
      expect(
        entry.collectionTitle,
        isNot(t.download_interconnect_section_title),
      );
      expect(entry.actions.clear, isNull);
      expect(entry.actions.deletesFiles, isTrue);
      await entry.actions.delete!(deleteFiles: true);
      expect(deletedWithFiles, isTrue);
    });

    test('任务快照带着成品落点（完成后删文件不再靠库行反推）', () async {
      final InterconnectDownloadManager manager = InterconnectDownloadManager();
      addTearDown(manager.dispose);
      final File dest = File('${tmp.path}/ep2.mp4');
      await manager.startVideoDownload(
        id: 'ep2',
        title: 'Episode 2',
        dest: dest,
        origin: InterconnectDownloadOrigin.extension,
        run:
            (
              File target, {
              void Function(double progress)? onProgress,
              void Function(int received, int? total)? onBytes,
              Future<void>? cancelSignal,
            }) async => target.writeAsBytesSync(<int>[1]),
      );
      expect(manager.taskFor('ep2')!.destPath, dest.path);
    });

    test('配对设备来源保持原状：标签不变，仍可清记录', () async {
      final DownloadTaskEntry entry = await entryFor(
        InterconnectDownloadOrigin.ownDevice,
      );
      expect(entry.collectionTitle, t.download_interconnect_section_title);
      expect(entry.actions.clear, isNotNull);
      expect(entry.actions.delete, isNull);
    });
  });
  group('deleteCompletedDownloadFile：按文件删、删不掉就保留任务', () {
    late Directory tmp;
    late File file;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('dlext_del_');
      file = File('${tmp.path}/ep.mp4')..writeAsBytesSync(<int>[1, 2, 3]);
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    Future<LocalFileDeleteReport> realDelete(String path) =>
        deleteLocalFiles(<String>[path]);

    test('库里有行指向这个文件：走媒体库删除链，不碰孤儿删除', () async {
      final List<String> deletedRows = <String>[];
      bool orphanCalled = false;
      VideoLibraryDeleteResult? reported;
      final bool done = await deleteCompletedDownloadFile(
        destPath: file.path,
        libraryRowFor: (String path) async => path == file.path ? 'ep1' : null,
        deleteLibraryRow: (String uid) async {
          deletedRows.add(uid);
          return (
            deleted: 1,
            failed: const <VideoBookDeleteFailure>[],
            localFiles: await realDelete(file.path),
          );
        },
        deleteOrphanFile: (String path) async {
          orphanCalled = true;
          return const LocalFileDeleteReport();
        },
        fileExists: (String path) => File(path).exists(),
        report: (VideoLibraryDeleteResult r) => reported = r,
      );
      expect(deletedRows, <String>['ep1']);
      expect(orphanCalled, isFalse);
      expect(done, isTrue);
      expect(file.existsSync(), isFalse);
      expect(reported!.localFiles.failures, isEmpty);
    });

    test('同 bookUid 已是流媒体行 / 行已删（按路径找不到行）：只删文件，不删任何库行', () async {
      bool rowDeleteCalled = false;
      final bool done = await deleteCompletedDownloadFile(
        destPath: file.path,
        // anime-source:// 行的 videoPath 不是这个文件，按路径查不到。
        libraryRowFor: (String path) async => null,
        deleteLibraryRow: (String uid) async {
          rowDeleteCalled = true;
          throw StateError('must not delete library rows');
        },
        deleteOrphanFile: realDelete,
        fileExists: (String path) => File(path).exists(),
        report: (VideoLibraryDeleteResult r) {},
      );
      expect(rowDeleteCalled, isFalse);
      expect(done, isTrue);
      expect(file.existsSync(), isFalse);
    });

    test('删行失败：上报失败且保留任务', () async {
      VideoLibraryDeleteResult? reported;
      final bool done = await deleteCompletedDownloadFile(
        destPath: file.path,
        libraryRowFor: (String path) async => 'ep1',
        deleteLibraryRow: (String uid) async => (
          deleted: 0,
          failed: <VideoBookDeleteFailure>[
            VideoBookDeleteFailure(
              bookUid: uid,
              error: StateError('db busy'),
              stackTrace: StackTrace.current,
            ),
          ],
          localFiles: const LocalFileDeleteReport(),
        ),
        deleteOrphanFile: realDelete,
        fileExists: (String path) => File(path).exists(),
        report: (VideoLibraryDeleteResult r) => reported = r,
      );
      expect(done, isFalse);
      expect(reported!.failed, hasLength(1));
    });

    test('原件删失败（句柄占用）：上报失败且保留任务', () async {
      VideoLibraryDeleteResult? reported;
      final bool done = await deleteCompletedDownloadFile(
        destPath: file.path,
        libraryRowFor: (String path) async => null,
        deleteOrphanFile: (String path) async => LocalFileDeleteReport(
          failures: <LocalFileDeleteFailure>[
            LocalFileDeleteFailure(path, const FileSystemException('locked')),
          ],
        ),
        deleteLibraryRow: (String uid) async => throw StateError('unused'),
        fileExists: (String path) => File(path).exists(),
        report: (VideoLibraryDeleteResult r) => reported = r,
      );
      expect(done, isFalse);
      expect(reported!.localFiles.failures, hasLength(1));
      expect(file.existsSync(), isTrue);
    });

    test('删除链没报失败但文件还在（被别的库行引用，护栏没删）：补报失败、保留任务', () async {
      VideoLibraryDeleteResult? reported;
      final bool done = await deleteCompletedDownloadFile(
        destPath: file.path,
        libraryRowFor: (String path) async => 'ep1',
        deleteLibraryRow: (String uid) async => (
          deleted: 1,
          failed: const <VideoBookDeleteFailure>[],
          localFiles: const LocalFileDeleteReport(),
        ),
        deleteOrphanFile: realDelete,
        fileExists: (String path) => File(path).exists(),
        report: (VideoLibraryDeleteResult r) => reported = r,
      );
      expect(done, isFalse);
      expect(reported!.localFiles.failures.single.path, file.path);
    });
  });
}
