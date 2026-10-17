import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/downloads/download_task_browser.dart';
import 'package:fushi/src/media/downloads/download_task_card.dart';
import 'package:fushi/src/media/downloads/download_task_entry.dart';
import 'package:fushi/src/pages/implementations/video_discovery_detail_page.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';

/// 发现详情页「任务」→ 下载中心只看这部作品的任务（反馈 Dnx43C5bpE：此前跳到
/// 下载页就「没动静了」，用户还得自己在全部任务里翻）。

final VideoMediaReference _reference = VideoMediaReference(
  providerId: 'tmdb',
  mediaId: '100',
  mediaKind: VideoMetadataMediaKind.tv,
  discoveryCategory: VideoDiscoveryCategory.anime,
  title: '星环纪元',
  originalTitle: 'Hoshiwa Kigen',
  anilistId: 555,
);

DownloadTaskEntry _task(
  String id, {
  required String title,
  DownloadTaskStatus status = DownloadTaskStatus.active,
  DownloadTaskWorkIdentity? identity,
  String? collectionKey,
}) => DownloadTaskEntry(
  id: id,
  title: title,
  kind: DownloadTaskKind.video,
  status: status,
  collectionKey: collectionKey,
  collectionTitle: collectionKey == null ? null : title,
  workIdentity: identity,
  builder: (BuildContext context) => DownloadTaskCard(
    key: ValueKey<String>('card-$id'),
    taskId: id,
    title: title,
    status: downloadTaskStatusLabel(status),
    progress: status == DownloadTaskStatus.completed ? 1 : 0.3,
    details: Text('details-$id'),
  ),
);

/// 本作品：两条身份精确命中（其中一条是跨站 AniList id）+ 一条无身份按标题兜底；
/// 外加一条**同名但身份不同**的别的作品、一条无关的直链。
final List<DownloadTaskEntry> _tasks = <DownloadTaskEntry>[
  _task(
    'job-done',
    title: '星环纪元',
    status: DownloadTaskStatus.completed,
    identity: const DownloadTaskWorkIdentity(
      provider: 'tmdb',
      externalId: '100',
    ),
    collectionKey: 'series:tmdb:100',
  ),
  _task(
    'job-failed',
    title: '星环纪元 第二季资源',
    status: DownloadTaskStatus.attention,
    identity: const DownloadTaskWorkIdentity(
      provider: 'anilist',
      externalId: '555',
    ),
    collectionKey: 'series:tmdb:100',
  ),
  _task('direct-title', title: '[Sub] Hoshiwa Kigen - 01 [1080p]'),
  _task(
    'job-other-same-name',
    title: '星环纪元',
    identity: const DownloadTaskWorkIdentity(
      provider: 'tmdb',
      externalId: '200',
    ),
    collectionKey: 'series:tmdb:200',
  ),
  _task('direct-other', title: '另一部番 第01话'),
];

const List<String> _ownIds = <String>['job-done', 'job-failed', 'direct-title'];
const List<String> _otherIds = <String>['job-other-same-name', 'direct-other'];

Finder _card(String id) => find.byKey(ValueKey<String>('card-$id'));

void _expectVisible(Iterable<String> ids, Matcher matcher) {
  for (final String id in ids) {
    expect(_card(id), matcher, reason: id);
  }
}

Future<void> _pumpFrames(WidgetTester tester) async {
  // 在途任务的波浪进度条常驻动画，pumpAndSettle 不会返回。
  for (int i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

/// 模拟首页组合根：详情页的「任务」把宿主切到下载中心并带上定位，下载中心的
/// 「显示全部任务」由宿主清空定位（与 BrowsePage 持有 _downloadsWorkFocus 同形）。
class _Host extends StatefulWidget {
  const _Host();

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  bool _showDownloads = false;
  DownloadTaskWorkFocus? _focus;

  @override
  Widget build(BuildContext context) {
    if (!_showDownloads) {
      return VideoDiscoveryDetailPage(
        item: VideoDiscoveryItem(reference: _reference),
        actions: VideoDiscoveryActions(
          onOpenDownloads: () => fail('详情页必须走「定位到本作品」的入口'),
          onOpenWorkDownloads: (VideoMediaReference reference) => setState(() {
            _showDownloads = true;
            _focus = videoDiscoveryDownloadTaskFocus(reference);
          }),
        ),
      );
    }
    return Scaffold(
      body: DownloadTaskBrowser(
        tasks: _tasks,
        workFocus: _focus,
        onClearWorkFocus: () => setState(() => _focus = null),
      ),
    );
  }
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  testWidgets('详情页点「任务」→ 只显示该番任务（含已完成 / 出错），清除后恢复全部', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: const _Host(),
        ),
      ),
    );
    await _pumpFrames(tester);

    Finder entry = find.byKey(
      const ValueKey<String>('video-discovery-detail-downloads-menu'),
    );
    if (entry.evaluate().isEmpty) {
      // 宽度不够时收在「⋯」里。
      await tester.tap(
        find.byKey(const ValueKey<String>('video-discovery-detail-more')),
      );
      await _pumpFrames(tester);
      entry = find.byKey(
        const ValueKey<String>('video-discovery-detail-downloads-menu'),
      );
    }
    expect(entry, findsOneWidget);
    await tester.tap(entry);
    await _pumpFrames(tester);

    // 定位条可见、写明是哪部作品，并给出一键清除。
    expect(
      find.byKey(const ValueKey<String>('download-task-work-focus')),
      findsOneWidget,
    );
    expect(
      find.text(t.download_task_work_focus_label(title: '星环纪元')),
      findsOneWidget,
    );
    _expectVisible(_ownIds, findsOneWidget);
    _expectVisible(_otherIds, findsNothing);
    expect(find.text('3 / 5'), findsOneWidget, reason: '计数要说明是筛过的');

    await tester.tap(
      find.byKey(const ValueKey<String>('download-task-work-focus-clear')),
    );
    await _pumpFrames(tester);

    expect(
      find.byKey(const ValueKey<String>('download-task-work-focus')),
      findsNothing,
    );
    _expectVisible(<String>[..._ownIds, ..._otherIds], findsOneWidget);
  });

  testWidgets('新的定位清掉会藏任务的筛选并展开所在分组', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Widget host(DownloadTaskWorkFocus? focus) => TranslationProvider(
      child: MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: DownloadTaskBrowser(
            tasks: _tasks,
            workFocus: focus,
            onClearWorkFocus: () {},
          ),
        ),
      ),
    );

    await tester.pumpWidget(host(null));
    await _pumpFrames(tester);

    // 用户此前停在「下载中」段、并把分组全部折叠。
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('download-task-status-filter')),
        matching: find.text(t.download_task_status_downloading),
      ),
    );
    await _pumpFrames(tester);
    await tester.tap(
      find.byKey(const ValueKey<String>('download-task-collapse-all')),
    );
    await _pumpFrames(tester);
    _expectVisible(<String>['job-done', 'job-failed'], findsNothing);

    await tester.pumpWidget(host(videoDiscoveryDownloadTaskFocus(_reference)));
    await _pumpFrames(tester);

    _expectVisible(_ownIds, findsOneWidget);
    _expectVisible(_otherIds, findsNothing);
  });

  test('定位判据：有身份只认身份，没身份按标题兜底', () {
    final DownloadTaskWorkFocus focus = videoDiscoveryDownloadTaskFocus(
      _reference,
    );
    expect(
      _tasks.where(focus.matches).map((DownloadTaskEntry e) => e.id),
      unorderedEquals(_ownIds),
    );
  });
}
