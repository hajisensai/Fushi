import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/updates/update_feed_kind.dart';
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

    await service.setSystemNotificationsEnabled(false);
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
