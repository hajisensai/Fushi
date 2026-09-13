import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_engine/updates/update_feed_kind.dart';
import 'package:fushi/src/updates/update_feed_service.dart';
import 'package:fushi/src/updates/update_notifier.dart';

/// v101 统一更新提醒的服务层契约。
///
/// 覆盖四条不变式：① 同一事件重复投递不复活已读、不刷新排序；② 关掉的域整批
/// 丢弃（不投递、不出红点、不通知）；③ 一批多条只发**一条**汇总通知；④ 已读
/// 保留期只清已读、未读永不清。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late PreferencesRepository prefs;
  late RecordingUpdateNotifier notifier;
  late DateTime clock;

  Future<UpdateFeedService> makeService() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    notifier = RecordingUpdateNotifier();
    clock = DateTime.utc(2026, 9, 9, 12);
    return UpdateFeedService(
      database: db,
      prefs: prefs,
      notifier: notifier,
      now: () => clock,
    );
  }

  UpdateFeedDraft episode(String key, {String title = '孤独摇滚'}) =>
      UpdateFeedDraft(
        kind: UpdateFeedKind.videoEpisode,
        targetKey: key,
        title: title,
        subtitle: '第 $key 集',
      );

  test('重复投递同一事件：不再算新、不复活已读、不刷新发现时刻', () async {
    final UpdateFeedService service = await makeService();

    final UpdateFeedPublishResult first =
        await service.publishBatch(UpdateFeedKind.videoEpisode, <UpdateFeedDraft>[
      episode('3'),
    ]);
    expect(first.newEntries, hasLength(1));
    expect(await service.unseenTotal(), 1);

    await service.markAllSeen(kind: UpdateFeedKind.videoEpisode);
    expect(await service.unseenTotal(), 0,
        reason: '标记已读后红点必须归零');

    // 下一轮检查又看到同一集（订阅检查每小时都会重新扫到已下载的集）。
    clock = clock.add(const Duration(hours: 1));
    final UpdateFeedPublishResult second =
        await service.publishBatch(UpdateFeedKind.videoEpisode, <UpdateFeedDraft>[
      episode('3'),
    ]);

    expect(second.newEntries, isEmpty, reason: '同身份事件只算一次新');
    expect(second.notificationSent, isFalse);
    expect(await service.unseenTotal(), 0,
        reason: '已读的条目不能被重复发现拽回未读——否则每轮检查都重新变红');

    final List<UpdateFeedEntryRow> rows = await service.entries();
    expect(rows, hasLength(1));
    expect(rows.single.discoveredAt,
        DateTime.utc(2026, 9, 9, 12).millisecondsSinceEpoch,
        reason: '重复发现不刷新 discoveredAt，否则列表排序会无故跳动');
  });

  test('关掉的域整批丢弃：不投递、不出红点、不通知', () async {
    final UpdateFeedService service = await makeService();
    await service.setKindEnabled(UpdateFeedKind.mangaChapter, false);

    final UpdateFeedPublishResult result = await service
        .publishBatch(UpdateFeedKind.mangaChapter, <UpdateFeedDraft>[
      const UpdateFeedDraft(
        kind: UpdateFeedKind.mangaChapter,
        targetKey: 'uid|ch-12',
        title: '葬送的芙莉莲',
        subtitle: '第 12 话',
      ),
    ]);

    expect(result.hasNew, isFalse);
    expect(notifier.sent, isEmpty);
    expect(await service.entries(), isEmpty,
        reason: '关掉的域不该在更新页留下用户明确说过不关心的条目');

    // 别的域不受影响。
    await service.publishBatch(
        UpdateFeedKind.videoEpisode, <UpdateFeedDraft>[episode('1')]);
    expect(await service.unseenTotal(), 1);
  });

  test('一批多条只发一条汇总通知；系统通知总开关只关通知不关红点', () async {
    final UpdateFeedService service = await makeService();

    await service.publishBatch(
      UpdateFeedKind.videoEpisode,
      <UpdateFeedDraft>[episode('1'), episode('2'), episode('3')],
    );
    expect(notifier.sent, hasLength(1),
        reason: '一轮检查落 3 集必须合成一条通知，逐条发等于刷屏');
    expect(notifier.sent.single.body, contains('+2'));
    expect(await service.unseenTotal(), 3);

    await service.disableSystemNotifications();
    await service.publishBatch(
        UpdateFeedKind.videoEpisode, <UpdateFeedDraft>[episode('4')]);
    expect(notifier.sent, hasLength(1), reason: '总开关关掉后不再发通知');
    expect(await service.unseenTotal(), 4,
        reason: '总开关只关系统通知，应用内红点照常');
  });

  test('通知权限被拒：照常投递照常红点，只是发不出通知', () async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final RecordingUpdateNotifier denied =
        RecordingUpdateNotifier(ready: false);
    final UpdateFeedService service = UpdateFeedService(
      database: db,
      prefs: prefs,
      notifier: denied,
      now: () => DateTime.utc(2026, 9, 9, 12),
    );

    final UpdateFeedPublishResult result = await service
        .publishBatch(UpdateFeedKind.videoEpisode, <UpdateFeedDraft>[
      episode('5'),
    ]);

    expect(result.hasNew, isTrue);
    expect(result.notificationSent, isFalse);
    expect(denied.sent, isEmpty);
    expect(await service.unseenTotal(), 1,
        reason: '通知发不出去绝不能把事件一起丢掉');
  });

  test('保留期只清已读，未读的一条不动', () async {
    final UpdateFeedService service = await makeService();

    await service.publishBatch(UpdateFeedKind.videoEpisode,
        <UpdateFeedDraft>[episode('1'), episode('2')]);
    final List<UpdateFeedEntryRow> all = await service.entries();
    await service.markSeen(<String>[all.first.entryId]);

    clock = clock.add(const Duration(days: 60));
    final int pruned = await service.pruneSeen();

    expect(pruned, 1);
    final List<UpdateFeedEntryRow> left = await service.entries();
    expect(left, hasLength(1));
    expect(left.single.seenAt, isNull,
        reason: '半年没看的订阅，那条未读提醒依然有效，不能因为老就抹掉');
  });

  test('未读计数按域分组，且域没有未读时键不出现', () async {
    final UpdateFeedService service = await makeService();
    await service.publishBatch(
        UpdateFeedKind.videoEpisode, <UpdateFeedDraft>[episode('1')]);
    await service.publishBatch(UpdateFeedKind.appRelease, <UpdateFeedDraft>[
      const UpdateFeedDraft(
        kind: UpdateFeedKind.appRelease,
        targetKey: '2.3.1',
        title: 'Hibiki 2.3.1',
      ),
    ]);

    final Map<UpdateFeedKind, int> counts = await service.unseenCounts();
    expect(counts[UpdateFeedKind.videoEpisode], 1);
    expect(counts[UpdateFeedKind.appRelease], 1);
    expect(counts.containsKey(UpdateFeedKind.mangaChapter), isFalse);
  });

  test('通知按组拆：同域不同作品各一条，同作品多集一条；配图/时刻/按钮透传', () async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    notifier = RecordingUpdateNotifier();
    final UpdateFeedService service = UpdateFeedService(
      database: db,
      prefs: prefs,
      notifier: notifier,
      notificationText: (UpdateFeedKind kind, List<UpdateFeedDraft> fresh) =>
          UpdateNotificationText(
        title: fresh.first.title,
        body: fresh.length == 1
            ? fresh.first.subtitle ?? ''
            : '+${fresh.length - 1}',
        openLabel: 'Play',
        viewAllLabel: 'View',
      ),
    );

    UpdateFeedDraft grouped(String key, String group, {String? image}) =>
        UpdateFeedDraft(
          kind: UpdateFeedKind.videoEpisode,
          targetKey: '$group/$key',
          title: group,
          subtitle: 'S01E$key',
          imagePath: image,
          publishedAt: 1700000000000,
          notificationGroup: 'collection:$group',
        );

    await service.publishBatch(
      UpdateFeedKind.videoEpisode,
      <UpdateFeedDraft>[
        grouped('1', 'A', image: r'C:\covers\a1.jpg'),
        grouped('2', 'A'),
        grouped('1', 'B'),
      ],
    );
    expect(notifier.sent, hasLength(2), reason: '两部作品各占一格，同作品两集合并');
    final UpdateNotification a = notifier.sent[0];
    final UpdateNotification b = notifier.sent[1];
    expect(a.id, isNot(b.id));
    expect(
      a.id,
      updateNotificationId(UpdateFeedKind.videoEpisode, 'collection:A'),
      reason: '同组恒同 id：下次 A 再更新替换而不是叠加',
    );
    expect(a.body, '+1');
    expect(a.imagePath, r'C:\covers\a1.jpg', reason: '配图取组内第一条');
    expect(a.timestamp, DateTime.fromMillisecondsSinceEpoch(1700000000000));
    expect(
      a.actions.map((UpdateNotificationAction x) => x.id),
      <String>[kUpdateNotificationActionOpen, kUpdateNotificationActionViewAll],
    );
    expect(
      a.actions.map((UpdateNotificationAction x) => x.label),
      <String>['Play', 'View'],
    );
    final UpdateNotificationPayload? payload =
        UpdateNotificationPayload.decode(a.payload);
    expect(payload?.kind, UpdateFeedKind.videoEpisode);
    expect(payload?.entryId, grouped('1', 'A').entryId,
        reason: '载荷指向组内第一条：点通知就播那一集');
    expect(b.imagePath, isNull);

    await service.markAllSeen(kind: UpdateFeedKind.videoEpisode);
    expect(notifier.cancelled, containsAll(<int>[a.id, b.id]),
        reason: '标已读要撤掉本进程发过的每条分组通知');
    expect(
      notifier.cancelled,
      contains(updateNotificationId(UpdateFeedKind.videoEpisode, null)),
      reason: '域级固定 id 也撤：上个进程留下的那条不在内存账本里',
    );
  });

  test('warmUpNotifier：启动期初始化一次；总开关关着不初始化', () async {
    final UpdateFeedService service = await makeService();
    await service.warmUpNotifier();
    await service.warmUpNotifier();
    expect(notifier.ensureReadyCalls, 1, reason: '重复 warm-up 不重复初始化');
    await service.publishBatch(
        UpdateFeedKind.videoEpisode, <UpdateFeedDraft>[episode('1')]);
    expect(notifier.ensureReadyCalls, 1, reason: '发通知复用启动期的初始化');

    final UpdateFeedService cold = await makeService();
    await cold.disableSystemNotifications();
    await cold.warmUpNotifier();
    expect(notifier.ensureReadyCalls, 0, reason: '关着总开关时不初始化');
  });

  test('BUG-2498：启动期 warm-up 只查询权限，绝不申请；申请只跟着用户打开开关',
      () async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final RecordingUpdateNotifier fresh =
        RecordingUpdateNotifier(permission: false);
    final UpdateFeedService service = UpdateFeedService(
      database: db,
      prefs: prefs,
      notifier: fresh,
      now: () => DateTime.utc(2026, 9, 13, 12),
    );

    await service.warmUpNotifier();
    expect(fresh.ensureReadyCalls, 1);
    expect(fresh.requestPermissionCalls, 0,
        reason: '退出新手引导那一帧不得弹系统权限框——MIUI 的权限界面会崩并连坐杀掉我们');
    expect(service.systemNotificationsEnabled, isTrue, reason: '偏好默认开');
    expect(service.systemNotificationsActive, isFalse,
        reason: '系统没授权时开关显示为关，不假装能发');

    final UpdateFeedPublishResult result = await service
        .publishBatch(UpdateFeedKind.videoEpisode, <UpdateFeedDraft>[
      episode('1'),
    ]);
    expect(result.hasNew, isTrue);
    expect(result.notificationSent, isFalse);
    expect(fresh.requestPermissionCalls, 0, reason: '发通知也不趁机申请');
    expect(await service.unseenTotal(), 1, reason: '没权限只是不发通知，红点照常');

    // 用户在设置里打开开关：这才是唯一的申请点。系统拒绝 → 开关仍显示为关。
    expect(await service.enableSystemNotifications(), isFalse);
    expect(fresh.requestPermissionCalls, 1);
    expect(service.systemNotificationsActive, isFalse);

    // 关掉再打开 = 再申请一次（用户改了主意，系统也可能已在设置里放行）。
    await service.disableSystemNotifications();
    expect(service.systemNotificationsEnabled, isFalse);
    expect(await service.enableSystemNotifications(), isFalse);
    expect(fresh.requestPermissionCalls, 2);
  });

  test('BUG-2498：用户打开开关且系统放行 → 开关显示开、通知照发', () async {
    final UpdateFeedService service = await makeService();
    expect(service.systemNotificationsActive, isFalse,
        reason: '还没 warm-up/申请，权限状态未知，不能显示为开');
    expect(await service.enableSystemNotifications(), isTrue);
    expect(notifier.requestPermissionCalls, 1);
    expect(service.systemNotificationsActive, isTrue);
    await service.publishBatch(
        UpdateFeedKind.videoEpisode, <UpdateFeedDraft>[episode('1')]);
    expect(notifier.sent, hasLength(1));
  });

  test('通知 id：无组回落到域固定值；有组跨进程稳定且不与其它域撞', () {
    expect(updateNotificationId(UpdateFeedKind.videoEpisode, null), 9101);
    expect(updateNotificationId(UpdateFeedKind.appRelease, null), 9104);
    final int a1 =
        updateNotificationId(UpdateFeedKind.videoEpisode, 'collection:1');
    expect(
      a1,
      updateNotificationId(UpdateFeedKind.videoEpisode, 'collection:1'),
    );
    expect(
      a1,
      isNot(updateNotificationId(UpdateFeedKind.videoEpisode, 'collection:2')),
    );
    expect(
      a1,
      isNot(updateNotificationId(UpdateFeedKind.mangaChapter, 'collection:1')),
    );
    expect(a1, greaterThan(0));
    expect(a1, lessThan(1 << 31), reason: 'Android 通知 id 是 32 位有符号 int');
  });

  test('载荷：JSON 往返；旧版裸 kind 值 / 垃圾解成 null 让调用方退到更新中心', () {
    const UpdateNotificationPayload payload = UpdateNotificationPayload(
      kind: UpdateFeedKind.mangaChapter,
      entryId: 'manga_chapter:x',
    );
    final UpdateNotificationPayload? back =
        UpdateNotificationPayload.decode(payload.encode());
    expect(back?.kind, UpdateFeedKind.mangaChapter);
    expect(back?.entryId, 'manga_chapter:x');
    expect(UpdateNotificationPayload.decode('video_episode'), isNull);
    expect(UpdateNotificationPayload.decode('{not json'), isNull);
    expect(UpdateNotificationPayload.decode(null), isNull);
  });

  test('混域投递直接抛错（通知按域合并，混进来会算错归属）', () async {
    final UpdateFeedService service = await makeService();
    expect(
      () => service.publishBatch(
        UpdateFeedKind.videoEpisode,
        <UpdateFeedDraft>[
          episode('1'),
          const UpdateFeedDraft(
            kind: UpdateFeedKind.mangaChapter,
            targetKey: 'uid|ch1',
            title: '别的域',
          ),
        ],
      ),
      throwsArgumentError,
    );
  });
}
