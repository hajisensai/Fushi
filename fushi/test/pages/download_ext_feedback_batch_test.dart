// 反馈批 download-ext（XFsZIWYbr8 / GWal_-1tfs / rnvZvDwhS1 / Dnx43C5bpE）的行为钉子：
// ① 工具栏动作少时平铺、不收进「⋯」；
// ② 下载中的进度圈落在原下载钮的命中区中心；
// ③ 集卡「观看至」独占一行、不挤规格摘要；
// ④ 合辑可整组选中；
// ⑤ 扩展源已完成任务：来源标签不是「配对设备」、提供删除（可连文件）且不再只清记录。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/collections/collection_detail_layout.dart';
import 'package:fushi/src/media/detail/media_detail_kit.dart';
import 'package:fushi/src/media/downloads/download_task_entry.dart';
import 'package:fushi/src/pages/implementations/interconnect_download_tasks_section.dart';
import 'package:fushi/src/pages/implementations/video_resource_version_group_list.dart';
import 'package:fushi/src/sync/interconnect_download_manager.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
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

  group('MediaDetailMoreButton 平铺', () {
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

    testWidgets('动作不超过 inlineMax：全部平铺，点击直达', (WidgetTester tester) async {
      final List<String> taps = <String>[];
      await tester.pumpWidget(
        _host(
          MediaDetailMoreButton(
            buttonKey: const ValueKey<String>('more'),
            items: items(2, taps),
            inlineMax: 3,
          ),
        ),
      );
      expect(find.byKey(const ValueKey<String>('item0')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('item1')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('item1')));
      expect(taps, <String>['item1']);
    });

    testWidgets('超过 inlineMax：仍收进「⋯」单个按钮', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          MediaDetailMoreButton(
            buttonKey: const ValueKey<String>('more'),
            items: items(4, <String>[]),
            inlineMax: 3,
          ),
        ),
      );
      expect(find.byKey(const ValueKey<String>('more')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('item0')), findsNothing);
    });

    testWidgets('默认 inlineMax=0 保持旧行为（收进菜单）', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          MediaDetailMoreButton(
            buttonKey: const ValueKey<String>('more'),
            items: items(1, <String>[]),
          ),
        ),
      );
      expect(find.byKey(const ValueKey<String>('more')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('item0')), findsNothing);
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

  testWidgets('集卡：观看至与规格摘要分两行，观看至在上', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(
        SizedBox(
          width: 420,
          height: kCollectionEpisodeCardHeight,
          child: CollectionEpisodeCard(
            thumb: const SizedBox(width: 120, height: 80),
            number: '1',
            title: 'Episode 1',
            positionMs: 90000,
            trailingStatus: const Text(
              '1080p · HEVC',
              key: ValueKey<String>('specs'),
            ),
          ),
        ),
      ),
    );
    final Finder watched = find.byKey(
      const ValueKey<String>('collection-episode-watched'),
    );
    expect(watched, findsOneWidget);
    expect(
      tester.getTopLeft(watched).dy,
      lessThan(tester.getTopLeft(find.byKey(const ValueKey<String>('specs'))).dy),
    );
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
      expect(entry.collectionTitle, isNot(t.download_interconnect_section_title));
      expect(entry.actions.clear, isNull);
      expect(entry.actions.deletesFiles, isTrue);
      await entry.actions.delete!(deleteFiles: true);
      expect(deletedWithFiles, isTrue);
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
}
