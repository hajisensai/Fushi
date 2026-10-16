import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/sync_compare_cli.dart';
import 'package:fushi/src/sync/sync_compare_dialog.dart';

SyncCompareEntry _book(
  String title, {
  String? key,
  int? local,
  int? remote,
  int? base,
  String? folder,
  bool content = true,
}) => SyncCompareEntry(
  title: title,
  bookKey: key,
  localUpdatedAt: local,
  remoteUpdatedAt: remote,
  base: base,
  remoteFolderId: folder,
  remoteHasContent: content,
);

/// 同步差异对比的控制通道：默认选择与对话框同一个函数，`--keep` / `--item` 只覆盖
/// 点到的部分；远端独有书只有点名 remote 才下载。
void main() {
  final List<SyncCompareEntry> entries = <SyncCompareEntry>[
    _book('本机较新', key: 'k-local', local: 200, remote: 100, base: 100),
    _book('远端较新', key: 'k-remote', local: 100, remote: 200, base: 100),
    _book('真分叉', key: 'k-conflict', local: 300, remote: 200, base: 100),
    _book('已一致', key: 'k-synced', local: 100, remote: 100, base: 100),
    _book('远端独有', folder: 'f1', remote: 50),
    _book('远端孤儿', folder: 'f2', remote: 50, content: false),
  ];

  test('id：本机书 = bookKey，远端独有 = remote:<书名>', () {
    expect(syncCompareEntryId(entries[0]), 'k-local');
    expect(syncCompareEntryId(entries[4]), 'remote:远端独有');
  });

  test('auto = 对话框默认：较新一侧（含真分叉），已一致 / 远端独有跳过', () {
    final SyncCompareCliPlan plan = resolveSyncCompareCliPlan(entries);
    expect(plan.books.map((SyncCompareEntry e) => e.title), <String>[
      '本机较新',
      '远端较新',
      '真分叉',
    ]);
    expect(plan.choices['本机较新'], SyncChoice.useLocal);
    expect(plan.choices['远端较新'], SyncChoice.useRemote);
    expect(plan.choices['真分叉'], SyncChoice.useLocal, reason: '本机时间戳较新');
    expect(plan.choices['已一致'], SyncChoice.skip);
    expect(plan.downloads, isEmpty);
    expect(
      defaultSyncCompareChoices(entries),
      plan.choices,
      reason: '与对话框默认选择同一份',
    );
  });

  test('--keep 管没点名的书，--item 逐条覆盖（含真分叉）', () {
    final SyncCompareCliPlan plan = resolveSyncCompareCliPlan(
      entries,
      keep: 'remote',
      items: <String, SyncChoice>{
        'k-conflict': SyncChoice.useLocal,
        'k-remote': SyncChoice.skip,
      },
    );
    expect(plan.choices['真分叉'], SyncChoice.useLocal);
    expect(plan.choices['本机较新'], SyncChoice.useRemote);
    expect(plan.choices['远端较新'], SyncChoice.skip);
    expect(plan.choices['已一致'], SyncChoice.skip, reason: '已一致的不被 --keep 卷进来');
    expect(
      plan.books.map((SyncCompareEntry e) => e.title),
      isNot(contains('远端较新')),
    );
  });

  test('远端独有：点名 remote 才下载；local / 孤儿 / 未知 id 拒绝', () {
    final SyncCompareCliPlan plan = resolveSyncCompareCliPlan(
      entries,
      keep: 'skip',
      items: <String, SyncChoice>{'remote:远端独有': SyncChoice.useRemote},
    );
    expect(plan.downloads.single.title, '远端独有');
    expect(plan.books, isEmpty);
    expect(
      () => resolveSyncCompareCliPlan(
        entries,
        items: <String, SyncChoice>{'remote:远端独有': SyncChoice.useLocal},
      ),
      throwsArgumentError,
    );
    expect(
      () => resolveSyncCompareCliPlan(
        entries,
        items: <String, SyncChoice>{'remote:远端孤儿': SyncChoice.useRemote},
      ),
      throwsArgumentError,
    );
    expect(
      () => resolveSyncCompareCliPlan(
        entries,
        items: <String, SyncChoice>{'nope': SyncChoice.useLocal},
      ),
      throwsArgumentError,
    );
    expect(
      () => resolveSyncCompareCliPlan(entries, keep: 'both'),
      throwsArgumentError,
    );
  });

  test('items JSON：合法对象解析，坏写法 FormatException / ArgumentError', () {
    expect(parseSyncCompareItems(null), isEmpty);
    expect(
      parseSyncCompareItems('{"a":"local","b":"skip"}'),
      <String, SyncChoice>{'a': SyncChoice.useLocal, 'b': SyncChoice.skip},
    );
    expect(() => parseSyncCompareItems('[1]'), throwsFormatException);
    expect(() => parseSyncCompareItems('{'), throwsFormatException);
    expect(() => parseSyncCompareItems('{"a":"mine"}'), throwsArgumentError);
  });
}
