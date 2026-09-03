import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fushi/models.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/media/discovery/discovery_download_queue.dart';
import 'package:fushi/src/media/discovery/discovery_models.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/games_library_page.dart';
import 'package:fushi/utils.dart';

import '../helpers/test_platform_services.dart';

/// BUG-1911：「刚开始下载的、下载一半的应该也进到库里面占位。否则不知道是否加入了，
/// 毕竟发现已经获取到对应的名称和封面了」（用户 2026-08-28）。
///
/// **刻意不往 `Galgames` 表写占位行**：那张表的 `exePath` 是 NOT NULL、且没有任何状态列
/// ——一行存在就等于「本机有一个可启动的 exe」。为占位造一行意味着要么写个假路径，
/// 要么加 schema 列 + 迁移，还得回答「下载失败/取消后这行归谁删」「同步与墓碑怎么算」。
/// 而下载队列本身就是这些条目此刻的唯一真相源，并且随手带着用户说的那两样东西
/// （`item.title` / `item.coverUrl`）。所以占位是**渲染**出来的、不是**存**出来的：
/// 下载完成走既有入库路径落成真条目，失败/取消则自然消失。
DiscoveryResourceItem _item({
  required String title,
  DiscoveryMediaKind kind = DiscoveryMediaKind.game,
  String? coverUrl,
}) =>
    DiscoveryResourceItem(
      sourceId: 'shinnku',
      title: title,
      id: title,
      kind: kind,
      payloadKind: DiscoveryPayloadKind.httpFile,
      coverUrl: coverUrl,
    );

DiscoveryDownloadTask _task({
  required String title,
  DiscoveryMediaKind kind = DiscoveryMediaKind.game,
  DiscoveryDownloadStatus status = DiscoveryDownloadStatus.running,
  int receivedBytes = 0,
  int? totalBytes,
  String? coverUrl,
}) =>
    DiscoveryDownloadTask.forTesting(
      item: _item(title: title, kind: kind, coverUrl: coverUrl),
      status: status,
      receivedBytes: receivedBytes,
      totalBytes: totalBytes,
    );

/// 队列可注入的 [AppModel]：真队列（真 `enqueue` / 真 `tasks` / 真 notify），只是
/// payload 解析永不完成，任务因此稳定停在「在途」——库页要的正是这个状态。
class _QueuedAppModel extends AppModel {
  _QueuedAppModel() : super(testPlatformServices());

  @override
  DiscoveryDownloadQueue get discoveryDownloadQueue => _queue;

  late final DiscoveryDownloadQueue _queue = DiscoveryDownloadQueue(
    resolvePayload: (DiscoveryResourceItem item) =>
        Completer<DiscoveryPayload>().future,
    importer: (DiscoveryDownloadTask task, File file) async =>
        const DiscoveryImportOutcome(),
  );
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  group('pendingGameDownloads', () {
    test('只收「游戏域 + 尚未结束」的任务', () {
      final List<DiscoveryDownloadTask> tasks = <DiscoveryDownloadTask>[
        _task(title: '在下', status: DiscoveryDownloadStatus.running),
        _task(title: '排队', status: DiscoveryDownloadStatus.queued),
        _task(title: '重试', status: DiscoveryDownloadStatus.waitingRetry),
        // 已完成的会走既有入库路径变成真条目，再占位就是重复。
        _task(title: '完成', status: DiscoveryDownloadStatus.done),
        _task(title: '失败', status: DiscoveryDownloadStatus.failed),
        _task(title: '取消', status: DiscoveryDownloadStatus.cancelled),
        // 别的媒体域的下载不该出现在游戏库里。
        _task(title: '一本书', kind: DiscoveryMediaKind.novel),
      ];

      expect(
        pendingGameDownloads(tasks)
            .map((DiscoveryDownloadTask t) => t.item.title)
            .toList(),
        <String>['在下', '排队', '重试'],
      );
    });
  });

  group('pendingGameDownloadLabel', () {
    test('有总大小时显示百分比', () {
      expect(
        pendingGameDownloadLabel(_task(
          title: 'x',
          receivedBytes: 250,
          totalBytes: 1000,
        )),
        '25%',
      );
    });

    test('总大小未知时退回「下载中」而不是显示 NaN/0%', () {
      expect(
        pendingGameDownloadLabel(_task(title: 'x')),
        t.game_library_downloading,
      );
    });

    test('排队/重试各有自己的文案', () {
      expect(
        pendingGameDownloadLabel(
            _task(title: 'x', status: DiscoveryDownloadStatus.queued)),
        t.game_library_download_queued,
      );
      expect(
        pendingGameDownloadLabel(
            _task(title: 'x', status: DiscoveryDownloadStatus.waitingRetry)),
        t.game_library_download_retrying,
      );
    });
  });

  testWidgets('占位卡渲染发现页拿到的名称，并给出进度', (WidgetTester tester) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 168,
              height: 260,
              child: buildPendingGameDownloadCard(
                _task(title: '9-nine-', receivedBytes: 500, totalBytes: 1000),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('9-nine-'), findsOneWidget,
        reason: '名称必须来自发现页条目 —— 用户正是靠它确认「加进来了」');
    final LinearProgressIndicator bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, closeTo(0.5, 0.001));
    expect(find.text('50%'), findsOneWidget);
  });

  testWidgets('没有封面时不崩，退回占位图标', (WidgetTester tester) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 168,
              height: 260,
              child: buildPendingGameDownloadCard(_task(title: '无封面')),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.download_outlined), findsOneWidget);
  });

  test('占位是渲染出来的，不是往 Galgames 表写假行（BUG-1911）', () {
    final String page = File(
      'lib/src/pages/implementations/games_library_page.dart',
    ).readAsStringSync();

    // 库页必须跟着下载队列刷新，否则占位卡不会随进度更新/消失。
    expect(page.contains('discoveryDownloadQueue.addListener'), isTrue);
    expect(page.contains('discoveryDownloadQueue.removeListener'), isTrue,
        reason: '监听必须解绑，否则页面销毁后队列还持有回调');

    // 占位路径绝不能碰写库原语 —— 那正是本条刻意避开的设计。
    final int start =
        page.indexOf('List<DiscoveryDownloadTask> pendingGameDownloads(');
    expect(start, greaterThanOrEqualTo(0));
    final int end = page.indexOf('/// 合集详情页的 game 成员卡', start);
    expect(end, greaterThan(start));
    final String body = page.substring(start, end);
    for (final String writer in <String>[
      'upsertGalgame(',
      'addAll(',
      'setGames(',
      'newGalgameEntryFromExe(',
    ]) {
      expect(body.contains(writer), isFalse,
          reason: '占位不得调用写库原语 $writer —— Galgames.exePath 是 NOT NULL，'
              '为占位造行等于埋下孤儿数据');
    }
  });

  // ---------------------------------------------------------------------------
  // 真 [GamesLibraryPage] 的三条渲染分支：占位与「库里有什么 / 筛出了什么」正交。
  //
  // 首版把占位 sliver 挂在网格构造内部，于是 `_games.isEmpty`（空态）和
  // `visible.isEmpty`（无匹配态）这两条分支上占位整个消失——而空库首次下载恰恰
  // 是用户提这条需求的场景本身（「否则不知道是否加入了」）。纯函数测不到它：
  // `pendingGameDownloads` 在坏版本里照样返回正确的列表，坏的是谁去渲染它。
  // ---------------------------------------------------------------------------
  group('GamesLibraryPage 占位与库内容并列', () {
    late Directory tmpDir;

    Future<_QueuedAppModel> buildModel(List<GalgameEntry> games) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final PreferencesRepository prefsRepo = PreferencesRepository(db);
      await prefsRepo.loadFromDb();
      tmpDir = Directory.systemTemp.createTempSync('hibiki_games_pending_');
      addTearDown(() {
        try {
          tmpDir.deleteSync(recursive: true);
        } catch (_) {}
      });
      final _QueuedAppModel appModel = _QueuedAppModel()
        ..wireLocalAudioForTesting(prefsRepo: prefsRepo, databaseDirectory: tmpDir)
        ..wireDatabaseForTesting(db);
      await appModel.setGalgames(games);
      return appModel;
    }

    /// 真入队一条游戏下载（走 [DiscoveryDownloadQueue.enqueue]，不是伪造 tasks）。
    void enqueueGame(_QueuedAppModel appModel, String title) {
      final bool added = appModel.discoveryDownloadQueue.enqueue(
        _item(title: title),
        destinationDir: tmpDir.path,
      );
      expect(added, isTrue, reason: '入队失败的话后面断言的「占位可见」就是空转');
    }

    Future<void> pumpPage(WidgetTester tester, _QueuedAppModel appModel) async {
      final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
      FushiToast.navigatorKey = navKey;
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[appProvider.overrideWith((_) => appModel)],
          child: TranslationProvider(
            child: MaterialApp(
              navigatorKey: navKey,
              home: const FushiFocusRoot(child: GamesLibraryPage()),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    GalgameEntry game(String id, String name) => GalgameEntry(
          id: id,
          name: name,
          exePath: 'Z:\\$id\\$name.exe',
          workdir: 'Z:\\$id',
          addedAt: DateTime(2026),
        );

    testWidgets('空库 + 在途下载：占位与空态同屏，占位不被空态吃掉',
        (WidgetTester tester) async {
      final _QueuedAppModel appModel = await buildModel(<GalgameEntry>[]);
      enqueueGame(appModel, '9-nine-');
      await pumpPage(tester, appModel);

      expect(find.text(t.game_empty), findsOneWidget,
          reason: '库确实是空的，空态引导必须还在');
      expect(
        find.byKey(const ValueKey<String>('games_pending_downloads')),
        findsOneWidget,
        reason: '空库首次下载正是用户提这条需求的场景，占位必须在场',
      );
      expect(find.text('9-nine-'), findsOneWidget,
          reason: '占位卡要显示发现页拿到的名称');
    });

    testWidgets('筛选后无匹配 + 在途下载：占位与无匹配态同屏',
        (WidgetTester tester) async {
      final _QueuedAppModel appModel =
          await buildModel(<GalgameEntry>[game('g1', 'alpha')]);
      enqueueGame(appModel, 'beta-downloading');
      await pumpPage(tester, appModel);
      // 先确认未筛选时库内容在场，避免下面的断言在「页面根本没渲染」上假绿。
      expect(find.text('alpha'), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, 'zzz-no-such-game');
      await tester.pump();

      expect(find.text('alpha'), findsNothing, reason: '搜索必须真的把库条目筛掉');
      expect(find.text(t.game_no_match), findsOneWidget,
          reason: '库里有东西只是被筛掉了，必须是无匹配态而不是空态');
      expect(
        find.byKey(const ValueKey<String>('games_pending_downloads')),
        findsOneWidget,
        reason: '在途下载还不在库里，本就不该被库的筛选条件筛掉',
      );
      expect(find.text('beta-downloading'), findsOneWidget);
    });

    testWidgets('库里有匹配项 + 在途下载：占位排在库内容之前',
        (WidgetTester tester) async {
      final _QueuedAppModel appModel =
          await buildModel(<GalgameEntry>[game('g1', 'alpha')]);
      enqueueGame(appModel, 'beta-downloading');
      await pumpPage(tester, appModel);

      expect(find.text('alpha'), findsOneWidget);
      expect(find.text('beta-downloading'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('beta-downloading')).dy,
        lessThan(tester.getTopLeft(find.text('alpha')).dy),
        reason: '用户刚点完下载，第一眼要能确认「加进来了」',
      );
    });
  });
}
